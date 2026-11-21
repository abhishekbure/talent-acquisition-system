using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using TalentAcquisition.Common;
using TalentAcquisition.Data;
using TalentAcquisition.Models;

// Business services: input validation, shaping of multi-result reads, then one stored-procedure call each.
// Authorisation is enforced twice: [Authorize(Roles=...)] at the API edge and again (with data SCOPE) inside every procedure.
namespace TalentAcquisition.Business
{
    internal static class Shape
    {
        public static PagedResult Paged(List<Row> rows, int page, int size)
        {
            int total = rows.Count > 0 && rows[0].ContainsKey("TotalCount") ? rows[0].Int("TotalCount") : rows.Count;
            foreach (var r in rows) r.Remove("TotalCount");
            return new PagedResult { Items = rows, Total = total, Page = page, PageSize = size };
        }
        public static Row First(List<List<Row>> sets) { return sets.Count > 0 && sets[0].Count > 0 ? sets[0][0] : null; }
        public static List<Row> Set(List<List<Row>> sets, int i) { return sets.Count > i ? sets[i] : new List<Row>(); }
        public static Row NotNull(Row r, string what) { if (r == null) throw new ApiException(404, "not_found", what + " not found."); return r; }
        public static T Body<T>(T body) where T : class { if (body == null) throw new ApiException(400, "validation", "A request body is required."); return body; }
        public static void Dates(DateTime from, DateTime to, string what) { if (to < from) throw new ApiException(400, "validation", what + ": the end cannot be before the start."); }
    }

    public sealed class UserService
    {
        private readonly AdminRepository _r;
        public UserService(AdminRepository r) { _r = r; }
        public async Task<PagedResult> ListAsync(int actor, string q, string role, bool? active, int page, int size) { Guard.Page(ref page, ref size); return Shape.Paged(await _r.ListUsersAsync(actor, q, role, active, page, size), page, size); }
        public async Task<Row> GetAsync(int actor, int id) { return Shape.NotNull(await _r.GetUserAsync(actor, id), "User"); }
        public async Task<Row> CreateAsync(int actor, CreateUserRequest b)
        {
            Shape.Body(b); b.Email = Guard.EmailAddress(b.Email); PasswordPolicy.Validate(b.TemporaryPassword);
            byte[] hash, salt; PasswordHasher.Hash(b.TemporaryPassword, out hash, out salt);
            return await _r.CreateUserAsync(actor, b, hash, salt);
        }
        public Task SetActiveAsync(int actor, int id, bool active) { return _r.SetUserActiveAsync(actor, id, active); }
        public Task AssignRoleAsync(int actor, int id, AssignRoleRequest b) { Shape.Body(b); return _r.AssignRoleAsync(actor, id, b.RoleName, b.Add); }
    }

    public sealed class AdminService
    {
        private readonly AdminRepository _r;
        public AdminService(AdminRepository r) { _r = r; }
        public async Task<PagedResult> AuditAsync(int actor, string table, string record, DateTime? from, DateTime? to, int page, int size) { Guard.Page(ref page, ref size); return Shape.Paged(await _r.AuditLogsAsync(actor, table, record, from, to, page, size), page, size); }
        public async Task<PagedResult> LoginsAsync(int actor, string email, bool? success, int page, int size) { Guard.Page(ref page, ref size); return Shape.Paged(await _r.LoginHistoryAsync(actor, email, success, page, size), page, size); }
        public Task<List<Row>> JobsAsync(int actor) { return _r.JobsAsync(actor); }
        public Task<List<Row>> JobHistoryAsync(int actor, int id, int top) { return _r.JobHistoryAsync(actor, id, top); }
        public Task<List<Row>> JobRunDetailsAsync(int actor, long executionId) { return _r.JobRunDetailsAsync(actor, executionId); }
        public Task<List<Row>> RateCardsAsync(int actor, int? customerId) { return _r.RateCardsAsync(actor, customerId); }
        public Task<Row> UpsertRateCardAsync(int actor, RateCardRequest b) { Shape.Body(b); if (b.EffectiveTo.HasValue) Shape.Dates(b.EffectiveFrom, b.EffectiveTo.Value, "Rate card"); return _r.UpsertRateCardAsync(actor, b); }
    }

