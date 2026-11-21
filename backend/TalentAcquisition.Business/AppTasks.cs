using System;
using System.Collections.Generic;
using System.Data.SqlClient;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using TalentAcquisition.Common;
using TalentAcquisition.Data;
using TalentAcquisition.Models;

namespace TalentAcquisition.Business
{
    /// <summary>Retries work whose failure looks temporary: database busy (deadlock / lock timeout), timeouts, connection loss.
    /// Back-off doubles from the first delay. Anything else (a rule violation, a bug) fails at once.</summary>
    public static class RetryPolicy
    {
        private static readonly int[] TransientSql = { -2, 53, 121, 233, 258, 1205, 1222, 4060, 10053, 10054, 10060, 40143, 40197, 40501, 40613 };

        public static bool IsTransient(Exception ex)
        {
            for (var e = ex; e != null; e = e.InnerException)
            {
                if (e is TimeoutException) return true;
                var sql = e as SqlException;
                if (sql != null && sql.Errors.Cast<SqlError>().Any(x => TransientSql.Contains(x.Number))) return true;
                var api = e as ApiException;
                if (api != null && (api.Status == 503 || api.Status == 504)) return true;     // mapped "busy" / "timeout"
            }
            return false;
        }

        public static async Task<T> RunAsync<T>(Func<Task<T>> work, int attempts, TimeSpan firstDelay, Action<int, Exception, TimeSpan> onRetry = null, CancellationToken ct = default(CancellationToken))
        {
            if (attempts < 1) throw new ArgumentOutOfRangeException(nameof(attempts));
            var delay = firstDelay;
            for (int attempt = 1; ; attempt++)
            {
                try { return await work().ConfigureAwait(false); }
                catch (Exception ex) when (attempt < attempts && IsTransient(ex))
                {
                    onRetry?.Invoke(attempt, ex, delay);
                    await Task.Delay(delay, ct).ConfigureAwait(false);
                    delay = TimeSpan.FromTicks(delay.Ticks * 2);
                }
            }
        }
    }

    public sealed class TaskResult
    {
        public int Rows { get; set; }
        public string Summary { get; set; }
    }

    public sealed class TaskContext
    {
        public long ExecutionId { get; set; }
        public AppSettings Settings { get; set; }
        public AppTaskRepository Repo { get; set; }
        public StoredProcedureExecutor Db { get; set; }
        public StructuredLog Log { get; set; }
        public int MaxMessages { get; set; } = 1000;
        /// <summary>Writes a line to the run's details in the database (shown on Administrator > Scheduled jobs) and to the log.</summary>
        public async Task DetailAsync(string message, string level = "Info")
        {
            Log.Write(level == "Info" ? "info" : level == "Warning" ? "warn" : "error", message);
            try { await Repo.LogAsync(ExecutionId, message, level).ConfigureAwait(false); } catch (Exception ex) { Log.Error("could not store a run detail", ex); }
        }
    }

    public sealed class AppTaskDefinition
    {
        public string Command { get; set; }          // command-line name, e.g. interview-reminders
        public string JobName { get; set; }          // sched.JobDefinitions.JobName (Owner = TaskScheduler)
        public Func<TaskContext, Task<TaskResult>> Run { get; set; }
    }

    /// <summary>The application tasks. They queue messages or touch files; the data-changing work belongs to SQL Agent (Phase 11).</summary>
    public static class AppTaskCatalog
    {
        public static readonly AppTaskDefinition[] All =
        {
            new AppTaskDefinition { Command = "interview-reminders", JobName = "Interview reminders", Run = async c => Queued(await c.Repo.QueueInterviewRemindersAsync(24), "interview reminders (next 24 hours)") },
            new AppTaskDefinition { Command = "offer-reminders", JobName = "Offer expiry reminders", Run = async c => Queued(await c.Repo.QueueOfferExpiryRemindersAsync(2), "offer expiry reminders (next 2 days)") },
            new AppTaskDefinition { Command = "timesheet-reminders", JobName = "Timesheet reminders", Run = async c => Queued(await c.Repo.QueueTimesheetRemindersAsync(), "timesheet reminders (this week)") },
            new AppTaskDefinition { Command = "contract-expiry-notices", JobName = "Contract expiry notifications", Run = async c => Queued(await c.Repo.QueueContractExpiryNoticesAsync(), "contract expiry notices") },
            new AppTaskDefinition { Command = "daily-report", JobName = "Daily report delivery", Run = async c => Queued(await c.Repo.QueueDailyReportAsync(), "daily summary e-mails") },
            new AppTaskDefinition { Command = "process-notifications", JobName = "Email queue processing", Run = ProcessNotificationsAsync },
            new AppTaskDefinition { Command = "file-housekeeping", JobName = "File housekeeping", Run = FileHousekeeping.RunAsync }
        };

