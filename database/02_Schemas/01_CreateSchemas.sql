/* ============================================================================
   TAMS - 02_Schemas / 01_CreateSchemas.sql
   Creates the 13 functional schemas. Repeatable.
   ========================================================================== */
USE TalentAcquisitionDB;
GO
SET NOCOUNT ON;

DECLARE @schemas TABLE (Name SYSNAME NOT NULL PRIMARY KEY);
INSERT @schemas (Name) VALUES
 (N'sec'),(N'org'),(N'rec'),(N'cand'),(N'hr'),(N'staff'),(N'time'),
 (N'bill'),(N'doc'),(N'notify'),(N'audit'),(N'report'),(N'sched');

DECLARE @n SYSNAME, @sql NVARCHAR(200);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT Name FROM @schemas ORDER BY Name;
OPEN c; FETCH NEXT FROM c INTO @n;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF SCHEMA_ID(@n) IS NULL
    BEGIN
        SET @sql = N'CREATE SCHEMA ' + QUOTENAME(@n) + N' AUTHORIZATION dbo;';
        EXEC sys.sp_executesql @sql;
        PRINT 'Created schema ' + @n;
    END
    FETCH NEXT FROM c INTO @n;
END
CLOSE c; DEALLOCATE c;
GO
