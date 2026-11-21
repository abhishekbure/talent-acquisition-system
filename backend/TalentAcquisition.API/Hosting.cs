using System;
using System.Collections.Generic;
using System.Data.SqlClient;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Net.Http.Formatting;
using System.Security.Claims;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Cors;
using System.Web.Http;
using System.Web.Http.Controllers;
using System.Web.Http.Dependencies;
using System.Web.Http.ExceptionHandling;
using System.Web.Http.Filters;
using Microsoft.Owin;
using Microsoft.Owin.Cors;
using Newtonsoft.Json;
using Newtonsoft.Json.Serialization;
using Owin;
using TalentAcquisition.Business;
using TalentAcquisition.Common;
using TalentAcquisition.Data;
using TalentAcquisition.Models;

namespace TalentAcquisition.API
{
    /// <summary>Composition root: every dependency is created once here (singletons; all are stateless or thread-safe).</summary>
    public sealed class CompositionRoot
    {
        private readonly Dictionary<Type, object> _map = new Dictionary<Type, object>();
        public AppSettings Settings { get; private set; }
        public ILog Log { get; private set; }

        public CompositionRoot(AppSettings s, ILog log)
        {
            Settings = s; Log = log;
            var db = new StoredProcedureExecutor(new ConnectionManager(s), log);
            var staffing = new StaffingRepository(db); var admin = new AdminRepository(db);
            Add(s); Add(log); Add(db);
            Add(new AuthService(new AuthRepository(db), new JwtTokenService(s), s, log));
            Add(new UserService(admin)); Add(new AdminService(admin));
            Add(new OrganizationService(new OrgRepository(db))); Add(new CandidateService(new CandidateRepository(db)));
            Add(new RecruitmentService(new RecruitmentRepository(db))); Add(new ApplicationService(new ApplicationRepository(db)));
            Add(new InterviewService(new InterviewRepository(db))); Add(new OfferService(new OfferRepository(db)));
            Add(new HrService(new HrRepository(db))); Add(new StaffingService(staffing)); Add(new ContractService(staffing));
            Add(new TimesheetService(new TimesheetRepository(db))); Add(new BillingService(new BillingRepository(db)));
            Add(new NotificationService(new NotificationRepository(db))); Add(new DashboardService(new DashboardRepository(db)));
            Add(new DocumentService(new DocumentRepository(db), new DocumentStore(s.DocumentStorePath), log));
            Add(new ReportService(new ReportRepository(db), log));
        }
        private void Add(object o) { _map[o.GetType()] = o; foreach (var i in o.GetType().GetInterfaces()) _map[i] = o; }
        public object Get(Type t) { object o; return _map.TryGetValue(t, out o) ? o : null; }
        public T Get<T>() { return (T)Get(typeof(T)); }
    }

    /// <summary>Constructs controllers with their services from the composition root; everything else is left to Web API defaults.</summary>
    public sealed class SimpleResolver : IDependencyResolver
    {
        private readonly CompositionRoot _root;
        public SimpleResolver(CompositionRoot root) { _root = root; }
        public object GetService(Type t)
        {
            if (!typeof(ApiController).IsAssignableFrom(t)) return null;
            var ctor = t.GetConstructors().OrderByDescending(c => c.GetParameters().Length).First();
            return ctor.Invoke(ctor.GetParameters().Select(p => _root.Get(p.ParameterType) ?? throw new InvalidOperationException("No registration for " + p.ParameterType.Name)).ToArray());
        }
        public IEnumerable<object> GetServices(Type t) { return Enumerable.Empty<object>(); }
        public IDependencyScope BeginScope() { return this; }
        public void Dispose() { }
    }

    public sealed class Startup
    {
        private readonly CompositionRoot _root;
        public Startup(CompositionRoot root) { _root = root; }