        public static AppTaskDefinition Find(string command)
        {
            if (command == "email-queue") command = "process-notifications";
            return All.FirstOrDefault(t => t.Command == command);
        }

        private static TaskResult Queued(Row r, string what)
        {
            int q = r == null ? 0 : r.Int("Queued"), n = r == null ? 0 : r.Int("Considered");
            return new TaskResult { Rows = q, Summary = "queued " + q + " " + what + " for " + n + " item(s)" };
        }

        private static async Task<TaskResult> ProcessNotificationsAsync(TaskContext c)
        {
            var p = new NotificationProcessor(new NotificationRepository(c.Db), new PickupDirectoryMailSender(c.Settings.MailOutboxPath), c.Settings, c.Log);
            var r = await p.RunAsync(c.MaxMessages).ConfigureAwait(false);
            if (r.Failed + r.GaveUp > 0) await c.DetailAsync(r.Failed + " message(s) failed and will be retried, " + r.GaveUp + " given up (see Administrator > E-mail queue).", "Warning");
            return new TaskResult { Rows = r.Sent, Summary = r.ToString() };
        }
    }

    /// <summary>File work in the application's folders, which SQL Server does not touch (KI-032, KI-033, KI-040).</summary>
    public static class FileHousekeeping
    {
        public static async Task<TaskResult> RunAsync(TaskContext c)
        {
            var s = c.Settings; int rows = 0;
            // 1. files of documents deleted more than N days ago (the database row stays for the audit trail)
            var store = new DocumentStore(s.DocumentStorePath);
            var purge = await c.Repo.ListPurgeableFilesAsync(s.DeletedFileRetentionDays).ConfigureAwait(false);
            int purged = 0, missing = 0;
            foreach (var d in purge)
            {
                var name = d.Str("StoredFileName");
                bool existed = File.Exists(store.PathFor(name));
                store.DeleteOrphan(name);
                if (File.Exists(store.PathFor(name))) throw new IOException("Could not delete the file of document " + d.Int("DocumentId") + ".");
                await c.Repo.MarkFilePurgedAsync(d.Int("DocumentId")).ConfigureAwait(false);
                if (existed) purged++; else missing++;
            }
            rows += purge.Count;
            await c.DetailAsync("Deleted documents: removed " + purged + " file(s) deleted over " + s.DeletedFileRetentionDays + " days ago" + (missing > 0 ? " (" + missing + " were already gone)" : "") + ".");

            // 2. e-mails in the mock outbox older than N days
            int mails = 0;
            if (Directory.Exists(s.MailOutboxPath))
            {
                var cutoff = DateTime.UtcNow.AddDays(-s.OutboxRetentionDays);
                foreach (var f in new DirectoryInfo(s.MailOutboxPath).GetFiles("*.eml", SearchOption.TopDirectoryOnly).Where(f => f.LastWriteTimeUtc < cutoff))
                { f.Delete(); mails++; }
            }
            rows += mails;
            await c.DetailAsync("Mail outbox: removed " + mails + " e-mail file(s) older than " + s.OutboxRetentionDays + " days.");

            // 3. the document store copied to its backup folder (new and changed files; files no longer in the store removed)
            int copied = 0, removed = 0;
            Directory.CreateDirectory(s.DocumentBackupPath);
            if (Directory.Exists(s.DocumentStorePath))
            {
                var src = new DirectoryInfo(s.DocumentStorePath); string srcRoot = src.FullName.TrimEnd('\\') + "\\";
                var present = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                foreach (var f in src.GetFiles("*", SearchOption.AllDirectories))
                {
                    var rel = f.FullName.Substring(srcRoot.Length); present.Add(rel);
                    var dst = new FileInfo(Path.Combine(s.DocumentBackupPath, rel));
                    if (!dst.Exists || dst.Length != f.Length || dst.LastWriteTimeUtc < f.LastWriteTimeUtc)
                    {
                        Directory.CreateDirectory(dst.DirectoryName);
                        f.CopyTo(dst.FullName, true); copied++;
                    }
                }
                var bakRoot = new DirectoryInfo(s.DocumentBackupPath).FullName.TrimEnd('\\') + "\\";
                foreach (var f in new DirectoryInfo(s.DocumentBackupPath).GetFiles("*", SearchOption.AllDirectories))
                    if (!present.Contains(f.FullName.Substring(bakRoot.Length))) { f.Delete(); removed++; }
            }
            rows += copied + removed;
            await c.DetailAsync("Document store copy in " + s.DocumentBackupPath + ": " + copied + " file(s) copied, " + removed + " removed.");
            return new TaskResult { Rows = rows, Summary = "purged " + purged + " document file(s), removed " + mails + " outbox e-mail(s), backup copied " + copied + " / removed " + removed };
        }
    }

