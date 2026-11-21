using System;
using System.Data.SqlClient;
using System.Linq;
using System.Net;
using System.Text;
using System.Threading.Tasks;
using Microsoft.VisualStudio.TestTools.UnitTesting;
using Newtonsoft.Json.Linq;

namespace TalentAcquisition.Tests
{
    /// <summary>Phase 10: the 19 reports over HTTP - catalog per role, results that match the database, customer isolation,
    /// pay-rate secrecy, validation and the CSV export.</summary>
    [TestClass]
    public class ReportTests
    {
        private static readonly string[] Staffing = { "staffing-requests", "submissions", "placements", "active-contractors", "expiring-contracts", "pending-timesheets", "customer-invoices", "outstanding-payments" };

        private static string[] Codes(Resp r) { return r.Json.Select(x => (string)x["reportCode"]).ToArray(); }

        [TestMethod]
        public async Task Each_role_gets_its_own_report_catalog_and_candidates_and_contractors_get_none()
        {
            var admin = await Api.As("admin@tams.local");
            var all = Codes(Expect.Status(await admin.Get("api/v1/reports"), HttpStatusCode.OK));
            Assert.AreEqual(19, all.Length, string.Join(",", all));
            var recruiter = Codes(Expect.Status(await (await Api.As("priya.menon@tams.local")).Get("api/v1/reports"), HttpStatusCode.OK));
            var hr = Codes(Expect.Status(await (await Api.As("anita.kapoor@tams.local")).Get("api/v1/reports"), HttpStatusCode.OK));
            var customer = Expect.Status(await (await Api.As("arjun.shah@apexlogistics.example")).Get("api/v1/reports"), HttpStatusCode.OK);
            Assert.AreEqual(16, recruiter.Length); Assert.IsFalse(recruiter.Contains("onboarding"));
            Assert.AreEqual(11, hr.Length); Assert.IsFalse(hr.Contains("placements"));
            CollectionAssert.AreEquivalent(Staffing, Codes(customer));
            Assert.IsTrue(customer.Json.All(x => !(bool)x["canFilterCustomer"]), "a customer cannot pick a customer");
            Expect.Status(await (await Api.As("divya.reddy@candidate.example")).Get("api/v1/reports"), HttpStatusCode.Forbidden);
            Expect.Status(await (await Api.As("ravi.kumar@contractor.example")).Get("api/v1/reports/placements"), HttpStatusCode.Forbidden);
        }

        [TestMethod]
        public async Task All_nineteen_reports_run_with_labelled_typed_columns()
        {
            var admin = await Api.As("admin@tams.local");
            foreach (var code in Codes(await admin.Get("api/v1/reports")))
            {
                var r = Expect.Status(await admin.Get("api/v1/reports/" + code), HttpStatusCode.OK, code);
                var cols = (JArray)r.Json["columns"];
                Assert.IsTrue(cols.Count >= 3, code);
                Assert.IsTrue(cols.All(c => !string.IsNullOrEmpty((string)c["label"]) && !string.IsNullOrEmpty((string)c["type"])), code);
                Assert.AreEqual(((JArray)r.Json["rows"]).Count, (int)r.Json["rowCount"], code);
                Assert.AreEqual(code, (string)r.Json["report"]["reportCode"]);
            }
            var abs = await admin.Get("api/v1/reports/applications-by-status");
            Assert.AreEqual("percent", (string)abs.Json["columns"].Single(c => (string)c["key"] == "sharePct")["type"]);
            Assert.AreEqual("Share %", (string)abs.Json["columns"].Single(c => (string)c["key"] == "sharePct")["label"]);
            var outst = await admin.Get("api/v1/reports/outstanding-payments");
            Assert.AreEqual("Overdue 1 to 30 days", (string)outst.Json["columns"].Single(c => (string)c["key"] == "overdue1To30Days")["label"]);
            Assert.AreEqual("money", (string)outst.Json["columns"].Single(c => (string)c["key"] == "outstanding")["type"]);
        }

