/* ============================================================================
   TAMS - 06_StoredProcedures / 06_Timesheets_Billing.sql
   Timesheets (contractor enters, customer approves) and billing (invoice from approved
   billable entries x contract BILL rate, payments, balances).
   ========================================================================== */
USE TalentAcquisitionDB;
GO

/* ---------------- timesheets ---------------- */
-- Contractor saves (replaces) the entries of ONE week of one of THEIR OWN assignments. Allowed while Draft or Rejected.
CREATE OR ALTER PROCEDURE [time].usp_SaveTimesheet
    @ActorUserId INT, @WeekStartDate DATE, @Entries [time].TimesheetEntryList READONLY, @AssignmentId INT = NULL, @RowVer BINARY(8) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @own BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;
    BEGIN TRY
        IF @own = 1 BEGIN BEGIN TRANSACTION; END ELSE BEGIN SAVE TRANSACTION sp_SaveTimesheet; END
        EXEC sec.usp_Authorize @ActorUserId, N'Contractor';
        DECLARE @ctr INT = staff.fn_ContractorIdForUser(@ActorUserId);
        IF @ctr IS NULL THROW 50005, N'This login is not linked to an active contractor.', 1;
        IF DATEDIFF(DAY, '19000101', @WeekStartDate) % 7 <> 0 THROW 50001, N'The week must start on a Monday.', 1;
        DECLARE @thisMonday DATE = CAST(DATEADD(DAY, (DATEDIFF(DAY, '19000101', CAST(SYSUTCDATETIME() AS DATE)) / 7) * 7, '19000101') AS DATE);
        IF @WeekStartDate > @thisMonday THROW 50002, N'Time cannot be entered for a future week.', 1;
        IF @AssignmentId IS NULL
        BEGIN
            DECLARE @cnt INT, @only INT;
            SELECT @cnt = COUNT(*), @only = MIN(AssignmentId) FROM staff.Assignments WHERE ContractorId = @ctr AND Status = 'Active';
            IF @cnt <> 1 THROW 50001, N'Specify the AssignmentId (you do not have exactly one active assignment).', 1;
            SET @AssignmentId = @only;
        END
        DECLARE @cust INT, @astart DATE, @aend DATE, @astatus VARCHAR(10);
        SELECT @cust = CustomerId, @astart = StartDate, @aend = EndDate, @astatus = Status FROM staff.Assignments WHERE AssignmentId = @AssignmentId AND ContractorId = @ctr;
        IF @cust IS NULL THROW 50004, N'Assignment not found.', 1;                       -- someone else's assignment looks missing
        IF @astatus <> 'Active' THROW 50002, N'The assignment is not active.', 1;
        DECLARE @weekEnd DATE = DATEADD(DAY, 6, @WeekStartDate);
        IF EXISTS (SELECT 1 FROM @Entries WHERE WorkDate < @WeekStartDate OR WorkDate > @weekEnd) THROW 50001, N'Every entry must fall inside the selected week.', 1;
        IF EXISTS (SELECT 1 FROM @Entries WHERE Hours <= 0 OR Hours > 24) THROW 50001, N'Hours per entry must be greater than 0 and at most 24.', 1;
        IF EXISTS (SELECT 1 FROM @Entries WHERE EntryType NOT IN ('Regular', 'Overtime')) THROW 50001, N'Entry type must be Regular or Overtime.', 1;
        IF EXISTS (SELECT WorkDate FROM @Entries GROUP BY WorkDate HAVING SUM(Hours) > 24) THROW 50001, N'More than 24 hours entered for a single day.', 1;
        IF EXISTS (SELECT 1 FROM @Entries WHERE WorkDate < @astart OR (@aend IS NOT NULL AND WorkDate > @aend)) THROW 50002, N'Entries fall outside the assignment period.', 1;

        DECLARE @tid INT, @status VARCHAR(10), @rv BINARY(8);
        SELECT @tid = TimesheetId, @status = Status, @rv = RowVer FROM [time].Timesheets WITH (UPDLOCK, HOLDLOCK) WHERE AssignmentId = @AssignmentId AND WeekStartDate = @WeekStartDate;
        IF @tid IS NULL
        BEGIN
            INSERT [time].Timesheets (AssignmentId, ContractorId, CustomerId, WeekStartDate, Status) VALUES (@AssignmentId, @ctr, @cust, @WeekStartDate, 'Draft');
            SET @tid = SCOPE_IDENTITY();
        END
        ELSE
        BEGIN
            IF @status NOT IN ('Draft', 'Rejected') THROW 50002, N'Only a Draft or Rejected timesheet can be edited.', 1;
            IF @RowVer IS NOT NULL AND @RowVer <> @rv THROW 50006, N'The timesheet was changed by someone else. Reload and try again.', 1;
        END
        DELETE [time].TimesheetEntries WHERE TimesheetId = @tid;
        INSERT [time].TimesheetEntries (TimesheetId, WorkDate, Hours, EntryType, IsBillable, Notes) SELECT @tid, WorkDate, Hours, EntryType, IsBillable, Notes FROM @Entries;
        UPDATE [time].Timesheets SET TotalHours = ISNULL((SELECT SUM(Hours) FROM [time].TimesheetEntries WHERE TimesheetId = @tid), 0),
               Status = 'Draft', SubmittedAt = NULL, UpdatedAt = SYSUTCDATETIME() WHERE TimesheetId = @tid;
        IF @own = 1 COMMIT;
        SELECT TimesheetId, TotalHours, Status, RowVer FROM [time].Timesheets WHERE TimesheetId = @tid;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 ROLLBACK TRANSACTION; ELSE IF @own = 1 AND @@TRANCOUNT > 0 ROLLBACK TRANSACTION; ELSE IF @own = 0 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_SaveTimesheet;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE [time].usp_SubmitTimesheet @ActorUserId INT, @TimesheetId INT
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @own BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;
    BEGIN TRY
        IF @own = 1 BEGIN BEGIN TRANSACTION; END ELSE BEGIN SAVE TRANSACTION sp_SubmitTs; END
        EXEC sec.usp_Authorize @ActorUserId, N'Contractor';
        DECLARE @ctr INT = staff.fn_ContractorIdForUser(@ActorUserId), @status VARCHAR(10), @total DECIMAL(6,2), @cust INT, @week DATE;
        SELECT @status = Status, @total = TotalHours, @cust = CustomerId, @week = WeekStartDate FROM [time].Timesheets WITH (UPDLOCK, HOLDLOCK) WHERE TimesheetId = @TimesheetId AND ContractorId = @ctr;
        IF @status IS NULL THROW 50004, N'Timesheet not found.', 1;
        IF @status NOT IN ('Draft', 'Rejected') THROW 50002, N'Only a Draft or Rejected timesheet can be submitted.', 1;
        IF @total <= 0 THROW 50002, N'A timesheet with no hours cannot be submitted.', 1;
        UPDATE [time].Timesheets SET Status = 'Submitted', SubmittedAt = SYSUTCDATETIME(), UpdatedAt = SYSUTCDATETIME() WHERE TimesheetId = @TimesheetId;
        DECLARE @subj NVARCHAR(300) = N'Timesheet submitted for approval (week of ' + CONVERT(NVARCHAR(10), @week, 120) + N')';
        DECLARE @key NVARCHAR(180) = N'TSSUB:' + CAST(@TimesheetId AS NVARCHAR(12)) + N':' + CONVERT(NVARCHAR(30), SYSUTCDATETIME(), 126);
        EXEC notify.usp_EnqueueForCustomer @cust, 'TIMESHEET_SUBMITTED', @subj, @subj, @key, 'Timesheet', @TimesheetId;
        IF @own = 1 COMMIT;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 ROLLBACK TRANSACTION; ELSE IF @own = 1 AND @@TRANCOUNT > 0 ROLLBACK TRANSACTION; ELSE IF @own = 0 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_SubmitTs;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE [time].usp_ApproveTimesheet @ActorUserId INT, @TimesheetId INT, @Comments NVARCHAR(500) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @own BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;
    BEGIN TRY
        IF @own = 1 BEGIN BEGIN TRANSACTION; END ELSE BEGIN SAVE TRANSACTION sp_ApproveTs; END
        EXEC sec.usp_Authorize @ActorUserId, N'Customer';
        DECLARE @mine INT = sec.fn_UserCustomerId(@ActorUserId);
        IF @mine IS NULL THROW 50005, N'This login is not linked to a customer.', 1;
        DECLARE @status VARCHAR(10), @ctr INT, @week DATE;
        SELECT @status = Status, @ctr = ContractorId, @week = WeekStartDate FROM [time].Timesheets WITH (UPDLOCK, HOLDLOCK) WHERE TimesheetId = @TimesheetId AND CustomerId = @mine;   -- isolation filter
        IF @status IS NULL THROW 50004, N'Timesheet not found.', 1;
        IF @status <> 'Submitted' THROW 50002, N'Only a Submitted timesheet can be approved.', 1;
        INSERT [time].TimesheetApprovals (TimesheetId, ApprovedByUserId, Comments) VALUES (@TimesheetId, @ActorUserId, @Comments);
        UPDATE [time].Timesheets SET Status = 'Approved', UpdatedAt = SYSUTCDATETIME() WHERE TimesheetId = @TimesheetId;
        DECLARE @cuser INT = (SELECT UserId FROM staff.Contractors WHERE ContractorId = @ctr);
        DECLARE @subj NVARCHAR(300) = N'Your timesheet for the week of ' + CONVERT(NVARCHAR(10), @week, 120) + N' was approved';
        EXEC notify.usp_Enqueue 'TIMESHEET_APPROVED', @cuser, @subj, @subj, N'TSAPPR', 'Timesheet', @TimesheetId;
        IF @own = 1 COMMIT;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 ROLLBACK TRANSACTION; ELSE IF @own = 1 AND @@TRANCOUNT > 0 ROLLBACK TRANSACTION; ELSE IF @own = 0 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_ApproveTs;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE [time].usp_RejectTimesheet @ActorUserId INT, @TimesheetId INT, @Reason NVARCHAR(500)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @own BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;
    BEGIN TRY
        IF @own = 1 BEGIN BEGIN TRANSACTION; END ELSE BEGIN SAVE TRANSACTION sp_RejectTs; END
        EXEC sec.usp_Authorize @ActorUserId, N'Customer';
        DECLARE @mine INT = sec.fn_UserCustomerId(@ActorUserId);
        IF @mine IS NULL THROW 50005, N'This login is not linked to a customer.', 1;
        IF LEN(LTRIM(RTRIM(ISNULL(@Reason, N'')))) = 0 THROW 50001, N'A reason is required when rejecting a timesheet.', 1;
        DECLARE @status VARCHAR(10), @ctr INT, @week DATE;
        SELECT @status = Status, @ctr = ContractorId, @week = WeekStartDate FROM [time].Timesheets WITH (UPDLOCK, HOLDLOCK) WHERE TimesheetId = @TimesheetId AND CustomerId = @mine;
        IF @status IS NULL THROW 50004, N'Timesheet not found.', 1;
        IF @status <> 'Submitted' THROW 50002, N'Only a Submitted timesheet can be rejected.', 1;
        INSERT [time].TimesheetRejections (TimesheetId, RejectedByUserId, Reason) VALUES (@TimesheetId, @ActorUserId, LTRIM(RTRIM(@Reason)));
        UPDATE [time].Timesheets SET Status = 'Rejected', UpdatedAt = SYSUTCDATETIME() WHERE TimesheetId = @TimesheetId;
        DECLARE @cuser INT = (SELECT UserId FROM staff.Contractors WHERE ContractorId = @ctr);
        DECLARE @subj NVARCHAR(300) = N'Your timesheet for the week of ' + CONVERT(NVARCHAR(10), @week, 120) + N' was rejected';
        DECLARE @key NVARCHAR(180) = N'TSREJ:' + CAST(@TimesheetId AS NVARCHAR(12)) + N':' + CONVERT(NVARCHAR(30), SYSUTCDATETIME(), 126);
        EXEC notify.usp_Enqueue 'TIMESHEET_REJECTED', @cuser, @subj, @Reason, @key, 'Timesheet', @TimesheetId;
        IF @own = 1 COMMIT;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 ROLLBACK TRANSACTION; ELSE IF @own = 1 AND @@TRANCOUNT > 0 ROLLBACK TRANSACTION; ELSE IF @own = 0 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_RejectTs;
        THROW;
    END CATCH
