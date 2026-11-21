/* ============================================================================
   TAMS - 01_Database / 01_CreateDatabase.sql
   Creates TalentAcquisitionDB if (and only if) it does not already exist.
   NEVER drops or alters existing data. Safe to re-run.
   Run against the master database of the default local instance.
   ========================================================================== */
SET NOCOUNT ON;

IF DB_ID(N'TalentAcquisitionDB') IS NULL
BEGIN
    CREATE DATABASE TalentAcquisitionDB;
    PRINT 'Database TalentAcquisitionDB created.';
END
ELSE
    PRINT 'Database TalentAcquisitionDB already exists - left untouched.';
GO

-- FULL recovery so that transaction-log backups / point-in-time restore can be demonstrated (Phase 3.5).
IF (SELECT recovery_model_desc FROM sys.databases WHERE name = N'TalentAcquisitionDB') <> N'FULL'
    ALTER DATABASE TalentAcquisitionDB SET RECOVERY FULL;
GO

-- Phase 13: limit parallelism for THIS database only (database-scoped; the server settings stay as they are). With the server
-- defaults (cost threshold 5, MAXDOP = all 12 cores) nearly every multi-join query went 12-way parallel and concurrent users
-- spent their time in CXPACKET/CXCONSUMER waits; with MAXDOP 4 the API served 40 % more requests under the same load
-- (scripts\testing\Test-Performance.ps1). Re-runnable.
USE TalentAcquisitionDB;
GO
IF (SELECT value FROM sys.database_scoped_configurations WHERE name = N'MAXDOP') <> 4
    ALTER DATABASE SCOPED CONFIGURATION SET MAXDOP = 4;
GO