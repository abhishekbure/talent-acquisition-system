using System.Threading.Tasks;
using System.Web.Http;
using TalentAcquisition.Business;
using TalentAcquisition.Models;

namespace TalentAcquisition.API.Controllers
{
    /// <summary>Customer staffing requests and candidate submissions. Customer scope is enforced in every procedure.</summary>
    [RoutePrefix("api/v1/staffing")]
    public sealed class StaffingController : ApiBase
    {
        private readonly StaffingService _s;
        public StaffingController(StaffingService s) { _s = s; }
        [HttpPost, Route("requests"), TamsAuthorize(Roles = "Customer,Recruiter,Administrator")] public async Task<IHttpActionResult> Create([FromBody] StaffingRequestCreate body) { return Created(await _s.CreateRequestAsync(Actor, body)); }
        [HttpGet, Route("requests"), TamsAuthorize(Roles = "Customer,Recruiter,Administrator")] public async Task<IHttpActionResult> List(int? customerId = null, string status = null) { return Ok(await _s.ListRequestsAsync(Actor, customerId, status)); }
        [HttpPost, Route("requests/{id:int}/accept"), TamsAuthorize(Roles = "Recruiter,Administrator")] public async Task<IHttpActionResult> Accept(int id, [FromBody] AcceptRequest body) { await _s.AcceptRequestAsync(Actor, id, body); return Done(); }
        [HttpPost, Route("requests/{id:int}/cancel"), TamsAuthorize(Roles = "Customer,Administrator")] public async Task<IHttpActionResult> Cancel(int id, [FromBody] ReasonRequest body) { await _s.CancelRequestAsync(Actor, id, body); return Done(); }
        [HttpGet, Route("requests/{id:int}/submissions"), TamsAuthorize(Roles = "Customer,Recruiter,Administrator")] public async Task<IHttpActionResult> Submissions(int id) { return Ok(await _s.SubmissionsAsync(Actor, id)); }
        [HttpPost, Route("requests/{id:int}/submissions"), TamsAuthorize(Roles = "Recruiter,Administrator")] public async Task<IHttpActionResult> Submit(int id, [FromBody] SubmitCandidateRequest body) { return Created(await _s.SubmitCandidateAsync(Actor, id, body)); }
        [HttpPost, Route("submissions/{id:int}/decision"), TamsAuthorize(Roles = R.Customer)] public async Task<IHttpActionResult> Decide(int id, [FromBody] DecideSubmissionRequest body) { await _s.DecideSubmissionAsync(Actor, id, body); return Done(); }
        [HttpPost, Route("submissions/{id:int}/withdraw"), TamsAuthorize(Roles = "Recruiter,Administrator")] public async Task<IHttpActionResult> Withdraw(int id) { await _s.WithdrawSubmissionAsync(Actor, id); return Done(); }
    }

    [RoutePrefix("api/v1/contractors")]
    public sealed class ContractorsController : ApiBase
    {
        private readonly StaffingService _s;
        public ContractorsController(StaffingService s) { _s = s; }
        [HttpGet, Route(""), TamsAuthorize(Roles = "Customer,Recruiter,Administrator")] public async Task<IHttpActionResult> List(string status = null, string q = null) { return Ok(await _s.ContractorsAsync(Actor, status, q)); }
        [HttpGet, Route("me"), TamsAuthorize(Roles = R.Contractor)] public async Task<IHttpActionResult> Me() { return Ok(await _s.MyContractorAsync(Actor)); }
        [HttpPost, Route(""), TamsAuthorize(Roles = "Recruiter,Administrator")] public async Task<IHttpActionResult> Create([FromBody] CreateContractorRequest body) { return Created(await _s.CreateContractorAsync(Actor, body)); }
        [HttpGet, Route("compliance"), TamsAuthorize(Roles = "Contractor,Recruiter,Administrator")] public async Task<IHttpActionResult> Compliance(int? contractorId = null, int? expiringWithinDays = null) { return Ok(await _s.ComplianceAsync(Actor, contractorId, expiringWithinDays)); }
    }

