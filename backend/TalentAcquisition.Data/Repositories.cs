using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using TalentAcquisition.Models;

// Thin ADO.NET repositories: one method per stored procedure. No SQL text anywhere; every call is a parameterised procedure.
namespace TalentAcquisition.Data
{
    public abstract class RepoBase
    {
        protected readonly StoredProcedureExecutor Db;
        protected RepoBase(StoredProcedureExecutor db) { Db = db; }
        protected static ProcParameters A(int actor) { return ProcParameters.For(actor); }
        /// <summary>Phase 13: rows a list endpoint returns at most (the procedures return the newest first).</summary>
        public const int ListLimit = 500;
        /// <summary>Asks the procedure for one row more than the limit, so the caller learns whether more exist.</summary>
        protected async Task<List<Row>> Capped(string proc, ProcParameters p)
        {
            var rows = await Db.QueryAsync(proc, p.Add("Top", ListLimit + 1)).ConfigureAwait(false);
            var list = new CappedList { Limit = ListLimit, Truncated = rows.Count > ListLimit };
            list.AddRange(rows.Take(ListLimit));
            return list;
        }
    }

    public sealed class AuthRepository : RepoBase
    {
        public AuthRepository(StoredProcedureExecutor db) : base(db) { }
        public Task<Row> PingAsync() { return Db.QueryOneAsync("sec.usp_Ping"); }
        public Task<Row> GetUserForLoginAsync(string email) { return Db.QueryOneAsync("sec.usp_GetUserForLogin", ProcParameters.None().Add("Email", email)); }
        public Task<Row> RecordLoginAttemptAsync(string email, bool success, string reason, string ip, string ua, bool countFailure = true)
        { return Db.QueryOneAsync("sec.usp_RecordLoginAttempt", ProcParameters.None().Add("Email", email).Add("Success", success).Add("FailureReason", reason).Add("IpAddress", ip).Add("UserAgent", ua).Add("CountFailure", countFailure)); }
        public Task IssueTokenAsync(int userId, Guid jti, DateTime expiresAt) { return Db.ExecuteAsync("sec.usp_IssueToken", ProcParameters.None().Add("UserId", userId).Add("Jti", jti).Add("ExpiresAt", expiresAt)); }
        public Task<Row> ValidateTokenAsync(Guid jti) { return Db.QueryOneAsync("sec.usp_ValidateToken", ProcParameters.None().Add("Jti", jti)); }
        public Task RevokeTokenAsync(Guid jti, string reason) { return Db.ExecuteAsync("sec.usp_RevokeToken", ProcParameters.None().Add("Jti", jti).Add("Reason", reason)); }
        public Task<Row> CreatePasswordResetAsync(string email, byte[] tokenHash, DateTime expiresAt)
        { return Db.QueryOneAsync("sec.usp_CreatePasswordReset", ProcParameters.None().Add("Email", email).Add("TokenHash", tokenHash).Add("ExpiresAt", expiresAt)); }
        public Task<Row> ConsumePasswordResetAsync(byte[] tokenHash, byte[] hash, byte[] salt, int iterations)
        { return Db.QueryOneAsync("sec.usp_ConsumePasswordReset", ProcParameters.None().Add("TokenHash", tokenHash).Add("NewPasswordHash", hash).Add("NewPasswordSalt", salt).Add("Iterations", iterations)); }
        public Task ChangePasswordAsync(int actor, byte[] hash, byte[] salt, int iterations)
        { return Db.ExecuteAsync("sec.usp_ChangePassword", A(actor).Add("NewPasswordHash", hash).Add("NewPasswordSalt", salt).Add("Iterations", iterations)); }
        public Task<Row> RegisterCandidateAsync(RegisterRequest r, byte[] hash, byte[] salt, int iterations, byte[] verifyTokenHash, DateTime verifyExpiresAt)
        { return Db.QueryOneAsync("sec.usp_RegisterCandidate", ProcParameters.None().Add("Email", r.Email).Add("FirstName", r.FirstName).Add("LastName", r.LastName).Add("Phone", r.Phone).Add("PasswordHash", hash).Add("PasswordSalt", salt).Add("Iterations", iterations).Add("VerifyTokenHash", verifyTokenHash).Add("VerifyExpiresAt", verifyExpiresAt)); }
        public Task<Row> CreateEmailVerificationAsync(string email, byte[] tokenHash, DateTime expiresAt)
        { return Db.QueryOneAsync("sec.usp_CreateEmailVerification", ProcParameters.None().Add("Email", email).Add("TokenHash", tokenHash).Add("ExpiresAt", expiresAt)); }
        public Task<Row> VerifyEmailAsync(byte[] tokenHash) { return Db.QueryOneAsync("sec.usp_VerifyEmail", ProcParameters.None().Add("TokenHash", tokenHash)); }
        public Task<Row> GetMeAsync(int actor) { return Db.QueryOneAsync("sec.usp_GetMe", A(actor)); }
        public Task<List<Row>> GetMyPermissionsAsync(int actor) { return Db.QueryAsync("sec.usp_GetMyPermissions", A(actor)); }
        public Task EnqueueNotificationAsync(string template, int recipientUserId, string subject, string body, string dedupeKey, string entityType = null, int? entityId = null)
        { return Db.ExecuteAsync("notify.usp_Enqueue", ProcParameters.None().Add("TemplateCode", template).Add("RecipientUserId", recipientUserId).Add("Subject", subject).Add("Body", body).Add("DedupeKey", dedupeKey).Add("RelatedEntityType", entityType).Add("RelatedEntityId", entityId)); }
    }

