using System;
using System.Data.SqlClient;
using System.IO;
using System.Linq;
using System.Net;
using System.Threading.Tasks;
using Microsoft.VisualStudio.TestTools.UnitTesting;
using Newtonsoft.Json.Linq;
using TalentAcquisition.Business;
using TalentAcquisition.Common;
using TalentAcquisition.Data;

namespace TalentAcquisition.Tests
{
    /// <summary>
    /// Phase 14: the business rules the requirements name explicitly, proved through the HTTP API (the browser tests prove
    /// the same paths through the UI). Direct SQL only arranges time-dependent state or checks the stored trail.
    /// </summary>
    [TestClass]
    public class CandidateManagementTests
    {
        [TestMethod]
        public async Task Recruiters_create_update_and_search_candidates_with_optimistic_concurrency()
        {
            var rec = await Api.As("priya.menon@tams.local");
            var email = "mgmt." + Guid.NewGuid().ToString("N").Substring(0, 8) + "@candidate.example";
            int id = (int)Expect.Status(await rec.Post("api/v1/candidates", new { firstName = "Mira", lastName = "Manage", email, currentTitle = "Analyst", totalExperienceYears = 4 }), HttpStatusCode.Created).Json["candidateId"];
            Expect.Error(await rec.Post("api/v1/candidates", new { firstName = "Mira", lastName = "Twice", email = email.ToUpperInvariant(), totalExperienceYears = 4 }), HttpStatusCode.Conflict, "conflict");

            var got = Expect.Status(await rec.Get("api/v1/candidates/" + id), HttpStatusCode.OK).Json["profile"];
            var rowVer = (string)got["rowVer"];
            Expect.Status(await rec.Put("api/v1/candidates/" + id, new { rowVer, firstName = "Mira", lastName = "Manage", currentTitle = "Senior Analyst", totalExperienceYears = 5 }), HttpStatusCode.OK);
            Expect.Error(await rec.Put("api/v1/candidates/" + id, new { rowVer, firstName = "Mira", lastName = "Stale", totalExperienceYears = 6 }), HttpStatusCode.Conflict, "concurrency");   // someone saved in between
            Expect.Error(await rec.Put("api/v1/candidates/" + id, new { firstName = "Mira", lastName = "Manage", totalExperienceYears = 61 }), HttpStatusCode.BadRequest, "validation");

            Expect.Status(await rec.Post("api/v1/candidates/" + id + "/skills", new { skillName = "Tableau", yearsExperience = 3, proficiencyLevel = 4 }), HttpStatusCode.NoContent);
            var found = Expect.Status(await rec.Get("api/v1/candidates?skills=Tableau&minExp=5"), HttpStatusCode.OK).Json;
            Assert.IsTrue(((JArray)found["items"]).Any(c => (int)c["candidateId"] == id), found.ToString());
            Assert.AreEqual("Senior Analyst", Db.Scalar<string>("SELECT CurrentTitle FROM cand.Candidates WHERE CandidateId = @i", new SqlParameter("@i", id)));
            Assert.IsTrue(Db.Scalar<int>("SELECT COUNT(*) FROM audit.AuditLogs WHERE TableName = 'cand.Candidates' AND RecordId = CAST(@i AS NVARCHAR(50)) AND ChangedByUserId = @u",
                new SqlParameter("@i", id), new SqlParameter("@u", Db.UserId("priya.menon@tams.local"))) >= 2, "created and updated by the recruiter, audited");
            var cand = await Api.As("rohan.gupta@candidate.example");
            Expect.Error(await cand.Get("api/v1/candidates/" + id), HttpStatusCode.Forbidden, "forbidden");
        }
    }

