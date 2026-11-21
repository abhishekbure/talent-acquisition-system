using System;
using System.Data.SqlClient;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Threading.Tasks;
using Microsoft.VisualStudio.TestTools.UnitTesting;
using Newtonsoft.Json.Linq;

namespace TalentAcquisition.Tests
{
    [TestClass]
    public class DocumentTests
    {
        private static byte[] Pdf(string text) { return Encoding.ASCII.GetBytes("%PDF-1.4\n% " + text + "\n1 0 obj << /Type /Catalog >> endobj\ntrailer << /Root 1 0 R >>\n%%EOF\n"); }
        private static byte[] Png() { return new byte[] { 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52 }; }
        private static byte[] Docx(bool withWordPart)
        {
            using (var ms = new MemoryStream())
            {
                using (var zip = new ZipArchive(ms, ZipArchiveMode.Create, true))
                {
                    using (var w = new StreamWriter(zip.CreateEntry("[Content_Types].xml").Open())) w.Write("<Types/>");
                    if (withWordPart) using (var w = new StreamWriter(zip.CreateEntry("word/document.xml").Open())) w.Write("<w:document/>");
                    else using (var w = new StreamWriter(zip.CreateEntry("payload.bin").Open())) w.Write("x");
                }
                return ms.ToArray();
            }
        }
        private static int CandidateId(string email) { return Db.Scalar<int>("SELECT CandidateId FROM cand.Candidates WHERE EmailNormalized = UPPER(@e)", new SqlParameter("@e", email)); }
        private static int FilesInStore() { return Directory.Exists(TestHost.DocumentStore) ? Directory.GetFiles(TestHost.DocumentStore, "*", SearchOption.AllDirectories).Length : 0; }

        [TestMethod]
        public async Task A_candidate_uploads_a_resume_and_gets_the_identical_file_back_as_a_safe_attachment()
        {
            var rohan = await Api.As("rohan.gupta@candidate.example");
            int me = (int)rohan.User["candidateId"];
            var bytes = Pdf("rohan resume " + Guid.NewGuid());
            var up = Expect.Status(await rohan.Upload("Candidate", me, "../../etc/Rohan CV|final.pdf", bytes, "Resume"), HttpStatusCode.Created);
            int id = (int)up.Json["documentId"];
            Assert.IsTrue((bool)up.Json["isPrimaryResume"] || (int)up.Json["isPrimaryResume"] == 1);

            var row = Db.Scalar<string>("SELECT StoredFileName + '|' + OriginalFileName + '|' + ContentType FROM doc.Documents WHERE DocumentId = @d", new SqlParameter("@d", id)).Split('|');
            StringAssert.Matches(row[0], new System.Text.RegularExpressions.Regex("^[0-9a-f]{32}\\.pdf$"), "stored under a generated GUID name");
            Assert.AreEqual("Rohan CVfinal.pdf", row[1], "path segments and reserved characters stripped from the display name");
            Assert.AreEqual("application/pdf", row[2], "content type decided by the server, not the client");
            Assert.IsTrue(File.Exists(Path.Combine(TestHost.DocumentStore, row[0].Substring(0, 2), row[0])), "file is in the store, outside any served folder");

            var list = (JArray)Expect.Status(await rohan.Get("api/v1/documents?ownerType=Candidate&ownerId=" + me), HttpStatusCode.OK).Json;
            Assert.IsTrue(list.Any(d => (int)d["documentId"] == id && d["storedFileName"] == null), "the list never exposes the stored name");

            var dl = await rohan.Download(id);
            Assert.AreEqual(HttpStatusCode.OK, dl.Item1.StatusCode);
            CollectionAssert.AreEqual(bytes, dl.Item2, "byte-for-byte identical");
            Assert.AreEqual("application/pdf", dl.Item1.Content.Headers.ContentType.MediaType);
            Assert.AreEqual("attachment", dl.Item1.Content.Headers.ContentDisposition.DispositionType);
            Assert.AreEqual("Rohan CVfinal.pdf", dl.Item1.Content.Headers.ContentDisposition.FileNameStar);
            StringAssert.Contains(string.Join(";", dl.Item1.Headers.GetValues("Content-Security-Policy")), "sandbox");
            Assert.AreEqual("nosniff", dl.Item1.Headers.GetValues("X-Content-Type-Options").Single());
        }