END
GO

-- Customer sees only its own pending timesheets; staff can pass any customer.
CREATE OR ALTER PROCEDURE [time].usp_ListPendingTimesheets @ActorUserId INT, @CustomerId INT = NULL, @Top INT = 500
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
    IF @Top IS NULL OR @Top < 1 OR @Top > 5000 SET @Top = 500;   -- Phase 13: lists are capped (newest first); the API says when more exist
    SELECT TOP (@Top) TimesheetId, CustomerId, CustomerName, ContractorId, ContractorNo, ContractorName, RoleTitle, WeekStartDate, TotalHours, SubmittedAt, DaysWaiting
    FROM report.vw_PendingTimesheets WHERE (@CustomerId IS NULL OR CustomerId = @CustomerId) ORDER BY SubmittedAt;
END
GO

-- A contractor's own timesheets, with the latest rejection reason.
CREATE OR ALTER PROCEDURE [time].usp_GetMyTimesheets @ActorUserId INT, @Top INT = 20
AS
BEGIN
    SET NOCOUNT ON;
    EXEC sec.usp_Authorize @ActorUserId, N'Contractor';
    DECLARE @ctr INT = staff.fn_ContractorIdForUser(@ActorUserId);
    IF @ctr IS NULL THROW 50005, N'This login is not linked to an active contractor.', 1;
    SELECT TOP (@Top) t.TimesheetId, t.AssignmentId, t.WeekStartDate, t.Status, t.TotalHours, t.SubmittedAt, t.RowVer,
           (SELECT TOP (1) r.Reason FROM [time].TimesheetRejections r WHERE r.TimesheetId = t.TimesheetId ORDER BY r.RejectedAt DESC, r.RejectionId DESC) AS LastRejectionReason
    FROM [time].Timesheets t WHERE t.ContractorId = @ctr ORDER BY t.WeekStartDate DESC;
