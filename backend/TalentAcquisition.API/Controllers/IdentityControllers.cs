using System;
using System.Net;
using System.Threading.Tasks;
using System.Web.Http;
using TalentAcquisition.Business;
using TalentAcquisition.Models;

namespace TalentAcquisition.API.Controllers
{
    [RoutePrefix("api/v1")]
    public sealed class HealthController : ApiBase
    {
        private readonly AuthService _auth;
        public HealthController(AuthService auth) { _auth = auth; }

        [AllowAnonymous, HttpGet, Route("health")]
        public async Task<IHttpActionResult> Get()
        {
            try { var p = await _auth.PingAsync(); return Ok(new { status = "ok", database = p.Str("DatabaseName"), serverTimeUtc = p.Date("ServerTimeUtc") }); }
            catch { return Content(HttpStatusCode.ServiceUnavailable, new { status = "database_unreachable" }); }
        }
    }

    [RoutePrefix("api/v1/auth")]
    public sealed class AuthController : ApiBase
    {
        private readonly AuthService _auth;
        public AuthController(AuthService auth) { _auth = auth; }

        [AllowAnonymous, HttpPost, Route("login")]
        public async Task<IHttpActionResult> Login([FromBody] LoginRequest body) { return Ok(await _auth.LoginAsync(body ?? new LoginRequest(), ClientIp, UserAgent)); }

        [AllowAnonymous, HttpPost, Route("register")]
        public async Task<IHttpActionResult> Register([FromBody] RegisterRequest body) { return Created(await _auth.RegisterAsync(body)); }

        [AllowAnonymous, HttpPost, Route("forgot-password")]
        public async Task<IHttpActionResult> Forgot([FromBody] ForgotPasswordRequest body)
        {
            await _auth.ForgotPasswordAsync(body);
            return Content(HttpStatusCode.Accepted, new { message = "If an account exists for that e-mail, a reset link has been sent." });
        }

        /// <summary>Confirms the address of a new account from the e-mailed link (single use, 24 hours).</summary>
        [AllowAnonymous, HttpPost, Route("verify-email")]
        public async Task<IHttpActionResult> VerifyEmail([FromBody] VerifyEmailRequest body) { return Ok(await _auth.VerifyEmailAsync(body)); }

        [AllowAnonymous, HttpPost, Route("resend-verification")]
        public async Task<IHttpActionResult> ResendVerification([FromBody] ResendVerificationRequest body)
        {
            await _auth.ResendVerificationAsync(body);
            return Content(HttpStatusCode.Accepted, new { message = "If an unconfirmed account exists for that e-mail, a new confirmation link has been sent." });
        }

        [AllowAnonymous, HttpPost, Route("reset-password")]
        public async Task<IHttpActionResult> Reset([FromBody] ResetPasswordRequest body) { await _auth.ResetPasswordAsync(body); return Done(); }

        [HttpPost, Route("logout")]
        public async Task<IHttpActionResult> Logout() { await _auth.LogoutAsync(Jti); return Done(); }

        [HttpPost, Route("change-password")]
        public async Task<IHttpActionResult> ChangePassword([FromBody] ChangePasswordRequest body) { await _auth.ChangePasswordAsync(Actor, body); return Done(); }

        [HttpGet, Route("me")]
        public async Task<IHttpActionResult> Me() { return Ok(await _auth.MeAsync(Actor)); }
    }

    [RoutePrefix("api/v1/users"), TamsAuthorize(Roles = R.Admin)]
    public sealed class UsersController : ApiBase
    {
        private readonly UserService _s;
        public UsersController(UserService s) { _s = s; }
        [HttpGet, Route("")] public async Task<IHttpActionResult> List(string q = null, string role = null, bool? active = null, int page = 1, int pageSize = 25) { return Ok(await _s.ListAsync(Actor, q, role, active, page, pageSize)); }
        [HttpGet, Route("{id:int}")] public async Task<IHttpActionResult> Get(int id) { return Ok(await _s.GetAsync(Actor, id)); }
        [HttpPost, Route("")] public async Task<IHttpActionResult> Create([FromBody] CreateUserRequest body) { return Created(await _s.CreateAsync(Actor, body)); }
        [HttpPost, Route("{id:int}/activate")] public async Task<IHttpActionResult> Activate(int id) { await _s.SetActiveAsync(Actor, id, true); return Done(); }
        [HttpPost, Route("{id:int}/deactivate")] public async Task<IHttpActionResult> Deactivate(int id) { await _s.SetActiveAsync(Actor, id, false); return Done(); }
        [HttpPost, Route("{id:int}/roles")] public async Task<IHttpActionResult> Roles(int id, [FromBody] AssignRoleRequest body) { await _s.AssignRoleAsync(Actor, id, body); return Done(); }
    }

