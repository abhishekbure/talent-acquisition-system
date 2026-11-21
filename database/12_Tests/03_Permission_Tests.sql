/* ============================================================================
   TAMS - 12_Tests / 03_Permission_Tests.sql   (Phase 3.5 / 13: least privilege)
   Impersonates the no-login demo users with EXECUTE AS and proves what they can and cannot do.
   Data-changing probes run in a transaction that is rolled back; DDL-denial probes run outside
   it (a denied DDL statement dooms an open transaction).
   ========================================================================== */
USE TalentAcquisitionDB;
GO
SET NOCOUNT ON;
DECLARE @r TABLE (Id INT IDENTITY(1,1), Name NVARCHAR(220), Ok BIT, Detail NVARCHAR(300));
DECLARE @e INT, @n INT;

BEGIN TRANSACTION;

-- ---- application role: tams_app_demo ----
EXECUTE AS USER = N'tams_app_demo';
SET @e = 0; BEGIN TRY SET @n = (SELECT COUNT(*) FROM cand.Candidates); END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
REVERT; INSERT @r VALUES (N'P01 the app role cannot SELECT from a table directly (229)', IIF(@e = 229, 1, 0), CONCAT(N'err=', @e));
EXECUTE AS USER = N'tams_app_demo';
SET @e = 0; BEGIN TRY SET @n = (SELECT COUNT(*) FROM sec.Users); END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
REVERT; INSERT @r VALUES (N'P02 ...so password hashes in sec.Users are unreachable by direct query (229)', IIF(@e = 229, 1, 0), CONCAT(N'err=', @e));
EXECUTE AS USER = N'tams_app_demo';
SET @e = 0; BEGIN TRY INSERT sec.UserRoles (UserId, RoleId) VALUES (1, 1); END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
REVERT; INSERT @r VALUES (N'P03 the app role cannot INSERT into a table directly (229)', IIF(@e = 229, 1, 0), CONCAT(N'err=', @e));
EXECUTE AS USER = N'tams_app_demo';
SET @e = 0; BEGIN TRY DELETE audit.AuditLogs; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
REVERT; INSERT @r VALUES (N'P04 the app role cannot touch the audit log directly (229)', IIF(@e = 229, 1, 0), CONCAT(N'err=', @e));
EXECUTE AS USER = N'tams_app_demo';
SET @e = 0; BEGIN TRY EXEC sec.usp_RecordLoginAttempt N'nobody@nowhere.example', 0, N'permission test'; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
REVERT; INSERT @r VALUES (N'P05 the app role CAN execute a stored procedure that writes tables (ownership chaining)', IIF(@e = 0 AND EXISTS (SELECT 1 FROM audit.LoginHistory WHERE Email = N'nobody@nowhere.example'), 1, 0), CONCAT(N'err=', @e));
EXECUTE AS USER = N'tams_app_demo';
SET @e = 0; BEGIN TRY SET @n = (SELECT COUNT(*) FROM report.vw_OpenRequisitions); END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
REVERT; INSERT @r VALUES (N'P06 the app role CAN read the report views', IIF(@e = 0, 1, 0), CONCAT(N'err=', @e));
EXECUTE AS USER = N'tams_app_demo';
SET @e = 0; BEGIN TRY DECLARE @pl dbo.IdList; INSERT @pl VALUES (1); END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
REVERT; INSERT @r VALUES (N'P07 the app role may use the table-valued parameter types', IIF(@e = 0, 1, 0), CONCAT(N'err=', @e));

