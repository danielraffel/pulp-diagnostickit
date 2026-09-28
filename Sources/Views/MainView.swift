import SwiftUI

struct MainView: View {
    @StateObject private var viewModel: DiagnosticViewModel
    @State private var userFeedback = ""
    @State private var autoSend: Bool
    @State private var showingTerms = false

    init(config: AppConfig) {
        _viewModel = StateObject(wrappedValue: DiagnosticViewModel(config: config))
        _autoSend = State(initialValue: config.autoSendDefault)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView

            Divider()

            // Content based on state
            Group {
                switch viewModel.state {
                case .idle:
                    idleView
                case .collecting:
                    collectingView
                case .submitting:
                    submittingView
                case .archiving:
                    archivingView
                case .sending:
                    sendingView
                case .readyToSend(let path):
                    readyToSendView(path: path)
                case .sent(let reference, let path):
                    sentView(reference: reference, path: path)
                case .sendFailed(let message, let path):
                    sendFailedView(message: message, path: path)
                case .success(let url):
                    successView(url: url)
                case .successLocal(let path):
                    localSuccessView(path: path)
                case .error(let message):
                    errorView(message: message)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: CGFloat(viewModel.config.windowWidth),
               height: CGFloat(viewModel.config.windowHeight))
    }

    private var headerView: some View {
        VStack(spacing: 8) {
            Text(viewModel.config.appName)
                .font(.title2)
                .fontWeight(.semibold)

            Text(viewModel.config.outputMode == .localArchive ? "Collect a diagnostic report to share with support" : "Send a diagnostic report to help us troubleshoot issues")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    private var idleView: some View {
        VStack(spacing: 20) {
            Image(systemName: "stethoscope")
                .font(.system(size: 40))
                .foregroundColor(.accentColor)

            if viewModel.config.showPrivacyNotice {
                privacyNotice
            }

            if viewModel.config.allowUserFeedback {
                feedbackSection
            }

            Spacer()

            if viewModel.config.outputMode != .localArchive {
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Send automatically when ready", isOn: $autoSend)
                    Text("Uncheck to review the report before anything is sent.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.leading, 20)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if viewModel.config.outputMode == .send && autoSend {
                consentLine(buttonTitle: "Send Report")
            }

            Button(action: {
                viewModel.start(userFeedback: userFeedback, autoSend: autoSend)
            }) {
                Label(idleButtonTitle, systemImage: viewModel.config.outputMode == .localArchive ? "archivebox.fill" : "paperplane.fill")
                    .frame(maxWidth: .infinity)
                    .padding()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding()
    }

    private var privacyNotice: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label("Privacy Notice", systemImage: "lock.shield")
                    .font(.headline)

                Text("This diagnostic report includes information such as:")
                    .font(.subheadline)

                VStack(alignment: .leading, spacing: 4) {
                    bulletPoint("Your Mac's model, macOS version, graphics and audio devices")
                    bulletPoint("Where \(viewModel.config.productName) is installed and whether it loads")
                    bulletPoint("Which music apps are installed and their plug-in settings")
                    bulletPoint("Recent crash reports and log lines that mention \(viewModel.config.productName)")
                }
                .font(.caption)

                Text("We do our best to remove your name, user folder and computer name, but can't guarantee every instance is caught.")
                    .fixedSize(horizontal: false, vertical: true)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 4)
            }
        }
    }

    private var feedbackSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Describe the issue (optional):")
                .font(.subheadline)
                .fontWeight(.medium)

            TextEditor(text: $userFeedback)
                .frame(height: 80)
                .padding(4)
                .background(Color(NSColor.textBackgroundColor))
                .cornerRadius(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )
        }
    }

    private var idleButtonTitle: String {
        switch viewModel.config.outputMode {
        case .send: return autoSend ? "Send Report" : "Collect Report"
        case .github: return "Collect & Submit Diagnostic"
        case .localArchive: return "Collect & Save Diagnostic"
        }
    }

