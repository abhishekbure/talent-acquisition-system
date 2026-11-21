using System;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Threading.Tasks;
using System.Web.Http;
using TalentAcquisition.Business;
using TalentAcquisition.Common;
using TalentAcquisition.Models;

namespace TalentAcquisition.API.Controllers
{
    /// <summary>
    /// Documents of candidates, contractors (incl. compliance proofs), employees and contracts.
    /// Who may see / add / remove what is decided in the database (doc.fn_CanAccessDocument / doc.fn_CanManageOwner);
    /// the files never leave the store except through Download, after that check and an integrity check.
    /// </summary>
    [RoutePrefix("api/v1/documents")]
    public sealed class DocumentsController : ApiBase
    {
        private readonly DocumentService _s;
        public DocumentsController(DocumentService s) { _s = s; }

        /// <summary>multipart/form-data: ownerType, ownerId, docType (optional), complianceId (optional), primaryResume (optional), and exactly one file.</summary>
        [HttpPost, Route(""), TamsAuthorize(Roles = "Candidate,Contractor,Recruiter,HRManager,Administrator")]
        public async Task<IHttpActionResult> Upload()
        {
            if (Request.Content == null || !Request.Content.IsMimeMultipartContent("form-data"))
                throw new ApiException(415, "unsupported_media_type", "Send the file as multipart/form-data.");
            var parts = await Request.Content.ReadAsMultipartAsync(new MultipartMemoryStreamProvider());
            string ownerType = null, docType = null, fileName = null; int ownerId = 0; int? complianceId = null; bool primary = false; byte[] data = null; int files = 0;
            foreach (var part in parts.Contents)
            {
                var cd = part.Headers.ContentDisposition;
                var name = cd == null || cd.Name == null ? "" : cd.Name.Trim('"');
                if (cd != null && cd.FileName != null)
                {
                    files++; fileName = cd.FileName.Trim('"'); data = await part.ReadAsByteArrayAsync();
                    continue;
                }
                var value = (await part.ReadAsStringAsync()).Trim();
                switch (name)
                {
                    case "ownerType": ownerType = value; break;
                    case "ownerId": int.TryParse(value, out ownerId); break;
                    case "docType": docType = value; break;
                    case "complianceId": int c; if (int.TryParse(value, out c)) complianceId = c; break;
                    case "primaryResume": primary = value == "true" || value == "1"; break;
                }
            }
            if (files != 1) throw new ApiException(400, "validation", "Attach exactly one file.");
            return Created(await _s.UploadAsync(Actor, ownerType, ownerId, docType, complianceId, primary, fileName, data));
        }

        [HttpGet, Route(""), TamsAuthorize(Roles = R.Anyone)]
        public async Task<IHttpActionResult> List(string ownerType, int ownerId) { return Ok(await _s.ListAsync(Actor, ownerType, ownerId)); }

        [HttpGet, Route("{id:int}/download"), TamsAuthorize(Roles = R.Anyone)]
        public async Task<HttpResponseMessage> Download(int id)
        {
            var doc = await _s.DownloadAsync(Actor, id);
            var name = doc.Item1.Str("OriginalFileName");
            var res = new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(doc.Item2) };
            res.Content.Headers.ContentType = new MediaTypeHeaderValue(doc.Item1.Str("ContentType"));
            res.Content.Headers.ContentDisposition = new ContentDispositionHeaderValue("attachment") { FileName = "\"" + DocumentStore.AsciiFallback(name) + "\"", FileNameStar = name };
            res.Headers.Add("Content-Security-Policy", "default-src 'none'; sandbox");   // never rendered as active content even if opened inline
            return res;
        }

        [HttpDelete, Route("{id:int}"), TamsAuthorize(Roles = "Candidate,Contractor,Recruiter,HRManager,Administrator")]
        public async Task<IHttpActionResult> Delete(int id) { await _s.DeleteAsync(Actor, id); return Done(); }
    }

    [RoutePrefix("api/v1/compliance")]
    public sealed class ComplianceController : ApiBase
    {
        private readonly DocumentService _s;
        public ComplianceController(DocumentService s) { _s = s; }

        /// <summary>Recruiter verifies or rejects a contractor's compliance record (Verified needs an attached document; Rejected needs a reason).</summary>
        [HttpPost, Route("{id:int}/decision"), TamsAuthorize(Roles = "Recruiter,Administrator")]
        public async Task<IHttpActionResult> Decide(int id, [FromBody] ComplianceDecisionRequest body)
        {
            if (body == null) throw new ApiException(400, "validation", "A request body is required.");
            await _s.DecideComplianceAsync(Actor, id, body.Status, body.Notes);
            return Done();
        }
    }
}