    [RoutePrefix("api/v1")]
    public sealed class ContractsController : ApiBase
    {
        private readonly ContractService _s;
        public ContractsController(ContractService s) { _s = s; }
        [HttpGet, Route("contracts"), TamsAuthorize(Roles = "Contractor,Customer,Recruiter,Administrator")] public async Task<IHttpActionResult> List(string status = null, int? customerId = null) { return Ok(await _s.ListAsync(Actor, status, customerId)); }
        [HttpGet, Route("contracts/{id:int}"), TamsAuthorize(Roles = "Contractor,Customer,Recruiter,Administrator")] public async Task<IHttpActionResult> Get(int id) { return Ok(await _s.GetAsync(Actor, id)); }
        [HttpPost, Route("contracts"), TamsAuthorize(Roles = "Recruiter,Administrator")] public async Task<IHttpActionResult> Create([FromBody] CreateContractRequest body) { return Created(await _s.CreateAsync(Actor, body)); }
        [HttpPost, Route("contracts/{id:int}/renew"), TamsAuthorize(Roles = "Recruiter,Administrator")] public async Task<IHttpActionResult> Renew(int id, [FromBody] RenewContractRequest body) { return Ok(await _s.RenewAsync(Actor, id, body)); }
        [HttpPost, Route("contracts/{id:int}/terminate"), TamsAuthorize(Roles = "Recruiter,Administrator")] public async Task<IHttpActionResult> Terminate(int id, [FromBody] TerminateRequest body) { await _s.TerminateAsync(Actor, id, body); return Done(); }
        [HttpGet, Route("assignments"), TamsAuthorize(Roles = "Contractor,Customer,Recruiter,Administrator")] public async Task<IHttpActionResult> Assignments(string status = null) { return Ok(await _s.AssignmentsAsync(Actor, status)); }
        [HttpPost, Route("assignments"), TamsAuthorize(Roles = "Recruiter,Administrator")] public async Task<IHttpActionResult> CreateAssignment([FromBody] CreateAssignmentRequest body) { return Created(await _s.CreateAssignmentAsync(Actor, body)); }
    }

    [RoutePrefix("api/v1/timesheets")]
    public sealed class TimesheetsController : ApiBase
    {
        private readonly TimesheetService _s;
        public TimesheetsController(TimesheetService s) { _s = s; }
        [HttpGet, Route(""), TamsAuthorize(Roles = "Contractor,Customer,Recruiter,Administrator")] public async Task<IHttpActionResult> List(string status = null, int? customerId = null, int? contractorId = null) { return Ok(await _s.ListAsync(Actor, status, customerId, contractorId)); }
        [HttpGet, Route("mine"), TamsAuthorize(Roles = R.Contractor)] public async Task<IHttpActionResult> Mine(int top = 20) { return Ok(await _s.MineAsync(Actor, top)); }
        [HttpGet, Route("pending"), TamsAuthorize(Roles = "Customer,Recruiter,Administrator")] public async Task<IHttpActionResult> Pending(int? customerId = null) { return Ok(await _s.PendingAsync(Actor, customerId)); }
        [HttpGet, Route("{id:int}"), TamsAuthorize(Roles = "Contractor,Customer,Recruiter,Administrator")] public async Task<IHttpActionResult> Get(int id) { return Ok(await _s.GetAsync(Actor, id)); }
        [HttpPut, Route("entries"), TamsAuthorize(Roles = R.Contractor)] public async Task<IHttpActionResult> Save([FromBody] SaveTimesheetRequest body) { return Ok(await _s.SaveAsync(Actor, body)); }
        [HttpPost, Route("{id:int}/submit"), TamsAuthorize(Roles = R.Contractor)] public async Task<IHttpActionResult> Submit(int id) { await _s.SubmitAsync(Actor, id); return Done(); }
        [HttpPost, Route("{id:int}/approve"), TamsAuthorize(Roles = R.Customer)] public async Task<IHttpActionResult> Approve(int id, [FromBody] ApproveTimesheetRequest body) { await _s.ApproveAsync(Actor, id, body); return Done(); }
        [HttpPost, Route("{id:int}/reject"), TamsAuthorize(Roles = R.Customer)] public async Task<IHttpActionResult> Reject(int id, [FromBody] RejectTimesheetRequest body) { await _s.RejectAsync(Actor, id, body); return Done(); }
    }

    [RoutePrefix("api/v1/invoices")]
    public sealed class InvoicesController : ApiBase
    {
        private readonly BillingService _s;
        public InvoicesController(BillingService s) { _s = s; }
        [HttpGet, Route(""), TamsAuthorize(Roles = "Customer,Recruiter,Administrator")] public async Task<IHttpActionResult> List(int? customerId = null) { return Ok(await _s.ListAsync(Actor, customerId)); }
        [HttpGet, Route("{id:int}"), TamsAuthorize(Roles = "Customer,Recruiter,Administrator")] public async Task<IHttpActionResult> Get(int id) { return Ok(await _s.GetAsync(Actor, id)); }
        [HttpPost, Route("generate"), TamsAuthorize(Roles = "Recruiter,Administrator")] public async Task<IHttpActionResult> Generate([FromBody] GenerateInvoiceRequest body) { return Created(await _s.GenerateAsync(Actor, body)); }
        [HttpPost, Route("{id:int}/issue"), TamsAuthorize(Roles = "Recruiter,Administrator")] public async Task<IHttpActionResult> Issue(int id) { await _s.IssueAsync(Actor, id); return Done(); }
        [HttpPost, Route("{id:int}/void"), TamsAuthorize(Roles = "Recruiter,Administrator")] public async Task<IHttpActionResult> Void(int id, [FromBody] VoidRequest body) { await _s.VoidAsync(Actor, id, body); return Done(); }
        [HttpPost, Route("{id:int}/payments"), TamsAuthorize(Roles = "Recruiter,Administrator")] public async Task<IHttpActionResult> Pay(int id, [FromBody] RecordPaymentRequest body) { return Created(await _s.PayAsync(Actor, id, body)); }
    }
}