-- ---- report role: tams_report_demo ----
EXECUTE AS USER = N'tams_report_demo';
SET @e = 0; BEGIN TRY SET @n = (SELECT COUNT(*) FROM report.vw_CustomerInvoices); END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
REVERT; INSERT @r VALUES (N'P11 the report role CAN read report views', IIF(@e = 0, 1, 0), CONCAT(N'err=', @e));
EXECUTE AS USER = N'tams_report_demo';
SET @e = 0; BEGIN TRY EXEC sec.usp_RecordLoginAttempt N'x@y.example', 0; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
REVERT; INSERT @r VALUES (N'P12 the report role cannot execute procedures (229)', IIF(@e = 229, 1, 0), CONCAT(N'err=', @e));
EXECUTE AS USER = N'tams_report_demo';
SET @e = 0; BEGIN TRY SET @n = (SELECT COUNT(*) FROM bill.Invoices); END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
REVERT; INSERT @r VALUES (N'P13 the report role cannot read base tables (229)', IIF(@e = 229, 1, 0), CONCAT(N'err=', @e));

-- ---- worker role: tams_worker_demo (Phase 13) ----
EXECUTE AS USER = N'tams_worker_demo';
SET @e = 0; BEGIN TRY SET @n = (SELECT COUNT(*) FROM notify.NotificationQueue); END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
REVERT; INSERT @r VALUES (N'P17 the worker role cannot SELECT from a table directly, not even the queue it processes (229)', IIF(@e = 229, 1, 0), CONCAT(N'err=', @e));
EXECUTE AS USER = N'tams_worker_demo';
SET @e = 0; BEGIN TRY EXEC sec.usp_RecordLoginAttempt N'worker@nowhere.example', 0, N'permission test'; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
REVERT; INSERT @r VALUES (N'P18 the worker role cannot execute the API''s procedures (229)', IIF(@e = 229, 1, 0), CONCAT(N'err=', @e));
EXECUTE AS USER = N'tams_worker_demo';
SET @e = 0; BEGIN TRY SET @n = (SELECT COUNT(*) FROM report.vw_CustomerInvoices); END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
REVERT; INSERT @r VALUES (N'P19 the worker role cannot read the report views (229)', IIF(@e = 229, 1, 0), CONCAT(N'err=', @e));
EXECUTE AS USER = N'tams_worker_demo';
SET @e = 0; BEGIN TRY EXEC sec.usp_Ping; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
REVERT; INSERT @r VALUES (N'P20 the worker role CAN run the health ping (used by --check)', IIF(@e = 0, 1, 0), CONCAT(N'err=', @e));
EXECUTE AS USER = N'tams_app_demo';
SET @e = 0; BEGIN TRY EXEC notify.usp_QueueDailyReport; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
REVERT; INSERT @r VALUES (N'P21 the app role (API) cannot run a worker procedure (229)', IIF(@e = 229, 1, 0), CONCAT(N'err=', @e));

IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
INSERT @r VALUES (N'P16 the data-changing probes left no trace (login-history probe rolled back)', IIF(NOT EXISTS (SELECT 1 FROM audit.LoginHistory WHERE Email = N'nobody@nowhere.example'), 1, 0), N'');

-- ---- DDL denial (outside any transaction; nothing can be changed because every statement is denied) ----
EXECUTE AS USER = N'tams_app_demo';
SET @e = 0; BEGIN TRY EXEC (N'CREATE TABLE dbo.zz_nope (x INT)'); END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
REVERT; INSERT @r VALUES (N'P08 the app role cannot run DDL (CREATE TABLE) (262)', IIF(@e = 262, 1, 0), CONCAT(N'err=', @e));
EXECUTE AS USER = N'tams_app_demo';
SET @e = 0; BEGIN TRY EXEC (N'DROP TABLE cand.Candidates'); END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
REVERT; INSERT @r VALUES (N'P09 the app role cannot DROP a table (permission error)', IIF(@e IN (3701, 229, 262), 1, 0), CONCAT(N'err=', @e));
EXECUTE AS USER = N'tams_app_demo';
SET @e = 0; BEGIN TRY EXEC (N'DISABLE TRIGGER ALL ON cand.Candidates'); END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
REVERT; INSERT @r VALUES (N'P10 the app role cannot disable audit triggers', IIF(@e <> 0 AND (SELECT COUNT(*) FROM sys.triggers WHERE parent_id = OBJECT_ID(N'cand.Candidates') AND is_disabled = 1) = 0, 1, 0), CONCAT(N'err=', @e));

