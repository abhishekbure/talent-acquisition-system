using System;
using System.Net;
using System.Net.Http;
using System.Security.Claims;
using System.Web.Http;

namespace TalentAcquisition.API.Controllers
{
    public static class R
    {
        public const string Candidate = "Candidate", Contractor = "Contractor", Customer = "Customer", Recruiter = "Recruiter", HR = "HRManager", Admin = "Administrator";
        public const string Staff = "Recruiter,HRManager,Administrator";
        public const string Anyone = "Candidate,Contractor,Customer,Recruiter,HRManager,Administrator";
    }

    /// <summary>The caller's identity ALWAYS comes from the validated token, never from the request body or URL.</summary>
    public abstract class ApiBase : ApiController
    {
        protected int Actor { get { return int.Parse(((ClaimsPrincipal)User).FindFirst(ClaimTypes.NameIdentifier).Value); } }
        protected Guid Jti { get { return Guid.Parse(((ClaimsPrincipal)User).FindFirst("jti").Value); } }
        protected string ClientIp { get { try { return Request.GetOwinContext().Request.RemoteIpAddress; } catch { return null; } } }
        protected string UserAgent { get { return Request.Headers.UserAgent == null ? null : Request.Headers.UserAgent.ToString(); } }
        protected IHttpActionResult Created(object body) { return Content(HttpStatusCode.Created, body); }
        protected IHttpActionResult Done() { return StatusCode(HttpStatusCode.NoContent); }
    }
}
