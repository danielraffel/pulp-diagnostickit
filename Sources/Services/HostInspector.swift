import Foundation
import CoreAudio

/// What the HOSTS on this Mac know about the product, and whether the product
/// actually runs here: the checks behind "it installed, but my DAW does not
/// see it".
extension InstallInspector {

    // MARK: - Logic Pro / GarageBand

    /// Logic keeps its own picture of every Audio Unit, separate from macOS's
    /// registration: a global "Enable Audio Units" switch, a per-component
    /// cache keyed by the component's version, a validation verdict, and scan
    /// logs. Any of them can hide a correctly installed plug-in.
    func logicSection(_ bundles: [InstalledBundle]) -> Section {
        var section = Section(markdown: "# Logic Pro & GarageBand\n\n")
        let apps = [("Logic Pro", "/Applications/Logic Pro.app", "com.apple.logic10"),
                    ("Logic Pro X", "/Applications/Logic Pro X.app", "com.apple.logic10"),
                    ("GarageBand", "/Applications/GarageBand.app", "com.apple.garageband10"),
                    ("MainStage", "/Applications/MainStage.app", "com.apple.mainstage3")]
        let present = apps.filter { fileManager.fileExists(atPath: $0.1) }
        if present.isEmpty {
            section.markdown += "_Neither Logic Pro nor GarageBand is installed._\n"
            return section
        }
        let key = "\(config.auType)-\(config.auSubtype)-\(config.auManufacturer)"
        let auBundle = bundles.first { $0.format == "Audio Unit" }
        let bundleVersion = auBundle.flatMap { componentVersion($0.path) }

        for (name, path, domain) in present {
            let info = Bundle(path: path)?.infoDictionary
            let version = info?["CFBundleShortVersionString"] as? String ?? "?"
            section.markdown += "## \(name) \(version)\n\n"
            if rosettaRequested(bundleId: info?["CFBundleIdentifier"] as? String) {
                section.markdown += "- ❌ Set to **Open using Rosetta**\n"
                section.findings.append(Finding(severity: .problem, message:
                    "\(name) is set to Open using Rosetta, so it runs as Intel and cannot load \(config.pluginName)'s Apple-silicon build. Turn off \"Open using Rosetta\" in \(name)'s Get Info window."))
            } else {
                section.markdown += "- Runs natively (not set to Open using Rosetta)\n"
            }

            let prefsPath = "\(fileManager.homeDirectoryForCurrentUser.path)/Library/Preferences/\(domain).plist"
            guard let data = fileManager.contents(atPath: prefsPath),
                  let prefs = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                section.markdown += "- No preferences yet (never launched on this account)\n\n"
                continue
            }
            if let enabled = prefs["UseAudioUnits"] as? Bool {
                section.markdown += "- Audio Units enabled in Settings › Plug-ins: \(enabled ? "✅ yes" : "❌ no")\n"
                if !enabled {
                    section.findings.append(Finding(severity: .problem, message:
                        "\(name) has Audio Units turned OFF (Settings › Plug-ins › Enable Audio Units), so it will not show any AU."))
                }
            }
            if let entry = prefs[key] as? [String: Any] {
                let cached = entry["componentVersion"] as? Int
                let archs = (entry["AvailableArchitectures"] as? [String])?.joined(separator: ", ") ?? "?"
                section.markdown += "- Has `\(key)` in its component cache (version \(cached.map(String.init) ?? "?"), archs \(archs))\n"
                if let result = entry["ValidationResult"] {
                    section.markdown += "  - Recorded validation result: `\(result)`\n"
                    section.findings.append(Finding(severity: .warning, message:
                        "\(name) holds a recorded validation result (\(result)) for \(config.pluginName). Open \(name) › Settings › Plug-in Manager, select \(config.pluginName), and click Reset & Rescan Selection."))
                }
                if let cached, let bundleVersion, cached != bundleVersion {
                    section.markdown += "  - ⚠️ cached version \(cached) differs from the installed component's \(bundleVersion)\n"
                    section.findings.append(Finding(severity: .warning, message:
                        "\(name) cached \(config.pluginName) at component version \(cached), but version \(bundleVersion) is installed. It may be using stale information; Reset & Rescan in the Plug-in Manager."))
                }
            } else if auBundle != nil {
                section.markdown += "- ⚠️ `\(key)` is NOT in its component cache: \(name) has not scanned this plug-in yet\n"
                section.findings.append(Finding(severity: .warning, message:
                    "\(name) has never scanned \(config.pluginName) (it is not in \(name)'s component cache). Quit and reopen \(name); if it still does not appear, open Settings › Plug-in Manager and Reset & Rescan."))
            }
            section.markdown += "\n"
        }