        public void Configuration(IAppBuilder app)
        {
            var s = _root.Settings;
            var policy = new CorsPolicy { AllowAnyHeader = true, AllowAnyMethod = true, SupportsCredentials = false, PreflightMaxAge = 600 };
            foreach (var o in s.CorsOrigins) policy.Origins.Add(o.TrimEnd('/'));
            policy.ExposedHeaders.Add("X-Correlation-Id");
            policy.ExposedHeaders.Add("X-Result-Limit"); policy.ExposedHeaders.Add("X-Result-Truncated");   // Phase 13: capped lists
            app.UseCors(new CorsOptions { PolicyProvider = new CorsPolicyProvider { PolicyResolver = ctx => Task.FromResult(policy) } });
            // Phase 15: the production Angular build on the API's own address (everything outside /api/)
            if (!string.IsNullOrWhiteSpace(s.WebRoot))
            {
                if (System.IO.File.Exists(System.IO.Path.Combine(s.WebRoot, "index.html"))) { app.Use(typeof(WebAppMiddleware), s.WebRoot, _root.Log); _root.Log.Info("serving the web application from " + s.WebRoot); }
                else _root.Log.Warn("WebRoot " + s.WebRoot + " has no index.html (build the frontend: npx ng build); serving the API only");
            }
            app.Use(typeof(TokenAuthMiddleware), _root.Get<AuthService>(), _root.Log);

            var config = new HttpConfiguration();
            config.MapHttpAttributeRoutes();
            config.DependencyResolver = new SimpleResolver(_root);
            config.Formatters.Remove(config.Formatters.XmlFormatter);
            var json = config.Formatters.JsonFormatter.SerializerSettings;
            json.ContractResolver = new DefaultContractResolver { NamingStrategy = new CamelCaseNamingStrategy { ProcessDictionaryKeys = true } };
            json.DateTimeZoneHandling = DateTimeZoneHandling.Utc;
            json.DateFormatHandling = DateFormatHandling.IsoDateFormat;
            json.MaxDepth = 32;
            config.Filters.Add(new TamsAuthorizeAttribute());                  // deny by default; [AllowAnonymous] opts out
            config.Filters.Add(new ValidateModelFilter());
            config.Filters.Add(new ApiExceptionFilter(_root.Log));
            config.Services.Replace(typeof(IExceptionHandler), new LastChanceExceptionHandler(_root.Log));
            config.MessageHandlers.Add(new RequestPipelineHandler(_root.Log, s, new RateLimiter()));
            config.IncludeErrorDetailPolicy = IncludeErrorDetailPolicy.Never;
            config.EnsureInitialized();
            app.UseWebApi(config);
            // Phase 13: a request that matches no route is passed on by Web API's OWIN adapter ("soft 404"), so it never reaches the
            // pipeline handler. Answer it here with the same JSON error and security headers as everything else.
            app.Run(ctx =>
            {
                var cid = Guid.NewGuid().ToString("N");
                ctx.Response.StatusCode = 404;
                ctx.Response.ContentType = "application/json; charset=utf-8";
                ctx.Response.Headers.Set("X-Correlation-Id", cid);
                ctx.Response.Headers.Set("X-Content-Type-Options", "nosniff");
                ctx.Response.Headers.Set("X-Frame-Options", "DENY");
                ctx.Response.Headers.Set("Referrer-Policy", "no-referrer");
                ctx.Response.Headers.Set("Cache-Control", "no-store");
                _root.Log.Info("http " + ctx.Request.Method + " " + ctx.Request.Path + " 404 no-route cid=" + cid);
                return ctx.Response.WriteAsync(JsonConvert.SerializeObject(new ApiError { Code = "not_found", Message = "No such address in this API.", CorrelationId = cid }, json));
            });
        }
    }