    public sealed class OrganizationService
    {
        private readonly OrgRepository _r;
        public OrganizationService(OrgRepository r) { _r = r; }
        public Task<List<Row>> CustomersAsync(int actor) { return _r.CustomersAsync(actor); }
        public async Task<object> CustomerAsync(int actor, int id) { var s = await _r.CustomerAsync(actor, id); return new { customer = Shape.NotNull(Shape.First(s), "Customer"), contacts = Shape.Set(s, 1) }; }
        public Task<Row> SaveCustomerAsync(int actor, CustomerRequest b) { Shape.Body(b); return _r.UpsertCustomerAsync(actor, b); }
        public Task<Row> BalanceAsync(int actor, int? id) { return _r.BalanceAsync(actor, id); }
        public Task<List<Row>> DepartmentsAsync(int actor) { return _r.DepartmentsAsync(actor); }
        public Task<Row> SaveDepartmentAsync(int actor, DepartmentRequest b) { Shape.Body(b); return _r.UpsertDepartmentAsync(actor, b); }
        public Task<List<Row>> LocationsAsync(int actor) { return _r.LocationsAsync(actor); }
        public Task<List<Row>> SourcesAsync(int actor) { return _r.SourcesAsync(actor); }
        public Task<List<Row>> StaffDirectoryAsync(int actor) { return _r.StaffDirectoryAsync(actor); }
    }

    public sealed class CandidateService
    {
        private readonly CandidateRepository _r;
        public CandidateService(CandidateRepository r) { _r = r; }
        public async Task<object> GetAsync(int actor, int? id)
        {
            var s = await _r.GetAsync(actor, id);
            return new { profile = Shape.NotNull(Shape.First(s), "Candidate"), skills = Shape.Set(s, 1), education = Shape.Set(s, 2), experience = Shape.Set(s, 3) };
        }
        public Task<Row> CreateAsync(int actor, CandidateCreateRequest b) { Shape.Body(b); b.Email = Guard.EmailAddress(b.Email); return _r.CreateAsync(actor, b); }
        public Task<Row> UpdateAsync(int actor, CandidateUpdateRequest b) { Shape.Body(b); return _r.UpdateAsync(actor, b); }
        public async Task<PagedResult> SearchAsync(int actor, string q, string skills, decimal? min, decimal? max, string status, int page, int size)
        { Guard.Page(ref page, ref size); return Shape.Paged(await _r.SearchAsync(actor, q, skills, min, max, status, page, size), page, size); }
        public Task AddSkillAsync(int actor, int? id, SkillRequest b) { Shape.Body(b); return _r.AddSkillAsync(actor, id, b); }
        public Task RemoveSkillAsync(int actor, int? id, string skill) { Guard.Required(skill, "Skill"); return _r.RemoveSkillAsync(actor, id, skill); }
    }

    public sealed class RecruitmentService
    {
        private readonly RecruitmentRepository _r;
        public RecruitmentService(RecruitmentRepository r) { _r = r; }
        public Task<Row> CreateHiringRequestAsync(int actor, HiringRequestCreate b) { Shape.Body(b); return _r.CreateHiringRequestAsync(actor, b); }
        public Task SubmitHiringRequestAsync(int actor, int id) { return _r.SubmitHiringRequestAsync(actor, id); }
        public Task DecideHiringRequestAsync(int actor, int id, bool approve, DecisionRequest b) { return _r.DecideHiringRequestAsync(actor, id, approve ? "Approved" : "Rejected", b == null ? null : b.Comments); }
        public async Task<PagedResult> ListHiringRequestsAsync(int actor, string status, int page, int size) { Guard.Page(ref page, ref size); return Shape.Paged(await _r.ListHiringRequestsAsync(actor, status, page, size), page, size); }
        public async Task<object> GetHiringRequestAsync(int actor, int id) { var s = await _r.GetHiringRequestAsync(actor, id); return new { request = Shape.NotNull(Shape.First(s), "Hiring request"), approvals = Shape.Set(s, 1), jobs = Shape.Set(s, 2) }; }
        public Task<Row> CreateJobAsync(int actor, JobCreateRequest b) { Shape.Body(b); return _r.CreateJobAsync(actor, b); }
        public Task DecideJobAsync(int actor, int id, bool approve, DecisionRequest b) { return _r.DecideJobAsync(actor, id, approve ? "Approved" : "Rejected", b == null ? null : b.Comments); }
        public Task<Row> PublishJobAsync(int actor, int id, PublishJobRequest b) { return _r.PublishJobAsync(actor, id, b ?? new PublishJobRequest()); }
        public Task CloseJobAsync(int actor, int id, ReasonRequest b) { return _r.CloseJobAsync(actor, id, b == null ? null : b.Reason); }
        public async Task<PagedResult> ListJobsAsync(int actor, string status, string q, int page, int size) { Guard.Page(ref page, ref size); return Shape.Paged(await _r.ListJobsAsync(actor, status, q, page, size), page, size); }
        public async Task<object> GetJobAsync(int actor, int id) { var s = await _r.GetJobAsync(actor, id); return new { job = Shape.NotNull(Shape.First(s), "Job"), skills = Shape.Set(s, 1), postings = Shape.Set(s, 2), approvals = Shape.Set(s, 3) }; }
        public async Task<PagedResult> ListPublishedAsync(int actor, string q, int? dept, int page, int size) { Guard.Page(ref page, ref size, 100); return Shape.Paged(await _r.ListPublishedAsync(actor, q, dept, page, size), page, size); }
        public async Task<object> GetPublishedAsync(int actor, int postingId) { var s = await _r.GetPublishedAsync(actor, postingId); return new { job = Shape.NotNull(Shape.First(s), "Job posting"), skills = Shape.Set(s, 1) }; }
    }

