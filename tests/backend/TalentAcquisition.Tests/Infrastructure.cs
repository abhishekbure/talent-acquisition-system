using System;
using System.Data.SqlClient;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Threading.Tasks;
using Microsoft.Owin.Hosting;
using Microsoft.VisualStudio.TestTools.UnitTesting;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;
using TalentAcquisition.API;
using TalentAcquisition.Common;

namespace TalentAcquisition.Tests
{
    /// <summary>
    /// Starts the REAL Web API in-process (same Startup, same pipeline) against a DISPOSABLE copy of the database
    /// (TAMS_TEST_DB, created by scripts\deployment\Run-BackendTests.ps1). Nothing is mocked. Refuses to run against the live database.
    /// Every seeded user gets the same TEST password, only in that copy.
    /// </summary>
    [TestClass]
    public static class TestHost
    {
        public const string Password = "Test#Pass12345";
        /// <summary>The background worker's own least-privileged database user (Phase 13); the API uses tams_app_demo.</summary>
        public const string WorkerDbUser = "tams_worker_demo";
        public static string BaseUrl { get; private set; }
        public static string DbConnection { get; private set; }
        /// <summary>Temporary document store for this run (deleted at the end).</summary>
        public static string DocumentStore { get; private set; }
        /// <summary>Temporary mock-mail outbox for this run (deleted at the end): .eml files written by the real sender.</summary>
        public static string MailOutbox { get; private set; }
        public static AppSettings Settings { get; private set; }
        private static IDisposable _app;

        [AssemblyInitialize]
        public static void Start(TestContext _)
        {
            var dbName = Environment.GetEnvironmentVariable("TAMS_TEST_DB");
            if (string.IsNullOrWhiteSpace(dbName) || dbName.Equals("TalentAcquisitionDB", StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Set TAMS_TEST_DB to a disposable copy (use scripts\\deployment\\Run-BackendTests.ps1). The live database is never used by tests.");
            DbConnection = "Server=localhost;Database=" + dbName + ";Integrated Security=SSPI;TrustServerCertificate=True";

            // test passwords, applied only to the disposable copy
            byte[] hash, salt; PasswordHasher.Hash(Password, out hash, out salt);
            Db.Exec("UPDATE sec.Users SET PasswordHash = @h, PasswordSalt = @s, HashIterations = 210000, FailedLoginCount = 0, LockoutUntil = NULL", new SqlParameter("@h", hash), new SqlParameter("@s", salt));

            var secret = new byte[48]; using (var r = System.Security.Cryptography.RandomNumberGenerator.Create()) r.GetBytes(secret);
            DocumentStore = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "tams-doc-tests-" + Guid.NewGuid().ToString("N"));
            MailOutbox = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "tams-mail-tests-" + Guid.NewGuid().ToString("N"));
            var settings = new AppSettings { ConnectionString = DbConnection, DbImpersonateUser = "tams_app_demo", JwtSecret = Convert.ToBase64String(secret), ListenUrl = "http://localhost:5055/", MaxRequestBodyKb = 64, DocumentStorePath = DocumentStore, MailOutboxPath = MailOutbox,
                                             DocumentBackupPath = DocumentStore + "-backup",
                                             // the suite logs in far more often than a person; the limiter itself is proved on a second host (SecurityTests)
                                             RateLimitLoginPerMinute = 100000, RateLimitAccountPerMinute = 100000, RateLimitTokenPerMinute = 100000 };
            Settings = settings;
            var problems = settings.Validate(); if (problems.Length > 0) throw new InvalidOperationException(string.Join("; ", problems));
            BaseUrl = settings.ListenUrl;
            // the API's own log of the run (errors with their exception) next to the test results, so a failure can be diagnosed
            var logDir = System.IO.Path.GetFullPath(System.IO.Path.Combine(AppDomain.CurrentDomain.BaseDirectory, @"..\..\..\..\TestResults"));
            var root = new CompositionRoot(settings, new FileLog(logDir, console: false, prefix: "api-under-test"));
            _app = WebApp.Start(new StartOptions(BaseUrl), a => new Startup(root).Configuration(a));
        }

