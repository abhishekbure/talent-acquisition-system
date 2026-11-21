/* ============================================================================
   TAMS - 12_Tests / 06_Notification_Tests.sql        (Phase 9)
   Delivery queue (claim/lease, sent, failure back-off, give-up, lost leases, de-duplication, deactivated recipients,
   erasing one-time links), administration (list, history, retry, cancel), in-app filtering, e-mail verification
   (KI-014), business time zone (KI-028) and least privilege.
   Runs inside a transaction that is rolled back. Messages already queued are parked (not due) while it runs, and
   timestamps are moved directly where a test needs time to pass.
   ========================================================================== */
USE TalentAcquisitionDB;
GO
SET NOCOUNT ON;
DECLARE @r TABLE (Id INT IDENTITY(1,1), Name NVARCHAR(240), Ok BIT, Detail NVARCHAR(400));
DECLARE @e INT, @e2 INT, @n INT, @id BIGINT, @id2 BIGINT, @id3 BIGINT, @at DATETIME2(0), @m NVARCHAR(400);
DECLARE @admin INT = (SELECT UserId FROM sec.Users WHERE EmailNormalized = N'ADMIN@TAMS.LOCAL'),
        @priya INT = (SELECT UserId FROM sec.Users WHERE EmailNormalized = N'PRIYA.MENON@TAMS.LOCAL'),
        @divya INT = (SELECT UserId FROM sec.Users WHERE EmailNormalized = N'DIVYA.REDDY@CANDIDATE.EXAMPLE'),
        @rohan INT = (SELECT UserId FROM sec.Users WHERE EmailNormalized = N'ROHAN.GUPTA@CANDIDATE.EXAMPLE');
DECLARE @h32 VARBINARY(32) = HASHBYTES('SHA2_256', N'pw-hash'), @s32 VARBINARY(32) = HASHBYTES('SHA2_256', N'pw-salt');
DECLARE @tag NVARCHAR(20) = LEFT(REPLACE(CONVERT(NVARCHAR(36), NEWID()), N'-', N''), 12);

CREATE TABLE #c (NotificationId BIGINT, AttemptNo INT, MaxAttempts INT, TemplateCode VARCHAR(40), ToEmail NVARCHAR(256), RecipientName NVARCHAR(150),
                 Subject NVARCHAR(300), Body NVARCHAR(MAX), RelatedEntityType VARCHAR(30), RelatedEntityId INT, CreatedAt DATETIME2(0));
CREATE TABLE #s (Updated INT);
CREATE TABLE #f (Updated INT, Status VARCHAR(12), NextAttemptAt DATETIME2(0));
CREATE TABLE #q (NotificationId BIGINT, TemplateCode VARCHAR(40), ToEmail NVARCHAR(256), RecipientName NVARCHAR(150), Subject NVARCHAR(300), Status VARCHAR(12),
                 Attempts INT, MaxAttempts INT, NextAttemptAt DATETIME2(0), CreatedAt DATETIME2(0), ProcessedAt DATETIME2(0), RelatedEntityType VARCHAR(30),
                 RelatedEntityId INT, IsSecurity BIT, LastError NVARCHAR(1000), LastAttemptAt DATETIME2(0), TotalCount INT);
CREATE TABLE #h (HistoryId BIGINT, AttemptNo INT, Outcome VARCHAR(10), ErrorMessage NVARCHAR(1000), AttemptedAt DATETIME2(0));
CREATE TABLE #my (NotificationId BIGINT, TemplateCode VARCHAR(40), Subject NVARCHAR(300), Body NVARCHAR(MAX), IsRead BIT, CreatedAt DATETIME2(0),
                  RelatedEntityType VARCHAR(30), RelatedEntityId INT, EmailStatus VARCHAR(12), EmailedAt DATETIME2(0), UnreadCount INT);
CREATE TABLE #rt (NotificationId BIGINT, Status VARCHAR(12), Attempts INT, NextAttemptAt DATETIME2(0));
CREATE TABLE #cn (NotificationId BIGINT, Status VARCHAR(12));
CREATE TABLE #reg (UserId INT, CandidateId INT);
CREATE TABLE #ver (UserId INT, Email NVARCHAR(256));
CREATE TABLE #cev (UserId INT);
CREATE TABLE #rst (UserId INT);
CREATE TABLE #login (UserId INT, Email NVARCHAR(256), DisplayName NVARCHAR(150), PasswordHash VARBINARY(64), PasswordSalt VARBINARY(32), HashIterations INT,
                     IsActive BIT, LockoutUntil DATETIME2(0), EmailVerifiedAt DATETIME2(0), Roles NVARCHAR(400), CustomerId INT, CandidateId INT, ContractorId INT);
CREATE TABLE #la (LockoutUntil DATETIME2(0), FailedLoginCount INT);

