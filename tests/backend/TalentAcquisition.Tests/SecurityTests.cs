using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Data.SqlClient;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Http;
using Microsoft.VisualStudio.TestTools.UnitTesting;
using Newtonsoft.Json.Linq;
using TalentAcquisition.API;

namespace TalentAcquisition.Tests
{
    /// <summary>One attribute-routed action of the real API, found by reflection (so new endpoints are covered automatically).</summary>
    internal sealed class RouteInfo
    {
        public string Verb; public string Template; public MethodInfo Action;
        public override string ToString() { return Verb + " " + Template; }
    }

    internal static class Routes
    {
        private static readonly Regex Placeholder = new Regex(@"\{(\w+)(?::(\w+))?\}");
        private static List<RouteInfo> _all;

        public static List<RouteInfo> All()
        {
            if (_all != null) return _all;
            var list = new List<RouteInfo>();
            foreach (var t in typeof(Startup).Assembly.GetTypes().Where(x => typeof(ApiController).IsAssignableFrom(x) && !x.IsAbstract))
            {
                var p = t.GetCustomAttribute<RoutePrefixAttribute>(); var prefix = p == null ? "" : p.Prefix;
                foreach (var m in t.GetMethods(BindingFlags.Instance | BindingFlags.Public | BindingFlags.DeclaredOnly))
                    foreach (var r in m.GetCustomAttributes<RouteAttribute>())
                    {
                        string verb = m.GetCustomAttribute<HttpGetAttribute>() != null ? "GET" : m.GetCustomAttribute<HttpPostAttribute>() != null ? "POST"
                                    : m.GetCustomAttribute<HttpPutAttribute>() != null ? "PUT" : m.GetCustomAttribute<HttpDeleteAttribute>() != null ? "DELETE" : null;
                        if (verb == null) continue;
                        var tpl = string.IsNullOrEmpty(r.Template) ? prefix : prefix.Length == 0 ? r.Template : prefix + "/" + r.Template;
                        list.Add(new RouteInfo { Verb = verb, Template = tpl, Action = m });
                    }
            }
            return _all = list;
        }
        public static int Count(string tpl) { return Placeholder.Matches(tpl).Count; }
        public static bool OnlyNumeric(string tpl) { return Placeholder.Matches(tpl).Cast<Match>().All(x => x.Groups[2].Value == "int" || x.Groups[2].Value == "long"); }
        public static string Fill(string tpl, long id) { return Placeholder.Replace(tpl, id.ToString()); }
        /// <summary>GET routes that return JSON about records (no sign-in endpoints, no file downloads/exports).</summary>
        public static IEnumerable<RouteInfo> DataGets()
        {
            return All().Where(r => r.Verb == "GET" && !r.Template.StartsWith("api/v1/auth") && !r.Template.EndsWith("/health") && !r.Template.EndsWith("/download") && !r.Template.EndsWith("/csv"));
        }
    }

    /// <summary>What a given user must never see: other parties' identifying strings, and record ids of other parties.</summary>
    internal sealed class LeakRule
    {
        public string Who; public string[] Markers; public string IdProperty; public long OwnId;
        public string Check(string body)
        {
            foreach (var m in Markers) if (!string.IsNullOrEmpty(m) && body.IndexOf(m, StringComparison.OrdinalIgnoreCase) >= 0) return "contains '" + m + "'";
            if (IdProperty == null) return null;
            JToken j; try { j = JToken.Parse(body); } catch (Newtonsoft.Json.JsonException) { return null; }
            var other = (j is JContainer ? ((JContainer)j).Descendants() : Enumerable.Empty<JToken>()).OfType<JProperty>().FirstOrDefault(p => string.Equals(p.Name, IdProperty, StringComparison.OrdinalIgnoreCase) && p.Value.Type == JTokenType.Integer && (long)p.Value != OwnId);
            return other == null ? null : IdProperty + "=" + other.Value;
        }
    }

    /// <summary>
    /// Phase 13: attempts to reach other parties' data with MANIPULATED identifiers, swept over EVERY JSON GET endpoint of the
    /// API (found by reflection) and every record id in use, as a customer, a candidate and a contractor. Any 200 response must
    /// contain nothing of another customer / candidate / contractor; nothing may answer 500.
    /// </summary>
    [TestClass]
    public class ManipulatedIdentifierTests
    {
        private static long MaxId()
        {
            return Db.Scalar<long>(@"SELECT MAX(v) FROM (VALUES ((SELECT MAX(CandidateId) FROM cand.Candidates)), ((SELECT MAX(ApplicationId) FROM cand.JobApplications)),
                ((SELECT MAX(InterviewId) FROM cand.Interviews)), ((SELECT MAX(OfferId) FROM cand.JobOffers)), ((SELECT MAX(ContractId) FROM staff.Contracts)),
                ((SELECT MAX(ContractorId) FROM staff.Contractors)), ((SELECT MAX(TimesheetId) FROM [time].Timesheets)), ((SELECT MAX(InvoiceId) FROM bill.Invoices)),
                ((SELECT MAX(CustomerRequisitionId) FROM staff.CustomerRequisitions)), ((SELECT MAX(SubmissionId) FROM staff.SubmittedCandidates)),
                ((SELECT MAX(AssignmentId) FROM staff.Assignments)), ((SELECT MAX(JobPostingId) FROM rec.JobPostings)), ((SELECT MAX(DocumentId) FROM doc.Documents)),
                ((SELECT MAX(CustomerId) FROM org.Customers)), ((SELECT MAX(UserId) FROM sec.Users))) AS x(v)");
        }

