using System;
using System.IO;
using Newtonsoft.Json.Linq;

namespace TalentAcquisition.Common
{
    /// <summary>
    /// Settings from appsettings.json, overridden by appsettings.local.json (git-ignored, holds secrets) and then by
    /// environment variables TAMS_*. Validated at start-up: a missing/weak secret stops the process (exit code 2).
    /// </summary>
    public sealed class AppSettings
    {
        public string ConnectionString { get; set; }
        public string DbImpersonateUser { get; set; }          // database user to EXECUTE AS after connecting (least privilege)
        public string JwtSecret { get; set; }
        public string JwtIssuer { get; set; } = "TalentAcquisition.API";
        public string JwtAudience { get; set; } = "TalentAcquisition.UI";
        public int TokenMinutes { get; set; } = 60;
        public string ListenUrl { get; set; } = "http://localhost:5000/";
        public string[] CorsOrigins { get; set; } = new[] { "http://localhost:4200" };
        public string LogDirectory { get; set; } = "logs";
        public string ResetLinkBase { get; set; } = "http://localhost:4200/reset-password";
        public int CommandTimeoutSeconds { get; set; } = 60;
        public int MaxRequestBodyKb { get; set; } = 1024;
        /// <summary>Folder for uploaded documents, outside anything the web host serves. Relative paths are resolved against the API folder.</summary>
        public string DocumentStorePath { get; set; } = @"..\..\..\..\..\storage\documents";
        /// <summary>Link e-mailed to confirm a new account's address (token appended as ?token=).</summary>
        public string VerifyEmailLinkBase { get; set; } = "http://localhost:4200/verify-email";
        /// <summary>Address of the web application, used for links in e-mails.</summary>
        public string AppBaseUrl { get; set; } = "http://localhost:4200";
        /// <summary>Mock e-mail provider: every message is written as an .eml file into this folder (SMTP pickup directory); nothing is sent over the network.</summary>
        public string MailOutboxPath { get; set; } = @"..\..\..\..\..\storage\mail-outbox";
        public string MailFrom { get; set; } = "TAMS <no-reply@tams.local>";
        public int NotificationBatchSize { get; set; } = 20;
        public int NotificationLeaseSeconds { get; set; } = 300;
        // Phase 12: Task Scheduler tasks
        /// <summary>Copy of the document store kept by the file-housekeeping task (files are not in database backups).</summary>
        public string DocumentBackupPath { get; set; } = @"..\..\..\..\..\storage\document-backup";
        public int DeletedFileRetentionDays { get; set; } = 30;
        public int OutboxRetentionDays { get; set; } = 30;
        /// <summary>A task run that has not reported back after this long is considered abandoned.</summary>
        public int TaskLeaseMinutes { get; set; } = 60;
        /// <summary>Attempts for a task whose failure looks temporary (database busy/unreachable, timeouts); back-off 2 s, 4 s, ...</summary>
        public int TaskRetryAttempts { get; set; } = 3;
        // Phase 13: per-client limits on the anonymous account endpoints (requests per minute per client IP address; 0 = off)
        /// <summary>POST auth/login. Complements the per-account lockout (5 failures) against guessing across many accounts.</summary>
        public int RateLimitLoginPerMinute { get; set; } = 20;
        /// <summary>POST auth/register, auth/forgot-password and auth/resend-verification (each sends an e-mail).</summary>
        public int RateLimitAccountPerMinute { get; set; } = 5;
        /// <summary>POST auth/verify-email and auth/reset-password (guessing of one-time links).</summary>
        public int RateLimitTokenPerMinute { get; set; } = 10;
        // Phase 15: local deployment
        /// <summary>Folder of the production Angular build (the folder holding index.html). When set, the API also serves the web
        /// application on its own address (same origin, no CORS needed); empty = API only. Relative paths are resolved against the API folder.</summary>
        public string WebRoot { get; set; } = "";

        /// <param name="extraSettingsFile">Optional extra JSON file applied after appsettings(.local).json and before environment variables
        /// (the scheduler's --settings option, e.g. to point a test registration at a disposable database).</param>
        public static AppSettings Load(string baseDirectory = null, string extraSettingsFile = null)
        {
            baseDirectory = baseDirectory ?? AppDomain.CurrentDomain.BaseDirectory;
            var merged = new JObject();
            var files = new System.Collections.Generic.List<string> { Path.Combine(baseDirectory, "appsettings.json"), Path.Combine(baseDirectory, "appsettings.local.json") };
            if (extraSettingsFile != null)
            {
                if (!File.Exists(extraSettingsFile)) throw new FileNotFoundException("Settings file not found.", extraSettingsFile);
                files.Add(extraSettingsFile);
            }
            foreach (var path in files)
            {
                if (File.Exists(path)) merged.Merge(JObject.Parse(File.ReadAllText(path)), new JsonMergeSettings { MergeArrayHandling = MergeArrayHandling.Replace });
            }
            var s = merged.ToObject<AppSettings>() ?? new AppSettings();
            s.ConnectionString = Env("TAMS_CONNECTION_STRING") ?? s.ConnectionString;
            s.JwtSecret = Env("TAMS_JWT_SECRET") ?? s.JwtSecret;
            s.ListenUrl = Env("TAMS_LISTEN_URL") ?? s.ListenUrl;
            s.DbImpersonateUser = Env("TAMS_DB_IMPERSONATE") ?? s.DbImpersonateUser;
            if (!Path.IsPathRooted(s.LogDirectory)) s.LogDirectory = Path.Combine(baseDirectory, s.LogDirectory);
            s.WebRoot = Env("TAMS_WEB_ROOT") ?? s.WebRoot;
            if (!string.IsNullOrWhiteSpace(s.WebRoot) && !Path.IsPathRooted(s.WebRoot)) s.WebRoot = Path.GetFullPath(Path.Combine(baseDirectory, s.WebRoot));
            s.DocumentStorePath = Env("TAMS_DOCUMENT_STORE") ?? s.DocumentStorePath;
            if (!string.IsNullOrWhiteSpace(s.DocumentStorePath) && !Path.IsPathRooted(s.DocumentStorePath)) s.DocumentStorePath = Path.GetFullPath(Path.Combine(baseDirectory, s.DocumentStorePath));
            s.MailOutboxPath = Env("TAMS_MAIL_OUTBOX") ?? s.MailOutboxPath;
            if (!string.IsNullOrWhiteSpace(s.MailOutboxPath) && !Path.IsPathRooted(s.MailOutboxPath)) s.MailOutboxPath = Path.GetFullPath(Path.Combine(baseDirectory, s.MailOutboxPath));
            if (!string.IsNullOrWhiteSpace(s.DocumentBackupPath) && !Path.IsPathRooted(s.DocumentBackupPath)) s.DocumentBackupPath = Path.GetFullPath(Path.Combine(baseDirectory, s.DocumentBackupPath));
            return s;
        }