    public sealed class ApplicationService
    {
        private readonly ApplicationRepository _r;
        public ApplicationService(ApplicationRepository r) { _r = r; }
        public Task<Row> ApplyAsync(int actor, ApplyRequest b) { Shape.Body(b); Guard.Positive(b.JobPostingId, "JobPostingId"); return _r.CreateAsync(actor, b); }
        public Task WithdrawAsync(int actor, int id, ReasonRequest b) { return _r.WithdrawAsync(actor, id, b == null ? null : b.Reason); }
        public Task<Row> ChangeStatusAsync(int actor, int id, StatusChangeRequest b) { Shape.Body(b); return _r.ChangeStatusAsync(actor, id, b); }
        public Task ShortlistAsync(int actor, int id, ReasonRequest b) { return _r.ShortlistAsync(actor, id, b == null ? null : b.Reason); }
        public Task<List<Row>> MineAsync(int actor) { return _r.ListMineAsync(actor); }
        public Task<List<Row>> MySubmissionsAsync(int actor) { return _r.ListMySubmissionsAsync(actor); }
        public async Task<object> GetAsync(int actor, int id) { var s = await _r.GetAsync(actor, id); return new { application = Shape.NotNull(Shape.First(s), "Application"), history = Shape.Set(s, 1), interviews = Shape.Set(s, 2), offers = Shape.Set(s, 3) }; }
        public async Task<PagedResult> ListAsync(int actor, int? jobId, string status, string q, int page, int size) { Guard.Page(ref page, ref size); return Shape.Paged(await _r.ListAsync(actor, jobId, status, q, page, size), page, size); }
    }

    public sealed class InterviewService
    {
        private readonly InterviewRepository _r;
        public InterviewService(InterviewRepository r) { _r = r; }
        public Task<Row> ScheduleAsync(int actor, ScheduleInterviewRequest b)
        {
            Shape.Body(b);
            if ((b.JobApplicationId.HasValue ? 1 : 0) + (b.SubmittedCandidateId.HasValue ? 1 : 0) != 1) throw new ApiException(400, "validation", "Specify exactly one of jobApplicationId or submittedCandidateId.");
            if (b.Panel == null || b.Panel.Count == 0) throw new ApiException(400, "validation", "At least one interviewer is required.");
            b.Panel = b.Panel.Distinct().ToList();          // keeps the caller's order
            if (!b.LeadUserId.HasValue) b.LeadUserId = b.Panel[0];   // the first listed interviewer leads
            return _r.ScheduleAsync(actor, b);
        }
        public Task<Row> RescheduleAsync(int actor, int id, RescheduleInterviewRequest b) { Shape.Body(b); return _r.RescheduleAsync(actor, id, b); }
        public Task CancelAsync(int actor, int id, ReasonRequest b) { return _r.CancelAsync(actor, id, b == null ? null : b.Reason); }
        public Task FeedbackAsync(int actor, int id, FeedbackRequest b) { Shape.Body(b); return _r.FeedbackAsync(actor, id, b); }
        public Task<List<Row>> ListAsync(int actor, DateTime? from, DateTime? to, string status) { return _r.ListAsync(actor, from, to, status); }
        public async Task<object> GetAsync(int actor, int id) { var s = await _r.GetAsync(actor, id); return new { interview = Shape.NotNull(Shape.First(s), "Interview"), panel = Shape.Set(s, 1), feedback = Shape.Set(s, 2) }; }
    }