        private static string[] Strings(string sql, params SqlParameter[] p)
        {
            var list = new List<string>();
            using (var c = new SqlConnection(TestHost.DbConnection)) { c.Open(); using (var cmd = new SqlCommand(sql, c)) { cmd.Parameters.AddRange(p); using (var r = cmd.ExecuteReader()) while (r.Read()) if (!r.IsDBNull(0)) list.Add(r.GetString(0)); } }
            return list.ToArray();
        }

        private static async Task<List<string>> Sweep(Api who, LeakRule rule, long maxId, string listQuery)
        {
            var problems = new ConcurrentBag<string>(); var gate = new SemaphoreSlim(8); var tasks = new List<Task>(); int probes = 0;
            foreach (var r in Routes.DataGets())
            {
                IEnumerable<string> urls;
                if (Routes.Count(r.Template) == 0) urls = new[] { r.Template + listQuery };
                else if (Routes.OnlyNumeric(r.Template)) urls = Enumerable.Range(1, (int)maxId).Select(i => Routes.Fill(r.Template, i));
                else continue;                                            // e.g. dashboards/{role}, reports/{code}: covered by their own tests
                foreach (var url in urls)
                {
                    var u = url; Interlocked.Increment(ref probes);
                    tasks.Add(Task.Run(async () =>
                    {
                        await gate.WaitAsync();
                        try
                        {
                            var res = await who.Get(u);
                            if ((int)res.Status >= 500) problems.Add(rule.Who + " GET " + u + " -> " + res);
                            else if (res.Status == HttpStatusCode.OK) { var why = rule.Check(res.Body); if (why != null) problems.Add(rule.Who + " GET " + u + " leaked: " + why); }
                        }
                        finally { gate.Release(); }
                    }));
                }
            }
            await Task.WhenAll(tasks);
            Assert.IsTrue(probes > 100, "the sweep found too few endpoints (" + probes + ")");
            return problems.ToList();
        }

        [TestMethod]
        public async Task A_customer_never_receives_another_customers_data_whatever_identifiers_it_sends()
        {
            int bright = Db.CustomerId("BRIGHT"), apex = Db.CustomerId("APEX");
            var markers = Strings("SELECT Name FROM org.Customers WHERE CustomerId <> @c", new SqlParameter("@c", bright))
                .Concat(Strings("SELECT DISTINCT SUBSTRING(u.Email, CHARINDEX('@', u.Email), 200) FROM sec.Users u JOIN org.CustomerUsers cu ON cu.UserId = u.UserId WHERE cu.CustomerId <> @c", new SqlParameter("@c", bright)))
                .ToArray();
            Assert.IsTrue(markers.Length >= 4, string.Join(",", markers));
            int otherContractor = Db.Scalar<int>("SELECT TOP 1 ContractorId FROM [time].Timesheets WHERE CustomerId = @c", new SqlParameter("@c", apex));
            var rule = new LeakRule { Who = "customer", Markers = markers, IdProperty = "customerId", OwnId = bright };
            var staff = await Api.As("priya.menon@tams.local");                // self-check: the detector fires on an unrestricted view
            Assert.IsNotNull(rule.Check(Expect.Status(await staff.Get("api/v1/contracts"), HttpStatusCode.OK).Body), "leak detector self-check");
            var meera = await Api.As("meera.iyer@brightwave.example");
            var problems = await Sweep(meera, rule, MaxId(),
                                       "?customerId=" + apex + "&contractorId=" + otherContractor + "&q=a");
            Assert.AreEqual(0, problems.Count, string.Join("\n", problems.Take(25)));
        }

        [TestMethod]
        public async Task A_candidate_never_receives_another_candidates_data()
        {
            int rohanId = Db.Scalar<int>("SELECT CandidateId FROM cand.Candidates WHERE EmailNormalized = 'ROHAN.GUPTA@CANDIDATE.EXAMPLE'");
            var markers = Strings("SELECT Email FROM cand.Candidates WHERE CandidateId <> @c AND Email IS NOT NULL", new SqlParameter("@c", rohanId));
            var rule = new LeakRule { Who = "candidate", Markers = markers, IdProperty = "candidateId", OwnId = rohanId };
            var staff = await Api.As("priya.menon@tams.local");
            Assert.IsNotNull(rule.Check(Expect.Status(await staff.Get("api/v1/candidates?pageSize=200"), HttpStatusCode.OK).Body), "leak detector self-check");
            var rohan = await Api.As("rohan.gupta@candidate.example");
            var problems = await Sweep(rohan, rule, MaxId(), "?candidateId=1&q=a");
            Assert.AreEqual(0, problems.Count, string.Join("\n", problems.Take(25)));
        }

