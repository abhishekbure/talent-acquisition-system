using System;
using System.Collections.Generic;
using System.ComponentModel.DataAnnotations;

// Property names equal the stored-procedure parameter names (without '@'); the data layer binds them by reflection.
// Null optional values are simply not sent, so the procedure's own default applies. [NotProc] = route/helper field.
namespace TalentAcquisition.Models
{
    // ------------------------------------------------------------------ auth / users
    public sealed class LoginRequest { [Required, StringLength(256)] public string Email { get; set; } [Required, StringLength(200)] public string Password { get; set; } }
    public sealed class RegisterRequest
    {
        [Required, StringLength(256)] public string Email { get; set; }
        [Required, StringLength(200)] public string Password { get; set; }
        [Required, StringLength(100)] public string FirstName { get; set; }
        [Required, StringLength(100)] public string LastName { get; set; }
        [StringLength(30)] public string Phone { get; set; }
    }
    public sealed class ForgotPasswordRequest { [Required, StringLength(256)] public string Email { get; set; } }
    public sealed class VerifyEmailRequest { [Required, StringLength(200)] public string Token { get; set; } }
    public sealed class ResendVerificationRequest { [Required, StringLength(256)] public string Email { get; set; } }
    public sealed class RegisterResponse { public string Email { get; set; } public bool VerificationRequired { get; set; } public string Message { get; set; } }
    public sealed class ResetPasswordRequest { [Required, StringLength(200)] public string Token { get; set; } [Required, StringLength(200)] public string NewPassword { get; set; } }
    public sealed class ChangePasswordRequest { [Required, StringLength(200)] public string CurrentPassword { get; set; } [Required, StringLength(200)] public string NewPassword { get; set; } }

    public sealed class CreateUserRequest
    {
        [Required, StringLength(256)] public string Email { get; set; }
        [Required, StringLength(150)] public string DisplayName { get; set; }
        [Required, StringLength(200)] public string TemporaryPassword { get; set; }
        [Required] public string RoleName { get; set; }
        public int? CustomerId { get; set; }
        public int? DepartmentId { get; set; }
        [StringLength(100)] public string JobTitle { get; set; }
        public bool IsHiringManager { get; set; }
    }
    public sealed class AssignRoleRequest { [Required] public string RoleName { get; set; } public bool Add { get; set; } }

    // ------------------------------------------------------------------ organisation
    public sealed class CustomerRequest
    {
        [NotProc] public int? CustomerId { get; set; }
        [Required, StringLength(20)] public string CustomerCode { get; set; }
        [Required, StringLength(200)] public string Name { get; set; }
        [StringLength(100)] public string Industry { get; set; }
        public string Status { get; set; } = "Active";
        [StringLength(256)] public string BillingEmail { get; set; }
        [StringLength(300)] public string BillingAddress { get; set; }
        [Range(0, 365)] public int PaymentTermsDays { get; set; } = 30;
        public int? AccountManagerUserId { get; set; }
        public byte[] RowVer { get; set; }
    }
    public sealed class DepartmentRequest
    {
        [NotProc] public int? DepartmentId { get; set; }
        [Required, StringLength(100)] public string Name { get; set; }
        [StringLength(30)] public string CostCenter { get; set; }
        public int? HeadUserId { get; set; }
        public bool IsActive { get; set; } = true;
    }
    public sealed class RateCardRequest
    {
        [NotProc] public int? RateCardId { get; set; }
        [Required] public int CustomerId { get; set; }
        [Required, StringLength(100)] public string RoleCategory { get; set; }
        [Range(0.01, 100000)] public decimal StandardBillRate { get; set; }
        public string Currency { get; set; } = "INR";
        [Required] public DateTime EffectiveFrom { get; set; }
        public DateTime? EffectiveTo { get; set; }
        public bool IsActive { get; set; } = true;
    }