    [RoutePrefix("api/v1/admin"), TamsAuthorize(Roles = R.Admin)]
    public sealed class AdminController : ApiBase
    {
        private readonly AdminService _s; private readonly NotificationService _n;
        public AdminController(AdminService s, NotificationService n) { _s = s; _n = n; }
        // e-mail delivery queue (Phase 9): no message bodies are exposed here
        [HttpGet, Route("notifications")] public async Task<IHttpActionResult> Queue(string status = null, string q = null, int page = 1, int pageSize = 25) { return Ok(await _n.QueueAsync(Actor, status, q, page, pageSize)); }
        [HttpGet, Route("notifications/{id:long}/history")] public async Task<IHttpActionResult> DeliveryHistory(long id) { return Ok(await _n.DeliveryHistoryAsync(Actor, id)); }
        [HttpPost, Route("notifications/{id:long}/retry")] public async Task<IHttpActionResult> Retry(long id) { return Ok(await _n.RetryAsync(Actor, id)); }
        [HttpPost, Route("notifications/{id:long}/cancel")] public async Task<IHttpActionResult> Cancel(long id) { return Ok(await _n.CancelAsync(Actor, id)); }
        [HttpGet, Route("audit-logs")] public async Task<IHttpActionResult> Audit(string table = null, string recordId = null, DateTime? from = null, DateTime? to = null, int page = 1, int pageSize = 50) { return Ok(await _s.AuditAsync(Actor, table, recordId, from, to, page, pageSize)); }
        [HttpGet, Route("login-history")] public async Task<IHttpActionResult> Logins(string email = null, bool? success = null, int page = 1, int pageSize = 50) { return Ok(await _s.LoginsAsync(Actor, email, success, page, pageSize)); }
        [HttpGet, Route("jobs")] public async Task<IHttpActionResult> Jobs() { return Ok(await _s.JobsAsync(Actor)); }
        [HttpGet, Route("jobs/{id:int}/history")] public async Task<IHttpActionResult> JobHistory(int id, int top = 50) { return Ok(await _s.JobHistoryAsync(Actor, id, top)); }
        /// <summary>Phase 11: what one scheduled-job run did (each contract flagged, backup file written, index rebuilt ...).</summary>
        [HttpGet, Route("jobs/runs/{executionId:long}/details")] public async Task<IHttpActionResult> JobRunDetails(long executionId) { return Ok(await _s.JobRunDetailsAsync(Actor, executionId)); }
        [HttpPost, Route("rate-cards")] public async Task<IHttpActionResult> SaveRateCard([FromBody] RateCardRequest body) { return Ok(await _s.UpsertRateCardAsync(Actor, body)); }
        [HttpPut, Route("rate-cards/{id:int}")] public async Task<IHttpActionResult> UpdateRateCard(int id, [FromBody] RateCardRequest body) { if (body != null) body.RateCardId = id; return Ok(await _s.UpsertRateCardAsync(Actor, body)); }
    }