    /// "By clicking “Send Report”, you agree to the Diagnostic Data Terms." --
    /// names the exact button that sends, on one line.
    private func consentLine(buttonTitle: String) -> some View {
        HStack(spacing: 3) {
            Text("By clicking “\(buttonTitle)”, you agree to the")
                .foregroundColor(.secondary)
            Button("Diagnostic Data Terms") {
                if let url = URL(string: viewModel.config.termsURL), !viewModel.config.termsURL.isEmpty {
                    NSWorkspace.shared.open(url)
                } else {
                    showingTerms = true
                }
            }
            .buttonStyle(.link)
        }
        .font(.caption)
        .fixedSize()
        .frame(maxWidth: .infinity)
        .sheet(isPresented: $showingTerms) { termsSheet }
    }

    /// The terms with their inline Markdown (bold headings) rendered and
    /// line breaks kept as written.
    private var termsAttributed: AttributedString {
        let text = viewModel.config.termsText.isEmpty ? "Terms are not available in this build." : viewModel.config.termsText
        return (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    private var termsSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            // The support address inside the terms is a link, and the sheet
            // scrolls to its first link on open; start at the top instead.
            ScrollViewReader { proxy in
                ScrollView {
                    Text(termsAttributed)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.trailing, 8)
                        .id("terms-top")
                }
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        proxy.scrollTo("terms-top", anchor: .top)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Close") { showingTerms = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: CGFloat(viewModel.config.windowWidth) - 20,
               height: CGFloat(viewModel.config.windowHeight) - 60)
    }

    private var cancelButton: some View {
        Button("Cancel") { viewModel.cancel() }
            .buttonStyle(.bordered)
    }

    private var sendingView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
                .padding()

            Text("Sending to support...")
                .font(.headline)

            Text(viewModel.statusMessage)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            cancelButton
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sentView(reference: String, path: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundColor(.green)

            Text("Sent to support")
                .font(.headline)

            Text("Thanks! Your report reached support. If you get in touch about it, mention reference \(reference).")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)

            archiveBox(path: path, caption: "A copy is saved on your Desktop.")

            Spacer()

            HStack {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
                .buttonStyle(.bordered)

                Button("Done") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func readyToSendView(path: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 56))
                .foregroundColor(.accentColor)

            Text("Ready to send")
                .font(.headline)

