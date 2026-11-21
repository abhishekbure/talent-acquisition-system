/* ============================================================================
   TAMS - 12_Tests / 05_Document_Tests.sql        (Phase 8)
   Document metadata rules: who may add, list, download and delete documents of candidates, contractors,
   employees and contracts; primary resume; compliance verification; soft delete; audit; app-role permission.
   Runs inside a transaction that is rolled back.
   ========================================================================== */
USE TalentAcquisitionDB;
GO
SET NOCOUNT ON;
DECLARE @r TABLE (Id INT IDENTITY(1,1), Name NVARCHAR(240), Ok BIT, Detail NVARCHAR(300));
DECLARE @e INT, @n INT;
DECLARE @priya INT = (SELECT UserId FROM sec.Users WHERE EmailNormalized = N'PRIYA.MENON@TAMS.LOCAL'),
        @rahul INT = (SELECT UserId FROM sec.Users WHERE EmailNormalized = N'RAHUL.DESAI@TAMS.LOCAL'),
        @anita INT = (SELECT UserId FROM sec.Users WHERE EmailNormalized = N'ANITA.KAPOOR@TAMS.LOCAL'),
        @arjun INT = (SELECT UserId FROM sec.Users WHERE EmailNormalized = N'ARJUN.SHAH@APEXLOGISTICS.EXAMPLE'),
        @meera INT = (SELECT UserId FROM sec.Users WHERE EmailNormalized = N'MEERA.IYER@BRIGHTWAVE.EXAMPLE'),
        @ravi  INT = (SELECT UserId FROM sec.Users WHERE EmailNormalized = N'RAVI.KUMAR@CONTRACTOR.EXAMPLE'),
        @sneha INT = (SELECT UserId FROM sec.Users WHERE EmailNormalized = N'SNEHA.PILLAI@CONTRACTOR.EXAMPLE'),
        @rohan INT = (SELECT UserId FROM sec.Users WHERE EmailNormalized = N'ROHAN.GUPTA@CANDIDATE.EXAMPLE'),
        @divya INT = (SELECT UserId FROM sec.Users WHERE EmailNormalized = N'DIVYA.REDDY@CANDIDATE.EXAMPLE'),
        @ananya INT = (SELECT UserId FROM sec.Users WHERE EmailNormalized = N'ANANYA.SHARMA@CANDIDATE.EXAMPLE');
DECLARE @rohanCand INT = cand.fn_CandidateIdForUser(@rohan), @divyaCand INT = cand.fn_CandidateIdForUser(@divya),
        @poojaCand INT = (SELECT CandidateId FROM cand.Candidates WHERE EmailNormalized = N'POOJA.NAMBIAR@CANDIDATE.EXAMPLE'),
        @raviCtr INT = staff.fn_ContractorIdForUser(@ravi), @snehaCtr INT = staff.fn_ContractorIdForUser(@sneha),
        @emp INT = (SELECT EmployeeId FROM hr.Employees WHERE CandidateId = cand.fn_CandidateIdForUser(@ananya)),
        @apex INT = (SELECT CustomerId FROM org.Customers WHERE CustomerCode = N'APEX');
DECLARE @raviContract INT = (SELECT TOP (1) ct.ContractId FROM staff.Contracts ct JOIN staff.Placements p ON p.PlacementId = ct.PlacementId WHERE p.ContractorId = @raviCtr);
DECLARE @raviComp INT = (SELECT TOP (1) ComplianceId FROM staff.ComplianceRecords WHERE ContractorId = @raviCtr ORDER BY ComplianceId);
DECLARE @snehaComp INT = (SELECT TOP (1) ComplianceId FROM staff.ComplianceRecords WHERE ContractorId = @snehaCtr AND DocumentId IS NULL ORDER BY ComplianceId);
DECLARE @sha BINARY(32) = HASHBYTES('SHA2_256', 'tams-test');
DECLARE @nm NVARCHAR(100);

CREATE TABLE #add (DocumentId INT, OwnerType VARCHAR(12), OwnerId INT, DocType VARCHAR(20), IsPrimaryResume BIT);
CREATE TABLE #lst (DocumentId INT, OwnerType VARCHAR(12), OwnerId INT, DocType VARCHAR(20), IsPrimaryResume BIT, ComplianceId INT, ComplianceType VARCHAR(20),
                   OriginalFileName NVARCHAR(260), ContentType NVARCHAR(100), SizeBytes BIGINT, UploadedAt DATETIME2(0), UploadedBy NVARCHAR(150), CanDelete BIT);
