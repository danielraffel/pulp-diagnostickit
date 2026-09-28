import Foundation

/// One conclusion drawn from the collected facts. The report opens with these
/// so a reader sees the likely cause before the raw evidence.
struct Finding {
    enum Severity: Int, Comparable {
        case problem = 0, warning = 1, note = 2
        static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
        var mark: String {
            switch self {
            case .problem: return "❌"
            case .warning: return "⚠️"
            case .note: return "ℹ️"
            }
        }
    }
    let severity: Severity
    let message: String
}

/// A report section plus the conclusions it supports and any raw files that
/// belong in the archive next to the report.
struct Section {
    var markdown: String
    var findings: [Finding] = []
    var attachments: [String: String] = [:]
    var files: [String: Data] = [:]
}

typealias ProcessResult = (output: String, exitCode: Int32, timedOut: Bool, error: String?)

/// The installed bundles of one product, found at the standard macOS
/// locations for each format.
struct InstalledBundle {
    let format: String
    let path: String
}

/// Everything about an installed bundle that decides whether a host can load
/// it: what it is, what it was built with, and whether this Mac can run it.
struct InstallInspector {
    let config: AppConfig
    let run: (String, [String], Int?) -> ProcessResult
    let fileManager = FileManager.default

    init(config: AppConfig, run: @escaping (String, [String], Int?) -> ProcessResult) {
        self.config = config
        self.run = run
    }

    // MARK: - Where the product is installed

    func installedBundles() -> [InstalledBundle] {
        let home = fileManager.homeDirectoryForCurrentUser.path
        var candidates: [(String, String, Bool)] = []
        let name = config.pluginName
        let formats: [(String, String, String, Bool)] = [
            ("Audio Unit", "Components", "component", config.checkAU),
            ("VST3", "VST3", "vst3", config.checkVST3),
            ("CLAP", "CLAP", "clap", config.checkCLAP),
        ]
        for (label, dir, ext, enabled) in formats {
            candidates.append((label, "/Library/Audio/Plug-Ins/\(dir)/\(name).\(ext)", enabled))
            candidates.append((label, "\(home)/Library/Audio/Plug-Ins/\(dir)/\(name).\(ext)", enabled))
        }
        for path in ["/Applications/\(name).app", "/Applications/\(name)/\(name).app",
                     "\(home)/Applications/\(name).app"] {
            candidates.append(("Standalone App", path, config.checkStandalone))
        }
        return candidates.filter { $0.2 && fileManager.fileExists(atPath: $0.1) }
            .map { InstalledBundle(format: $0.0, path: $0.1) }
    }

    // MARK: - Summary of what is installed

    func placementSection(_ bundles: [InstalledBundle]) -> Section {
        var section = Section(markdown: "# Where \(config.pluginName) Is Installed\n\n")
        let enabled: [(String, Bool)] = [("Audio Unit", config.checkAU), ("VST3", config.checkVST3),
                                         ("CLAP", config.checkCLAP), ("Standalone App", config.checkStandalone)]
        section.markdown += "| Format | Location | Version |\n|---|---|---|\n"
        for (format, on) in enabled where on {
            let found = bundles.filter { $0.format == format }
            if found.isEmpty {
                section.markdown += "| \(format) | ❌ not installed | |\n"
                section.findings.append(Finding(severity: .warning, message: "\(format) is not installed at any standard location."))
                continue
            }
            for bundle in found {
                section.markdown += "| \(format) | `\(bundle.path)` | \(shortVersion(bundle.path)) |\n"
            }
            if found.count > 1 {
                section.findings.append(Finding(severity: .warning, message:
                    "\(format) is installed \(found.count) times (\(found.map { $0.path }.joined(separator: ", "))). A host may load the stale copy; remove all but one."))
            }
        }
        let versions = Set(bundles.map { buildIdentity($0.path) })
        if versions.count > 1 {
            section.findings.append(Finding(severity: .warning, message:
                "The installed formats come from different builds (\(versions.sorted().joined(separator: " vs "))). Reinstall so every format matches."))
        }
        section.markdown += "\n"
        return section
    }