        section.markdown += logicScanLogs(installedAt: auBundle.flatMap { modificationDate($0.path) }, into: &section)
        return section
    }

    /// Logic's own scan logs (~/Library/Caches/AudioUnitCache/Logs): when it
    /// last scanned, whether that scan reached this product, and what it said.
    private func logicScanLogs(installedAt: Date?, into section: inout Section) -> String {
        let dir = "\(fileManager.homeDirectoryForCurrentUser.path)/Library/Caches/AudioUnitCache/Logs"
        guard let files = try? fileManager.contentsOfDirectory(atPath: dir) else {
            return "## Logic scan logs\n\n_None on this account._\n"
        }
        let logs = files.filter { $0.hasPrefix("AUScan") }
            .compactMap { name -> (String, Date)? in
                let path = "\(dir)/\(name)"
                guard let date = modificationDate(path) else { return nil }
                return (path, date)
            }
            .sorted { $0.1 > $1.1 }
        var md = "## Logic scan logs (\(logs.count))\n\n"
        guard let latest = logs.first else { return md + "_None._\n" }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        md += "- Latest scan: \(formatter.string(from: latest.1))\n"
        let mentioning = logs.first { (try? String(contentsOfFile: $0.0, encoding: .utf8))?.contains(config.pluginName) == true }
        if let mentioning {
            md += "- Latest scan that included \(config.pluginName): \(formatter.string(from: mentioning.1))\n"
            if let text = try? String(contentsOfFile: mentioning.0, encoding: .utf8) {
                let lines = text.components(separatedBy: "\n").filter { $0.contains(config.pluginName) }
                    .map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "<string>", with: "").replacingOccurrences(of: "</string>", with: "") }
                md += "\n```\n\(lines.prefix(20).joined(separator: "\n"))\n```\n"
            }
            if let installedAt, installedAt > mentioning.1 {
                section.findings.append(Finding(severity: .note, message:
                    "\(config.pluginName) was installed or updated after Logic last scanned it; Logic rescans on its next launch."))
            }
        } else {
            md += "- No Logic scan log mentions \(config.pluginName)\n"
        }
        section.attachments["logic_scan_latest.plist"] = (try? String(contentsOfFile: latest.0, encoding: .utf8)) ?? ""
        return md
    }

    /// "Open using Rosetta" is stored per app in LaunchServices' preferences.
    private func rosettaRequested(bundleId: String?) -> Bool {
        guard let bundleId else { return false }
        let path = "\(fileManager.homeDirectoryForCurrentUser.path)/Library/Preferences/com.apple.LaunchServices/com.apple.LaunchServices.plist"
        guard let data = fileManager.contents(atPath: path),
              let prefs = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return false }
        for (key, value) in prefs where key.hasPrefix("Architectures for") {
            if let map = value as? [String: Any], let archs = map[bundleId] as? [String], archs.contains("x86_64") {
                return true
            }
        }
        return false
    }

    private func componentVersion(_ bundlePath: String) -> Int? {
        let components = Bundle(path: bundlePath)?.infoDictionary?["AudioComponents"] as? [[String: Any]]
        return components?.first?["version"] as? Int
    }

    // MARK: - DAWs on this Mac

    func dawSection() -> Section {
        var section = Section(markdown: "# DAWs Installed\n\n")
        let hostArch = hostArchitecture()
        let known = ["Logic Pro", "Logic Pro X", "GarageBand", "MainStage", "Ableton Live", "Bitwig Studio",
                     "REAPER", "Studio One", "Cubase", "Nuendo", "FL Studio", "Digital Performer",
                     "Pro Tools", "Reason", "Luna", "Waveform", "Tracktion", "Cakewalk", "Renoise", "Ardour",
                     "Mixbus", "Audacity", "AUM", "Gig Performer", "Hosting AU", "Element", "Plogue Bidule"]
        var apps: [String] = []
        for root in ["/Applications", "\(fileManager.homeDirectoryForCurrentUser.path)/Applications"] {
            guard let items = try? fileManager.contentsOfDirectory(atPath: root) else { continue }
            for item in items {
                let path = "\(root)/\(item)"
                if item.hasSuffix(".app"), known.contains(where: { item.hasPrefix($0) }) { apps.append(path) }
                // Many DAWs install as a folder holding the app.
                if !item.hasSuffix(".app"), known.contains(where: { item.hasPrefix($0) }),
                   let inner = try? fileManager.contentsOfDirectory(atPath: path) {
                    for app in inner where app.hasSuffix(".app") && known.contains(where: { app.hasPrefix($0) }) {
                        apps.append("\(path)/\(app)")
                    }
                }
            }
        }
        if apps.isEmpty {
            section.markdown += "_No known DAW found in /Applications._\n"
            return section
        }
        section.markdown += "| DAW | Version | Architectures | Open using Rosetta |\n|---|---|---|---|\n"
        for path in apps.sorted() {
            let info = Bundle(path: path)?.infoDictionary
            let name = (path as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
            let version = info?["CFBundleShortVersionString"] as? String ?? "?"
            let exe = Bundle(path: path)?.executablePath
            let archs = exe.map { run("/usr/bin/lipo", ["-archs", $0], nil).output.trimmingCharacters(in: .whitespacesAndNewlines) } ?? "?"
            let rosetta = rosettaRequested(bundleId: info?["CFBundleIdentifier"] as? String)
            section.markdown += "| \(name) | \(version) | \(archs) | \(rosetta ? "❌ yes" : "no") |\n"
            if hostArch == "arm64" && !archs.contains("arm64") && !archs.isEmpty && archs != "?" {
                section.findings.append(Finding(severity: .problem, message:
                    "\(name) is Intel-only, so on this Mac it runs under Rosetta and cannot load \(config.pluginName)'s Apple-silicon build."))
            } else if rosetta && !name.hasPrefix("Logic") && !name.hasPrefix("GarageBand") {
                section.findings.append(Finding(severity: .problem, message:
                    "\(name) is set to Open using Rosetta, so it cannot load \(config.pluginName)'s Apple-silicon build."))
            }
        }
        return section
    }

    // MARK: - Other hosts' plug-in scan records

    /// Hosts that keep a readable record of what they scanned and what failed.
    func hostCachesSection() -> Section {
        var section = Section(markdown: "# Other Hosts' Plug-in Records\n\n")
        let home = fileManager.homeDirectoryForCurrentUser.path
        let needle = config.pluginName
        var any = false

        // REAPER: one ini per format/arch; a failed scan is recorded inline.
        let reaper = "\(home)/Library/Application Support/REAPER"
        if let files = try? fileManager.contentsOfDirectory(atPath: reaper) {
            for file in files.sorted() where file.hasPrefix("reaper-") && file.hasSuffix(".ini") && file.contains("plugins") {
                guard let text = try? String(contentsOfFile: "\(reaper)/\(file)", encoding: .utf8) else { continue }
                let lines = text.components(separatedBy: "\n").filter { $0.localizedCaseInsensitiveContains(needle) }
                any = true
                section.markdown += "- REAPER `\(file)`: \(lines.isEmpty ? "no entry for \(needle)" : lines.prefix(4).map { "`\($0.prefix(160))`" }.joined(separator: " "))\n"
            }
        }

        // Ableton Live writes its plug-in scan into Log.txt.
        let abletonPrefs = "\(home)/Library/Preferences/Ableton"
        if let versions = try? fileManager.contentsOfDirectory(atPath: abletonPrefs) {
            for version in versions.sorted() where version.hasPrefix("Live") {
                let log = "\(abletonPrefs)/\(version)/Log.txt"
                guard let text = try? String(contentsOfFile: log, encoding: .utf8) else { continue }
                any = true
                let lines = text.components(separatedBy: "\n").filter { $0.localizedCaseInsensitiveContains(needle) }
                section.markdown += "- Ableton \(version) Log.txt: \(lines.count) line(s) mention \(needle)\n"
                if !lines.isEmpty {
                    section.markdown += "\n```\n\(lines.suffix(15).joined(separator: "\n").prefix(3000))\n```\n"
                    section.attachments["ableton_\(version)_log_excerpt.txt"] = lines.suffix(400).joined(separator: "\n")
                    if lines.contains(where: { $0.range(of: "fail|error|crash|could not", options: [.regularExpression, .caseInsensitive]) != nil }) {
                        section.findings.append(Finding(severity: .warning, message:
                            "Ableton \(version)'s log records a failure involving \(needle); see the Ableton excerpt in the archive."))
                    }
                }
            }
        }
        if !any { section.markdown += "_No REAPER or Ableton Live scan records on this account._\n" }
        return section
    }

    // MARK: - Other Pulp plug-ins and Objective-C class clashes

    /// Two plug-ins that define the same Objective-C class, loaded in one host,
    /// share one of the two implementations at random -- the classic cause of
    /// "works alone, breaks next to X". Pulp-built plug-ins share the framework,
    /// so this checks the product's classes against every other Pulp plug-in.
    func neighborsSection(_ bundles: [InstalledBundle]) -> Section {
        var section = Section(markdown: "# Other Pulp-built Plug-ins\n\n")
        let home = fileManager.homeDirectoryForCurrentUser.path
        let ours = Set(bundles.map { $0.path })
        var neighbors: [String] = []
        for root in ["/Library/Audio/Plug-Ins", "\(home)/Library/Audio/Plug-Ins"] {
            for dir in ["Components", "VST3", "CLAP"] {
                guard let items = try? fileManager.contentsOfDirectory(atPath: "\(root)/\(dir)") else { continue }
                for item in items {
                    let path = "\(root)/\(dir)/\(item)"
                    guard !ours.contains(path), isPulpBuilt(path) else { continue }
                    neighbors.append(path)
                }
            }
        }
        if neighbors.isEmpty {
            section.markdown += "_No other Pulp-built plug-ins installed._\n"
            return section
        }
        let mine = Set(bundles.filter { $0.format != "Standalone App" }.prefix(1)
            .flatMap { objcClasses($0.path) })
        // Reading symbols costs seconds per binary, and a developer machine can
        // hold a hundred Pulp-built plug-ins; an unbounded scan turned a
        // minutes-long collection into half an hour. Scan within a budget and
        // say how many were left unchecked.
        let budgetEnds = Date().addingTimeInterval(neighborScanBudgetSeconds)
        var unchecked = 0
        let rows = neighbors.map { path -> (String, [String]) in
            if mine.isEmpty { return (path, []) }
            if Date() >= budgetEnds { unchecked += 1; return (path, []) }
            return (path, Array(mine.intersection(objcClasses(path))).sorted())
        }.sorted { ($0.1.count, $1.0) > ($1.1.count, $0.0) }
        let clashing = rows.filter { !$0.1.isEmpty }.count
        section.markdown += "\(neighbors.count) other Pulp-built plug-in bundle(s); \(clashing) share Objective-C class names with \(config.pluginName) (checked against its \(mine.count) classes).\n\n"
        if unchecked > 0 {
            section.markdown += "_\(unchecked) of them were not checked: the scan stops after \(Int(neighborScanBudgetSeconds)) seconds._\n\n"
        }
        section.markdown += "| Plug-in | Version | Shared Objective-C classes |\n|---|---|---|\n"
        for (path, shared) in rows.prefix(25) {
            let version = Bundle(path: path)?.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–"
            section.markdown += "| `\((path as NSString).lastPathComponent)` | \(version) | \(shared.isEmpty ? "none" : "\(shared.count): " + shared.prefix(4).joined(separator: ", ")) |\n"
            if !shared.isEmpty {
                section.findings.append(Finding(severity: .warning, message:
                    "\((path as NSString).lastPathComponent) defines \(shared.count) of the same Objective-C classes as \(config.pluginName) (e.g. \(shared.prefix(2).joined(separator: ", "))). Loaded in the same host, one plug-in can end up running the other's code. Try removing it if \(config.pluginName) misbehaves only alongside it."))
            }
        }
        return section
    }

    private var neighborScanBudgetSeconds: TimeInterval { 30 }

    private func isPulpBuilt(_ path: String) -> Bool {
        let resources = "\(path)/Contents/Resources"
        return fileManager.fileExists(atPath: "\(resources)/pulp-build-info.json")
            || fileManager.fileExists(atPath: "\(resources)/pulp-control-shipping-evidence")
            || fileManager.fileExists(atPath: "\(path)/Contents/MacOS/libwgpu_native.dylib")
    }

    private func objcClasses(_ bundlePath: String) -> Set<String> {
        guard let exe = Bundle(path: bundlePath)?.executablePath else { return [] }
        // Shipped binaries drop the _OBJC_CLASS_$_ symbols, but every method
        // keeps a local symbol like "-[ClassName selector]", which names its class.
        let out = run("/usr/bin/nm", ["-U", exe], 15).output
        var classes = Set<String>()
        for line in out.split(separator: "\n") {
            guard let open = line.range(of: "[") else { continue }
            let before = line[..<open.lowerBound]
            guard before.hasSuffix("-") || before.hasSuffix("+") else { continue }
            let rest = line[open.upperBound...]
            if let space = rest.firstIndex(of: " ") {
                let name = String(rest[..<space]).components(separatedBy: "(").first ?? ""
                if !name.isEmpty { classes.insert(name) }
            }
        }
        return classes
    }

    // MARK: - The product's own saved state

    func stateSection() -> Section {
        var section = Section(markdown: "# \(config.pluginName) Settings & Saved Data\n\n")
        let home = fileManager.homeDirectoryForCurrentUser.path
        var dirs = config.stateDirs.map { expand($0) }
        if dirs.isEmpty { dirs = ["\(home)/Library/Application Support/\(config.pluginName)"] }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        for dir in dirs {
            guard let top = try? fileManager.contentsOfDirectory(atPath: dir) else {
                section.markdown += "- `\(dir)`: not present\n"
                continue
            }
            section.markdown += "- `\(dir)`: \(top.count) item(s)\n"
            // One line per top-level entry: a folder is summarised (file count,
            // total size, newest change), a file is shown as itself.
            for name in top.sorted().prefix(30) where !name.hasPrefix(".") {
                let path = "\(dir)/\(name)"
                var isDir: ObjCBool = false
                fileManager.fileExists(atPath: path, isDirectory: &isDir)
                var count = 0, bytes: Int64 = 0
                var newest: Date?
                let visit = { (file: String) in
                    let attrs = try? fileManager.attributesOfItem(atPath: file)
                    guard (attrs?[.type] as? FileAttributeType) == .typeRegular else { return }
                    count += 1
                    bytes += (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                    if let date = attrs?[.modificationDate] as? Date, date > (newest ?? .distantPast) { newest = date }
                }
                if isDir.boolValue, let walker = fileManager.enumerator(atPath: path) {
                    while let item = walker.nextObject() as? String { visit("\(path)/\(item)") }
                } else {
                    visit(path)
                }
                let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
                section.markdown += "  - `\(name)\(isDir.boolValue ? "/" : "")` — \(isDir.boolValue ? "\(count) file(s), " : "")\(size)\(newest.map { ", " + formatter.string(from: $0) } ?? "")\n"
                if !isDir.boolValue && bytes == 0 && (name.hasSuffix(".json") || name.hasSuffix(".plist")) {
                    section.findings.append(Finding(severity: .warning, message:
                        "\(config.pluginName)'s saved file `\(name)` is empty; a truncated settings file can stop it loading."))
                }
            }
        }
        if !config.pluginBundleId.isEmpty,
           let prefs = try? fileManager.contentsOfDirectory(atPath: "\(home)/Library/Preferences") {
            let own = config.appIdentifier.lowercased()
            let matching = prefs.filter {
                $0.lowercased().hasPrefix(config.pluginBundleId.lowercased()) && (own.isEmpty || !$0.lowercased().hasPrefix(own))
            }
            if !matching.isEmpty { section.markdown += "- Preferences: \(matching.map { "`\($0)`" }.joined(separator: ", "))\n" }
        }
        return section
    }

    // MARK: - Audio devices

    func audioSection() -> Section {
        var section = Section(markdown: "# Audio Devices\n\n")
        let defaultIn = defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
        let defaultOut = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
        section.markdown += "| Device | In | Out | Sample rate | Buffer | Default |\n|---|---|---|---|---|---|\n"
        for device in allDevices() {
            let name = deviceString(device, kAudioObjectPropertyName) ?? "?"
            let ins = channelCount(device, scope: kAudioObjectPropertyScopeInput)
            let outs = channelCount(device, scope: kAudioObjectPropertyScopeOutput)
            let rate = deviceFloat64(device, kAudioDevicePropertyNominalSampleRate).map { String(format: "%.0f Hz", $0) } ?? "?"
            let buffer = deviceUInt32(device, kAudioDevicePropertyBufferFrameSize).map { "\($0)" } ?? "?"
            var marks: [String] = []
            if device == defaultIn { marks.append("input") }
            if device == defaultOut { marks.append("output") }
            section.markdown += "| \(name) | \(ins) | \(outs) | \(rate) | \(buffer) | \(marks.joined(separator: ", ")) |\n"
        }
        return section
    }

    private func allDevices() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr ? id : nil
    }

    private func deviceString(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private func deviceFloat64(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Double? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private func deviceUInt32(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private func channelCount(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    // MARK: - Microphone permission (standalone)

    /// The standalone needs microphone permission for live input. macOS keeps
    /// the decision private, but its privacy daemon logs each check.
    func microphoneSection() -> Section {
        var section = Section(markdown: "# Microphone Permission\n\n")
        guard !config.pluginBundleId.isEmpty else { return section }
        let id = config.pluginBundleId.replacingOccurrences(of: "\"", with: "")
        let predicate = "process == \"tccd\" AND eventMessage CONTAINS[c] \"\(id)\" AND eventMessage CONTAINS \"Microphone\""
        let result = run("/usr/bin/log", ["show", "--last", "7d", "--style", "compact", "--predicate", predicate], 90)
        // The diagnostics app's own id starts with the product's, so drop its checks.
        let own = config.appIdentifier.lowercased()
        let lines = result.output.split(separator: "\n").map(String.init)
            .filter { !$0.hasPrefix("Timestamp") && (own.isEmpty || !$0.lowercased().contains(own)) }
        if result.timedOut {
            section.markdown += "_Timed out reading the privacy log._\n"
        } else if lines.isEmpty {
            section.markdown += "_No microphone permission checks for \(config.pluginName) in the last 7 days._\n"
        } else {
            section.markdown += "```\n\(lines.suffix(10).joined(separator: "\n").prefix(3000))\n```\n"
            if lines.last?.range(of: "denied|auth_value: 0|Denied", options: .regularExpression) != nil {
                section.findings.append(Finding(severity: .warning, message:
                    "macOS denied \(config.pluginName) microphone access; the standalone app will get no audio input. Allow it in System Settings › Privacy & Security › Microphone."))
            }
        }
        return section
    }

    // MARK: - Folder permissions

    func permissionsSection(_ bundles: [InstalledBundle]) -> Section {
        var section = Section(markdown: "# Folder Permissions\n\n")
        let home = fileManager.homeDirectoryForCurrentUser.path
        var paths = ["/Library/Audio/Plug-Ins/Components", "/Library/Audio/Plug-Ins/VST3", "/Library/Audio/Plug-Ins/CLAP",
                     "\(home)/Library/Audio/Plug-Ins/Components", "\(home)/Library/Audio/Plug-Ins/VST3",
                     "\(home)/Library/Audio/Plug-Ins/CLAP"].filter { fileManager.fileExists(atPath: $0) }
        paths += bundles.map { $0.path }
        section.markdown += "| Path | Owner | Mode | Readable |\n|---|---|---|---|\n"
        for path in paths {
            let attrs = try? fileManager.attributesOfItem(atPath: path)
            let owner = attrs?[.ownerAccountName] as? String ?? "?"
            let mode = (attrs?[.posixPermissions] as? NSNumber).map { String($0.intValue, radix: 8) } ?? "?"
            let readable = fileManager.isReadableFile(atPath: path) && fileManager.isExecutableFile(atPath: path)
            section.markdown += "| `\(path)` | \(owner) | \(mode) | \(readable ? "✅" : "❌") |\n"
            if !readable {
                section.findings.append(Finding(severity: .problem, message:
                    "`\(path)` cannot be read by this account, so hosts running as this user cannot see what is inside it."))
            }
        }
        return section
    }

    // MARK: - Displays

    func displaysSection() -> Section {
        var section = Section(markdown: "## Displays\n\n")
        let result = run("/usr/sbin/system_profiler", ["SPDisplaysDataType", "-json"], nil)
        guard let data = result.output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let gpus = json["SPDisplaysDataType"] as? [[String: Any]] else { return section }
        for gpu in gpus {
            for display in (gpu["spdisplays_ndrvs"] as? [[String: Any]]) ?? [] {
                let name = display["_name"] as? String ?? "?"
                let resolution = display["_spdisplays_resolution"] as? String ?? display["spdisplays_resolution"] as? String ?? "?"
                let main = (display["spdisplays_main"] as? String) == "spdisplays_yes"
                section.markdown += "- \(name): \(resolution)\(main ? " (main)" : "")\n"
            }
        }
        return section
    }

    // MARK: - Running the product: load test and editor render

    /// Loads each installed VST3 and CLAP in a child process (a copy of this
    /// app in `--load-probe` mode). A crash there is reported, not suffered.
    func loadProbeSection(_ bundles: [InstalledBundle]) -> Section {
        var section = Section(markdown: "# Load Test (VST3 / CLAP)\n\n")
        guard let me = Bundle.main.executablePath else { return section }
        let targets = bundles.filter { $0.format == "VST3" || $0.format == "CLAP" }
        if targets.isEmpty {
            section.markdown += "_No VST3 or CLAP installed to load._\n"
            return section
        }
        for bundle in targets {
            let kind = bundle.format == "VST3" ? "vst3" : "clap"
            let result = run(me, ["--load-probe", kind, bundle.path], 45)
            let passed = !result.timedOut && result.exitCode == 0
            section.markdown += "## \(bundle.format): \(passed ? "✅ loads" : "❌ did not load")\n\n```\n\(result.output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(3000))\n\(result.timedOut ? "timed out" : "exit \(result.exitCode)")\n```\n\n"
            if !passed {
                let reason = result.timedOut ? "it hung for 45 seconds"
                    : result.exitCode > 128 || result.exitCode < 0 ? "it crashed (exit \(result.exitCode))"
                    : (result.output.components(separatedBy: "\n").first { $0.hasPrefix("PROBE_FAIL") }.map { String($0.dropFirst(11)) } ?? "exit \(result.exitCode)")
                section.findings.append(Finding(severity: .problem, message:
                    "The \(bundle.format) did not load outside a host: \(reason.prefix(240))"))
            }
        }
        return section
    }

    /// Runs the installed standalone app headless: it builds the same
    /// processor and editor the plug-ins do, brings up Metal, Dawn and Skia,
    /// renders the editor offscreen and exits. No audio device is opened and
    /// no window is shown. Its log and the rendered image go in the archive.
    func editorProbeSection(_ bundles: [InstalledBundle], workDir: URL) -> Section {
        var section = Section(markdown: "# Editor Render Test (Metal / Dawn / Skia)\n\n")
        guard config.standaloneProbe,
              let app = bundles.first(where: { $0.format == "Standalone App" && $0.path.hasPrefix("/Applications") })
                ?? bundles.first(where: { $0.format == "Standalone App" }),
              let exe = Bundle(path: app.path)?.executablePath else {
            section.markdown += "_Skipped (no standalone app installed, or the test is disabled)._\n"
            return section
        }
        try? fileManager.createDirectory(at: workDir, withIntermediateDirectories: true)
        let shot = workDir.appendingPathComponent("editor_render.png")
        try? fileManager.removeItem(at: shot)
        let started = Date()
        let result = runWithEnvironment(exe, [], env: ["PULP_HEADLESS": "1", "PULP_SCREENSHOT": shot.path, "PULP_FRAMES": "60",
                                                    // Route Skia's own log records into the text log (builds that support it).
                                                    "PULP_GPU_LOG_BRIDGE": "1"], timeout: 90)
        let seconds = Date().timeIntervalSince(started)
        let size = (try? fileManager.attributesOfItem(atPath: shot.path)[.size] as? NSNumber)?.intValue ?? 0
        let log = result.output
        section.attachments["editor_render_log.txt"] = log
        if size > 0, let png = fileManager.contents(atPath: shot.path) { section.files["editor_render.png"] = png }
        let gpuLines = log.components(separatedBy: "\n").filter {
            $0.range(of: "GpuSurface|SkiaSurface|Dawn|Metal|Graphite|gpu-host|adapter|error|fail", options: [.regularExpression, .caseInsensitive]) != nil
        }
        let rendered = size > 10_000
        section.markdown += gpuReadout(log, into: &section)
        section.markdown += "- Result: \(rendered ? "✅ editor rendered" : "❌ no editor image") in \(String(format: "%.1f", seconds)) s (exit \(result.exitCode)\(result.timedOut ? ", timed out" : ""))\n\n```\n\(gpuLines.prefix(40).joined(separator: "\n").prefix(5000))\n```\n"
        if !rendered {
            section.findings.append(Finding(severity: .problem, message:
                "The editor did not render on this Mac (exit \(result.exitCode)\(result.timedOut ? ", timed out" : "")). The plug-in window will likely be blank or crash; editor_render_log.txt in the archive has the GPU start-up log."))
        } else if !log.contains("Graphite initialized") {
            section.findings.append(Finding(severity: .warning, message:
                "The editor rendered, but not through the GPU path (no Graphite start-up in the log); expect slower drawing."))
        }
        return section
    }

    /// The structured lines newer Pulp builds log at GPU start-up, read into
    /// plain statements. Older builds do not emit them; that is reported, not
    /// treated as a failure.
    func gpuReadout(_ log: String, into section: inout Section) -> String {
        let lines = log.components(separatedBy: "\n")
        func line(_ prefix: String) -> String? {
            lines.first { $0.contains(prefix) }.map { String($0[$0.range(of: prefix)!.upperBound...]) }
        }
        func fields(_ text: String) -> [String: String] {
            var out: [String: String] = [:]
            let pattern = try! NSRegularExpression(pattern: "([a-z_0-9]+)=(\"(?:[^\"\\\\]|\\\\.)*\"|\\S+)")
            for m in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let k = Range(m.range(at: 1), in: text), let v = Range(m.range(at: 2), in: text) else { continue }
                out[String(text[k])] = String(text[v]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
            return out
        }
        var md = ""
        // Match the identity line by its first field: 0.873-era builds also log
        // "GpuSurface: adapter offers timestamp-query ...", which is not it.
        if let adapter = line("GpuSurface: adapter name=").map({ fields("name=" + $0) }) {
            md += "- GPU chosen: **\(adapter["name"] ?? "?")** (\(adapter["vendor"] ?? "?"), \(adapter["architecture"] ?? "?"), \(adapter["type"] ?? "?"), backend \(adapter["backend"] ?? "?"))\n"
            if adapter["null"] == "true" {
                section.findings.append(Finding(severity: .problem, message:
                    "The editor ran on Dawn's null backend: no real GPU was used, so nothing it draws will appear."))
            } else if adapter["type"] == "cpu" {
                section.findings.append(Finding(severity: .warning, message:
                    "No hardware GPU was available; the editor ran on a software renderer (\(adapter["name"] ?? "?")) and will be slow."))
            }
        } else {
            md += "- GPU identity: _not logged by this build (needs a Pulp SDK with start-up diagnostics)_\n"
        }
        if let startup = line("GpuSurface: startup_ms ").map(fields) {
            md += "- GPU start-up (ms): " + ["instance", "adapter", "device", "surface", "graphite", "first_frame"]
                .map { "\($0) \(startup[$0] ?? "?")" }.joined(separator: ", ") + "\n"
            if let first = Double(startup["first_frame"] ?? ""), first > 2000 {
                section.findings.append(Finding(severity: .warning, message:
                    String(format: "The editor took %.1f s to show its first frame on this Mac.", first / 1000)))
            }
        }
        if let frames = line("Standalone: frame_ms ").map(fields) {
            md += "- Frames: \(frames["frames"] ?? "?") drawn, p50 \(frames["p50"] ?? "?") ms, p95 \(frames["p95"] ?? "?") ms, max \(frames["max"] ?? "?") ms, \(frames["over16"] ?? "?") over 16.7 ms, \(frames["over33"] ?? "?") over 33.3 ms\n"
            if let p95 = Double(frames["p95"] ?? ""), p95 > 33.3 {
                section.findings.append(Finding(severity: .warning, message:
                    "Drawing the editor took \(frames["p95"]!) ms per frame at the 95th percentile; animation will stutter on this Mac."))
            }
        }
        if let bridge = line("GpuDiagnostics: ").map(fields) {
            md += "- Skia log bridge: \(bridge["skia_bridge"] ?? "?"), \(bridge["skia_records"] ?? "0") Skia record(s), \(bridge["gpu_diagnostics_emitted"] ?? "0") GPU diagnostic(s)\n"
        }
        let skia = lines.filter { $0.contains("skia: [") }
        let dawnErrors = lines.filter { $0.range(of: "uncaptured error|device lost|Device lost|validation error", options: [.regularExpression, .caseInsensitive]) != nil }
        if !skia.isEmpty {
            md += "\n```\n\(skia.prefix(20).joined(separator: "\n"))\n```\n"
            if skia.contains(where: { $0.contains("[error]") || $0.contains("[fatal]") }) {
                section.findings.append(Finding(severity: .warning, message: "Skia reported errors while drawing the editor; see editor_render_log.txt."))
            }
        }
        if !dawnErrors.isEmpty {
            section.findings.append(Finding(severity: .problem, message:
                "Dawn reported a GPU error while drawing the editor: \(dawnErrors[0].trimmingCharacters(in: .whitespaces).prefix(200))"))
        }
        return md + "\n"
    }

    private func runWithEnvironment(_ path: String, _ args: [String], env: [String: String], timeout: Int) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return ("", -1, false, error.localizedDescription) }
        var collected = Data()
        let reader = DispatchGroup()
        reader.enter()
        DispatchQueue.global(qos: .utility).async {
            collected = pipe.fileHandleForReading.readDataToEndOfFile()
            reader.leave()
        }
        let done = DispatchGroup()
        done.enter()
        DispatchQueue.global(qos: .utility).async { process.waitUntilExit(); done.leave() }
        let timedOut = done.wait(timeout: .now() + .seconds(timeout)) == .timedOut
        if timedOut { process.terminate(); process.waitUntilExit() }
        reader.wait()
        return (String(decoding: collected, as: UTF8.self), process.terminationStatus, timedOut, nil)
    }

    // MARK: - Helpers

    func modificationDate(_ path: String) -> Date? {
        (try? fileManager.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    private func expand(_ path: String) -> String {
        path.hasPrefix("~") ? fileManager.homeDirectoryForCurrentUser.path + path.dropFirst() : path
    }
}