        [TestMethod]
        public async Task Report_figures_match_the_database()
        {
            var admin = await Api.As("admin@tams.local");
            var abs = await admin.Get("api/v1/reports/applications-by-status");
            Assert.AreEqual(Db.Scalar<int>("SELECT COUNT(*) FROM cand.JobApplications"), abs.Json["rows"].Sum(x => (int)x["applications"]));
            Assert.AreEqual(Db.Scalar<int>("SELECT COUNT(*) FROM cand.JobApplications WHERE Status = 'Hired'"), (int)abs.Json["rows"].Single(x => (string)x["status"] == "Hired")["applications"]);

            var outst = await admin.Get("api/v1/reports/outstanding-payments");
            foreach (var row in outst.Json["rows"])
            {
                var expected = Db.Scalar<decimal>("SELECT bill.fn_CustomerOutstandingBalance(CustomerId) FROM org.Customers WHERE Name = @n", new SqlParameter("@n", (string)row["customer"]));
                Assert.AreEqual(expected, (decimal)row["outstanding"], (string)row["customer"]);
            }
            var pts = await admin.Get("api/v1/reports/pending-timesheets");
            Assert.AreEqual(Db.Scalar<int>("SELECT COUNT(*) FROM [time].Timesheets WHERE Status = 'Submitted'"), (int)pts.Json["rowCount"]);

            // the date range: nothing before the first application, everything from it on
            var first = Db.Scalar<DateTime>("SELECT MIN(AppliedAt) FROM cand.JobApplications").Date;
            var before = await admin.Get("api/v1/reports/applications-by-status?to=" + first.AddDays(-1).ToString("yyyy-MM-dd"));
            Assert.AreEqual(0, before.Json["rows"].Sum(x => (int)x["applications"]));
            var from = await admin.Get("api/v1/reports/applications-by-status?from=" + first.ToString("yyyy-MM-dd") + "&to=" + DateTime.UtcNow.AddDays(1).ToString("yyyy-MM-dd"));
            Assert.AreEqual(Db.Scalar<int>("SELECT COUNT(*) FROM cand.JobApplications"), from.Json["rows"].Sum(x => (int)x["applications"]));
        }

        [TestMethod]
        public async Task A_customer_sees_only_its_own_company_in_every_staffing_report_and_never_pay_rates()
        {
            var arjun = await Api.As("arjun.shah@apexlogistics.example");
            string apexName = Db.Scalar<string>("SELECT Name FROM org.Customers WHERE CustomerCode = 'APEX'");
            int bright = Db.CustomerId("BRIGHT"), apex = Db.CustomerId("APEX");
            foreach (var code in Staffing)
            {
                var r = Expect.Status(await arjun.Get("api/v1/reports/" + code), HttpStatusCode.OK, code);
                if (((JArray)r.Json["columns"]).Any(c => (string)c["key"] == "customer"))
                    Assert.IsTrue(r.Json["rows"].All(x => (string)x["customer"] == apexName), code + ": " + r.Body);
                Assert.IsFalse(r.Body.IndexOf("payRate", StringComparison.OrdinalIgnoreCase) >= 0 || r.Body.IndexOf("marginPct", StringComparison.OrdinalIgnoreCase) >= 0, code + " exposes pay");
                // a manipulated customer id is refused, the own id works
                Expect.Error(await arjun.Get("api/v1/reports/" + code + "?customerId=" + bright), HttpStatusCode.NotFound, "not_found");
                Expect.Status(await arjun.Get("api/v1/reports/" + code + "?customerId=" + apex), HttpStatusCode.OK, code);
            }
            var csv = await arjun.Send(System.Net.Http.HttpMethod.Get, "api/v1/reports/placements/csv", null);
            Assert.IsFalse(csv.Body.Contains("Pay rate") || csv.Body.Contains("Margin"), "no pay in the export either");

            var rahul = await Api.As("rahul.desai@tams.local");
            var staff = await rahul.Get("api/v1/reports/placements");
            CollectionAssert.IsSubsetOf(new[] { "payRate", "billRate", "marginPct" }, staff.Json["columns"].Select(c => (string)c["key"]).ToArray());
            var filtered = await rahul.Get("api/v1/reports/submissions?customerId=" + bright);
            Assert.AreEqual(Db.Scalar<int>("SELECT COUNT(*) FROM staff.SubmittedCandidates WHERE CustomerId = @c", new SqlParameter("@c", bright)), (int)filtered.Json["rowCount"]);
        }