END
GO

/* ---------------- billing ---------------- */
-- Builds a DRAFT invoice from APPROVED, not-yet-invoiced timesheets whose whole week lies inside the period.
-- Lines use the BILL rate in force on each work day (overtime x overtime-bill multiplier). Pay rates are never touched.
CREATE OR ALTER PROCEDURE bill.usp_GenerateInvoice @ActorUserId INT, @CustomerId INT, @PeriodStart DATE, @PeriodEnd DATE, @TaxRate DECIMAL(5,2) = 18.00
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @own BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;
    BEGIN TRY
        IF @own = 1 BEGIN BEGIN TRANSACTION; END ELSE BEGIN SAVE TRANSACTION sp_GenInvoice; END
        EXEC sec.usp_Authorize @ActorUserId, N'Recruiter,Administrator';
        IF NOT EXISTS (SELECT 1 FROM org.Customers WHERE CustomerId = @CustomerId) THROW 50004, N'Customer not found.', 1;
        IF @PeriodEnd < @PeriodStart THROW 50001, N'The period end cannot be before the period start.', 1;
        IF @TaxRate < 0 OR @TaxRate > 100 THROW 50001, N'Tax rate must be between 0 and 100.', 1;

        DECLARE @ts TABLE (TimesheetId INT PRIMARY KEY);
        INSERT @ts (TimesheetId)
        SELECT t.TimesheetId FROM [time].Timesheets t WITH (UPDLOCK, HOLDLOCK)
        WHERE t.CustomerId = @CustomerId AND t.Status = 'Approved' AND t.WeekStartDate >= @PeriodStart AND DATEADD(DAY, 6, t.WeekStartDate) <= @PeriodEnd
          AND EXISTS (SELECT 1 FROM [time].TimesheetEntries e WHERE e.TimesheetId = t.TimesheetId AND e.IsBillable = 1)
          AND NOT EXISTS (SELECT 1 FROM [time].TimesheetEntries e JOIN bill.InvoiceLines l ON l.TimesheetEntryId = e.EntryId WHERE e.TimesheetId = t.TimesheetId);
        IF NOT EXISTS (SELECT 1 FROM @ts) THROW 50002, N'There are no approved, uninvoiced timesheets for this customer in the period.', 1;

        DECLARE @lines TABLE (EntryId INT PRIMARY KEY, Descr NVARCHAR(300), Hrs DECIMAL(5,2), Rate DECIMAL(10,2), Cur CHAR(3), WorkDate DATE, AssignmentId INT);
        INSERT @lines (EntryId, Descr, Hrs, Rate, Cur, WorkDate, AssignmentId)
        SELECT e.EntryId,
               cd.FirstName + N' ' + cd.LastName + N' - ' + a.RoleTitle + N' - ' + CONVERT(NVARCHAR(10), e.WorkDate, 120) + N' (' + e.EntryType + N')',
               e.Hours,
               CASE WHEN r.ContractRateId IS NULL THEN NULL WHEN e.EntryType = 'Overtime' THEN CAST(r.BillRate * r.OvertimeBillMultiplier AS DECIMAL(10,2)) ELSE r.BillRate END,
               r.Currency, e.WorkDate, t.AssignmentId
        FROM @ts x
        JOIN [time].Timesheets t ON t.TimesheetId = x.TimesheetId
        JOIN [time].TimesheetEntries e ON e.TimesheetId = t.TimesheetId AND e.IsBillable = 1
        JOIN staff.Assignments a ON a.AssignmentId = t.AssignmentId
        JOIN staff.Contractors k ON k.ContractorId = t.ContractorId
        JOIN cand.Candidates cd ON cd.CandidateId = k.CandidateId
        OUTER APPLY staff.fn_EffectiveRate(a.ContractId, e.WorkDate) r;

        IF EXISTS (SELECT 1 FROM @lines WHERE Rate IS NULL)
        BEGIN
            DECLARE @bad NVARCHAR(200) = N'No contract rate is in force on ' + CONVERT(NVARCHAR(10), (SELECT MIN(WorkDate) FROM @lines WHERE Rate IS NULL), 120) + N' (assignment ' + CAST((SELECT MIN(AssignmentId) FROM @lines WHERE Rate IS NULL) AS NVARCHAR(12)) + N').';
            THROW 50002, @bad, 1;
        END
        IF (SELECT COUNT(DISTINCT Cur) FROM @lines) > 1 THROW 50002, N'The billable entries use more than one currency; invoice them separately.', 1;

        DECLARE @n INT = NEXT VALUE FOR bill.seq_InvoiceNo;
        DECLARE @no NVARCHAR(30) = N'INV-' + CAST(YEAR(SYSUTCDATETIME()) AS NVARCHAR(4)) + N'-' + dbo.fn_PadNumber(@n, 4);
        INSERT bill.Invoices (InvoiceNo, CustomerId, PeriodStart, PeriodEnd, Currency, TaxRate, Status, GeneratedByUserId)
        VALUES (@no, @CustomerId, @PeriodStart, @PeriodEnd, (SELECT TOP (1) Cur FROM @lines), @TaxRate, 'Draft', @ActorUserId);
        DECLARE @iid INT = SCOPE_IDENTITY();
        INSERT bill.InvoiceLines (InvoiceId, TimesheetEntryId, Description, Hours, BillRate, LineTotal)
        SELECT @iid, EntryId, Descr, Hrs, Rate, CAST(Hrs * Rate AS DECIMAL(12,2)) FROM @lines;
        DECLARE @sub DECIMAL(12,2) = (SELECT SUM(LineTotal) FROM bill.InvoiceLines WHERE InvoiceId = @iid);
        DECLARE @tax DECIMAL(12,2) = CAST(ROUND(@sub * @TaxRate / 100.0, 2) AS DECIMAL(12,2));
        UPDATE bill.Invoices SET Subtotal = @sub, TaxAmount = @tax, Total = @sub + @tax, UpdatedAt = SYSUTCDATETIME() WHERE InvoiceId = @iid;
        IF @own = 1 COMMIT;
        SELECT InvoiceId, InvoiceNo, Subtotal, TaxAmount, Total, Status FROM bill.Invoices WHERE InvoiceId = @iid;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 ROLLBACK TRANSACTION; ELSE IF @own = 1 AND @@TRANCOUNT > 0 ROLLBACK TRANSACTION; ELSE IF @own = 0 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_GenInvoice;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE bill.usp_IssueInvoice @ActorUserId INT, @InvoiceId INT
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @own BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;
    BEGIN TRY
        IF @own = 1 BEGIN BEGIN TRANSACTION; END ELSE BEGIN SAVE TRANSACTION sp_IssueInvoice; END
        EXEC sec.usp_Authorize @ActorUserId, N'Recruiter,Administrator';
        DECLARE @status VARCHAR(15), @cust INT, @terms INT, @no NVARCHAR(30);
        SELECT @status = i.Status, @cust = i.CustomerId, @no = i.InvoiceNo, @terms = c.PaymentTermsDays
        FROM bill.Invoices i WITH (UPDLOCK, HOLDLOCK) JOIN org.Customers c ON c.CustomerId = i.CustomerId WHERE i.InvoiceId = @InvoiceId;
        IF @status IS NULL THROW 50004, N'Invoice not found.', 1;
        IF @status <> 'Draft' THROW 50002, N'Only a Draft invoice can be issued.', 1;
        IF NOT EXISTS (SELECT 1 FROM bill.InvoiceLines WHERE InvoiceId = @InvoiceId) THROW 50002, N'An invoice without lines cannot be issued.', 1;
        DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);
        UPDATE bill.Invoices SET Status = 'Issued', IssueDate = @today, DueDate = DATEADD(DAY, @terms, @today), UpdatedAt = SYSUTCDATETIME() WHERE InvoiceId = @InvoiceId;
        UPDATE t SET Status = 'Invoiced', UpdatedAt = SYSUTCDATETIME()
        FROM [time].Timesheets t
        WHERE t.Status = 'Approved' AND EXISTS (SELECT 1 FROM [time].TimesheetEntries e JOIN bill.InvoiceLines l ON l.TimesheetEntryId = e.EntryId
                                                WHERE e.TimesheetId = t.TimesheetId AND l.InvoiceId = @InvoiceId);
        DECLARE @subj NVARCHAR(300) = N'Invoice ' + @no + N' has been issued';
        EXEC notify.usp_EnqueueForCustomer @cust, 'INVOICE_ISSUED', @subj, @subj, N'INVISSUE', 'Invoice', @InvoiceId;
        IF @own = 1 COMMIT;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 ROLLBACK TRANSACTION; ELSE IF @own = 1 AND @@TRANCOUNT > 0 ROLLBACK TRANSACTION; ELSE IF @own = 0 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_IssueInvoice;
        THROW;
    END CATCH