    // MARK: - Build info and runtime libraries

    func buildSection(_ bundles: [InstalledBundle]) -> Section {
        var section = Section(markdown: "# Build Information\n\n")
        if bundles.isEmpty {
            section.markdown += "_Nothing installed to inspect._\n"
            return section
        }
        let hostArch = hostArchitecture()
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        for bundle in bundles {
            section.markdown += "## \(bundle.format): `\(bundle.path)`\n\n"
            let info = Bundle(path: bundle.path)?.infoDictionary ?? [:]
            section.markdown += "- Version: `\(info["CFBundleShortVersionString"] as? String ?? "?")` (build `\(info["CFBundleVersion"] as? String ?? "?")`)\n"
            section.markdown += "- Bundle id: `\(info["CFBundleIdentifier"] as? String ?? "not set")`\n"

            let buildInfoPath = "\(bundle.path)/Contents/Resources/pulp-build-info.json"
            if let json = try? String(contentsOfFile: buildInfoPath, encoding: .utf8) {
                section.markdown += buildInfoSummary(json)
                section.markdown += "- Full build info (`pulp-build-info.json`):\n\n```json\n\(String(json.prefix(6000)))\n```\n"
            } else {
                section.markdown += "- Build info: _no `pulp-build-info.json` in this bundle (built before Pulp stamped one); embedded source revisions below_\n"
                let revisions = embeddedRevisions(bundle.path)
                if !revisions.isEmpty {
                    section.markdown += "  - Source revisions embedded in the executable: \(revisions.map { "`\($0)`" }.joined(separator: ", "))\n"
                }
            }

            // Every Mach-O the host has to load for this bundle: the main
            // executable and every library shipped inside the bundle.
            section.markdown += "\n### Executables and bundled libraries\n\n"
            section.markdown += "| File | Archs | Min macOS | Signature | SHA-256 |\n|---|---|---|---|---|\n"
            for binary in machOFiles(in: bundle.path) {
                let name = (binary as NSString).lastPathComponent
                let archs = run("/usr/bin/lipo", ["-archs", binary], nil).output
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let minOS = minimumOS(binary)
                let signed = run("/usr/bin/codesign", ["--verify", "--strict", binary], nil)
                let hash = run("/usr/bin/shasum", ["-a", "256", binary], nil).output.prefix(16)
                section.markdown += "| `\(name)` | \(archs.isEmpty ? "?" : archs) | \(minOS ?? "?") | \(signed.exitCode == 0 ? "✅" : "❌") | `\(hash)` |\n"

                if !archs.isEmpty && !archs.split(separator: " ").contains(Substring(hostArch)) {
                    section.findings.append(Finding(severity: .problem, message:
                        "\(bundle.format): `\(name)` is built for \(archs) but this Mac is \(hostArch). Hosts running natively cannot load it."))
                }
                if let minOS, isNewer(minOS, than: osVersion) {
                    section.findings.append(Finding(severity: .problem, message:
                        "\(bundle.format): `\(name)` requires macOS \(minOS); this Mac runs \(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)."))
                }
                if signed.exitCode != 0 {
                    section.findings.append(Finding(severity: .problem, message:
                        "\(bundle.format): the signature on `\(name)` does not verify: \(signed.output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))"))
                }
                for missing in unresolvedDependencies(binary) {
                    section.findings.append(Finding(severity: .problem, message:
                        "\(bundle.format): `\(name)` links `\(missing)`, which does not resolve inside the installed bundle. The host will fail to load it."))
                    section.markdown += "  - ❌ unresolved dependency: `\(missing)`\n"
                }
            }
            section.markdown += "\n"
        }
        return section
    }

    // MARK: - Gatekeeper and notarization