        /// <summary>Starts a SECOND real API in-process on another port with changed settings (rate limits, an unreachable
        /// database...). Same Startup and pipeline as the main host; dispose it at the end of the test.</summary>
        public static IDisposable StartAnother(int port, Action<AppSettings> change)
        {
            var s = Settings;
            var other = new AppSettings { ConnectionString = s.ConnectionString, DbImpersonateUser = s.DbImpersonateUser, JwtSecret = s.JwtSecret, ListenUrl = "http://localhost:" + port + "/",
                                          MaxRequestBodyKb = s.MaxRequestBodyKb, DocumentStorePath = s.DocumentStorePath, MailOutboxPath = s.MailOutboxPath, DocumentBackupPath = s.DocumentBackupPath,
                                          RateLimitLoginPerMinute = s.RateLimitLoginPerMinute, RateLimitAccountPerMinute = s.RateLimitAccountPerMinute, RateLimitTokenPerMinute = s.RateLimitTokenPerMinute };
            change(other);
            var problems = other.Validate(); if (problems.Length > 0) throw new InvalidOperationException(string.Join("; ", problems));
            var root = new CompositionRoot(other, new NullLog());
            return WebApp.Start(new StartOptions(other.ListenUrl), a => new Startup(root).Configuration(a));
        }

        [AssemblyCleanup]
        public static void Stop()
        {
            if (_app != null) _app.Dispose();
            try { if (DocumentStore != null && System.IO.Directory.Exists(DocumentStore)) System.IO.Directory.Delete(DocumentStore, true); } catch (System.IO.IOException) { }
            try { if (MailOutbox != null && System.IO.Directory.Exists(MailOutbox)) System.IO.Directory.Delete(MailOutbox, true); } catch (System.IO.IOException) { }
        }
    }

    /// <summary>One delivered e-mail, parsed from the .eml file the mock provider wrote.</summary>
    public sealed class Eml
    {
        public string Path { get; set; }
        public long NotificationId { get; set; }
        public string Template { get; set; }
        public string To { get; set; }
        public string Raw { get; set; }
        public string Text { get; set; }
        /// <summary>The token= value of the first link in the plain-text part.</summary>
        public string Token
        {
            get { var m = System.Text.RegularExpressions.Regex.Match(Text ?? "", @"[?&]token=([A-Za-z0-9_\-%]+)"); return m.Success ? Uri.UnescapeDataString(m.Groups[1].Value) : null; }
        }
    }

    /// <summary>Runs the REAL notification sender (TalentAcquisition.Business.NotificationProcessor with the pickup-directory provider)
    /// against the disposable database, and reads what it delivered.</summary>
    public static class Mail
    {
        public static TalentAcquisition.Business.ProcessResult Deliver(string outbox = null, int batch = 20)
        {
            var s = TestHost.Settings;
            var settings = new AppSettings { ConnectionString = s.ConnectionString, DbImpersonateUser = TestHost.WorkerDbUser, MailOutboxPath = outbox ?? s.MailOutboxPath, MailFrom = s.MailFrom,
                                             AppBaseUrl = s.AppBaseUrl, NotificationBatchSize = batch, NotificationLeaseSeconds = 300, CommandTimeoutSeconds = 60 };
            var db = new TalentAcquisition.Data.StoredProcedureExecutor(new TalentAcquisition.Data.ConnectionManager(settings), new NullLog());
            var p = new TalentAcquisition.Business.NotificationProcessor(new TalentAcquisition.Data.NotificationRepository(db),
                        new TalentAcquisition.Business.PickupDirectoryMailSender(settings.MailOutboxPath), settings, new NullLog());
            return p.RunAsync().GetAwaiter().GetResult();
        }


        public static Eml[] All(string outbox = null)
        {
            var dir = outbox ?? TestHost.MailOutbox;
            if (!System.IO.Directory.Exists(dir)) return new Eml[0];
            return System.IO.Directory.GetFiles(dir, "*.eml").Select(Parse).OrderBy(e => e.NotificationId).ToArray();
        }

        /// <summary>The newest delivered e-mail of a template to an address (null if none).</summary>
        public static Eml Latest(string to, string template)
        {
            return All().Where(e => string.Equals(e.To, to, StringComparison.OrdinalIgnoreCase) && e.Template == template).OrderByDescending(e => e.NotificationId).FirstOrDefault();
        }