    public sealed class AdminRepository : RepoBase
    {
        public AdminRepository(StoredProcedureExecutor db) : base(db) { }
        public Task<List<Row>> ListUsersAsync(int actor, string q, string role, bool? active, int page, int size) { return Db.QueryAsync("sec.usp_ListUsers", A(actor).Add("Q", q).Add("RoleName", role).Add("IsActive", active).Add("Page", page).Add("PageSize", size)); }
        public Task<Row> GetUserAsync(int actor, int userId) { return Db.QueryOneAsync("sec.usp_GetUser", A(actor).Add("UserId", userId)); }
        public Task<Row> CreateUserAsync(int actor, CreateUserRequest r, byte[] hash, byte[] salt)
        { return Db.QueryOneAsync("sec.usp_CreateUser", A(actor).Add("Email", r.Email).Add("DisplayName", r.DisplayName).Add("PasswordHash", hash).Add("PasswordSalt", salt).Add("Iterations", 210000).Add("RoleName", r.RoleName).Add("CustomerId", r.CustomerId).Add("DepartmentId", r.DepartmentId).Add("JobTitle", r.JobTitle).Add("IsHiringManager", r.IsHiringManager)); }
        public Task SetUserActiveAsync(int actor, int userId, bool active) { return Db.ExecuteAsync("sec.usp_SetUserActive", A(actor).Add("UserId", userId).Add("IsActive", active)); }
        public Task AssignRoleAsync(int actor, int userId, string role, bool add) { return Db.ExecuteAsync("sec.usp_AssignRole", A(actor).Add("UserId", userId).Add("RoleName", role).Add("Add", add)); }
        public Task<List<Row>> AuditLogsAsync(int actor, string table, string recordId, DateTime? from, DateTime? to, int page, int size) { return Db.QueryAsync("audit.usp_ListAuditLogs", A(actor).Add("TableName", table).Add("RecordId", recordId).Add("FromDate", from).Add("ToDate", to).Add("Page", page).Add("PageSize", size)); }
        public Task<List<Row>> LoginHistoryAsync(int actor, string email, bool? successOnly, int page, int size) { return Db.QueryAsync("audit.usp_ListLoginHistory", A(actor).Add("Email", email).Add("SuccessOnly", successOnly).Add("Page", page).Add("PageSize", size)); }
        public Task<List<Row>> JobsAsync(int actor) { return Db.QueryAsync("sched.usp_ListJobs", A(actor)); }
        public Task<List<Row>> JobHistoryAsync(int actor, int jobId, int top) { return Db.QueryAsync("sched.usp_ListJobHistory", A(actor).Add("JobDefinitionId", jobId).Add("Top", top)); }
        public Task<List<Row>> JobRunDetailsAsync(int actor, long executionId) { return Db.QueryAsync("sched.usp_ListJobRunDetails", A(actor).Add("ExecutionId", executionId)); }
        public Task<List<Row>> RateCardsAsync(int actor, int? customerId) { return Db.QueryAsync("bill.usp_ListRateCards", A(actor).Add("CustomerId", customerId)); }
        public Task<Row> UpsertRateCardAsync(int actor, RateCardRequest r) { return Db.QueryOneAsync("bill.usp_UpsertRateCard", A(actor).Add("RateCardId", r.RateCardId).From(r)); }
    }

