using System;
using System.Collections;
using System.Collections.Generic;
using System.Data;
using System.Data.SqlClient;
using System.Diagnostics;
using System.Linq;
using System.Reflection;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using TalentAcquisition.Common;
using TalentAcquisition.Models;

namespace TalentAcquisition.Data
{
    /// <summary>Opens pooled connections. When DbImpersonateUser is set the session switches to that least-privileged DATABASE USER
    /// (EXECUTE on procedures + SELECT on report views only) before any statement runs.</summary>
    public sealed class ConnectionManager
    {
        private readonly AppSettings _s;
        public ConnectionManager(AppSettings settings) { _s = settings; }
        public AppSettings Settings { get { return _s; } }

        public async Task<LeasedConnection> OpenAsync()
        {
            var c = new SqlConnection(_s.ConnectionString);
            await c.OpenAsync().ConfigureAwait(false);
            bool impersonating = false;
            if (!string.IsNullOrWhiteSpace(_s.DbImpersonateUser))
            {
                if (!Regex.IsMatch(_s.DbImpersonateUser, "^[A-Za-z0-9_]{1,64}$")) { c.Dispose(); throw new InvalidOperationException("Invalid impersonation user name."); }
                using (var cmd = c.CreateCommand())
                {
                    cmd.CommandText = "EXECUTE AS USER = '" + _s.DbImpersonateUser + "';";   // identifier validated above
                    await cmd.ExecuteNonQueryAsync().ConfigureAwait(false);
                }
                impersonating = true;
            }
            return new LeasedConnection(c, impersonating);
        }
    }

    /// <summary>A pooled connection that REVERTs its impersonation before it goes back to the pool: a pooled session still running
    /// under EXECUTE AS is killed by SQL Server when the pool resets it (error 596).</summary>
    public sealed class LeasedConnection : IDisposable
    {
        private readonly bool _impersonating;
        public SqlConnection Connection { get; private set; }
        public LeasedConnection(SqlConnection c, bool impersonating) { Connection = c; _impersonating = impersonating; }
        public void Dispose()
        {
            try
            {
                if (_impersonating && Connection.State == ConnectionState.Open)
                    using (var cmd = Connection.CreateCommand()) { cmd.CommandText = "REVERT;"; cmd.ExecuteNonQuery(); }
            }
            catch { SqlConnection.ClearPool(Connection); }     // if we cannot revert, never let this session be reused
            finally { Connection.Dispose(); }
        }
    }

    /// <summary>Fluent parameter list for a stored procedure; also binds a request DTO by reflection (property name = parameter name).</summary>
    public sealed class ProcParameters
    {
        private readonly List<SqlParameter> _list = new List<SqlParameter>();
        public IEnumerable<SqlParameter> Items { get { return _list; } }

        public static ProcParameters For(int actorUserId) { return new ProcParameters().Add("ActorUserId", actorUserId); }
        public static ProcParameters None() { return new ProcParameters(); }

        public ProcParameters Add(string name, object value)
        {
            if (value == null) return this;                       // omitted => the procedure's default applies
            SqlParameter p;
            if (value is decimal) { p = new SqlParameter("@" + name, SqlDbType.Decimal) { Precision = 18, Scale = 4, Value = value }; }   // default scale 0 would truncate cents
            else if (value is byte[]) { p = new SqlParameter("@" + name, SqlDbType.VarBinary, ((byte[])value).Length) { Value = value }; }
            else if (value is DateTime) { p = new SqlParameter("@" + name, SqlDbType.DateTime2) { Value = value }; }
            else if (value is string) { p = new SqlParameter("@" + name, SqlDbType.NVarChar, -1) { Value = value }; }
            else p = new SqlParameter("@" + name, value);
            _list.Add(p); return this;
        }

        public ProcParameters AddNullable(string name, object value) { _list.Add(new SqlParameter("@" + name, value ?? DBNull.Value)); return this; }

        public ProcParameters AddTvp(string name, string typeName, DataTable table)
        {
            _list.Add(new SqlParameter("@" + name, SqlDbType.Structured) { TypeName = typeName, Value = table }); return this;
        }

        /// <summary>Binds every public property of the DTO (except [NotProc] and ActorUserId); null values are omitted; lists marked [Tvp] become table-valued parameters.</summary>
        public ProcParameters From(object dto)
        {
            if (dto == null) return this;
            foreach (var prop in dto.GetType().GetProperties(BindingFlags.Public | BindingFlags.Instance))
            {
                if (prop.GetCustomAttribute<NotProcAttribute>() != null || prop.Name == "ActorUserId") continue;
                var value = prop.GetValue(dto, null);
                var tvp = prop.GetCustomAttribute<TvpAttribute>();
                if (tvp != null) { AddTvp(prop.Name, tvp.TypeName, ToTable((IEnumerable)value ?? new object[0])); continue; }
                Add(prop.Name, value);
            }
            return this;
        }

        private static DataTable ToTable(IEnumerable items)
        {
            var t = new DataTable();
            Type itemType = null; foreach (var i in items) { itemType = i.GetType(); break; }
            var listType = items.GetType(); var elem = listType.IsGenericType ? listType.GetGenericArguments()[0] : null;
            if (elem == null || elem.IsPrimitive) { t.Columns.Add("Id", typeof(int)); foreach (var i in items) t.Rows.Add(Convert.ToInt32(i)); return t; }
            var props = elem.GetProperties(BindingFlags.Public | BindingFlags.Instance);
            foreach (var p in props) t.Columns.Add(p.Name, Nullable.GetUnderlyingType(p.PropertyType) ?? p.PropertyType);
            foreach (var i in items) t.Rows.Add(props.Select(p => p.GetValue(i, null) ?? DBNull.Value).ToArray());
            return t;
        }
    }

