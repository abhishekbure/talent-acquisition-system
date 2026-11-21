using System;
using System.Data.SqlClient;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.VisualStudio.TestTools.UnitTesting;
using Newtonsoft.Json.Linq;
using TalentAcquisition.Business;
using TalentAcquisition.Common;
using TalentAcquisition.Data;

namespace TalentAcquisition.Tests
{
    /// <summary>Phase 12: the console app's building blocks (retry policy, structured log) and the task runner against the
    /// disposable database. Real process runs and Task Scheduler runs are in scripts/testing/Test-ScheduledTasks.ps1.</summary>
    [TestClass]
    public class SchedulerTests
    {
        [TestMethod]
        public async Task Temporary_failures_are_retried_with_back_off_and_other_failures_are_not()
        {
            int calls = 0; var delays = new System.Collections.Generic.List<TimeSpan>();
            var r = await RetryPolicy.RunAsync(() => { calls++; if (calls < 3) throw new TimeoutException("db slow"); return Task.FromResult(42); },
                                               3, TimeSpan.FromMilliseconds(10), (n, ex, d) => delays.Add(d));
            Assert.AreEqual(42, r); Assert.AreEqual(3, calls);
            CollectionAssert.AreEqual(new[] { TimeSpan.FromMilliseconds(10), TimeSpan.FromMilliseconds(20) }, delays, "back-off doubles");

            calls = 0;
            await Assert.ThrowsExceptionAsync<TimeoutException>(() => RetryPolicy.RunAsync<int>(() => { calls++; throw new TimeoutException(); }, 3, TimeSpan.FromMilliseconds(1)));
            Assert.AreEqual(3, calls, "gives up after the attempts");

            calls = 0;
            await Assert.ThrowsExceptionAsync<ApiException>(() => RetryPolicy.RunAsync<int>(() => { calls++; throw new ApiException(422, "business_rule", "no summary"); }, 3, TimeSpan.FromMilliseconds(1)));
            Assert.AreEqual(1, calls, "a rule violation is not retried");

            Assert.IsTrue(RetryPolicy.IsTransient(new ApiException(503, "busy", "x")));
            Assert.IsTrue(RetryPolicy.IsTransient(new ApiException(504, "timeout", "x")));
            Assert.IsTrue(RetryPolicy.IsTransient(new InvalidOperationException("wrapped", new TimeoutException())));
            Assert.IsFalse(RetryPolicy.IsTransient(new ApiException(404, "not_found", "x")));
            Assert.IsFalse(RetryPolicy.IsTransient(new IOException("disk")));
        }

        [TestMethod]
        public void The_structured_log_writes_one_json_object_per_line_with_the_task_and_run()
        {
            var dir = Path.Combine(Path.GetTempPath(), "tams-log-test-" + Guid.NewGuid().ToString("N"));
            try
            {
                var log = new StructuredLog(dir, "scheduler", console: false).With("task", "daily-report").With("run", 77L);
                log.Write("info", "succeeded", new { rows = 5, summary = "queued 5" });
                log.Error("failed \"quoted\"", new TimeoutException("db"));
                var lines = File.ReadAllLines(Directory.GetFiles(dir, "scheduler-*.jsonl").Single());
                Assert.AreEqual(2, lines.Length);
                var a = JObject.Parse(lines[0]); var b = JObject.Parse(lines[1]);
                Assert.AreEqual("daily-report", (string)a["task"]); Assert.AreEqual(77, (long)a["run"]); Assert.AreEqual(5, (int)a["rows"]); Assert.AreEqual("info", (string)a["level"]);
                Assert.AreEqual("error", (string)b["level"]); Assert.AreEqual("failed \"quoted\"", (string)b["msg"]); StringAssert.Contains((string)b["error"], "TimeoutException");
                StringAssert.Matches(lines[0], new System.Text.RegularExpressions.Regex("^\\{\"ts\":\"\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}\\.\\d{3}Z\""), "ISO UTC timestamp first");
            }
            finally { if (Directory.Exists(dir)) Directory.Delete(dir, true); }
        }