    public sealed class OrgRepository : RepoBase
    {
        public OrgRepository(StoredProcedureExecutor db) : base(db) { }
        public Task<List<Row>> CustomersAsync(int actor) { return Db.QueryAsync("org.usp_ListCustomers", A(actor)); }
        public Task<List<List<Row>>> CustomerAsync(int actor, int id) { return Db.QueryMultiAsync("org.usp_GetCustomer", A(actor).Add("CustomerId", id)); }
        public Task<Row> UpsertCustomerAsync(int actor, CustomerRequest r) { return Db.QueryOneAsync("org.usp_UpsertCustomer", A(actor).Add("CustomerId", r.CustomerId).From(r)); }
        public Task<Row> BalanceAsync(int actor, int? customerId) { return Db.QueryOneAsync("bill.usp_GetCustomerBalance", A(actor).Add("CustomerId", customerId)); }
        public Task<List<Row>> DepartmentsAsync(int actor) { return Db.QueryAsync("org.usp_ListDepartments", A(actor)); }
        public Task<Row> UpsertDepartmentAsync(int actor, DepartmentRequest r) { return Db.QueryOneAsync("org.usp_UpsertDepartment", A(actor).Add("DepartmentId", r.DepartmentId).From(r)); }
        public Task<List<Row>> LocationsAsync(int actor) { return Db.QueryAsync("org.usp_ListLocations", A(actor)); }
        public Task<List<Row>> SourcesAsync(int actor) { return Db.QueryAsync("rec.usp_ListSources", A(actor)); }
        public Task<List<Row>> StaffDirectoryAsync(int actor) { return Db.QueryAsync("sec.usp_ListStaffDirectory", A(actor)); }
    }

    public sealed class CandidateRepository : RepoBase
    {
        public CandidateRepository(StoredProcedureExecutor db) : base(db) { }
        public Task<Row> CreateAsync(int actor, CandidateCreateRequest r) { return Db.QueryOneAsync("cand.usp_CreateCandidate", A(actor).From(r)); }
        public Task<Row> UpdateAsync(int actor, CandidateUpdateRequest r) { return Db.QueryOneAsync("cand.usp_UpdateCandidate", A(actor).Add("CandidateId", r.CandidateId).From(r)); }
        public Task<List<List<Row>>> GetAsync(int actor, int? candidateId) { return Db.QueryMultiAsync("cand.usp_GetCandidate", A(actor).Add("CandidateId", candidateId)); }
        public Task<List<Row>> SearchAsync(int actor, string q, string skills, decimal? min, decimal? max, string status, int page, int size) { return Db.QueryAsync("cand.usp_SearchCandidates", A(actor).Add("Q", q).Add("SkillsCsv", skills).Add("MinExp", min).Add("MaxExp", max).Add("Status", status).Add("Page", page).Add("PageSize", size)); }
        public Task AddSkillAsync(int actor, int? candidateId, SkillRequest s) { return Db.ExecuteAsync("cand.usp_AddCandidateSkill", A(actor).Add("CandidateId", candidateId).From(s)); }
        public Task RemoveSkillAsync(int actor, int? candidateId, string skill) { return Db.ExecuteAsync("cand.usp_RemoveCandidateSkill", A(actor).Add("CandidateId", candidateId).Add("SkillName", skill)); }
    }