    // ------------------------------------------------------------------ candidates
    public sealed class CandidateCreateRequest
    {
        [Required, StringLength(100)] public string FirstName { get; set; }
        [Required, StringLength(100)] public string LastName { get; set; }
        [Required, StringLength(256)] public string Email { get; set; }
        [StringLength(30)] public string Phone { get; set; }
        [StringLength(150)] public string CurrentTitle { get; set; }
        [StringLength(150)] public string CurrentEmployer { get; set; }
        [Range(0, 60)] public decimal TotalExperienceYears { get; set; }
        public decimal? ExpectedSalary { get; set; }
        public int? NoticePeriodDays { get; set; }
        [StringLength(1000)] public string Summary { get; set; }
        public int? SourceId { get; set; }
    }
    public sealed class CandidateUpdateRequest
    {
        [NotProc] public int? CandidateId { get; set; }
        public byte[] RowVer { get; set; }
        [Required, StringLength(100)] public string FirstName { get; set; }
        [Required, StringLength(100)] public string LastName { get; set; }
        [StringLength(30)] public string Phone { get; set; }
        [StringLength(150)] public string CurrentTitle { get; set; }
        [StringLength(150)] public string CurrentEmployer { get; set; }
        [Range(0, 60)] public decimal TotalExperienceYears { get; set; }
        public decimal? ExpectedSalary { get; set; }
        public int? NoticePeriodDays { get; set; }
        [StringLength(1000)] public string Summary { get; set; }
        public string Status { get; set; }
    }
    public sealed class SkillRequest
    {
        [Required, StringLength(100)] public string SkillName { get; set; }
        [Range(0, 60)] public decimal YearsExperience { get; set; }
        [Range(1, 5)] public byte ProficiencyLevel { get; set; } = 3;
    }

    // ------------------------------------------------------------------ hiring requests, jobs
    public sealed class HiringRequestCreate
    {
        [Required] public int DepartmentId { get; set; }
        public int? LocationId { get; set; }
        [Required, StringLength(200)] public string Title { get; set; }
        [Range(1, 1000)] public int Headcount { get; set; } = 1;
        public string EmploymentType { get; set; } = "FullTime";
        [StringLength(1000)] public string Justification { get; set; }
        public decimal? BudgetMax { get; set; }
        public DateTime? RequiredByDate { get; set; }
        public bool Submit { get; set; }
    }
    public sealed class DecisionRequest { [StringLength(500)] public string Comments { get; set; } }
    public sealed class JobCreateRequest
    {
        [Required] public int EmployeeRequisitionId { get; set; }
        public int? OwnerRecruiterUserId { get; set; }
        public int? Openings { get; set; }
        [StringLength(500)] public string Summary { get; set; }
        public string Responsibilities { get; set; }
        public string Qualifications { get; set; }
        [Range(0, 60)] public decimal MinExperienceYears { get; set; }
        public decimal? SalaryMin { get; set; }
        public decimal? SalaryMax { get; set; }
        public DateTime? ClosesBy { get; set; }
        [Tvp("rec.JobSkillList")] public List<SkillItem> Skills { get; set; } = new List<SkillItem>();
    }
    public sealed class PublishJobRequest { public int? SourceId { get; set; } public DateTime? ClosesAt { get; set; } }
    public sealed class ReasonRequest { [StringLength(500)] public string Reason { get; set; } }

    // ------------------------------------------------------------------ applications, interviews, offers
    public sealed class ApplyRequest { [Required] public int JobPostingId { get; set; } [StringLength(1000)] public string CoverNote { get; set; } public int? SourceId { get; set; } }
    public sealed class StatusChangeRequest { [Required] public string NewStatus { get; set; } [StringLength(500)] public string Reason { get; set; } public byte[] RowVer { get; set; } }
    public sealed class ScheduleInterviewRequest
    {
        public int? JobApplicationId { get; set; }
        public int? SubmittedCandidateId { get; set; }
        [Range(1, 10)] public byte RoundNo { get; set; } = 1;
        public string InterviewType { get; set; } = "Technical";
        [Required] public DateTime StartsAt { get; set; }
        [Required] public DateTime EndsAt { get; set; }
        public string Mode { get; set; } = "Video";
        [StringLength(300)] public string LocationOrLink { get; set; }
        [StringLength(1000)] public string Notes { get; set; }
        [Tvp("dbo.IdList")] public List<int> Panel { get; set; } = new List<int>();
        /// <summary>Lead interviewer; must be on the panel. When omitted the first listed panel member leads.</summary>
        public int? LeadUserId { get; set; }
    }
    public sealed class RescheduleInterviewRequest { [Required] public DateTime StartsAt { get; set; } [Required] public DateTime EndsAt { get; set; } public string Mode { get; set; } [StringLength(300)] public string LocationOrLink { get; set; } public byte[] RowVer { get; set; } }
    public sealed class FeedbackRequest { [Range(1, 5)] public byte Rating { get; set; } [Required] public string Recommendation { get; set; } [StringLength(1000)] public string Strengths { get; set; } [StringLength(1000)] public string Concerns { get; set; } }
    public sealed class CreateOfferRequest
    {
        [Required] public int ApplicationId { get; set; }
        [Required, StringLength(150)] public string Designation { get; set; }
        [Range(1, 1000000000)] public decimal OfferedSalary { get; set; }
        public string Currency { get; set; } = "INR";
        [Required] public DateTime StartDate { get; set; }
        [Required] public DateTime ExpiresAt { get; set; }
    }
    public sealed class OfferResponseRequest { [StringLength(500)] public string Note { get; set; } }
    public sealed class CompleteTaskRequest { [StringLength(500)] public string Notes { get; set; } public bool Waive { get; set; } }

