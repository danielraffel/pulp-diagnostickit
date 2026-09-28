import SwiftUI

/// Manual entry point so we can intercept `--selftest` before SwiftUI takes
/// over the process. In self-test mode we run the full collect + local-archive
/// pipeline headlessly, print the resulting ZIP path, and exit — no window.
/// This is the deterministic verification path (also usable from CI) for the
/// "creates a ZIP on the Desktop" contract; GUI automation of the SwiftUI
/// button proved unreliable.
@main
enum DiagnosticMain {
    static func main() {
        let args = CommandLine.arguments
        if let at = args.firstIndex(of: "--load-probe"), args.count > at + 2 {
            setvbuf(stdout, nil, _IOLBF, 0)
            exit(LoadProbe.run(kind: args[at + 1], bundlePath: args[at + 2]))
        }
        if CommandLine.arguments.contains("--selftest") {
            runSelfTest()
            // runSelfTest() calls exit(), so we never fall through.
        }
        DiagnosticApp.main()
    }

    private static func runSelfTest() {
        let config = AppConfig.load()
        FileHandle.standardError.write(Data("[selftest] mode=localArchive app=\(config.appName) v\(config.appVersion)\n".utf8))

        let semaphore = DispatchSemaphore(value: 0)
        var exitCode: Int32 = 0

        Task {
            defer { semaphore.signal() }
            let collector = DiagnosticCollector(config: config)
            let data = await collector.collectDiagnostics(userFeedback: "self-test run")
            do {
                let url = try await LocalArchiveWriter(config: config).writeArchive(data)
                let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                let size = (attrs?[.size] as? NSNumber)?.intValue ?? -1
                print("SELFTEST_OK \(url.path) bytes=\(size)")
                // --send also delivers it through the configured intake, so a
                // build's send path can be proved end to end without the UI.
                if CommandLine.arguments.contains("--send") {
                    let anonymize = config.anonymizeUsernames || config.excludeUserPaths
                    let summary = Data(anonymizeDiagnosticText(String(decoding: data.summaryJSON, as: UTF8.self), enabled: anonymize).utf8)
                    let reference = try await SupportSender(endpoint: config.sendEndpoint, key: config.sendKey, timeout: 60)
                        .sendWithRetry(archive: url, product: config.productName, summary: summary, note: "self-test run")
                    print("SELFTEST_SENT reference=\(reference)")
                }
            } catch {
                FileHandle.standardError.write(Data("SELFTEST_FAIL \(error.localizedDescription)\n".utf8))
                exitCode = 1
            }
        }

        semaphore.wait()
        exit(exitCode)
    }
}

struct DiagnosticApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            MainView(config: AppConfig.load())
        }
        .windowResizability(.contentSize)
        .commands {
            // Remove some default menu items
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .undoRedo) {}
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon (optional - makes it feel more like a utility)
        // NSApp.setActivationPolicy(.accessory)
    }
}

struct ErrorView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 60))
                .foregroundColor(.red)

            Text("Configuration Error")
                .font(.headline)

            Text("Could not load .env configuration file.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Text("Please ensure the app was built correctly with a valid .env file.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .frame(width: 400, height: 300)
    }
}