            Text("Nothing has been sent yet. Open the report to see exactly what support will receive.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            archiveBox(path: path, caption: "Saved on your Desktop. Closing this window sends nothing.")

            Spacer()

            consentLine(buttonTitle: "Send Report")

            HStack {
                Button("Open Report") { viewModel.openReport() }
                    .buttonStyle(.bordered)

                Button {
                    viewModel.retrySend(path: path)
                } label: {
                    Label("Send Report", systemImage: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sendFailedView(message: String, path: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 60))
                .foregroundColor(.orange)

            Text("Couldn't send the report")
                .font(.headline)

            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            archiveBox(path: path, caption: viewModel.config.supportEmail.isEmpty
                ? "It's saved on your Desktop. You can send it another way, or try again."
                : "It's saved on your Desktop. You can try again, or email it to \(viewModel.config.supportEmail).")

            Spacer()

            HStack {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
                .buttonStyle(.bordered)

                Button("Try Again") { viewModel.retrySend(path: path) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var collectingView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
                .padding()

            Text("Collecting diagnostic information...")
                .font(.headline)

            Text("This usually takes 2–4 minutes. You can leave this window open and come back.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Text(viewModel.statusMessage)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            cancelButton
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var submittingView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
                .padding()

            Text("Submitting to GitHub...")
                .font(.headline)

            Text("Creating issue in \(viewModel.config.githubRepo)")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var archivingView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
                .padding()

            Text("Saving diagnostic archive...")
                .font(.headline)

            Text("Writing ZIP to your Desktop")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func successView(url: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundColor(.green)

            Text("Report Submitted Successfully!")
                .font(.headline)

            Text("Your diagnostic report has been created.")
                .font(.subheadline)
                .foregroundColor(.secondary)

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Issue URL:")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text(url)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }

            Spacer()

            HStack {
                Button("Open in Browser") {
                    if let issueURL = URL(string: url) {
                        NSWorkspace.shared.open(issueURL)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func localSuccessView(path: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundColor(.green)

            Text("Diagnostic Archive Saved")
                .font(.headline)

            Text("Your diagnostic report ZIP has been created on your Desktop.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            archiveBox(path: path, caption: "Optional: drag this to Mail or Messages to share it.")

            Spacer()

            HStack {
                // Share is off by default: SHOW_SHARE_BUTTON=true in .env adds it.
                if viewModel.config.showShareButton {
                    ShareLink(item: URL(fileURLWithPath: path)) {
                        Label("Share…", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                }

                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The saved archive as a draggable file: drop it into Mail, Messages or
    /// a chat window to share it without going through Finder.
    private func archiveBox(path: String, caption: String) -> some View {
            VStack(spacing: 6) {
                GroupBox {
                    HStack(spacing: 10) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                            .resizable()
                            .frame(width: 32, height: 32)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Archive:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text((path as NSString).lastPathComponent)
                                .font(.system(.caption, design: .monospaced))
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "hand.draw")
                            .foregroundColor(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .onDrag {
                    NSItemProvider(contentsOf: URL(fileURLWithPath: path)) ?? NSItemProvider()
                } preview: {
                    // What Finder shows when a file is dragged: its icon over
                    // its name, on a solid background -- not a see-through
                    // snapshot of this panel.
                    VStack(spacing: 4) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                            .resizable()
                            .frame(width: 48, height: 48)
                        Text((path as NSString).lastPathComponent)
                            .font(.caption)
                            .lineLimit(1)
                            .foregroundColor(.primary)
                    }
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(nsColor: .windowBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
                }
                .help("Drag to Mail or Messages to share")

                Text(caption)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 60))
                .foregroundColor(.orange)

            Text("Submission Failed")
                .font(.headline)

            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            if !viewModel.config.supportEmail.isEmpty {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Alternative: Email Support")
                            .font(.subheadline)
                            .fontWeight(.medium)

                        HStack {
                            Text(viewModel.config.supportEmail)
                                .font(.caption)
                                .textSelection(.enabled)

                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(viewModel.config.supportEmail, forType: .string)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            }

            Spacer()

            HStack {
                Button("Try Again") {
                    viewModel.reset()
                }
                .buttonStyle(.borderedProminent)

                Button("Cancel") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func bulletPoint(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•")
            Text(text)
            Spacer()
        }
    }
}

// MARK: - View Model

@MainActor
class DiagnosticViewModel: ObservableObject {
    enum State {
        case idle
        case collecting
        case submitting
        case archiving
        case sending
        case readyToSend(path: String)
        case sent(reference: String, path: String)
        case sendFailed(message: String, path: String)
        case success(String)
        case successLocal(String)
        case error(String)
    }

    @Published var state: State = .idle
    /// What the user typed in the description box, kept so Email to Support
    /// can put it in the message body.
    @Published var lastFeedback = ""
    @Published var statusMessage = ""

    let config: AppConfig
    private let collector: DiagnosticCollector
    private let uploader: GitHubUploader
    private let archiver: LocalArchiveWriter
    private var work: Task<Void, Never>?
    /// The anonymized findings.json and note of the report being sent, kept
    /// for Try Again.
    private var pendingSummary = Data()
    private var pendingNote = ""
    /// The report text exactly as it is in the archive, for Open Report.
    private var pendingReport = ""

    init(config: AppConfig) {
        self.config = config
        self.collector = DiagnosticCollector(config: config)
        self.uploader = GitHubUploader(config: config)
        self.archiver = LocalArchiveWriter(config: config)
        // Opens directly on the saved-archive screen for an existing ZIP, so
        // that screen can be checked without a full collection run.
        if let archive = ProcessInfo.processInfo.environment["DIAGNOSTICKIT_PREVIEW_ARCHIVE"],
           FileManager.default.fileExists(atPath: archive) {
            switch ProcessInfo.processInfo.environment["DIAGNOSTICKIT_PREVIEW_STATE"] {
            case "sent": state = .sent(reference: "AB12CD34", path: archive)
            case "review": state = .readyToSend(path: archive)
            case "failed": state = .sendFailed(message: SupportSender.userMessage(for: URLError(.notConnectedToInternet)), path: archive)
            default: state = .successLocal(archive)
            }
        }
    }

    func start(userFeedback: String, autoSend: Bool = true) {
        work?.cancel()
        work = Task { await collectAndSubmit(userFeedback: userFeedback, autoSend: autoSend) }
    }

    /// Opens the report (the same text that is in the archive) in the user's
    /// default app for Markdown or plain text.
    func openReport() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(config.productName)-diagnostic-report.md")
        try? pendingReport.write(to: url, atomically: true, encoding: .utf8)
        if !NSWorkspace.shared.open(url) {
            NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                                    configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// Back to the start screen. Collection tools already running finish in
    /// the background and their result is discarded; nothing is sent.
    func cancel() {
        work?.cancel()
        work = nil
        state = .idle
        statusMessage = ""
    }

    func retrySend(path: String) {
        work?.cancel()
        work = Task { await send(archive: URL(fileURLWithPath: path)) }
    }

    private func send(archive: URL) async {
        state = .sending
        statusMessage = "Uploading \(archive.lastPathComponent)"
        let sender = SupportSender(endpoint: config.sendEndpoint, key: config.sendKey, timeout: 60)
        do {
            let reference = try await sender.sendWithRetry(archive: archive, product: config.productName,
                                                           summary: pendingSummary, note: pendingNote)
            guard !Task.isCancelled else { return }
            state = .sent(reference: reference, path: archive.path)
        } catch {
            guard !Task.isCancelled else { return }
            state = .sendFailed(message: SupportSender.userMessage(for: error), path: archive.path)
        }
    }

    func collectAndSubmit(userFeedback: String, autoSend: Bool = true) async {
        // Collect phase
        state = .collecting
        statusMessage = "Gathering system information..."

        do {
            lastFeedback = userFeedback.trimmingCharacters(in: .whitespacesAndNewlines)
            let diagnosticData = await collector.collectDiagnostics(userFeedback: userFeedback)
            guard !Task.isCancelled else { return }

            switch config.outputMode {
            case .send:
                state = .archiving
                statusMessage = "Writing ZIP archive..."
                let archiveURL = try await archiver.writeArchive(diagnosticData)
                guard !Task.isCancelled else { return }
                let anonymize = config.anonymizeUsernames || config.excludeUserPaths
                pendingSummary = Data(anonymizeDiagnosticText(String(decoding: diagnosticData.summaryJSON, as: UTF8.self),
                                                              enabled: anonymize).utf8)
                pendingNote = anonymizeDiagnosticText(lastFeedback, enabled: anonymize)
                pendingReport = anonymizeDiagnosticText(
                    renderDiagnosticReport(diagnosticData, appName: config.appName, appVersion: config.appVersion),
                    enabled: anonymize)
                if autoSend {
                    await send(archive: archiveURL)
                } else {
                    state = .readyToSend(path: archiveURL.path)
                }

            case .github:
                state = .submitting
                statusMessage = "Creating GitHub issue..."
                let issueURL = try await uploader.submitDiagnostic(diagnosticData)
                state = .success(issueURL)

            case .localArchive:
                state = .archiving
                statusMessage = "Writing ZIP archive..."
                let archiveURL = try await archiver.writeArchive(diagnosticData)
                state = .successLocal(archiveURL.path)
            }

        } catch GitHubError.invalidConfiguration {
            state = .error("GitHub configuration is invalid. Please check your .env file.")
        } catch GitHubError.authenticationError {
            state = .error("GitHub authentication failed. Please check your Personal Access Token.")
        } catch GitHubError.rateLimitExceeded {
            state = .error("GitHub rate limit exceeded. Please try again later.")
        } catch {
            state = .error("Failed to create report: \(error.localizedDescription)")
        }
    }

    func reset() {
        state = .idle
        statusMessage = ""
    }
}
