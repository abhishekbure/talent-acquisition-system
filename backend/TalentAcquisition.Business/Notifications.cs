using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Mail;
using System.Net.Mime;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using TalentAcquisition.Common;
using TalentAcquisition.Data;
using TalentAcquisition.Models;

namespace TalentAcquisition.Business
{
    /// <summary>Where rendered e-mails go. The only implementation is the local mock provider below.</summary>
    public interface IMailSender
    {
        void Send(MailMessage message);
    }

    /// <summary>
    /// Mock e-mail provider: System.Net.Mail.SmtpClient in pickup-directory mode writes each message as an .eml file into a
    /// local folder (open it with any mail program). No SMTP server is contacted and nothing leaves the machine.
    /// The folder is (re)created on every send, so a missing folder is not a failure but an unwritable one is.
    /// </summary>
    public sealed class PickupDirectoryMailSender : IMailSender
    {
        private readonly string _dir;
        public PickupDirectoryMailSender(string directory)
        {
            if (string.IsNullOrWhiteSpace(directory) || !Path.IsPathRooted(directory)) throw new ArgumentException("The mail outbox must be an absolute path.", nameof(directory));
            _dir = directory;
        }
        public string Directory { get { return _dir; } }

        public void Send(MailMessage message)
        {
            System.IO.Directory.CreateDirectory(_dir);
            using (var client = new SmtpClient { DeliveryMethod = SmtpDeliveryMethod.SpecifiedPickupDirectory, PickupDirectoryLocation = _dir })
                client.Send(message);
        }
    }

    /// <summary>Turns a queued notification into an e-mail: plain text plus an HTML alternative, both built from the same text.
    /// Every value is HTML-encoded (bodies can contain comments typed by users) and header values are reduced to one line.</summary>
    public static class MailRenderer
    {
        private static readonly Regex Url = new Regex(@"https?://[^\s<>""]+[^\s<>"".,;:!?)]", RegexOptions.Compiled | RegexOptions.CultureInvariant);
        private static readonly Regex Control = new Regex(@"[\x00-\x1F\x7F]+", RegexOptions.Compiled);

        public static string OneLine(string v, int max)
        {
            v = Control.Replace(v ?? "", " ").Trim();
            return v.Length <= max ? v : v.Substring(0, max - 1).TrimEnd() + "…";
        }

        public static MailMessage Render(Row n, AppSettings s)
        {
            var to = new MailAddress(n.Str("ToEmail"), OneLine(n.Str("RecipientName"), 150));
            var m = new MailMessage(new MailAddress(s.MailFrom), to)
            {
                Subject = OneLine(n.Str("Subject"), 250),
                SubjectEncoding = Encoding.UTF8,
                HeadersEncoding = Encoding.UTF8
            };
            long id = Convert.ToInt64(n["NotificationId"]);
            m.Headers.Add("X-TAMS-Notification-Id", id.ToString(System.Globalization.CultureInfo.InvariantCulture));
            // one id per notification and attempt: a duplicate delivery after a lost lease is recognisable as such
            m.Headers.Add("Message-ID", "<notification-" + id + "." + n.Int("AttemptNo") + "@tams.local>");
            m.Headers.Add("X-TAMS-Template", OneLine(n.Str("TemplateCode"), 40));
            m.Headers.Add("Auto-Submitted", "auto-generated");

            string text = Text(n, s);
            var plain = AlternateView.CreateAlternateViewFromString(text, Encoding.UTF8, MediaTypeNames.Text.Plain);
            plain.TransferEncoding = TransferEncoding.EightBit;            // readable in the .eml file as it is
            var html = AlternateView.CreateAlternateViewFromString(Html(text), Encoding.UTF8, MediaTypeNames.Text.Html);
            html.TransferEncoding = TransferEncoding.EightBit;
            m.AlternateViews.Add(plain);
            m.AlternateViews.Add(html);
            return m;
        }

        public static string Text(Row n, AppSettings s)
        {
            var name = OneLine(n.Str("RecipientName"), 150);
            var body = (n.Str("Body") ?? "").Replace("\r\n", "\n").Trim();
            var sb = new StringBuilder();
            sb.Append("Hello ").Append(name.Length > 0 ? name : "there").Append(",\n\n");
            sb.Append(body).Append("\n\n");
            bool security = n.Str("TemplateCode") == "PASSWORD_RESET" || n.Str("TemplateCode") == "EMAIL_VERIFY";
            if (!security) sb.Append("See it in TAMS: ").Append(s.AppBaseUrl.TrimEnd('/')).Append("/notifications\n\n");
            sb.Append("-- \nTAMS - Talent Acquisition Management System\n");
            sb.Append("This message was generated automatically by a local development system. Replies are not read.\n");
            return sb.ToString();
        }