    func gatekeeperSection(_ bundles: [InstalledBundle]) -> Section {
        var section = Section(markdown: "# Gatekeeper & Notarization\n\n")
        let status = run("/usr/sbin/spctl", ["--status"], nil).output.trimmingCharacters(in: .whitespacesAndNewlines)
        section.markdown += "- Gatekeeper: `\(status)`\n\n"
        for bundle in bundles {
            let assess = run("/usr/sbin/spctl", ["--assess", "--type", bundle.format == "Standalone App" ? "execute" : "install", "-vv", bundle.path], nil)
            let staple = run("/usr/bin/stapler", ["validate", bundle.path], nil)
            let quarantine = run("/usr/bin/xattr", ["-p", "com.apple.quarantine", bundle.path], nil)
            section.markdown += "## \(bundle.format)\n\n```\nspctl: exit \(assess.exitCode)\n\(assess.output.trimmingCharacters(in: .whitespacesAndNewlines))\n\nstapler: exit \(staple.exitCode)\n\(staple.output.trimmingCharacters(in: .whitespacesAndNewlines))\n```\n"
            if quarantine.exitCode == 0 {
                section.markdown += "- quarantine: `\(quarantine.output.trimmingCharacters(in: .whitespacesAndNewlines))`\n"
                section.findings.append(Finding(severity: .warning, message:
                    "\(bundle.format) carries the quarantine flag, so macOS treats it as downloaded. If it will not load, reinstall with the signed installer rather than copying the bundle."))
            }
            if bundle.format == "Standalone App" && assess.exitCode != 0 {
                section.findings.append(Finding(severity: .problem, message:
                    "Gatekeeper rejects the standalone app: \(assess.output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))"))
            }
            section.markdown += "\n"
        }
        return section
    }

    // MARK: - Installer history

    func installerSection() -> Section {
        var section = Section(markdown: "# Installer History\n\n")
        let needles = [config.pluginName.lowercased(), config.pluginBundleId.lowercased()].filter { !$0.isEmpty }
        let pkgs = run("/usr/sbin/pkgutil", ["--pkgs"], nil).output
            .split(separator: "\n").map(String.init)
            .filter { id in needles.contains { id.lowercased().contains($0) } }
        if pkgs.isEmpty {
            section.markdown += "_No installer receipts for \(config.pluginName). It was not installed by a .pkg on this Mac, or the install did not complete._\n\n"
            section.findings.append(Finding(severity: .note, message:
                "No installer receipts were found for \(config.pluginName)."))
        } else {
            section.markdown += "## Receipts\n\n```\n"
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            for id in pkgs {
                for line in run("/usr/sbin/pkgutil", ["--pkg-info", id], nil).output.split(separator: "\n") {
                    if line.hasPrefix("install-time: "), let epoch = TimeInterval(line.dropFirst(14)) {
                        section.markdown += "install-time: \(formatter.string(from: Date(timeIntervalSince1970: epoch)))\n"
                    } else {
                        section.markdown += "\(line)\n"
                    }
                }
                section.markdown += "\n"
            }
            section.markdown += "```\n\n"
        }

        // install.log is admin-readable; the installer writes the reason for a
        // failed or partial install here and nowhere else. A session is one
        // installer process: it names the package, and its outcome is judged
        // from how it ENDED, not from words like "Error" that appear in the
        // installer's own method names on every run.
        let logPath = "/var/log/install.log"
        if let log = try? String(contentsOfFile: logPath, encoding: .utf8) {
            let sessions = installSessions(in: log, needles: needles)
            section.markdown += "## Install sessions for \(config.pluginName) (install.log)\n\n"
            if sessions.isEmpty {
                section.markdown += "_install.log records no installer run for \(config.pluginName)._\n\n"
            } else {
                section.markdown += "| Started | Outcome | Detail |\n|---|---|---|\n"
                for session in sessions.suffix(10) {
                    section.markdown += "| \(session.started) | \(session.outcome.rawValue) | \(session.detail.prefix(160).replacingOccurrences(of: "|", with: "/")) |\n"
                }
                section.markdown += "\n"
                section.attachments["install_log_\(config.pluginName).txt"] = sessions.suffix(10)
                    .map { $0.lines.joined(separator: "\n") }.joined(separator: "\n\n")
                if let last = sessions.last {
                    switch last.outcome {
                    case .failed:
                        section.findings.append(Finding(severity: .problem, message:
                            "The most recent install of \(config.pluginName) (\(last.started)) failed: \(last.detail.prefix(200))"))
                    case .unfinished:
                        section.findings.append(Finding(severity: .warning, message:
                            "The most recent install of \(config.pluginName) (\(last.started)) did not finish (cancelled or quit)."))
                    case .completed:
                        let failed = sessions.filter { $0.outcome == .failed }.count
                        if failed > 0 {
                            section.findings.append(Finding(severity: .note, message:
                                "The latest install completed; \(failed) earlier attempt(s) failed."))
                        }
                    }
                }
            }
        } else {
            section.markdown += "_Could not read \(logPath) (this account is not an administrator)._\n\n"
        }

        let free = freeDiskSpaceGB()
        section.markdown += "- Free space on the startup disk: \(free.map { String(format: "%.1f GB", $0) } ?? "unknown")\n"
        if let free, free < 2 {
            section.findings.append(Finding(severity: .warning, message: String(format: "Only %.1f GB free on the startup disk; installs can fail.", free)))
        }
        return section
    }

