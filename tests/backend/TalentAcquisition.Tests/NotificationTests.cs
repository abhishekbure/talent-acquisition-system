using System;
using System.Data.SqlClient;
using System.IO;
using System.Linq;
using System.Net;
using System.Threading.Tasks;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace TalentAcquisition.Tests
{
    /// <summary>
    /// Phase 9: e-mail delivery through the REAL sender (NotificationProcessor + pickup-directory provider writing .eml files),
    /// retries, concurrent workers, administration, and e-mail ownership at registration (KI-014).
    /// </summary>
    [TestClass]
    public class NotificationTests
    {
        private static long Enqueue(string template, int userId, string subject, string body)
        {
            var key = "T-" + Guid.NewGuid().ToString("N");
            Db.Exec("EXEC notify.usp_Enqueue @t, @u, @s, @b, @k, 'Test', 1", new SqlParameter("@t", template), new SqlParameter("@u", userId), new SqlParameter("@s", subject),
                    new SqlParameter("@b", body), new SqlParameter("@k", key));
            return Db.Scalar<long>("SELECT NotificationId FROM notify.NotificationQueue WHERE DedupeKey LIKE @k + '|%'", new SqlParameter("@k", key));
        }
        private static string Status(long id) { return Db.Scalar<string>("SELECT Status FROM notify.NotificationQueue WHERE NotificationId = @i", new SqlParameter("@i", id)); }

        [TestMethod]
        public async Task Knowing_someones_email_is_not_enough_to_take_over_their_candidate_record()
        {
            var priya = await Api.As("priya.menon@tams.local");
            var email = "owner." + Guid.NewGuid().ToString("N").Substring(0, 8) + "@candidate.example";
            int candidateId = (int)Expect.Status(await priya.Post("api/v1/candidates", new { firstName = "Real", lastName = "Owner", email, totalExperienceYears = 4 }), HttpStatusCode.Created).Json["candidateId"];

            // an impostor registers that address first
            Expect.Status(await Api.Anonymous().Post("api/v1/auth/register", new { email, password = "Imposter#Pass1", firstName = "Im", lastName = "Poster" }), HttpStatusCode.Created);
            Expect.Error(await Api.Anonymous().Post("api/v1/auth/login", new { email, password = "Imposter#Pass1" }), HttpStatusCode.Forbidden, "email_unverified");
            Assert.AreEqual(0, Db.Scalar<int>("SELECT ISNULL(UserId, 0) FROM cand.Candidates WHERE CandidateId = @c", new SqlParameter("@c", candidateId)), "not linked before the address is proven");
            Assert.AreEqual(1, Db.Scalar<int>("SELECT COUNT(*) FROM cand.Candidates WHERE EmailNormalized = UPPER(@e)", new SqlParameter("@e", email)), "no second candidate record");

            // the confirmation goes to the real owner's mailbox; the real owner uses "Forgot password" instead and takes the account over
            Mail.Deliver();
            Assert.IsNotNull(Mail.Latest(email, "EMAIL_VERIFY"), "the confirmation link went to the address, not to the impostor");
            Expect.Status(await Api.Anonymous().Post("api/v1/auth/forgot-password", new { email }), HttpStatusCode.Accepted);
            Mail.Deliver();
            var reset = Mail.Latest(email, "PASSWORD_RESET");
            Expect.Status(await Api.Anonymous().Post("api/v1/auth/reset-password", new { token = reset.Token, newPassword = "Owner#Pass12345" }), HttpStatusCode.NoContent);
            var owner = await Api.As(email, "Owner#Pass12345");
            Assert.AreEqual(candidateId, (int)owner.User["candidateId"], "the owner is linked to the record the recruiter created");
            Expect.Error(await Api.Anonymous().Post("api/v1/auth/login", new { email, password = "Imposter#Pass1" }), HttpStatusCode.Unauthorized, "invalid_credentials");
        }

        [TestMethod]
        public async Task Resend_confirmation_always_answers_the_same_and_the_new_link_works()
        {
            var email = "resend." + Guid.NewGuid().ToString("N").Substring(0, 8) + "@candidate.example";
            Expect.Status(await Api.Anonymous().Post("api/v1/auth/register", new { email, password = TestHost.Password, firstName = "Re", lastName = "Send" }), HttpStatusCode.Created);
            Mail.Deliver();
            var first = Mail.Latest(email, "EMAIL_VERIFY");
            Db.Exec("UPDATE sec.EmailVerificationTokens SET CreatedAt = DATEADD(MINUTE, -2, CreatedAt) WHERE UserId = (SELECT UserId FROM sec.Users WHERE EmailNormalized = UPPER(@e))", new SqlParameter("@e", email));  // a while later
            var a = await Api.Anonymous().Post("api/v1/auth/resend-verification", new { email });
            var b = await Api.Anonymous().Post("api/v1/auth/resend-verification", new { email = "nobody.here@candidate.example" });
            var c = await Api.Anonymous().Post("api/v1/auth/resend-verification", new { email = "divya.reddy@candidate.example" });   // already verified
            Assert.AreEqual(HttpStatusCode.Accepted, a.Status); Assert.AreEqual(a.Body, b.Body); Assert.AreEqual(a.Body, c.Body);
            Mail.Deliver();
            var second = Mail.Latest(email, "EMAIL_VERIFY");
            Assert.AreNotEqual(first.NotificationId, second.NotificationId);
            Assert.IsNull(Mail.Latest("divya.reddy@candidate.example", "EMAIL_VERIFY"), "nothing sent to a verified address");
            Expect.Error(await Api.Anonymous().Post("api/v1/auth/verify-email", new { token = first.Token }), (HttpStatusCode)422, "business_rule");
            Expect.Status(await Api.Anonymous().Post("api/v1/auth/verify-email", new { token = second.Token }), HttpStatusCode.OK);
            await Api.As(email);
        }

        [TestMethod]
        public void A_failed_delivery_is_retried_with_back_off_and_then_delivered_safely_encoded()
        {
            Mail.Deliver();                                                     // start from an empty queue
            int divya = Db.UserId("divya.reddy@candidate.example");
            long id = Enqueue("TEST_NOTE", divya, "Phase 9 retry test", "Comment: <script>alert(1)</script> & \"quotes\" – ünïcödé");

            // the provider fails: the outbox path is below a FILE, so the folder cannot be created
            var blocker = Path.Combine(Path.GetTempPath(), "tams-blocked-" + Guid.NewGuid().ToString("N"));
            File.WriteAllText(blocker, "not a folder");
            try
            {
                var r = Mail.Deliver(Path.Combine(blocker, "outbox"));
                Assert.IsTrue(r.Failed >= 1, r.ToString());
            }
            finally { File.Delete(blocker); }
            Assert.AreEqual("Pending", Status(id));
            Assert.AreEqual(1, Db.Scalar<int>("SELECT Attempts FROM notify.NotificationQueue WHERE NotificationId = @i", new SqlParameter("@i", id)));
            var err = Db.Scalar<string>("SELECT TOP 1 ErrorMessage FROM notify.NotificationHistory WHERE NotificationId = @i AND Outcome = 'Failed'", new SqlParameter("@i", id));
            StringAssert.Contains(err, "IOException");
            var wait = Db.Scalar<int>("SELECT DATEDIFF(SECOND, SYSUTCDATETIME(), NextAttemptAt) FROM notify.NotificationQueue WHERE NotificationId = @i", new SqlParameter("@i", id));
            Assert.IsTrue(wait >= 45 && wait <= 61, "retry about a minute later, was " + wait + " s");

            var early = Mail.Deliver();                                          // too early: not retried
            Assert.AreEqual("Pending", Status(id)); Assert.IsFalse(Mail.All().Any(e => e.NotificationId == id));

            Db.Exec("UPDATE notify.NotificationQueue SET NextAttemptAt = DATEADD(SECOND, -1, SYSUTCDATETIME()) WHERE NotificationId = @i", new SqlParameter("@i", id));   // test clock
            Mail.Deliver();
            Assert.AreEqual("Sent", Status(id));
            var mail = Mail.All().Single(e => e.NotificationId == id);
            Assert.AreEqual("divya.reddy@candidate.example", mail.To);
            StringAssert.Contains(mail.Text, "ünïcödé");
            StringAssert.Contains(mail.Raw, "&lt;script&gt;alert(1)&lt;/script&gt;");
            var htmlPart = mail.Raw.Substring(mail.Raw.IndexOf("Content-Type: text/html", StringComparison.Ordinal));
            Assert.IsFalse(htmlPart.Contains("<script>"), "nothing typed by a user becomes markup in the HTML part");
            StringAssert.Contains(mail.Raw, "Message-ID: <notification-" + id + ".2@tams.local>");
            Assert.AreEqual(2, Db.Scalar<int>("SELECT COUNT(*) FROM notify.NotificationHistory WHERE NotificationId = @i", new SqlParameter("@i", id)), "Failed, then Sent");
        }

        [TestMethod]
        public void Four_workers_at_once_deliver_every_message_exactly_once()
        {
            Mail.Deliver();
            int divya = Db.UserId("divya.reddy@candidate.example");
            var ids = Enumerable.Range(1, 40).Select(i => Enqueue("TEST_NOTE", divya, "Concurrency " + i, "Message " + i)).ToArray();
            var outbox = Path.Combine(Path.GetTempPath(), "tams-mail-concurrency-" + Guid.NewGuid().ToString("N"));
            try
            {
                var results = Enumerable.Range(0, 4).Select(_ => Task.Run(() => Mail.Deliver(outbox, batch: 3))).ToArray();
                Task.WaitAll(results);
                Assert.AreEqual(40, results.Sum(t => t.Result.Sent), string.Join(" | ", results.Select(t => t.Result.ToString())));
                Assert.IsTrue(results.Count(t => t.Result.Sent > 0) >= 2, "the work was actually shared: " + string.Join(" | ", results.Select(t => t.Result.ToString())));
                var files = Mail.All(outbox).Where(e => ids.Contains(e.NotificationId)).ToArray();
                Assert.AreEqual(40, files.Length, "one file per message");
                Assert.AreEqual(40, files.Select(f => f.NotificationId).Distinct().Count(), "no message delivered twice");
                Assert.AreEqual(0, Db.Scalar<int>("SELECT COUNT(*) FROM notify.NotificationQueue WHERE NotificationId BETWEEN @a AND @b AND TemplateCode = 'TEST_NOTE' AND Status <> 'Sent'",
                                                  new SqlParameter("@a", ids.Min()), new SqlParameter("@b", ids.Max())));
            }
            finally { if (Directory.Exists(outbox)) Directory.Delete(outbox, true); }
        }

        [TestMethod]
        public async Task Administrators_see_the_queue_without_bodies_and_can_retry_or_cancel()
        {
            Mail.Deliver();
            int divya = Db.UserId("divya.reddy@candidate.example");
            long failed = Enqueue("TEST_NOTE", divya, "Admin retry test", "secret body text");
            Db.Exec("UPDATE notify.NotificationQueue SET Status = 'Failed', Attempts = MaxAttempts, ProcessedAt = SYSUTCDATETIME() WHERE NotificationId = @i", new SqlParameter("@i", failed));
            Db.Exec("INSERT notify.NotificationHistory (NotificationId, AttemptNo, Outcome, ErrorMessage) VALUES (@i, 5, 'Failed', 'disk full')", new SqlParameter("@i", failed));
            long pending = Enqueue("TEST_NOTE", divya, "Admin cancel test", "x");
            Db.Exec("UPDATE notify.NotificationQueue SET NextAttemptAt = DATEADD(HOUR, 1, SYSUTCDATETIME()) WHERE NotificationId = @i", new SqlParameter("@i", pending));

            var rahul = await Api.As("rahul.desai@tams.local");
            Expect.Status(await rahul.Get("api/v1/admin/notifications"), HttpStatusCode.Forbidden);
            var admin = await Api.As("admin@tams.local");
            var list = Expect.Status(await admin.Get("api/v1/admin/notifications?status=Failed&q=Admin%20retry"), HttpStatusCode.OK);
            var row = list.Json["items"].Single(i => (long)i["notificationId"] == failed);
            Assert.AreEqual("disk full", (string)row["lastError"]);
            Assert.IsNull(row["body"]); Assert.IsFalse(list.Body.Contains("secret body text"), "bodies are never listed");
            Expect.Error(await admin.Get("api/v1/admin/notifications?status=Bogus"), HttpStatusCode.BadRequest, "validation");
            var hist = Expect.Status(await admin.Get("api/v1/admin/notifications/" + failed + "/history"), HttpStatusCode.OK);
            Assert.AreEqual("disk full", (string)hist.Json[0]["errorMessage"]);

            Expect.Status(await admin.Post("api/v1/admin/notifications/" + failed + "/retry"), HttpStatusCode.OK);
            Assert.AreEqual("Pending", Status(failed));
            Mail.Deliver();
            Assert.AreEqual("Sent", Status(failed), "re-queued message is delivered");
            Expect.Error(await admin.Post("api/v1/admin/notifications/" + failed + "/retry"), (HttpStatusCode)422, "business_rule");

            Expect.Status(await admin.Post("api/v1/admin/notifications/" + pending + "/cancel"), HttpStatusCode.OK);
            Assert.AreEqual("Cancelled", Status(pending));
            Expect.Error(await admin.Get("api/v1/admin/notifications/999999999/history"), HttpStatusCode.NotFound, "not_found");

            // a sign-in link is never re-sent
            Expect.Status(await Api.Anonymous().Post("api/v1/auth/forgot-password", new { email = "neha.verma@apexlogistics.example" }), HttpStatusCode.Accepted);
            long reset = Db.Scalar<long>("SELECT MAX(NotificationId) FROM notify.NotificationQueue WHERE TemplateCode = 'PASSWORD_RESET'");
            Expect.Status(await admin.Post("api/v1/admin/notifications/" + reset + "/cancel"), HttpStatusCode.OK);
            Expect.Error(await admin.Post("api/v1/admin/notifications/" + reset + "/retry"), (HttpStatusCode)422, "business_rule");
            Assert.IsFalse(Db.Scalar<string>("SELECT Body FROM notify.NotificationQueue WHERE NotificationId = @i", new SqlParameter("@i", reset)).Contains("token="), "cancelled link erased");
        }

        [TestMethod]
        public async Task Sign_in_links_are_not_shown_in_the_in_app_list()
        {
            const string email = "neha.verma@apexlogistics.example";
            Expect.Status(await Api.Anonymous().Post("api/v1/auth/forgot-password", new { email }), HttpStatusCode.Accepted);
            var neha = await Api.As(email);
            var list = Expect.Status(await neha.Get("api/v1/notifications?top=200"), HttpStatusCode.OK);
            Assert.IsFalse(list.Json.Any(n => (string)n["templateCode"] == "PASSWORD_RESET"), list.Body);
            Assert.IsFalse(list.Body.Contains("token="));
        }
    }
}
