using System;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Threading.Tasks;
using System.Web.Http;
using TalentAcquisition.Business;

namespace TalentAcquisition.API.Controllers
{
    /// <summary>
    /// Phase 10 reports. Which reports a caller may run, and the customer scope of staffing reports, are decided in the
    /// database (report.usp_ListReports / report.usp_RunReport) from the caller's roles; candidates and contractors have none.
    /// </summary>
    [RoutePrefix("api/v1/reports"), TamsAuthorize(Roles = "Customer,Recruiter,HRManager,Administrator")]
    public sealed class ReportsController : ApiBase
    {
        private readonly ReportService _s;
        public ReportsController(ReportService s) { _s = s; }

        /// <summary>The caller's report catalog: code, category, title, description, which filters apply and how to chart it.</summary>
        [HttpGet, Route("")]
        public async Task<IHttpActionResult> List() { return Ok(await _s.ListAsync(Actor)); }

        /// <summary>Runs a report. from/to = inclusive dates (yyyy-MM-dd); customerId = staff only (a customer always gets its own); days = expiring-contracts window.</summary>
        [HttpGet, Route("{code}")]
        public async Task<IHttpActionResult> Run(string code, DateTime? from = null, DateTime? to = null, int? customerId = null, int? days = null)
        { return Ok(await _s.RunAsync(Actor, code, from, to, customerId, days)); }

        /// <summary>The same report as a CSV download.</summary>
        [HttpGet, Route("{code}/csv")]
        public async Task<HttpResponseMessage> Csv(string code, DateTime? from = null, DateTime? to = null, int? customerId = null, int? days = null)
        {
            var r = await _s.RunAsync(Actor, code, from, to, customerId, days, "csv");
            var res = new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(ReportService.ToCsv(r)) };
            res.Content.Headers.ContentType = new MediaTypeHeaderValue("text/csv") { CharSet = "utf-8" };
            var name = "tams-" + code + "-" + r.GeneratedAt.ToString("yyyyMMdd-HHmm") + ".csv";
            res.Content.Headers.ContentDisposition = new ContentDispositionHeaderValue("attachment") { FileName = "\"" + name + "\"" };
            res.Headers.Add("Content-Security-Policy", "default-src 'none'; sandbox");
            res.Headers.CacheControl = new CacheControlHeaderValue { NoStore = true };
            return res;
        }
    }
}