BEGIN TRANSACTION;
-- park everything already queued so only this suite's messages are due
UPDATE notify.NotificationQueue SET NextAttemptAt = '9999-12-31' WHERE Status IN ('Pending', 'Processing');

/* ============================== QUEUE ============================== */
EXEC notify.usp_Enqueue 'TEST_NOTE', @divya, N'N-test one', N'Body one', N'NT1', 'Test', 1;
EXEC notify.usp_Enqueue 'TEST_NOTE', @divya, N'N-test one again', N'Body', N'NT1', 'Test', 1;
EXEC notify.usp_Enqueue 'TEST_NOTE', @rohan, N'N-test one', N'Body one', N'NT1', 'Test', 1;
INSERT @r VALUES (N'N01 the same event is queued once per recipient (de-duplication), each recipient gets one',
    IIF((SELECT COUNT(*) FROM notify.NotificationQueue WHERE TemplateCode = 'TEST_NOTE' AND RelatedEntityId = 1 AND RecipientUserId = @divya) = 1
        AND (SELECT COUNT(*) FROM notify.NotificationQueue WHERE TemplateCode = 'TEST_NOTE' AND RelatedEntityId = 1 AND RecipientUserId = @rohan) = 1, 1, 0), N'');
SET @id  = (SELECT NotificationId FROM notify.NotificationQueue WHERE TemplateCode = 'TEST_NOTE' AND RecipientUserId = @divya AND RelatedEntityId = 1);
SET @id2 = (SELECT NotificationId FROM notify.NotificationQueue WHERE TemplateCode = 'TEST_NOTE' AND RecipientUserId = @rohan AND RelatedEntityId = 1);

-- a message that is not due yet stays queued
EXEC notify.usp_Enqueue 'TEST_NOTE', @divya, N'N-test later', N'Later', N'NT2', 'Test', 2;
SET @id3 = (SELECT NotificationId FROM notify.NotificationQueue WHERE TemplateCode = 'TEST_NOTE' AND RelatedEntityId = 2);
UPDATE notify.NotificationQueue SET NextAttemptAt = DATEADD(HOUR, 1, SYSUTCDATETIME()) WHERE NotificationId = @id3;