        [TestMethod]
        public async Task Dangerous_or_disguised_files_are_refused_and_nothing_is_left_on_disk()
        {
            var rohan = await Api.As("rohan.gupta@candidate.example");
            int me = (int)rohan.User["candidateId"];
            int before = FilesInStore();
            var exe = new byte[] { 0x4D, 0x5A, 0x90, 0x00, 0x03 }.Concat(Enumerable.Repeat((byte)0, 200)).ToArray();   // "MZ" = Windows executable
            Expect.Error(await rohan.Upload("Candidate", me, "cv.pdf", exe), HttpStatusCode.BadRequest, "invalid_file");          // renamed .exe
            Expect.Error(await rohan.Upload("Candidate", me, "tool.exe", exe), HttpStatusCode.BadRequest, "invalid_file");        // not on the allow-list
            Expect.Error(await rohan.Upload("Candidate", me, "page.html", Encoding.ASCII.GetBytes("<script>alert(1)</script>")), HttpStatusCode.BadRequest, "invalid_file");
            Expect.Error(await rohan.Upload("Candidate", me, "cv.docx", Docx(false)), HttpStatusCode.BadRequest, "invalid_file");  // a ZIP that is not a Word document
            Expect.Error(await rohan.Upload("Candidate", me, "photo.png", Pdf("not a png")), HttpStatusCode.BadRequest, "invalid_file");
            Expect.Error(await rohan.Upload("Candidate", me, "empty.pdf", new byte[0]), HttpStatusCode.BadRequest, "invalid_file");
            Assert.AreEqual(before, FilesInStore(), "refused uploads leave no file behind");
            Expect.Status(await rohan.Upload("Candidate", me, "cv.docx", Docx(true), "Resume"), HttpStatusCode.Created, "a real .docx package is accepted");
            Expect.Status(await rohan.Upload("Candidate", me, "certificate.png", Png(), "Certificate"), HttpStatusCode.Created);
        }

        [TestMethod]
        public async Task Oversized_uploads_are_refused_with_413_before_anything_is_stored()
        {
            var rohan = await Api.As("rohan.gupta@candidate.example");
            int before = FilesInStore();
            var big = Pdf("big").Concat(new byte[10 * 1024 * 1024]).ToArray();
            Expect.Error(await rohan.Upload("Candidate", (int)rohan.User["candidateId"], "big.pdf", big), (HttpStatusCode)413, "too_large");
            Assert.AreEqual(before, FilesInStore());
            Expect.Error(await rohan.Send(HttpMethod.Post, "api/v1/documents", null, "{\"ownerType\":\"Candidate\"}"), (HttpStatusCode)415, "unsupported_media_type");
        }

        [TestMethod]
        public async Task Other_people_cannot_see_upload_or_delete_and_a_refused_upload_leaves_no_file()
        {
            var rohan = await Api.As("rohan.gupta@candidate.example");
            var divya = await Api.As("divya.reddy@candidate.example");
            int rohanId = (int)rohan.User["candidateId"];
            int id = (int)Expect.Status(await rohan.Upload("Candidate", rohanId, "private.pdf", Pdf("private"), "Identity"), HttpStatusCode.Created).Json["documentId"];
            Assert.AreEqual(0, ((JArray)Expect.Status(await divya.Get("api/v1/documents?ownerType=Candidate&ownerId=" + rohanId), HttpStatusCode.OK).Json).Count);
            Assert.AreEqual(HttpStatusCode.NotFound, (await divya.Download(id)).Item1.StatusCode);
            Expect.Error(await divya.Delete("api/v1/documents/" + id), HttpStatusCode.NotFound, "not_found");
            int before = FilesInStore();
            Expect.Error(await divya.Upload("Candidate", rohanId, "planted.pdf", Pdf("planted")), HttpStatusCode.NotFound, "not_found");
            Assert.AreEqual(before, FilesInStore(), "the file written before the database refused is removed again");
            var ravi = await Api.As("ravi.kumar@contractor.example");
            Expect.Error(await ravi.Get("api/v1/documents/" + id + "/download"), HttpStatusCode.NotFound, "not_found");
        }

        [TestMethod]
        public async Task A_customer_reads_only_resumes_of_candidates_it_shortlisted()
        {
            var priya = await Api.As("priya.menon@tams.local");
            int rohanId = CandidateId("rohan.gupta@candidate.example"), poojaId = CandidateId("pooja.nambiar@candidate.example");
            int cv = (int)Expect.Status(await priya.Upload("Candidate", rohanId, "Rohan_CV.pdf", Pdf("cv"), "Resume", null, true), HttpStatusCode.Created).Json["documentId"];
            int idDoc = (int)Expect.Status(await priya.Upload("Candidate", rohanId, "Rohan_ID.pdf", Pdf("id"), "Identity"), HttpStatusCode.Created).Json["documentId"];
            int poojaCv = (int)Expect.Status(await priya.Upload("Candidate", poojaId, "Pooja_CV.pdf", Pdf("pooja"), "Resume"), HttpStatusCode.Created).Json["documentId"];
            var arjun = await Api.As("arjun.shah@apexlogistics.example");       // Apex: Rohan at Interview stage, Pooja only Submitted
            var meera = await Api.As("meera.iyer@brightwave.example");
            Assert.AreEqual(HttpStatusCode.OK, (await arjun.Download(cv)).Item1.StatusCode);
            Assert.AreEqual(HttpStatusCode.NotFound, (await arjun.Download(idDoc)).Item1.StatusCode, "identity documents are not shared with customers");
            Assert.AreEqual(HttpStatusCode.NotFound, (await arjun.Download(poojaCv)).Item1.StatusCode, "not shortlisted yet");
            Assert.AreEqual(HttpStatusCode.NotFound, (await meera.Download(cv)).Item1.StatusCode, "another customer");
            var list = (JArray)Expect.Status(await arjun.Get("api/v1/documents?ownerType=Candidate&ownerId=" + rohanId), HttpStatusCode.OK).Json;
            Assert.IsTrue(list.Count > 0 && list.All(d => (string)d["docType"] == "Resume" && !(bool)d["canDelete"]));
            Expect.Error(await arjun.Upload("Candidate", rohanId, "x.pdf", Pdf("x")), HttpStatusCode.Forbidden, "forbidden");
        }

