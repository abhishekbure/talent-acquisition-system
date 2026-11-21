using System;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Threading.Tasks;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace TalentAcquisition.Tests
{
    [TestClass]
    public class AuthenticationTests
    {
        [TestMethod]
        public async Task Login_returns_a_token_roles_and_linked_profile()
        {
            var a = await Api.As("arjun.shah@apexlogistics.example");
            Assert.IsFalse(string.IsNullOrEmpty(a.Token));
            Assert.AreEqual("Customer", (string)a.User["roles"][0]);
            Assert.AreEqual(Db.CustomerId("APEX"), (int)a.User["customerId"]);
            var me = Expect.Status(await a.Get("api/v1/auth/me"), HttpStatusCode.OK);
            Assert.IsTrue(me.Json["permissions"].Select(p => (string)p).Contains("timesheet.approve"), "permissions come from the database");
        }

        [TestMethod]
        public async Task Wrong_password_and_unknown_email_get_the_same_generic_401()
        {
            var bad = await Api.Anonymous().Post("api/v1/auth/login", new { email = "priya.menon@tams.local", password = "Wrong#Pass12345" });
            var unknown = await Api.Anonymous().Post("api/v1/auth/login", new { email = "nobody.at.all@tams.local", password = "Wrong#Pass12345" });
            Expect.Error(bad, HttpStatusCode.Unauthorized, "invalid_credentials");
            Expect.Error(unknown, HttpStatusCode.Unauthorized, "invalid_credentials");
            Assert.AreEqual((string)bad.Json["message"], (string)unknown.Json["message"], "no account enumeration");
            Assert.IsTrue(Db.Scalar<int>("SELECT COUNT(*) FROM audit.LoginHistory WHERE Email = 'nobody.at.all@tams.local' AND Success = 0") >= 1, "failed attempts are audited");
        }

        [TestMethod]
        public async Task Five_failures_lock_the_account_even_for_the_right_password()
        {
            const string email = "karan.joshi@candidate.example";
            for (int i = 0; i < 5; i++) await Api.Anonymous().Post("api/v1/auth/login", new { email, password = "Wrong#Pass12345" });
            Expect.Error(await Api.Anonymous().Post("api/v1/auth/login", new { email, password = TestHost.Password }), (HttpStatusCode)429, "locked");
            Db.Exec("UPDATE sec.Users SET FailedLoginCount = 0, LockoutUntil = NULL WHERE EmailNormalized = 'KARAN.JOSHI@CANDIDATE.EXAMPLE'");   // reset for other tests
        }

        [TestMethod]
        public async Task Logout_revokes_the_token_immediately()
        {
            var a = await Api.As("anita.kapoor@tams.local");
            Expect.Status(await a.Get("api/v1/auth/me"), HttpStatusCode.OK);
            Expect.Status(await a.Post("api/v1/auth/logout"), HttpStatusCode.NoContent);
            Expect.Error(await a.Get("api/v1/auth/me"), HttpStatusCode.Unauthorized, "unauthenticated");
        }

        [TestMethod]
        public async Task Tampered_and_garbage_tokens_are_rejected()
        {
            var a = await Api.As("vikram.nair@tams.local");
            var parts = a.Token.Split('.');
            var forgedPayload = Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes("{\"sub\":\"1\",\"roles\":[\"Administrator\"]}")).TrimEnd('=').Replace('+', '-').Replace('/', '_');
            Expect.Status(await new Api { Token = parts[0] + "." + forgedPayload + "." + parts[2] }.Get("api/v1/users"), HttpStatusCode.Unauthorized, "payload swapped => signature fails");
            Expect.Status(await new Api { Token = "eyJhbGciOiJub25lIn0." + parts[1] + "." }.Get("api/v1/auth/me"), HttpStatusCode.Unauthorized, "alg=none rejected");
            Expect.Status(await new Api { Token = "garbage" }.Get("api/v1/auth/me"), HttpStatusCode.Unauthorized);
        }

        [TestMethod]
        public async Task Registration_needs_the_emailed_confirmation_before_sign_in_and_duplicates_and_weak_passwords_are_refused()
        {
            var email = "reg." + Guid.NewGuid().ToString("N").Substring(0, 8) + "@candidate.example";
            var r = Expect.Status(await Api.Anonymous().Post("api/v1/auth/register", new { email, password = TestHost.Password, firstName = "Reg", lastName = "Test" }), HttpStatusCode.Created);
            Assert.IsTrue((bool)r.Json["verificationRequired"]);
            Assert.IsNull(r.Json["candidateId"], "the response says nothing about candidate records");
            // right password, unconfirmed address: refused, logged, not counted towards lockout
            for (int i = 0; i < 6; i++) Expect.Error(await Api.Anonymous().Post("api/v1/auth/login", new { email, password = TestHost.Password }), HttpStatusCode.Forbidden, "email_unverified");
            Assert.AreEqual(0, Db.Scalar<int>("SELECT FailedLoginCount FROM sec.Users WHERE EmailNormalized = UPPER(@e)", new System.Data.SqlClient.SqlParameter("@e", email)));
            // a wrong password still says nothing about the address
            Expect.Error(await Api.Anonymous().Post("api/v1/auth/login", new { email, password = "Wrong#Pass12345" }), HttpStatusCode.Unauthorized, "invalid_credentials");
            // a used / invented link is refused
            Expect.Error(await Api.Anonymous().Post("api/v1/auth/verify-email", new { token = "invented-token" }), (HttpStatusCode)422, "business_rule");
            await Mail.VerifyThroughEmail(email);
            var link = Mail.Latest(email, "EMAIL_VERIFY");
            StringAssert.Contains(link.Text, "http://localhost:4200/verify-email?token=");
            Expect.Error(await Api.Anonymous().Post("api/v1/auth/verify-email", new { token = link.Token }), (HttpStatusCode)422, "business_rule");
            Assert.IsFalse(Db.Scalar<string>("SELECT Body FROM notify.NotificationQueue WHERE NotificationId = @i", new System.Data.SqlClient.SqlParameter("@i", link.NotificationId)).Contains("token="),
                "the link is erased from the queue once delivered");
            var a = await Api.As(email);
            Assert.AreEqual("Candidate", (string)a.User["roles"][0]);
            Expect.Error(await Api.Anonymous().Post("api/v1/auth/register", new { email = email.ToUpperInvariant(), password = TestHost.Password, firstName = "Dup", lastName = "Dup" }), HttpStatusCode.Conflict, "conflict");
            Expect.Error(await Api.Anonymous().Post("api/v1/auth/register", new { email = "weak." + email, password = "password", firstName = "W", lastName = "P" }), HttpStatusCode.BadRequest, "weak_password");
            Expect.Status(await Api.Anonymous().Post("api/v1/auth/register", new { email = "bad-email", password = TestHost.Password, firstName = "B", lastName = "E" }), HttpStatusCode.BadRequest);
            Assert.AreEqual(0, Db.Scalar<int>("SELECT COUNT(*) FROM sec.Users WHERE DATALENGTH(PasswordHash) <> 32 AND EmailNormalized = UPPER(@e)", new System.Data.SqlClient.SqlParameter("@e", email)), "stored as a 32-byte PBKDF2 hash, never plaintext");
        }

        [TestMethod]
        public async Task Forgot_password_always_answers_202_and_queues_a_reset_mail_only_for_real_accounts()
        {
            var before = Db.Scalar<int>("SELECT COUNT(*) FROM notify.NotificationQueue WHERE TemplateCode = 'PASSWORD_RESET'");
            Expect.Status(await Api.Anonymous().Post("api/v1/auth/forgot-password", new { email = "no.such.user@tams.local" }), HttpStatusCode.Accepted);
            Expect.Status(await Api.Anonymous().Post("api/v1/auth/forgot-password", new { email = "neha.verma@apexlogistics.example" }), HttpStatusCode.Accepted);
            Assert.AreEqual(before + 1, Db.Scalar<int>("SELECT COUNT(*) FROM notify.NotificationQueue WHERE TemplateCode = 'PASSWORD_RESET'"));
            Expect.Error(await Api.Anonymous().Post("api/v1/auth/reset-password", new { token = "not-a-real-token", newPassword = TestHost.Password }), (HttpStatusCode)422, "business_rule");
        }

        [TestMethod]
        public async Task Password_reset_link_works_once_and_the_new_password_logs_in()
        {
            const string email = "kabir.malhotra@crestline.example";
            Expect.Status(await Api.Anonymous().Post("api/v1/auth/forgot-password", new { email }), HttpStatusCode.Accepted);
            Mail.Deliver();                                         // the person reads the e-mail
            var mail = Mail.Latest(email, "PASSWORD_RESET");
            Assert.IsNotNull(mail, "reset e-mail delivered");
            var token = mail.Token;
            Assert.IsNotNull(token, mail.Text);
            const string newPassword = "Brand#New12345";
            Expect.Status(await Api.Anonymous().Post("api/v1/auth/reset-password", new { token, newPassword }), HttpStatusCode.NoContent);
            Expect.Status(await Api.Anonymous().Post("api/v1/auth/reset-password", new { token, newPassword }), (HttpStatusCode)422, "single use");
            await Api.As(email, newPassword);
            var a = await Api.As(email, newPassword);
            Expect.Status(await a.Post("api/v1/auth/change-password", new { currentPassword = newPassword, newPassword = TestHost.Password }), HttpStatusCode.NoContent);
            await Api.As(email);   // back to the shared test password
        }

        [TestMethod]
        public async Task Role_changes_apply_to_existing_tokens_at_once()
        {
            var admin = await Api.As("admin@tams.local");
            var email = "roles." + Guid.NewGuid().ToString("N").Substring(0, 6) + "@tams.local";
            int uid = (int)Expect.Status(await admin.Post("api/v1/users", new { email, displayName = "Role Change", temporaryPassword = TestHost.Password, roleName = "Recruiter" }), HttpStatusCode.Created).Json["userId"];
            var u = await Api.As(email);                                         // token issued while only Recruiter
            Expect.Error(await u.Get("api/v1/employees"), HttpStatusCode.Forbidden, "forbidden");
            Expect.Status(await admin.Post("api/v1/users/" + uid + "/roles", new { roleName = "HRManager", add = true }), HttpStatusCode.NoContent);
            Expect.Status(await u.Get("api/v1/employees"), HttpStatusCode.OK, "granted role usable with the same token");
            Expect.Status(await admin.Post("api/v1/users/" + uid + "/roles", new { roleName = "HRManager", add = false }), HttpStatusCode.NoContent);
            Expect.Error(await u.Get("api/v1/employees"), HttpStatusCode.Forbidden, "forbidden");   // removed role stops at once
        }

        [TestMethod]
        public async Task Deactivated_users_lose_access_at_once()
        {
            var admin = await Api.As("admin@tams.local");
            var email = "temp." + Guid.NewGuid().ToString("N").Substring(0, 6) + "@tams.local";
            var created = Expect.Status(await admin.Post("api/v1/users", new { email, displayName = "Temp Recruiter", temporaryPassword = TestHost.Password, roleName = "Recruiter" }), HttpStatusCode.Created);
            var u = await Api.As(email);
            Expect.Status(await u.Get("api/v1/jobs"), HttpStatusCode.OK);
            Expect.Status(await admin.Post("api/v1/users/" + (int)created.Json["userId"] + "/deactivate"), HttpStatusCode.NoContent);
            Expect.Status(await u.Get("api/v1/jobs"), HttpStatusCode.Unauthorized, "existing token revoked");
            Expect.Status(await Api.Anonymous().Post("api/v1/auth/login", new { email, password = TestHost.Password }), HttpStatusCode.Unauthorized);
        }
    }

    [TestClass]
    public class AuthorizationTests
    {
        [TestMethod]
        public async Task Anonymous_requests_get_401_except_health()
        {
            Expect.Status(await Api.Anonymous().Get("api/v1/health"), HttpStatusCode.OK);
            foreach (var path in new[] { "api/v1/jobs", "api/v1/invoices", "api/v1/auth/me", "api/v1/dashboards/Candidate", "api/v1/users" })
                Expect.Error(await Api.Anonymous().Get(path), HttpStatusCode.Unauthorized, "unauthenticated");
        }

        [TestMethod]
        public async Task Every_role_is_refused_the_other_roles_endpoints_with_403()
        {
            var cand = await Api.As("rohan.gupta@candidate.example");
            var ctr = await Api.As("ravi.kumar@contractor.example");
            var cust = await Api.As("arjun.shah@apexlogistics.example");
            var rec = await Api.As("priya.menon@tams.local");
            var hr = await Api.As("vikram.nair@tams.local");
            Expect.Error(await cand.Post("api/v1/jobs", new { employeeRequisitionId = 1 }), HttpStatusCode.Forbidden, "forbidden");
            Expect.Error(await cand.Get("api/v1/candidates"), HttpStatusCode.Forbidden, "forbidden");
            Expect.Error(await ctr.Get("api/v1/invoices"), HttpStatusCode.Forbidden, "forbidden");
            Expect.Error(await ctr.Get("api/v1/employees"), HttpStatusCode.Forbidden, "forbidden");
            Expect.Error(await cust.Get("api/v1/employees"), HttpStatusCode.Forbidden, "forbidden");
            Expect.Error(await cust.Post("api/v1/invoices/generate", new { customerId = 1, periodStart = "2026-01-01", periodEnd = "2026-01-31" }), HttpStatusCode.Forbidden, "forbidden");
            Expect.Error(await rec.Post("api/v1/offers/1/approve", new { }), HttpStatusCode.Forbidden, "forbidden");
            Expect.Error(await rec.Get("api/v1/users"), HttpStatusCode.Forbidden, "forbidden");
            Expect.Error(await hr.Post("api/v1/timesheets/1/approve", new { }), HttpStatusCode.Forbidden, "forbidden");
            Expect.Error(await hr.Get("api/v1/dashboards/Administrator"), HttpStatusCode.Forbidden, "forbidden");   // role check inside the procedure
            Expect.Error(await cust.Get("api/v1/staff-directory"), HttpStatusCode.Forbidden, "forbidden");
            var dir = (Newtonsoft.Json.Linq.JArray)Expect.Status(await rec.Get("api/v1/staff-directory"), HttpStatusCode.OK).Json;
            Assert.IsTrue(dir.Count > 0 && dir.All(u => u["email"] == null), "staff directory exposes names, not e-mail addresses");
        }
    }

    [TestClass]
    public class ErrorHandlingTests
    {
        [TestMethod]
        public async Task Missing_records_return_404_without_leaking_internals()
        {
            var rec = await Api.As("priya.menon@tams.local");
            var r = Expect.Error(await rec.Get("api/v1/jobs/999999"), HttpStatusCode.NotFound, "not_found");
            StringAssert.DoesNotMatch(r.Body, new System.Text.RegularExpressions.Regex("SqlException|usp_|stack", System.Text.RegularExpressions.RegexOptions.IgnoreCase));
            Assert.IsNotNull(r.Json["correlationId"]);
        }

        [TestMethod]
        public async Task Malformed_json_and_invalid_fields_return_400_with_details()
        {
            var cand = await Api.As("rohan.gupta@candidate.example");
            Expect.Status(await cand.Send(HttpMethod.Post, "api/v1/applications", null, "{ this is not json"), HttpStatusCode.BadRequest);
            var hr = await Api.As("vikram.nair@tams.local");
            var r = Expect.Error(await hr.Post("api/v1/requisitions", new { departmentId = 1, title = "", headcount = 0 }), HttpStatusCode.BadRequest, "validation");
            Assert.IsNotNull(r.Json["details"], r.ToString());
        }

        [TestMethod]
        public async Task Business_rule_violations_map_to_422_and_conflicts_to_409()
        {
            var rec = await Api.As("priya.menon@tams.local");
            Expect.Error(await rec.Post("api/v1/applications/1/status", new { newStatus = "Interview", reason = "jump" }), (HttpStatusCode)422, "business_rule");    // Hired application cannot move
            Expect.Error(await rec.Post("api/v1/candidates", new { firstName = "Dup", lastName = "Dup", email = "ananya.sharma@candidate.example" }), HttpStatusCode.Conflict, "conflict");
        }

        [TestMethod]
        public async Task Oversized_bodies_are_refused_with_413()
        {
            var cand = await Api.As("rohan.gupta@candidate.example");
            var big = "{\"jobPostingId\":1,\"coverNote\":\"" + new string('x', 100 * 1024) + "\"}";
            Expect.Error(await cand.Send(HttpMethod.Post, "api/v1/applications", null, big), (HttpStatusCode)413, "too_large");
        }

        [TestMethod]
        public async Task Security_headers_and_CORS_are_applied()
        {
            var r = await Api.Anonymous().Get("api/v1/health");
            Assert.AreEqual("nosniff", r.Raw.Headers.GetValues("X-Content-Type-Options").Single());
            Assert.AreEqual("DENY", r.Raw.Headers.GetValues("X-Frame-Options").Single());
            Assert.IsTrue(r.Raw.Headers.CacheControl.NoStore);
            using (var http = new HttpClient())
            {
                var ok = new HttpRequestMessage(HttpMethod.Options, TestHost.BaseUrl + "api/v1/jobs");
                ok.Headers.Add("Origin", "http://localhost:4200"); ok.Headers.Add("Access-Control-Request-Method", "GET");
                var okRes = await http.SendAsync(ok);
                Assert.AreEqual("http://localhost:4200", okRes.Headers.GetValues("Access-Control-Allow-Origin").Single());
                var evil = new HttpRequestMessage(HttpMethod.Options, TestHost.BaseUrl + "api/v1/jobs");
                evil.Headers.Add("Origin", "http://evil.example"); evil.Headers.Add("Access-Control-Request-Method", "GET");
                var evilRes = await http.SendAsync(evil);
                Assert.IsFalse(evilRes.Headers.Contains("Access-Control-Allow-Origin"), "other origins are not allowed");
            }
        }

        [TestMethod]
        public async Task SQL_injection_strings_are_treated_as_data()
        {
            var rec = await Api.As("priya.menon@tams.local");
            var r = Expect.Status(await rec.Get("api/v1/candidates?q=" + Uri.EscapeDataString("x'; DROP TABLE cand.Candidates; --")), HttpStatusCode.OK);
            Assert.AreEqual(0, (int)r.Json["total"]);
            Assert.IsTrue(Db.Scalar<int>("SELECT COUNT(*) FROM cand.Candidates") > 0, "table still there");
            var login = await Api.Anonymous().Post("api/v1/auth/login", new { email = "' OR 1=1 --", password = "' OR 1=1 --" });
            Expect.Error(login, HttpStatusCode.Unauthorized, "invalid_credentials");
        }
    }
}
