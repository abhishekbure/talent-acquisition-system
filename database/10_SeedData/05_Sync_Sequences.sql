/* ============================================================================
   TAMS - 10_SeedData / 05_Sync_Sequences.sql
   Moves every business-number sequence to (highest existing number + 1) so generated
   numbers never collide with seeded or previously generated rows. Safe to re-run:
   the worst case is re-using a number that belonged to a rolled-back transaction.
   ========================================================================== */
USE TalentAcquisitionDB;
GO
SET NOCOUNT ON;

DECLARE @m TABLE (SeqSchema SYSNAME, SeqName SYSNAME, TableName NVARCHAR(256), ColName SYSNAME);
INSERT @m VALUES
 (N'rec',   N'seq_JobCode',      N'rec.JobRequisitions',        N'JobCode'),
 (N'hr',    N'seq_RequisitionNo',N'hr.EmployeeRequisitions',    N'RequisitionNo'),
 (N'hr',    N'seq_EmployeeNo',   N'hr.Employees',               N'EmployeeNo'),
 (N'cand',  N'seq_OfferNo',      N'cand.JobOffers',             N'OfferNo'),
 (N'staff', N'seq_ContractorNo', N'staff.Contractors',          N'ContractorNo'),
 (N'staff', N'seq_ContractNo',   N'staff.Contracts',            N'ContractNo'),
 (N'staff', N'seq_RequestNo',    N'staff.CustomerRequisitions', N'RequestNo'),
 (N'bill',  N'seq_InvoiceNo',    N'bill.Invoices',              N'InvoiceNo');

DECLARE @ss SYSNAME, @sn SYSNAME, @t NVARCHAR(256), @c SYSNAME, @sql NVARCHAR(1000), @next INT;
DECLARE cur CURSOR LOCAL FAST_FORWARD FOR SELECT SeqSchema, SeqName, TableName, ColName FROM @m;
OPEN cur; FETCH NEXT FROM cur INTO @ss, @sn, @t, @c;
WHILE @@FETCH_STATUS = 0
BEGIN
    -- numeric suffix = text after the last '-'
    SET @sql = N'SELECT @n = ISNULL(MAX(TRY_CAST(RIGHT(' + QUOTENAME(@c) + N', CHARINDEX(N''-'', REVERSE(' + QUOTENAME(@c) + N')) - 1) AS INT)), 0) + 1 FROM ' + @t + N';';
    EXEC sys.sp_executesql @sql, N'@n INT OUTPUT', @n = @next OUTPUT;
    SET @sql = N'ALTER SEQUENCE ' + QUOTENAME(@ss) + N'.' + QUOTENAME(@sn) + N' RESTART WITH ' + CAST(@next AS NVARCHAR(10)) + N';';
    EXEC sys.sp_executesql @sql;
    FETCH NEXT FROM cur INTO @ss, @sn, @t, @c;
END
CLOSE cur; DEALLOCATE cur;
PRINT 'Sequences synchronised with existing data.';
GO
