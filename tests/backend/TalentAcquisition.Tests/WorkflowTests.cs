using System;
using System.Data.SqlClient;
using System.Linq;
using System.Net;
using System.Threading.Tasks;
using Microsoft.VisualStudio.TestTools.UnitTesting;
using Newtonsoft.Json.Linq;

namespace TalentAcquisition.Tests
{
    /// <summary>
    /// The two business models end to end, driven ONLY through the HTTP API by the real role accounts.
    /// Direct SQL is used for two things only: moving an interview into the past (time cannot be waited for) and verifying the stored trail.
    /// </summary>
    [TestClass]
    public class InternalRecruitmentWorkflowTests
    {
        [TestMethod]
        public async Task Hiring_request_to_active_employee()
        {
            var vikram = await Api.As("vikram.nair@tams.local");   // HR Manager, Engineering head
            var anita = await Api.As("anita.kapoor@tams.local");   // HR Manager
            var priya = await Api.As("priya.menon@tams.local");    // Recruiter
            int vikramId = Db.UserId("vikram.nair@tams.local"), priyaId = Db.UserId("priya.menon@tams.local");
            int dept = Db.Scalar<int>("SELECT DepartmentId FROM org.Departments WHERE HeadUserId = @u", new SqlParameter("@u", vikramId));
            var title = "API Workflow Engineer " + Guid.NewGuid().ToString("N").Substring(0, 6);

            // 1. hiring request: create + submit, requester cannot approve own, another HR manager approves
            var er = Expect.Status(await vikram.Post("api/v1/requisitions", new { departmentId = dept, title, headcount = 1, justification = "API test", submit = true }), HttpStatusCode.Created);
            int erId = (int)er.Json["employeeRequisitionId"];
            Expect.Error(await vikram.Post("api/v1/requisitions/" + erId + "/approve", new { comments = "self" }), (HttpStatusCode)422, "business_rule");
            Expect.Status(await anita.Post("api/v1/requisitions/" + erId + "/approve", new { comments = "budget ok" }), HttpStatusCode.NoContent);

            // 2. job with skills; recruiters cannot approve jobs; HR approves; recruiter publishes
            var job = Expect.Status(await priya.Post("api/v1/jobs", new
            {
                employeeRequisitionId = erId, openings = 1, summary = "Builds APIs", minExperienceYears = 2, salaryMin = 1200000, salaryMax = 1800000,
                skills = new[] { new { skillName = "C#", isRequired = true, minYears = 2 }, new { skillName = "SQL Server", isRequired = false, minYears = 1 } }
            }), HttpStatusCode.Created);
            int jobId = (int)job.Json["jobRequisitionId"];
            Expect.Status(await priya.Post("api/v1/jobs/" + jobId + "/publish", new { }), (HttpStatusCode)422, "not approved yet");
            Expect.Error(await priya.Post("api/v1/jobs/" + jobId + "/approve", new { }), HttpStatusCode.Forbidden, "forbidden");
            Expect.Status(await anita.Post("api/v1/jobs/" + jobId + "/approve", new { comments = "ok" }), HttpStatusCode.NoContent);
            int postingId = (int)Expect.Status(await priya.Post("api/v1/jobs/" + jobId + "/publish", new { }), HttpStatusCode.OK).Json["jobPostingId"];
            var detail = Expect.Status(await priya.Get("api/v1/jobs/" + jobId), HttpStatusCode.OK);
            Assert.AreEqual(2, ((JArray)detail.Json["skills"]).Count);

            // 3. a new candidate finds the job and applies once
            var cand = await Fresh.Candidate("hire");
            var pub = Expect.Status(await cand.Get("api/v1/public/jobs?q=" + Uri.EscapeDataString(title)), HttpStatusCode.OK);
            Assert.AreEqual(1, (int)pub.Json["total"]);
            int appId = (int)Expect.Status(await cand.Post("api/v1/applications", new { jobPostingId = postingId, coverNote = "Keen" }), HttpStatusCode.Created).Json["applicationId"];
            Expect.Error(await cand.Post("api/v1/applications", new { jobPostingId = postingId }), HttpStatusCode.Conflict, "conflict");

            // 4. shortlist -> interview with an internal panel
            Expect.Status(await priya.Post("api/v1/applications/" + appId + "/shortlist", new { reason = "Strong CV" }), HttpStatusCode.NoContent);
            var starts = DateTime.UtcNow.AddDays(2);
            int ivId = (int)Expect.Status(await priya.Post("api/v1/interviews", new
            {
                jobApplicationId = appId, roundNo = 1, interviewType = "Technical", startsAt = starts, endsAt = starts.AddHours(1), mode = "Video",
                locationOrLink = "https://meet.example/abc", panel = new[] { vikramId, priyaId }
            }), HttpStatusCode.Created).Json["interviewId"];
            Assert.AreEqual("Interview", Db.Scalar<string>("SELECT Status FROM cand.JobApplications WHERE ApplicationId = @a", new SqlParameter("@a", appId)));
            Assert.AreEqual(vikramId, Db.Scalar<int>("SELECT UserId FROM cand.InterviewPanels WHERE InterviewId = @i AND IsLead = 1", new SqlParameter("@i", ivId)), "the first listed panel member leads (Vikram has the higher user id)");
            Expect.Error(await priya.Post("api/v1/interviews", new { jobApplicationId = appId, roundNo = 2, interviewType = "HR", startsAt = starts.AddDays(1), endsAt = starts.AddDays(1).AddHours(1), panel = new[] { priyaId }, leadUserId = vikramId }), HttpStatusCode.BadRequest, "validation");
            Expect.Error(await vikram.Post("api/v1/interviews/" + ivId + "/feedback", new { rating = 4, recommendation = "Yes" }), (HttpStatusCode)422, "business_rule");
            Expect.Error(await anita.Post("api/v1/interviews/" + ivId + "/feedback", new { rating = 4, recommendation = "Yes" }), HttpStatusCode.NotFound, "not_found");   // not on the panel

            // the interview "takes place" (only the clock is moved)
            Db.Exec("UPDATE cand.Interviews SET StartsAt = DATEADD(HOUR, -3, SYSUTCDATETIME()), EndsAt = DATEADD(HOUR, -2, SYSUTCDATETIME()) WHERE InterviewId = @i", new SqlParameter("@i", ivId));
            Expect.Status(await vikram.Post("api/v1/interviews/" + ivId + "/feedback", new { rating = 5, recommendation = "StrongYes", strengths = "Design" }), HttpStatusCode.NoContent);
            Expect.Error(await vikram.Post("api/v1/interviews/" + ivId + "/feedback", new { rating = 5, recommendation = "StrongYes" }), HttpStatusCode.Conflict, "conflict");
            Expect.Status(await priya.Post("api/v1/interviews/" + ivId + "/feedback", new { rating = 4, recommendation = "Yes" }), HttpStatusCode.NoContent);
            var ivStaff = Expect.Status(await priya.Get("api/v1/interviews/" + ivId), HttpStatusCode.OK);
            Assert.AreEqual("Completed", (string)ivStaff.Json["interview"]["status"]);
            Assert.AreEqual(2, ((JArray)ivStaff.Json["feedback"]).Count);
            var ivCand = Expect.Status(await cand.Get("api/v1/interviews/" + ivId), HttpStatusCode.OK);
            Assert.AreEqual(0, ((JArray)ivCand.Json["feedback"]).Count, "candidates never see panel feedback");

            // 5. selection and offer with approval; HR approves (not the creator), recruiter sends
            Expect.Status(await priya.Post("api/v1/applications/" + appId + "/status", new { newStatus = "Selected", reason = "Panel recommends" }), HttpStatusCode.OK);
            var offer = Expect.Status(await priya.Post("api/v1/offers", new
            {
                applicationId = appId, designation = "Software Engineer", offeredSalary = 1500000, startDate = Dates.Today.AddDays(30), expiresAt = DateTime.UtcNow.AddDays(7)
            }), HttpStatusCode.Created);
            int offerId = (int)offer.Json["offerId"];
            Expect.Error(await priya.Post("api/v1/offers", new { applicationId = appId, designation = "Dup", offeredSalary = 1, startDate = Dates.Today.AddDays(30), expiresAt = DateTime.UtcNow.AddDays(7) }), HttpStatusCode.Conflict, "conflict");
            Expect.Error(await priya.Post("api/v1/offers/" + offerId + "/approve", new { }), HttpStatusCode.Forbidden, "forbidden");
            Expect.Error(await cand.Post("api/v1/offers/" + offerId + "/accept", new { }), (HttpStatusCode)422, "business_rule");   // not sent yet
            Expect.Status(await anita.Post("api/v1/offers/" + offerId + "/approve", new { comments = "within band" }), HttpStatusCode.NoContent);
            Expect.Status(await priya.Post("api/v1/offers/" + offerId + "/send"), HttpStatusCode.NoContent);
            var other = await Api.As("rohan.gupta@candidate.example");
            Expect.Error(await other.Post("api/v1/offers/" + offerId + "/accept", new { }), HttpStatusCode.NotFound, "not_found");
            var mine = (JArray)Expect.Status(await cand.Get("api/v1/offers/mine"), HttpStatusCode.OK).Json;
            Assert.IsTrue(mine.Any(o => (int)o["offerId"] == offerId && (string)o["status"] == "Sent"));

            // 6. acceptance creates the employee and onboarding in one transaction
            var acc = Expect.Status(await cand.Post("api/v1/offers/" + offerId + "/accept", new { note = "Delighted" }), HttpStatusCode.OK);
            Assert.AreEqual("Accepted", (string)acc.Json["result"]);
            int empId = (int)acc.Json["employeeId"];
            var emp = Expect.Status(await anita.Get("api/v1/employees/" + empId), HttpStatusCode.OK);
            Assert.AreEqual("Onboarding", (string)emp.Json["employee"]["status"]);
            var tasks = (JArray)emp.Json["onboarding"];
            Assert.AreEqual(7, tasks.Count);
            JToken last = null;
            foreach (var t in tasks)
                last = Expect.Status(await anita.Post("api/v1/employees/" + empId + "/onboarding/" + (int)t["onboardingId"] + "/complete", new { notes = "done" }), HttpStatusCode.OK).Json;
            Assert.AreEqual("Active", (string)last["employeeStatus"]);
            Expect.Error(await anita.Post("api/v1/employees/" + empId + "/onboarding/" + (int)tasks[0]["onboardingId"] + "/complete", new { }), (HttpStatusCode)422, "business_rule");

            // 7. the stored trail
            var p = new Func<SqlParameter>(() => new SqlParameter("@j", jobId));
            Assert.AreEqual("Filled", Db.Scalar<string>("SELECT Status FROM rec.JobRequisitions WHERE JobRequisitionId = @j", p()));
            Assert.AreEqual("Closed", Db.Scalar<string>("SELECT Status FROM rec.JobPostings WHERE JobRequisitionId = @j", p()));
            Assert.AreEqual("Hired", Db.Scalar<string>("SELECT Status FROM cand.JobApplications WHERE ApplicationId = @a", new SqlParameter("@a", appId)));
            Assert.IsTrue(Db.Scalar<int>("SELECT COUNT(*) FROM cand.ApplicationStatusHistory WHERE ApplicationId = @a", new SqlParameter("@a", appId)) >= 5, "Applied, Screening, Shortlisted, Interview, Selected, Hired");
            Assert.AreEqual(1, Db.Scalar<int>("SELECT COUNT(*) FROM hr.EmploymentHistory WHERE EmployeeId = @e AND EventType = 'Hired'", new SqlParameter("@e", empId)));
            Assert.IsTrue(Db.Scalar<int>("SELECT COUNT(*) FROM notify.NotificationQueue WHERE RelatedEntityType = 'Interview' AND RelatedEntityId = @i", new SqlParameter("@i", ivId)) >= 1, "invitation queued");
            // Phase 9 (KI-028): the invitation states the time in IST, and the candidate receives it by e-mail
            var invite = Db.Scalar<string>("SELECT TOP 1 Subject FROM notify.NotificationQueue WHERE RelatedEntityType = 'Interview' AND RelatedEntityId = @i ORDER BY NotificationId", new SqlParameter("@i", ivId));
            StringAssert.EndsWith(invite, " IST", invite); Assert.IsFalse(invite.Contains("UTC"), invite);
            Mail.Deliver();
            var inviteMail = Mail.All().LastOrDefault(e => e.Template == "INTERVIEW_INVITE" && e.Text != null && e.Text.Contains(invite));
            Assert.IsNotNull(inviteMail, "invitation e-mail delivered: " + invite);
            StringAssert.Contains(inviteMail.Text, "Mode: ");
            Assert.IsTrue(Db.Scalar<int>("SELECT COUNT(*) FROM audit.AuditLogs WHERE TableName = 'cand.JobOffers' AND RecordId = CAST(@o AS NVARCHAR(50))", new SqlParameter("@o", offerId)) >= 3, "offer changes audited with the acting user");
            Assert.AreEqual(Db.UserId("anita.kapoor@tams.local"), Db.Scalar<int>("SELECT TOP 1 ApproverUserId FROM cand.OfferApprovals WHERE OfferId = @o", new SqlParameter("@o", offerId)));
        }
    }

