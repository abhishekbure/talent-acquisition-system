using System;
using System.Collections.Generic;

namespace TalentAcquisition.Models
{
    /// <summary>The property is NOT passed to the stored procedure (route ids, helper fields).</summary>
    [AttributeUsage(AttributeTargets.Property)]
    public sealed class NotProcAttribute : Attribute { }

    /// <summary>The property (a list) is passed as a table-valued parameter of this SQL type.</summary>
    [AttributeUsage(AttributeTargets.Property)]
    public sealed class TvpAttribute : Attribute
    {
        public string TypeName { get; private set; }
        public TvpAttribute(string typeName) { TypeName = typeName; }
    }

    /// <summary>One database row: column name (case-insensitive) -> value (null for SQL NULL).</summary>
    public sealed class Row : Dictionary<string, object>
    {
        public Row() : base(StringComparer.OrdinalIgnoreCase) { }
        public string Str(string c) { object v; return TryGetValue(c, out v) && v != null ? Convert.ToString(v) : null; }
        public int? IntN(string c) { object v; return TryGetValue(c, out v) && v != null ? (int?)Convert.ToInt32(v) : null; }
        public int Int(string c) { return IntN(c) ?? 0; }
        public bool Bool(string c) { object v; return TryGetValue(c, out v) && v != null && Convert.ToBoolean(v); }
        public DateTime? Date(string c) { object v; return TryGetValue(c, out v) && v != null ? (DateTime?)Convert.ToDateTime(v) : null; }
        public byte[] Bytes(string c) { object v; return TryGetValue(c, out v) ? v as byte[] : null; }
    }

    /// <summary>A result set with its column names and SQL types (known even with no rows).</summary>
    public sealed class ResultTable
    {
        public List<ResultColumn> Columns { get; } = new List<ResultColumn>();
        public List<Row> Rows { get; } = new List<Row>();
    }
    public sealed class ResultColumn { public string Name { get; set; } public string SqlType { get; set; } }

    /// <summary>Phase 10: a report column as the UI and the CSV export show it. Type: text, number, money, percent, hours, date, datetime, bool.</summary>
    public sealed class ReportColumn { public string Key { get; set; } public string Label { get; set; } public string Type { get; set; } }

    public sealed class ReportResult
    {
        public Row Report { get; set; }
        public List<ReportColumn> Columns { get; set; }
        public List<Row> Rows { get; set; }
        public int RowCount { get; set; }
        public bool Truncated { get; set; }
        public DateTime GeneratedAt { get; set; }
        public DateTime? From { get; set; }
        public DateTime? To { get; set; }
        public int? CustomerId { get; set; }
        public int? Days { get; set; }
    }

    /// <summary>Phase 13: a list cut at a limit (newest first). Serialised as a plain JSON array; the API adds the headers
    /// X-Result-Limit and X-Result-Truncated so a client can tell people to narrow their filters.</summary>
    public sealed class CappedList : List<Row>
    {
        public int Limit { get; set; }
        public bool Truncated { get; set; }
    }

    public sealed class PagedResult
    {
        public List<Row> Items { get; set; }
        public int Total { get; set; }
        public int Page { get; set; }
        public int PageSize { get; set; }
    }

    public sealed class ApiError
    {
        public string Code { get; set; }
        public string Message { get; set; }
        public string CorrelationId { get; set; }
        public Dictionary<string, string[]> Details { get; set; }
    }

    /// <summary>Entry of a table-valued parameter (rec.JobSkillList).</summary>
    public sealed class SkillItem
    {
        public string SkillName { get; set; }
        public bool IsRequired { get; set; } = true;
        public decimal MinYears { get; set; }
    }

    /// <summary>Entry of a table-valued parameter ([time].TimesheetEntryList).</summary>
    public sealed class TimesheetEntryItem
    {
        public DateTime WorkDate { get; set; }
        public decimal Hours { get; set; }
        public string EntryType { get; set; } = "Regular";
        public bool IsBillable { get; set; } = true;
        public string Notes { get; set; }
    }

    public sealed class UserProfile
    {
        public int UserId { get; set; }
        public string Email { get; set; }
        public string DisplayName { get; set; }
        public string[] Roles { get; set; }
        public int? CustomerId { get; set; }
        public string CustomerName { get; set; }
        public int? CandidateId { get; set; }
        public int? ContractorId { get; set; }
        public int UnreadNotifications { get; set; }
        public string[] Permissions { get; set; }
    }

    public sealed class LoginResponse
    {
        public string Token { get; set; }
        public DateTime ExpiresAt { get; set; }
        public UserProfile User { get; set; }
    }

    /// <summary>What a validated token tells the pipeline about the caller.</summary>
    public sealed class TokenInfo
    {
        public int UserId { get; set; }
        public Guid Jti { get; set; }
        public string Name { get; set; }
        public string[] Roles { get; set; }
        public int? CustomerId { get; set; }
        public int? CandidateId { get; set; }
        public int? ContractorId { get; set; }
        public DateTime ExpiresAt { get; set; }
    }
}