    [TestClass]
    public class OfferAndInterviewEdgeCaseTests
    {
        [TestMethod]
        public async Task HR_rejects_an_offer_with_a_reason_and_a_candidate_declines_a_sent_offer()
        {
            var anita = await Api.As("anita.kapoor@tams.local");
            int pending = Db.Scalar<int>("SELECT OfferId FROM cand.JobOffers WHERE OfferNo LIKE 'OFR-%-003'");
            Expect.Error(await anita.Post("api/v1/offers/" + pending + "/reject", new { }), HttpStatusCode.BadRequest, "validation");     // a reason is required
            Expect.Status(await anita.Post("api/v1/offers/" + pending + "/reject", new { comments = "Above the approved band" }), HttpStatusCode.NoContent);
            Assert.AreEqual("Rejected", Db.Scalar<string>("SELECT Status FROM cand.JobOffers WHERE OfferId = @o", new SqlParameter("@o", pending)));
            var rahul = await Api.As("rahul.desai@tams.local");
            Expect.Error(await rahul.Post("api/v1/offers/" + pending + "/send"), (HttpStatusCode)422, "business_rule");

            int sent = Db.Scalar<int>("SELECT OfferId FROM cand.JobOffers WHERE OfferNo LIKE 'OFR-%-002'");
            Db.Exec("UPDATE cand.JobOffers SET ExpiresAt = DATEADD(DAY, 5, SYSUTCDATETIME()) WHERE OfferId = @o AND Status = 'Sent'", new SqlParameter("@o", sent));
            var karan = await Api.As("karan.joshi@candidate.example");
            Expect.Status(await karan.Post("api/v1/offers/" + sent + "/decline", new { note = "Accepted elsewhere" }), HttpStatusCode.OK);
            Expect.Error(await karan.Post("api/v1/offers/" + sent + "/accept", new { }), (HttpStatusCode)422, "business_rule");          // answered once
            Assert.AreEqual("Declined", Db.Scalar<string>("SELECT Status FROM cand.JobOffers WHERE OfferId = @o", new SqlParameter("@o", sent)));
            Assert.AreEqual("Rejected", Db.Scalar<string>("SELECT a.Status FROM cand.JobApplications a JOIN cand.JobOffers o ON o.ApplicationId = a.ApplicationId WHERE o.OfferId = @o", new SqlParameter("@o", sent)));
            Assert.AreEqual(0, Db.Scalar<int>("SELECT COUNT(*) FROM hr.Employees WHERE JobOfferId = @o", new SqlParameter("@o", sent)), "no employee for a declined offer");
        }

        [TestMethod]
        public async Task An_interview_is_rescheduled_with_concurrency_and_time_checks_then_cancelled()
        {
            var admin = await Api.As("admin@tams.local");
            int iv = Db.Scalar<int>("SELECT TOP 1 InterviewId FROM cand.Interviews WHERE Status IN ('Scheduled', 'Rescheduled') AND StartsAt > SYSUTCDATETIME() ORDER BY InterviewId");
            Assert.IsTrue(iv > 0, "seed has an upcoming interview");
            var before = Expect.Status(await admin.Get("api/v1/interviews/" + iv), HttpStatusCode.OK).Json["interview"];
            var rowVer = (string)before["rowVer"];
            int invites = Db.Scalar<int>("SELECT COUNT(*) FROM notify.NotificationQueue WHERE RelatedEntityType = 'Interview' AND RelatedEntityId = @i", new SqlParameter("@i", iv));
            var start = DateTime.UtcNow.AddDays(3).Date.AddHours(5);
            Expect.Error(await admin.Put("api/v1/interviews/" + iv + "/reschedule", new { startsAt = DateTime.UtcNow.AddHours(-2), endsAt = DateTime.UtcNow.AddHours(-1), rowVer }), HttpStatusCode.BadRequest, "validation");   // not in the past
            var moved = Expect.Status(await admin.Put("api/v1/interviews/" + iv + "/reschedule", new { startsAt = start, endsAt = start.AddHours(1), mode = "Onsite", locationOrLink = "Room 4", rowVer }), HttpStatusCode.OK).Json;
            Assert.AreEqual("Rescheduled", (string)moved["status"]); Assert.AreNotEqual(rowVer, (string)moved["rowVer"], "a new row version is returned");
            Expect.Error(await admin.Put("api/v1/interviews/" + iv + "/reschedule", new { startsAt = start.AddDays(1), endsAt = start.AddDays(1).AddHours(1), rowVer }), HttpStatusCode.Conflict, "concurrency");   // stale version
            var after = Expect.Status(await admin.Get("api/v1/interviews/" + iv), HttpStatusCode.OK).Json["interview"];
            Assert.AreEqual("Rescheduled", (string)after["status"]); Assert.AreEqual("Onsite", (string)after["mode"]);
            Assert.IsTrue(Db.Scalar<int>("SELECT COUNT(*) FROM notify.NotificationQueue WHERE RelatedEntityType = 'Interview' AND RelatedEntityId = @i", new SqlParameter("@i", iv)) > invites, "a new invitation is queued");
            Expect.Status(await admin.Post("api/v1/interviews/" + iv + "/cancel", new { reason = "Candidate unavailable" }), HttpStatusCode.NoContent);
            Expect.Error(await admin.Put("api/v1/interviews/" + iv + "/reschedule", new { startsAt = start, endsAt = start.AddHours(1) }), (HttpStatusCode)422, "business_rule");    // cancelled is final
        }
    }

