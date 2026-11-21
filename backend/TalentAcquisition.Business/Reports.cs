using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using TalentAcquisition.Common;
using TalentAcquisition.Data;
using TalentAcquisition.Models;

namespace TalentAcquisition.Business
{
    /// <summary>
    /// Phase 10 reports. The database decides who may run what and scopes the data (report.usp_RunReport); this service
    /// validates the request, describes the columns (label + display type) and builds the CSV export.
    /// </summary>
    public sealed class ReportService
    {
        public const int MaxRows = 10000;
        private static readonly Newtonsoft.Json.Serialization.NamingStrategy Camel = new Newtonsoft.Json.Serialization.CamelCaseNamingStrategy();
        private static readonly Regex Code = new Regex("^[a-z][a-z-]{2,39}$", RegexOptions.Compiled);
        private readonly ReportRepository _r; private readonly ILog _log;
        public ReportService(ReportRepository r, ILog log) { _r = r; _log = log; }

        public Task<List<Row>> ListAsync(int actor) { return _r.ListAsync(actor); }

        /// <param name="format">view (on screen) or csv (exported); recorded in audit.ReportRuns by the database.</param>
        public async Task<ReportResult> RunAsync(int actor, string code, DateTime? from, DateTime? to, int? customerId, int? days, string format = "view")
        {
            if (code == null || !Code.IsMatch(code)) throw new ApiException(404, "not_found", "Report not found.");
            if (from.HasValue && to.HasValue && from.Value.Date > to.Value.Date) throw new ApiException(400, "validation", "The start date must not be after the end date.");
            if (days.HasValue && (days.Value < 1 || days.Value > 365)) throw new ApiException(400, "validation", "Days must be between 1 and 365.");
            from = from.HasValue ? from.Value.Date : (DateTime?)null; to = to.HasValue ? to.Value.Date : (DateTime?)null;

            var table = await _r.RunAsync(actor, code, from, to, customerId, days, format);      // authorisation + scope + audit happen here
            var def = (await _r.ListAsync(actor)).FirstOrDefault(d => d.Str("ReportCode") == code);
            if (def == null) throw new ApiException(404, "not_found", "Report not found.");
            _log.Info("report run code=" + code + " format=" + format + " actor=" + actor + " rows=" + table.Rows.Count);

            bool truncated = table.Rows.Count > MaxRows;
            return new ReportResult
            {
                Report = def,
                // Key = the name as it appears in the JSON rows (the API camel-cases row keys); rows themselves stay case-insensitive
                Columns = table.Columns.Select(c => new ReportColumn { Key = Camel.GetPropertyName(c.Name, false), Label = Label(c.Name), Type = DisplayType(c.Name, c.SqlType) }).ToList(),
                Rows = truncated ? table.Rows.Take(MaxRows).ToList() : table.Rows,
                RowCount = table.Rows.Count, Truncated = truncated, GeneratedAt = DateTime.UtcNow,
                From = from, To = to, CustomerId = customerId, Days = days
            };
        }

        /// <summary>"Overdue1To30Days" -> "Overdue 1 to 30 days", "HireRatePct" -> "Hire rate %", "ContractNo" -> "Contract no."</summary>
        public static string Label(string name)
        {
            var words = Regex.Matches(name ?? "", "[A-Z]+(?![a-z])|[A-Z]?[a-z]+|[0-9]+").Cast<Match>().Select(m => m.Value).ToList();
            if (words.Count == 0) return name;
            var outWords = new List<string>();
            for (int i = 0; i < words.Count; i++)
            {
                var w = words[i];
                if (w == "Pct") { outWords.Add("%"); continue; }
                if (w == "No" && i == words.Count - 1) { outWords.Add("no."); continue; }
                bool acronym = w.Length > 1 && w.All(char.IsUpper);
                outWords.Add(i == 0 || acronym ? w : w.ToLowerInvariant());
            }
            return string.Join(" ", outWords);
        }

        public static string DisplayType(string name, string sqlType)
        {
            switch (sqlType)
            {
                case "date": return "date";
                case "datetime": case "datetime2": case "smalldatetime": case "datetimeoffset": return "datetime";
                case "bit": return "bool";
                case "int": case "bigint": case "smallint": case "tinyint": return "number";
                case "decimal": case "numeric": case "money": case "smallmoney": case "float": case "real":
                    if (name.EndsWith("Pct", StringComparison.Ordinal)) return "percent";
                    if (name.EndsWith("Hours", StringComparison.Ordinal)) return "hours";
                    if (name == "Total" || name.StartsWith("Overdue", StringComparison.Ordinal) ||
                        new[] { "Rate", "Amount", "Outstanding", "Balance", "Paid", "Due" }.Any(s => name.EndsWith(s, StringComparison.Ordinal))) return "money";
                    return "number";
                default: return "text";
            }
        }

        /// <summary>RFC 4180 CSV (UTF-8 with BOM so spreadsheet programs read accents). Text that a spreadsheet would run as a
        /// formula (starting with = + - @ tab or CR) is prefixed with an apostrophe (CSV/formula injection).</summary>
        public static byte[] ToCsv(ReportResult r)
        {
            var sb = new StringBuilder();
            sb.Append(string.Join(",", r.Columns.Select(c => Field(c.Type == "datetime" ? c.Label + " (UTC)" : c.Label)))).Append("\r\n");
            foreach (var row in r.Rows)
            {
                sb.Append(string.Join(",", r.Columns.Select(c => { object v; row.TryGetValue(c.Key, out v); return Field(Value(v, c.Type)); }))).Append("\r\n");
            }
            var bom = Encoding.UTF8.GetPreamble(); var body = Encoding.UTF8.GetBytes(sb.ToString());
            var all = new byte[bom.Length + body.Length]; Buffer.BlockCopy(bom, 0, all, 0, bom.Length); Buffer.BlockCopy(body, 0, all, bom.Length, body.Length);
            return all;
        }

        private static string Value(object v, string type)
        {
            if (v == null) return "";
            if (v is DateTime) { var d = (DateTime)v; return type == "date" ? d.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture) : d.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture); }
            if (v is bool) return (bool)v ? "Yes" : "No";
            if (v is IFormattable) return ((IFormattable)v).ToString(null, CultureInfo.InvariantCulture);
            var s = Convert.ToString(v, CultureInfo.InvariantCulture);
            if (s.Length > 0 && "=+-@\t\r".IndexOf(s[0]) >= 0) s = "'" + s;            // never a formula when opened in a spreadsheet
            return s;
        }

        private static string Field(string s)
        {
            if (s == null) return "";
            return s.IndexOfAny(new[] { ',', '"', '\r', '\n' }) >= 0 || s != s.Trim() ? "\"" + s.Replace("\"", "\"\"") + "\"" : s;
        }
    }
}
