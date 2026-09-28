import AppKit

/// Sends the diagnostics archive to support through the email service the
/// user actually uses.
///
/// Only a desktop mail app can attach a file on another app's behalf: Apple
/// Mail through the system compose service, Microsoft Outlook through
/// AppleScript. Webmail compose links (Gmail, Outlook on the web) and plain
/// `mailto:` links can fill in the recipient, subject and body, but no browser
/// lets a page attach a local file -- so for those the archive is shown in
/// Finder, ready to drag into the message, and the caller tells the user so.
struct EmailComposer {
    enum Client: Hashable {
        case defaultApp(name: String)
        case appleMail
        case gmail
        case outlook
    }

    enum Outcome {
        /// The message opened with the archive attached.
        case attached
        /// The message opened; the user still has to drag the archive in.
        case needsManualAttachment(String)
    }

    let to: String
    let subject: String
    let body: String
    let archive: URL

    /// The options to offer, in order. "Default email app" is listed only when
    /// the system default is something other than Apple Mail, and is named
    /// after it, so nothing appears twice.
    static func availableClients() -> [Client] {
        var clients: [Client] = []
        if let handler = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "mailto:support@example.com")!),
           Bundle(url: handler)?.bundleIdentifier != "com.apple.mail" {
            let name = FileManager.default.displayName(atPath: handler.path).replacingOccurrences(of: ".app", with: "")
            clients.append(.defaultApp(name: name))
        }
        clients += [.appleMail, .gmail, .outlook]
        return clients
    }

    static func title(_ client: Client) -> String {
        switch client {
        case .defaultApp(let name): return "Default Email App (\(name))"
        case .appleMail: return "Apple Mail"
        case .gmail: return "Gmail"
        case .outlook: return outlookAppURL() != nil ? "Outlook" : "Outlook (web)"
        }
    }

    func send(with client: Client) -> Outcome {
        switch client {
        case .appleMail:
            if let service = NSSharingService(named: .composeEmail) {
                service.recipients = [to]
                service.subject = subject
                let items: [Any] = [body, archive]
                if service.canPerform(withItems: items) {
                    service.perform(withItems: items)
                    return .attached
                }
            }
            return openMailto()
        case .defaultApp:
            return openMailto()
        case .gmail:
            return openWeb(.gmail, service: "Gmail")
        case .outlook:
            if Self.outlookAppURL() != nil, composeInOutlookApp() { return .attached }
            return openWeb(.outlook, service: "Outlook")
        }
    }

    // MARK: - Paths that cannot attach

    /// The compose link for a client that cannot attach: `mailto:` for the
    /// default app, the provider's web compose page otherwise.
    func composeURL(_ client: Client) -> URL? {
        var components: URLComponents
        let query: [(String, String)]
        switch client {
        case .gmail:
            components = URLComponents(string: "https://mail.google.com/mail/")!
            query = [("view", "cm"), ("fs", "1"), ("to", to), ("su", subject), ("body", body)]
        case .outlook:
            components = URLComponents(string: "https://outlook.office.com/mail/deeplink/compose")!
            query = [("to", to), ("subject", subject), ("body", body)]
        case .defaultApp, .appleMail:
            components = URLComponents()
            components.scheme = "mailto"
            components.path = to
            query = [("subject", subject), ("body", body)]
        }
        components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        // URLComponents escapes "&" and "=" inside values but leaves "+", which
        // web forms (Gmail, Outlook) decode as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }

    private func openMailto() -> Outcome {
        if let url = composeURL(.defaultApp(name: "")) { NSWorkspace.shared.open(url) }
        return revealForDragging("your email app")
    }

    private func openWeb(_ client: Client, service: String) -> Outcome {
        if let url = composeURL(client) { NSWorkspace.shared.open(url) }
        return revealForDragging(service)
    }

    private func revealForDragging(_ service: String) -> Outcome {
        NSWorkspace.shared.activateFileViewerSelecting([archive])
        return .needsManualAttachment(
            "\(service) opened with the message filled in. Drag the report above (or from the Finder window) into it before sending.")
    }

    // MARK: - Microsoft Outlook (desktop)

    static func outlookAppURL() -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.Outlook")
    }

    /// New Outlook message with the archive attached. macOS asks the user once
    /// to let this app control Outlook; a refusal returns false and the web
    /// compose is used instead.
    private func composeInOutlookApp() -> Bool {
        func quoted(_ text: String) -> String {
            "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let script = """
        tell application id "com.microsoft.Outlook"
            set m to make new outgoing message with properties {subject:\(quoted(subject)), plain text content:\(quoted(body))}
            make new to recipient at m with properties {email address:{address:\(quoted(to))}}
            make new attachment at m with properties {file:(POSIX file \(quoted(archive.path)))}
            open m
            activate
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        return error == nil
    }
}