    public sealed class OfferService
    {
        private readonly OfferRepository _r;
        public OfferService(OfferRepository r) { _r = r; }
        public Task<Row> CreateAsync(int actor, CreateOfferRequest b) { Shape.Body(b); return _r.CreateAsync(actor, b); }
        public Task DecideAsync(int actor, int id, bool approve, DecisionRequest b) { return _r.DecideAsync(actor, id, approve ? "Approved" : "Rejected", b == null ? null : b.Comments); }
        public Task SendAsync(int actor, int id) { return _r.SendAsync(actor, id); }
        public Task<Row> RespondAsync(int actor, int id, bool accept, OfferResponseRequest b) { return _r.RespondAsync(actor, id, accept, b == null ? null : b.Note); }
        public Task<List<Row>> MineAsync(int actor) { return _r.ListMineAsync(actor); }
        public Task<List<Row>> ListAsync(int actor, string status) { return _r.ListAsync(actor, status); }
    }

    public sealed class HrService
    {
        private readonly HrRepository _r;
        public HrService(HrRepository r) { _r = r; }
        public async Task<PagedResult> ListAsync(int actor, string status, int? dept, string q, int page, int size) { Guard.Page(ref page, ref size); return Shape.Paged(await _r.ListEmployeesAsync(actor, status, dept, q, page, size), page, size); }
        public async Task<object> GetAsync(int actor, int id) { var s = await _r.GetEmployeeAsync(actor, id); return new { employee = Shape.NotNull(Shape.First(s), "Employee"), onboarding = Shape.Set(s, 1), history = Shape.Set(s, 2) }; }
        public Task<Row> CompleteTaskAsync(int actor, int taskId, CompleteTaskRequest b) { return _r.CompleteTaskAsync(actor, taskId, b ?? new CompleteTaskRequest()); }
    }

    public sealed class StaffingService
    {
        private readonly StaffingRepository _r;
        public StaffingService(StaffingRepository r) { _r = r; }
        public Task<Row> CreateRequestAsync(int actor, StaffingRequestCreate b) { Shape.Body(b); return _r.CreateRequestAsync(actor, b); }
        public Task AcceptRequestAsync(int actor, int id, AcceptRequest b) { return _r.AcceptRequestAsync(actor, id, b == null ? null : b.AssignedRecruiterUserId); }
        public Task CancelRequestAsync(int actor, int id, ReasonRequest b) { return _r.CancelRequestAsync(actor, id, b == null ? null : b.Reason); }
        public Task<List<Row>> ListRequestsAsync(int actor, int? customerId, string status) { return _r.ListRequestsAsync(actor, customerId, status); }
        public Task<Row> SubmitCandidateAsync(int actor, int requestId, SubmitCandidateRequest b) { Shape.Body(b); return _r.SubmitCandidateAsync(actor, requestId, b); }
        public Task<List<Row>> SubmissionsAsync(int actor, int requestId) { return _r.SubmissionsAsync(actor, requestId); }
        public Task DecideSubmissionAsync(int actor, int id, DecideSubmissionRequest b) { Shape.Body(b); return _r.DecideSubmissionAsync(actor, id, b); }
        public Task WithdrawSubmissionAsync(int actor, int id) { return _r.WithdrawSubmissionAsync(actor, id); }
        public Task<Row> CreateContractorAsync(int actor, CreateContractorRequest b) { Shape.Body(b); return _r.CreateContractorAsync(actor, b); }
        public Task<List<Row>> ContractorsAsync(int actor, string status, string q) { return _r.ListContractorsAsync(actor, status, q); }
        public async Task<object> MyContractorAsync(int actor) { var s = await _r.MyContractorAsync(actor); return new { contractor = Shape.NotNull(Shape.First(s), "Contractor"), assignments = Shape.Set(s, 1), compliance = Shape.Set(s, 2) }; }
        public Task<List<Row>> ComplianceAsync(int actor, int? contractorId, int? withinDays) { return _r.ListComplianceAsync(actor, contractorId, withinDays); }
    }