    // ------------------------------------------------------------------ staffing
    public sealed class StaffingRequestCreate
    {
        public int? CustomerId { get; set; }
        [Required, StringLength(200)] public string Title { get; set; }
        [StringLength(2000)] public string Description { get; set; }
        [Range(1, 1000)] public int Positions { get; set; } = 1;
        [StringLength(500)] public string SkillsRequired { get; set; }
        public DateTime? StartDate { get; set; }
        public int? DurationMonths { get; set; }
        public decimal? MaxBillRate { get; set; }
        [StringLength(150)] public string WorkLocation { get; set; }
    }
    public sealed class AcceptRequest { public int? AssignedRecruiterUserId { get; set; } }
    public sealed class SubmitCandidateRequest { [Required] public int CandidateId { get; set; } public decimal? ProposedBillRate { get; set; } [StringLength(1000)] public string Notes { get; set; } }
    public sealed class DecideSubmissionRequest { [Required] public string Decision { get; set; } [StringLength(500)] public string Comments { get; set; } }
    public sealed class CreateContractorRequest { [Required] public int CandidateId { get; set; } public int? UserId { get; set; } }
    public sealed class CreateContractRequest
    {
        [Required] public int SubmissionId { get; set; }
        [Required] public DateTime StartDate { get; set; }
        [Required] public DateTime EndDate { get; set; }
        [Range(0, 100000)] public decimal PayRate { get; set; }
        [Range(0.01, 100000)] public decimal BillRate { get; set; }
        [Range(1, 5)] public decimal OvertimePayMultiplier { get; set; } = 1.5m;
        [Range(1, 5)] public decimal OvertimeBillMultiplier { get; set; } = 1.5m;
        [Required, StringLength(150)] public string RoleTitle { get; set; }
        [StringLength(150)] public string SiteLocation { get; set; }
        [Range(1, 80)] public decimal HoursPerWeek { get; set; } = 40;
        [StringLength(2000)] public string Terms { get; set; }
        public string Currency { get; set; } = "INR";
    }
    public sealed class RenewContractRequest { [Required] public DateTime NewEndDate { get; set; } public decimal? PayRate { get; set; } public decimal? BillRate { get; set; } [StringLength(500)] public string Reason { get; set; } }
    public sealed class TerminateRequest { [Required, StringLength(500)] public string Reason { get; set; } }
    public sealed class CreateAssignmentRequest
    {
        [Required] public int ContractId { get; set; }
        [Required, StringLength(150)] public string RoleTitle { get; set; }
        [StringLength(150)] public string SiteLocation { get; set; }
        [Range(1, 80)] public decimal HoursPerWeek { get; set; } = 40;
        [Required] public DateTime StartDate { get; set; }
        public DateTime? EndDate { get; set; }
    }

    // ------------------------------------------------------------------ timesheets, billing
    public sealed class SaveTimesheetRequest
    {
        [Required] public DateTime WeekStartDate { get; set; }
        public int? AssignmentId { get; set; }
        public byte[] RowVer { get; set; }
        [Tvp("[time].TimesheetEntryList")] public List<TimesheetEntryItem> Entries { get; set; } = new List<TimesheetEntryItem>();
    }
    public sealed class ApproveTimesheetRequest { [StringLength(500)] public string Comments { get; set; } }
    public sealed class RejectTimesheetRequest { [Required, StringLength(500)] public string Reason { get; set; } }
    public sealed class GenerateInvoiceRequest { [Required] public int CustomerId { get; set; } [Required] public DateTime PeriodStart { get; set; } [Required] public DateTime PeriodEnd { get; set; } [Range(0, 100)] public decimal TaxRate { get; set; } = 18.00m; }
    public sealed class RecordPaymentRequest { [Range(0.01, 1000000000)] public decimal Amount { get; set; } [Required] public DateTime PaidOn { get; set; } public string Method { get; set; } = "BankTransfer"; [StringLength(100)] public string Reference { get; set; } }
    public sealed class VoidRequest { [Required, StringLength(300)] public string Reason { get; set; } }
    public sealed class ComplianceDecisionRequest { [Required] public string Status { get; set; } [StringLength(500)] public string Notes { get; set; } }
}