        [TestMethod]
        public async Task A_contractor_never_receives_another_contractors_data()
        {
            int snehaId = Db.Scalar<int>("SELECT k.ContractorId FROM staff.Contractors k JOIN sec.Users u ON u.UserId = k.UserId WHERE u.EmailNormalized = 'SNEHA.PILLAI@CONTRACTOR.EXAMPLE'");
            var markers = Strings("SELECT u.Email FROM staff.Contractors k JOIN sec.Users u ON u.UserId = k.UserId WHERE k.ContractorId <> @k", new SqlParameter("@k", snehaId));
            Assert.IsTrue(markers.Length >= 1);
            var rule = new LeakRule { Who = "contractor", Markers = markers, IdProperty = "contractorId", OwnId = snehaId };
            var staff = await Api.As("priya.menon@tams.local");
            Assert.IsNotNull(rule.Check(Expect.Status(await staff.Get("api/v1/timesheets"), HttpStatusCode.OK).Body), "leak detector self-check");
            var sneha = await Api.As("sneha.pillai@contractor.example");
            var problems = await Sweep(sneha, rule, MaxId(), "?contractorId=1&q=a");
            Assert.AreEqual(0, problems.Count, string.Join("\n", problems.Take(25)));
        }

        [TestMethod]
        public async Task Reports_ignore_a_customer_filter_pointing_at_another_customer()
        {
            int bright = Db.CustomerId("BRIGHT"), apex = Db.CustomerId("APEX");
            var apexName = Db.Scalar<string>("SELECT Name FROM org.Customers WHERE CustomerId = @c", new SqlParameter("@c", apex));
            var meera = await Api.As("meera.iyer@brightwave.example");
            var list = (JArray)Expect.Status(await meera.Get("api/v1/reports"), HttpStatusCode.OK).Json;
            Assert.IsTrue(list.Count > 0);
            foreach (var code in list.Select(r => (string)r["reportCode"]))
            {
                var r = await meera.Get("api/v1/reports/" + code + "?customerId=" + apex);
                Expect.Error(r, HttpStatusCode.NotFound, "not_found");                     // another customer's id is refused outright
                var csv = await meera.Get("api/v1/reports/" + code + "/csv?customerId=" + apex);
                Expect.Error(csv, HttpStatusCode.NotFound, "not_found");
                var own = Expect.Status(await meera.Get("api/v1/reports/" + code), HttpStatusCode.OK, code);
                StringAssert.DoesNotMatch(own.Body, new Regex(Regex.Escape(apexName)), code + " leaked the other customer");
            }
            // refused runs are not audited; a run that returned data is, with its filter and format (Phase 13, KI-043)
            int meeraId = Db.UserId("meera.iyer@brightwave.example");
            Assert.AreEqual(0, Db.Scalar<int>("SELECT COUNT(*) FROM audit.ReportRuns WHERE ActorUserId = @u AND CustomerId = @c", new SqlParameter("@u", meeraId), new SqlParameter("@c", apex)));
            var first = (string)list[0]["reportCode"];
            Expect.Status(await meera.Get("api/v1/reports/" + first + "/csv?customerId=" + bright), HttpStatusCode.OK);
            Assert.IsTrue(Db.Scalar<int>("SELECT COUNT(*) FROM audit.ReportRuns WHERE ActorUserId = @u AND ReportCode = @r AND CustomerId = @c AND OutputFormat = 'csv'",
                new SqlParameter("@u", meeraId), new SqlParameter("@r", first), new SqlParameter("@c", bright)) >= 1);
        }

        [TestMethod]
        public async Task Writes_with_another_customers_identifiers_change_nothing()
        {
            int apex = Db.CustomerId("APEX");
            var meera = await Api.As("meera.iyer@brightwave.example");
            int contract = Db.Scalar<int>("SELECT TOP 1 ContractId FROM staff.Contracts WHERE CustomerId = @c ORDER BY ContractId DESC", new SqlParameter("@c", apex));
            int invoice = Db.Scalar<int>("SELECT TOP 1 InvoiceId FROM bill.Invoices WHERE CustomerId = @c ORDER BY InvoiceId DESC", new SqlParameter("@c", apex));
            var before = Db.Scalar<int>("SELECT CHECKSUM_AGG(CHECKSUM(*)) FROM staff.Contracts WHERE CustomerId = @c", new SqlParameter("@c", apex));
            var auditBefore = Db.Scalar<long>("SELECT ISNULL(MAX(AuditId), 0) FROM audit.AuditLogs");
            foreach (var r in Routes.All().Where(x => x.Verb != "GET" && Routes.Count(x.Template) > 0 && Routes.OnlyNumeric(x.Template)
                                                      && (x.Template.StartsWith("api/v1/contracts") || x.Template.StartsWith("api/v1/invoices"))))
            {
                var id = r.Template.StartsWith("api/v1/contracts") ? contract : invoice;
                var res = await meera.Send(new HttpMethod(r.Verb), Routes.Fill(r.Template, id), new { reason = "hostile", amount = 1, paidOn = Dates.Today, decision = "Approve" });
                Assert.IsTrue(res.Status == HttpStatusCode.NotFound || res.Status == HttpStatusCode.Forbidden || res.Status == HttpStatusCode.BadRequest, r + " -> " + res);
            }
            Assert.AreEqual(before, Db.Scalar<int>("SELECT CHECKSUM_AGG(CHECKSUM(*)) FROM staff.Contracts WHERE CustomerId = @c", new SqlParameter("@c", apex)), "contracts unchanged");
            Assert.AreEqual(0, Db.Scalar<int>("SELECT COUNT(*) FROM audit.AuditLogs WHERE AuditId > @a AND ChangedByUserId = @u",
                new SqlParameter("@a", auditBefore), new SqlParameter("@u", Db.UserId("meera.iyer@brightwave.example"))), "no audited change by the hostile customer");
        }
    }