    [RoutePrefix("api/v1")]
    public sealed class OrganizationController : ApiBase
    {
        private readonly OrganizationService _s; private readonly AdminService _a;
        public OrganizationController(OrganizationService s, AdminService a) { _s = s; _a = a; }
        [HttpGet, Route("customers"), TamsAuthorize(Roles = "Customer,Recruiter,HRManager,Administrator")] public async Task<IHttpActionResult> Customers() { return Ok(await _s.CustomersAsync(Actor)); }
        [HttpGet, Route("customers/{id:int}"), TamsAuthorize(Roles = "Customer,Recruiter,HRManager,Administrator")] public async Task<IHttpActionResult> Customer(int id) { return Ok(await _s.CustomerAsync(Actor, id)); }
        [HttpGet, Route("customers/{id:int}/balance"), TamsAuthorize(Roles = "Customer,Recruiter,Administrator")] public async Task<IHttpActionResult> Balance(int id) { return Ok(await _s.BalanceAsync(Actor, id)); }
        [HttpGet, Route("customers/{id:int}/rate-cards"), TamsAuthorize(Roles = "Customer,Recruiter,Administrator")] public async Task<IHttpActionResult> RateCards(int id) { return Ok(await _a.RateCardsAsync(Actor, id)); }
        [HttpPost, Route("customers"), TamsAuthorize(Roles = R.Admin)] public async Task<IHttpActionResult> CreateCustomer([FromBody] CustomerRequest body) { if (body != null) body.CustomerId = null; return Created(await _s.SaveCustomerAsync(Actor, body)); }
        [HttpPut, Route("customers/{id:int}"), TamsAuthorize(Roles = R.Admin)] public async Task<IHttpActionResult> UpdateCustomer(int id, [FromBody] CustomerRequest body) { if (body != null) body.CustomerId = id; return Ok(await _s.SaveCustomerAsync(Actor, body)); }
        [HttpGet, Route("departments"), TamsAuthorize(Roles = R.Staff)] public async Task<IHttpActionResult> Departments() { return Ok(await _s.DepartmentsAsync(Actor)); }
        [HttpPost, Route("departments"), TamsAuthorize(Roles = "HRManager,Administrator")] public async Task<IHttpActionResult> CreateDepartment([FromBody] DepartmentRequest body) { if (body != null) body.DepartmentId = null; return Created(await _s.SaveDepartmentAsync(Actor, body)); }
        [HttpPut, Route("departments/{id:int}"), TamsAuthorize(Roles = "HRManager,Administrator")] public async Task<IHttpActionResult> UpdateDepartment(int id, [FromBody] DepartmentRequest body) { if (body != null) body.DepartmentId = id; return Ok(await _s.SaveDepartmentAsync(Actor, body)); }
        [HttpGet, Route("locations"), TamsAuthorize(Roles = R.Staff)] public async Task<IHttpActionResult> Locations() { return Ok(await _s.LocationsAsync(Actor)); }
        [HttpGet, Route("sources"), TamsAuthorize(Roles = "Candidate,Recruiter,HRManager,Administrator")] public async Task<IHttpActionResult> Sources() { return Ok(await _s.SourcesAsync(Actor)); }
        /// <summary>Active staff users (id, name, staff roles) for interview-panel pickers. No e-mail addresses.</summary>
        [HttpGet, Route("staff-directory"), TamsAuthorize(Roles = R.Staff)] public async Task<IHttpActionResult> StaffDirectory() { return Ok(await _s.StaffDirectoryAsync(Actor)); }
    }

    [RoutePrefix("api/v1")]
    public sealed class NotificationsController : ApiBase
    {
        private readonly NotificationService _s; private readonly DashboardService _d;
        public NotificationsController(NotificationService s, DashboardService d) { _s = s; _d = d; }
        [HttpGet, Route("notifications")] public async Task<IHttpActionResult> List(bool unreadOnly = false, int top = 30) { return Ok(await _s.ListAsync(Actor, unreadOnly, top)); }
        [HttpPost, Route("notifications/read-all")] public async Task<IHttpActionResult> ReadAll() { await _s.MarkReadAsync(Actor, null); return Done(); }
        [HttpPost, Route("notifications/{id:long}/read")] public async Task<IHttpActionResult> Read(long id) { await _s.MarkReadAsync(Actor, id); return Done(); }
        [HttpGet, Route("dashboards/{role}")] public async Task<IHttpActionResult> Dashboard(string role) { return Ok(await _d.MetricsAsync(Actor, role)); }
    }
}