        [TestMethod]
        public async Task A_file_changed_on_disk_is_never_served()
        {
            var rohan = await Api.As("rohan.gupta@candidate.example");
            int id = (int)Expect.Status(await rohan.Upload("Candidate", (int)rohan.User["candidateId"], "tamper.pdf", Pdf("original"), "Other"), HttpStatusCode.Created).Json["documentId"];
            var stored = Db.Scalar<string>("SELECT StoredFileName FROM doc.Documents WHERE DocumentId = @d", new SqlParameter("@d", id));
            File.WriteAllBytes(Path.Combine(TestHost.DocumentStore, stored.Substring(0, 2), stored), Pdf("evil replacement"));
            var dl = await rohan.Download(id);
            Assert.AreEqual(HttpStatusCode.InternalServerError, dl.Item1.StatusCode);
            var body = Encoding.UTF8.GetString(dl.Item2);
            StringAssert.Contains(body, "document_integrity");
            Assert.IsFalse(body.Contains("evil"), "no content of the altered file is returned");
        }

        [TestMethod]
        public async Task Deleted_documents_disappear_but_their_record_is_kept()
        {
            var rohan = await Api.As("rohan.gupta@candidate.example");
            int id = (int)Expect.Status(await rohan.Upload("Candidate", (int)rohan.User["candidateId"], "old.pdf", Pdf("old"), "Other"), HttpStatusCode.Created).Json["documentId"];
            Expect.Status(await rohan.Delete("api/v1/documents/" + id), HttpStatusCode.NoContent);
            Assert.AreEqual(HttpStatusCode.NotFound, (await rohan.Download(id)).Item1.StatusCode);
            Assert.AreEqual(1, Db.Scalar<int>("SELECT CAST(IsDeleted AS INT) FROM doc.Documents WHERE DocumentId = @d", new SqlParameter("@d", id)));
        }

        [TestMethod]
        public async Task Contractor_compliance_proof_then_recruiter_verification()
        {
            var ravi = await Api.As("ravi.kumar@contractor.example");
            var rahul = await Api.As("rahul.desai@tams.local");
            int ctr = (int)ravi.User["contractorId"];
            int comp = Db.Scalar<int>("SELECT TOP 1 ComplianceId FROM staff.ComplianceRecords WHERE ContractorId = @c ORDER BY ComplianceId", new SqlParameter("@c", ctr));
            int doc = (int)Expect.Status(await ravi.Upload("Contractor", ctr, "nda_signed.pdf", Pdf("nda"), null, comp), HttpStatusCode.Created).Json["documentId"];
            var mine = (JArray)Expect.Status(await ravi.Get("api/v1/contractors/compliance"), HttpStatusCode.OK).Json;
            Assert.IsTrue(mine.Any(c => (int)c["complianceId"] == comp && (int)c["documentId"] == doc && (string)c["status"] == "Pending"), "proof linked; back to Pending");
            Expect.Error(await ravi.Post("api/v1/compliance/" + comp + "/decision", new { status = "Verified" }), HttpStatusCode.Forbidden, "forbidden");
            Expect.Error(await rahul.Post("api/v1/compliance/" + comp + "/decision", new { status = "Rejected" }), HttpStatusCode.BadRequest, "validation");
            Expect.Status(await rahul.Post("api/v1/compliance/" + comp + "/decision", new { status = "Verified", notes = "Original seen" }), HttpStatusCode.NoContent);
            Assert.AreEqual("Verified", Db.Scalar<string>("SELECT Status FROM staff.ComplianceRecords WHERE ComplianceId = @c", new SqlParameter("@c", comp)));
            Assert.AreEqual(HttpStatusCode.OK, (await rahul.Download(doc)).Item1.StatusCode);
            var sneha = await Api.As("sneha.pillai@contractor.example");
            Assert.AreEqual(HttpStatusCode.NotFound, (await sneha.Download(doc)).Item1.StatusCode);
        }
    }
}