    /// <summary>Phase 13: token handling beyond the Phase 4 tests, using the real signing key of the test host to forge tokens
    /// whose ONLY defect is the one under test.</summary>
    [TestClass]
    public class TokenSecurityTests
    {
        private static string B64(byte[] b) { return Convert.ToBase64String(b).TrimEnd('=').Replace('+', '-').Replace('/', '_'); }
        private static byte[] UnB64(string s) { s = s.Replace('-', '+').Replace('_', '/'); return Convert.FromBase64String(s + new string('=', (4 - s.Length % 4) % 4)); }
        private static string Resign(string token, Action<JObject> change)
        {
            var parts = token.Split('.');
            var payload = JObject.Parse(Encoding.UTF8.GetString(UnB64(parts[1])));
            change(payload);
            var data = parts[0] + "." + B64(Encoding.UTF8.GetBytes(payload.ToString(Newtonsoft.Json.Formatting.None)));
            using (var h = new HMACSHA256(Encoding.UTF8.GetBytes(TestHost.Settings.JwtSecret))) return data + "." + B64(h.ComputeHash(Encoding.ASCII.GetBytes(data)));
        }
        private static long Now() { return DateTimeOffset.UtcNow.ToUnixTimeSeconds(); }

        [TestMethod]
        public async Task Expired_wrong_audience_and_future_tokens_are_rejected_even_with_a_valid_signature()
        {
            var a = await Api.As("rohan.gupta@candidate.example");
            Expect.Status(await new Api { Token = Resign(a.Token, p => { }) }.Get("api/v1/auth/me"), HttpStatusCode.OK, "control: re-signing an unchanged token works");
            Expect.Error(await new Api { Token = Resign(a.Token, p => { p["exp"] = Now() - 5; }) }.Get("api/v1/auth/me"), HttpStatusCode.Unauthorized, "unauthenticated");
            Expect.Error(await new Api { Token = Resign(a.Token, p => { p["aud"] = "SomeOtherApp"; }) }.Get("api/v1/auth/me"), HttpStatusCode.Unauthorized, "unauthenticated");
            Expect.Error(await new Api { Token = Resign(a.Token, p => { p["iss"] = "evil"; }) }.Get("api/v1/auth/me"), HttpStatusCode.Unauthorized, "unauthenticated");
            Expect.Error(await new Api { Token = Resign(a.Token, p => { p["nbf"] = Now() + 3600; }) }.Get("api/v1/auth/me"), HttpStatusCode.Unauthorized, "unauthenticated");
            Expect.Error(await new Api { Token = Resign(a.Token, p => { p["jti"] = Guid.NewGuid().ToString(); }) }.Get("api/v1/auth/me"), HttpStatusCode.Unauthorized, "unauthenticated");
        }

        [TestMethod]
        public async Task Roles_in_a_validly_signed_token_grant_nothing_and_another_users_id_is_refused()
        {
            var rohan = await Api.As("rohan.gupta@candidate.example");
            // even with the signing key compromised, roles come from the database, and the token id is bound to its user
            var asAdmin = new Api { Token = Resign(rohan.Token, p => { p["roles"] = new JArray("Administrator"); }) };
            Expect.Error(await asAdmin.Get("api/v1/users"), HttpStatusCode.Forbidden, "forbidden");
            var otherUser = new Api { Token = Resign(rohan.Token, p => { p["sub"] = Db.UserId("admin@tams.local").ToString(); }) };
            Expect.Error(await otherUser.Get("api/v1/users"), HttpStatusCode.Unauthorized, "unauthenticated");
        }
    }

