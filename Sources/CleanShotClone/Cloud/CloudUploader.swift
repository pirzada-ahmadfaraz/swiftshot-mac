import Foundation
import UniformTypeIdentifiers

/// Anything that can take a local file and return a shareable link.
///
/// There is no real backend here — this is an honest abstraction. The shipping
/// implementation is `LocalLinkProvider` (copies into a synced/public folder and
/// hands back a `file://` or mapped http(s) URL); `HTTPEndpointProvider` is a
/// pluggable multipart uploader for anyone who runs their own endpoint.
protocol CloudUploader {
    /// Upload (or copy) `fileURL` and return a link that points at the result.
    func upload(fileURL: URL) async throws -> URL
}

/// Failures surfaced by the cloud providers. `CloudService` catches every one of
/// these and turns it into an NSAlert/toast — uploads must never crash the app.
enum CloudError: Error, LocalizedError {
    /// No provider is configured (e.g. HTTP selected but no endpoint URL).
    case notConfigured
    /// The local destination folder could not be created or written to.
    case folderUnavailable
    /// The endpoint string in preferences is not a valid URL.
    case invalidEndpoint
    /// Server replied with a non-2xx status code.
    case httpStatus(Int)
    /// Response body was not the JSON we expected, or the URL key was missing.
    case badResponse
    /// The configured JSON key was present but did not hold a usable URL string.
    case missingLink(key: String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Cloud sharing isn't configured yet."
        case .folderUnavailable:
            return "The shared folder couldn't be created or written to."
        case .invalidEndpoint:
            return "The upload endpoint isn't a valid URL."
        case .httpStatus(let code):
            return "The server responded with HTTP status \(code)."
        case .badResponse:
            return "The server's response couldn't be read."
        case .missingLink(let key):
            return "The server response didn't contain a \"\(key)\" link."
        }
    }
}

// MARK: - Local folder provider

/// Copies the file into a user-configured "public" / synced folder (Dropbox,
/// iCloud Drive, a web-root, …) and returns a link to it. When the user has set a
/// `publicBaseURL` that maps that folder to the web, we hand back an http(s) URL;
/// otherwise we return the plain `file://` URL of the copied file.
struct LocalLinkProvider: CloudUploader {
    /// Destination folder the file is copied into. Created on demand.
    let folderURL: URL
    /// Optional public base (e.g. "https://files.example.com/shots"). Empty = none.
    let publicBaseURL: String

    func upload(fileURL: URL) async throws -> URL {
        let fm = FileManager.default

        // Ensure the destination folder exists.
        do {
            try fm.createDirectory(at: folderURL, withIntermediateDirectories: true)
        } catch {
            Log.error("Cloud: could not create folder \(folderURL.path): \(error)", log: Log.general)
            throw CloudError.folderUnavailable
        }

        // Pick a non-colliding name inside the folder, then copy.
        let destFilename = Self.uniqueFilename(for: fileURL.lastPathComponent, in: folderURL)
        let dest = folderURL.appendingPathComponent(destFilename)
        do {
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.copyItem(at: fileURL, to: dest)
        } catch {
            Log.error("Cloud: could not copy into \(dest.path): \(error)", log: Log.general)
            throw CloudError.folderUnavailable
        }

        return Self.makeLink(folderFilename: destFilename, publicBaseURL: publicBaseURL, copiedFileURL: dest)
    }

    // MARK: Pure helpers (harness-testable)

    /// Maps a copied file to its shareable link. PURE: no I/O, no globals.
    /// - If `publicBaseURL` is non-empty, returns `<base>/<filename>` with the
    ///   base's trailing slash trimmed and the filename percent-encoded.
    /// - Otherwise returns the `file://` URL of the copied file.
    static func makeLink(folderFilename: String, publicBaseURL: String, copiedFileURL: URL) -> URL {
        let base = publicBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else {
            return copiedFileURL
        }
        let trimmedBase = base.hasSuffix("/") ? String(base.dropLast()) : base
        let encoded = folderFilename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? folderFilename
        // Fall back to the file URL if the user typed something un-parseable.
        return URL(string: "\(trimmedBase)/\(encoded)") ?? copiedFileURL
    }

    /// Returns a filename that does not already exist in `folder`, appending
    /// " 2", " 3", … before the extension when needed.
    private static func uniqueFilename(for proposed: String, in folder: URL) -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: folder.appendingPathComponent(proposed).path) else {
            return proposed
        }
        let ext = (proposed as NSString).pathExtension
        let stem = (proposed as NSString).deletingPathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            if !fm.fileExists(atPath: folder.appendingPathComponent(candidate).path) {
                return candidate
            }
            n += 1
        }
    }
}

// MARK: - HTTP endpoint provider

/// Uploads the file with a `multipart/form-data` POST to a user-supplied endpoint
/// and reads the returned link out of the JSON response. No external dependencies:
/// the multipart body is assembled by hand.
struct HTTPEndpointProvider: CloudUploader {
    let endpoint: URL
    let token: String?
    /// JSON key in the response that holds the shareable link (default "url").
    let responseURLKey: String

    func upload(fileURL: URL) async throws -> URL {
        let fileData: Data
        do {
            fileData = try Data(contentsOf: fileURL)
        } catch {
            Log.error("Cloud: could not read \(fileURL.path): \(error)", log: Log.general)
            throw CloudError.folderUnavailable
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = Self.multipartBody(
            boundary: boundary,
            fieldName: "file",
            filename: fileURL.lastPathComponent,
            mimeType: Self.mimeType(for: fileURL),
            fileData: fileData
        )

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            Log.error("Cloud: upload request failed: \(error)", log: Log.general)
            throw CloudError.badResponse
        }

        guard let http = response as? HTTPURLResponse else {
            throw CloudError.badResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CloudError.httpStatus(http.statusCode)
        }

        // Parse JSON and pull the configured key. Support a top-level string or a
        // (shallowly) nested object, which covers the common API shapes.
        guard let link = Self.extractLink(from: data, key: responseURLKey) else {
            // Distinguish "we couldn't parse anything" from "key missing".
            if (try? JSONSerialization.jsonObject(with: data)) == nil {
                throw CloudError.badResponse
            }
            throw CloudError.missingLink(key: responseURLKey)
        }
        return link
    }

    // MARK: Pure helpers

    /// Builds a single-file multipart/form-data body.
    static func multipartBody(boundary: String, fieldName: String, filename: String, mimeType: String, fileData: Data) -> Data {
        var body = Data()
        func append(_ s: String) { body.append(s.data(using: .utf8)!) }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(fileData)
        append("\r\n--\(boundary)--\r\n")
        return body
    }

    /// Reads `key` from a JSON object (top level, or one level of nesting under
    /// common wrappers like "data"). Returns nil if no usable URL string is found.
    static func extractLink(from data: Data, key: String) -> URL? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let s = obj[key] as? String, let url = URL(string: s) {
            return url
        }
        // One shallow level of nesting (e.g. {"data": {"url": "..."}}).
        for value in obj.values {
            if let nested = value as? [String: Any],
               let s = nested[key] as? String,
               let url = URL(string: s) {
                return url
            }
        }
        return nil
    }

    /// Best-effort Content-Type from the file extension.
    static func mimeType(for url: URL) -> String {
        if let type = UTType(filenameExtension: url.pathExtension),
           let mime = type.preferredMIMEType {
            return mime
        }
        return "application/octet-stream"
    }
}