    // MARK: - Audio Unit registration

    func auRegistrationSection(componentInstalled: Bool) -> Section {
        var section = Section(markdown: "# Audio Unit Registration\n\n")
        guard config.checkAU else {
            section.markdown += "_Skipped (AU checks disabled)._\n"
            return section
        }
        let triple = "\(config.auType) \(config.auSubtype) \(config.auManufacturer)"
        let list = run("/usr/bin/auval", ["-a"], nil).output
        let registered = list.split(separator: "\n").filter { $0.contains(config.auSubtype) && $0.contains(config.auManufacturer) }
        section.markdown += "- Registered with the system (`auval -a`): \(registered.isEmpty ? "❌ no" : "✅ yes")\n"
        for line in registered { section.markdown += "  - `\(line.trimmingCharacters(in: .whitespaces))`\n" }
        if registered.isEmpty && componentInstalled {
            section.findings.append(Finding(severity: .problem, message:
                "The Audio Unit `\(triple)` is not registered with macOS. Log out and back in (or restart) after installing; if that does not help, the component failed to load."))
        }

        let validation = run("/usr/bin/auval", ["-v", config.auType, config.auSubtype, config.auManufacturer], 120)
        let passed = validation.output.contains("AU VALIDATION SUCCEEDED")
        section.markdown += "- `auval -v \(triple)`: \(validation.timedOut ? "⏱ timed out" : (passed ? "✅ passed" : "❌ failed"))\n\n"
        section.markdown += "```\n\(validation.output.suffix(2500))\n```\n"
        section.attachments["auval.txt"] = validation.output
        if !passed && !registered.isEmpty {
            section.findings.append(Finding(severity: .problem, message:
                "`auval` does not pass for `\(triple)`; hosts such as Logic will refuse it. See auval.txt in the archive."))
        }
        return section
    }

    // MARK: - GPU

    func gpuSection() -> Section {
        var section = Section(markdown: "# Graphics\n\n")
        let result = run("/usr/sbin/system_profiler", ["SPDisplaysDataType", "-json"], nil)
        guard let data = result.output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let gpus = json["SPDisplaysDataType"] as? [[String: Any]] else {
            section.markdown += "_Could not read the GPU list._\n"
            return section
        }
        for gpu in gpus {
            let model = gpu["sppci_model"] as? String ?? gpu["_name"] as? String ?? "?"
            let metal = gpu["spdisplays_mtlgpufamilysupport"] as? String ?? gpu["spdisplays_metal"] as? String ?? "unknown"
            let cores = gpu["sppci_cores"] as? String
            section.markdown += "- \(model)\(cores.map { " (\($0) cores)" } ?? "") — Metal: `\(metal)`\n"
        }
        if gpus.isEmpty {
            section.findings.append(Finding(severity: .problem, message: "No GPU is visible to macOS; the plug-in's editor needs Metal."))
        }
        return section
    }

