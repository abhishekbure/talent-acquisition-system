using System;
using System.Threading.Tasks;
using System.Web.Http;
using TalentAcquisition.Business;
using TalentAcquisition.Models;

namespace TalentAcquisition.API.Controllers
{
    [RoutePrefix("api/v1/candidates")]
    public sealed class CandidatesController : ApiBase
    {
        private readonly CandidateService _s;
        public CandidatesController(CandidateService s) { _s = s; }
        // own profile (Candidate)
        [HttpGet, Route("me"), TamsAuthorize(Roles = R.Candidate)] public async Task<IHttpActionResult> Me() { return Ok(await _s.GetAsync(Actor, null)); }
        [HttpPut, Route("me"), TamsAuthorize(Roles = R.Candidate)] public async Task<IHttpActionResult> UpdateMe([FromBody] CandidateUpdateRequest body) { if (body != null) { body.CandidateId = null; body.Status = null; } return Ok(await _s.UpdateAsync(Actor, body)); }
        [HttpPost, Route("me/skills"), TamsAuthorize(Roles = R.Candidate)] public async Task<IHttpActionResult> AddMySkill([FromBody] SkillRequest body) { await _s.AddSkillAsync(Actor, null, body); return Done(); }
        [HttpDelete, Route("me/skills/{skill}"), TamsAuthorize(Roles = R.Candidate)] public async Task<IHttpActionResult> RemoveMySkill(string skill) { await _s.RemoveSkillAsync(Actor, null, skill); return Done(); }
        // shared candidate master (staff)
        [HttpGet, Route(""), TamsAuthorize(Roles = R.Staff)] public async Task<IHttpActionResult> Search(string q = null, string skills = null, decimal? minExp = null, decimal? maxExp = null, string status = null, int page = 1, int pageSize = 25) { return Ok(await _s.SearchAsync(Actor, q, skills, minExp, maxExp, status, page, pageSize)); }
        [HttpGet, Route("{id:int}"), TamsAuthorize(Roles = R.Staff)] public async Task<IHttpActionResult> Get(int id) { return Ok(await _s.GetAsync(Actor, id)); }
        [HttpPost, Route(""), TamsAuthorize(Roles = R.Staff)] public async Task<IHttpActionResult> Create([FromBody] CandidateCreateRequest body) { return Created(await _s.CreateAsync(Actor, body)); }
        [HttpPut, Route("{id:int}"), TamsAuthorize(Roles = R.Staff)] public async Task<IHttpActionResult> Update(int id, [FromBody] CandidateUpdateRequest body) { if (body != null) body.CandidateId = id; return Ok(await _s.UpdateAsync(Actor, body)); }
        [HttpPost, Route("{id:int}/skills"), TamsAuthorize(Roles = R.Staff)] public async Task<IHttpActionResult> AddSkill(int id, [FromBody] SkillRequest body) { await _s.AddSkillAsync(Actor, id, body); return Done(); }
        [HttpDelete, Route("{id:int}/skills/{skill}"), TamsAuthorize(Roles = R.Staff)] public async Task<IHttpActionResult> RemoveSkill(int id, string skill) { await _s.RemoveSkillAsync(Actor, id, skill); return Done(); }
    }

    /// <summary>Department hiring requests (hr.EmployeeRequisitions).</summary>
    [RoutePrefix("api/v1/requisitions")]
    public sealed class RequisitionsController : ApiBase
    {
        private readonly RecruitmentService _s;
        public RequisitionsController(RecruitmentService s) { _s = s; }
        [HttpGet, Route(""), TamsAuthorize(Roles = R.Staff)] public async Task<IHttpActionResult> List(string status = null, int page = 1, int pageSize = 25) { return Ok(await _s.ListHiringRequestsAsync(Actor, status, page, pageSize)); }
        [HttpGet, Route("{id:int}"), TamsAuthorize(Roles = R.Staff)] public async Task<IHttpActionResult> Get(int id) { return Ok(await _s.GetHiringRequestAsync(Actor, id)); }
        [HttpPost, Route(""), TamsAuthorize(Roles = "HRManager,Administrator")] public async Task<IHttpActionResult> Create([FromBody] HiringRequestCreate body) { return Created(await _s.CreateHiringRequestAsync(Actor, body)); }
        [HttpPost, Route("{id:int}/submit"), TamsAuthorize(Roles = "HRManager,Administrator")] public async Task<IHttpActionResult> Submit(int id) { await _s.SubmitHiringRequestAsync(Actor, id); return Done(); }
        [HttpPost, Route("{id:int}/approve"), TamsAuthorize(Roles = "HRManager,Administrator")] public async Task<IHttpActionResult> Approve(int id, [FromBody] DecisionRequest body) { await _s.DecideHiringRequestAsync(Actor, id, true, body); return Done(); }
        [HttpPost, Route("{id:int}/reject"), TamsAuthorize(Roles = "HRManager,Administrator")] public async Task<IHttpActionResult> Reject(int id, [FromBody] DecisionRequest body) { await _s.DecideHiringRequestAsync(Actor, id, false, body); return Done(); }
    }

