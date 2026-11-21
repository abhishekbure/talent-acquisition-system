/* ============================================================================
   TAMS - 06_StoredProcedures / 07_Security_Roles.sql        (Phase 3.5: database permissions)
   LEAST PRIVILEGE: the application never touches tables directly.
     tams_app_role        EXECUTE on the procedure schemas + the table types, SELECT on report views.
     tams_report_role     SELECT on report views only (read-only dashboards / BI).
   Ownership chaining (all objects owned by dbo) lets the procedures read/write the tables while the
   caller has NO table permission at all. A real login is mapped to tams_app_role at deployment time
   (Phase 15); the *_demo users below have no login and exist so the permissions can be tested with EXECUTE AS.
   Repeatable.
   ========================================================================== */
USE TalentAcquisitionDB;
GO
SET NOCOUNT ON;

IF DATABASE_PRINCIPAL_ID(N'tams_app_role') IS NULL    CREATE ROLE tams_app_role    AUTHORIZATION dbo;
IF DATABASE_PRINCIPAL_ID(N'tams_report_role') IS NULL CREATE ROLE tams_report_role AUTHORIZATION dbo;
GO

GRANT EXECUTE ON SCHEMA::sec    TO tams_app_role;
GRANT EXECUTE ON SCHEMA::cand   TO tams_app_role;
GRANT EXECUTE ON SCHEMA::rec    TO tams_app_role;
GRANT EXECUTE ON SCHEMA::hr     TO tams_app_role;
GRANT EXECUTE ON SCHEMA::staff  TO tams_app_role;
GRANT EXECUTE ON SCHEMA::[time] TO tams_app_role;
GRANT EXECUTE ON SCHEMA::bill   TO tams_app_role;
GRANT EXECUTE ON SCHEMA::notify TO tams_app_role;
GRANT EXECUTE ON SCHEMA::org    TO tams_app_role;
GRANT EXECUTE ON SCHEMA::audit  TO tams_app_role;
GRANT EXECUTE ON SCHEMA::sched  TO tams_app_role;
GRANT EXECUTE ON SCHEMA::doc    TO tams_app_role;      -- document metadata procedures (Phase 8)
GRANT EXECUTE ON SCHEMA::report TO tams_app_role;      -- report.usp_* (dashboards)
GRANT SELECT  ON SCHEMA::report TO tams_app_role;       -- views (dashboards)
GRANT EXECUTE ON TYPE::dbo.IdList               TO tams_app_role;
GRANT EXECUTE ON TYPE::rec.JobSkillList         TO tams_app_role;
GRANT EXECUTE ON TYPE::[time].TimesheetEntryList TO tams_app_role;
GRANT SELECT  ON SCHEMA::report TO tams_report_role;
GO

-- Users WITHOUT login, for permission tests only (never usable to connect).
IF DATABASE_PRINCIPAL_ID(N'tams_app_demo')    IS NULL CREATE USER tams_app_demo    WITHOUT LOGIN;
IF DATABASE_PRINCIPAL_ID(N'tams_report_demo') IS NULL CREATE USER tams_report_demo WITHOUT LOGIN;
GO
IF NOT EXISTS (SELECT 1 FROM sys.database_role_members rm WHERE rm.role_principal_id = DATABASE_PRINCIPAL_ID(N'tams_app_role') AND rm.member_principal_id = DATABASE_PRINCIPAL_ID(N'tams_app_demo'))
    ALTER ROLE tams_app_role ADD MEMBER tams_app_demo;
IF NOT EXISTS (SELECT 1 FROM sys.database_role_members rm WHERE rm.role_principal_id = DATABASE_PRINCIPAL_ID(N'tams_report_role') AND rm.member_principal_id = DATABASE_PRINCIPAL_ID(N'tams_report_demo'))
    ALTER ROLE tams_report_role ADD MEMBER tams_report_demo;
GO