INSERT #c EXEC notify.usp_ClaimBatch 10, 300;
INSERT @r VALUES (N'N02 a claim takes only due messages, oldest first, marks them Processing (attempt 1) under a lease',
    IIF((SELECT COUNT(*) FROM #c) = 2 AND (SELECT MIN(NotificationId) FROM #c) = @id AND NOT EXISTS (SELECT 1 FROM #c WHERE NotificationId = @id3)
        AND NOT EXISTS (SELECT 1 FROM notify.NotificationQueue WHERE NotificationId IN (@id, @id2) AND (Status <> 'Processing' OR Attempts <> 1
                         OR NextAttemptAt NOT BETWEEN DATEADD(SECOND, 290, SYSUTCDATETIME()) AND DATEADD(SECOND, 310, SYSUTCDATETIME()))), 1, 0),
    CONCAT(N'claimed=', (SELECT COUNT(*) FROM #c)));
INSERT @r VALUES (N'N03 the claim returns what the sender needs (address, recipient name, subject, body, attempt number)',
    IIF(EXISTS (SELECT 1 FROM #c WHERE NotificationId = @id AND ToEmail = N'divya.reddy@candidate.example' AND RecipientName IS NOT NULL
                AND Subject = N'N-test one' AND Body = N'Body one' AND AttemptNo = 1 AND MaxAttempts = 5), 1, 0), N'');
DELETE #c; INSERT #c EXEC notify.usp_ClaimBatch 10, 300;
INSERT @r VALUES (N'N04 a leased message is not handed to a second worker', IIF(NOT EXISTS (SELECT 1 FROM #c), 1, 0), CONCAT(N'claimed=', (SELECT COUNT(*) FROM #c)));

INSERT #s EXEC notify.usp_MarkSent @id, 1;
INSERT @r VALUES (N'N05 mark-sent records Sent with a history row',
    IIF((SELECT Updated FROM #s) = 1 AND EXISTS (SELECT 1 FROM notify.NotificationQueue WHERE NotificationId = @id AND Status = 'Sent' AND ProcessedAt IS NOT NULL AND Body = N'Body one')
        AND (SELECT COUNT(*) FROM notify.NotificationHistory WHERE NotificationId = @id AND Outcome = 'Sent' AND AttemptNo = 1) = 1, 1, 0), N'');
DELETE #s; INSERT #s EXEC notify.usp_MarkSent @id, 1;
INSERT @r VALUES (N'N06 a repeated or late outcome for the same attempt changes nothing',
    IIF((SELECT Updated FROM #s) = 0 AND (SELECT COUNT(*) FROM notify.NotificationHistory WHERE NotificationId = @id) = 1, 1, 0), N'');

INSERT #f EXEC notify.usp_MarkFailed @id2, 1, N'SMTP pickup folder not writable';
INSERT @r VALUES (N'N07 a failed attempt goes back to Pending with a 1-minute back-off and the error in the history',
    IIF((SELECT Updated FROM #f) = 1 AND (SELECT Status FROM #f) = 'Pending'
        AND (SELECT NextAttemptAt FROM notify.NotificationQueue WHERE NotificationId = @id2) BETWEEN DATEADD(SECOND, 50, SYSUTCDATETIME()) AND DATEADD(SECOND, 70, SYSUTCDATETIME())
        AND EXISTS (SELECT 1 FROM notify.NotificationHistory WHERE NotificationId = @id2 AND Outcome = 'Failed' AND AttemptNo = 1 AND ErrorMessage = N'SMTP pickup folder not writable'), 1, 0), N'');
DELETE #c; INSERT #c EXEC notify.usp_ClaimBatch 10, 300;
INSERT @r VALUES (N'N08 it is not retried before the back-off has passed', IIF(NOT EXISTS (SELECT 1 FROM #c), 1, 0), N'');
-- attempts 2..5 fail; after each, move the clock past the back-off
DECLARE @k INT = 2, @gaps NVARCHAR(200) = N'';
DECLARE @g TABLE (AttemptNo INT, ClaimedAttempt INT, Status VARCHAR(12), GapSeconds INT);
WHILE @k <= 5
BEGIN
    UPDATE notify.NotificationQueue SET NextAttemptAt = DATEADD(SECOND, -1, SYSUTCDATETIME()) WHERE NotificationId = @id2;
    DELETE #c; INSERT #c EXEC notify.usp_ClaimBatch 10, 300;
    DELETE #f; INSERT #f EXEC notify.usp_MarkFailed @id2, @k, N'still failing';
    INSERT @g SELECT @k, (SELECT AttemptNo FROM #c WHERE NotificationId = @id2), Status, DATEDIFF(SECOND, SYSUTCDATETIME(), NextAttemptAt) FROM #f;
    SET @k += 1;
END
SELECT @gaps = STRING_AGG(CONCAT(AttemptNo, N':', ClaimedAttempt, N':', Status, N':', GapSeconds), N' ') FROM @g;
INSERT @r VALUES (N'N09 back-off doubles (2, 4, 8 minutes after attempts 2-4) and the 5th failure gives up (Failed)',
    IIF(NOT EXISTS (SELECT 1 FROM @g WHERE ClaimedAttempt IS NULL OR ClaimedAttempt <> AttemptNo)
        AND EXISTS (SELECT 1 FROM @g WHERE AttemptNo = 2 AND Status = 'Pending' AND GapSeconds BETWEEN 110 AND 121)
        AND EXISTS (SELECT 1 FROM @g WHERE AttemptNo = 3 AND Status = 'Pending' AND GapSeconds BETWEEN 230 AND 241)
        AND EXISTS (SELECT 1 FROM @g WHERE AttemptNo = 4 AND Status = 'Pending' AND GapSeconds BETWEEN 470 AND 481)
        AND EXISTS (SELECT 1 FROM @g WHERE AttemptNo = 5 AND Status = 'Failed')
        AND EXISTS (SELECT 1 FROM notify.NotificationQueue WHERE NotificationId = @id2 AND Status = 'Failed' AND Attempts = 5 AND ProcessedAt IS NOT NULL)
        AND (SELECT COUNT(*) FROM notify.NotificationHistory WHERE NotificationId = @id2 AND Outcome = 'Failed') = 5, 1, 0), @gaps);
UPDATE notify.NotificationQueue SET NextAttemptAt = DATEADD(MINUTE, -5, SYSUTCDATETIME()) WHERE NotificationId = @id2;
DELETE #c; INSERT #c EXEC notify.usp_ClaimBatch 10, 300;
INSERT @r VALUES (N'N10 a Failed message is never claimed again, even when its next-attempt time has passed', IIF(NOT EXISTS (SELECT 1 FROM #c WHERE NotificationId = @id2), 1, 0), N'');

-- lost lease: a worker claimed and vanished
UPDATE notify.NotificationQueue SET NextAttemptAt = DATEADD(SECOND, -1, SYSUTCDATETIME()) WHERE NotificationId = @id3;
DELETE #c; INSERT #c EXEC notify.usp_ClaimBatch 10, 300;              -- attempt 1, then the worker "dies"
UPDATE notify.NotificationQueue SET NextAttemptAt = DATEADD(SECOND, -1, SYSUTCDATETIME()) WHERE NotificationId = @id3;   -- lease runs out
DELETE #c; INSERT #c EXEC notify.usp_ClaimBatch 10, 300;
INSERT @r VALUES (N'N11 an expired lease is recorded as a failed attempt and the message is claimed again (attempt 2)',
    IIF(EXISTS (SELECT 1 FROM #c WHERE NotificationId = @id3 AND AttemptNo = 2)
        AND EXISTS (SELECT 1 FROM notify.NotificationHistory WHERE NotificationId = @id3 AND AttemptNo = 1 AND Outcome = 'Failed' AND ErrorMessage LIKE N'%lease expired%'), 1, 0), N'');
DELETE #s; INSERT #s EXEC notify.usp_MarkSent @id3, 1;
INSERT @r VALUES (N'N12 the vanished worker cannot record an outcome for its old attempt', IIF((SELECT Updated FROM #s) = 0
    AND (SELECT Status FROM notify.NotificationQueue WHERE NotificationId = @id3) = 'Processing', 1, 0), N'');
UPDATE notify.NotificationQueue SET Attempts = MaxAttempts, NextAttemptAt = DATEADD(SECOND, -1, SYSUTCDATETIME()) WHERE NotificationId = @id3;
DELETE #c; INSERT #c EXEC notify.usp_ClaimBatch 10, 300;
INSERT @r VALUES (N'N13 an expired lease on the last allowed attempt gives up (Failed)',
    IIF((SELECT Status FROM notify.NotificationQueue WHERE NotificationId = @id3) = 'Failed' AND NOT EXISTS (SELECT 1 FROM #c WHERE NotificationId = @id3), 1, 0), N'');

-- recipient deactivated after queuing
DECLARE @tmpUser INT;
DECLARE @tmpMail NVARCHAR(256) = N'n.' + @tag + N'@candidate.example';
INSERT #reg EXEC sec.usp_RegisterCandidate @tmpMail, N'Temp', N'Person', NULL, @h32, @s32;
SET @tmpUser = (SELECT UserId FROM #reg);
EXEC notify.usp_Enqueue 'TEST_NOTE', @tmpUser, N'N-to inactive', N'x', N'NT3', 'Test', 3;
SET @id = (SELECT NotificationId FROM notify.NotificationQueue WHERE TemplateCode = 'TEST_NOTE' AND RelatedEntityId = 3);
EXEC sec.usp_SetUserActive @admin, @tmpUser, 0;
DELETE #c; INSERT #c EXEC notify.usp_ClaimBatch 10, 300;
INSERT @r VALUES (N'N14 a recipient deactivated after the message was queued is not contacted (Cancelled)',
    IIF((SELECT Status FROM notify.NotificationQueue WHERE NotificationId = @id) = 'Cancelled' AND NOT EXISTS (SELECT 1 FROM #c WHERE NotificationId = @id), 1, 0), N'');

-- one-time links
EXEC notify.usp_Enqueue 'PASSWORD_RESET', @divya, N'Reset your TAMS password', N'secret link https://x/reset?token=abc', N'NT4', 'User', 4;
EXEC notify.usp_Enqueue 'EMAIL_VERIFY', @rohan, N'Confirm your e-mail', N'secret link https://x/verify?token=def', N'NT5', 'User', 5;
EXEC notify.usp_Enqueue 'PASSWORD_RESET', @rohan, N'Reset your TAMS password', N'secret link https://x/reset?token=ghi', N'NT6', 'User', 6;
DECLARE @sec1 BIGINT = (SELECT NotificationId FROM notify.NotificationQueue WHERE DedupeKey LIKE N'NT4|%'),
        @sec2 BIGINT = (SELECT NotificationId FROM notify.NotificationQueue WHERE DedupeKey LIKE N'NT5|%'),
        @sec3 BIGINT = (SELECT NotificationId FROM notify.NotificationQueue WHERE DedupeKey LIKE N'NT6|%');
DELETE #my; INSERT #my EXEC notify.usp_ListMyNotifications @divya, 0, 200;
INSERT @r VALUES (N'N15 sign-in links are e-mail only: not in the in-app list or the unread count',
    IIF(NOT EXISTS (SELECT 1 FROM #my WHERE TemplateCode IN ('PASSWORD_RESET', 'EMAIL_VERIFY')) AND EXISTS (SELECT 1 FROM #my WHERE TemplateCode = 'TEST_NOTE')
        AND (SELECT TOP (1) UnreadCount FROM #my) = (SELECT COUNT(*) FROM notify.NotificationQueue WHERE RecipientUserId = @divya AND IsRead = 0 AND TemplateCode NOT IN ('PASSWORD_RESET', 'EMAIL_VERIFY')), 1, 0), N'');
INSERT @r VALUES (N'N15b the in-app list shows the e-mail status', IIF(EXISTS (SELECT 1 FROM #my WHERE Subject = N'N-test one' AND EmailStatus = 'Sent' AND EmailedAt IS NOT NULL), 1, 0), N'');
DELETE #c; INSERT #c EXEC notify.usp_ClaimBatch 10, 300;
DELETE #s; INSERT #s EXEC notify.usp_MarkSent @sec1, 1;
UPDATE notify.NotificationQueue SET Attempts = MaxAttempts WHERE NotificationId = @sec2;      -- as if this were its last allowed attempt
DELETE #f; INSERT #f EXEC notify.usp_MarkFailed @sec2, 5, N'gave up';
INSERT @r VALUES (N'N16 the body of a sign-in link is erased once delivered or given up (KI-021); the subject stays',
    IIF(NOT EXISTS (SELECT 1 FROM notify.NotificationQueue WHERE NotificationId IN (@sec1, @sec2) AND Body LIKE N'%token=%')
        AND (SELECT Status FROM notify.NotificationQueue WHERE NotificationId = @sec1) = 'Sent'
        AND (SELECT Status FROM notify.NotificationQueue WHERE NotificationId = @sec2) = 'Failed'
        AND (SELECT Subject FROM notify.NotificationQueue WHERE NotificationId = @sec1) = N'Reset your TAMS password', 1, 0),
    CONCAT(N's1=', (SELECT Status FROM notify.NotificationQueue WHERE NotificationId = @sec1), N' s2=', (SELECT Status FROM notify.NotificationQueue WHERE NotificationId = @sec2)));
-- an ordinary message keeps its body after delivery (in-app history)
INSERT @r VALUES (N'N16b an ordinary message keeps its body after delivery', IIF((SELECT Body FROM notify.NotificationQueue WHERE DedupeKey LIKE N'NT1|%u' + CAST(@divya AS NVARCHAR(12))) = N'Body one', 1, 0), N'');

/* ============================== ADMINISTRATION ============================== */
SET @e = 0; BEGIN TRY EXEC notify.usp_ListQueue @priya; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
DELETE #q; INSERT #q EXEC notify.usp_ListQueue @admin, 'Failed', N'N-test', 1, 50;
INSERT @r VALUES (N'N17 only an administrator sees the queue; the list shows the last error and carries no message bodies',
    IIF(@e = 50005 AND EXISTS (SELECT 1 FROM #q WHERE NotificationId = @id2 AND LastError = N'still failing' AND Attempts = 5)
        AND NOT EXISTS (SELECT 1 FROM #q WHERE Status <> 'Failed'), 1, 0), CONCAT(N'err=', @e));   -- #q has no Body column: a body would break the INSERT
INSERT #h EXEC notify.usp_ListDeliveryHistory @admin, @id2;
SET @e = 0; BEGIN TRY EXEC notify.usp_ListDeliveryHistory @admin, -1; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'N18 the delivery history lists every attempt in order; unknown id is 404 (50004)',
    IIF((SELECT COUNT(*) FROM #h) = 5 AND (SELECT MIN(AttemptNo) FROM #h) = 1 AND (SELECT MAX(AttemptNo) FROM #h) = 5 AND @e = 50004, 1, 0), CONCAT(N'rows=', (SELECT COUNT(*) FROM #h), N' err=', @e));

SET @e = 0; BEGIN TRY EXEC notify.usp_RetryNotification @priya, @id2; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT #rt EXEC notify.usp_RetryNotification @admin, @id2;
INSERT @r VALUES (N'N19 an administrator re-queues a Failed message with fresh attempts (others: 50005), and it is audited',
    IIF(@e = 50005 AND EXISTS (SELECT 1 FROM notify.NotificationQueue WHERE NotificationId = @id2 AND Status = 'Pending' AND Attempts = 0 AND ProcessedAt IS NULL)
        AND EXISTS (SELECT 1 FROM audit.AuditLogs WHERE TableName = N'notify.NotificationQueue' AND RecordId = CAST(@id2 AS NVARCHAR(50)) AND ChangedByUserId = @admin), 1, 0), CONCAT(N'err=', @e));
SET @e = 0; BEGIN TRY EXEC notify.usp_RetryNotification @admin, @sec2; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
SET @e2 = 0; BEGIN TRY EXEC notify.usp_RetryNotification @admin, @sec1; END TRY BEGIN CATCH SET @e2 = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'N20 sign-in links are never re-sent, and a Sent message cannot be retried (50002)', IIF(@e = 50002 AND @e2 = 50002, 1, 0), CONCAT(N'err=', @e, N'/', @e2));
INSERT #cn EXEC notify.usp_CancelNotification @admin, @id2;
SET @e = 0; BEGIN TRY EXEC notify.usp_CancelNotification @admin, @id2; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'N21 an administrator cancels a Pending message; cancelling it again is refused (50002)',
    IIF((SELECT Status FROM notify.NotificationQueue WHERE NotificationId = @id2) = 'Cancelled' AND @e = 50002, 1, 0), CONCAT(N'err=', @e));
SET @n = (SELECT NotificationId FROM #c WHERE NotificationId = @sec3);
SET @e = 0; BEGIN TRY EXEC notify.usp_CancelNotification @admin, @sec3; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'N22 a message being sent right now (Processing) cannot be cancelled (50002)', IIF(@n IS NOT NULL AND @e = 50002, 1, 0), CONCAT(N'err=', @e, N' claimed=', @n));
SET @e = 0; BEGIN TRY DELETE #c; INSERT #c EXEC notify.usp_ClaimBatch 0, 300; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
SET @e2 = 0; BEGIN TRY DELETE #c; INSERT #c EXEC notify.usp_ClaimBatch 10, 5; END TRY BEGIN CATCH SET @e2 = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'N23 claim parameters are validated (50001)', IIF(@e = 50001 AND @e2 = 50001, 1, 0), CONCAT(N'err=', @e, N'/', @e2));

/* ============================== E-MAIL VERIFICATION (KI-014) ============================== */
DECLARE @t1 VARBINARY(32) = HASHBYTES('SHA2_256', N'v1-' + @tag), @t2 VARBINARY(32) = HASHBYTES('SHA2_256', N'v2-' + @tag),
        @t3 VARBINARY(32) = HASHBYTES('SHA2_256', N'v3-' + @tag), @t4 VARBINARY(32) = HASHBYTES('SHA2_256', N'v4-' + @tag);
DECLARE @newMail NVARCHAR(256) = N'v.new.' + @tag + N'@candidate.example', @masterMail NVARCHAR(256) = N'v.master.' + @tag + N'@candidate.example';
DECLARE @newUser INT, @masterUser INT, @masterCand INT;
DELETE #reg; INSERT #reg EXEC sec.usp_RegisterCandidate @newMail, N'Vera', N'New', NULL, @h32, @s32, 210000, @t1, '2099-01-01';
SET @newUser = (SELECT UserId FROM #reg);
INSERT @r VALUES (N'V01 a self-registered login starts unverified, with a hashed one-time link and its own candidate record',
    IIF(EXISTS (SELECT 1 FROM sec.Users WHERE UserId = @newUser AND EmailVerifiedAt IS NULL)
        AND EXISTS (SELECT 1 FROM sec.EmailVerificationTokens WHERE UserId = @newUser AND TokenHash = @t1 AND UsedAt IS NULL)
        AND EXISTS (SELECT 1 FROM cand.Candidates WHERE UserId = @newUser), 1, 0), N'');
DELETE #login; INSERT #login EXEC sec.usp_GetUserForLogin @newMail;
INSERT @r VALUES (N'V02 sign-in data tells the API the address is not verified', IIF(EXISTS (SELECT 1 FROM #login WHERE UserId = @newUser AND EmailVerifiedAt IS NULL), 1, 0), N'');

EXEC cand.usp_CreateCandidate @priya, N'Mara', N'Master', @masterMail, NULL, N'Analyst';
SET @masterCand = (SELECT CandidateId FROM cand.Candidates WHERE EmailNormalized = UPPER(@masterMail));
DELETE #reg; INSERT #reg EXEC sec.usp_RegisterCandidate @masterMail, N'Someone', N'Else', NULL, @h32, @s32, 210000, @t2, '2099-01-01';
SET @masterUser = (SELECT UserId FROM #reg);
INSERT @r VALUES (N'V03 registering the address of a recruiter-created candidate does NOT link it before verification, nor create a second record',
    IIF((SELECT UserId FROM cand.Candidates WHERE CandidateId = @masterCand) IS NULL AND (SELECT CandidateId FROM #reg) IS NULL
        AND (SELECT COUNT(*) FROM cand.Candidates WHERE EmailNormalized = UPPER(@masterMail)) = 1, 1, 0), N'');
DELETE #ver; INSERT #ver EXEC sec.usp_VerifyEmail @t2;
INSERT @r VALUES (N'V04 the e-mailed link verifies the address and then links the existing candidate record',
    IIF((SELECT UserId FROM #ver) = @masterUser AND EXISTS (SELECT 1 FROM sec.Users WHERE UserId = @masterUser AND EmailVerifiedAt IS NOT NULL)
        AND (SELECT UserId FROM cand.Candidates WHERE CandidateId = @masterCand) = @masterUser
        AND EXISTS (SELECT 1 FROM sec.EmailVerificationTokens WHERE TokenHash = @t2 AND UsedAt IS NOT NULL), 1, 0), N'');
SET @e = 0; BEGIN TRY EXEC sec.usp_VerifyEmail @t2; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
UPDATE sec.EmailVerificationTokens SET ExpiresAt = DATEADD(MINUTE, -1, SYSUTCDATETIME()) WHERE TokenHash = @t1;
SET @e2 = 0; BEGIN TRY EXEC sec.usp_VerifyEmail @t1; END TRY BEGIN CATCH SET @e2 = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'V05 a used or expired link is refused (50002) and changes nothing',
    IIF(@e = 50002 AND @e2 = 50002 AND EXISTS (SELECT 1 FROM sec.Users WHERE UserId = @newUser AND EmailVerifiedAt IS NULL), 1, 0), CONCAT(N'err=', @e, N'/', @e2));

-- resend
UPDATE sec.EmailVerificationTokens SET CreatedAt = DATEADD(MINUTE, -5, CreatedAt) WHERE UserId = @newUser;
DELETE #cev; INSERT #cev EXEC sec.usp_CreateEmailVerification @newMail, @t3, '2099-01-01';
SET @n = (SELECT UserId FROM #cev);
DELETE #cev; INSERT #cev EXEC sec.usp_CreateEmailVerification @newMail, @t4, '2099-01-01';
INSERT @r VALUES (N'V06 a new link replaces older ones; a second request within a minute creates nothing (no mailbox flooding)',
    IIF(@n = @newUser AND (SELECT UserId FROM #cev) IS NULL AND NOT EXISTS (SELECT 1 FROM sec.EmailVerificationTokens WHERE TokenHash = @t4)
        AND (SELECT COUNT(*) FROM sec.EmailVerificationTokens WHERE UserId = @newUser AND UsedAt IS NULL) = 1, 1, 0), N'');
DECLARE @nobody NVARCHAR(256) = N'nobody.' + @tag + N'@x.example';
DELETE #cev; INSERT #cev EXEC sec.usp_CreateEmailVerification @nobody, @t4, '2099-01-01';
SET @n = (SELECT UserId FROM #cev);
DELETE #cev; INSERT #cev EXEC sec.usp_CreateEmailVerification N'divya.reddy@candidate.example', @t4, '2099-01-01';
INSERT @r VALUES (N'V07 no link for unknown or already verified addresses (the API answers the same either way)',
    IIF(@n IS NULL AND (SELECT UserId FROM #cev) IS NULL AND NOT EXISTS (SELECT 1 FROM sec.EmailVerificationTokens WHERE TokenHash = @t4), 1, 0), N'');
DELETE #ver; INSERT #ver EXEC sec.usp_VerifyEmail @t3;
INSERT @r VALUES (N'V08 the replacement link verifies the account', IIF(EXISTS (SELECT 1 FROM sec.Users WHERE UserId = @newUser AND EmailVerifiedAt IS NOT NULL), 1, 0), N'');

-- password reset also proves the address
DECLARE @rsMail NVARCHAR(256) = N'v.reset.' + @tag + N'@candidate.example', @rsUser INT, @rsCand INT, @rt VARBINARY(32) = HASHBYTES('SHA2_256', N'r-' + @tag);
EXEC cand.usp_CreateCandidate @priya, N'Rita', N'Reset', @rsMail, NULL, NULL;
SET @rsCand = (SELECT CandidateId FROM cand.Candidates WHERE EmailNormalized = UPPER(@rsMail));
DELETE #reg; INSERT #reg EXEC sec.usp_RegisterCandidate @rsMail, N'Imposter', N'First', NULL, @h32, @s32;   -- no link e-mailed to them
SET @rsUser = (SELECT UserId FROM #reg);
DELETE #rst; INSERT #rst EXEC sec.usp_CreatePasswordReset @rsMail, @rt, '2099-01-01';
DELETE #rst; INSERT #rst EXEC sec.usp_ConsumePasswordReset @rt, @h32, @s32;
INSERT @r VALUES (N'V09 completing an e-mailed password reset verifies the account and links the candidate record (the real owner can take over an unverified registration)',
    IIF(EXISTS (SELECT 1 FROM sec.Users WHERE UserId = @rsUser AND EmailVerifiedAt IS NOT NULL) AND (SELECT UserId FROM cand.Candidates WHERE CandidateId = @rsCand) = @rsUser, 1, 0), N'');

-- refused sign-in because unverified does not count towards lockout
DECLARE @fc INT = (SELECT FailedLoginCount FROM sec.Users WHERE UserId = @tmpUser);
DELETE #la; INSERT #la EXEC sec.usp_RecordLoginAttempt @tmpMail, 0, N'email not verified', '127.0.0.1', NULL, 0;
INSERT @r VALUES (N'V10 a sign-in refused only because the address is unverified is logged but not counted towards lockout',
    IIF((SELECT FailedLoginCount FROM sec.Users WHERE UserId = @tmpUser) = @fc
        AND EXISTS (SELECT 1 FROM audit.LoginHistory WHERE UserId = @tmpUser AND FailureReason = N'email not verified'), 1, 0), N'');

DECLARE @staffMail NVARCHAR(256) = N'v.staff.' + @tag + N'@tams.local';
EXEC sec.usp_CreateUser @admin, @staffMail, N'Staff Person', @h32, @s32, 210000, N'Recruiter';
INSERT @r VALUES (N'V11 accounts created by an administrator are verified (vouched for by the administrator)',
    IIF(EXISTS (SELECT 1 FROM sec.Users WHERE EmailNormalized = UPPER(@staffMail) AND EmailVerifiedAt IS NOT NULL), 1, 0), N'');

/* ============================== TIME ZONE (KI-028) ============================== */
INSERT @r VALUES (N'T01 notification times are written in IST (business time zone); data stays UTC',
    IIF(dbo.fn_BusinessTime('2026-11-20 04:30') = N'20 Nov 2026, 10:00 IST' AND dbo.fn_BusinessTime('2026-12-31 20:00') = N'01 Jan 2027, 01:30 IST'
        AND dbo.fn_BusinessTime(NULL) IS NULL, 1, 0), dbo.fn_BusinessTime('2026-11-20 04:30'));
INSERT @r VALUES (N'T02 interview invitations and reschedules use it (no "UTC" text left in the procedures)',
    IIF(OBJECT_DEFINITION(OBJECT_ID(N'cand.usp_ScheduleInterview')) LIKE N'%dbo.fn_BusinessTime(@StartsAt)%'
        AND OBJECT_DEFINITION(OBJECT_ID(N'cand.usp_RescheduleInterview')) LIKE N'%dbo.fn_BusinessTime(@StartsAt)%'
        AND NOT EXISTS (SELECT 1 FROM sys.sql_modules WHERE definition LIKE N'%N'' UTC''%'), 1, 0), N'');

/* ============================== LEAST PRIVILEGE ============================== */
EXECUTE AS USER = 'tams_worker_demo';
SET @e = 0; BEGIN TRY DELETE #c; INSERT #c EXEC notify.usp_ClaimBatch 1, 300; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
SET @e2 = 0; BEGIN TRY SELECT @n = COUNT(*) FROM notify.NotificationQueue; END TRY BEGIN CATCH SET @e2 = ERROR_NUMBER(); END CATCH
DECLARE @e3 INT = 0; BEGIN TRY SELECT @n = COUNT(*) FROM sec.EmailVerificationTokens; END TRY BEGIN CATCH SET @e3 = ERROR_NUMBER(); END CATCH
REVERT;
EXECUTE AS USER = 'tams_app_demo';
DECLARE @e5 INT = 0; BEGIN TRY DELETE #c; INSERT #c EXEC notify.usp_ClaimBatch 1, 300; END TRY BEGIN CATCH SET @e5 = ERROR_NUMBER(); END CATCH
DECLARE @e6 INT = 0; BEGIN TRY EXEC notify.usp_MarkSent 1, 1; END TRY BEGIN CATCH SET @e6 = ERROR_NUMBER(); END CATCH
REVERT;
INSERT @r VALUES (N'P01 the worker identity runs the queue procedures but cannot read the queue or the verification tokens directly (229); the API identity cannot claim or mark messages (229, Phase 13)',
    IIF(@e = 0 AND @e2 = 229 AND @e3 = 229 AND @e5 = 229 AND @e6 = 229, 1, 0), CONCAT(N'worker exec=', @e, N' queue=', @e2, N' tokens=', @e3, N'; api claim=', @e5, N' mark=', @e6));

IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
INSERT @r VALUES (N'Z01 the suite left no trace',
    IIF(NOT EXISTS (SELECT 1 FROM notify.NotificationQueue WHERE TemplateCode = 'TEST_NOTE' OR NextAttemptAt = '9999-12-31')
        AND NOT EXISTS (SELECT 1 FROM sec.Users WHERE Email LIKE N'%' + @tag + N'%') AND @@TRANCOUNT = 0, 1, 0), N'');

DECLARE @line NVARCHAR(700);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT CASE WHEN Ok = 1 THEN N'PASS  ' ELSE N'FAIL  ' END + Name + CASE WHEN Ok = 0 THEN N'  -> ' + ISNULL(Detail, N'') ELSE N'' END FROM @r ORDER BY Id;
OPEN c; FETCH NEXT FROM c INTO @line; WHILE @@FETCH_STATUS = 0 BEGIN PRINT @line; FETCH NEXT FROM c INTO @line; END CLOSE c; DEALLOCATE c;
DECLARE @total INT = (SELECT COUNT(*) FROM @r), @passed INT = (SELECT COUNT(*) FROM @r WHERE Ok = 1);
PRINT CONCAT(N'--- Notification tests: ', @passed, N' passed, ', @total - @passed, N' failed, ', @total, N' total ---');
IF @passed <> @total RAISERROR(N'Notification tests FAILED', 16, 1);
GO