    public sealed class RecruitmentRepository : RepoBase
    {
        public RecruitmentRepository(StoredProcedureExecutor db) : base(db) { }
        public Task<Row> CreateHiringRequestAsync(int actor, HiringRequestCreate r) { return Db.QueryOneAsync("hr.usp_CreateEmployeeRequisition", A(actor).From(r)); }
        public Task SubmitHiringRequestAsync(int actor, int id) { return Db.ExecuteAsync("hr.usp_SubmitEmployeeRequisition", A(actor).Add("EmployeeRequisitionId", id)); }
        public Task DecideHiringRequestAsync(int actor, int id, string decision, string comments) { return Db.ExecuteAsync("hr.usp_DecideEmployeeRequisition", A(actor).Add("EmployeeRequisitionId", id).Add("Decision", decision).Add("Comments", comments)); }
        public Task<List<Row>> ListHiringRequestsAsync(int actor, string status, int page, int size) { return Db.QueryAsync("hr.usp_ListEmployeeRequisitions", A(actor).Add("Status", status).Add("Page", page).Add("PageSize", size)); }
        public Task<List<List<Row>>> GetHiringRequestAsync(int actor, int id) { return Db.QueryMultiAsync("hr.usp_GetEmployeeRequisition", A(actor).Add("EmployeeRequisitionId", id)); }
        public Task<Row> CreateJobAsync(int actor, JobCreateRequest r) { return Db.QueryOneAsync("rec.usp_CreateJob", A(actor).From(r)); }
        public Task DecideJobAsync(int actor, int id, string decision, string comments) { return Db.ExecuteAsync("rec.usp_DecideJob", A(actor).Add("JobRequisitionId", id).Add("Decision", decision).Add("Comments", comments)); }
        public Task<Row> PublishJobAsync(int actor, int id, PublishJobRequest r) { return Db.QueryOneAsync("rec.usp_PublishJob", A(actor).Add("JobRequisitionId", id).From(r)); }
        public Task CloseJobAsync(int actor, int id, string reason) { return Db.ExecuteAsync("rec.usp_CloseJob", A(actor).Add("JobRequisitionId", id).Add("Reason", reason)); }
        public Task<List<Row>> ListJobsAsync(int actor, string status, string q, int page, int size) { return Db.QueryAsync("rec.usp_ListJobs", A(actor).Add("Status", status).Add("Q", q).Add("Page", page).Add("PageSize", size)); }
        public Task<List<List<Row>>> GetJobAsync(int actor, int id) { return Db.QueryMultiAsync("rec.usp_GetJob", A(actor).Add("JobRequisitionId", id)); }
        public Task<List<Row>> ListPublishedAsync(int actor, string q, int? dept, int page, int size) { return Db.QueryAsync("rec.usp_ListPublishedJobs", A(actor).Add("Q", q).Add("DepartmentId", dept).Add("Page", page).Add("PageSize", size)); }
        public Task<List<List<Row>>> GetPublishedAsync(int actor, int postingId) { return Db.QueryMultiAsync("rec.usp_GetPublishedJob", A(actor).Add("JobPostingId", postingId)); }
    }

    public sealed class ApplicationRepository : RepoBase
    {
        public ApplicationRepository(StoredProcedureExecutor db) : base(db) { }
        public Task<Row> CreateAsync(int actor, ApplyRequest r) { return Db.QueryOneAsync("cand.usp_CreateApplication", A(actor).From(r)); }
        public Task WithdrawAsync(int actor, int id, string reason) { return Db.ExecuteAsync("cand.usp_WithdrawApplication", A(actor).Add("ApplicationId", id).Add("Reason", reason)); }
        public Task<Row> ChangeStatusAsync(int actor, int id, StatusChangeRequest r) { return Db.QueryOneAsync("cand.usp_ChangeApplicationStatus", A(actor).Add("ApplicationId", id).From(r)); }
        public Task ShortlistAsync(int actor, int id, string reason) { return Db.ExecuteAsync("cand.usp_ShortlistApplication", A(actor).Add("ApplicationId", id).Add("Reason", reason)); }
        public Task<List<Row>> ListMineAsync(int actor) { return Db.QueryAsync("cand.usp_ListMyApplications", A(actor)); }
        public Task<List<Row>> ListMySubmissionsAsync(int actor) { return Db.QueryAsync("cand.usp_ListMySubmissions", A(actor)); }
        public Task<List<List<Row>>> GetAsync(int actor, int id) { return Db.QueryMultiAsync("cand.usp_GetApplication", A(actor).Add("ApplicationId", id)); }
        public Task<List<Row>> ListAsync(int actor, int? jobId, string status, string q, int page, int size) { return Db.QueryAsync("cand.usp_ListApplications", A(actor).Add("JobRequisitionId", jobId).Add("Status", status).Add("Q", q).Add("Page", page).Add("PageSize", size)); }
    }

