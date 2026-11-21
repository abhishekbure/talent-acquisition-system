using System.Data.SqlClient;
using System.Linq;
using System.Net;
using System.Threading.Tasks;
using Microsoft.VisualStudio.TestTools.UnitTesting;
using Newtonsoft.Json.Linq;

namespace TalentAcquisition.Tests
{
    /// <summary>Attempts to reach another customer's data with MANIPULATED identifiers. Every one must be refused (404 = "not found", existence not revealed).</summary>
    [TestClass]
    public class CustomerIsolationTests
    {
        private static int Id(string sql, int customerId) { return Db.Scalar<int>(sql, new SqlParameter("@c", customerId)); }

        [TestMethod]
        public async Task A_customer_cannot_read_or_act_on_another_customers_records_by_id()
        {
            var apex = Db.CustomerId("APEX");
            var meera = await Api.As("meera.iyer@brightwave.example");   // Brightwave
            int inv = Id("SELECT TOP 1 InvoiceId FROM bill.Invoices WHERE CustomerId = @c", apex);
            int ts = Id("SELECT TOP 1 TimesheetId FROM [time].Timesheets WHERE CustomerId = @c AND Status = 'Submitted'", apex);
            int ct = Id("SELECT TOP 1 ContractId FROM staff.Contracts WHERE CustomerId = @c", apex);
            int req = Id("SELECT TOP 1 CustomerRequisitionId FROM staff.CustomerRequisitions WHERE CustomerId = @c", apex);
            int sub = Id("SELECT TOP 1 SubmissionId FROM staff.SubmittedCandidates WHERE CustomerId = @c AND Status = 'Submitted'", apex);
            int iv = Id("SELECT TOP 1 InterviewId FROM cand.Interviews WHERE CustomerId = @c", apex);

            Expect.Error(await meera.Get("api/v1/invoices/" + inv), HttpStatusCode.NotFound, "not_found");
            Expect.Error(await meera.Get("api/v1/invoices?customerId=" + apex), HttpStatusCode.NotFound, "not_found");
            Expect.Error(await meera.Get("api/v1/timesheets/" + ts), HttpStatusCode.NotFound, "not_found");
            Expect.Error(await meera.Post("api/v1/timesheets/" + ts + "/approve", new { }), HttpStatusCode.NotFound, "not_found");
            Expect.Error(await meera.Post("api/v1/timesheets/" + ts + "/reject", new { reason = "hostile" }), HttpStatusCode.NotFound, "not_found");
            Expect.Error(await meera.Get("api/v1/contracts/" + ct), HttpStatusCode.NotFound, "not_found");
            Expect.Error(await meera.Get("api/v1/contracts?customerId=" + apex), HttpStatusCode.NotFound, "not_found");
            Expect.Error(await meera.Get("api/v1/staffing/requests/" + req + "/submissions"), HttpStatusCode.NotFound, "not_found");
            Expect.Error(await meera.Get("api/v1/staffing/requests?customerId=" + apex), HttpStatusCode.NotFound, "not_found");
            Expect.Error(await meera.Post("api/v1/staffing/submissions/" + sub + "/decision", new { decision = "Reject", comments = "hostile" }), HttpStatusCode.NotFound, "not_found");
            Expect.Error(await meera.Post("api/v1/staffing/requests/" + req + "/cancel", new { reason = "hostile" }), HttpStatusCode.NotFound, "not_found");
            Expect.Error(await meera.Get("api/v1/interviews/" + iv), HttpStatusCode.NotFound, "not_found");
            Expect.Error(await meera.Get("api/v1/customers/" + apex), HttpStatusCode.NotFound, "not_found");
            Expect.Error(await meera.Get("api/v1/customers/" + apex + "/balance"), HttpStatusCode.NotFound, "not_found");
            Expect.Error(await meera.Post("api/v1/staffing/requests", new { customerId = apex, title = "Forged request" }), HttpStatusCode.NotFound, "not_found");
            Assert.AreEqual(0, Db.Scalar<int>("SELECT COUNT(*) FROM staff.CustomerRequisitions WHERE Title = 'Forged request'"));
            Assert.AreEqual("Submitted", Db.Scalar<string>("SELECT Status FROM staff.SubmittedCandidates WHERE SubmissionId = @s", new SqlParameter("@s", sub)), "nothing changed");
        }

        [TestMethod]
        public async Task Lists_contain_only_the_callers_own_customer()
        {
            var bright = Db.CustomerId("BRIGHT");
            var meera = await Api.As("meera.iyer@brightwave.example");
            foreach (var path in new[] { "api/v1/invoices", "api/v1/contracts", "api/v1/timesheets", "api/v1/staffing/requests", "api/v1/assignments", "api/v1/interviews" })
            {
                var arr = (JArray)Expect.Status(await meera.Get(path), HttpStatusCode.OK).Json;
                Assert.IsTrue(arr.All(x => x["customerId"] == null || x["customerId"].Type == JTokenType.Null || (int)x["customerId"] == bright), path + " leaked another customer's row");
            }
            var customers = (JArray)Expect.Status(await meera.Get("api/v1/customers"), HttpStatusCode.OK).Json;
            Assert.AreEqual(1, customers.Count);
        }