CREATE TABLE #dl (DocumentId INT, StoredFileName NVARCHAR(100), OriginalFileName NVARCHAR(260), ContentType NVARCHAR(100), SizeBytes BIGINT, Sha256 BINARY(32), UploadedAt DATETIME2(0));

BEGIN TRANSACTION;

-- ---------- candidate documents ----------
SET @nm = CONVERT(NVARCHAR(36), NEWID()) + N'.pdf';
INSERT #add EXEC doc.usp_AddDocument @rohan, 'Candidate', @rohanCand, 'Resume', @nm, N'Rohan_CV_2026.pdf', N'application/pdf', 52000, @sha;
DECLARE @cv1 INT = (SELECT MAX(DocumentId) FROM #add);
INSERT @r VALUES (N'D01 a candidate uploads his own resume; the first resume becomes the primary one', IIF(EXISTS (SELECT 1 FROM #add WHERE DocumentId = @cv1 AND IsPrimaryResume = 1), 1, 0), N'');
SET @nm = CONVERT(NVARCHAR(36), NEWID()) + N'.docx';
INSERT #add EXEC doc.usp_AddDocument @rohan, 'Candidate', @rohanCand, 'Resume', @nm, N'Rohan_CV_v2.docx', N'application/vnd.openxmlformats-officedocument.wordprocessingml.document', 61000, @sha, NULL, 1;
DECLARE @cv2 INT = (SELECT MAX(DocumentId) FROM #add);
INSERT @r VALUES (N'D02 uploading a new resume as primary moves the primary flag (only one primary)',
    IIF((SELECT COUNT(*) FROM cand.CandidateDocuments WHERE CandidateId = @rohanCand AND IsPrimaryResume = 1) = 1 AND EXISTS (SELECT 1 FROM cand.CandidateDocuments WHERE DocumentId = @cv2 AND IsPrimaryResume = 1), 1, 0), N'');
SET @nm = CONVERT(NVARCHAR(36), NEWID()) + N'.png';
INSERT #add EXEC doc.usp_AddDocument @priya, 'Candidate', @rohanCand, 'Identity', @nm, N'passport.png', N'image/png', 30000, @sha;
DECLARE @ident INT = (SELECT MAX(DocumentId) FROM #add);
INSERT @r VALUES (N'D03 a recruiter can add a document to any candidate (identity proof, not primary)', IIF(EXISTS (SELECT 1 FROM #add WHERE DocumentId = @ident AND IsPrimaryResume = 0 AND DocType = 'Identity'), 1, 0), N'');

SET @e = 0; SET @nm = CONVERT(NVARCHAR(36), NEWID()) + N'.pdf';
BEGIN TRY EXEC doc.usp_AddDocument @rohan, 'Candidate', @divyaCand, 'Resume', @nm, N'x.pdf', N'application/pdf', 100, @sha; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'D04 a candidate cannot add a document to another candidate (50004 - looks missing)', IIF(@e = 50004, 1, 0), CONCAT(N'err=', @e));
SET @e = 0;
BEGIN TRY EXEC doc.usp_AddDocument @rohan, 'Candidate', @rohanCand, 'Resume', N'..\..\windows\system32\evil.pdf', N'x.pdf', N'application/pdf', 100, @sha; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'D05 a stored name containing a path is refused (50001)', IIF(@e = 50001, 1, 0), CONCAT(N'err=', @e));
SET @e = 0; SET @nm = CONVERT(NVARCHAR(36), NEWID()) + N'.pdf';
BEGIN TRY EXEC doc.usp_AddDocument @rohan, 'Candidate', @rohanCand, 'Resume', @nm, N'big.pdf', N'application/pdf', 10485761, @sha; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'D06 a document over 10 MB is refused (50001)', IIF(@e = 50001, 1, 0), CONCAT(N'err=', @e));
SET @e = 0; SET @nm = CONVERT(NVARCHAR(36), NEWID()) + N'.pdf';
BEGIN TRY EXEC doc.usp_AddDocument @rohan, 'Candidate', @rohanCand, 'Payslip', @nm, N'x.pdf', N'application/pdf', 100, @sha; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'D07 an unknown document type is refused (50001)', IIF(@e = 50001, 1, 0), CONCAT(N'err=', @e));

INSERT #lst EXEC doc.usp_ListDocuments @rohan, 'Candidate', @rohanCand;
INSERT @r VALUES (N'D08 the candidate lists all 3 of his documents and may delete them', IIF((SELECT COUNT(*) FROM #lst) = 3 AND NOT EXISTS (SELECT 1 FROM #lst WHERE CanDelete = 0), 1, 0), CONCAT(N'n=', (SELECT COUNT(*) FROM #lst)));
DELETE #lst; INSERT #lst EXEC doc.usp_ListDocuments @divya, 'Candidate', @rohanCand;
SET @e = 0; BEGIN TRY INSERT #dl EXEC doc.usp_GetDocumentForDownload @divya, @cv1; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'D09 another candidate sees none of them and cannot download (50004)', IIF(NOT EXISTS (SELECT 1 FROM #lst) AND @e = 50004, 1, 0), CONCAT(N'err=', @e));
DELETE #dl; INSERT #dl EXEC doc.usp_GetDocumentForDownload @priya, @cv1;
INSERT @r VALUES (N'D10 a recruiter can download; the stored GUID name and SHA-256 are returned for the API only', IIF(EXISTS (SELECT 1 FROM #dl WHERE DocumentId = @cv1 AND Sha256 = @sha AND StoredFileName LIKE N'%.pdf'), 1, 0), N'');

-- customer access: Rohan is at Interview stage for Apex (seed), Pooja only Submitted for Apex
DELETE #lst; INSERT #lst EXEC doc.usp_ListDocuments @arjun, 'Candidate', @rohanCand;
INSERT @r VALUES (N'D11 Apex (which shortlisted Rohan) sees his RESUMES only - not his identity document', IIF((SELECT COUNT(*) FROM #lst) = 2 AND NOT EXISTS (SELECT 1 FROM #lst WHERE DocType <> 'Resume') AND NOT EXISTS (SELECT 1 FROM #lst WHERE CanDelete = 1), 1, 0), CONCAT(N'n=', (SELECT COUNT(*) FROM #lst)));
SET @e = 0; BEGIN TRY INSERT #dl EXEC doc.usp_GetDocumentForDownload @arjun, @ident; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'D12 Apex cannot download Rohan''s identity document (50004)', IIF(@e = 50004, 1, 0), CONCAT(N'err=', @e));
SET @e = 0; BEGIN TRY INSERT #dl EXEC doc.usp_GetDocumentForDownload @meera, @cv1; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'D13 ISOLATION: Brightwave cannot download Rohan''s resume (never submitted to it) (50004)', IIF(@e = 50004, 1, 0), CONCAT(N'err=', @e));
SET @nm = CONVERT(NVARCHAR(36), NEWID()) + N'.pdf';
INSERT #add EXEC doc.usp_AddDocument @priya, 'Candidate', @poojaCand, 'Resume', @nm, N'Pooja.pdf', N'application/pdf', 4000, @sha;
DECLARE @poojaCv INT = (SELECT MAX(DocumentId) FROM #add);
SET @e = 0; BEGIN TRY INSERT #dl EXEC doc.usp_GetDocumentForDownload @arjun, @poojaCv; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'D14 a customer cannot read the resume of a candidate it has NOT shortlisted yet (Pooja: Submitted) (50004)', IIF(@e = 50004, 1, 0), CONCAT(N'err=', @e));

-- ---------- contractor compliance ----------
SET @nm = CONVERT(NVARCHAR(36), NEWID()) + N'.pdf';
INSERT #add EXEC doc.usp_AddDocument @ravi, 'Contractor', @raviCtr, NULL, @nm, N'bgcheck.pdf', N'application/pdf', 9000, @sha, @raviComp;
DECLARE @comp INT = (SELECT MAX(DocumentId) FROM #add);
INSERT @r VALUES (N'D15 a contractor attaches proof to his own compliance record: linked and set back to Pending for re-verification',
    IIF(EXISTS (SELECT 1 FROM staff.ComplianceRecords WHERE ComplianceId = @raviComp AND DocumentId = @comp AND Status = 'Pending' AND VerifiedByUserId IS NULL), 1, 0), N'');
SET @e = 0; SET @nm = CONVERT(NVARCHAR(36), NEWID()) + N'.pdf';
BEGIN TRY EXEC doc.usp_AddDocument @ravi, 'Contractor', @raviCtr, NULL, @nm, N'x.pdf', N'application/pdf', 100, @sha, @snehaComp; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'D16 he cannot attach a file to another contractor''s compliance record (50004)', IIF(@e = 50004, 1, 0), CONCAT(N'err=', @e));
SET @e = 0; BEGIN TRY INSERT #dl EXEC doc.usp_GetDocumentForDownload @sneha, @comp; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
DECLARE @e2 INT = 0; BEGIN TRY INSERT #dl EXEC doc.usp_GetDocumentForDownload @anita, @comp; END TRY BEGIN CATCH SET @e2 = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'D17 another contractor and an HR manager cannot read contractor compliance files (50004)', IIF(@e = 50004 AND @e2 = 50004, 1, 0), CONCAT(N'err=', @e, N'/', @e2));
SET @e = 0; BEGIN TRY EXEC staff.usp_DecideCompliance @ravi, @raviComp, 'Verified'; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'D18 a contractor cannot verify his own compliance record (50005)', IIF(@e = 50005, 1, 0), CONCAT(N'err=', @e));
EXEC staff.usp_DecideCompliance @rahul, @raviComp, 'Verified', N'Checked original';
INSERT @r VALUES (N'D19 a recruiter verifies it (who and when recorded) and the contractor is notified',
    IIF(EXISTS (SELECT 1 FROM staff.ComplianceRecords WHERE ComplianceId = @raviComp AND Status = 'Verified' AND VerifiedByUserId = @rahul AND VerifiedAt IS NOT NULL)
        AND EXISTS (SELECT 1 FROM notify.NotificationQueue WHERE TemplateCode = 'COMPLIANCE_DECISION' AND RecipientUserId = @ravi AND RelatedEntityId = @raviComp), 1, 0), N'');
INSERT @r VALUES (N'D19a the decision is in the audit log with the recruiter as the actor',
    IIF(EXISTS (SELECT 1 FROM audit.AuditLogs WHERE TableName = N'staff.ComplianceRecords' AND RecordId = CAST(@raviComp AS NVARCHAR(50)) AND Action = 'U'
                AND ChangedByUserId = @rahul AND NewValues LIKE N'%<Status>Verified</Status>%' AND OldValues NOT LIKE N'%<Status>Verified</Status>%'), 1, 0), N'');
SET @e = 0; BEGIN TRY EXEC staff.usp_DecideCompliance @rahul, @snehaComp, 'Verified'; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
SET @e2 = 0; BEGIN TRY EXEC staff.usp_DecideCompliance @rahul, @snehaComp, 'Rejected'; END TRY BEGIN CATCH SET @e2 = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'D20 verifying without an attached document is refused (50002); rejecting needs a reason (50001)', IIF(@e = 50002 AND @e2 = 50001, 1, 0), CONCAT(N'err=', @e, N'/', @e2, N' comp=', @snehaComp));

-- ---------- employee and contract documents ----------
SET @nm = CONVERT(NVARCHAR(36), NEWID()) + N'.pdf';
INSERT #add EXEC doc.usp_AddDocument @anita, 'Employee', @emp, 'Contract', @nm, N'employment_agreement.pdf', N'application/pdf', 20000, @sha;
DECLARE @empDoc INT = (SELECT MAX(DocumentId) FROM #add);
SET @e = 0; BEGIN TRY INSERT #dl EXEC doc.usp_GetDocumentForDownload @priya, @empDoc; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
DELETE #dl; INSERT #dl EXEC doc.usp_GetDocumentForDownload @ananya, @empDoc;
INSERT @r VALUES (N'D21 HR files an employee document: a recruiter cannot read it (50004), the employee herself can', IIF(@e = 50004 AND EXISTS (SELECT 1 FROM #dl WHERE DocumentId = @empDoc), 1, 0), CONCAT(N'err=', @e));
SET @e = 0; SET @nm = CONVERT(NVARCHAR(36), NEWID()) + N'.pdf';
BEGIN TRY EXEC doc.usp_AddDocument @priya, 'Employee', @emp, 'Other', @nm, N'x.pdf', N'application/pdf', 100, @sha; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'D22 a recruiter cannot add employee documents (50004)', IIF(@e = 50004, 1, 0), CONCAT(N'err=', @e));
SET @nm = CONVERT(NVARCHAR(36), NEWID()) + N'.pdf';
INSERT #add EXEC doc.usp_AddDocument @rahul, 'Contract', @raviContract, NULL, @nm, N'signed_contract.pdf', N'application/pdf', 40000, @sha;
DECLARE @ctDoc INT = (SELECT MAX(DocumentId) FROM #add);
DELETE #dl; INSERT #dl EXEC doc.usp_GetDocumentForDownload @arjun, @ctDoc;
SET @n = (SELECT COUNT(*) FROM #dl WHERE DocumentId = @ctDoc);
DELETE #dl; INSERT #dl EXEC doc.usp_GetDocumentForDownload @ravi, @ctDoc;
SET @e = 0; BEGIN TRY INSERT #dl EXEC doc.usp_GetDocumentForDownload @meera, @ctDoc; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'D23 a signed contract is customer-scoped: Apex and the contractor can read it, Brightwave cannot (50004); the contract points to it',
    IIF(@n = 1 AND EXISTS (SELECT 1 FROM #dl WHERE DocumentId = @ctDoc) AND @e = 50004 AND (SELECT CustomerId FROM doc.Documents WHERE DocumentId = @ctDoc) = @apex
        AND (SELECT DocumentId FROM staff.Contracts WHERE ContractId = @raviContract) = @ctDoc, 1, 0), CONCAT(N'err=', @e));

-- ---------- delete ----------
SET @e = 0; BEGIN TRY EXEC doc.usp_DeleteDocument @divya, @cv1; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
SET @e2 = 0; BEGIN TRY EXEC doc.usp_DeleteDocument @arjun, @cv1; END TRY BEGIN CATCH SET @e2 = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'D24 another candidate cannot delete the resume (50004); a customer cannot delete (50005: role)', IIF(@e = 50004 AND @e2 = 50005, 1, 0), CONCAT(N'err=', @e, N'/', @e2));
EXEC doc.usp_DeleteDocument @rohan, @cv2;
DELETE #lst; INSERT #lst EXEC doc.usp_ListDocuments @rohan, 'Candidate', @rohanCand;
SET @e = 0; BEGIN TRY INSERT #dl EXEC doc.usp_GetDocumentForDownload @priya, @cv2; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'D25 soft delete: the row is kept (IsDeleted = 1) but no longer listed or downloadable, even for staff (50004)',
    IIF((SELECT IsDeleted FROM doc.Documents WHERE DocumentId = @cv2) = 1 AND NOT EXISTS (SELECT 1 FROM #lst WHERE DocumentId = @cv2) AND @e = 50004, 1, 0), CONCAT(N'err=', @e));
EXEC doc.usp_DeleteDocument @rahul, @comp;
INSERT @r VALUES (N'D26 deleting a compliance proof clears the link on the compliance record', IIF((SELECT DocumentId FROM staff.ComplianceRecords WHERE ComplianceId = @raviComp) IS NULL, 1, 0), N'');
INSERT @r VALUES (N'D27 uploads and deletions are audited with the acting user',
    IIF(EXISTS (SELECT 1 FROM audit.AuditLogs WHERE TableName = N'doc.Documents' AND RecordId = CAST(@cv1 AS NVARCHAR(50)) AND Action = 'I' AND ChangedByUserId = @rohan)
        AND EXISTS (SELECT 1 FROM audit.AuditLogs WHERE TableName = N'doc.Documents' AND RecordId = CAST(@cv2 AS NVARCHAR(50)) AND Action = 'U' AND ChangedByUserId = @rohan), 1, 0), N'');

-- ---------- least privilege ----------
EXECUTE AS USER = 'tams_app_demo';
SET @e = 0; BEGIN TRY DELETE #lst; INSERT #lst EXEC doc.usp_ListDocuments @priya, 'Candidate', @rohanCand; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
SET @e2 = 0; BEGIN TRY SELECT @n = COUNT(*) FROM doc.Documents; END TRY BEGIN CATCH SET @e2 = ERROR_NUMBER(); END CATCH
REVERT;
INSERT @r VALUES (N'D28 the application role can EXECUTE the document procedures but cannot SELECT doc.Documents directly (229)', IIF(@e = 0 AND @e2 = 229, 1, 0), CONCAT(N'exec=', @e, N' select=', @e2));

IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
INSERT @r VALUES (N'Z01 the suite left no trace', IIF(NOT EXISTS (SELECT 1 FROM doc.Documents WHERE Sha256 = HASHBYTES('SHA2_256', 'tams-test')) AND @@TRANCOUNT = 0, 1, 0), N'');

DECLARE @line NVARCHAR(600);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT CASE WHEN Ok = 1 THEN N'PASS  ' ELSE N'FAIL  ' END + Name + CASE WHEN Ok = 0 THEN N'  -> ' + Detail ELSE N'' END FROM @r ORDER BY Id;
OPEN c; FETCH NEXT FROM c INTO @line; WHILE @@FETCH_STATUS = 0 BEGIN PRINT @line; FETCH NEXT FROM c INTO @line; END CLOSE c; DEALLOCATE c;
DECLARE @total INT = (SELECT COUNT(*) FROM @r), @passed INT = (SELECT COUNT(*) FROM @r WHERE Ok = 1);
PRINT CONCAT(N'--- Document tests: ', @passed, N' passed, ', @total - @passed, N' failed, ', @total, N' total ---');
IF @passed <> @total RAISERROR(N'Document tests FAILED', 16, 1);
GO