    /// <summary>
    /// Phase 15: serves the production Angular build (WebRoot) for GET/HEAD outside /api/. A known file is sent with its type;
    /// an address without a file extension is an Angular route and gets index.html (the route guards and, behind them, the API
    /// decide what the person may see). Anything else falls through to the JSON 404. Only files inside WebRoot with a listed
    /// extension are ever sent (no directory listing, no path tricks). Every page carries a Content-Security-Policy:
    /// scripts only from this origin; inline styles are allowed because Angular adds component styles as style elements.
    /// </summary>
    public sealed class WebAppMiddleware : OwinMiddleware
    {
        internal const string Csp = "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data:; connect-src 'self'; object-src 'none'; base-uri 'self'; form-action 'self'; frame-ancestors 'none'";
        private static readonly Dictionary<string, string> Types = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            { ".html", "text/html; charset=utf-8" }, { ".js", "text/javascript; charset=utf-8" }, { ".mjs", "text/javascript; charset=utf-8" },
            { ".css", "text/css; charset=utf-8" }, { ".json", "application/json; charset=utf-8" }, { ".txt", "text/plain; charset=utf-8" },
            { ".ico", "image/x-icon" }, { ".png", "image/png" }, { ".jpg", "image/jpeg" }, { ".svg", "image/svg+xml" }, { ".webp", "image/webp" },
            { ".woff", "font/woff" }, { ".woff2", "font/woff2" }, { ".webmanifest", "application/manifest+json" }
        };
        private static readonly System.Text.RegularExpressions.Regex Hashed = new System.Text.RegularExpressions.Regex(@"-[A-Z0-9]{8}\.(js|css)$");
        private readonly string _root; private readonly ILog _log;
        public WebAppMiddleware(OwinMiddleware next, string root, ILog log) : base(next)
        {
            _root = System.IO.Path.GetFullPath(root).TrimEnd('\\') + "\\"; _log = log;
        }

        public override Task Invoke(IOwinContext ctx)
        {
            var method = ctx.Request.Method; var path = ctx.Request.Path.HasValue ? ctx.Request.Path.Value : "/";
            if ((method != "GET" && method != "HEAD") || path.Equals("/api", StringComparison.OrdinalIgnoreCase) || path.StartsWith("/api/", StringComparison.OrdinalIgnoreCase))
                return Next.Invoke(ctx);
            var file = Resolve(path);
            if (file == null) return Next.Invoke(ctx);
            return Send(ctx, file, method == "HEAD");
        }

        /// <summary>The file to send for a request path, or null (not ours: JSON 404).</summary>
        internal string Resolve(string path)
        {
            if (path.IndexOf('\\') >= 0 || path.IndexOf(':') >= 0 || path.IndexOf('\0') >= 0 || path.Contains("..")) return null;
            var rel = path.TrimStart('/');
            if (rel.Length == 0) return _root + "index.html";
            string full;
            try { full = System.IO.Path.GetFullPath(System.IO.Path.Combine(_root, rel.Replace('/', '\\'))); } catch (Exception) { return null; }
            if (!full.StartsWith(_root, StringComparison.OrdinalIgnoreCase)) return null;
            var ext = System.IO.Path.GetExtension(full);
            if (ext.Length > 0 && Types.ContainsKey(ext)) return System.IO.File.Exists(full) ? full : null;
            var last = rel.Substring(rel.LastIndexOf('/') + 1);
            return last.IndexOf('.') < 0 ? _root + "index.html" : null;        // an Angular route such as /recruiter/jobs
        }

