/* ============================================================================
   TAMS - 06_StoredProcedures / 00_Types.sql
   Table types used for set-based parameters from ADO.NET (SqlDbType.Structured).
   Types cannot be altered in place; they are created only when missing.
   ========================================================================== */
USE TalentAcquisitionDB;
GO
IF TYPE_ID(N'dbo.IdList') IS NULL
    CREATE TYPE dbo.IdList AS TABLE (Id INT NOT NULL PRIMARY KEY);
GO
IF TYPE_ID(N'rec.JobSkillList') IS NULL
    CREATE TYPE rec.JobSkillList AS TABLE (
        SkillName  NVARCHAR(100) NOT NULL PRIMARY KEY,
        IsRequired BIT NOT NULL DEFAULT (1),
        MinYears   DECIMAL(4,1) NOT NULL DEFAULT (0));
GO
IF TYPE_ID(N'[time].TimesheetEntryList') IS NULL
    CREATE TYPE [time].TimesheetEntryList AS TABLE (
        WorkDate   DATE NOT NULL,
        Hours      DECIMAL(5,2) NOT NULL,
        EntryType  VARCHAR(10) NOT NULL DEFAULT ('Regular'),
        IsBillable BIT NOT NULL DEFAULT (1),
        Notes      NVARCHAR(500) NULL,
        PRIMARY KEY (WorkDate, EntryType));
GO