    [RoutePrefix("api/v1")]
    public sealed class JobsController : ApiBase
    {
        private readonly RecruitmentService _s;
        public JobsController(RecruitmentService s) { _s = s; }
        [HttpGet, Route("jobs"), TamsAuthorize(Roles = R.Staff)] public async Task<IHttpActionResult> List(string status = null, string q = null, int page = 1, int pageSize = 25) { return Ok(await _s.ListJobsAsync(Actor, status, q, page, pageSize)); }
        [HttpGet, Route("jobs/{id:int}"), TamsAuthorize(Roles = R.Staff)] public async Task<IHttpActionResult> Get(int id) { return Ok(await _s.GetJobAsync(Actor, id)); }
        [HttpPost, Route("jobs"), TamsAuthorize(Roles = R.Staff)] public async Task<IHttpActionResult> Create([FromBody] JobCreateRequest body) { return Created(await _s.CreateJobAsync(Actor, body)); }
        [HttpPost, Route("jobs/{id:int}/approve"), TamsAuthorize(Roles = "HRManager,Administrator")] public async Task<IHttpActionResult> Approve(int id, [FromBody] DecisionRequest body) { await _s.DecideJobAsync(Actor, id, true, body); return Done(); }
        [HttpPost, Route("jobs/{id:int}/reject"), TamsAuthorize(Roles = "HRManager,Administrator")] public async Task<IHttpActionResult> Reject(int id, [FromBody] DecisionRequest body) { await _s.DecideJobAsync(Actor, id, false, body); return Done(); }
        [HttpPost, Route("jobs/{id:int}/publish"), TamsAuthorize(Roles = R.Staff)] public async Task<IHttpActionResult> Publish(int id, [FromBody] PublishJobRequest body) { return Ok(await _s.PublishJobAsync(Actor, id, body)); }
        [HttpPost, Route("jobs/{id:int}/close"), TamsAuthorize(Roles = R.Staff)] public async Task<IHttpActionResult> Close(int id, [FromBody] ReasonRequest body) { await _s.CloseJobAsync(Actor, id, body); return Done(); }
        [HttpGet, Route("public/jobs"), TamsAuthorize(Roles = "Candidate,Recruiter,HRManager,Administrator")] public async Task<IHttpActionResult> Published(string q = null, int? departmentId = null, int page = 1, int pageSize = 20) { return Ok(await _s.ListPublishedAsync(Actor, q, departmentId, page, pageSize)); }
        [HttpGet, Route("public/jobs/{postingId:int}"), TamsAuthorize(Roles = "Candidate,Recruiter,HRManager,Administrator")] public async Task<IHttpActionResult> PublishedOne(int postingId) { return Ok(await _s.GetPublishedAsync(Actor, postingId)); }
    }

    [RoutePrefix("api/v1/applications")]
    public sealed class ApplicationsController : ApiBase
    {
        private readonly ApplicationService _s;
        public ApplicationsController(ApplicationService s) { _s = s; }
        [HttpPost, Route(""), TamsAuthorize(Roles = R.Candidate)] public async Task<IHttpActionResult> Apply([FromBody] ApplyRequest body) { return Created(await _s.ApplyAsync(Actor, body)); }
        [HttpGet, Route("mine"), TamsAuthorize(Roles = R.Candidate)] public async Task<IHttpActionResult> Mine() { return Ok(await _s.MineAsync(Actor)); }
        [HttpGet, Route("mine/submissions"), TamsAuthorize(Roles = "Candidate,Contractor")] public async Task<IHttpActionResult> MySubmissions() { return Ok(await _s.MySubmissionsAsync(Actor)); }
        [HttpPost, Route("{id:int}/withdraw"), TamsAuthorize(Roles = R.Candidate)] public async Task<IHttpActionResult> Withdraw(int id, [FromBody] ReasonRequest body) { await _s.WithdrawAsync(Actor, id, body); return Done(); }
        [HttpGet, Route("{id:int}"), TamsAuthorize(Roles = "Candidate,Recruiter,HRManager,Administrator")] public async Task<IHttpActionResult> Get(int id) { return Ok(await _s.GetAsync(Actor, id)); }
        [HttpGet, Route(""), TamsAuthorize(Roles = R.Staff)] public async Task<IHttpActionResult> List(int? jobId = null, string status = null, string q = null, int page = 1, int pageSize = 25) { return Ok(await _s.ListAsync(Actor, jobId, status, q, page, pageSize)); }
        [HttpPost, Route("{id:int}/status"), TamsAuthorize(Roles = "Recruiter,Administrator")] public async Task<IHttpActionResult> Status(int id, [FromBody] StatusChangeRequest body) { return Ok(await _s.ChangeStatusAsync(Actor, id, body)); }
        [HttpPost, Route("{id:int}/shortlist"), TamsAuthorize(Roles = "Recruiter,Administrator")] public async Task<IHttpActionResult> Shortlist(int id, [FromBody] ReasonRequest body) { await _s.ShortlistAsync(Actor, id, body); return Done(); }
    }