    // MARK: - Crashes involving the product, whoever crashed

    /// A plug-in crash is filed under the HOST's name ("Logic Pro X-...ips"),
    /// so a filename filter misses the crashes that matter most. This reads each
    /// recent report and keeps the ones whose contents mention the product.
    func crashSection() -> (section: Section, paths: [String]) {
        var section = Section(markdown: "# Crashes Involving \(config.pluginName) (last 14 days)\n\n")
        let dirs = ["\(fileManager.homeDirectoryForCurrentUser.path)/Library/Logs/DiagnosticReports",
                    "/Library/Logs/DiagnosticReports"]
        let cutoff = Date().addingTimeInterval(-14 * 24 * 3600)
        let needle = config.pluginName
        var hits: [(path: String, date: Date, process: String)] = []
        var jetsam: [String] = []
        for dir in dirs {
            guard let files = try? fileManager.contentsOfDirectory(atPath: dir) else { continue }
            for file in files where file.hasSuffix(".ips") || file.hasSuffix(".crash") || file.hasSuffix(".hang") {
                let path = "\(dir)/\(file)"
                guard let attrs = try? fileManager.attributesOfItem(atPath: path),
                      let date = attrs[.modificationDate] as? Date, date > cutoff,
                      let handle = FileHandle(forReadingAtPath: path) else { continue }
                let head = handle.readData(ofLength: 2_000_000)
                try? handle.close()
                let text = String(decoding: head, as: UTF8.self)
                guard file.contains(needle) || text.contains(needle) else { continue }
                // A memory-pressure snapshot lists every running process, so a
                // mention there is not a crash of the product.
                if file.hasPrefix("JetsamEvent") {
                    jetsam.append(path)
                    continue
                }
                let process = file.components(separatedBy: "-20").first ?? file
                hits.append((path, date, process))
            }
        }
        hits.sort { $0.date > $1.date }
        if !jetsam.isEmpty {
            section.markdown += "- \(jetsam.count) low-memory event(s) happened while \(needle) was running (macOS ended processes to free memory).\n"
            section.findings.append(Finding(severity: .note, message:
                "\(jetsam.count) low-memory event(s) in the last 14 days while \(needle) was running."))
        }
        if hits.isEmpty {
            section.markdown += "_No crash, hang or spin reports mention \(needle)._\n"
            return (section, [])
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        for hit in hits.prefix(10) {
            section.markdown += "- \(formatter.string(from: hit.date)) — **\(hit.process)** — `\((hit.path as NSString).lastPathComponent)`\n"
        }
        section.findings.append(Finding(severity: .warning, message:
            "\(hits.count) crash/hang report(s) in the last 14 days mention \(needle) (most recent: \(hit0Process(hits)) at \(formatter.string(from: hits[0].date))). They are included in the archive."))
        if let text = try? String(contentsOfFile: hits[0].path, encoding: .utf8) {
            let lines = text.split(separator: "\n").map(String.init)
            let context = lines.filter { $0.contains(needle) || $0.contains("exception") || $0.contains("termination") || $0.contains("\"faultingThread\"") }
            section.markdown += "\n## Most recent report — lines naming \(needle) or the fault\n\n```\n\(context.prefix(60).joined(separator: "\n").prefix(6000))\n```\n"
        }
        return (section, hits.prefix(10).map { $0.path })
    }

    private func hit0Process(_ hits: [(path: String, date: Date, process: String)]) -> String {
        hits.first?.process ?? "?"
    }

    // MARK: - Unified log

    func unifiedLogSection() -> Section {
        var section = Section(markdown: "# System Log (last hour, mentions of \(config.pluginName))\n\n")
        let name = config.pluginName.replacingOccurrences(of: "\"", with: "")
        // The diagnostics app's own name contains the product's, so its own
        // housekeeping would otherwise fill this section.
        let own = ProcessInfo.processInfo.processName.replacingOccurrences(of: "\"", with: "")
        let predicate = "(eventMessage CONTAINS[c] \"\(name)\" OR process CONTAINS[c] \"\(name)\" OR senderImagePath CONTAINS[c] \"\(name)\") AND NOT process == \"\(own)\""
        let result = run("/usr/bin/log", ["show", "--last", "1h", "--style", "compact", "--info", "--predicate", predicate], 90)
        if result.timedOut {
            section.markdown += "_Timed out reading the system log._\n"
            return section
        }
        let lines = result.output.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("Timestamp") }
        section.attachments["system_log_\(config.pluginName).txt"] = lines.suffix(5000).joined(separator: "\n")
        // Compact style tags each entry with its level after the timestamp:
        // "E" error, "F" fault. Debug and info lines that merely contain the
        // word "error" are not errors.
        let notable = lines.filter { line in
            let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            return fields.count > 2 && (fields[2] == "E" || fields[2] == "F")
        }
        section.markdown += "\(lines.count) line(s); \(notable.count) logged as errors or faults. Last 40 of those:\n\n```\n\(notable.suffix(40).joined(separator: "\n").prefix(8000))\n```\n"
        return section
    }