    public sealed class InterviewRepository : RepoBase
    {
        public InterviewRepository(StoredProcedureExecutor db) : base(db) { }
        public Task<Row> ScheduleAsync(int actor, ScheduleInterviewRequest r) { return Db.QueryOneAsync("cand.usp_ScheduleInterview", A(actor).From(r)); }
        public Task<Row> RescheduleAsync(int actor, int id, RescheduleInterviewRequest r) { return Db.QueryOneAsync("cand.usp_RescheduleInterview", A(actor).Add("InterviewId", id).From(r)); }
        public Task CancelAsync(int actor, int id, string reason) { return Db.ExecuteAsync("cand.usp_CancelInterview", A(actor).Add("InterviewId", id).Add("Reason", reason)); }
        public Task FeedbackAsync(int actor, int id, FeedbackRequest r) { return Db.ExecuteAsync("cand.usp_SubmitInterviewFeedback", A(actor).Add("InterviewId", id).From(r)); }
        public Task<List<Row>> ListAsync(int actor, DateTime? from, DateTime? to, string status) { return Capped("cand.usp_ListInterviews", A(actor).Add("FromDate", from).Add("ToDate", to).Add("Status", status)); }
        public Task<List<List<Row>>> GetAsync(int actor, int id) { return Db.QueryMultiAsync("cand.usp_GetInterview", A(actor).Add("InterviewId", id)); }
    }

    public sealed class OfferRepository : RepoBase
    {
        public OfferRepository(StoredProcedureExecutor db) : base(db) { }
        public Task<Row> CreateAsync(int actor, CreateOfferRequest r) { return Db.QueryOneAsync("cand.usp_CreateOffer", A(actor).From(r)); }
        public Task DecideAsync(int actor, int id, string decision, string comments) { return Db.ExecuteAsync("cand.usp_DecideOffer", A(actor).Add("OfferId", id).Add("Decision", decision).Add("Comments", comments)); }
        public Task SendAsync(int actor, int id) { return Db.ExecuteAsync("cand.usp_SendOffer", A(actor).Add("OfferId", id)); }
        public Task<Row> RespondAsync(int actor, int id, bool accept, string note) { return Db.QueryOneAsync("cand.usp_RespondToOffer", A(actor).Add("OfferId", id).Add("Accept", accept).Add("Note", note)); }
        public Task<List<Row>> ListMineAsync(int actor) { return Db.QueryAsync("cand.usp_ListMyOffers", A(actor)); }
        public Task<List<Row>> ListAsync(int actor, string status) { return Capped("cand.usp_ListOffers", A(actor).Add("Status", status)); }
    }

    public sealed class HrRepository : RepoBase
    {
        public HrRepository(StoredProcedureExecutor db) : base(db) { }
        public Task<List<Row>> ListEmployeesAsync(int actor, string status, int? dept, string q, int page, int size) { return Db.QueryAsync("hr.usp_ListEmployees", A(actor).Add("Status", status).Add("DepartmentId", dept).Add("Q", q).Add("Page", page).Add("PageSize", size)); }
        public Task<List<List<Row>>> GetEmployeeAsync(int actor, int id) { return Db.QueryMultiAsync("hr.usp_GetEmployee", A(actor).Add("EmployeeId", id)); }
        public Task<Row> CompleteTaskAsync(int actor, int taskId, CompleteTaskRequest r) { return Db.QueryOneAsync("hr.usp_CompleteOnboardingTask", A(actor).Add("OnboardingId", taskId).From(r)); }
    }

    /// <summary>Document metadata (doc schema). The files themselves are handled by Common.DocumentStore.</summary>
    public sealed class DocumentRepository : RepoBase
    {
        public DocumentRepository(StoredProcedureExecutor db) : base(db) { }
        public Task<Row> AddAsync(int actor, string ownerType, int ownerId, string docType, string storedName, string originalName, string contentType, long size, byte[] sha256, int? complianceId, bool primaryResume)
        {
            return Db.QueryOneAsync("doc.usp_AddDocument", A(actor).Add("OwnerType", ownerType).Add("OwnerId", ownerId).Add("DocType", docType).Add("StoredFileName", storedName)
                .Add("OriginalFileName", originalName).Add("ContentType", contentType).Add("SizeBytes", size).Add("Sha256", sha256).Add("ComplianceId", complianceId).Add("IsPrimaryResume", primaryResume));
        }
        public Task<List<Row>> ListAsync(int actor, string ownerType, int ownerId) { return Db.QueryAsync("doc.usp_ListDocuments", A(actor).Add("OwnerType", ownerType).Add("OwnerId", ownerId)); }
        public Task<Row> ForDownloadAsync(int actor, int documentId) { return Db.QueryOneAsync("doc.usp_GetDocumentForDownload", A(actor).Add("DocumentId", documentId)); }
        public Task DeleteAsync(int actor, int documentId) { return Db.ExecuteAsync("doc.usp_DeleteDocument", A(actor).Add("DocumentId", documentId)); }
        public Task DecideComplianceAsync(int actor, int complianceId, string status, string notes) { return Db.ExecuteAsync("staff.usp_DecideCompliance", A(actor).Add("ComplianceId", complianceId).Add("Status", status).Add("Notes", notes)); }
    }