        [TestMethod]
        public async Task Rates_are_visible_only_to_the_right_party()
        {
            var ravi = await Api.As("ravi.kumar@contractor.example");
            var arjun = await Api.As("arjun.shah@apexlogistics.example");
            var c1 = (JArray)Expect.Status(await ravi.Get("api/v1/contracts"), HttpStatusCode.OK).Json;
            var c2 = (JArray)Expect.Status(await arjun.Get("api/v1/contracts"), HttpStatusCode.OK).Json;
            Assert.IsTrue(c1.All(c => c["payRate"].Type != JTokenType.Null && c["billRate"].Type == JTokenType.Null), "contractor: pay only");
            Assert.IsTrue(c2.All(c => c["billRate"].Type != JTokenType.Null && c["payRate"].Type == JTokenType.Null), "customer: bill only");
        }

        [TestMethod]
        public async Task A_contractor_cannot_touch_another_contractors_timesheets()
        {
            var sneha = await Api.As("sneha.pillai@contractor.example");
            int raviTs = Db.Scalar<int>("SELECT TOP 1 t.TimesheetId FROM [time].Timesheets t JOIN staff.Contractors k ON k.ContractorId = t.ContractorId WHERE k.ContractorNo = 'CTR-0001' AND t.Status = 'Draft'");
            Expect.Error(await sneha.Get("api/v1/timesheets/" + raviTs), HttpStatusCode.NotFound, "not_found");
            Expect.Error(await sneha.Post("api/v1/timesheets/" + raviTs + "/submit"), HttpStatusCode.NotFound, "not_found");
        }

        [TestMethod]
        public async Task A_candidate_cannot_read_another_candidates_application_or_offer()
        {
            var rohan = await Api.As("rohan.gupta@candidate.example");
            int app = Db.Scalar<int>("SELECT a.ApplicationId FROM cand.JobApplications a JOIN cand.Candidates c ON c.CandidateId = a.CandidateId WHERE c.EmailNormalized = 'ANANYA.SHARMA@CANDIDATE.EXAMPLE'");
            int offer = Db.Scalar<int>("SELECT OfferId FROM cand.JobOffers WHERE OfferNo LIKE 'OFR-%-002'");
            Expect.Error(await rohan.Get("api/v1/applications/" + app), HttpStatusCode.NotFound, "not_found");
            Expect.Error(await rohan.Post("api/v1/offers/" + offer + "/accept", new { }), HttpStatusCode.NotFound, "not_found");
            Expect.Error(await rohan.Post("api/v1/applications/" + app + "/withdraw", new { }), HttpStatusCode.NotFound, "not_found");
        }
    }

    [TestClass]
    public class ConcurrencyTests
    {
        [TestMethod]
        public async Task Two_simultaneous_payments_cannot_overpay_an_invoice()
        {
            var a = await Api.As("priya.menon@tams.local"); var b = await Api.As("rahul.desai@tams.local");
            int inv = Db.Scalar<int>("SELECT InvoiceId FROM bill.Invoices WHERE InvoiceNo LIKE 'INV-%-0003'");      // Issued, 80,240 unpaid
            var today = Dates.Today.ToString("yyyy-MM-dd");
            var results = await Task.WhenAll(
                a.Post("api/v1/invoices/" + inv + "/payments", new { amount = 50000, paidOn = today, method = "BankTransfer", reference = "C-1" }),
                b.Post("api/v1/invoices/" + inv + "/payments", new { amount = 50000, paidOn = today, method = "BankTransfer", reference = "C-2" }));
            Assert.AreEqual(1, results.Count(r => r.Status == HttpStatusCode.Created), string.Join(" | ", results.Select(r => r.ToString())));
            Assert.AreEqual(1, results.Count(r => (int)r.Status == 422), "the second sees the reduced balance");
            Assert.IsTrue(Db.Scalar<decimal>("SELECT SUM(Amount) FROM bill.Payments WHERE InvoiceId = @i", new SqlParameter("@i", inv)) <= Db.Scalar<decimal>("SELECT Total FROM bill.Invoices WHERE InvoiceId = @i", new SqlParameter("@i", inv)));
        }

        [TestMethod]
        public async Task Two_simultaneous_applications_create_exactly_one()
        {
            var cand = await Fresh.Candidate("race");
            int posting = Db.Scalar<int>("SELECT TOP 1 p.JobPostingId FROM rec.JobPostings p JOIN rec.JobRequisitions jr ON jr.JobRequisitionId = p.JobRequisitionId WHERE p.Status = 'Published' AND jr.Status = 'Open' ORDER BY p.JobPostingId");
            var results = await Task.WhenAll(cand.Post("api/v1/applications", new { jobPostingId = posting }), cand.Post("api/v1/applications", new { jobPostingId = posting }));
            Assert.AreEqual(1, results.Count(r => r.Status == HttpStatusCode.Created), string.Join(" | ", results.Select(r => r.ToString())));
            Assert.AreEqual(1, results.Count(r => r.Status == HttpStatusCode.Conflict));
        }
    }
}