    enum InstallOutcome: String { case completed = "✅ completed", failed = "❌ failed", unfinished = "⚠️ did not finish" }
    struct InstallSession { let started: String; var outcome: InstallOutcome; var detail: String; var lines: [String] }

    /// Installer runs that installed this product, oldest first. The
    /// package-level outcome comes from installd's PackageKit markers logged
    /// while the session ran, and from the installer's own error lines.
    func installSessions(in log: String, needles: [String]) -> [InstallSession] {
        let lines = log.split(separator: "\n").map(String.init)
        let pidPattern = try! NSRegularExpression(pattern: "[Ii]nstaller\\[(\\d+)\\]")
        func pid(_ line: String) -> String? {
            guard let m = pidPattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let r = Range(m.range(at: 1), in: line) else { return nil }
            return String(line[r])
        }
        var order: [String] = []
        for line in lines where needles.contains(where: { line.lowercased().contains($0) }) {
            if let p = pid(line), !order.contains(p) { order.append(p) }
        }
        let failure = try! NSRegularExpression(pattern:
            "install(ation)? failed|encountered an error|PKInstallErrorDomain|not enough (disk )?space|Install Failed|could not be installed", options: [.caseInsensitive])
        var sessions: [InstallSession] = []
        for p in order {
            let own = lines.filter { pid($0) == p }
            guard let first = own.first, let last = own.last else { continue }
            let start = String(first.prefix(19)), end = String(last.prefix(19))
            let packageKit = lines.filter { line in
                line.contains("installd[") && line.contains("PackageKit: -----")
                    && String(line.prefix(19)) >= start && String(line.prefix(19)) <= end
            }
            let body = own + packageKit
            let failed = body.first { failure.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
            let outcome: InstallOutcome
            var detail = ""
            if let failed {
                outcome = .failed; detail = String(failed.dropFirst(19))
            } else if packageKit.contains(where: { $0.contains("Cancelled install") }) {
                outcome = .unfinished; detail = "PackageKit cancelled the install"
            } else if own.contains(where: { $0.contains("**** Summary Information ****") }) {
                outcome = .completed
                detail = own.first { $0.contains("-total-") }
                    .flatMap { $0.components(separatedBy: "-total-").last }
                    .map { "took " + $0.trimmingCharacters(in: .whitespaces) } ?? ""
            } else {
                outcome = .unfinished; detail = "no completion summary logged"
            }
            // Drop the "-07 host installer[pid]:" prefix the log repeats on every line.
            if let colon = detail.range(of: "]: ") { detail = String(detail[colon.upperBound...]) }
            detail = detail.trimmingCharacters(in: .whitespaces)
            sessions.append(InstallSession(started: start, outcome: outcome, detail: detail, lines: body))
        }
        return sessions
    }

    /// The lines a reader looks for first, from a `pulp.build-info.v1` record.
    private func buildInfoSummary(_ text: String) -> String {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        let product = json["product"] as? [String: Any] ?? [:]
        let build = json["build"] as? [String: Any] ?? [:]
        let pins = json["runtime_pins"] as? [String: Any] ?? [:]
        let sdk = (pins["pulp"] as? [String: Any]) ?? (json["pulp_sdk"] as? [String: Any]) ?? [:]
        let skia = pins["skia"] as? [String: Any] ?? [:]
        let dawn = pins["dawn"] as? [String: Any] ?? [:]
        let webgpu = pins["webgpu"] as? [String: Any] ?? [:]
        func s(_ v: Any?) -> String { v.map { "\($0)" } ?? "?" }
        var md = ""
        md += "- Product source: `\(s(product["source_git_sha"]))`\((product["source_git_dirty"] as? Bool) == true ? " (dirty)" : "")\n"
        md += "- Build: \(s(build["type"])), archs \(((build["archs"] as? [String]) ?? []).joined(separator: ", "))\n"
        md += "- Pulp SDK: \(s(sdk["sdk_version"] ?? sdk["version"])) (`\(s(sdk["source_git_sha"]))`)\n"
        md += "- Skia: \(s(skia["release"])) (`\(s(skia["commit"]))`)\n"
        md += "- Dawn: `\(s(dawn["commit"]))`\n"
        md += "- WebGPU runtime: \(s(webgpu["backend"])) \(s(webgpu["wgpu_native_version"]))\n"
        return md
    }

    // MARK: - Helpers

    private func shortVersion(_ path: String) -> String {
        let info = Bundle(path: path)?.infoDictionary
        return info?["CFBundleShortVersionString"] as? String ?? "?"
    }

    /// Version plus, when the bundle carries one, the exact source revision --
    /// two formats with the same marketing version can still be different builds.
    private func buildIdentity(_ path: String) -> String {
        let version = shortVersion(path)
        if let data = try? Data(contentsOf: URL(fileURLWithPath: "\(path)/Contents/Resources/pulp-build-info.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let product = json["product"] as? [String: Any]
            if let sha = (product?["source_git_sha"] ?? product?["git_sha"]) as? String, !sha.isEmpty, sha != "unknown" {
                return "\(version)@\(sha.prefix(9))"
            }
        }
        return version
    }

    /// 40-character hex strings in the main executable: the product and SDK
    /// source revisions a Pulp build embeds, for bundles that predate the
    /// build-info file.
    private func embeddedRevisions(_ bundlePath: String) -> [String] {
        guard let exe = executable(bundlePath) else { return [] }
        let out = run("/usr/bin/strings", ["-n", "40", exe], nil).output
        var seen: [String] = []
        for line in out.split(separator: "\n") {
            let s = String(line).trimmingCharacters(in: .whitespaces)
            if s.count == 40, s.allSatisfy({ $0.isHexDigit && !$0.isUppercase }), !seen.contains(s) { seen.append(s) }
            if seen.count >= 4 { break }
        }
        return seen
    }

    private func executable(_ bundlePath: String) -> String? {
        guard let name = Bundle(path: bundlePath)?.infoDictionary?["CFBundleExecutable"] as? String else { return nil }
        let path = "\(bundlePath)/Contents/MacOS/\(name)"
        return fileManager.fileExists(atPath: path) ? path : nil
    }

    private func machOFiles(in bundlePath: String) -> [String] {
        var files: [String] = []
        if let exe = executable(bundlePath) { files.append(exe) }
        for sub in ["Contents/MacOS", "Contents/Frameworks", "Contents/lib"] {
            let dir = "\(bundlePath)/\(sub)"
            guard let items = try? fileManager.contentsOfDirectory(atPath: dir) else { continue }
            for item in items.sorted() where item.hasSuffix(".dylib") || item.hasSuffix(".so") {
                files.append("\(dir)/\(item)")
            }
            for item in items.sorted() where item.hasSuffix(".framework") {
                let fw = "\(dir)/\(item)"
                let name = (item as NSString).deletingPathExtension
                for candidate in ["\(fw)/Versions/A/\(name)", "\(fw)/\(name)"] where fileManager.fileExists(atPath: candidate) {
                    files.append(candidate); break
                }
            }
        }
        return files
    }

    private func minimumOS(_ binary: String) -> String? {
        let out = run("/usr/bin/otool", ["-l", binary], nil).output
        var inBuildVersion = false
        for raw in out.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("cmd LC_BUILD_VERSION") || line.hasPrefix("cmd LC_VERSION_MIN_MACOSX") { inBuildVersion = true; continue }
            if inBuildVersion && (line.hasPrefix("minos ") || line.hasPrefix("version ")) {
                return line.split(separator: " ").last.map(String.init)
            }
        }
        return nil
    }

    /// `@rpath` / `@loader_path` / `@executable_path` dependencies that do not
    /// resolve to a file. This is the "installs fine, never loads" failure.
    private func unresolvedDependencies(_ binary: String) -> [String] {
        let dir = (binary as NSString).deletingLastPathComponent
        let loadCommands = run("/usr/bin/otool", ["-l", binary], nil).output
        var rpaths: [String] = []
        var nextIsPath = false
        for raw in loadCommands.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == "cmd LC_RPATH" { nextIsPath = true; continue }
            if nextIsPath && line.hasPrefix("path ") {
                let value = String(line.dropFirst(5)).components(separatedBy: " (offset").first ?? ""
                rpaths.append(value.replacingOccurrences(of: "@loader_path", with: dir)
                                   .replacingOccurrences(of: "@executable_path", with: dir))
                nextIsPath = false
            }
        }
        var missing: [String] = []
        let deps = run("/usr/bin/otool", ["-L", binary], nil).output.split(separator: "\n").dropFirst()
        for raw in deps {
            let dep = raw.trimmingCharacters(in: .whitespaces).components(separatedBy: " (compatibility").first ?? ""
            if dep.hasPrefix("@rpath/") {
                let tail = String(dep.dropFirst("@rpath/".count))
                if !rpaths.contains(where: { fileManager.fileExists(atPath: "\($0)/\(tail)") }) { missing.append(dep) }
            } else if dep.hasPrefix("@loader_path/") || dep.hasPrefix("@executable_path/") {
                let resolved = dep.replacingOccurrences(of: "@loader_path", with: dir)
                                  .replacingOccurrences(of: "@executable_path", with: dir)
                if !fileManager.fileExists(atPath: resolved) { missing.append(dep) }
            } else if dep.hasPrefix("/") && !dep.hasPrefix("/System/") && !dep.hasPrefix("/usr/lib/") {
                // A dependency on a file outside the OS: present on the build
                // machine, absent on everyone else's.
                if !fileManager.fileExists(atPath: dep) { missing.append(dep) }
            }
        }
        // The binary's own install name is listed first for a dylib; drop it.
        let ownName = (binary as NSString).lastPathComponent
        return missing.filter { !$0.hasSuffix("/\(ownName)") || !(binary.hasSuffix(".dylib")) }
    }

    func hostArchitecture() -> String {
        var size = 0
        sysctlbyname("hw.optional.arm64", nil, &size, nil, 0)
        var value: Int32 = 0
        size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0, value == 1 { return "arm64" }
        return "x86_64"
    }

    private func isNewer(_ version: String, than os: OperatingSystemVersion) -> Bool {
        let parts = version.split(separator: ".").compactMap { Int($0) }
        let need = [parts.first ?? 0, parts.count > 1 ? parts[1] : 0, parts.count > 2 ? parts[2] : 0]
        let have = [os.majorVersion, os.minorVersion, os.patchVersion]
        for i in 0..<3 where need[i] != have[i] { return need[i] > have[i] }
        return false
    }

    private func freeDiskSpaceGB() -> Double? {
        let url = URL(fileURLWithPath: "/")
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let bytes = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return Double(bytes) / 1_000_000_000
    }
}