        public static Eml Parse(string path)
        {
            var raw = System.IO.File.ReadAllText(path, Encoding.UTF8);
            var e = new Eml { Path = path, Raw = raw };
            foreach (var line in raw.Split(new[] { "\r\n", "\n" }, StringSplitOptions.None))
            {
                if (line.Length == 0) break;                                       // end of the message headers
                if (line.StartsWith("X-TAMS-Notification-Id:")) e.NotificationId = long.Parse(line.Substring(23).Trim());
                else if (line.StartsWith("X-TAMS-Template:")) e.Template = line.Substring(16).Trim();
                else if (line.StartsWith("To:")) { var m = System.Text.RegularExpressions.Regex.Match(line, "<([^>]+)>"); e.To = m.Success ? m.Groups[1].Value : line.Substring(3).Trim(); }
            }
            var t = System.Text.RegularExpressions.Regex.Match(raw, @"Content-Type: text/plain; charset=utf-8\r?\nContent-Transfer-Encoding: 8bit\r?\n\r?\n(.*?)\r?\n----boundary", System.Text.RegularExpressions.RegexOptions.Singleline);
            e.Text = t.Success ? t.Groups[1].Value : null;
            return e;
        }

        /// <summary>Delivers the queue, then confirms the address with the link from the e-mail - exactly what a person does.</summary>
        public static async Task VerifyThroughEmail(string email)
        {
            Deliver();
            var mail = Latest(email, "EMAIL_VERIFY");
            Assert.IsNotNull(mail, "no confirmation e-mail delivered to " + email);
            Assert.IsNotNull(mail.Token, "no link in the confirmation e-mail: " + mail.Text);
            Expect.Status(await Api.Anonymous().Post("api/v1/auth/verify-email", new { token = mail.Token }), HttpStatusCode.OK, "verify " + email);
        }
    }

    /// <summary>Direct database access for test SET-UP and for verifying the record trail (sysadmin on the disposable copy, never via the API).</summary>
    public static class Db
    {
        public static void Exec(string sql, params SqlParameter[] p)
        {
            using (var c = new SqlConnection(TestHost.DbConnection)) { c.Open(); using (var cmd = new SqlCommand(sql, c)) { cmd.Parameters.AddRange(p); cmd.ExecuteNonQuery(); } }
        }
        public static T Scalar<T>(string sql, params SqlParameter[] p)
        {
            using (var c = new SqlConnection(TestHost.DbConnection)) { c.Open(); using (var cmd = new SqlCommand(sql, c)) { cmd.Parameters.AddRange(p); var v = cmd.ExecuteScalar(); return v == null || v is DBNull ? default(T) : (T)Convert.ChangeType(v, Nullable.GetUnderlyingType(typeof(T)) ?? typeof(T)); } }
        }
        public static int UserId(string email) { return Scalar<int>("SELECT UserId FROM sec.Users WHERE EmailNormalized = UPPER(@e)", new SqlParameter("@e", email)); }
        public static int CustomerId(string code) { return Scalar<int>("SELECT CustomerId FROM org.Customers WHERE CustomerCode = @c", new SqlParameter("@c", code)); }
    }

    public sealed class Resp
    {
        public HttpStatusCode Status { get; set; }
        public string Body { get; set; }
        public HttpResponseMessage Raw { get; set; }
        public JToken Json { get { return string.IsNullOrEmpty(Body) ? null : JToken.Parse(Body); } }
        public override string ToString() { return (int)Status + " " + Body; }
    }

    public sealed class Api
    {
        private static readonly HttpClient Http = new HttpClient();
        public string Token { get; set; }
        /// <summary>Which API this client talks to (default: the main test host).</summary>
        public string BaseUrl { get; set; }
        private string Url(string path) { return (BaseUrl ?? TestHost.BaseUrl) + path; }
        public static Api At(string baseUrl) { return new Api { BaseUrl = baseUrl }; }
        public JObject User { get; private set; }

        public static Api Anonymous() { return new Api(); }

        public static async Task<Api> As(string email, string password = TestHost.Password)
        {
            var a = new Api();
            var r = await a.Post("api/v1/auth/login", new { email, password });
            Assert.AreEqual(HttpStatusCode.OK, r.Status, "login " + email + ": " + r);
            a.Token = (string)r.Json["token"]; a.User = (JObject)r.Json["user"];
            return a;
        }

        public Task<Resp> Get(string path) { return Send(HttpMethod.Get, path, null); }
        public Task<Resp> Post(string path, object body = null) { return Send(HttpMethod.Post, path, body); }
        public Task<Resp> Put(string path, object body) { return Send(HttpMethod.Put, path, body); }
        public Task<Resp> Delete(string path) { return Send(HttpMethod.Delete, path, null); }

