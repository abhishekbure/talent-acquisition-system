using System;
using System.Linq;
using System.Threading.Tasks;
using TalentAcquisition.Common;
using TalentAcquisition.Data;
using TalentAcquisition.Models;

namespace TalentAcquisition.Business
{
    /// <summary>Authentication: PBKDF2 password verification, lockout (enforced in sec.usp_RecordLoginAttempt), JWT issue with a server-side
    /// revocable jti, registration, password reset (single-use hashed token delivered through the notification queue), logout.</summary>
    public sealed class AuthService
    {
        private readonly AuthRepository _repo; private readonly JwtTokenService _jwt; private readonly AppSettings _s; private readonly ILog _log;
        public AuthService(AuthRepository repo, JwtTokenService jwt, AppSettings s, ILog log) { _repo = repo; _jwt = jwt; _s = s; _log = log; }

        private static ApiException BadCredentials() { return new ApiException(401, "invalid_credentials", "Invalid e-mail or password."); }

        public async Task<LoginResponse> LoginAsync(LoginRequest r, string ip, string userAgent)
        {
            var email = Guard.Required(r == null ? null : r.Email, "E-mail", 256); var password = r.Password ?? "";
            var u = await _repo.GetUserForLoginAsync(email);
            if (u == null)
            {
                PasswordHasher.DummyVerify();                                     // same cost as a real check: no user enumeration by timing
                await _repo.RecordLoginAttemptAsync(email, false, "unknown account", ip, userAgent);
                throw BadCredentials();
            }
            var lockout = u.Date("LockoutUntil");
            if (lockout.HasValue && lockout.Value > DateTime.UtcNow)
            {
                await _repo.RecordLoginAttemptAsync(email, false, "locked", ip, userAgent);
                throw new ApiException(429, "locked", "Too many failed attempts. The account is temporarily locked; try again later.");
            }
            bool ok = u.Bool("IsActive") && PasswordHasher.Verify(password, u.Bytes("PasswordSalt"), u.Int("HashIterations"), u.Bytes("PasswordHash"));
            if (!ok)
            {
                await _repo.RecordLoginAttemptAsync(email, false, u.Bool("IsActive") ? "bad password" : "inactive", ip, userAgent);
                throw BadCredentials();
            }
            if (!u.Date("EmailVerifiedAt").HasValue)
            {
                // only someone who knows the password learns that the address is unconfirmed; not counted towards lockout
                await _repo.RecordLoginAttemptAsync(email, false, "email not verified", ip, userAgent, countFailure: false);
                throw new ApiException(403, "email_unverified", "Please confirm your e-mail address first: open the link we sent to it. You can ask for a new link here.");
            }
            await _repo.RecordLoginAttemptAsync(email, true, null, ip, userAgent);
            var profile = new UserProfile
            {
                UserId = u.Int("UserId"), Email = u.Str("Email"), DisplayName = u.Str("DisplayName"),
                Roles = (u.Str("Roles") ?? "").Split(new[] { ',' }, StringSplitOptions.RemoveEmptyEntries),
                CustomerId = u.IntN("CustomerId"), CandidateId = u.IntN("CandidateId"), ContractorId = u.IntN("ContractorId")
            };
            var jti = Guid.NewGuid(); DateTime expires;
            var token = _jwt.Create(profile, jti, out expires);
            await _repo.IssueTokenAsync(profile.UserId, jti, expires);
            _log.Info("auth login ok user=" + profile.UserId);
            return new LoginResponse { Token = token, ExpiresAt = expires, User = profile };
        }

        /// <summary>Used by the authentication middleware on every request: signature/expiry AND the server-side jti (revocation, deactivation).</summary>
        public async Task<TokenInfo> ValidateAsync(string token)
        {
            var info = _jwt.Validate(token);
            if (info == null) return null;
            var row = await _repo.ValidateTokenAsync(info.Jti);
            if (row == null || row.Int("UserId") != info.UserId) return null;
            // current roles from the database win over the roles captured in the token at sign-in
            var roles = row.Str("Roles");
            info.Roles = string.IsNullOrEmpty(roles) ? new string[0] : roles.Split(new[] { ',' }, StringSplitOptions.RemoveEmptyEntries);
            return info;
        }

        public Task LogoutAsync(Guid jti) { return _repo.RevokeTokenAsync(jti, "logout"); }

        public const int VerificationHours = 24;

        /// <summary>Creates an unverified candidate login and e-mails a one-time confirmation link. The response says nothing about
        /// existing candidate records (that would reveal who a recruiter has on file).</summary>
        public async Task<RegisterResponse> RegisterAsync(RegisterRequest r)
        {
            if (r == null) throw new ApiException(400, "validation", "A request body is required.");
            r.Email = Guard.EmailAddress(r.Email); r.FirstName = Guard.Required(r.FirstName, "First name", 100); r.LastName = Guard.Required(r.LastName, "Last name", 100);
            PasswordPolicy.Validate(r.Password);
            byte[] hash, salt; PasswordHasher.Hash(r.Password, out hash, out salt);
            var token = TokenGenerator.NewUrlSafeToken(); var tokenHash = TokenGenerator.Sha256(token);
            var row = await _repo.RegisterCandidateAsync(r, hash, salt, PasswordHasher.Iterations, tokenHash, DateTime.UtcNow.AddHours(VerificationHours));
            int userId = row.Int("UserId");
            await QueueVerificationAsync(userId, token, tokenHash);
            _log.Info("auth register user=" + userId + " (verification e-mail queued)");
            return new RegisterResponse { Email = r.Email, VerificationRequired = true, Message = "Account created. We have e-mailed you a link to confirm your address; sign in after confirming." };
        }