        [TestMethod]
        public async Task Roles_codes_and_parameters_are_checked()
        {
            var arjun = await Api.As("arjun.shah@apexlogistics.example");
            var anita = await Api.As("anita.kapoor@tams.local");
            var admin = await Api.As("admin@tams.local");
            Expect.Error(await arjun.Get("api/v1/reports/pipeline"), HttpStatusCode.Forbidden, "forbidden");
            Expect.Error(await anita.Get("api/v1/reports/placements"), HttpStatusCode.Forbidden, "forbidden");
            Expect.Error(await admin.Get("api/v1/reports/no-such-report"), HttpStatusCode.NotFound, "not_found");
            Expect.Status(await admin.Get("api/v1/reports/Pipeline%3BDROP"), HttpStatusCode.NotFound);
            Expect.Error(await admin.Get("api/v1/reports/pipeline?from=2026-02-01&to=2026-01-01"), HttpStatusCode.BadRequest, "validation");
            Expect.Error(await admin.Get("api/v1/reports/expiring-contracts?days=0"), HttpStatusCode.BadRequest, "validation");
            Expect.Status(await admin.Get("api/v1/reports/pipeline?from=not-a-date"), HttpStatusCode.BadRequest);
            Expect.Error(await admin.Get("api/v1/reports/submissions?customerId=999999"), HttpStatusCode.NotFound, "not_found");
            var exp = await admin.Get("api/v1/reports/expiring-contracts?days=365");
            Assert.AreEqual(365, (int)exp.Json["days"]);
            Assert.IsTrue(exp.Json["rows"].All(x => (int)x["daysToExpiry"] <= 365));
        }

        [TestMethod]
        public async Task The_csv_export_is_a_safe_download_that_matches_the_report()
        {
            // a customer types a title that a spreadsheet would run as a formula
            var kabir = await Api.As("kabir.malhotra@crestline.example");
            var title = "=HYPERLINK(\"http://evil.example\",\"Click\")";
            Expect.Status(await kabir.Post("api/v1/staffing/requests", new { title, description = "csv test", positions = 1, durationMonths = 3, maxBillRate = 1000, workLocation = "Remote" }), HttpStatusCode.Created);

            var admin = await Api.As("admin@tams.local");
            var json = await admin.Get("api/v1/reports/staffing-requests");
            var r = await admin.Send(System.Net.Http.HttpMethod.Get, "api/v1/reports/staffing-requests/csv", null);
            Assert.AreEqual(HttpStatusCode.OK, r.Status);
            Assert.AreEqual("text/csv", r.Raw.Content.Headers.ContentType.MediaType);
            Assert.AreEqual("attachment", r.Raw.Content.Headers.ContentDisposition.DispositionType);
            StringAssert.StartsWith(r.Raw.Content.Headers.ContentDisposition.FileName.Trim('"'), "tams-staffing-requests-");
            var bytes = await r.Raw.Content.ReadAsByteArrayAsync();
            Assert.IsTrue(bytes.Length > 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF, "UTF-8 BOM");
            var text = Encoding.UTF8.GetString(bytes, 3, bytes.Length - 3);
            var lines = text.Split(new[] { "\r\n" }, StringSplitOptions.RemoveEmptyEntries);
            StringAssert.StartsWith(lines[0], "Request no.,Customer,Title,Positions,Status,Created at (UTC)");
            Assert.AreEqual((int)json.Json["rowCount"] + 1, lines.Length, "one line per row plus the header");
            StringAssert.Contains(text, "\"'=HYPERLINK(\"\"http://evil.example\"\",\"\"Click\"\")\"", "the formula is neutralised and quoted");
            Assert.IsFalse(lines.Any(l => l.Contains(",=HYPERLINK") || l.StartsWith("=")), "no cell starts with =");
        }
    }
}
