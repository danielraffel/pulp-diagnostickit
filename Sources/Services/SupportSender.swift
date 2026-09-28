import Foundation

/// Sends the saved archive to the product's report intake (see
/// server/cloudflare), which emails it to support. The user never opens a mail
/// app; the intake replies with a short reference they can quote.
struct SupportSender {
    enum Failure: LocalizedError {
        case notConfigured
        case rejected(Int, String)
        case unreadableReply

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "Sending is not set up in this build."
            case .rejected(let status, let reason): return reason.isEmpty ? "The server refused the report (\(status))." : reason
            case .unreadableReply: return "The server's reply could not be read."
            }
        }
    }

    let endpoint: String
    let key: String
    let timeout: TimeInterval

    /// The multipart body the intake expects: the archive plus the product
    /// name, findings.json and the user's note as plain fields.
    static func body(boundary: String, product: String, summary: Data, note: String,
                     archiveName: String, archive: Data) -> Data {
        var body = Data()
        func field(_ name: String, _ value: Data, filename: String? = nil, type: String = "text/plain; charset=utf-8") {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            let disposition = filename.map { "form-data; name=\"\(name)\"; filename=\"\($0.replacingOccurrences(of: "\"", with: ""))\"" }
                ?? "form-data; name=\"\(name)\""
            body.append("Content-Disposition: \(disposition)\r\nContent-Type: \(type)\r\n\r\n".data(using: .utf8)!)
            body.append(value)
            body.append("\r\n".data(using: .utf8)!)
        }
        field("product", Data(product.utf8))
        field("summary", summary, type: "application/json")
        field("note", Data(note.utf8))
        field("archive", archive, filename: archiveName, type: "application/zip")
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return body
    }

    /// Sends, retrying once after a short pause when the failure is the kind
    /// that passes (no connection, timeout, a server error, rate limiting).
    func sendWithRetry(archive: URL, product: String, summary: Data, note: String) async throws -> String {
        do {
            return try await send(archive: archive, product: product, summary: summary, note: note)
        } catch where Self.isTransient(error) {
            try await Task.sleep(nanoseconds: 3_000_000_000)
            return try await send(archive: archive, product: product, summary: summary, note: note)
        }
    }

    static func isTransient(_ error: Error) -> Bool {
        if let failure = error as? Failure, case .rejected(let status, _) = failure {
            return status == 429 || status >= 500
        }
        if let url = error as? URLError {
            return [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
                    .cannotFindHost, .dnsLookupFailed].contains(url.code)
        }
        return false
    }

    /// What to tell the user, in plain words.
    static func userMessage(for error: Error) -> String {
        if let url = error as? URLError {
            switch url.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return "This Mac doesn't seem to be connected to the internet."
            case .timedOut:
                return "Sending took too long; the connection may be slow."
            case .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost:
                return "The support server couldn't be reached."
            default:
                return "The report couldn't be sent (\(url.localizedDescription))."
            }
        }
        if let failure = error as? Failure {
            switch failure {
            case .notConfigured:
                return "Sending isn't set up in this build."
            case .rejected(let status, let reason):
                switch status {
                case 401: return "This build isn't allowed to send reports any more; ask support for an updated build."
                case 413: return "The report is too large to send."
                case 429: return "Too many reports were sent from this network recently; try again in a minute."
                case 500...: return "The support server had a problem\(reason.isEmpty ? "" : ": \(reason)")."
                default: return failure.errorDescription ?? "The report couldn't be sent."
                }
            case .unreadableReply:
                return "The support server's reply couldn't be read."
            }
        }
        return "The report couldn't be sent (\(error.localizedDescription))."
    }

    /// Returns the intake's reference for the report.
    func send(archive: URL, product: String, summary: Data, note: String) async throws -> String {
        guard let url = URL(string: endpoint), !endpoint.isEmpty, !key.isEmpty else { throw Failure.notConfigured }
        let boundary = "dk-\(UUID().uuidString)"
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let payload = Self.body(boundary: boundary, product: product, summary: summary, note: note,
                                archiveName: archive.lastPathComponent, archive: try Data(contentsOf: archive))
        let (data, response) = try await URLSession.shared.upload(for: request, from: payload)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard status == 200 else { throw Failure.rejected(status, reply?["error"] as? String ?? "") }
        guard let reference = reply?["reference"] as? String else { throw Failure.unreadableReply }
        return reference
    }
}