        private async Task Send(IOwinContext ctx, string file, bool headOnly)
        {
            byte[] body;
            try { body = System.IO.File.ReadAllBytes(file); }
            catch (System.IO.IOException ex) { _log.Warn("web app file unreadable: " + file + " " + ex.Message); await Next.Invoke(ctx); return; }
            var res = ctx.Response; var name = System.IO.Path.GetFileName(file);
            res.StatusCode = 200;
            res.ContentType = Types[System.IO.Path.GetExtension(file)];
            res.ContentLength = body.Length;
            res.Headers.Set("Cache-Control", Hashed.IsMatch(name) ? "public, max-age=31536000, immutable" : "no-cache");
            res.Headers.Set("X-Content-Type-Options", "nosniff");
            res.Headers.Set("X-Frame-Options", "DENY");
            res.Headers.Set("Referrer-Policy", "no-referrer");
            res.Headers.Set("Content-Security-Policy", Csp);
            if (!headOnly) await res.WriteAsync(body);
        }
    }

    /// <summary>Validates "Authorization: Bearer" on every request: JWT signature + expiry + the jti in sec.AuthTokens (logout / deactivation take effect immediately).</summary>
    public sealed class TokenAuthMiddleware : OwinMiddleware
    {
        private readonly AuthService _auth; private readonly ILog _log;
        public TokenAuthMiddleware(OwinMiddleware next, AuthService auth, ILog log) : base(next) { _auth = auth; _log = log; }
        public override async Task Invoke(IOwinContext ctx)
        {
            var h = ctx.Request.Headers.Get("Authorization");
            if (h != null && h.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase))
            {
                TokenInfo info = null;
                try { info = await _auth.ValidateAsync(h.Substring(7).Trim()); } catch (Exception ex) { _log.Error("token validation failed", ex); }
                if (info != null)
                {
                    var id = new ClaimsIdentity("Bearer", ClaimTypes.Name, ClaimTypes.Role);
                    id.AddClaim(new Claim(ClaimTypes.NameIdentifier, info.UserId.ToString()));
                    id.AddClaim(new Claim(ClaimTypes.Name, info.Name ?? ""));
                    id.AddClaim(new Claim("jti", info.Jti.ToString()));
                    foreach (var r in info.Roles) id.AddClaim(new Claim(ClaimTypes.Role, r));
                    ctx.Request.User = new ClaimsPrincipal(id);
                }
            }
            await Next.Invoke(ctx);
        }
    }

    /// <summary>401 when not logged in, 403 when logged in without the role. Same JSON error shape as every other error.</summary>
    public sealed class TamsAuthorizeAttribute : AuthorizeAttribute
    {
        protected override void HandleUnauthorizedRequest(HttpActionContext ctx)
        {
            var p = ctx.RequestContext.Principal;
            bool authenticated = p != null && p.Identity != null && p.Identity.IsAuthenticated;
            ctx.Response = ctx.Request.CreateResponse(authenticated ? HttpStatusCode.Forbidden : HttpStatusCode.Unauthorized,
                new ApiError { Code = authenticated ? "forbidden" : "unauthenticated", Message = authenticated ? "You do not have permission for this operation." : "Authentication is required." });
        }
    }

    public sealed class ValidateModelFilter : ActionFilterAttribute
    {
        public override void OnActionExecuting(HttpActionContext ctx)
        {
            if (ctx.ModelState.IsValid) return;
            var details = ctx.ModelState.Where(m => m.Value.Errors.Count > 0)
                .ToDictionary(m => m.Key, m => m.Value.Errors.Select(e => string.IsNullOrEmpty(e.ErrorMessage) ? "Invalid value." : e.ErrorMessage).ToArray());
            ctx.Response = ctx.Request.CreateResponse(HttpStatusCode.BadRequest, new ApiError { Code = "validation", Message = "The request is not valid.", Details = details });
        }
    }

    /// <summary>Maps ApiException (incl. mapped SQL THROW numbers) to its status; everything else becomes a 500 with a correlation id and NO internal detail.</summary>
    public sealed class ApiExceptionFilter : ExceptionFilterAttribute
    {
        private readonly ILog _log;
        public ApiExceptionFilter(ILog log) { _log = log; }
        public override void OnException(HttpActionExecutedContext ctx) { ctx.Response = ErrorResponses.From(ctx.Request, ctx.Exception, _log); }
    }

    public sealed class LastChanceExceptionHandler : ExceptionHandler
    {
        private readonly ILog _log;
        public LastChanceExceptionHandler(ILog log) { _log = log; }
        public override void Handle(ExceptionHandlerContext ctx) { ctx.Result = new ResponseResult(ErrorResponses.From(ctx.Request, ctx.Exception, _log)); }
        private sealed class ResponseResult : IHttpActionResult
        {
            private readonly HttpResponseMessage _m; public ResponseResult(HttpResponseMessage m) { _m = m; }
            public Task<HttpResponseMessage> ExecuteAsync(CancellationToken c) { return Task.FromResult(_m); }
        }
    }

    internal static class ErrorResponses
    {
        public static HttpResponseMessage From(HttpRequestMessage req, Exception ex, ILog log)
        {
            var cid = req.Properties.ContainsKey("tams.cid") ? (string)req.Properties["tams.cid"] : Guid.NewGuid().ToString("N");
            // Phase 13: Web API signals client errors it detects itself (e.g. 415 for a body type no formatter reads) by throwing
            // HttpResponseException; pass its response on (the pipeline handler gives it the standard error shape) instead of a 500.
            var hre = ex as HttpResponseException;
            if (hre != null && hre.Response != null && (int)hre.Response.StatusCode < 500) return hre.Response;
            var api = ex as ApiException ?? (ex is SqlException ? SqlErrorMapper.Map((SqlException)ex) : null);
            if (api != null && api.Status < 500) return req.CreateResponse((HttpStatusCode)api.Status, new ApiError { Code = api.Code, Message = api.Message, CorrelationId = cid });
            log.Error("unhandled error cid=" + cid + " " + req.Method + " " + req.RequestUri.AbsolutePath, ex);
            if (api != null) return req.CreateResponse((HttpStatusCode)api.Status, new ApiError { Code = api.Code, Message = api.Message, CorrelationId = cid });
            return req.CreateResponse(HttpStatusCode.InternalServerError, new ApiError { Code = "server_error", Message = "An unexpected error occurred. Quote the correlation id when reporting it.", CorrelationId = cid });
        }
    }

    /// <summary>
    /// Phase 13 (KI-022): fixed one-minute windows per (endpoint group, client IP address). In-memory, so it applies per API
    /// process and restarts empty; that is enough for a single local API. A fixed window can let up to twice the limit through
    /// across a minute boundary, which is acceptable for slowing down guessing and e-mail floods.
    /// </summary>
    public sealed class RateLimiter
    {
        private sealed class Window { public long Minute; public int Count; }
        private readonly System.Collections.Concurrent.ConcurrentDictionary<string, Window> _w = new System.Collections.Concurrent.ConcurrentDictionary<string, Window>();
        private readonly Func<DateTime> _now;
        private long _lastSweep;
        public RateLimiter(Func<DateTime> utcNow = null) { _now = utcNow ?? (() => DateTime.UtcNow); }
        public int TrackedClients { get { return _w.Count; } }

        /// <summary>Counts one request. Returns 0 when it is allowed, otherwise the seconds until the client may try again.</summary>
        public int Hit(string group, string client, int limitPerMinute)
        {
            if (limitPerMinute <= 0) return 0;
            long now = _now().Ticks, minute = now / TimeSpan.TicksPerMinute;
            var w = _w.GetOrAdd(group + "|" + (client ?? "unknown"), _ => new Window { Minute = minute });
            int retryAfter = 0;
            lock (w)
            {
                if (w.Minute != minute) { w.Minute = minute; w.Count = 0; }
                w.Count++;
                if (w.Count > limitPerMinute) retryAfter = Math.Max(1, (int)Math.Ceiling(((minute + 1) * TimeSpan.TicksPerMinute - now) / (double)TimeSpan.TicksPerSecond));
            }
            if (Interlocked.Exchange(ref _lastSweep, minute) != minute)          // once a minute: forget clients from earlier windows
                foreach (var kv in _w) { if (kv.Value.Minute < minute) { Window gone; _w.TryRemove(kv.Key, out gone); } }
            return retryAfter;
        }
    }

    /// <summary>Correlation id, rate limits, body-size limit, security headers and one access-log line per request (method, path, status, ms — no bodies, no tokens).</summary>
    public sealed class RequestPipelineHandler : DelegatingHandler
    {
        private readonly ILog _log; private readonly long _maxBytes; private readonly AppSettings _s; private readonly RateLimiter _limiter;
        /// <summary>Uploads may carry one 10 MB file plus the multipart envelope; everything else keeps the small JSON limit.</summary>
        public const long UploadMaxBytes = FileRules.MaxBytes + 64 * 1024;
        public RequestPipelineHandler(ILog log, AppSettings s, RateLimiter limiter) { _log = log; _s = s; _limiter = limiter; _maxBytes = s.MaxRequestBodyKb * 1024L; }
        private static bool IsUpload(HttpRequestMessage req) { return req.Method == HttpMethod.Post && req.RequestUri.AbsolutePath.TrimEnd('/').Equals("/api/v1/documents", StringComparison.OrdinalIgnoreCase); }

        /// <summary>The anonymous account endpoints and their per-minute limit (null = not limited).</summary>
        private Tuple<string, int> RateGroup(HttpRequestMessage req)
        {
            if (req.Method != HttpMethod.Post) return null;
            switch (req.RequestUri.AbsolutePath.TrimEnd('/').ToLowerInvariant())
            {
                case "/api/v1/auth/login": return Tuple.Create("login", _s.RateLimitLoginPerMinute);
                case "/api/v1/auth/register": case "/api/v1/auth/forgot-password": case "/api/v1/auth/resend-verification": return Tuple.Create("account", _s.RateLimitAccountPerMinute);
                case "/api/v1/auth/verify-email": case "/api/v1/auth/reset-password": return Tuple.Create("token", _s.RateLimitTokenPerMinute);
                default: return null;
            }
        }

        /// <summary>The TCP peer's address. X-Forwarded-For is deliberately ignored: the API is not behind a proxy and the header is client-controlled.</summary>
        private static string ClientAddress(HttpRequestMessage req)
        {
            var owin = req.GetOwinContext();
            return owin != null && !string.IsNullOrEmpty(owin.Request.RemoteIpAddress) ? owin.Request.RemoteIpAddress : "unknown";
        }

        /// <summary>A body without Content-Length (chunked) is read up to the limit; more than that gives null (KI-034).</summary>
        private static async Task<HttpContent> ReadCappedAsync(HttpContent content, long limit, CancellationToken ct)
        {
            var src = await content.ReadAsStreamAsync().ConfigureAwait(false);
            var buf = new System.IO.MemoryStream(); var chunk = new byte[16 * 1024]; int n;
            while ((n = await src.ReadAsync(chunk, 0, chunk.Length, ct).ConfigureAwait(false)) > 0)
            {
                if (buf.Length + n > limit) return null;
                buf.Write(chunk, 0, n);
            }
            var copy = new ByteArrayContent(buf.ToArray());
            foreach (var h in content.Headers) if (!h.Key.Equals("Content-Length", StringComparison.OrdinalIgnoreCase)) copy.Headers.TryAddWithoutValidation(h.Key, h.Value);
            return copy;
        }

        /// <summary>Phase 13: Web API's own 404 (no route), 405 (wrong method) and 415 (unsupported body type) answers get the same
        /// JSON error shape as every other error, so clients handle one format and nothing about the framework is described.</summary>
        private static HttpResponseMessage Normalise(HttpRequestMessage req, HttpResponseMessage res, string cid)
        {
            var oc = res.Content as ObjectContent;
            if (oc != null && oc.ObjectType == typeof(ApiError)) return res;
            string code, message;
            switch ((int)res.StatusCode)
            {
                case 404: if (res.Content != null && !(res.Content is ObjectContent)) return res;          // a file or other real content
                          code = "not_found"; message = "No such address in this API."; break;
                case 405: code = "method_not_allowed"; message = "This address does not accept " + req.Method + "."; break;
                case 415: code = "unsupported_media_type"; message = "Send the request body as application/json (uploads as multipart/form-data)."; break;
                default: return res;
            }
            var replaced = req.CreateResponse(res.StatusCode, new ApiError { Code = code, Message = message, CorrelationId = cid });
            foreach (var h in res.Content == null ? Enumerable.Empty<KeyValuePair<string, IEnumerable<string>>>() : res.Content.Headers.Where(h => h.Key.Equals("Allow", StringComparison.OrdinalIgnoreCase)))
                replaced.Content.Headers.TryAddWithoutValidation(h.Key, h.Value);
            res.Dispose();
            return replaced;
        }

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage req, CancellationToken ct)
        {
            var cid = Guid.NewGuid().ToString("N"); req.Properties["tams.cid"] = cid;
            var sw = System.Diagnostics.Stopwatch.StartNew();
            HttpResponseMessage res = null;
            var limit = IsUpload(req) ? UploadMaxBytes : _maxBytes;
            var group = RateGroup(req);
            int retryAfter = group == null ? 0 : _limiter.Hit(group.Item1, ClientAddress(req), group.Item2);
            if (retryAfter > 0)
            {
                _log.Warn("rate limit " + group.Item1 + " client=" + ClientAddress(req) + " cid=" + cid);
                res = req.CreateResponse((HttpStatusCode)429, new ApiError { Code = "rate_limited", Message = "Too many requests. Try again in " + retryAfter + " seconds.", CorrelationId = cid });
                res.Headers.RetryAfter = new System.Net.Http.Headers.RetryConditionHeaderValue(TimeSpan.FromSeconds(retryAfter));
            }
            else if (IsUpload(req) && (req.Content == null || !req.Content.Headers.ContentLength.HasValue))
                res = req.CreateResponse((HttpStatusCode)411, new ApiError { Code = "length_required", Message = "Uploads must state their length.", CorrelationId = cid });
            else if (req.Content != null && req.Content.Headers.ContentLength.HasValue && req.Content.Headers.ContentLength.Value > limit)
                res = req.CreateResponse((HttpStatusCode)413, new ApiError { Code = "too_large", Message = IsUpload(req) ? "Files may be at most 10 MB." : "The request body is too large.", CorrelationId = cid });
            else if (req.Content != null && !req.Content.Headers.ContentLength.HasValue)
            {
                var capped = await ReadCappedAsync(req.Content, limit, ct).ConfigureAwait(false);
                if (capped == null) res = req.CreateResponse((HttpStatusCode)413, new ApiError { Code = "too_large", Message = "The request body is too large.", CorrelationId = cid });
                else req.Content = capped;
            }
            if (res == null) res = await base.SendAsync(req, ct);
            res = Normalise(req, res, cid);
            var list = res.Content is ObjectContent ? ((ObjectContent)res.Content).Value as CappedList : null;
            if (list != null) { res.Headers.Add("X-Result-Limit", list.Limit.ToString()); res.Headers.Add("X-Result-Truncated", list.Truncated ? "true" : "false"); }
            res.Headers.Add("X-Correlation-Id", cid);
            res.Headers.Add("X-Content-Type-Options", "nosniff");
            res.Headers.Add("X-Frame-Options", "DENY");
            res.Headers.Add("Referrer-Policy", "no-referrer");
            res.Headers.CacheControl = new System.Net.Http.Headers.CacheControlHeaderValue { NoStore = true };
            _log.Info("http " + req.Method + " " + req.RequestUri.AbsolutePath + " " + (int)res.StatusCode + " " + sw.ElapsedMilliseconds + "ms cid=" + cid);
            return res;
        }
    }
}
