using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace TalentAcquisition.Common
{
    /// <summary>A file that passed validation: what we store and what we tell the browser.</summary>
    public sealed class ValidatedFile
    {
        public string Extension { get; set; }        // ".pdf" ... (lower case, from the allow-list)
        public string ContentType { get; set; }      // decided by the server from the verified type, never taken from the client
        public string SafeOriginalName { get; set; } // display name only; never used on disk
        public byte[] Data { get; set; }
        public byte[] Sha256 { get; set; }
    }

    /// <summary>
    /// Upload rules: extension allow-list, 10 MB limit, and the file's first bytes must match its extension
    /// (a renamed .exe is refused). Word .docx must be a real Office package. Nothing is executed or rendered.
    /// </summary>
    public static class FileRules
    {
        public const long MaxBytes = 10L * 1024 * 1024;

        private static readonly Dictionary<string, string> Types = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            { ".pdf", "application/pdf" },
            { ".png", "image/png" },
            { ".jpg", "image/jpeg" },
            { ".jpeg", "image/jpeg" },
            { ".doc", "application/msword" },
            { ".docx", "application/vnd.openxmlformats-officedocument.wordprocessingml.document" }
        };

        public static string AllowedList { get { return "PDF, Word (.doc, .docx), PNG or JPEG"; } }

        public static ValidatedFile Validate(string originalName, byte[] data)
        {
            if (data == null || data.Length == 0) throw new ApiException(400, "invalid_file", "The file is empty.");
            if (data.LongLength > MaxBytes) throw new ApiException(413, "too_large", "Files may be at most 10 MB.");
            var name = SafeName(originalName);
            var ext = Path.GetExtension(name).ToLowerInvariant();
            string contentType;
            if (string.IsNullOrEmpty(ext) || !Types.TryGetValue(ext, out contentType))
                throw new ApiException(400, "invalid_file", "Only " + AllowedList + " files can be uploaded.");
            if (!ContentMatches(ext, data))
                throw new ApiException(400, "invalid_file", "The file content does not match its " + ext + " extension.");
            byte[] hash;
            using (var sha = SHA256.Create()) hash = sha.ComputeHash(data);
            return new ValidatedFile { Extension = ext == ".jpeg" ? ".jpg" : ext, ContentType = contentType, SafeOriginalName = name, Data = data, Sha256 = hash };
        }

        /// <summary>Strips any path, control and reserved characters; keeps a readable display name of at most 200 characters.</summary>
        public static string SafeName(string original)
        {
            var n = (original ?? "").Replace('\\', '/');
            n = n.Substring(n.LastIndexOf('/') + 1);
            n = Regex.Replace(n, @"[\x00-\x1F\x7F""<>|:*?]", "").Trim().Trim('.');
            if (n.Length > 200)
            {
                var ext = Path.GetExtension(n);
                n = n.Substring(0, 200 - ext.Length) + ext;
            }
            if (string.IsNullOrWhiteSpace(n)) throw new ApiException(400, "invalid_file", "The file needs a name.");
            return n;
        }

        private static bool StartsWith(byte[] d, params byte[] sig) { return d.Length >= sig.Length && !sig.Where((b, i) => d[i] != b).Any(); }

        private static bool ContentMatches(string ext, byte[] d)
        {
            switch (ext)
            {
                case ".pdf": return StartsWith(d, 0x25, 0x50, 0x44, 0x46, 0x2D);                                  // %PDF-
                case ".png": return StartsWith(d, 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A);
                case ".jpg": case ".jpeg": return StartsWith(d, 0xFF, 0xD8, 0xFF);
                case ".doc": return StartsWith(d, 0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1);                // OLE compound file
                case ".docx": return StartsWith(d, 0x50, 0x4B, 0x03, 0x04) && IsWordPackage(d);                   // ZIP with Word parts
                default: return false;
            }
        }

        private static bool IsWordPackage(byte[] d)
        {
            try
            {
                using (var ms = new MemoryStream(d, false))
                using (var zip = new ZipArchive(ms, ZipArchiveMode.Read))
                {
                    var names = new HashSet<string>(zip.Entries.Select(e => e.FullName), StringComparer.OrdinalIgnoreCase);
                    return names.Contains("[Content_Types].xml") && names.Contains("word/document.xml");   // only the directory is read, nothing is extracted
                }
            }
            catch (InvalidDataException) { return false; }
        }
    }

    /// <summary>
    /// Stores files under a root folder that is NOT served by the web host, as {root}\{first two hex chars}\{32-hex GUID}{ext}.
    /// The stored name is generated here, never derived from user input, and is re-validated before every read.
    /// </summary>
    public sealed class DocumentStore
    {
        private static readonly Regex StoredName = new Regex(@"^[0-9a-f]{32}\.(pdf|png|jpg|doc|docx)$", RegexOptions.CultureInvariant);
        private readonly string _root;

        public DocumentStore(string root)
        {
            if (string.IsNullOrWhiteSpace(root) || !Path.IsPathRooted(root)) throw new ArgumentException("The document store path must be absolute.");
            _root = Path.GetFullPath(root);
            Directory.CreateDirectory(_root);
        }

        public string Root { get { return _root; } }

        /// <summary>Writes the bytes under a new GUID name (never overwrites) and returns that name.</summary>
        public string Save(ValidatedFile file)
        {
            var name = Guid.NewGuid().ToString("N") + file.Extension;
            var path = PathFor(name);
            Directory.CreateDirectory(Path.GetDirectoryName(path));
            using (var fs = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None)) fs.Write(file.Data, 0, file.Data.Length);
            return name;
        }

        /// <summary>Reads a stored file and checks it against the size and SHA-256 recorded at upload (tamper / corruption detection).</summary>
        public byte[] ReadVerified(string storedName, long expectedSize, byte[] expectedSha256)
        {
            var path = PathFor(storedName);
            if (!File.Exists(path)) throw new ApiException(500, "document_missing", "The stored file is missing. The incident has been logged.");
            var data = File.ReadAllBytes(path);
            byte[] hash;
            using (var sha = SHA256.Create()) hash = sha.ComputeHash(data);
            if (data.LongLength != expectedSize || !hash.SequenceEqual(expectedSha256))
                throw new ApiException(500, "document_integrity", "The stored file does not match its recorded fingerprint. The incident has been logged.");
            return data;
        }

        /// <summary>Removes a file written for an upload whose database record could not be created.</summary>
        public void DeleteOrphan(string storedName)
        {
            try { var p = PathFor(storedName); if (File.Exists(p)) File.Delete(p); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }

        public string PathFor(string storedName)
        {
            if (storedName == null || !StoredName.IsMatch(storedName)) throw new ApiException(500, "document_name", "Invalid stored document name.");
            var full = Path.GetFullPath(Path.Combine(_root, storedName.Substring(0, 2), storedName));
            if (!full.StartsWith(_root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)) throw new ApiException(500, "document_name", "Invalid stored document path.");
            return full;
        }

        /// <summary>RFC 6266 / 5987 Content-Disposition value with an ASCII fallback.</summary>
        public static string AsciiFallback(string name)
        {
            var sb = new StringBuilder();
            foreach (var ch in name) sb.Append(ch >= 32 && ch < 127 && ch != '"' && ch != '\\' ? ch : '_');
            return sb.ToString();
        }
    }
}
