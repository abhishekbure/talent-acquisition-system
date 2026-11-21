using System.Linq;
using System.Net;
using System.Threading.Tasks;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace TalentAcquisition.Tests
{
    /// <summary>Phase 11: an administrator sees scheduled-job runs and what each run did. (The jobs themselves are proved
    /// by real SQL Server Agent runs in scripts/testing/Test-AgentJobs.ps1 and by database/12_Tests/08_Job_Tests.sql.)</summary>
    [TestClass]
    public class JobTests
    {
        [TestMethod]
        public async Task Administrators_see_job_runs_with_their_details_and_nobody_else_does()
        {
            // a real run of a job procedure in the disposable copy (as SQL Server Agent would run it)
            Db.Exec("EXEC sched.usp_Job_DailyRecruitmentSummary");
            int defId = Db.Scalar<int>("SELECT JobDefinitionId FROM sched.JobDefinitions WHERE JobName = N'TAMS - Prepare daily recruitment summary'");

            var admin = await Api.As("admin@tams.local");
            var jobs = Expect.Status(await admin.Get("api/v1/admin/jobs"), HttpStatusCode.OK);
            Assert.AreEqual(9, jobs.Json.Count(j => (string)j["owner"] == "SqlAgent"), "the 9 SQL Server Agent jobs are listed");
            var summary = jobs.Json.Single(j => (int)j["jobDefinitionId"] == defId);
            Assert.AreEqual("Succeeded", (string)summary["lastOutcome"]);

            var history = Expect.Status(await admin.Get("api/v1/admin/jobs/" + defId + "/history"), HttpStatusCode.OK);
            long run = (long)history.Json[0]["executionId"];
            var details = Expect.Status(await admin.Get("api/v1/admin/jobs/runs/" + run + "/details"), HttpStatusCode.OK);
            StringAssert.StartsWith((string)details.Json[0]["message"], "Summary for ");

            Expect.Error(await admin.Get("api/v1/admin/jobs/runs/999999999/details"), HttpStatusCode.NotFound, "not_found");
            var rahul = await Api.As("rahul.desai@tams.local");
            Expect.Status(await rahul.Get("api/v1/admin/jobs/runs/" + run + "/details"), HttpStatusCode.Forbidden);
        }
    }
}