        /// <summary>multipart/form-data upload of one file plus form fields.</summary>
        public async Task<Resp> Upload(string ownerType, int ownerId, string fileName, byte[] content, string docType = null, int? complianceId = null, bool primary = false)
        {
            var form = new MultipartFormDataContent();
            form.Add(new StringContent(ownerType ?? ""), "ownerType");
            form.Add(new StringContent(ownerId.ToString()), "ownerId");
            if (docType != null) form.Add(new StringContent(docType), "docType");
            if (complianceId.HasValue) form.Add(new StringContent(complianceId.Value.ToString()), "complianceId");
            if (primary) form.Add(new StringContent("true"), "primaryResume");
            var file = new ByteArrayContent(content); file.Headers.ContentType = new System.Net.Http.Headers.MediaTypeHeaderValue("application/octet-stream");
            form.Add(file, "file", fileName);
            var req = new HttpRequestMessage(HttpMethod.Post, Url("api/v1/documents")) { Content = form };
            if (Token != null) req.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", Token);
            await form.LoadIntoBufferAsync();                        // sets Content-Length, as browsers do
            var res = await Http.SendAsync(req);
            return new Resp { Status = res.StatusCode, Body = await res.Content.ReadAsStringAsync(), Raw = res };
        }

        public async Task<Tuple<HttpResponseMessage, byte[]>> Download(int documentId)
        {
            var req = new HttpRequestMessage(HttpMethod.Get, Url("api/v1/documents/" + documentId + "/download"));
            if (Token != null) req.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", Token);
            var res = await Http.SendAsync(req);
            return Tuple.Create(res, await res.Content.ReadAsByteArrayAsync());
        }

        public async Task<Resp> Send(HttpMethod m, string path, object body, string rawJson = null)
        {
            var req = new HttpRequestMessage(m, Url(path));
            if (Token != null) req.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", Token);
            if (rawJson != null) req.Content = new StringContent(rawJson, Encoding.UTF8, "application/json");
            else if (body != null) req.Content = new StringContent(JsonConvert.SerializeObject(body), Encoding.UTF8, "application/json");
            var res = await Http.SendAsync(req);
            return new Resp { Status = res.StatusCode, Body = await res.Content.ReadAsStringAsync(), Raw = res };
        }

        /// <summary>Sends a prepared request (custom content, headers or transfer encoding) with this client's token.</summary>
        public async Task<Resp> Send(HttpRequestMessage req)
        {
            if (Token != null) req.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", Token);
            var res = await Http.SendAsync(req);
            return new Resp { Status = res.StatusCode, Body = await res.Content.ReadAsStringAsync(), Raw = res };
        }
        public string UrlOf(string path) { return Url(path); }
    }

    public static class Expect
    {
        public static Resp Status(Resp r, HttpStatusCode expected, string because = null)
        {
            Assert.AreEqual(expected, r.Status, (because ?? "") + " -> " + r);
            return r;
        }
        public static Resp Error(Resp r, HttpStatusCode expected, string code)
        {
            Status(r, expected);
            Assert.IsNotNull(r.Json, "no JSON error body: " + r + " " + r.Raw.Content.Headers.ContentType);
            Assert.AreEqual(code, (string)r.Json["code"], r.ToString());
            return r;
        }
    }

    public static class Dates
    {
        public static DateTime Today { get { return DateTime.UtcNow.Date; } }
        public static DateTime Monday(int weeksBack = 0) { var d = Today; int diff = ((int)d.DayOfWeek + 6) % 7; return d.AddDays(-diff - 7 * weeksBack); }
    }

    public static class Fresh
    {
        /// <summary>Self-registers a brand-new candidate through the API and logs them in.</summary>
        public static async Task<Api> Candidate(string tag)
        {
            var email = "api." + tag + "." + Guid.NewGuid().ToString("N").Substring(0, 8) + "@candidate.example";
            var r = await Api.Anonymous().Post("api/v1/auth/register", new { email, password = TestHost.Password, firstName = "Api", lastName = tag });
            Expect.Status(r, HttpStatusCode.Created, "register");
            await Mail.VerifyThroughEmail(email);
            return await Api.As(email);
        }
    }
}
