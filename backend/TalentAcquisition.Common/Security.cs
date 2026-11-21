using System;
using System.Collections.Generic;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using Newtonsoft.Json.Linq;
using TalentAcquisition.Models;

namespace TalentAcquisition.Common
{
    /// <summary>PBKDF2-SHA256, 210,000 iterations, 32-byte salt and hash — identical to what Set-DevPasswords.ps1 stores in sec.Users.</summary>
    public static class PasswordHasher
    {
        public const int Iterations = 210000;
        public const int SaltBytes = 32;
        public const int HashBytes = 32;

        public static void Hash(string password, out byte[] hash, out byte[] salt)
        {
            salt = new byte[SaltBytes];
            using (var rng = RandomNumberGenerator.Create()) rng.GetBytes(salt);
            hash = Derive(password, salt, Iterations);
        }

        public static byte[] Derive(string password, byte[] salt, int iterations)
        {
            using (var kdf = new Rfc2898DeriveBytes(password, salt, iterations, HashAlgorithmName.SHA256)) return kdf.GetBytes(HashBytes);
        }

        public static bool Verify(string password, byte[] salt, int iterations, byte[] expected)
        {
            if (salt == null || expected == null || salt.Length != SaltBytes || expected.Length != HashBytes || iterations < 10000) return false;
            return ConstantTimeEquals(Derive(password, salt, iterations), expected);
        }

        /// <summary>Burns the same CPU time as a real verification, so an unknown e-mail cannot be told apart by response time.</summary>
        public static void DummyVerify() { Derive("dummy-password-for-timing", new byte[SaltBytes], Iterations); }

        public static bool ConstantTimeEquals(byte[] a, byte[] b)
        {
            if (a == null || b == null || a.Length != b.Length) return false;
            int diff = 0; for (int i = 0; i < a.Length; i++) diff |= a[i] ^ b[i];
            return diff == 0;
        }
    }

    public static class PasswordPolicy
    {
        /// <summary>At least 10 characters with an upper-case letter, a lower-case letter and a digit.</summary>
        public static void Validate(string password)
        {
            if (string.IsNullOrEmpty(password) || password.Length < 10 || password.Length > 128 || !password.Any(char.IsUpper) || !password.Any(char.IsLower) || !password.Any(char.IsDigit))
                throw new ApiException(400, "weak_password", "The password must be 10-128 characters and contain an upper-case letter, a lower-case letter and a digit.");
        }
    }

    public static class TokenGenerator
    {
        public static string NewUrlSafeToken(int bytes = 32)
        {
            var b = new byte[bytes]; using (var rng = RandomNumberGenerator.Create()) rng.GetBytes(b);
            return Convert.ToBase64String(b).TrimEnd('=').Replace('+', '-').Replace('/', '_');
        }
        public static byte[] Sha256(string value) { using (var sha = SHA256.Create()) return sha.ComputeHash(Encoding.UTF8.GetBytes(value)); }
    }

    /// <summary>Minimal HS256 JWT implementation (no external dependency). Validation checks signature (constant time), algorithm, issuer, audience, nbf and exp.</summary>
    public sealed class JwtTokenService
    {
        private readonly byte[] _key; private readonly string _issuer, _audience; private readonly int _minutes;
        public JwtTokenService(AppSettings s) { _key = Encoding.UTF8.GetBytes(s.JwtSecret); _issuer = s.JwtIssuer; _audience = s.JwtAudience; _minutes = s.TokenMinutes; }

        public string Create(UserProfile u, Guid jti, out DateTime expires)
        {
            var now = DateTime.UtcNow; expires = now.AddMinutes(_minutes);
            var p = new JObject
            {
                ["sub"] = u.UserId.ToString(), ["jti"] = jti.ToString(), ["name"] = u.DisplayName, ["iss"] = _issuer, ["aud"] = _audience,
                ["iat"] = Unix(now), ["nbf"] = Unix(now), ["exp"] = Unix(expires), ["roles"] = new JArray(u.Roles ?? new string[0])
            };
            if (u.CustomerId.HasValue) p["cid"] = u.CustomerId.Value;
            if (u.CandidateId.HasValue) p["cand"] = u.CandidateId.Value;
            if (u.ContractorId.HasValue) p["ctr"] = u.ContractorId.Value;
            var h = B64(Encoding.UTF8.GetBytes("{\"alg\":\"HS256\",\"typ\":\"JWT\"}")); var b = B64(Encoding.UTF8.GetBytes(p.ToString(Newtonsoft.Json.Formatting.None)));
            return h + "." + b + "." + B64(Sign(h + "." + b));
        }

        /// <summary>Returns null when the token is malformed, tampered with, expired or not for this API.</summary>
        public TokenInfo Validate(string token)
        {
            try
            {
                var parts = (token ?? "").Split('.'); if (parts.Length != 3) return null;
                var header = JObject.Parse(Encoding.UTF8.GetString(Unb64(parts[0])));
                if ((string)header["alg"] != "HS256") return null;                                   // rejects "none" and algorithm confusion
                if (!PasswordHasher.ConstantTimeEquals(Sign(parts[0] + "." + parts[1]), Unb64(parts[2]))) return null;
                var p = JObject.Parse(Encoding.UTF8.GetString(Unb64(parts[1])));
                var now = Unix(DateTime.UtcNow);
                if ((string)p["iss"] != _issuer || (string)p["aud"] != _audience) return null;
                if ((long?)p["exp"] == null || (long)p["exp"] <= now || ((long?)p["nbf"] ?? 0) > now + 30) return null;
                return new TokenInfo
                {
                    UserId = int.Parse((string)p["sub"]), Jti = Guid.Parse((string)p["jti"]), Name = (string)p["name"],
                    Roles = ((JArray)p["roles"]).Select(x => (string)x).ToArray(), ExpiresAt = DateTimeOffset.FromUnixTimeSeconds((long)p["exp"]).UtcDateTime,
                    CustomerId = (int?)p["cid"], CandidateId = (int?)p["cand"], ContractorId = (int?)p["ctr"]
                };
            }
            catch { return null; }
        }

        private byte[] Sign(string data) { using (var h = new HMACSHA256(_key)) return h.ComputeHash(Encoding.ASCII.GetBytes(data)); }
        private static long Unix(DateTime utc) { return (long)(utc - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalSeconds; }
        private static string B64(byte[] b) { return Convert.ToBase64String(b).TrimEnd('=').Replace('+', '-').Replace('/', '_'); }
        private static byte[] Unb64(string s) { s = s.Replace('-', '+').Replace('_', '/'); switch (s.Length % 4) { case 2: s += "=="; break; case 3: s += "="; break; } return Convert.FromBase64String(s); }
    }

    public static class Guard
    {
        private static readonly Regex Email = new Regex(@"^[^@\s]+@[^@\s]+\.[^@\s]+$", RegexOptions.Compiled);
        public static string Required(string v, string field, int max = 4000)
        {
            if (string.IsNullOrWhiteSpace(v)) throw new ApiException(400, "validation", field + " is required.");
            if (v.Length > max) throw new ApiException(400, "validation", field + " is too long.");
            return v.Trim();
        }
        public static string EmailAddress(string v) { v = Required(v, "E-mail", 256); if (!Email.IsMatch(v)) throw new ApiException(400, "validation", "A valid e-mail address is required."); return v; }
        public static int Positive(int v, string field) { if (v <= 0) throw new ApiException(400, "validation", field + " must be a positive number."); return v; }
        public static void Page(ref int page, ref int size, int max = 200) { if (page < 1) page = 1; if (size < 1 || size > max) size = 25; }
    }
}
