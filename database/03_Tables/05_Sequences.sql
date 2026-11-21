/* ============================================================================
   TAMS - 03_Tables / 05_Sequences.sql
   Concurrency-safe business-number generators (used by the stored procedures).
   Created at 1; 10_SeedData/05_Sync_Sequences.sql moves them past existing data.
   ========================================================================== */
USE TalentAcquisitionDB;
GO
SET NOCOUNT ON;

DECLARE @s TABLE (SchemaName SYSNAME, SeqName SYSNAME);
INSERT @s VALUES (N'rec', N'seq_JobCode'), (N'hr', N'seq_RequisitionNo'), (N'hr', N'seq_EmployeeNo'),
                 (N'cand', N'seq_OfferNo'), (N'staff', N'seq_ContractorNo'), (N'staff', N'seq_ContractNo'),
                 (N'staff', N'seq_RequestNo'), (N'bill', N'seq_InvoiceNo');
DECLARE @sch SYSNAME, @nm SYSNAME, @sql NVARCHAR(400);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT SchemaName, SeqName FROM @s;
OPEN c; FETCH NEXT FROM c INTO @sch, @nm;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF NOT EXISTS (SELECT 1 FROM sys.sequences WHERE name = @nm AND SCHEMA_NAME(schema_id) = @sch)
    BEGIN
        SET @sql = N'CREATE SEQUENCE ' + QUOTENAME(@sch) + N'.' + QUOTENAME(@nm) + N' AS INT START WITH 1 INCREMENT BY 1 NO CYCLE CACHE 10;';
        EXEC sys.sp_executesql @sql;
    END
    FETCH NEXT FROM c INTO @sch, @nm;
END
CLOSE c; DEALLOCATE c;
GO