    public sealed class ContractService
    {
        private readonly StaffingRepository _r;
        public ContractService(StaffingRepository r) { _r = r; }
        public Task<Row> CreateAsync(int actor, CreateContractRequest b) { Shape.Body(b); Shape.Dates(b.StartDate, b.EndDate, "Contract"); if (b.BillRate < b.PayRate) throw new ApiException(422, "business_rule", "The bill rate cannot be below the contractor pay rate."); return _r.CreateContractAsync(actor, b); }
        public Task<Row> RenewAsync(int actor, int id, RenewContractRequest b) { Shape.Body(b); return _r.RenewContractAsync(actor, id, b); }
        public Task TerminateAsync(int actor, int id, TerminateRequest b) { Shape.Body(b); return _r.TerminateContractAsync(actor, id, b.Reason); }
        public Task<List<Row>> ListAsync(int actor, string status, int? customerId) { return _r.ListContractsAsync(actor, status, customerId); }
        public async Task<object> GetAsync(int actor, int id) { var s = await _r.GetContractAsync(actor, id); return new { contract = Shape.NotNull(Shape.First(s), "Contract"), rates = Shape.Set(s, 1), assignments = Shape.Set(s, 2), extensions = Shape.Set(s, 3) }; }
        public Task<Row> CreateAssignmentAsync(int actor, CreateAssignmentRequest b) { Shape.Body(b); return _r.CreateAssignmentAsync(actor, b); }
        public Task<List<Row>> AssignmentsAsync(int actor, string status) { return _r.ListAssignmentsAsync(actor, status); }
    }

    public sealed class TimesheetService
    {
        private readonly TimesheetRepository _r;
        public TimesheetService(TimesheetRepository r) { _r = r; }
        public Task<Row> SaveAsync(int actor, SaveTimesheetRequest b)
        {
            Shape.Body(b); b.WeekStartDate = b.WeekStartDate.Date;
            if (b.Entries == null) b.Entries = new List<TimesheetEntryItem>();
            foreach (var e in b.Entries) e.WorkDate = e.WorkDate.Date;
            if (b.Entries.GroupBy(e => new { e.WorkDate, e.EntryType }).Any(g => g.Count() > 1)) throw new ApiException(400, "validation", "Each day may have only one entry per entry type.");
            return _r.SaveAsync(actor, b);
        }
        public Task SubmitAsync(int actor, int id) { return _r.SubmitAsync(actor, id); }
        public Task ApproveAsync(int actor, int id, ApproveTimesheetRequest b) { return _r.ApproveAsync(actor, id, b == null ? null : b.Comments); }
        public Task RejectAsync(int actor, int id, RejectTimesheetRequest b) { Shape.Body(b); return _r.RejectAsync(actor, id, b.Reason); }
        public Task<List<Row>> PendingAsync(int actor, int? customerId) { return _r.PendingAsync(actor, customerId); }
        public Task<List<Row>> MineAsync(int actor, int top) { return _r.MineAsync(actor, top < 1 || top > 200 ? 20 : top); }
        public Task<List<Row>> ListAsync(int actor, string status, int? customerId, int? contractorId) { return _r.ListAsync(actor, status, customerId, contractorId); }
        public async Task<object> GetAsync(int actor, int id) { var s = await _r.GetAsync(actor, id); return new { timesheet = Shape.NotNull(Shape.First(s), "Timesheet"), entries = Shape.Set(s, 1), decisions = Shape.Set(s, 2) }; }
    }

    public sealed class BillingService
    {
        private readonly BillingRepository _r;
        public BillingService(BillingRepository r) { _r = r; }
        public Task<Row> GenerateAsync(int actor, GenerateInvoiceRequest b) { Shape.Body(b); Shape.Dates(b.PeriodStart, b.PeriodEnd, "Invoice period"); return _r.GenerateAsync(actor, b); }
        public Task IssueAsync(int actor, int id) { return _r.IssueAsync(actor, id); }
        public Task VoidAsync(int actor, int id, VoidRequest b) { Shape.Body(b); return _r.VoidAsync(actor, id, b.Reason); }
        public Task<Row> PayAsync(int actor, int id, RecordPaymentRequest b) { Shape.Body(b); return _r.RecordPaymentAsync(actor, id, b); }
        public Task<List<Row>> ListAsync(int actor, int? customerId) { return _r.ListAsync(actor, customerId); }
        public async Task<object> GetAsync(int actor, int id) { var s = await _r.GetAsync(actor, id); return new { invoice = Shape.NotNull(Shape.First(s), "Invoice"), lines = Shape.Set(s, 1), payments = Shape.Set(s, 2) }; }
    }