    public sealed class StaffingRepository : RepoBase
    {
        public StaffingRepository(StoredProcedureExecutor db) : base(db) { }
        public Task<Row> CreateRequestAsync(int actor, StaffingRequestCreate r) { return Db.QueryOneAsync("staff.usp_CreateCustomerRequisition", A(actor).From(r)); }
        public Task AcceptRequestAsync(int actor, int id, int? recruiter) { return Db.ExecuteAsync("staff.usp_AcceptCustomerRequisition", A(actor).Add("CustomerRequisitionId", id).Add("AssignedRecruiterUserId", recruiter)); }
        public Task CancelRequestAsync(int actor, int id, string reason) { return Db.ExecuteAsync("staff.usp_CancelCustomerRequisition", A(actor).Add("CustomerRequisitionId", id).Add("Reason", reason)); }
        public Task<List<Row>> ListRequestsAsync(int actor, int? customerId, string status) { return Capped("staff.usp_ListCustomerRequisitions", A(actor).Add("CustomerId", customerId).Add("Status", status)); }
        public Task<Row> SubmitCandidateAsync(int actor, int requestId, SubmitCandidateRequest r) { return Db.QueryOneAsync("staff.usp_SubmitCandidateToCustomer", A(actor).Add("CustomerRequisitionId", requestId).From(r)); }
        public Task<List<Row>> SubmissionsAsync(int actor, int requestId) { return Db.QueryAsync("staff.usp_GetSubmissionsForRequisition", A(actor).Add("CustomerRequisitionId", requestId)); }
        public Task DecideSubmissionAsync(int actor, int id, DecideSubmissionRequest r) { return Db.ExecuteAsync("staff.usp_DecideSubmission", A(actor).Add("SubmissionId", id).From(r)); }
        public Task WithdrawSubmissionAsync(int actor, int id) { return Db.ExecuteAsync("staff.usp_WithdrawSubmission", A(actor).Add("SubmissionId", id)); }
        public Task<Row> CreateContractorAsync(int actor, CreateContractorRequest r) { return Db.QueryOneAsync("staff.usp_CreateContractor", A(actor).From(r)); }
        public Task<List<Row>> ListContractorsAsync(int actor, string status, string q) { return Capped("staff.usp_ListContractors", A(actor).Add("Status", status).Add("Q", q)); }
        public Task<List<List<Row>>> MyContractorAsync(int actor) { return Db.QueryMultiAsync("staff.usp_GetMyContractor", A(actor)); }
        public Task<List<Row>> ListComplianceAsync(int actor, int? contractorId, int? withinDays) { return Db.QueryAsync("staff.usp_ListCompliance", A(actor).Add("ContractorId", contractorId).Add("ExpiringWithinDays", withinDays)); }
        public Task<Row> CreateContractAsync(int actor, CreateContractRequest r) { return Db.QueryOneAsync("staff.usp_CreateContract", A(actor).From(r)); }
        public Task<Row> RenewContractAsync(int actor, int id, RenewContractRequest r) { return Db.QueryOneAsync("staff.usp_RenewContract", A(actor).Add("ContractId", id).From(r)); }
        public Task TerminateContractAsync(int actor, int id, string reason) { return Db.ExecuteAsync("staff.usp_TerminateContract", A(actor).Add("ContractId", id).Add("Reason", reason)); }
        public Task<List<Row>> ListContractsAsync(int actor, string status, int? customerId) { return Capped("staff.usp_ListContracts", A(actor).Add("Status", status).Add("CustomerId", customerId)); }
        public Task<List<List<Row>>> GetContractAsync(int actor, int id) { return Db.QueryMultiAsync("staff.usp_GetContract", A(actor).Add("ContractId", id)); }
        public Task<Row> CreateAssignmentAsync(int actor, CreateAssignmentRequest r) { return Db.QueryOneAsync("staff.usp_CreateAssignment", A(actor).From(r)); }
        public Task<List<Row>> ListAssignmentsAsync(int actor, string status) { return Capped("staff.usp_ListAssignments", A(actor).Add("Status", status)); }
    }