-- ---- inventory ----
INSERT @r VALUES (N'P14 no explicit table-level grants exist to the app/report roles',
    IIF(NOT EXISTS (SELECT 1 FROM sys.database_permissions p JOIN sys.objects o ON o.object_id = p.major_id AND p.class = 1 AND o.type = 'U'
                    WHERE p.grantee_principal_id IN (DATABASE_PRINCIPAL_ID(N'tams_app_role'), DATABASE_PRINCIPAL_ID(N'tams_report_role')) AND p.state IN ('G', 'W')), 1, 0), N'');
INSERT @r VALUES (N'P15 the 3 roles and the 3 demo users exist; demo users have no login (cannot connect)',
    IIF(DATABASE_PRINCIPAL_ID(N'tams_app_role') IS NOT NULL AND DATABASE_PRINCIPAL_ID(N'tams_report_role') IS NOT NULL AND DATABASE_PRINCIPAL_ID(N'tams_worker_role') IS NOT NULL
        AND (SELECT COUNT(*) FROM sys.database_principals WHERE name IN (N'tams_app_demo', N'tams_report_demo', N'tams_worker_demo') AND authentication_type = 0) = 3, 1, 0), N'');
DECLARE @wGrants INT = (SELECT COUNT(*) FROM sys.database_permissions WHERE grantee_principal_id = DATABASE_PRINCIPAL_ID(N'tams_worker_role') AND state IN ('G', 'W'));
DECLARE @wProcs INT = (SELECT COUNT(*) FROM sys.database_permissions p JOIN sys.objects o ON o.object_id = p.major_id
                       WHERE p.class = 1 AND p.grantee_principal_id = DATABASE_PRINCIPAL_ID(N'tams_worker_role') AND p.state = 'G' AND p.permission_name = 'EXECUTE' AND o.type = 'P');
DECLARE @aDenied INT = (SELECT COUNT(*) FROM sys.database_permissions p
                        WHERE p.class = 1 AND p.grantee_principal_id = DATABASE_PRINCIPAL_ID(N'tams_app_role') AND p.state = 'D' AND p.permission_name = 'EXECUTE'
                          AND p.major_id IN (SELECT major_id FROM sys.database_permissions WHERE class = 1 AND grantee_principal_id = DATABASE_PRINCIPAL_ID(N'tams_worker_role')));
INSERT @r VALUES (N'P22 the worker role holds exactly 14 grants, all EXECUTE on single procedures (no schema-wide grant); the app role is denied the 13 worker-only ones',
    IIF(@wGrants = 14 AND @wProcs = 14 AND @aDenied = 13, 1, 0), CONCAT(N'grants=', @wGrants, N' procs=', @wProcs, N' app denied=', @aDenied));

DECLARE @line NVARCHAR(500);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT CASE WHEN Ok = 1 THEN N'PASS  ' ELSE N'FAIL  ' END + Name + CASE WHEN Ok = 0 THEN N'  -> ' + Detail ELSE N'' END FROM @r ORDER BY Id;
OPEN c; FETCH NEXT FROM c INTO @line; WHILE @@FETCH_STATUS = 0 BEGIN PRINT @line; FETCH NEXT FROM c INTO @line; END CLOSE c; DEALLOCATE c;
DECLARE @total INT = (SELECT COUNT(*) FROM @r), @passed INT = (SELECT COUNT(*) FROM @r WHERE Ok = 1);
PRINT CONCAT(N'--- Permission tests: ', @passed, N' passed, ', @total - @passed, N' failed, ', @total, N' total ---');
IF @passed <> @total RAISERROR(N'Permission tests FAILED', 16, 1);
GO