    [TestClass]
    public class StaffingWorkflowTests
    {
        [TestMethod]
        public async Task Customer_request_to_paid_invoice()
        {
            var kabir = await Api.As("kabir.malhotra@crestline.example");   // Crestline customer
            var arjun = await Api.As("arjun.shah@apexlogistics.example");   // Apex customer (the outsider)
            var rahul = await Api.As("rahul.desai@tams.local");             // Recruiter
            int crest = Db.CustomerId("CREST");

            // 1. the customer raises a request for their own company (customerId taken from the login)
            var req = Expect.Status(await kabir.Post("api/v1/staffing/requests", new
            {
                title = "Data Engineer (API test)", description = "Pipelines", positions = 1, skillsRequired = "Python, SQL", durationMonths = 6, maxBillRate = 1500, workLocation = "Remote"
            }), HttpStatusCode.Created);
            int reqId = (int)req.Json["customerRequisitionId"];
            Assert.AreEqual(crest, Db.Scalar<int>("SELECT CustomerId FROM staff.CustomerRequisitions WHERE CustomerRequisitionId = @r", new SqlParameter("@r", reqId)));
            Expect.Error(await arjun.Get("api/v1/staffing/requests/" + reqId + "/submissions"), HttpStatusCode.NotFound, "not_found");

            // 2. recruiter accepts and submits a candidate from the shared master
            Expect.Status(await rahul.Post("api/v1/staffing/requests/" + reqId + "/accept", new { }), HttpStatusCode.NoContent);
            var cand = await Fresh.Candidate("ctr");
            int candidateId = (int)cand.User["candidateId"];
            Expect.Error(await rahul.Post("api/v1/staffing/requests/" + reqId + "/submissions", new { candidateId, proposedBillRate = 1600 }), (HttpStatusCode)422, "business_rule");   // above max
            int subId = (int)Expect.Status(await rahul.Post("api/v1/staffing/requests/" + reqId + "/submissions", new { candidateId, proposedBillRate = 1450, notes = "5y Python" }), HttpStatusCode.Created).Json["submissionId"];
            Expect.Error(await rahul.Post("api/v1/staffing/requests/" + reqId + "/submissions", new { candidateId, proposedBillRate = 1450 }), HttpStatusCode.Conflict, "conflict");

            // contact details are hidden from the customer until shortlisting
            var subs = (JArray)Expect.Status(await kabir.Get("api/v1/staffing/requests/" + reqId + "/submissions"), HttpStatusCode.OK).Json;
            Assert.AreEqual(JTokenType.Null, subs.Single()["email"].Type);
            Expect.Error(await arjun.Post("api/v1/staffing/submissions/" + subId + "/decision", new { decision = "Shortlist" }), HttpStatusCode.NotFound, "not_found");
            Expect.Status(await kabir.Post("api/v1/staffing/submissions/" + subId + "/decision", new { decision = "Shortlist", comments = "Looks good" }), HttpStatusCode.NoContent);
            subs = (JArray)Expect.Status(await kabir.Get("api/v1/staffing/requests/" + reqId + "/submissions"), HttpStatusCode.OK).Json;
            Assert.AreNotEqual(JTokenType.Null, subs.Single()["email"].Type);

            // 3. the customer interviews with their own panel; another customer cannot
            var starts = DateTime.UtcNow.AddDays(1);
            int kabirId = Db.UserId("kabir.malhotra@crestline.example"), rahulId = Db.UserId("rahul.desai@tams.local");
            var ivBody = new { submittedCandidateId = subId, roundNo = 1, interviewType = "Customer", startsAt = starts, endsAt = starts.AddHours(1), mode = "Video", panel = new[] { kabirId, rahulId } };
            Expect.Error(await arjun.Post("api/v1/interviews", ivBody), HttpStatusCode.NotFound, "not_found");
            Expect.Error(await kabir.Post("api/v1/interviews", new { submittedCandidateId = subId, roundNo = 1, interviewType = "Customer", startsAt = starts, endsAt = starts.AddHours(1), mode = "Video", panel = new[] { Db.UserId("arjun.shah@apexlogistics.example") } }), HttpStatusCode.BadRequest, "validation");
            int ivId = (int)Expect.Status(await kabir.Post("api/v1/interviews", ivBody), HttpStatusCode.Created).Json["interviewId"];
            Expect.Error(await arjun.Get("api/v1/interviews/" + ivId), HttpStatusCode.NotFound, "not_found");
            Expect.Status(await kabir.Post("api/v1/staffing/submissions/" + subId + "/decision", new { decision = "Select", comments = "Hire" }), HttpStatusCode.NoContent);

            // 4. contract: bill below pay refused; created with separate pay and bill rates
            var start = Dates.Monday(2);
            Expect.Error(await rahul.Post("api/v1/contracts", new { submissionId = subId, startDate = start, endDate = start.AddMonths(6), payRate = 1600, billRate = 1450, roleTitle = "Data Engineer" }), (HttpStatusCode)422, "business_rule");
            Expect.Error(await rahul.Post("api/v1/contracts", new { submissionId = subId, startDate = start, endDate = start.AddMonths(6), payRate = 1100, billRate = 1501, roleTitle = "Data Engineer" }), (HttpStatusCode)422, "business_rule");   // above customer max
            Assert.AreEqual(0, Db.Scalar<int>("SELECT COUNT(*) FROM staff.Contractors WHERE CandidateId = @c", new SqlParameter("@c", candidateId)), "failed contract left no contractor behind");
            var k = Expect.Status(await rahul.Post("api/v1/contracts", new { submissionId = subId, startDate = start, endDate = start.AddMonths(6), payRate = 1100, billRate = 1450, roleTitle = "Data Engineer", siteLocation = "Remote", hoursPerWeek = 40 }), HttpStatusCode.Created);
            int contractId = (int)k.Json["contractId"];
            Assert.AreEqual("Filled", Db.Scalar<string>("SELECT Status FROM staff.CustomerRequisitions WHERE CustomerRequisitionId = @r", new SqlParameter("@r", reqId)));

            // the candidate's own login now has the Contractor role; rates are shown to each party correctly
            Expect.Status(await cand.Get("api/v1/contracts"), HttpStatusCode.OK, "the candidate's EXISTING token can use the new Contractor role");
            var ctr = await Api.As((string)cand.User["email"]);
            CollectionAssert.Contains(ctr.User["roles"].Select(r => (string)r).ToList(), "Contractor");
            var ctrView = Expect.Status(await ctr.Get("api/v1/contracts/" + contractId), HttpStatusCode.OK).Json["rates"][0];
            Assert.AreEqual(1100m, (decimal)ctrView["payRate"]); Assert.AreEqual(JTokenType.Null, ctrView["billRate"].Type);
            var custView = Expect.Status(await kabir.Get("api/v1/contracts/" + contractId), HttpStatusCode.OK).Json["rates"][0];
            Assert.AreEqual(1450m, (decimal)custView["billRate"]); Assert.AreEqual(JTokenType.Null, custView["payRate"].Type);
            Expect.Error(await arjun.Get("api/v1/contracts/" + contractId), HttpStatusCode.NotFound, "not_found");

            // 5. timesheets: week 1 approved straight away; week 2 rejected (reason required) then fixed and approved
            Func<DateTime, object> week = m => new { weekStartDate = m, entries = Enumerable.Range(0, 5).Select(d => new { workDate = m.AddDays(d), hours = 8, entryType = "Regular", isBillable = true }).ToArray() };
            Expect.Error(await ctr.Put("api/v1/timesheets/entries", new { weekStartDate = Dates.Monday(0).AddDays(7), entries = new object[0] }), (HttpStatusCode)422, "business_rule");   // future week
            int ts1 = (int)Expect.Status(await ctr.Put("api/v1/timesheets/entries", week(Dates.Monday(2))), HttpStatusCode.OK).Json["timesheetId"];
            Expect.Status(await ctr.Post("api/v1/timesheets/" + ts1 + "/submit"), HttpStatusCode.NoContent);
            Expect.Error(await arjun.Post("api/v1/timesheets/" + ts1 + "/approve", new { }), HttpStatusCode.NotFound, "not_found");
            Expect.Status(await kabir.Post("api/v1/timesheets/" + ts1 + "/approve", new { comments = "ok" }), HttpStatusCode.NoContent);
            Expect.Error(await ctr.Put("api/v1/timesheets/entries", week(Dates.Monday(2))), (HttpStatusCode)422, "business_rule");   // approved = locked

            var w2 = (JObject)JObject.FromObject(week(Dates.Monday(1)));
            w2["entries"][4]["hours"] = 12;
            int ts2 = (int)Expect.Status(await ctr.Put("api/v1/timesheets/entries", w2), HttpStatusCode.OK).Json["timesheetId"];
            Expect.Status(await ctr.Post("api/v1/timesheets/" + ts2 + "/submit"), HttpStatusCode.NoContent);
            Expect.Status(await kabir.Post("api/v1/timesheets/" + ts2 + "/reject", new { }), HttpStatusCode.BadRequest);
            Expect.Status(await kabir.Post("api/v1/timesheets/" + ts2 + "/reject", new { reason = "Friday should be 8 hours" }), HttpStatusCode.NoContent);
            Expect.Status(await ctr.Put("api/v1/timesheets/entries", week(Dates.Monday(1))), HttpStatusCode.OK);
            Expect.Status(await ctr.Post("api/v1/timesheets/" + ts2 + "/submit"), HttpStatusCode.NoContent);
            Expect.Status(await kabir.Post("api/v1/timesheets/" + ts2 + "/approve", new { }), HttpStatusCode.NoContent);
            var tsView = Expect.Status(await kabir.Get("api/v1/timesheets/" + ts2), HttpStatusCode.OK);
            Assert.IsTrue(((JArray)tsView.Json["decisions"]).Count >= 2, "rejection and approval recorded");

            // 6. invoice from approved hours at the BILL rate: 80 h x 1,450 = 116,000 + 18% tax 20,880 = 136,880
            var period = new { customerId = crest, periodStart = Dates.Monday(2), periodEnd = Dates.Monday(1).AddDays(6), taxRate = 18 };
            var inv = Expect.Status(await rahul.Post("api/v1/invoices/generate", period), HttpStatusCode.Created).Json;
            int invId = (int)inv["invoiceId"];
            Assert.AreEqual(116000m, (decimal)inv["subtotal"]); Assert.AreEqual(20880m, (decimal)inv["taxAmount"]); Assert.AreEqual(136880m, (decimal)inv["total"]);
            Assert.AreEqual("Draft", (string)inv["status"]);
            int invoicesBefore = Db.Scalar<int>("SELECT COUNT(*) FROM bill.Invoices");
            Expect.Error(await rahul.Post("api/v1/invoices/generate", period), (HttpStatusCode)422, "business_rule");   // hours cannot be billed twice
            Assert.AreEqual(invoicesBefore, Db.Scalar<int>("SELECT COUNT(*) FROM bill.Invoices"), "failed generation left nothing behind");
            Expect.Error(await arjun.Get("api/v1/invoices/" + invId), HttpStatusCode.NotFound, "not_found");
            Expect.Error(await rahul.Post("api/v1/invoices/" + invId + "/payments", new { amount = 1000, paidOn = Dates.Today }), (HttpStatusCode)422, "business_rule");   // Draft
            Expect.Status(await rahul.Post("api/v1/invoices/" + invId + "/issue"), HttpStatusCode.NoContent);
            var kv = Expect.Status(await kabir.Get("api/v1/invoices/" + invId), HttpStatusCode.OK).Json;
            Assert.AreEqual(10, ((JArray)kv["lines"]).Count);
            Assert.IsTrue(((JArray)kv["lines"]).All(l => (decimal)l["billRate"] == 1450m), "invoice uses the bill rate, never the pay rate");

            // 7. payments: partial, overpayment refused, settle
            var p1 = Expect.Status(await rahul.Post("api/v1/invoices/" + invId + "/payments", new { amount = 36880, paidOn = Dates.Today, method = "BankTransfer", reference = "CREST-1" }), HttpStatusCode.Created).Json;
            Assert.AreEqual("PartiallyPaid", (string)p1["status"]); Assert.AreEqual(100000m, (decimal)p1["balance"]);
            Expect.Error(await rahul.Post("api/v1/invoices/" + invId + "/payments", new { amount = 100000.01, paidOn = Dates.Today }), (HttpStatusCode)422, "business_rule");
            Expect.Error(await rahul.Post("api/v1/invoices/" + invId + "/payments", new { amount = 10, paidOn = Dates.Today.AddDays(2) }), (HttpStatusCode)400, "validation");   // future date
            var p2 = Expect.Status(await rahul.Post("api/v1/invoices/" + invId + "/payments", new { amount = 100000, paidOn = Dates.Today, method = "Cheque", reference = "CREST-2" }), HttpStatusCode.Created).Json;
            Assert.AreEqual("Paid", (string)p2["status"]); Assert.AreEqual(0m, (decimal)p2["balance"]);
            Expect.Error(await rahul.Post("api/v1/invoices/" + invId + "/void", new { reason = "too late" }), (HttpStatusCode)422, "business_rule");
            var bal = Expect.Status(await kabir.Get("api/v1/customers/" + crest + "/balance"), HttpStatusCode.OK).Json;
            Assert.AreEqual(Db.Scalar<decimal>("SELECT bill.fn_CustomerOutstandingBalance(@c)", new SqlParameter("@c", crest)), (decimal)bal["outstandingBalance"]);
        }
    }
}