        private static TaskRunner Runner(out StoredProcedureExecutor db)
        {
            var s = TestHost.Settings;
            var settings = new AppSettings { ConnectionString = s.ConnectionString, DbImpersonateUser = TestHost.WorkerDbUser, MailOutboxPath = s.MailOutboxPath, MailFrom = s.MailFrom,
                                             AppBaseUrl = s.AppBaseUrl, DocumentStorePath = s.DocumentStorePath, DocumentBackupPath = Path.Combine(Path.GetTempPath(), "tams-docbak-" + Guid.NewGuid().ToString("N")),
                                             TaskLeaseMinutes = 60, TaskRetryAttempts = 2, CommandTimeoutSeconds = 60 };
            db = new StoredProcedureExecutor(new ConnectionManager(settings), new NullLog());
            return new TaskRunner(settings, db, new StructuredLog(Path.Combine(Path.GetTempPath(), "tams-sched-test-logs"), "scheduler", console: false));
        }
        private static Tuple<string, string, int?> LastRun(string job)
        {
            using (var c = new SqlConnection(TestHost.DbConnection))
            {
                c.Open();
                using (var cmd = new SqlCommand("SELECT TOP 1 h.Outcome, h.ErrorMessage, h.RowsAffected FROM sched.JobExecutionHistory h JOIN sched.JobDefinitions d ON d.JobDefinitionId = h.JobDefinitionId WHERE d.JobName = @j ORDER BY h.ExecutionId DESC", c))
                {
                    cmd.Parameters.AddWithValue("@j", job);
                    using (var r = cmd.ExecuteReader()) { r.Read(); return Tuple.Create(r.GetString(0), r.IsDBNull(1) ? null : r.GetString(1), r.IsDBNull(2) ? (int?)null : r.GetInt32(2)); }
                }
            }
        }

        [TestMethod]
        public async Task The_task_runner_records_success_skips_a_held_job_and_reports_failure()
        {
            StoredProcedureExecutor db;
            var runner = Runner(out db);
            Assert.AreEqual(ExitCodes.Ok, await runner.RunAsync(AppTaskCatalog.Find("offer-reminders")));
            Assert.AreEqual("Succeeded", LastRun("Offer expiry reminders").Item1);

            // another machine holds the job's lease
            Db.Exec("INSERT sched.JobExecutionHistory (JobDefinitionId, HostName) SELECT JobDefinitionId, 'OTHER-PC' FROM sched.JobDefinitions WHERE JobName = N'Offer expiry reminders'");
            Assert.AreEqual(ExitCodes.Ok, await runner.RunAsync(AppTaskCatalog.Find("offer-reminders")), "skipped is not a failure");
            var skipped = LastRun("Offer expiry reminders");
            Assert.AreEqual("Skipped", skipped.Item1); StringAssert.Contains(skipped.Item2, "OTHER-PC");
            Db.Exec("UPDATE sched.JobExecutionHistory SET Outcome = 'Failed', FinishedAt = SYSUTCDATETIME() WHERE HostName = 'OTHER-PC' AND Outcome = 'Running'");

            // the daily report without a prepared summary fails, is recorded and is reported to the administrators
            Db.Exec("DELETE FROM report.DailyRecruitmentSummary WHERE SummaryDate = DATEADD(DAY, -1, dbo.fn_BusinessToday())");
            Assert.AreEqual(ExitCodes.Failed, await runner.RunAsync(AppTaskCatalog.Find("daily-report")));
            var failed = LastRun("Daily report delivery");
            Assert.AreEqual("Failed", failed.Item1); StringAssert.Contains(failed.Item2, "Prepare daily recruitment summary");
            Assert.IsTrue(Db.Scalar<int>("SELECT COUNT(*) FROM notify.NotificationQueue WHERE TemplateCode = 'JOB_FAILED' AND Subject LIKE N'%Daily report delivery%'") >= 1);

            Assert.IsNull(AppTaskCatalog.Find("drop-tables"));
            Assert.AreEqual("process-notifications", AppTaskCatalog.Find("email-queue").Command);
        }
    }
}
