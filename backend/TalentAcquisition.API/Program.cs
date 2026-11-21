using System;
using System.Threading;
using Microsoft.Owin.Hosting;
using TalentAcquisition.Business;
using TalentAcquisition.Common;

namespace TalentAcquisition.API
{
    /// <summary>
    /// Self-hosted ASP.NET Web API 2 (OWIN/HttpListener) on .NET Framework 4.7.2.
    /// Exit codes: 0 normal stop, 2 invalid configuration, 3 database unreachable at start-up, 4 could not bind the listen URL.
    ///   --check   validate configuration + database connectivity, then exit.
    /// </summary>
    public static class Program
    {
        public static int Main(string[] args)
        {
            // Phase 14: --settings <file> applies an extra JSON file after appsettings(.local).json (used by the automated
            // end-to-end run to point a throwaway API at a disposable database copy and temporary folders)
            AppSettings settings;
            int si = Array.IndexOf(args, "--settings");
            try { settings = AppSettings.Load(null, si >= 0 && si + 1 < args.Length ? args[si + 1] : null); }
            catch (Exception ex) when (ex is System.IO.FileNotFoundException || ex is Newtonsoft.Json.JsonException) { Console.Error.WriteLine("CONFIG ERROR: " + ex.Message); return 2; }
            var problems = settings.Validate();
            if (problems.Length > 0) { foreach (var p in problems) Console.Error.WriteLine("CONFIG ERROR: " + p); return 2; }
            var log = new FileLog(settings.LogDirectory);
            var root = new CompositionRoot(settings, log);
            try
            {
                var ping = root.Get<AuthService>().PingAsync().GetAwaiter().GetResult();
                log.Info("database reachable: " + ping.Str("DatabaseName") + " as database user '" + ping.Str("DatabaseUser") + "'");
            }
            catch (Exception ex) { log.Error("database is not reachable", ex); return 3; }
            if (Array.IndexOf(args, "--check") >= 0) { Console.WriteLine("CHECK OK"); return 0; }

            IDisposable app;
            try { app = WebApp.Start(new StartOptions(settings.ListenUrl), a => new Startup(root).Configuration(a)); }
            catch (Exception ex) { log.Error("could not listen on " + settings.ListenUrl, ex); return 4; }
            using (app)
            {
                var stop = new ManualResetEventSlim(false);
                Console.CancelKeyPress += (s, e) => { e.Cancel = true; stop.Set(); };
                log.Info("TalentAcquisition.API listening on " + settings.ListenUrl + " (Ctrl+C to stop)");
                stop.Wait();
                log.Info("stopping");
            }
            return 0;
        }
    }
}