END
GO

-- Void a Draft or Issued invoice that has no payments; its lines are released so the timesheets can be billed again.
CREATE OR ALTER PROCEDURE bill.usp_VoidInvoice @ActorUserId INT, @InvoiceId INT, @Reason NVARCHAR(300)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @own BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;
    BEGIN TRY
        IF @own = 1 BEGIN BEGIN TRANSACTION; END ELSE BEGIN SAVE TRANSACTION sp_VoidInvoice; END
        EXEC sec.usp_Authorize @ActorUserId, N'Recruiter,Administrator';
        IF LEN(LTRIM(RTRIM(ISNULL(@Reason, N'')))) = 0 THROW 50001, N'A reason is required.', 1;
        DECLARE @status VARCHAR(15);
        SELECT @status = Status FROM bill.Invoices WITH (UPDLOCK, HOLDLOCK) WHERE InvoiceId = @InvoiceId;
        IF @status IS NULL THROW 50004, N'Invoice not found.', 1;
        IF @status NOT IN ('Draft', 'Issued') THROW 50002, N'Only a Draft or Issued invoice can be voided.', 1;
        IF EXISTS (SELECT 1 FROM bill.Payments WHERE InvoiceId = @InvoiceId) THROW 50002, N'An invoice with payments cannot be voided.', 1;
        UPDATE t SET Status = 'Approved', UpdatedAt = SYSUTCDATETIME()
        FROM [time].Timesheets t
        WHERE t.Status = 'Invoiced' AND EXISTS (SELECT 1 FROM [time].TimesheetEntries e JOIN bill.InvoiceLines l ON l.TimesheetEntryId = e.EntryId
                                                WHERE e.TimesheetId = t.TimesheetId AND l.InvoiceId = @InvoiceId);
        DELETE bill.InvoiceLines WHERE InvoiceId = @InvoiceId;
        UPDATE bill.Invoices SET Status = 'Void', UpdatedAt = SYSUTCDATETIME() WHERE InvoiceId = @InvoiceId;
        IF @own = 1 COMMIT;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 ROLLBACK TRANSACTION; ELSE IF @own = 1 AND @@TRANCOUNT > 0 ROLLBACK TRANSACTION; ELSE IF @own = 0 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_VoidInvoice;
        THROW;
    END CATCH