    public static class ExitCodes
    {
        public const int Ok = 0, Failed = 1, Config = 2, Database = 3, Usage = 64;
    }

    /// <summary>
    /// Runs one task the way Task Scheduler expects:
    ///   machine-wide mutex (a second copy on this machine exits at once) -> database lease (sched.usp_AppTaskBegin: a run on
    ///   any machine blocks; abandoned runs are cleared) -> the work, retried while failures look temporary -> outcome
    ///   recorded (Succeeded / Failed + error; a failure notifies the administrators) -> exit code.
    /// </summary>
    public sealed class TaskRunner
    {
        private readonly AppSettings _s; private readonly StoredProcedureExecutor _db; private readonly AppTaskRepository _repo; private readonly StructuredLog _log;
        public TaskRunner(AppSettings s, StoredProcedureExecutor db, StructuredLog log) { _s = s; _db = db; _repo = new AppTaskRepository(db); _log = log; }

        public async Task<int> RunAsync(AppTaskDefinition task, int maxMessages = 1000)
        {
            var log = _log.With("task", task.Command);
            var dbName = new SqlConnectionStringBuilder(_s.ConnectionString).InitialCatalog;
            // a named semaphore, not a mutex: the run awaits, so it may finish on another thread, and a mutex must be released
            // by the thread that took it. Windows deletes the semaphore when the last process holding it ends (also on a crash).
            using (var gate = new Semaphore(1, 1, @"Global\TAMS.Scheduler." + dbName + "." + task.Command))
            {
                bool mine = gate.WaitOne(0);
                if (!mine)
                {
                    // not recorded in the database: the running copy holds the job's lease and records its own run
                    log.Write("warn", "another copy of this task is running on this machine; nothing to do", new { outcome = "Skipped" });
                    return ExitCodes.Ok;
                }
                try { return await RunLockedAsync(task, log, maxMessages).ConfigureAwait(false); }
                finally { gate.Release(); }
            }
        }

        private async Task<int> RunLockedAsync(AppTaskDefinition task, StructuredLog log, int maxMessages)
        {
            Row begin;
            try
            {
                begin = await RetryPolicy.RunAsync(() => _repo.BeginAsync(task.JobName, _s.TaskLeaseMinutes, Environment.MachineName), _s.TaskRetryAttempts, TimeSpan.FromSeconds(2),
                    (n, ex, d) => log.Write("warn", "database not available, retrying", new { attempt = n, delayMs = (int)d.TotalMilliseconds }, ex)).ConfigureAwait(false);
            }
            catch (Exception ex) { log.Write("error", "could not start: the database is not reachable or refused the run", null, ex); return ExitCodes.Database; }

            long id = Convert.ToInt64(begin["ExecutionId"]);
            log = log.With("run", id);
            if (begin.Str("Outcome") == "Skipped") { log.Write("warn", "skipped: " + begin.Str("Message"), new { outcome = "Skipped" }); return ExitCodes.Ok; }

            var ctx = new TaskContext { ExecutionId = id, Settings = _s, Repo = _repo, Db = _db, Log = log, MaxMessages = maxMessages };
            var sw = System.Diagnostics.Stopwatch.StartNew();
            log.Write("info", "started", new { job = task.JobName, host = Environment.MachineName });
            try
            {
                var r = await RetryPolicy.RunAsync(() => task.Run(ctx), _s.TaskRetryAttempts, TimeSpan.FromSeconds(2),
                    (n, ex, d) => { log.Write("warn", "temporary failure, retrying", new { attempt = n, delayMs = (int)d.TotalMilliseconds }, ex);
                                    ctx.DetailAsync("Attempt " + n + " failed (" + ex.GetType().Name + ": " + ex.Message + "); retrying.", "Warning").GetAwaiter().GetResult(); }).ConfigureAwait(false);
                await ctx.DetailAsync(char.ToUpperInvariant(r.Summary[0]) + r.Summary.Substring(1) + ".").ConfigureAwait(false);
                await _repo.EndAsync(id, "Succeeded", r.Rows, null).ConfigureAwait(false);
                log.Write("info", "succeeded", new { outcome = "Succeeded", rows = r.Rows, ms = sw.ElapsedMilliseconds, summary = r.Summary });
                return ExitCodes.Ok;
            }
            catch (Exception ex)
            {
                var msg = ex.GetType().Name + ": " + ex.Message;
                log.Write("error", "failed", new { outcome = "Failed", ms = sw.ElapsedMilliseconds }, ex);
                try { await _repo.EndAsync(id, "Failed", 0, msg).ConfigureAwait(false); }      // also notifies the administrators
                catch (Exception e2) { log.Write("error", "could not record the failure in the database (it stays 'Running' until the lease expires)", null, e2); }
                return ExitCodes.Failed;
            }
        }
    }
}