    [TestClass]
    public class ContractAndBillingEdgeCaseTests
    {
        [TestMethod]
        public async Task Contract_expiry_is_detected_shown_to_the_customer_reported_and_renewed()
        {
            int ct = Db.Scalar<int>("SELECT ContractId FROM staff.Contracts WHERE ContractNo LIKE 'CON-%-002'");
            Db.Exec("UPDATE staff.Contracts SET EndDate = DATEADD(DAY, 10, dbo.fn_BusinessToday()), Status = 'Active' WHERE ContractId = @c", new SqlParameter("@c", ct));
            Db.Exec("EXEC sched.usp_Job_DetectContractExpiry");                        // what the nightly SQL Agent job runs
            var meera = await Api.As("meera.iyer@brightwave.example");
            var mine = (JArray)Expect.Status(await meera.Get("api/v1/contracts"), HttpStatusCode.OK).Json;
            var c = mine.Single(x => (int)x["contractId"] == ct);
            Assert.AreEqual("Expiring", (string)c["status"]); Assert.AreEqual(10, (int)c["daysToExpiry"]);
            var report = Expect.Status(await meera.Get("api/v1/reports/expiring-contracts"), HttpStatusCode.OK).Json;
            Assert.IsTrue(report["rows"].Any(r => ((string)r["contractNo"]).StartsWith("CON-") && r.ToString().Contains((string)c["contractNo"])), "listed in the expiring-contracts report");

            var rahul = await Api.As("rahul.desai@tams.local");
            Expect.Error(await rahul.Post("api/v1/contracts/" + ct + "/renew", new { newEndDate = Dates.Today.AddDays(5), reason = "earlier" }), (HttpStatusCode)422, "business_rule");
            Expect.Error(await meera.Post("api/v1/contracts/" + ct + "/renew", new { newEndDate = Dates.Today.AddMonths(6) }), HttpStatusCode.Forbidden, "forbidden");
            var renewed = Expect.Status(await rahul.Post("api/v1/contracts/" + ct + "/renew", new { newEndDate = Dates.Today.AddMonths(6), reason = "Extended" }), HttpStatusCode.OK).Json;
            Assert.AreEqual("Active", (string)renewed["status"]);
            Assert.AreEqual("Active", Db.Scalar<string>("SELECT Status FROM staff.Contracts WHERE ContractId = @c", new SqlParameter("@c", ct)));
            Assert.AreEqual(1, Db.Scalar<int>("SELECT COUNT(*) FROM staff.ContractExtensions WHERE ContractId = @c AND Reason = N'Extended'", new SqlParameter("@c", ct)));
        }

        [TestMethod]
        public async Task Invoice_generation_fails_without_a_rate_in_force_leaves_nothing_and_succeeds_on_retry_then_void_releases_the_hours()
        {
            int apex = Db.CustomerId("APEX");
            var ts = Db.Scalar<int>("SELECT TOP 1 t.TimesheetId FROM [time].Timesheets t WHERE t.CustomerId = @c AND t.Status = 'Approved' ORDER BY t.WeekStartDate", new SqlParameter("@c", apex));
            Assert.IsTrue(ts > 0, "seed has approved, uninvoiced Apex hours");
            var week = Db.Scalar<DateTime>("SELECT WeekStartDate FROM [time].Timesheets WHERE TimesheetId = @t", new SqlParameter("@t", ts));
            int contract = Db.Scalar<int>("SELECT a.ContractId FROM [time].Timesheets t JOIN staff.Assignments a ON a.AssignmentId = t.AssignmentId WHERE t.TimesheetId = @t", new SqlParameter("@t", ts));
            var period = new { customerId = apex, periodStart = week.ToString("yyyy-MM-dd"), periodEnd = week.AddDays(6).ToString("yyyy-MM-dd"), taxRate = 18 };
            var rahul = await Api.As("rahul.desai@tams.local");
            int invoicesBefore = Db.Scalar<int>("SELECT COUNT(*) FROM bill.Invoices WHERE CustomerId = @c", new SqlParameter("@c", apex));

            // the rate in force starts only after the week: generation is refused with the day and assignment, nothing is written
            var original = new System.Collections.Generic.List<Tuple<int, DateTime>>();
            using (var cn = new SqlConnection(TestHost.DbConnection)) { cn.Open(); using (var cmd = new SqlCommand("SELECT ContractRateId, EffectiveFrom FROM staff.ContractRates WHERE ContractId = @c", cn)) { cmd.Parameters.AddWithValue("@c", contract); using (var r = cmd.ExecuteReader()) while (r.Read()) original.Add(Tuple.Create(r.GetInt32(0), r.GetDateTime(1))); } }
            Db.Exec("UPDATE staff.ContractRates SET EffectiveFrom = DATEADD(DAY, 7, @w) WHERE ContractId = @c", new SqlParameter("@c", contract), new SqlParameter("@w", week));
            try
            {
                var fail = Expect.Error(await rahul.Post("api/v1/invoices/generate", period), (HttpStatusCode)422, "business_rule");
                StringAssert.Contains((string)fail.Json["message"], "No contract rate is in force on");
                Assert.AreEqual(invoicesBefore, Db.Scalar<int>("SELECT COUNT(*) FROM bill.Invoices WHERE CustomerId = @c", new SqlParameter("@c", apex)), "no invoice and no lines left behind");
            }
            finally { foreach (var o in original) Db.Exec("UPDATE staff.ContractRates SET EffectiveFrom = @f WHERE ContractRateId = @r", new SqlParameter("@f", o.Item2), new SqlParameter("@r", o.Item1)); }

            // the rate is corrected: the same run succeeds
            var inv = Expect.Status(await rahul.Post("api/v1/invoices/generate", period), HttpStatusCode.Created).Json;
            int invId = (int)inv["invoiceId"];
            Assert.IsTrue((decimal)inv["total"] > 0);
            Expect.Error(await rahul.Post("api/v1/invoices/generate", period), (HttpStatusCode)422, "business_rule");    // nothing left to bill

            // voiding the draft releases the hours, so they can be invoiced again
            Expect.Error(await rahul.Post("api/v1/invoices/" + invId + "/void", new { }), HttpStatusCode.BadRequest, "validation");
            Expect.Status(await rahul.Post("api/v1/invoices/" + invId + "/void", new { reason = "Wrong period" }), HttpStatusCode.NoContent);
            Assert.AreEqual("Void", Db.Scalar<string>("SELECT Status FROM bill.Invoices WHERE InvoiceId = @i", new SqlParameter("@i", invId)));
            var again = Expect.Status(await rahul.Post("api/v1/invoices/generate", period), HttpStatusCode.Created).Json;
            Assert.AreEqual((decimal)inv["total"], (decimal)again["total"]);
        }
    }