END
GO

-- The invoice row is locked (UPDLOCK, HOLDLOCK) so two concurrent payments cannot both pass the balance check.
CREATE OR ALTER PROCEDURE bill.usp_RecordPayment
    @ActorUserId INT, @InvoiceId INT, @Amount DECIMAL(12,2), @PaidOn DATE, @Method VARCHAR(15) = 'BankTransfer', @Reference NVARCHAR(100) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @own BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;
    BEGIN TRY
        IF @own = 1 BEGIN BEGIN TRANSACTION; END ELSE BEGIN SAVE TRANSACTION sp_RecordPayment; END
        EXEC sec.usp_Authorize @ActorUserId, N'Recruiter,Administrator';
        IF ISNULL(@Amount, 0) <= 0 THROW 50001, N'The payment amount must be greater than zero.', 1;
        IF @PaidOn > CAST(SYSUTCDATETIME() AS DATE) THROW 50001, N'The payment date cannot be in the future.', 1;
        IF @Method NOT IN ('BankTransfer', 'Cheque', 'Card', 'Cash') THROW 50001, N'Invalid payment method.', 1;
        DECLARE @status VARCHAR(15), @cust INT;
        SELECT @status = Status, @cust = CustomerId FROM bill.Invoices WITH (UPDLOCK, HOLDLOCK) WHERE InvoiceId = @InvoiceId;
        IF @status IS NULL THROW 50004, N'Invoice not found.', 1;
        IF @status NOT IN ('Issued', 'PartiallyPaid') THROW 50002, N'Payments can only be recorded against an Issued or PartiallyPaid invoice.', 1;
        DECLARE @balance DECIMAL(12,2) = bill.fn_InvoiceBalance(@InvoiceId);
        IF @Amount > @balance THROW 50002, N'The payment exceeds the outstanding balance of the invoice.', 1;
        INSERT bill.Payments (InvoiceId, CustomerId, Amount, PaidOn, Method, Reference, RecordedByUserId) VALUES (@InvoiceId, @cust, @Amount, @PaidOn, @Method, @Reference, @ActorUserId);
        DECLARE @newBalance DECIMAL(12,2) = @balance - @Amount;
        UPDATE bill.Invoices SET Status = CASE WHEN @newBalance = 0 THEN 'Paid' ELSE 'PartiallyPaid' END, UpdatedAt = SYSUTCDATETIME() WHERE InvoiceId = @InvoiceId;
        IF @own = 1 COMMIT;
        SELECT @InvoiceId AS InvoiceId, @newBalance AS Balance, CASE WHEN @newBalance = 0 THEN 'Paid' ELSE 'PartiallyPaid' END AS Status, bill.fn_CustomerOutstandingBalance(@cust) AS CustomerOutstanding;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 ROLLBACK TRANSACTION; ELSE IF @own = 1 AND @@TRANCOUNT > 0 ROLLBACK TRANSACTION; ELSE IF @own = 0 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_RecordPayment;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE bill.usp_ListInvoices @ActorUserId INT, @CustomerId INT = NULL, @Top INT = 500
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
    DECLARE @isCustomerView BIT = CASE WHEN sec.fn_UserHasRole(@ActorUserId, N'Recruiter') = 0 AND sec.fn_UserHasRole(@ActorUserId, N'Administrator') = 0 THEN 1 ELSE 0 END;
    IF @Top IS NULL OR @Top < 1 OR @Top > 5000 SET @Top = 500;   -- Phase 13: lists are capped (newest first); the API says when more exist
    SELECT TOP (@Top) InvoiceId, InvoiceNo, CustomerId, CustomerName, PeriodStart, PeriodEnd, IssueDate, DueDate, Status, Currency, Subtotal, TaxAmount, Total, AmountPaid, Balance, DaysOverdue
    FROM report.vw_CustomerInvoices
    WHERE (@CustomerId IS NULL OR CustomerId = @CustomerId) AND (@CustomerId IS NOT NULL OR Status <> 'Void')
      AND (@isCustomerView = 0 OR Status <> 'Draft')              -- drafts are internal until issued
    ORDER BY InvoiceId DESC;
END
GO

CREATE OR ALTER PROCEDURE bill.usp_GetCustomerBalance @ActorUserId INT, @CustomerId INT = NULL
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
    IF @CustomerId IS NULL OR NOT EXISTS (SELECT 1 FROM org.Customers WHERE CustomerId = @CustomerId) THROW 50004, N'Customer not found.', 1;
    SELECT @CustomerId AS CustomerId, bill.fn_CustomerOutstandingBalance(@CustomerId) AS OutstandingBalance;
END
GO
