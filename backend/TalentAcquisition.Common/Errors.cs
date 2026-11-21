using System;
using System.Data.SqlClient;

namespace TalentAcquisition.Common
{
    /// <summary>An error that maps directly to an HTTP response. The message is safe to show to the client.</summary>
    public class ApiException : Exception
    {
        public int Status { get; private set; }
        public string Code { get; private set; }
        public ApiException(int status, string code, string message) : base(message) { Status = status; Code = code; }
    }

    /// <summary>Translates SQL Server errors (our THROW 5000x numbers and well-known engine errors) into ApiExceptions. Raw SQL text never reaches the client.</summary>
    public static class SqlErrorMapper
    {
        public static ApiException Map(SqlException ex)
        {
            foreach (SqlError e in ex.Errors)
            {
                switch (e.Number)
                {
                    case 50001: return new ApiException(400, "validation", e.Message);
                    case 50002: return new ApiException(422, "business_rule", e.Message);
                    case 50003: return new ApiException(409, "conflict", e.Message);
                    case 50004: return new ApiException(404, "not_found", e.Message);
                    case 50005: return new ApiException(403, "forbidden", e.Message);
                    case 50006: return new ApiException(409, "concurrency", e.Message);
                    case 2601: case 2627: return new ApiException(409, "conflict", "That record already exists.");
                    case 547: return new ApiException(422, "constraint", "The change violates a data rule.");
                    case 1205: return new ApiException(503, "busy", "The system is busy. Please try again.");
                    case 1222: return new ApiException(503, "busy", "The system is busy. Please try again.");
                    case -2: return new ApiException(504, "timeout", "The database did not answer in time.");
                    // Phase 13: the database cannot be reached or opened (server down, database offline or missing, login refused).
                    // A 503 tells the client to try again later; the details stay in the server log.
                    case -1: case 2: case 53: case 233: case 4060: case 4064: case 18456: case 10053: case 10054: case 10060: case 40613:
                        return new ApiException(503, "unavailable", "The database is not available. Please try again later.");
                    case 229: case 262: return new ApiException(500, "server_error", "An internal error occurred.");
                }
            }
            return null;   // not one of ours: treated as an unexpected server error by the caller
        }
    }
}