        public async Task<object> VerifyEmailAsync(VerifyEmailRequest r)
        {
            var token = Guard.Required(r == null ? null : r.Token, "Token", 200);
            var row = await _repo.VerifyEmailAsync(TokenGenerator.Sha256(token));
            _log.Info("auth email verified user=" + row.Int("UserId"));
            return new { verified = true, email = row.Str("Email") };
        }

        /// <summary>Always "accepted": never reveals whether the address exists or is already confirmed (and at most one link a minute is created).</summary>
        public async Task ResendVerificationAsync(ResendVerificationRequest r)
        {
            var email = ((r == null ? null : r.Email) ?? "").Trim();
            if (email.Length == 0 || email.Length > 256) return;
            var token = TokenGenerator.NewUrlSafeToken(); var tokenHash = TokenGenerator.Sha256(token);
            var row = await _repo.CreateEmailVerificationAsync(email, tokenHash, DateTime.UtcNow.AddHours(VerificationHours));
            var userId = row == null ? null : row.IntN("UserId");
            if (userId.HasValue) await QueueVerificationAsync(userId.Value, token, tokenHash);
        }

        private Task QueueVerificationAsync(int userId, string token, byte[] tokenHash)
        {
            var link = _s.VerifyEmailLinkBase + "?token=" + Uri.EscapeDataString(token);
            return _repo.EnqueueNotificationAsync("EMAIL_VERIFY", userId, "Confirm your e-mail address for TAMS",
                "Welcome to TAMS. To activate your account, confirm that this e-mail address is yours by opening this link (valid for " + VerificationHours + " hours, usable once): " + link
                + " . If you did not create an account, ignore this message; nothing more will happen.",
                "EMAILVERIFY:" + BitConverter.ToString(tokenHash, 0, 8).Replace("-", ""), "User", userId);
        }

        public async Task ForgotPasswordAsync(ForgotPasswordRequest r)
        {
            var email = (r == null ? null : r.Email) ?? "";
            if (email.Length == 0 || email.Length > 256) return;                 // always "accepted": never reveal whether an account exists
            var token = TokenGenerator.NewUrlSafeToken();
            var hash = TokenGenerator.Sha256(token);
            var row = await _repo.CreatePasswordResetAsync(email.Trim(), hash, DateTime.UtcNow.AddMinutes(30));
            var userId = row == null ? null : row.IntN("UserId");
            if (userId.HasValue)
            {
                var link = _s.ResetLinkBase + "?token=" + Uri.EscapeDataString(token);
                await _repo.EnqueueNotificationAsync("PASSWORD_RESET", userId.Value, "Reset your TAMS password",
                    "A password reset was requested for your account. The link is valid for 30 minutes and can be used once: " + link + " . If you did not ask for this, ignore this message.",
                    "PWDRESET:" + BitConverter.ToString(hash, 0, 8).Replace("-", ""), "User", userId.Value);
            }
        }

        public async Task ResetPasswordAsync(ResetPasswordRequest r)
        {
            Guard.Required(r == null ? null : r.Token, "Token", 200); PasswordPolicy.Validate(r.NewPassword);
            byte[] hash, salt; PasswordHasher.Hash(r.NewPassword, out hash, out salt);
            await _repo.ConsumePasswordResetAsync(TokenGenerator.Sha256(r.Token), hash, salt, PasswordHasher.Iterations);
        }

        public async Task ChangePasswordAsync(int actor, ChangePasswordRequest r)
        {
            if (r == null) throw new ApiException(400, "validation", "A request body is required.");
            var me = await _repo.GetMeAsync(actor);
            var u = await _repo.GetUserForLoginAsync(me.Str("Email"));
            if (u == null || !PasswordHasher.Verify(r.CurrentPassword ?? "", u.Bytes("PasswordSalt"), u.Int("HashIterations"), u.Bytes("PasswordHash")))
                throw new ApiException(400, "invalid_password", "The current password is not correct.");
            PasswordPolicy.Validate(r.NewPassword);
            byte[] hash, salt; PasswordHasher.Hash(r.NewPassword, out hash, out salt);
            await _repo.ChangePasswordAsync(actor, hash, salt, PasswordHasher.Iterations);
        }

        public async Task<UserProfile> MeAsync(int actor)
        {
            var me = await _repo.GetMeAsync(actor);
            var perms = await _repo.GetMyPermissionsAsync(actor);
            return new UserProfile
            {
                UserId = me.Int("UserId"), Email = me.Str("Email"), DisplayName = me.Str("DisplayName"),
                Roles = (me.Str("Roles") ?? "").Split(new[] { ',' }, StringSplitOptions.RemoveEmptyEntries),
                CustomerId = me.IntN("CustomerId"), CustomerName = me.Str("CustomerName"), CandidateId = me.IntN("CandidateId"), ContractorId = me.IntN("ContractorId"),
                UnreadNotifications = me.Int("UnreadNotifications"), Permissions = perms.Select(p => p.Str("Code")).ToArray()
            };
        }

        public Task<Row> PingAsync() { return _repo.PingAsync(); }
    }
}
