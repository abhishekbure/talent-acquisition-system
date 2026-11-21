/* ============================================================================
   TAMS - 06_StoredProcedures / 08_Queries_Admin_Reference.sql        (Phase 4 read side, part 1)
   Identity, administration, reference data, notifications, requisitions, jobs, employees.
   Every procedure takes @ActorUserId, re-checks the role and applies the caller's SCOPE.
   ========================================================================== */
USE TalentAcquisitionDB;
GO

/* ---------------- health ---------------- */
-- No authorisation: used by GET /health to prove the API can reach the database as its least-privileged user.
CREATE OR ALTER PROCEDURE sec.usp_Ping
AS
BEGIN
    SET NOCOUNT ON;
    SELECT 1 AS Ok, DB_NAME() AS DatabaseName, SYSUTCDATETIME() AS ServerTimeUtc, USER_NAME() AS DatabaseUser;
END
GO

/* ---------------- identity ---------------- */
CREATE OR ALTER PROCEDURE sec.usp_GetMe @ActorUserId INT
AS
BEGIN
    SET NOCOUNT ON;
    EXEC sec.usp_Authorize @ActorUserId, N'Candidate,Contractor,Customer,Recruiter,HRManager,Administrator';
    SELECT u.UserId, u.Email, u.DisplayName, u.LastLoginAt,
           Roles = STUFF((SELECT N',' + r.RoleName FROM sec.UserRoles ur JOIN sec.Roles r ON r.RoleId = ur.RoleId WHERE ur.UserId = u.UserId ORDER BY r.RoleName FOR XML PATH(N'')), 1, 1, N''),
           CustomerId = sec.fn_UserCustomerId(u.UserId), CustomerName = (SELECT c.Name FROM org.Customers c WHERE c.CustomerId = sec.fn_UserCustomerId(u.UserId)),
           CandidateId = cand.fn_CandidateIdForUser(u.UserId), ContractorId = staff.fn_ContractorIdForUser(u.UserId),
           UnreadNotifications = (SELECT COUNT(*) FROM notify.NotificationQueue n WHERE n.RecipientUserId = u.UserId AND n.IsRead = 0 AND notify.fn_IsSecurityTemplate(n.TemplateCode) = 0)
    FROM sec.Users u WHERE u.UserId = @ActorUserId;
END
GO

CREATE OR ALTER PROCEDURE sec.usp_GetMyPermissions @ActorUserId INT
AS
BEGIN
    SET NOCOUNT ON;
    EXEC sec.usp_Authorize @ActorUserId, N'Candidate,Contractor,Customer,Recruiter,HRManager,Administrator';
    SELECT DISTINCT p.Code FROM sec.UserRoles ur JOIN sec.RolePermissions rp ON rp.RoleId = ur.RoleId JOIN sec.Permissions p ON p.PermissionId = rp.PermissionId
    WHERE ur.UserId = @ActorUserId ORDER BY p.Code;
END
GO