    /// <summary>The ONLY way the application reaches SQL Server: parameterised stored procedures. Retries deadlock victims (1205), logs name + duration (never parameter values).</summary>
    public sealed class StoredProcedureExecutor
    {
        private readonly ConnectionManager _cm; private readonly ILog _log; private const int MaxAttempts = 3;
        public StoredProcedureExecutor(ConnectionManager cm, ILog log) { _cm = cm; _log = log; }

        public async Task<List<Row>> QueryAsync(string proc, ProcParameters p = null)
        {
            var sets = await QueryMultiAsync(proc, p).ConfigureAwait(false);
            return sets.Count > 0 ? sets[0] : new List<Row>();
        }

        public async Task<Row> QueryOneAsync(string proc, ProcParameters p = null)
        {
            var rows = await QueryAsync(proc, p).ConfigureAwait(false); return rows.FirstOrDefault();
        }

        public Task<List<List<Row>>> QueryMultiAsync(string proc, ProcParameters p = null)
        {
            return WithRetry(proc, async () =>
            {
                using (var lease = await _cm.OpenAsync().ConfigureAwait(false))
                {
                    var all = new List<List<Row>>();
                    using (var cmd = Build(lease.Connection, proc, p))
                    using (var rd = await cmd.ExecuteReaderAsync().ConfigureAwait(false))
                    {
                        do { var set = new List<Row>(); while (await rd.ReadAsync().ConfigureAwait(false)) set.Add(DataReaderMapper.ToRow(rd)); all.Add(set); } while (await rd.NextResultAsync().ConfigureAwait(false));
                    }
                    return all;                                   // reader closed before the lease reverts the impersonation
                }
            });
        }

        /// <summary>First result set with its column names and SQL types, known even when there are no rows (reports).</summary>
        public Task<ResultTable> QueryTableAsync(string proc, ProcParameters p = null)
        {
            return WithRetry(proc, async () =>
            {
                using (var lease = await _cm.OpenAsync().ConfigureAwait(false))
                using (var cmd = Build(lease.Connection, proc, p))
                using (var rd = await cmd.ExecuteReaderAsync().ConfigureAwait(false))
                {
                    var t = new ResultTable();
                    for (int i = 0; i < rd.FieldCount; i++) t.Columns.Add(new ResultColumn { Name = rd.GetName(i), SqlType = rd.GetDataTypeName(i).ToLowerInvariant() });
                    while (await rd.ReadAsync().ConfigureAwait(false)) t.Rows.Add(DataReaderMapper.ToRow(rd));
                    return t;
                }
            });
        }

        public Task ExecuteAsync(string proc, ProcParameters p = null)
        {
            return WithRetry<int>(proc, async () =>
            {
                using (var lease = await _cm.OpenAsync().ConfigureAwait(false))
                using (var cmd = Build(lease.Connection, proc, p)) { await cmd.ExecuteNonQueryAsync().ConfigureAwait(false); return 0; }
            });
        }

        private SqlCommand Build(SqlConnection conn, string proc, ProcParameters p)
        {
            var cmd = conn.CreateCommand(); cmd.CommandType = CommandType.StoredProcedure; cmd.CommandText = proc; cmd.CommandTimeout = _cm.Settings.CommandTimeoutSeconds;
            if (p != null) foreach (var sp in p.Items) cmd.Parameters.Add(Clone(sp));
            return cmd;
        }

        // a parameter object can belong to one command only; clone so a retry can reuse the list
        private static SqlParameter Clone(SqlParameter s)
        {
            var c = new SqlParameter(s.ParameterName, s.SqlDbType) { Value = s.Value, Size = s.Size, Precision = s.Precision, Scale = s.Scale, TypeName = s.TypeName, Direction = s.Direction };
            return c;
        }

        private async Task<T> WithRetry<T>(string proc, Func<Task<T>> work)
        {
            for (int attempt = 1; ; attempt++)
            {
                var sw = Stopwatch.StartNew();
                try { var r = await work().ConfigureAwait(false); _log.Info("sql " + proc + " ok " + sw.ElapsedMilliseconds + "ms"); return r; }
                catch (SqlException ex)
                {
                    bool deadlock = ex.Errors.Cast<SqlError>().Any(e => e.Number == 1205);
                    if (deadlock && attempt < MaxAttempts) { _log.Warn("sql " + proc + " deadlock victim, retry " + attempt); await Task.Delay(40 * attempt + new Random().Next(60)).ConfigureAwait(false); continue; }
                    var mapped = SqlErrorMapper.Map(ex);
                    _log.Info("sql " + proc + " failed " + ex.Number + " " + sw.ElapsedMilliseconds + "ms");
                    if (mapped != null) throw mapped;
                    throw;
                }
            }
        }
    }

    public static class DataReaderMapper
    {
        public static Row ToRow(IDataRecord r)
        {
            var row = new Row();
            for (int i = 0; i < r.FieldCount; i++) { var v = r.GetValue(i); row[r.GetName(i)] = v is DBNull ? null : v; }
            return row;
        }

        /// <summary>Maps a row onto a DTO by property name (case-insensitive), converting types.</summary>
        public static T Map<T>(Row row) where T : new()
        {
            var o = new T();
            foreach (var p in typeof(T).GetProperties(BindingFlags.Public | BindingFlags.Instance))
            {
                object v; if (!row.TryGetValue(p.Name, out v) || v == null || !p.CanWrite) continue;
                var t = Nullable.GetUnderlyingType(p.PropertyType) ?? p.PropertyType;
                p.SetValue(o, t == v.GetType() ? v : Convert.ChangeType(v, t), null);
            }
            return o;
        }
    }
}