    public sealed class TimesheetRepository : RepoBase
    {
        public TimesheetRepository(StoredProcedureExecutor db) : base(db) { }
        public Task<Row> SaveAsync(int actor, SaveTimesheetRequest r) { return Db.QueryOneAsync("time.usp_SaveTimesheet", A(actor).From(r)); }
        public Task SubmitAsync(int actor, int id) { return Db.ExecuteAsync("time.usp_SubmitTimesheet", A(actor).Add("TimesheetId", id)); }
        public Task ApproveAsync(int actor, int id, string comments) { return Db.ExecuteAsync("time.usp_ApproveTimesheet", A(actor).Add("TimesheetId", id).Add("Comments", comments)); }
        public Task RejectAsync(int actor, int id, string reason) { return Db.ExecuteAsync("time.usp_RejectTimesheet", A(actor).Add("TimesheetId", id).Add("Reason", reason)); }
        public Task<List<Row>> PendingAsync(int actor, int? customerId) { return Capped("time.usp_ListPendingTimesheets", A(actor).Add("CustomerId", customerId)); }
        public Task<List<Row>> MineAsync(int actor, int top) { return Db.QueryAsync("time.usp_GetMyTimesheets", A(actor).Add("Top", top)); }
        public Task<List<Row>> ListAsync(int actor, string status, int? customerId, int? contractorId) { return Capped("time.usp_ListTimesheets", A(actor).Add("Status", status).Add("CustomerId", customerId).Add("ContractorId", contractorId)); }
        public Task<List<List<Row>>> GetAsync(int actor, int id) { return Db.QueryMultiAsync("time.usp_GetTimesheet", A(actor).Add("TimesheetId", id)); }
    }

    public sealed class BillingRepository : RepoBase
    {
        public BillingRepository(StoredProcedureExecutor db) : base(db) { }
        public Task<Row> GenerateAsync(int actor, GenerateInvoiceRequest r) { return Db.QueryOneAsync("bill.usp_GenerateInvoice", A(actor).From(r)); }
        public Task IssueAsync(int actor, int id) { return Db.ExecuteAsync("bill.usp_IssueInvoice", A(actor).Add("InvoiceId", id)); }
        public Task VoidAsync(int actor, int id, string reason) { return Db.ExecuteAsync("bill.usp_VoidInvoice", A(actor).Add("InvoiceId", id).Add("Reason", reason)); }
        public Task<Row> RecordPaymentAsync(int actor, int id, RecordPaymentRequest r) { return Db.QueryOneAsync("bill.usp_RecordPayment", A(actor).Add("InvoiceId", id).From(r)); }
        public Task<List<Row>> ListAsync(int actor, int? customerId) { return Capped("bill.usp_ListInvoices", A(actor).Add("CustomerId", customerId)); }
        public Task<List<List<Row>>> GetAsync(int actor, int id) { return Db.QueryMultiAsync("bill.usp_GetInvoice", A(actor).Add("InvoiceId", id)); }
    }

    public sealed class NotificationRepository : RepoBase
    {
        public NotificationRepository(StoredProcedureExecutor db) : base(db) { }
        public Task<List<Row>> ListAsync(int actor, bool unreadOnly, int top) { return Db.QueryAsync("notify.usp_ListMyNotifications", A(actor).Add("UnreadOnly", unreadOnly).Add("Top", top)); }
        public Task MarkReadAsync(int actor, long? id) { return Db.ExecuteAsync("notify.usp_MarkRead", A(actor).Add("NotificationId", id)); }

        // delivery worker (no actor: the scheduler is a system process)
        public Task<List<Row>> ClaimBatchAsync(int batchSize, int leaseSeconds) { return Db.QueryAsync("notify.usp_ClaimBatch", ProcParameters.None().Add("BatchSize", batchSize).Add("LeaseSeconds", leaseSeconds)); }
        public async Task<bool> MarkSentAsync(long id, int attemptNo) { var r = await Db.QueryOneAsync("notify.usp_MarkSent", ProcParameters.None().Add("NotificationId", id).Add("AttemptNo", attemptNo)).ConfigureAwait(false); return r != null && r.Int("Updated") == 1; }
        public Task<Row> MarkFailedAsync(long id, int attemptNo, string error) { return Db.QueryOneAsync("notify.usp_MarkFailed", ProcParameters.None().Add("NotificationId", id).Add("AttemptNo", attemptNo).Add("Error", error)); }

