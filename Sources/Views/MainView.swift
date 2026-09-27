import SwiftUI

struct MainView: View {
    @StateObject private var viewModel: DiagnosticViewModel
    @State private var userFeedback = ""

    init(config: AppConfig) {
        _viewModel = StateObject(wrappedValue: DiagnosticViewModel(config: config))
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

            Text(viewModel.config.outputMode == .github ? "Submit a diagnostic report to help us troubleshoot issues" : "Collect a diagnostic report to share with support")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    private var idleView: some View {
        VStack(spacing: 20) {
            Image(systemName: "stethoscope")
                .font(.system(size: 60))
                .foregroundColor(.accentColor)
                .padding(.bottom, 10)

            if viewModel.config.showPrivacyNotice {
                privacyNotice
            }

            if viewModel.config.allowUserFeedback {
                feedbackSection
            }

            Spacer()

            Button(action: {
                Task {
                    await viewModel.collectAndSubmit(userFeedback: userFeedback)
                }
            }) {
                Label(viewModel.config.outputMode == .github ? "Collect & Submit Diagnostic" : "Collect & Save Diagnostic", systemImage: viewModel.config.outputMode == .github ? "paperplane.fill" : "archivebox.fill")
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

                Text("This diagnostic report will include:")
                    .font(.subheadline)

                VStack(alignment: .leading, spacing: 4) {
                    bulletPoint("System information (macOS version, hardware)")
                    bulletPoint("Plugin installation status")
                    bulletPoint("Recent crash logs (if any)")
                    bulletPoint("Audio Unit validation results")
                }
                .font(.caption)

                Text("No personal data is collected beyond what's needed for support.")
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

    private var collectingView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
                .padding()

            Text("Collecting diagnostic information...")
                .font(.headline)

            Text(viewModel.statusMessage)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
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

                Button("Done") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.bordered)
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

            // The archive itself, draggable: drop it into Mail, Messages or a
            // chat window to share it without going through Finder.
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
                }
                .help("Drag to Mail or Messages to share")

                Text("Optional: drag this to Mail or Messages to share it.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if !viewModel.config.supportEmail.isEmpty {
                Button {
                    emailToSupport(path: path)
                } label: {
                    Label("Email to Support", systemImage: "envelope")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            HStack {
                ShareLink(item: URL(fileURLWithPath: path)) {
                    Label("Share…", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)

                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
                .buttonStyle(.borderedProminent)

                Button("Done") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A new message to the support address with the archive attached, in the
    /// user's mail app. `mailto:` cannot carry an attachment, so this goes
    /// through the system compose-email service; when no mail app can take it,
    /// it falls back to a `mailto:` draft that asks for the file and shows the
    /// file in Finder to drag in.
    private func emailToSupport(path: String) {
        let archive = URL(fileURLWithPath: path)
        let subject = archive.deletingPathExtension().lastPathComponent
        let product = viewModel.config.productName
        let body = "Hi,\n\nHere is my \(product) diagnostics report (attached).\n\n"
        if let service = NSSharingService(named: .composeEmail) {
            service.recipients = [viewModel.config.supportEmail]
            service.subject = subject
            if service.canPerform(withItems: [body, archive]) {
                service.perform(withItems: [body, archive])
                return
            }
        }
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = viewModel.config.supportEmail
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body + "Please attach \(archive.lastPathComponent) from your Desktop.\n")
        ]
        if let url = components.url { NSWorkspace.shared.open(url) }
        NSWorkspace.shared.activateFileViewerSelecting([archive])
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
        case success(String)
        case successLocal(String)
        case error(String)
    }

    @Published var state: State = .idle
    @Published var statusMessage = ""

    let config: AppConfig
    private let collector: DiagnosticCollector
    private let uploader: GitHubUploader
    private let archiver: LocalArchiveWriter

    init(config: AppConfig) {
        self.config = config
        self.collector = DiagnosticCollector(config: config)
        self.uploader = GitHubUploader(config: config)
        self.archiver = LocalArchiveWriter(config: config)
        // Opens directly on the saved-archive screen for an existing ZIP, so
        // that screen can be checked without a full collection run.
        if let archive = ProcessInfo.processInfo.environment["DIAGNOSTICKIT_PREVIEW_ARCHIVE"],
           FileManager.default.fileExists(atPath: archive) {
            state = .successLocal(archive)
        }
    }

    func collectAndSubmit(userFeedback: String) async {
        // Collect phase
        state = .collecting
        statusMessage = "Gathering system information..."

        do {
            let diagnosticData = await collector.collectDiagnostics(userFeedback: userFeedback)

            switch config.outputMode {
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