    [RoutePrefix("api/v1/interviews")]
    public sealed class InterviewsController : ApiBase
    {
        private readonly InterviewService _s;
        public InterviewsController(InterviewService s) { _s = s; }
        [HttpGet, Route("")] public async Task<IHttpActionResult> List(DateTime? from = null, DateTime? to = null, string status = null) { return Ok(await _s.ListAsync(Actor, from, to, status)); }
        [HttpGet, Route("{id:int}")] public async Task<IHttpActionResult> Get(int id) { return Ok(await _s.GetAsync(Actor, id)); }
        [HttpPost, Route(""), TamsAuthorize(Roles = "Recruiter,HRManager,Administrator,Customer")] public async Task<IHttpActionResult> Schedule([FromBody] ScheduleInterviewRequest body) { return Created(await _s.ScheduleAsync(Actor, body)); }
        [HttpPut, Route("{id:int}/reschedule"), TamsAuthorize(Roles = "Recruiter,HRManager,Administrator,Customer")] public async Task<IHttpActionResult> Reschedule(int id, [FromBody] RescheduleInterviewRequest body) { return Ok(await _s.RescheduleAsync(Actor, id, body)); }
        [HttpPost, Route("{id:int}/cancel"), TamsAuthorize(Roles = "Recruiter,HRManager,Administrator,Customer")] public async Task<IHttpActionResult> Cancel(int id, [FromBody] ReasonRequest body) { await _s.CancelAsync(Actor, id, body); return Done(); }
        [HttpPost, Route("{id:int}/feedback"), TamsAuthorize(Roles = "Recruiter,HRManager,Administrator,Customer")] public async Task<IHttpActionResult> Feedback(int id, [FromBody] FeedbackRequest body) { await _s.FeedbackAsync(Actor, id, body); return Done(); }
    }

    [RoutePrefix("api/v1/offers")]
    public sealed class OffersController : ApiBase
    {
        private readonly OfferService _s;
        public OffersController(OfferService s) { _s = s; }
        [HttpGet, Route(""), TamsAuthorize(Roles = R.Staff)] public async Task<IHttpActionResult> List(string status = null) { return Ok(await _s.ListAsync(Actor, status)); }
        [HttpGet, Route("mine"), TamsAuthorize(Roles = R.Candidate)] public async Task<IHttpActionResult> Mine() { return Ok(await _s.MineAsync(Actor)); }
        [HttpPost, Route(""), TamsAuthorize(Roles = R.Staff)] public async Task<IHttpActionResult> Create([FromBody] CreateOfferRequest body) { return Created(await _s.CreateAsync(Actor, body)); }
        [HttpPost, Route("{id:int}/approve"), TamsAuthorize(Roles = "HRManager,Administrator")] public async Task<IHttpActionResult> Approve(int id, [FromBody] DecisionRequest body) { await _s.DecideAsync(Actor, id, true, body); return Done(); }
        [HttpPost, Route("{id:int}/reject"), TamsAuthorize(Roles = "HRManager,Administrator")] public async Task<IHttpActionResult> Reject(int id, [FromBody] DecisionRequest body) { await _s.DecideAsync(Actor, id, false, body); return Done(); }
        [HttpPost, Route("{id:int}/send"), TamsAuthorize(Roles = R.Staff)] public async Task<IHttpActionResult> Send(int id) { await _s.SendAsync(Actor, id); return Done(); }
        [HttpPost, Route("{id:int}/accept"), TamsAuthorize(Roles = R.Candidate)] public async Task<IHttpActionResult> Accept(int id, [FromBody] OfferResponseRequest body) { return Ok(await _s.RespondAsync(Actor, id, true, body)); }
        [HttpPost, Route("{id:int}/decline"), TamsAuthorize(Roles = R.Candidate)] public async Task<IHttpActionResult> Decline(int id, [FromBody] OfferResponseRequest body) { return Ok(await _s.RespondAsync(Actor, id, false, body)); }
    }

    [RoutePrefix("api/v1/employees"), TamsAuthorize(Roles = "HRManager,Administrator")]
    public sealed class EmployeesController : ApiBase
    {
        private readonly HrService _s;
        public EmployeesController(HrService s) { _s = s; }
        [HttpGet, Route("")] public async Task<IHttpActionResult> List(string status = null, int? departmentId = null, string q = null, int page = 1, int pageSize = 25) { return Ok(await _s.ListAsync(Actor, status, departmentId, q, page, pageSize)); }
        [HttpGet, Route("{id:int}")] public async Task<IHttpActionResult> Get(int id) { return Ok(await _s.GetAsync(Actor, id)); }
        [HttpPost, Route("{id:int}/onboarding/{taskId:int}/complete")] public async Task<IHttpActionResult> Complete(int id, int taskId, [FromBody] CompleteTaskRequest body) { return Ok(await _s.CompleteTaskAsync(Actor, taskId, body)); }
    }
}
