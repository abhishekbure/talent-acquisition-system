using System;
using System.IO;
using System.Text;

namespace TalentAcquisition.Common
{
    public interface ILog
    {
        void Info(string message);
        void Warn(string message);
        void Error(string message, Exception ex = null);
    }

    /// <summary>Thread-safe daily-rolling file logger that also writes to the console. Never logs secrets: callers pass only names and ids.</summary>
    public sealed class FileLog : ILog
    {
        private readonly string _dir; private readonly object _lock = new object(); private readonly bool _console; private readonly string _prefix;
        public FileLog(string directory, bool console = true, string prefix = "api") { _dir = directory; _console = console; _prefix = prefix; Directory.CreateDirectory(_dir); }

        private void Write(string level, string message)
        {
            var line = DateTime.UtcNow.ToString("yyyy-MM-dd HH:mm:ss.fff") + "Z " + level + " " + message;
            lock (_lock)
            {
                try { File.AppendAllText(Path.Combine(_dir, _prefix + "-" + DateTime.UtcNow.ToString("yyyyMMdd") + ".log"), line + Environment.NewLine, Encoding.UTF8); } catch { /* logging must never break a request */ }
                if (_console) Console.WriteLine(line);
            }
        }
        public void Info(string message) { Write("INFO ", message); }
        public void Warn(string message) { Write("WARN ", message); }
        public void Error(string message, Exception ex = null) { Write("ERROR", ex == null ? message : message + " :: " + ex.GetType().Name + ": " + ex.Message + Environment.NewLine + ex.StackTrace); }
    }

    public sealed class NullLog : ILog
    {
        public void Info(string message) { }
        public void Warn(string message) { }
        public void Error(string message, Exception ex = null) { }
    }

    /// <summary>
    /// Phase 12: structured log for scheduled tasks. Each entry is one JSON object per line (timestamp, level, task, run,
    /// message, and named fields) in {dir}\{prefix}-yyyyMMdd.jsonl, and a readable line on the console. A scope adds the task
    /// and run id to every entry. Never log secrets: callers pass names, ids and counts.
    /// </summary>
    public sealed class StructuredLog : ILog
    {
        private readonly string _dir, _prefix; private readonly bool _console; private readonly object _lock;
        private readonly System.Collections.Generic.Dictionary<string, object> _scope;
        public StructuredLog(string directory, string prefix = "scheduler", bool console = true)
            : this(directory, prefix, console, new object(), new System.Collections.Generic.Dictionary<string, object>()) { Directory.CreateDirectory(directory); }
        private StructuredLog(string d, string p, bool c, object l, System.Collections.Generic.Dictionary<string, object> scope) { _dir = d; _prefix = p; _console = c; _lock = l; _scope = scope; }

        /// <summary>A log whose entries also carry these fields (e.g. task and run).</summary>
        public StructuredLog With(string key, object value)
        {
            var s = new System.Collections.Generic.Dictionary<string, object>(_scope) { [key] = value };
            return new StructuredLog(_dir, _prefix, _console, _lock, s);
        }

        public void Write(string level, string message, object fields = null, Exception ex = null)
        {
            var o = new Newtonsoft.Json.Linq.JObject { ["ts"] = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffZ"), ["level"] = level };
            foreach (var kv in _scope) o[kv.Key] = kv.Value == null ? null : Newtonsoft.Json.Linq.JToken.FromObject(kv.Value);
            o["msg"] = message;
            if (fields != null) foreach (var p in Newtonsoft.Json.Linq.JObject.FromObject(fields).Properties()) o[p.Name] = p.Value;
            if (ex != null) { o["error"] = ex.GetType().Name + ": " + ex.Message; }
            var line = o.ToString(Newtonsoft.Json.Formatting.None);
            lock (_lock)
            {
                try { File.AppendAllText(Path.Combine(_dir, _prefix + "-" + DateTime.UtcNow.ToString("yyyyMMdd") + ".jsonl"), line + Environment.NewLine, Encoding.UTF8); } catch { /* logging never breaks a task */ }
                if (_console)
                {
                    object task; _scope.TryGetValue("task", out task);
                    Console.WriteLine(DateTime.UtcNow.ToString("HH:mm:ss") + "Z " + level.ToUpperInvariant().PadRight(5) + " " + (task == null ? "" : "[" + task + "] ") + message
                                      + (ex == null ? "" : " :: " + ex.GetType().Name + ": " + ex.Message));
                }
            }
        }
        public void Info(string message) { Write("info", message); }
        public void Warn(string message) { Write("warn", message); }
        public void Error(string message, Exception ex = null) { Write("error", message, null, ex); }
    }
}