        // administration
        public Task<List<Row>> ListQueueAsync(int actor, string status, string q, int page, int size) { return Db.QueryAsync("notify.usp_ListQueue", A(actor).Add("Status", status).Add("Q", q).Add("Page", page).Add("PageSize", size)); }
        public Task<List<Row>> DeliveryHistoryAsync(int actor, long id) { return Db.QueryAsync("notify.usp_ListDeliveryHistory", A(actor).Add("NotificationId", id)); }
        public Task<Row> RetryAsync(int actor, long id) { return Db.QueryOneAsync("notify.usp_RetryNotification", A(actor).Add("NotificationId", id)); }
        public Task<Row> CancelAsync(int actor, long id) { return Db.QueryOneAsync("notify.usp_CancelNotification", A(actor).Add("NotificationId", id)); }
    }

    /// <summary>Phase 10: the report catalog and the single report entry point (report.usp_RunReport authorises and scopes).</summary>
    public sealed class ReportRepository : RepoBase
    {
        public ReportRepository(StoredProcedureExecutor db) : base(db) { }
        public Task<List<Row>> ListAsync(int actor) { return Db.QueryAsync("report.usp_ListReports", A(actor)); }
        public Task<ResultTable> RunAsync(int actor, string code, DateTime? from, DateTime? to, int? customerId, int? days, string format = "view")
        { return Db.QueryTableAsync("report.usp_RunReport", A(actor).Add("ReportCode", code).Add("FromDate", from).Add("ToDate", to).Add("CustomerId", customerId).Add("Days", days).Add("Format", format)); }
    }
    /// <summary>Phase 12: the Task Scheduler tasks (system work: no actor). Bookkeeping is limited to Task Scheduler jobs in the database.</summary>
    public sealed class AppTaskRepository : RepoBase
    {
        public AppTaskRepository(StoredProcedureExecutor db) : base(db) { }
        public Task<Row> BeginAsync(string jobName, int leaseMinutes, string host)
        { return Db.QueryOneAsync("sched.usp_AppTaskBegin", ProcParameters.None().Add("JobName", jobName).Add("LeaseMinutes", leaseMinutes).Add("HostName", host)); }
        public Task LogAsync(long executionId, string message, string level = "Info")
        { return Db.ExecuteAsync("sched.usp_AppTaskLog", ProcParameters.None().Add("ExecutionId", executionId).Add("Message", message).Add("Level", level)); }
        public Task EndAsync(long executionId, string outcome, int rows, string error)
        { return Db.ExecuteAsync("sched.usp_AppTaskEnd", ProcParameters.None().Add("ExecutionId", executionId).Add("Outcome", outcome).Add("RowsAffected", rows).Add("Error", error)); }

        public Task<Row> QueueInterviewRemindersAsync(int withinHours) { return Db.QueryOneAsync("notify.usp_QueueInterviewReminders", ProcParameters.None().Add("WithinHours", withinHours)); }
        public Task<Row> QueueOfferExpiryRemindersAsync(int withinDays) { return Db.QueryOneAsync("notify.usp_QueueOfferExpiryReminders", ProcParameters.None().Add("WithinDays", withinDays)); }
        public Task<Row> QueueTimesheetRemindersAsync() { return Db.QueryOneAsync("notify.usp_QueueTimesheetReminders"); }
        public Task<Row> QueueContractExpiryNoticesAsync() { return Db.QueryOneAsync("notify.usp_QueueContractExpiryNotices"); }
        public Task<Row> QueueDailyReportAsync() { return Db.QueryOneAsync("notify.usp_QueueDailyReport"); }
        public Task<List<Row>> ListPurgeableFilesAsync(int olderThanDays) { return Db.QueryAsync("doc.usp_ListPurgeableFiles", ProcParameters.None().Add("OlderThanDays", olderThanDays)); }
        public Task MarkFilePurgedAsync(int documentId) { return Db.ExecuteAsync("doc.usp_MarkFilePurged", ProcParameters.None().Add("DocumentId", documentId)); }
    }
    public sealed class DashboardRepository : RepoBase
    {
        public DashboardRepository(StoredProcedureExecutor db) : base(db) { }
        public Task<List<Row>> MetricsAsync(int actor, string role) { return Db.QueryAsync("report.usp_Dashboard", A(actor).Add("Role", role)); }
    }
}