        /// <summary>HTML-encodes the text, keeps line breaks and makes plain http(s) links clickable.</summary>
        public static string Html(string text)
        {
            var enc = WebUtility.HtmlEncode(text);
            enc = Url.Replace(enc, mt => "<a href=\"" + mt.Value + "\">" + mt.Value + "</a>");
            enc = enc.Replace("\n", "<br>\n");
            return "<!DOCTYPE html><html><head><meta charset=\"utf-8\"></head><body style=\"font-family:Segoe UI,Arial,sans-serif;font-size:14px;line-height:1.5;color:#1f2937\">\n"
                 + enc + "\n</body></html>";
        }
    }

    public sealed class ProcessResult
    {
        public int Claimed { get; set; }
        public int Sent { get; set; }
        public int Failed { get; set; }
        public int GaveUp { get; set; }
        public int LostLease { get; set; }
        public override string ToString() { return "claimed=" + Claimed + " sent=" + Sent + " failed=" + Failed + " gave-up=" + GaveUp + " lost-lease=" + LostLease; }
    }

    /// <summary>
    /// Sends due notifications: claim a batch (leased in the database), render, hand to the mail provider, record the outcome.
    /// A provider error is recorded against that message (retried later with back-off); a database error stops the run.
    /// Logs ids and templates only - never addresses or message text.
    /// </summary>
    public sealed class NotificationProcessor
    {
        private readonly NotificationRepository _repo; private readonly IMailSender _sender; private readonly AppSettings _s; private readonly ILog _log;
        public NotificationProcessor(NotificationRepository repo, IMailSender sender, AppSettings s, ILog log) { _repo = repo; _sender = sender; _s = s; _log = log; }

        public async Task<ProcessResult> RunAsync(int maxMessages = 1000, CancellationToken ct = default(CancellationToken))
        {
            var result = new ProcessResult();
            while (result.Claimed < maxMessages && !ct.IsCancellationRequested)
            {
                int take = Math.Min(_s.NotificationBatchSize, maxMessages - result.Claimed);
                List<Row> batch = await _repo.ClaimBatchAsync(take, _s.NotificationLeaseSeconds).ConfigureAwait(false);
                if (batch.Count == 0) break;
                result.Claimed += batch.Count;
                foreach (var n in batch)
                {
                    long id = Convert.ToInt64(n["NotificationId"]); int attempt = n.Int("AttemptNo"); string tpl = n.Str("TemplateCode");
                    string error = null;
                    try { using (var m = MailRenderer.Render(n, _s)) _sender.Send(m); }
                    catch (Exception ex) when (!(ex is OutOfMemoryException)) { error = Describe(ex); }

                    if (error == null)
                    {
                        if (await _repo.MarkSentAsync(id, attempt).ConfigureAwait(false)) { result.Sent++; _log.Info("notify sent id=" + id + " template=" + tpl + " attempt=" + attempt); }
                        else { result.LostLease++; _log.Warn("notify id=" + id + " sent, but its lease had been taken over; a duplicate e-mail is possible"); }
                    }
                    else
                    {
                        var r = await _repo.MarkFailedAsync(id, attempt, error).ConfigureAwait(false);
                        if (r == null || r.Int("Updated") != 1) { result.LostLease++; _log.Warn("notify id=" + id + " failed after its lease was taken over: " + error); }
                        else if (r.Str("Status") == "Failed") { result.GaveUp++; _log.Error("notify gave up id=" + id + " template=" + tpl + " after attempt " + attempt + ": " + error, null); }
                        else { result.Failed++; _log.Warn("notify failed id=" + id + " template=" + tpl + " attempt=" + attempt + ", retry after " + (r.Date("NextAttemptAt") ?? DateTime.UtcNow).ToString("yyyy-MM-dd HH:mm:ss") + "Z: " + error); }
                    }
                }
            }
            return result;
        }

        private static string Describe(Exception ex)
        {
            var sb = new StringBuilder();
            for (var e = ex; e != null && sb.Length < 900; e = e.InnerException) { if (sb.Length > 0) sb.Append(" <- "); sb.Append(e.GetType().Name).Append(": ").Append(e.Message); }
            return sb.Length > 1000 ? sb.ToString(0, 1000) : sb.ToString();
        }
    }
}