        private static string Env(string name) { var v = Environment.GetEnvironmentVariable(name); return string.IsNullOrWhiteSpace(v) ? null : v; }

        /// <summary>Returns a list of problems (empty = valid). The scheduler issues no tokens, so it skips the JWT checks.</summary>
        public string[] Validate(bool requireJwt = true)
        {
            var p = new System.Collections.Generic.List<string>();
            if (string.IsNullOrWhiteSpace(ConnectionString)) p.Add("ConnectionString is not configured.");
            if (requireJwt && (string.IsNullOrWhiteSpace(JwtSecret) || System.Text.Encoding.UTF8.GetByteCount(JwtSecret) < 32))
                p.Add("JwtSecret must be at least 32 bytes. Run scripts\\setup\\New-LocalConfig.ps1 to generate appsettings.local.json.");
            if (string.IsNullOrWhiteSpace(MailOutboxPath) || !Path.IsPathRooted(MailOutboxPath)) p.Add("MailOutboxPath must resolve to an absolute folder.");
            try { new System.Net.Mail.MailAddress(MailFrom ?? ""); } catch (FormatException) { p.Add("MailFrom is not a valid address."); }
            if (NotificationBatchSize < 1 || NotificationBatchSize > 500) p.Add("NotificationBatchSize must be between 1 and 500.");
            if (NotificationLeaseSeconds < 30 || NotificationLeaseSeconds > 3600) p.Add("NotificationLeaseSeconds must be between 30 and 3600.");
            if (string.IsNullOrWhiteSpace(DocumentBackupPath) || !Path.IsPathRooted(DocumentBackupPath)) p.Add("DocumentBackupPath must resolve to an absolute folder.");
            if (!string.IsNullOrWhiteSpace(DocumentBackupPath) && !string.IsNullOrWhiteSpace(DocumentStorePath)
                && Path.GetFullPath(DocumentBackupPath).TrimEnd('\\').Equals(Path.GetFullPath(DocumentStorePath).TrimEnd('\\'), StringComparison.OrdinalIgnoreCase))
                p.Add("DocumentBackupPath must differ from DocumentStorePath.");
            if (DeletedFileRetentionDays < 7) p.Add("DeletedFileRetentionDays must be at least 7.");
            if (OutboxRetentionDays < 1) p.Add("OutboxRetentionDays must be at least 1.");
            if (TaskLeaseMinutes < 1 || TaskLeaseMinutes > 1440) p.Add("TaskLeaseMinutes must be between 1 and 1440.");
            if (TaskRetryAttempts < 1 || TaskRetryAttempts > 10) p.Add("TaskRetryAttempts must be between 1 and 10.");
            if (TokenMinutes < 5 || TokenMinutes > 1440) p.Add("TokenMinutes must be between 5 and 1440.");
            if (MaxRequestBodyKb < 1 || MaxRequestBodyKb > 10240) p.Add("MaxRequestBodyKb must be between 1 and 10240.");
            if (RateLimitLoginPerMinute < 0 || RateLimitAccountPerMinute < 0 || RateLimitTokenPerMinute < 0
                || RateLimitLoginPerMinute > 100000 || RateLimitAccountPerMinute > 100000 || RateLimitTokenPerMinute > 100000)
                p.Add("RateLimit*PerMinute must be between 0 (off) and 100000.");
            if (string.IsNullOrWhiteSpace(DocumentStorePath) || !Path.IsPathRooted(DocumentStorePath)) p.Add("DocumentStorePath must resolve to an absolute folder.");
            if (string.IsNullOrWhiteSpace(ListenUrl) || !ListenUrl.StartsWith("http://localhost", StringComparison.OrdinalIgnoreCase) && !ListenUrl.StartsWith("http://127.0.0.1"))
                p.Add("ListenUrl must be a loopback address (the API is local only).");
            if (!string.IsNullOrWhiteSpace(DbImpersonateUser) && !System.Text.RegularExpressions.Regex.IsMatch(DbImpersonateUser, "^[A-Za-z0-9_]{1,64}$"))
                p.Add("DbImpersonateUser contains invalid characters.");
            return p.ToArray();
        }
    }
}