    [TestClass]
    public class SchedulerRecoveryTests
    {
        [TestMethod]
        public async Task A_failed_daily_report_recovers_once_the_missing_summary_is_prepared()
        {
            var s = TestHost.Settings;
            var settings = new AppSettings { ConnectionString = s.ConnectionString, DbImpersonateUser = TestHost.WorkerDbUser, MailOutboxPath = s.MailOutboxPath, MailFrom = s.MailFrom, AppBaseUrl = s.AppBaseUrl,
                                             DocumentStorePath = s.DocumentStorePath, DocumentBackupPath = Path.Combine(Path.GetTempPath(), "tams-docbak-" + Guid.NewGuid().ToString("N")),
                                             TaskLeaseMinutes = 60, TaskRetryAttempts = 1, CommandTimeoutSeconds = 60 };
            var logDir = Path.Combine(Path.GetTempPath(), "tams-recovery-logs-" + Guid.NewGuid().ToString("N"));
            try
            {
                var runner = new TaskRunner(settings, new StoredProcedureExecutor(new ConnectionManager(settings), new NullLog()), new StructuredLog(logDir, "scheduler", console: false));
                Db.Exec("DELETE FROM report.DailyRecruitmentSummary WHERE SummaryDate = DATEADD(DAY, -1, dbo.fn_BusinessToday())");
                Assert.AreEqual(ExitCodes.Failed, await runner.RunAsync(AppTaskCatalog.Find("daily-report")));
                int queued = Db.Scalar<int>("SELECT COUNT(*) FROM notify.NotificationQueue WHERE TemplateCode = 'DAILY_SUMMARY'");
                Db.Exec("DECLARE @d DATE = DATEADD(DAY, -1, dbo.fn_BusinessToday()); EXEC sched.usp_Job_DailyRecruitmentSummary @SummaryDate = @d");   // the Agent job's catch-up
                Assert.AreEqual(ExitCodes.Ok, await runner.RunAsync(AppTaskCatalog.Find("daily-report")));
                Assert.AreEqual("Succeeded", Db.Scalar<string>("SELECT TOP 1 h.Outcome FROM sched.JobExecutionHistory h JOIN sched.JobDefinitions d ON d.JobDefinitionId = h.JobDefinitionId WHERE d.JobName = N'Daily report delivery' ORDER BY h.ExecutionId DESC"));
                Assert.IsTrue(Db.Scalar<int>("SELECT COUNT(*) FROM notify.NotificationQueue WHERE TemplateCode = 'DAILY_SUMMARY'") > queued, "the report is now queued to the recipients");
            }
            finally { if (Directory.Exists(logDir)) Directory.Delete(logDir, true); }
        }
    }
}