    /// <summary>Upload: validate (type, size, content), write the file under a new GUID name, then record it; the database decides who may do so.
    /// If the database refuses, the file just written is removed again. Download: access check in the database, then size + SHA-256 verified on read.</summary>
    public sealed class DocumentService
    {
        private readonly DocumentRepository _r; private readonly DocumentStore _store; private readonly ILog _log;
        public DocumentService(DocumentRepository r, DocumentStore store, ILog log) { _r = r; _store = store; _log = log; }

        public async Task<Row> UploadAsync(int actor, string ownerType, int ownerId, string docType, int? complianceId, bool primaryResume, string originalName, byte[] data)
        {
            if (string.IsNullOrWhiteSpace(ownerType) || ownerId <= 0) throw new ApiException(400, "validation", "ownerType and ownerId are required.");
            var file = FileRules.Validate(originalName, data);
            var stored = _store.Save(file);
            try
            {
                return await _r.AddAsync(actor, ownerType, ownerId, string.IsNullOrWhiteSpace(docType) ? null : docType.Trim(), stored, file.SafeOriginalName, file.ContentType, file.Data.LongLength, file.Sha256, complianceId, primaryResume);
            }
            catch
            {
                _store.DeleteOrphan(stored);      // nothing is left on disk for a refused upload
                throw;
            }
        }

        public Task<List<Row>> ListAsync(int actor, string ownerType, int ownerId) { return _r.ListAsync(actor, ownerType, ownerId); }

        public async Task<Tuple<Row, byte[]>> DownloadAsync(int actor, int documentId)
        {
            var row = await _r.ForDownloadAsync(actor, documentId);
            if (row == null) throw new ApiException(404, "not_found", "Document not found.");
            try { return Tuple.Create(row, _store.ReadVerified(row.Str("StoredFileName"), Convert.ToInt64(row["SizeBytes"]), row.Bytes("Sha256"))); }
            catch (ApiException ex) { _log.Error("document " + documentId + " unreadable: " + ex.Code, ex); throw; }
        }

        public Task DeleteAsync(int actor, int documentId) { return _r.DeleteAsync(actor, documentId); }

        public Task DecideComplianceAsync(int actor, int complianceId, string status, string notes)
        {
            if (string.IsNullOrWhiteSpace(status)) throw new ApiException(400, "validation", "status is required.");
            return _r.DecideComplianceAsync(actor, complianceId, status.Trim(), notes);
        }
    }

    public sealed class NotificationService
    {
        private readonly NotificationRepository _r;
        public NotificationService(NotificationRepository r) { _r = r; }
        public Task<List<Row>> ListAsync(int actor, bool unreadOnly, int top) { return _r.ListAsync(actor, unreadOnly, top); }
        public Task MarkReadAsync(int actor, long? id) { return _r.MarkReadAsync(actor, id); }

        // administration of the delivery queue (Administrator; enforced again in the procedures)
        private static readonly string[] Statuses = { "Pending", "Processing", "Sent", "Failed", "Cancelled" };
        public async Task<PagedResult> QueueAsync(int actor, string status, string q, int page, int size)
        {
            Guard.Page(ref page, ref size);
            if (!string.IsNullOrEmpty(status) && Array.IndexOf(Statuses, status) < 0) throw new ApiException(400, "validation", "Status must be one of " + string.Join(", ", Statuses) + ".");
            return Shape.Paged(await _r.ListQueueAsync(actor, string.IsNullOrEmpty(status) ? null : status, string.IsNullOrWhiteSpace(q) ? null : q.Trim(), page, size), page, size);
        }
        public Task<List<Row>> DeliveryHistoryAsync(int actor, long id) { return _r.DeliveryHistoryAsync(actor, id); }
        public Task<Row> RetryAsync(int actor, long id) { return _r.RetryAsync(actor, id); }
        public Task<Row> CancelAsync(int actor, long id) { return _r.CancelAsync(actor, id); }
    }

    public sealed class DashboardService
    {
        private readonly DashboardRepository _r;
        public DashboardService(DashboardRepository r) { _r = r; }
        public Task<List<Row>> MetricsAsync(int actor, string role) { return _r.MetricsAsync(actor, Guard.Required(role, "Role", 50)); }
    }
}