    [TestClass]
    public class PasswordStorageTests
    {
        [TestMethod]
        public async Task Passwords_are_unique_salted_PBKDF2_hashes_that_never_leave_the_database()
        {
            var e1 = "pw1." + Guid.NewGuid().ToString("N").Substring(0, 8) + "@candidate.example";
            var e2 = "pw2." + Guid.NewGuid().ToString("N").Substring(0, 8) + "@candidate.example";
            foreach (var e in new[] { e1, e2 })
                Expect.Status(await Api.Anonymous().Post("api/v1/auth/register", new { email = e, password = TestHost.Password, firstName = "Pw", lastName = "Test" }), HttpStatusCode.Created);
            var p1 = new SqlParameter("@a", e1); var p2 = new SqlParameter("@b", e2);
            Assert.AreEqual(2, Db.Scalar<int>(@"SELECT COUNT(*) FROM sec.Users WHERE EmailNormalized IN (UPPER(@a), UPPER(@b))
                AND DATALENGTH(PasswordHash) = 32 AND DATALENGTH(PasswordSalt) = 32 AND HashIterations >= 210000", p1, p2), "32-byte PBKDF2-SHA256 hash, 32-byte salt, 210,000 iterations");
            Assert.AreEqual(2, Db.Scalar<int>("SELECT COUNT(DISTINCT PasswordSalt) + 0 * COUNT(*) FROM sec.Users WHERE EmailNormalized IN (UPPER(@a), UPPER(@b))", new SqlParameter("@a", e1), new SqlParameter("@b", e2)), "a fresh salt per account");
            Assert.AreEqual(2, Db.Scalar<int>("SELECT COUNT(DISTINCT PasswordHash) FROM sec.Users WHERE EmailNormalized IN (UPPER(@a), UPPER(@b))", new SqlParameter("@a", e1), new SqlParameter("@b", e2)), "same password, different hashes");
            Assert.AreEqual(0, Db.Scalar<int>(@"SELECT COUNT(*) FROM sys.columns c JOIN sys.types t ON t.user_type_id = c.user_type_id
                WHERE c.name LIKE '%password%' AND t.name IN ('char', 'varchar', 'nchar', 'nvarchar', 'text', 'ntext') AND OBJECTPROPERTY(c.object_id, 'IsUserTable') = 1"), "no text column can hold a password");

            var admin = await Api.As("admin@tams.local");
            var bodies = new List<string> { (await Api.Anonymous().Post("api/v1/auth/login", new { email = "admin@tams.local", password = TestHost.Password })).Body,
                                            (await admin.Get("api/v1/auth/me")).Body, (await admin.Get("api/v1/users?pageSize=200")).Body,
                                            (await admin.Get("api/v1/users/" + Db.UserId("priya.menon@tams.local"))).Body };
            foreach (var b in bodies)
            {
                var names = ((JContainer)JToken.Parse(b)).Descendants().OfType<JProperty>().Select(p => p.Name.ToLowerInvariant()).ToList();
                Assert.IsFalse(names.Any(n => n.Contains("hash") || n.Contains("salt") || n.Contains("password")), "password material in a response: " + b.Substring(0, Math.Min(300, b.Length)));
            }
        }
    }

    /// <summary>Phase 13 (KI-022, KI-034): per-client rate limits on the anonymous account endpoints and the cap on bodies sent
    /// without a length. The limits are proved on a second real API host with small limits.</summary>
    [TestClass]
    public class AbuseLimitTests
    {
        [TestMethod]
        public void The_limiter_counts_per_client_and_endpoint_group_and_resets_each_minute()
        {
            var clock = new DateTime(2026, 11, 20, 10, 0, 15, DateTimeKind.Utc);
            var l = new RateLimiter(() => clock);
            Assert.AreEqual(0, l.Hit("login", "1.1.1.1", 2)); Assert.AreEqual(0, l.Hit("login", "1.1.1.1", 2));
            Assert.AreEqual(45, l.Hit("login", "1.1.1.1", 2), "third request in the minute: wait until the minute ends");
            Assert.AreEqual(0, l.Hit("login", "2.2.2.2", 2), "another client has its own budget");
            Assert.AreEqual(0, l.Hit("account", "1.1.1.1", 2), "another endpoint group has its own budget");
            Assert.AreEqual(0, l.Hit("login", "1.1.1.1", 0), "0 = no limit");
            clock = clock.AddMinutes(1);
            Assert.AreEqual(0, l.Hit("login", "1.1.1.1", 2), "a new minute starts afresh");
            Assert.AreEqual(1, l.TrackedClients, "clients of earlier minutes are forgotten");
        }

        [TestMethod]
        public async Task A_client_exceeding_the_limits_gets_429_with_Retry_After_and_a_spoofed_forwarded_address_does_not_help()
        {
            using (TestHost.StartAnother(5061, s => { s.RateLimitLoginPerMinute = 3; s.RateLimitAccountPerMinute = 2; s.RateLimitTokenPerMinute = 2; }))
            {
                var api = Api.At("http://localhost:5061/");
                // if the minute ends during the test the window restarts, so wait for a fresh minute when close to the end
                if (DateTime.UtcNow.Second > 45) await Task.Delay(TimeSpan.FromSeconds(61 - DateTime.UtcNow.Second));
                for (int i = 0; i < 3; i++)
                    Expect.Error(await api.Post("api/v1/auth/login", new { email = "nobody.rate@tams.local", password = "Wrong#Pass12345" }), HttpStatusCode.Unauthorized, "invalid_credentials");
                var limited = Expect.Error(await api.Post("api/v1/auth/login", new { email = "admin@tams.local", password = TestHost.Password }), (HttpStatusCode)429, "rate_limited");
                Assert.IsTrue(limited.Raw.Headers.RetryAfter != null && limited.Raw.Headers.RetryAfter.Delta.Value.TotalSeconds >= 1, "Retry-After says when to come back");
                var spoof = new HttpRequestMessage(HttpMethod.Post, api.UrlOf("api/v1/auth/login")) { Content = new StringContent("{\"email\":\"admin@tams.local\",\"password\":\"x\"}", Encoding.UTF8, "application/json") };
                spoof.Headers.Add("X-Forwarded-For", "203.0.113.7");
                Expect.Error(await api.Send(spoof), (HttpStatusCode)429, "rate_limited");

                Expect.Status(await api.Post("api/v1/auth/forgot-password", new { email = "nobody.rate@tams.local" }), HttpStatusCode.Accepted);
                Expect.Status(await api.Post("api/v1/auth/forgot-password", new { email = "nobody.rate@tams.local" }), HttpStatusCode.Accepted);
                Expect.Error(await api.Post("api/v1/auth/register", new { email = "rate@candidate.example", password = TestHost.Password, firstName = "R", lastName = "L" }), (HttpStatusCode)429, "rate_limited");
                Expect.Error(await api.Post("api/v1/auth/verify-email", new { token = "a" }), (HttpStatusCode)422, "business_rule");
                Expect.Error(await api.Post("api/v1/auth/reset-password", new { token = "b", newPassword = TestHost.Password }), (HttpStatusCode)422, "business_rule");
                Expect.Error(await api.Post("api/v1/auth/verify-email", new { token = "c" }), (HttpStatusCode)429, "rate_limited");
                Expect.Status(await api.Get("api/v1/health"), HttpStatusCode.OK, "other endpoints are not limited");
                Assert.AreEqual(0, Db.Scalar<int>("SELECT COUNT(*) FROM sec.Users WHERE EmailNormalized = 'RATE@CANDIDATE.EXAMPLE'"), "the limited registration did nothing");
            }
            Expect.Status(await Api.Anonymous().Post("api/v1/auth/login", new { email = "admin@tams.local", password = TestHost.Password }), HttpStatusCode.OK, "limits are per API process (main host unaffected)");
        }

        private sealed class UnknownLengthStream : System.IO.MemoryStream
        {
            public UnknownLengthStream(byte[] b) : base(b) { }
            public override bool CanSeek { get { return false; } }
        }
        private static HttpRequestMessage Chunked(Api api, string path, string json)
        {
            var c = new StreamContent(new UnknownLengthStream(Encoding.UTF8.GetBytes(json)));
            c.Headers.ContentType = new System.Net.Http.Headers.MediaTypeHeaderValue("application/json") { CharSet = "utf-8" };
            var req = new HttpRequestMessage(HttpMethod.Post, api.UrlOf(path)) { Content = c };
            req.Headers.TransferEncodingChunked = true;
            return req;
        }

        [TestMethod]
        public async Task Bodies_sent_without_a_length_are_capped_and_small_ones_still_work()
        {
            var cand = await Api.As("rohan.gupta@candidate.example");
            var big = "{\"jobPostingId\":1,\"coverNote\":\"" + new string('x', 200 * 1024) + "\"}";
            Expect.Error(await cand.Send(Chunked(cand, "api/v1/applications", big)), (HttpStatusCode)413, "too_large");
            var ok = await Api.Anonymous().Send(Chunked(Api.Anonymous(), "api/v1/auth/login", "{\"email\":\"rohan.gupta@candidate.example\",\"password\":\"" + TestHost.Password + "\"}"));
            Expect.Status(ok, HttpStatusCode.OK, "a small chunked body is read normally");
            Assert.IsFalse(string.IsNullOrEmpty((string)ok.Json["token"]));
        }
    }

    [TestClass]
    public class InputValidationAndErrorTests
    {
        [TestMethod]
        public async Task Every_endpoint_rejects_a_body_of_the_wrong_shape_with_400_or_403_and_never_500()
        {
            var users = new[] { "admin@tams.local", "priya.menon@tams.local", "vikram.nair@tams.local", "arjun.shah@apexlogistics.example", "ravi.kumar@contractor.example", "rohan.gupta@candidate.example" };
            var apis = new List<Tuple<string, Api>>(); foreach (var u in users) apis.Add(Tuple.Create(u, await Api.As(u)));
            var problems = new List<string>(); int probes = 0;
            foreach (var r in Routes.All().Where(x => x.Verb == "POST" || x.Verb == "PUT"))
            {
                var body = r.Action.GetParameters().FirstOrDefault(p => p.GetCustomAttribute<FromBodyAttribute>() != null);
                if (body == null) continue;                               // no JSON body: nothing to mis-shape (and the call would act)
                bool collection = body.ParameterType != typeof(string) && typeof(System.Collections.IEnumerable).IsAssignableFrom(body.ParameterType);
                foreach (var raw in new[] { collection ? "{\"a\":1}" : "[1,2,3]", "\"just a string\"", "{ \"broken\": " })
                    foreach (var api in apis)
                    {
                        probes++;
                        var res = await api.Item2.Send(new HttpMethod(r.Verb), Routes.Fill(r.Template, 1), null, raw);
                        if (res.Status != HttpStatusCode.BadRequest && res.Status != HttpStatusCode.Forbidden) problems.Add(r + " as " + api.Item1 + " body " + raw + " -> " + res);
                    }
            }
            Assert.IsTrue(probes > 200, "too few probes: " + probes);
            Assert.AreEqual(0, problems.Count, string.Join("\n", problems.Take(25)));
        }

        [TestMethod]
        public async Task Overlong_values_bad_numbers_and_bad_dates_are_400_or_404_never_500()
        {
            var rec = await Api.As("priya.menon@tams.local");
            Expect.Error(await rec.Post("api/v1/candidates", new { firstName = new string('A', 5000), lastName = "Long", email = "long." + Guid.NewGuid().ToString("N").Substring(0, 6) + "@candidate.example" }), HttpStatusCode.BadRequest, "validation");
            Expect.Error(await Api.Anonymous().Post("api/v1/auth/register", new { email = "long." + Guid.NewGuid().ToString("N").Substring(0, 6) + "@candidate.example", password = TestHost.Password, firstName = new string('B', 300), lastName = "X" }), HttpStatusCode.BadRequest, "validation");
            Expect.Error(await Api.Anonymous().Post("api/v1/auth/login", new { email = new string('c', 5000) + "@x.example", password = "x" }), HttpStatusCode.BadRequest, "validation");
            Expect.Error(await rec.Get("api/v1/jobs/0"), HttpStatusCode.NotFound, "not_found");
            Expect.Error(await rec.Get("api/v1/jobs/-5"), HttpStatusCode.NotFound, "not_found");
            Expect.Error(await rec.Get("api/v1/jobs/99999999999"), HttpStatusCode.NotFound, "not_found");       // larger than INT: no route
            Expect.Error(await rec.Get("api/v1/jobs/1;DROP TABLE x"), HttpStatusCode.NotFound, "not_found");
            Expect.Error(await rec.Get("api/v1/reports/pipeline?from=not-a-date"), HttpStatusCode.BadRequest, "validation");
            var page = Expect.Status(await rec.Get("api/v1/candidates?page=-3&pageSize=1000000"), HttpStatusCode.OK).Json;
            Assert.IsTrue(((JArray)page["items"]).Count <= 200, "page size is bounded");
            foreach (var path in Routes.DataGets().Where(r => Routes.Count(r.Template) == 0).Select(r => r.Template))
            {
                var res = await rec.Get(path + "?q=" + Uri.EscapeDataString("' OR '1'='1' --") + "&status=" + Uri.EscapeDataString("x'; DROP TABLE cand.Candidates; --"));
                Assert.IsTrue((int)res.Status < 500, path + " -> " + res);
            }
            Assert.IsTrue(Db.Scalar<int>("SELECT COUNT(*) FROM cand.Candidates") > 0, "injection strings were data");
        }

        [TestMethod]
        public async Task Unknown_addresses_wrong_methods_and_wrong_content_types_get_the_standard_error_shape()
        {
            var rec = await Api.As("priya.menon@tams.local");
            var r1 = Expect.Error(await rec.Get("api/v1/no-such-thing"), HttpStatusCode.NotFound, "not_found");
            var r2 = Expect.Error(await rec.Send(HttpMethod.Delete, "api/v1/health", null), HttpStatusCode.MethodNotAllowed, "method_not_allowed");
            var xml = new HttpRequestMessage(HttpMethod.Post, rec.UrlOf("api/v1/candidates")) { Content = new StringContent("<candidate/>", Encoding.UTF8, "application/xml") };
            var r3 = Expect.Error(await rec.Send(xml), HttpStatusCode.UnsupportedMediaType, "unsupported_media_type");
            foreach (var r in new[] { r1, r2, r3 })
            {
                Assert.IsNotNull(r.Json["correlationId"]);
                StringAssert.DoesNotMatch(r.Body, new Regex("Controller|System\\.|StackTrace|MessageDetail", RegexOptions.IgnoreCase), "framework internals: " + r.Body);
            }
        }

        [TestMethod]
        public async Task An_unreachable_database_gives_503_without_internal_details()
        {
            using (TestHost.StartAnother(5062, s => { s.ConnectionString = "Server=localhost;Database=TAMS_Does_Not_Exist_" + Guid.NewGuid().ToString("N").Substring(0, 6) + ";Integrated Security=SSPI;TrustServerCertificate=True;Connect Timeout=5"; }))
            {
                var api = Api.At("http://localhost:5062/");
                var h = Expect.Status(await api.Get("api/v1/health"), HttpStatusCode.ServiceUnavailable);
                Assert.AreEqual("database_unreachable", (string)h.Json["status"]);
                var login = Expect.Error(await api.Post("api/v1/auth/login", new { email = "admin@tams.local", password = TestHost.Password }), HttpStatusCode.ServiceUnavailable, "unavailable");
                StringAssert.DoesNotMatch(login.Body, new Regex("TAMS_Does_Not_Exist|SqlException|Cannot open database|login failed", RegexOptions.IgnoreCase));
            }
        }
    }

    /// <summary>Phase 13: concurrent operations keep the data consistent (one winner, invariants hold, nothing half-done).</summary>
    [TestClass]
    public class ConcurrencyAndIntegrityTests
    {
        [TestMethod]
        public async Task Two_simultaneous_approvals_of_one_timesheet_record_exactly_one_decision()
        {
            int bright = Db.CustomerId("BRIGHT");
            int ts = Db.Scalar<int>("SELECT TOP 1 TimesheetId FROM [time].Timesheets WHERE CustomerId = @c AND Status = 'Submitted' ORDER BY TimesheetId DESC", new SqlParameter("@c", bright));
            Assert.IsTrue(ts > 0, "seed has a submitted Brightwave timesheet");
            var a = await Api.As("meera.iyer@brightwave.example"); var b = await Api.As("meera.iyer@brightwave.example");
            var results = await Task.WhenAll(a.Post("api/v1/timesheets/" + ts + "/approve", new { }), b.Post("api/v1/timesheets/" + ts + "/approve", new { }));
            Assert.AreEqual(1, results.Count(r => r.Status == HttpStatusCode.NoContent), string.Join(" | ", results.Select(r => r.ToString())));
            Assert.AreEqual(1, results.Count(r => (int)r.Status == 409 || (int)r.Status == 422), string.Join(" | ", results.Select(r => r.ToString())));
            Assert.AreEqual("Approved", Db.Scalar<string>("SELECT Status FROM [time].Timesheets WHERE TimesheetId = @t", new SqlParameter("@t", ts)));
            Assert.AreEqual(1, Db.Scalar<int>("SELECT COUNT(*) FROM [time].TimesheetApprovals WHERE TimesheetId = @t", new SqlParameter("@t", ts)), "one decision recorded");
        }

        [TestMethod]
        public async Task Two_simultaneous_invoice_runs_for_the_same_hours_create_one_consistent_invoice()
        {
            int bright = Db.CustomerId("BRIGHT");
            var week = Db.Scalar<DateTime>("SELECT TOP 1 WeekStartDate FROM [time].Timesheets WHERE CustomerId = @c AND Status = 'Approved' ORDER BY WeekStartDate", new SqlParameter("@c", bright));
            Assert.AreNotEqual(default(DateTime), week, "seed has approved, uninvoiced Brightwave hours");
            var period = new { customerId = bright, periodStart = week.ToString("yyyy-MM-dd"), periodEnd = week.AddDays(6).ToString("yyyy-MM-dd"), taxRate = 18 };
            int before = Db.Scalar<int>("SELECT COUNT(*) FROM bill.Invoices WHERE CustomerId = @c", new SqlParameter("@c", bright));
            var p = await Api.As("priya.menon@tams.local"); var r = await Api.As("rahul.desai@tams.local");
            var results = await Task.WhenAll(p.Post("api/v1/invoices/generate", period), r.Post("api/v1/invoices/generate", period));
            Assert.AreEqual(1, results.Count(x => x.Status == HttpStatusCode.Created), string.Join(" | ", results.Select(x => x.ToString())));
            Assert.AreEqual(1, results.Count(x => (int)x.Status == 409 || (int)x.Status == 422), string.Join(" | ", results.Select(x => x.ToString())));
            Assert.AreEqual(before + 1, Db.Scalar<int>("SELECT COUNT(*) FROM bill.Invoices WHERE CustomerId = @c", new SqlParameter("@c", bright)), "exactly one invoice");
            int inv = (int)results.Single(x => x.Status == HttpStatusCode.Created).Json["invoiceId"];
            Assert.AreEqual(0, Db.Scalar<int>(@"SELECT COUNT(*) FROM bill.Invoices i WHERE i.InvoiceId = @i
                AND (i.Subtotal <> (SELECT SUM(LineTotal) FROM bill.InvoiceLines WHERE InvoiceId = i.InvoiceId) OR i.Total <> i.Subtotal + i.TaxAmount)", new SqlParameter("@i", inv)), "totals match the lines");
            // a timesheet counts as invoiced once its billable entries are on an invoice line (its status stays Approved)
            Assert.AreEqual(0, Db.Scalar<int>(@"SELECT COUNT(*) FROM [time].Timesheets t WHERE t.CustomerId = @c AND t.WeekStartDate = @w AND t.Status = 'Approved'
                AND EXISTS (SELECT 1 FROM [time].TimesheetEntries e WHERE e.TimesheetId = t.TimesheetId AND e.IsBillable = 1
                            AND NOT EXISTS (SELECT 1 FROM bill.InvoiceLines l WHERE l.TimesheetEntryId = e.EntryId))", new SqlParameter("@c", bright), new SqlParameter("@w", week)), "every billable hour of the week is invoiced");
            Assert.AreEqual(0, Db.Scalar<int>("SELECT COUNT(*) FROM (SELECT TimesheetEntryId FROM bill.InvoiceLines GROUP BY TimesheetEntryId HAVING COUNT(*) > 1) d"), "no hour is billed twice");
        }
    }
}