CREATE OR ALTER PROCEDURE sec.usp_ListUsers @ActorUserId INT, @Q NVARCHAR(100) = NULL, @RoleName NVARCHAR(50) = NULL, @IsActive BIT = NULL, @Page INT = 1, @PageSize INT = 25
AS
BEGIN
    SET NOCOUNT ON;
    EXEC sec.usp_Authorize @ActorUserId, N'Administrator';
    IF @Page < 1 SET @Page = 1; IF @PageSize < 1 OR @PageSize > 200 SET @PageSize = 25;
    SELECT u.UserId, u.Email, u.DisplayName, u.IsActive, u.LastLoginAt, u.FailedLoginCount, u.LockoutUntil, u.CreatedAt,
           Roles = STUFF((SELECT N',' + r.RoleName FROM sec.UserRoles ur JOIN sec.Roles r ON r.RoleId = ur.RoleId WHERE ur.UserId = u.UserId ORDER BY r.RoleName FOR XML PATH(N'')), 1, 1, N''),
           CustomerName = (SELECT c.Name FROM org.CustomerUsers cu JOIN org.Customers c ON c.CustomerId = cu.CustomerId WHERE cu.UserId = u.UserId),
           COUNT(*) OVER () AS TotalCount
    FROM sec.Users u
    WHERE (@IsActive IS NULL OR u.IsActive = @IsActive)
      AND (@Q IS NULL OR u.Email LIKE N'%' + @Q + N'%' OR u.DisplayName LIKE N'%' + @Q + N'%')
      AND (@RoleName IS NULL OR EXISTS (SELECT 1 FROM sec.UserRoles ur JOIN sec.Roles r ON r.RoleId = ur.RoleId WHERE ur.UserId = u.UserId AND r.RoleName = @RoleName))
    ORDER BY u.DisplayName, u.UserId OFFSET (@Page - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END
GO

CREATE OR ALTER PROCEDURE sec.usp_GetUser @ActorUserId INT, @UserId INT
AS
BEGIN
    SET NOCOUNT ON;
    EXEC sec.usp_Authorize @ActorUserId, N'Administrator';
    IF NOT EXISTS (SELECT 1 FROM sec.Users WHERE UserId = @UserId) THROW 50004, N'User not found.', 1;
    SELECT u.UserId, u.Email, u.DisplayName, u.IsActive, u.LastLoginAt, u.FailedLoginCount, u.LockoutUntil, u.CreatedAt,
           Roles = STUFF((SELECT N',' + r.RoleName FROM sec.UserRoles ur JOIN sec.Roles r ON r.RoleId = ur.RoleId WHERE ur.UserId = u.UserId ORDER BY r.RoleName FOR XML PATH(N'')), 1, 1, N''),
           CustomerId = sec.fn_UserCustomerId(u.UserId), CandidateId = cand.fn_CandidateIdForUser(u.UserId), ContractorId = staff.fn_ContractorIdForUser(u.UserId)
    FROM sec.Users u WHERE u.UserId = @UserId;
END
GO

-- Staff directory for interview panels: active Recruiter / HR Manager / Administrator users. Names and staff roles only (no e-mail, no customer users).
CREATE OR ALTER PROCEDURE sec.usp_ListStaffDirectory @ActorUserId INT
AS
BEGIN
    SET NOCOUNT ON;
    EXEC sec.usp_Authorize @ActorUserId, N'Recruiter,HRManager,Administrator';
    SELECT u.UserId, u.DisplayName,
           Roles = STUFF((SELECT N',' + r.RoleName FROM sec.UserRoles ur JOIN sec.Roles r ON r.RoleId = ur.RoleId
                          WHERE ur.UserId = u.UserId AND r.RoleName IN (N'Recruiter', N'HRManager', N'Administrator') ORDER BY r.RoleName FOR XML PATH(N'')), 1, 1, N'')
    FROM sec.Users u
    WHERE u.IsActive = 1
      AND EXISTS (SELECT 1 FROM sec.UserRoles ur JOIN sec.Roles r ON r.RoleId = ur.RoleId WHERE ur.UserId = u.UserId AND r.RoleName IN (N'Recruiter', N'HRManager', N'Administrator'))
    ORDER BY u.DisplayName;
END
GO

-- Staff roles only (Candidate/Customer/Contractor are tied to a profile and cannot be granted by hand). An admin cannot remove their own Administrator role.
CREATE OR ALTER PROCEDURE sec.usp_AssignRole @ActorUserId INT, @UserId INT, @RoleName NVARCHAR(50), @Add BIT
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @own BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;
    BEGIN TRY
        IF @own = 1 BEGIN BEGIN TRANSACTION; END ELSE BEGIN SAVE TRANSACTION sp_AssignRole; END
        EXEC sec.usp_Authorize @ActorUserId, N'Administrator';
        IF @RoleName NOT IN (N'Recruiter', N'HRManager', N'Administrator') THROW 50001, N'Only Recruiter, HRManager or Administrator can be assigned manually.', 1;
        IF NOT EXISTS (SELECT 1 FROM sec.Users WHERE UserId = @UserId) THROW 50004, N'User not found.', 1;
        DECLARE @rid INT = (SELECT RoleId FROM sec.Roles WHERE RoleName = @RoleName);
        IF @Add = 1
        BEGIN
            IF EXISTS (SELECT 1 FROM sec.UserRoles WHERE UserId = @UserId AND RoleId = @rid) THROW 50003, N'The user already has this role.', 1;
            INSERT sec.UserRoles (UserId, RoleId) VALUES (@UserId, @rid);
            IF NOT EXISTS (SELECT 1 FROM org.OrganizationUsers WHERE UserId = @UserId)
                INSERT org.OrganizationUsers (UserId, OrganizationId) SELECT @UserId, (SELECT TOP 1 OrganizationId FROM org.Organizations ORDER BY OrganizationId);
        END
        ELSE
        BEGIN
            IF @UserId = @ActorUserId AND @RoleName = N'Administrator' THROW 50002, N'You cannot remove your own Administrator role.', 1;
            DELETE sec.UserRoles WHERE UserId = @UserId AND RoleId = @rid;
            IF @@ROWCOUNT = 0 THROW 50004, N'The user does not have this role.', 1;
        END
        IF @own = 1 COMMIT;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 ROLLBACK TRANSACTION; ELSE IF @own = 1 AND @@TRANCOUNT > 0 ROLLBACK TRANSACTION; ELSE IF @own = 0 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_AssignRole;
        THROW;
    END CATCH
END
GO

/* ---------------- audit and scheduler (administrator) ---------------- */
CREATE OR ALTER PROCEDURE audit.usp_ListAuditLogs
    @ActorUserId INT, @TableName NVARCHAR(128) = NULL, @RecordId NVARCHAR(50) = NULL, @FromDate DATETIME2(0) = NULL, @ToDate DATETIME2(0) = NULL, @Page INT = 1, @PageSize INT = 50
AS
BEGIN
    SET NOCOUNT ON;
    EXEC sec.usp_Authorize @ActorUserId, N'Administrator';
    IF @Page < 1 SET @Page = 1; IF @PageSize < 1 OR @PageSize > 200 SET @PageSize = 50;
    SELECT a.AuditId, a.TableName, a.RecordId, a.Action, LEFT(a.OldValues, 4000) AS OldValues, LEFT(a.NewValues, 4000) AS NewValues,
           a.ChangedByUserId, u.DisplayName AS ChangedBy, a.ChangedAt, COUNT(*) OVER () AS TotalCount
    FROM audit.AuditLogs a LEFT JOIN sec.Users u ON u.UserId = a.ChangedByUserId
    WHERE (@TableName IS NULL OR a.TableName = @TableName) AND (@RecordId IS NULL OR a.RecordId = @RecordId)
      AND (@FromDate IS NULL OR a.ChangedAt >= @FromDate) AND (@ToDate IS NULL OR a.ChangedAt <= @ToDate)
    ORDER BY a.AuditId DESC OFFSET (@Page - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END
GO

CREATE OR ALTER PROCEDURE audit.usp_ListLoginHistory @ActorUserId INT, @Email NVARCHAR(256) = NULL, @SuccessOnly BIT = NULL, @Page INT = 1, @PageSize INT = 50
AS
BEGIN
    SET NOCOUNT ON;
    EXEC sec.usp_Authorize @ActorUserId, N'Administrator';
    IF @Page < 1 SET @Page = 1; IF @PageSize < 1 OR @PageSize > 200 SET @PageSize = 50;
    SELECT LoginHistoryId, UserId, Email, Success, FailureReason, IpAddress, AttemptedAt, COUNT(*) OVER () AS TotalCount
    FROM audit.LoginHistory
    WHERE (@Email IS NULL OR Email LIKE N'%' + @Email + N'%') AND (@SuccessOnly IS NULL OR Success = @SuccessOnly)
    ORDER BY LoginHistoryId DESC OFFSET (@Page - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END
GO

CREATE OR ALTER PROCEDURE sched.usp_ListJobs @ActorUserId INT
AS
BEGIN
    SET NOCOUNT ON;
    EXEC sec.usp_Authorize @ActorUserId, N'Administrator';
    SELECT j.JobDefinitionId, j.JobName, j.Owner, j.Description, j.ScheduleDescription, j.IsEnabled,
           l.StartedAt AS LastStartedAt, l.FinishedAt AS LastFinishedAt, l.Outcome AS LastOutcome, l.RowsAffected AS LastRowsAffected, l.ErrorMessage AS LastError
    FROM sched.JobDefinitions j
    OUTER APPLY (SELECT TOP (1) * FROM sched.JobExecutionHistory h WHERE h.JobDefinitionId = j.JobDefinitionId ORDER BY h.ExecutionId DESC) l
    ORDER BY j.Owner, j.JobName;
END
GO

CREATE OR ALTER PROCEDURE sched.usp_ListJobHistory @ActorUserId INT, @JobDefinitionId INT, @Top INT = 50
AS
BEGIN
    SET NOCOUNT ON;
    EXEC sec.usp_Authorize @ActorUserId, N'Administrator';
    IF NOT EXISTS (SELECT 1 FROM sched.JobDefinitions WHERE JobDefinitionId = @JobDefinitionId) THROW 50004, N'Job not found.', 1;
    IF @Top < 1 OR @Top > 500 SET @Top = 50;
    SELECT TOP (@Top) ExecutionId, StartedAt, FinishedAt, Outcome, RowsAffected, ErrorMessage, HostName FROM sched.JobExecutionHistory WHERE JobDefinitionId = @JobDefinitionId ORDER BY ExecutionId DESC;
END
GO

/* ---------------- organisation and reference data ---------------- */
CREATE OR ALTER PROCEDURE org.usp_ListCustomers @ActorUserId INT
AS
BEGIN
    SET NOCOUNT ON;
    EXEC sec.usp_Authorize @ActorUserId, N'Customer,Recruiter,HRManager,Administrator';
    DECLARE @mine INT = CASE WHEN sec.fn_IsStaff(@ActorUserId) = 1 THEN NULL ELSE sec.fn_UserCustomerId(@ActorUserId) END;
    IF sec.fn_IsStaff(@ActorUserId) = 0 AND @mine IS NULL THROW 50005, N'This login is not linked to a customer.', 1;
    SELECT c.CustomerId, c.CustomerCode, c.Name, c.Industry, c.Status, c.BillingEmail, c.PaymentTermsDays, am.DisplayName AS AccountManager,
           CASE WHEN sec.fn_IsStaff(@ActorUserId) = 1 THEN bill.fn_CustomerOutstandingBalance(c.CustomerId) ELSE bill.fn_CustomerOutstandingBalance(@mine) END AS OutstandingBalance
    FROM org.Customers c LEFT JOIN sec.Users am ON am.UserId = c.AccountManagerUserId
    WHERE (@mine IS NULL OR c.CustomerId = @mine) ORDER BY c.Name;
END
GO

CREATE OR ALTER PROCEDURE org.usp_GetCustomer @ActorUserId INT, @CustomerId INT
AS
BEGIN
    SET NOCOUNT ON;
    EXEC sec.usp_Authorize @ActorUserId, N'Customer,Recruiter,HRManager,Administrator';
    IF sec.fn_IsStaff(@ActorUserId) = 0 AND ISNULL(sec.fn_UserCustomerId(@ActorUserId), -1) <> @CustomerId THROW 50004, N'Customer not found.', 1;
    IF NOT EXISTS (SELECT 1 FROM org.Customers WHERE CustomerId = @CustomerId) THROW 50004, N'Customer not found.', 1;
    SELECT c.CustomerId, c.CustomerCode, c.Name, c.Industry, c.Status, c.BillingEmail, c.BillingAddress, c.PaymentTermsDays, c.AccountManagerUserId, c.RowVer,
           bill.fn_CustomerOutstandingBalance(c.CustomerId) AS OutstandingBalance FROM org.Customers c WHERE c.CustomerId = @CustomerId;
    SELECT cu.UserId, u.DisplayName, u.Email, cu.JobTitle, cu.IsPrimaryContact FROM org.CustomerUsers cu JOIN sec.Users u ON u.UserId = cu.UserId WHERE cu.CustomerId = @CustomerId ORDER BY cu.IsPrimaryContact DESC, u.DisplayName;
END
GO

CREATE OR ALTER PROCEDURE org.usp_UpsertCustomer
    @ActorUserId INT, @CustomerId INT = NULL, @CustomerCode NVARCHAR(20), @Name NVARCHAR(200), @Industry NVARCHAR(100) = NULL, @Status VARCHAR(15) = 'Active',
    @BillingEmail NVARCHAR(256) = NULL, @BillingAddress NVARCHAR(300) = NULL, @PaymentTermsDays INT = 30, @AccountManagerUserId INT = NULL, @RowVer BINARY(8) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @own BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;
    BEGIN TRY
        IF @own = 1 BEGIN BEGIN TRANSACTION; END ELSE BEGIN SAVE TRANSACTION sp_UpsertCustomer; END
        EXEC sec.usp_Authorize @ActorUserId, N'Administrator';
        SET @CustomerCode = UPPER(LTRIM(RTRIM(@CustomerCode))); SET @Name = LTRIM(RTRIM(@Name));
        IF LEN(ISNULL(@CustomerCode, N'')) = 0 OR LEN(ISNULL(@Name, N'')) = 0 THROW 50001, N'Customer code and name are required.', 1;
        IF @Status NOT IN ('Active', 'Inactive', 'OnHold') THROW 50001, N'Invalid status.', 1;
        IF @PaymentTermsDays NOT BETWEEN 0 AND 365 THROW 50001, N'Payment terms must be 0-365 days.', 1;
        IF @AccountManagerUserId IS NOT NULL AND sec.fn_UserHasRole(@AccountManagerUserId, N'Recruiter') = 0 THROW 50001, N'The account manager must be an active Recruiter.', 1;
        IF EXISTS (SELECT 1 FROM org.Customers WHERE (CustomerCode = @CustomerCode OR Name = @Name) AND (@CustomerId IS NULL OR CustomerId <> @CustomerId)) THROW 50003, N'A customer with this code or name already exists.', 1;
        IF @CustomerId IS NULL
        BEGIN
            INSERT org.Customers (CustomerCode, Name, Industry, Status, BillingEmail, BillingAddress, PaymentTermsDays, AccountManagerUserId)
            VALUES (@CustomerCode, @Name, @Industry, @Status, @BillingEmail, @BillingAddress, @PaymentTermsDays, @AccountManagerUserId);
            SET @CustomerId = SCOPE_IDENTITY();
        END
        ELSE
        BEGIN
            DECLARE @rv BINARY(8) = (SELECT RowVer FROM org.Customers WITH (UPDLOCK) WHERE CustomerId = @CustomerId);
            IF @rv IS NULL THROW 50004, N'Customer not found.', 1;
            IF @RowVer IS NOT NULL AND @RowVer <> @rv THROW 50006, N'The customer was changed by someone else. Reload and try again.', 1;
            UPDATE org.Customers SET CustomerCode = @CustomerCode, Name = @Name, Industry = @Industry, Status = @Status, BillingEmail = @BillingEmail, BillingAddress = @BillingAddress,
                   PaymentTermsDays = @PaymentTermsDays, AccountManagerUserId = @AccountManagerUserId, UpdatedAt = SYSUTCDATETIME() WHERE CustomerId = @CustomerId;
        END
        IF @own = 1 COMMIT;
        SELECT CustomerId, RowVer FROM org.Customers WHERE CustomerId = @CustomerId;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 ROLLBACK TRANSACTION; ELSE IF @own = 1 AND @@TRANCOUNT > 0 ROLLBACK TRANSACTION; ELSE IF @own = 0 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_UpsertCustomer;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE org.usp_ListDepartments @ActorUserId INT
AS
BEGIN
    SET NOCOUNT ON;
    EXEC sec.usp_Authorize @ActorUserId, N'Recruiter,HRManager,Administrator';
    SELECT d.DepartmentId, d.Name, d.CostCenter, d.IsActive, d.HeadUserId, h.DisplayName AS HeadName,
           (SELECT COUNT(*) FROM hr.Employees e WHERE e.DepartmentId = d.DepartmentId AND e.Status <> 'Terminated') AS Employees
    FROM org.Departments d LEFT JOIN sec.Users h ON h.UserId = d.HeadUserId ORDER BY d.Name;
END
GO

CREATE OR ALTER PROCEDURE org.usp_UpsertDepartment @ActorUserId INT, @DepartmentId INT = NULL, @Name NVARCHAR(100), @CostCenter NVARCHAR(30) = NULL, @HeadUserId INT = NULL, @IsActive BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    EXEC sec.usp_Authorize @ActorUserId, N'HRManager,Administrator';
    SET @Name = LTRIM(RTRIM(@Name));
    IF LEN(ISNULL(@Name, N'')) = 0 THROW 50001, N'Department name is required.', 1;
    IF @HeadUserId IS NOT NULL AND sec.fn_IsStaff(@HeadUserId) = 0 THROW 50001, N'The department head must be a staff user.', 1;
    DECLARE @org INT = (SELECT TOP 1 OrganizationId FROM org.Organizations ORDER BY OrganizationId);
    IF EXISTS (SELECT 1 FROM org.Departments WHERE OrganizationId = @org AND Name = @Name AND (@DepartmentId IS NULL OR DepartmentId <> @DepartmentId)) THROW 50003, N'A department with this name already exists.', 1;
    IF @DepartmentId IS NULL
    BEGIN INSERT org.Departments (OrganizationId, Name, CostCenter, HeadUserId, IsActive) VALUES (@org, @Name, @CostCenter, @HeadUserId, @IsActive); SET @DepartmentId = SCOPE_IDENTITY(); END
    ELSE
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM org.Departments WHERE DepartmentId = @DepartmentId) THROW 50004, N'Department not found.', 1;
        UPDATE org.Departments SET Name = @Name, CostCenter = @CostCenter, HeadUserId = @HeadUserId, IsActive = @IsActive WHERE DepartmentId = @DepartmentId;
    END
    SELECT @DepartmentId AS DepartmentId;
END
GO

CREATE OR ALTER PROCEDURE org.usp_ListLocations @ActorUserId INT
AS
BEGIN
    SET NOCOUNT ON;
    EXEC sec.usp_Authorize @ActorUserId, N'Recruiter,HRManager,Administrator';
    SELECT LocationId, Name, City, Country, IsActive FROM org.Locations ORDER BY Name;
END
GO

CREATE OR ALTER PROCEDURE rec.usp_ListSources @ActorUserId INT
AS
BEGIN
    SET NOCOUNT ON;
    EXEC sec.usp_Authorize @ActorUserId, N'Candidate,Recruiter,HRManager,Administrator';
    SELECT SourceId, Name, SourceType FROM rec.RecruitmentSources WHERE IsActive = 1 ORDER BY Name;
END
GO

CREATE OR ALTER PROCEDURE bill.usp_ListRateCards @ActorUserId INT, @CustomerId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    EXEC sec.usp_Authorize @ActorUserId, N'Customer,Recruiter,Administrator';
    IF sec.fn_UserHasRole(@ActorUserId, N'Recruiter') = 0 AND sec.fn_UserHasRole(@ActorUserId, N'Administrator') = 0
    BEGIN
        DECLARE @mine INT = sec.fn_UserCustomerId(@ActorUserId);
        IF @mine IS NULL THROW 50005, N'This login is not linked to a customer.', 1;
        IF @CustomerId IS NOT NULL AND @CustomerId <> @mine THROW 50004, N'Customer not found.', 1;
        SET @CustomerId = @mine;
    END
    SELECT r.RateCardId, r.CustomerId, c.Name AS CustomerName, r.RoleCategory, r.StandardBillRate, r.Currency, r.EffectiveFrom, r.EffectiveTo, r.IsActive
    FROM bill.RateCards r JOIN org.Customers c ON c.CustomerId = r.CustomerId WHERE (@CustomerId IS NULL OR r.CustomerId = @CustomerId) ORDER BY c.Name, r.RoleCategory, r.EffectiveFrom DESC;
END
GO

CREATE OR ALTER PROCEDURE bill.usp_UpsertRateCard
    @ActorUserId INT, @RateCardId INT = NULL, @CustomerId INT, @RoleCategory NVARCHAR(100), @StandardBillRate DECIMAL(10,2), @Currency CHAR(3) = 'INR',
    @EffectiveFrom DATE, @EffectiveTo DATE = NULL, @IsActive BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    EXEC sec.usp_Authorize @ActorUserId, N'Administrator';
    IF NOT EXISTS (SELECT 1 FROM org.Customers WHERE CustomerId = @CustomerId) THROW 50004, N'Customer not found.', 1;
    IF @StandardBillRate <= 0 THROW 50001, N'The rate must be positive.', 1;
    IF @EffectiveTo IS NOT NULL AND @EffectiveTo < @EffectiveFrom THROW 50001, N'EffectiveTo cannot be before EffectiveFrom.', 1;
    IF LEN(LTRIM(RTRIM(ISNULL(@RoleCategory, N'')))) = 0 THROW 50001, N'Role category is required.', 1;
    IF @RateCardId IS NULL
    BEGIN INSERT bill.RateCards (CustomerId, RoleCategory, StandardBillRate, Currency, EffectiveFrom, EffectiveTo, IsActive) VALUES (@CustomerId, LTRIM(RTRIM(@RoleCategory)), @StandardBillRate, @Currency, @EffectiveFrom, @EffectiveTo, @IsActive); SET @RateCardId = SCOPE_IDENTITY(); END
    ELSE
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM bill.RateCards WHERE RateCardId = @RateCardId AND CustomerId = @CustomerId) THROW 50004, N'Rate card not found.', 1;
        UPDATE bill.RateCards SET RoleCategory = LTRIM(RTRIM(@RoleCategory)), StandardBillRate = @StandardBillRate, Currency = @Currency, EffectiveFrom = @EffectiveFrom, EffectiveTo = @EffectiveTo, IsActive = @IsActive WHERE RateCardId = @RateCardId;
    END
    SELECT @RateCardId AS RateCardId;
END
GO

/* ---------------- notifications (in-app list) ---------------- */
CREATE OR ALTER PROCEDURE notify.usp_ListMyNotifications @ActorUserId INT, @UnreadOnly BIT = 0, @Top INT = 30
AS
BEGIN
    SET NOCOUNT ON;
    EXEC sec.usp_Authorize @ActorUserId, N'Candidate,Contractor,Customer,Recruiter,HRManager,Administrator';
    IF @Top < 1 OR @Top > 200 SET @Top = 30;
    SELECT TOP (@Top) NotificationId, TemplateCode, Subject, Body, IsRead, CreatedAt, RelatedEntityType, RelatedEntityId, Status AS EmailStatus, ProcessedAt AS EmailedAt,
           (SELECT COUNT(*) FROM notify.NotificationQueue n2 WHERE n2.RecipientUserId = @ActorUserId AND n2.IsRead = 0 AND notify.fn_IsSecurityTemplate(n2.TemplateCode) = 0) AS UnreadCount
    FROM notify.NotificationQueue WHERE RecipientUserId = @ActorUserId AND (@UnreadOnly = 0 OR IsRead = 0)
      AND notify.fn_IsSecurityTemplate(TemplateCode) = 0      -- sign-in links go by e-mail only (Phase 9)
    ORDER BY NotificationId DESC;
END
GO

/* ---------------- hiring requests, jobs, employees ---------------- */
CREATE OR ALTER PROCEDURE hr.usp_ListEmployeeRequisitions @ActorUserId INT, @Status VARCHAR(12) = NULL, @Page INT = 1, @PageSize INT = 25
AS
BEGIN
    SET NOCOUNT ON;
    EXEC sec.usp_Authorize @ActorUserId, N'Recruiter,HRManager,Administrator';
    IF @Page < 1 SET @Page = 1; IF @PageSize < 1 OR @PageSize > 200 SET @PageSize = 25;
    DECLARE @recOnly BIT = CASE WHEN sec.fn_UserHasRole(@ActorUserId, N'HRManager') = 0 AND sec.fn_UserHasRole(@ActorUserId, N'Administrator') = 0 THEN 1 ELSE 0 END;   -- recruiters see only APPROVED requests
    SELECT r.EmployeeRequisitionId, r.RequisitionNo, r.Title, d.Name AS Department, l.Name AS Location, r.Headcount, r.EmploymentType, r.BudgetMax, r.RequiredByDate, r.Status,
           u.DisplayName AS RequestedBy, r.RequestedByUserId, r.SubmittedAt, r.CreatedAt, r.RowVer,
           (SELECT ISNULL(SUM(jr.Openings), 0) FROM rec.JobRequisitions jr WHERE jr.EmployeeRequisitionId = r.EmployeeRequisitionId AND jr.Status NOT IN ('Closed', 'Expired')) AS OpeningsPlanned,
           COUNT(*) OVER () AS TotalCount
    FROM hr.EmployeeRequisitions r JOIN org.Departments d ON d.DepartmentId = r.DepartmentId LEFT JOIN org.Locations l ON l.LocationId = r.LocationId JOIN sec.Users u ON u.UserId = r.RequestedByUserId
    WHERE (@Status IS NULL OR r.Status = @Status) AND (@recOnly = 0 OR r.Status = 'Approved')
    ORDER BY r.CreatedAt DESC, r.EmployeeRequisitionId DESC OFFSET (@Page - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END
GO

CREATE OR ALTER PROCEDURE hr.usp_GetEmployeeRequisition @ActorUserId INT, @EmployeeRequisitionId INT
AS
BEGIN
    SET NOCOUNT ON;
    EXEC sec.usp_Authorize @ActorUserId, N'Recruiter,HRManager,Administrator';
    IF NOT EXISTS (SELECT 1 FROM hr.EmployeeRequisitions WHERE EmployeeRequisitionId = @EmployeeRequisitionId
                   AND (Status = 'Approved' OR sec.fn_UserHasRole(@ActorUserId, N'HRManager') = 1 OR sec.fn_UserHasRole(@ActorUserId, N'Administrator') = 1))
        THROW 50004, N'Hiring request not found.', 1;
    SELECT r.EmployeeRequisitionId, r.RequisitionNo, r.Title, r.DepartmentId, d.Name AS Department, r.LocationId, l.Name AS Location, r.Headcount, r.EmploymentType, r.Justification,
           r.BudgetMax, r.RequiredByDate, r.Status, u.DisplayName AS RequestedBy, r.RequestedByUserId, r.SubmittedAt, r.RowVer
    FROM hr.EmployeeRequisitions r JOIN org.Departments d ON d.DepartmentId = r.DepartmentId LEFT JOIN org.Locations l ON l.LocationId = r.LocationId JOIN sec.Users u ON u.UserId = r.RequestedByUserId
    WHERE r.EmployeeRequisitionId = @EmployeeRequisitionId;
    SELECT a.Decision, a.Comments, a.DecidedAt, u.DisplayName AS Approver FROM hr.HiringApprovals a JOIN sec.Users u ON u.UserId = a.ApproverUserId WHERE a.EmployeeRequisitionId = @EmployeeRequisitionId ORDER BY a.DecidedAt;
    SELECT JobRequisitionId, JobCode, Title, Openings, Status FROM rec.JobRequisitions WHERE EmployeeRequisitionId = @EmployeeRequisitionId ORDER BY JobRequisitionId;
END
GO

CREATE OR ALTER PROCEDURE rec.usp_ListJobs @ActorUserId INT, @Status VARCHAR(20) = NULL, @Q NVARCHAR(100) = NULL, @Page INT = 1, @PageSize INT = 25
AS
BEGIN
    SET NOCOUNT ON;
    EXEC sec.usp_Authorize @ActorUserId, N'Recruiter,HRManager,Administrator';
    IF @Page < 1 SET @Page = 1; IF @PageSize < 1 OR @PageSize > 200 SET @PageSize = 25;
    SELECT jr.JobRequisitionId, jr.JobCode, jr.Title, d.Name AS Department, l.Name AS Location, jr.Openings, jr.Status, jr.EmploymentType, o.DisplayName AS OwnerRecruiter, jr.OwnerRecruiterUserId,
           jr.OpenedAt, jr.ClosesBy, jr.EmployeeRequisitionId, jr.RowVer,
           (SELECT TOP (1) p.JobPostingId FROM rec.JobPostings p WHERE p.JobRequisitionId = jr.JobRequisitionId AND p.Status = 'Published') AS PublishedPostingId,
           (SELECT COUNT(*) FROM cand.JobApplications a JOIN rec.JobPostings p ON p.JobPostingId = a.JobPostingId WHERE p.JobRequisitionId = jr.JobRequisitionId) AS Applications,
           COUNT(*) OVER () AS TotalCount
    FROM rec.JobRequisitions jr JOIN org.Departments d ON d.DepartmentId = jr.DepartmentId LEFT JOIN org.Locations l ON l.LocationId = jr.LocationId JOIN sec.Users o ON o.UserId = jr.OwnerRecruiterUserId
    WHERE (@Status IS NULL OR jr.Status = @Status) AND (@Q IS NULL OR jr.Title LIKE N'%' + @Q + N'%' OR jr.JobCode LIKE N'%' + @Q + N'%')
    ORDER BY jr.JobRequisitionId DESC OFFSET (@Page - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END
GO

CREATE OR ALTER PROCEDURE rec.usp_GetJob @ActorUserId INT, @JobRequisitionId INT
AS
BEGIN
    SET NOCOUNT ON;
    EXEC sec.usp_Authorize @ActorUserId, N'Recruiter,HRManager,Administrator';
    IF NOT EXISTS (SELECT 1 FROM rec.JobRequisitions WHERE JobRequisitionId = @JobRequisitionId) THROW 50004, N'Job not found.', 1;
    SELECT jr.JobRequisitionId, jr.JobCode, jr.Title, jr.DepartmentId, d.Name AS Department, jr.LocationId, jr.EmploymentType, jr.Openings, jr.Status, jr.OwnerRecruiterUserId, o.DisplayName AS OwnerRecruiter,
           jr.OpenedAt, jr.ClosesBy, jr.EmployeeRequisitionId, jr.RowVer, ds.Summary, ds.Responsibilities, ds.Qualifications, ds.MinExperienceYears, ds.SalaryMin, ds.SalaryMax
    FROM rec.JobRequisitions jr JOIN org.Departments d ON d.DepartmentId = jr.DepartmentId JOIN sec.Users o ON o.UserId = jr.OwnerRecruiterUserId
    OUTER APPLY (SELECT TOP (1) * FROM rec.JobDescriptions x WHERE x.JobRequisitionId = jr.JobRequisitionId ORDER BY x.VersionNo DESC) ds
    WHERE jr.JobRequisitionId = @JobRequisitionId;
    SELECT SkillName, IsRequired, MinYears FROM rec.JobSkills WHERE JobRequisitionId = @JobRequisitionId ORDER BY IsRequired DESC, SkillName;
    SELECT JobPostingId, PostedAt, ClosesAt, Status FROM rec.JobPostings WHERE JobRequisitionId = @JobRequisitionId ORDER BY JobPostingId DESC;
    SELECT a.Decision, a.Comments, a.DecidedAt, u.DisplayName AS Approver FROM rec.JobApprovals a JOIN sec.Users u ON u.UserId = a.ApproverUserId WHERE a.JobRequisitionId = @JobRequisitionId ORDER BY a.DecidedAt;
END
GO

-- Published jobs for candidates (and staff previews). Salary range is shown; the candidate's own applied/not-applied state is included.
CREATE OR ALTER PROCEDURE rec.usp_ListPublishedJobs @ActorUserId INT, @Q NVARCHAR(100) = NULL, @DepartmentId INT = NULL, @Page INT = 1, @PageSize INT = 20
AS
BEGIN
    SET NOCOUNT ON;
    EXEC sec.usp_Authorize @ActorUserId, N'Candidate,Recruiter,HRManager,Administrator';
    IF @Page < 1 SET @Page = 1; IF @PageSize < 1 OR @PageSize > 100 SET @PageSize = 20;
    DECLARE @cid INT = cand.fn_CandidateIdForUser(@ActorUserId);
    SELECT p.JobPostingId, jr.JobCode, jr.Title, d.Name AS Department, l.Name AS Location, jr.EmploymentType, jr.Openings, p.PostedAt, p.ClosesAt, ds.Summary, ds.MinExperienceYears, ds.SalaryMin, ds.SalaryMax,
           CASE WHEN @cid IS NOT NULL AND EXISTS (SELECT 1 FROM cand.JobApplications a WHERE a.CandidateId = @cid AND a.JobPostingId = p.JobPostingId AND a.Status <> 'Withdrawn') THEN 1 ELSE 0 END AS AlreadyApplied,
           COUNT(*) OVER () AS TotalCount
    FROM rec.JobPostings p JOIN rec.JobRequisitions jr ON jr.JobRequisitionId = p.JobRequisitionId JOIN org.Departments d ON d.DepartmentId = jr.DepartmentId LEFT JOIN org.Locations l ON l.LocationId = jr.LocationId
    OUTER APPLY (SELECT TOP (1) * FROM rec.JobDescriptions x WHERE x.JobRequisitionId = jr.JobRequisitionId ORDER BY x.VersionNo DESC) ds
    WHERE p.Status = 'Published' AND jr.Status = 'Open' AND (p.ClosesAt IS NULL OR p.ClosesAt > SYSUTCDATETIME())
      AND (@DepartmentId IS NULL OR jr.DepartmentId = @DepartmentId) AND (@Q IS NULL OR jr.Title LIKE N'%' + @Q + N'%' OR ds.Summary LIKE N'%' + @Q + N'%')
    ORDER BY p.PostedAt DESC OFFSET (@Page - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END
GO

CREATE OR ALTER PROCEDURE rec.usp_GetPublishedJob @ActorUserId INT, @JobPostingId INT
AS
BEGIN
    SET NOCOUNT ON;
    EXEC sec.usp_Authorize @ActorUserId, N'Candidate,Recruiter,HRManager,Administrator';
    DECLARE @jid INT = (SELECT p.JobRequisitionId FROM rec.JobPostings p JOIN rec.JobRequisitions jr ON jr.JobRequisitionId = p.JobRequisitionId
                        WHERE p.JobPostingId = @JobPostingId AND p.Status = 'Published' AND jr.Status = 'Open');
    IF @jid IS NULL THROW 50004, N'Job posting not found.', 1;
    DECLARE @cid INT = cand.fn_CandidateIdForUser(@ActorUserId);
    SELECT p.JobPostingId, jr.JobCode, jr.Title, d.Name AS Department, l.Name AS Location, jr.EmploymentType, jr.Openings, p.PostedAt, p.ClosesAt,
           ds.Summary, ds.Responsibilities, ds.Qualifications, ds.MinExperienceYears, ds.SalaryMin, ds.SalaryMax,
           CASE WHEN @cid IS NOT NULL AND EXISTS (SELECT 1 FROM cand.JobApplications a WHERE a.CandidateId = @cid AND a.JobPostingId = p.JobPostingId AND a.Status <> 'Withdrawn') THEN 1 ELSE 0 END AS AlreadyApplied
    FROM rec.JobPostings p JOIN rec.JobRequisitions jr ON jr.JobRequisitionId = p.JobRequisitionId JOIN org.Departments d ON d.DepartmentId = jr.DepartmentId LEFT JOIN org.Locations l ON l.LocationId = jr.LocationId
    OUTER APPLY (SELECT TOP (1) * FROM rec.JobDescriptions x WHERE x.JobRequisitionId = jr.JobRequisitionId ORDER BY x.VersionNo DESC) ds
    WHERE p.JobPostingId = @JobPostingId;
    SELECT SkillName, IsRequired, MinYears FROM rec.JobSkills WHERE JobRequisitionId = @jid ORDER BY IsRequired DESC, SkillName;
END
GO

CREATE OR ALTER PROCEDURE hr.usp_ListEmployees @ActorUserId INT, @Status VARCHAR(12) = NULL, @DepartmentId INT = NULL, @Q NVARCHAR(100) = NULL, @Page INT = 1, @PageSize INT = 25
AS
BEGIN
    SET NOCOUNT ON;
    EXEC sec.usp_Authorize @ActorUserId, N'HRManager,Administrator';
    IF @Page < 1 SET @Page = 1; IF @PageSize < 1 OR @PageSize > 200 SET @PageSize = 25;
    SELECT e.EmployeeId, e.EmployeeNo, c.FirstName + N' ' + c.LastName AS EmployeeName, c.Email, d.Name AS Department, e.JobTitle, e.StartDate, e.Status, e.Salary, m.DisplayName AS Manager,
           (SELECT COUNT(*) FROM hr.EmployeeOnboarding o WHERE o.EmployeeId = e.EmployeeId AND o.Status IN ('Completed', 'Waived')) AS OnboardingDone,
           (SELECT COUNT(*) FROM hr.EmployeeOnboarding o WHERE o.EmployeeId = e.EmployeeId) AS OnboardingTotal, COUNT(*) OVER () AS TotalCount
    FROM hr.Employees e JOIN cand.Candidates c ON c.CandidateId = e.CandidateId JOIN org.Departments d ON d.DepartmentId = e.DepartmentId LEFT JOIN sec.Users m ON m.UserId = e.ManagerUserId
    WHERE (@Status IS NULL OR e.Status = @Status) AND (@DepartmentId IS NULL OR e.DepartmentId = @DepartmentId)
      AND (@Q IS NULL OR c.FirstName LIKE N'%' + @Q + N'%' OR c.LastName LIKE N'%' + @Q + N'%' OR e.EmployeeNo LIKE N'%' + @Q + N'%')
    ORDER BY e.EmployeeId DESC OFFSET (@Page - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END
GO

CREATE OR ALTER PROCEDURE hr.usp_GetEmployee @ActorUserId INT, @EmployeeId INT
AS
BEGIN
    SET NOCOUNT ON;
    EXEC sec.usp_Authorize @ActorUserId, N'HRManager,Administrator';
    IF NOT EXISTS (SELECT 1 FROM hr.Employees WHERE EmployeeId = @EmployeeId) THROW 50004, N'Employee not found.', 1;
    SELECT e.EmployeeId, e.EmployeeNo, e.CandidateId, c.FirstName + N' ' + c.LastName AS EmployeeName, c.Email, c.Phone, d.Name AS Department, l.Name AS Location, e.JobTitle, e.StartDate, e.Status, e.Salary, m.DisplayName AS Manager, e.JobOfferId
    FROM hr.Employees e JOIN cand.Candidates c ON c.CandidateId = e.CandidateId JOIN org.Departments d ON d.DepartmentId = e.DepartmentId LEFT JOIN org.Locations l ON l.LocationId = e.LocationId LEFT JOIN sec.Users m ON m.UserId = e.ManagerUserId
    WHERE e.EmployeeId = @EmployeeId;
    SELECT o.OnboardingId, o.TaskName, o.Category, o.DueDate, o.Status, o.CompletedAt, u.DisplayName AS CompletedBy, o.Notes FROM hr.EmployeeOnboarding o LEFT JOIN sec.Users u ON u.UserId = o.CompletedByUserId WHERE o.EmployeeId = @EmployeeId ORDER BY o.OnboardingId;
    SELECT EventType, EffectiveDate, Details, RecordedAt FROM hr.EmploymentHistory WHERE EmployeeId = @EmployeeId ORDER BY HistoryId;
END
GO
