using System;
using System.IO;
using System.Linq;
using TalentAcquisition.Business;
using TalentAcquisition.Common;
using TalentAcquisition.Data;

namespace TalentAcquisition.Scheduler
{
    /// <summary>
    /// Application-level scheduled tasks, started by Windows Task Scheduler (scripts\scheduler\Register-ScheduledTasks.ps1).
    ///   run &lt;task&gt; [--max N]       interview-reminders | offer-reminders | timesheet-reminders | contract-expiry-notices |
    ///                                daily-report | process-notifications (alias email-queue) | file-housekeeping
    ///   process-notifications [--max N]   (Phase 9 form, still accepted)
    ///   list                         the tasks and the job each records its runs under
    ///   --check                      validate configuration, folders and database access, then exit
    ///   --settings &lt;file&gt;           extra JSON settings applied after appsettings(.local).json (e.g. a test database)
    /// Exit codes: 0 succeeded or skipped (another run in progress / switched off), 1 the task failed (recorded, administrators
    ///             notified), 2 invalid configuration, 3 database unreachable, 64 wrong usage.
    /// Data-changing scheduled work is NOT here: it runs in SQL Server Agent (database\11_AgentJobs).
    /// </summary>
    public static class Program
    {
        public static int Main(string[] args)
        {
            string settingsFile = Option(args, "--settings");
            args = Strip(args, "--settings");
            AppSettings settings;
            try { settings = AppSettings.Load(null, settingsFile == null ? null : Path.GetFullPath(settingsFile)); }
            catch (Exception ex) when (ex is FileNotFoundException || ex is Newtonsoft.Json.JsonException) { Console.Error.WriteLine("CONFIG ERROR: " + ex.Message); return ExitCodes.Config; }
            var problems = settings.Validate(requireJwt: false);
            if (problems.Length > 0) { foreach (var p in problems) Console.Error.WriteLine("CONFIG ERROR: " + p); return ExitCodes.Config; }

            if (args.Length == 0 || args[0] == "--help" || args[0] == "-h") { Usage(); return args.Length == 0 ? ExitCodes.Usage : ExitCodes.Ok; }
            var log = new StructuredLog(settings.LogDirectory, "scheduler");
            var db = new StoredProcedureExecutor(new ConnectionManager(settings), new NullLog());   // per-call SQL timing is noise here; the task logs what matters

            if (args[0] == "list")
            {
                foreach (var t in AppTaskCatalog.All) Console.WriteLine(t.Command.PadRight(26) + t.JobName);
                return ExitCodes.Ok;
            }
            if (args[0] == "--check") return Check(settings, db, log);

            string command; int max = 1000;
            if (args[0] == "run" && args.Length >= 2) command = args[1];
            else if (args[0] == "process-notifications" || args[0] == "email-queue") command = "process-notifications";
            else { Usage(); return ExitCodes.Usage; }
            var task = AppTaskCatalog.Find(command);
            if (task == null) { Console.Error.WriteLine("Unknown task '" + command + "'. Run 'list' for the tasks."); return ExitCodes.Usage; }
            string m = Option(args, "--max");
            if (m != null && (!int.TryParse(m, out max) || max < 1)) { Usage(); return ExitCodes.Usage; }

            try { return new TaskRunner(settings, db, log).RunAsync(task, max).GetAwaiter().GetResult(); }
            catch (Exception ex) { log.Write("error", "unexpected error outside the task", null, ex); return ExitCodes.Failed; }
        }

        /// <summary>Configuration, folders and database: everything a scheduled run needs, without doing any work.</summary>
        private static int Check(AppSettings s, StoredProcedureExecutor db, StructuredLog log)
        {
            foreach (var dir in new[] { s.MailOutboxPath, s.DocumentBackupPath, s.LogDirectory })
            {
                try
                {
                    Directory.CreateDirectory(dir);
                    var probe = Path.Combine(dir, ".tams-write-check-" + Guid.NewGuid().ToString("N"));
                    File.WriteAllText(probe, "ok"); File.Delete(probe);
                }
                catch (Exception ex) { Console.Error.WriteLine("CONFIG ERROR: folder not writable: " + dir + " (" + ex.Message + ")"); return ExitCodes.Config; }
            }
            try
            {
                var ping = new AuthRepository(db).PingAsync().GetAwaiter().GetResult();
                Console.WriteLine("CHECK OK database=" + ping.Str("DatabaseName") + " user=" + ping.Str("DatabaseUser") + " outbox=" + s.MailOutboxPath
                                  + " documents=" + s.DocumentStorePath + " document-backup=" + s.DocumentBackupPath + " logs=" + s.LogDirectory);
                log.Write("info", "check ok", new { database = ping.Str("DatabaseName") });
                return ExitCodes.Ok;
            }
            catch (Exception ex) { log.Write("error", "database not reachable", null, ex); return ExitCodes.Database; }
        }

        private static string Option(string[] args, string name)
        {
            int i = Array.IndexOf(args, name);
            return i >= 0 && i + 1 < args.Length ? args[i + 1] : null;
        }
        private static string[] Strip(string[] args, string name)
        {
            int i = Array.IndexOf(args, name);
            return i < 0 ? args : args.Where((a, k) => k != i && k != i + 1).ToArray();
        }
        private static void Usage()
        {
            Console.Error.WriteLine("Usage: TalentAcquisition.Scheduler.exe run <task> [--max N] [--settings file] | list | --check [--settings file]");
            Console.Error.WriteLine("Tasks: " + string.Join(", ", AppTaskCatalog.All.Select(t => t.Command)));
        }
    }
}
