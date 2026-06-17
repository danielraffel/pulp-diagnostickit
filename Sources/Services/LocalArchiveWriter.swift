import Foundation

enum ArchiveError: Error, LocalizedError {
    case couldNotCreateStage(String)
    case couldNotWriteReport(String)
    case dittoFailed(String)
    case couldNotMoveArchive(String)

    var errorDescription: String? {
        switch self {
        case .couldNotCreateStage(let message):
            return "Could not create archive staging directory: \(message)"
        case .couldNotWriteReport(let message):
            return "Could not write diagnostic report: \(message)"
        case .dittoFailed(let message):
            return "Could not create diagnostic ZIP: \(message)"
        case .couldNotMoveArchive(let message):
            return "Could not finalize diagnostic ZIP: \(message)"
        }
    }
}

final class LocalArchiveWriter {
    private let config: AppConfig
    private let fileManager = FileManager.default

    init(config: AppConfig) {
        self.config = config
    }

    func writeArchive(_ data: DiagnosticData) async throws -> URL {
        try await Task.detached(priority: .utility) { [config, fileManager] in
            let timestamp = Self.archiveTimestamp()
            let archiveName = "PromptableAccompanistV2-Diagnostics-\(timestamp).zip"
            let desktopURL = fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Desktop", isDirectory: true)
            let finalURL = desktopURL.appendingPathComponent(archiveName)
            let partialURL = desktopURL.appendingPathComponent("\(archiveName).partial")

            let stageRoot = fileManager.temporaryDirectory
                .appendingPathComponent("PromptableAccompanistV2-Diagnostics-\(UUID().uuidString)", isDirectory: true)
            let stageURL = stageRoot.appendingPathComponent("PromptableAccompanistV2-Diagnostics", isDirectory: true)

            do {
                try fileManager.createDirectory(at: stageURL, withIntermediateDirectories: true)
            } catch {
                throw ArchiveError.couldNotCreateStage(error.localizedDescription)
            }

            defer { try? fileManager.removeItem(at: stageRoot) }
            try? fileManager.removeItem(at: partialURL)
            try? fileManager.removeItem(at: finalURL)

            let anonymize = config.anonymizeUsernames || config.excludeUserPaths
            let report = anonymizeDiagnosticText(
                renderDiagnosticReport(data, appName: config.appName, appVersion: config.appVersion),
                enabled: anonymize)
            do {
                try report.write(to: stageURL.appendingPathComponent("diagnostic_report.md"), atomically: true, encoding: .utf8)
            } catch {
                throw ArchiveError.couldNotWriteReport(error.localizedDescription)
            }

            // Raw crash logs / model-state files carry the username + hostname in
            // their bytes and filenames; when anonymizing, ship only the scrubbed
            // report (which already includes a crash excerpt) and skip the raw copies.
            if !anonymize {
                Self.copyBestEffort(paths: data.crashFilePaths, into: stageURL.appendingPathComponent("crash_logs", isDirectory: true), fileManager: fileManager)
                if let pulpModelStatePath = data.pulpModelStatePath {
                    Self.copyBestEffort(paths: [pulpModelStatePath], into: stageURL.appendingPathComponent("pulp_model_state", isDirectory: true), fileManager: fileManager)
                }
            }

            let result = Self.runDitto(stageURL: stageURL, partialURL: partialURL)
            guard result.exitCode == 0 else {
                throw ArchiveError.dittoFailed(result.output.isEmpty ? "ditto exited with code \(result.exitCode)" : result.output)
            }

            do {
                try fileManager.moveItem(at: partialURL, to: finalURL)
            } catch {
                throw ArchiveError.couldNotMoveArchive(error.localizedDescription)
            }

            return finalURL
        }.value
    }

    private static func archiveTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private static func copyBestEffort(paths: [String], into directory: URL, fileManager: FileManager) {
        guard !paths.isEmpty else { return }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        for path in paths {
            let sourceURL = URL(fileURLWithPath: path)
            let destinationURL = uniqueDestinationURL(for: sourceURL.lastPathComponent, in: directory, fileManager: fileManager)
            try? fileManager.copyItem(at: sourceURL, to: destinationURL)
        }
    }

    private static func uniqueDestinationURL(for fileName: String, in directory: URL, fileManager: FileManager) -> URL {
        var candidate = directory.appendingPathComponent(fileName)
        guard fileManager.fileExists(atPath: candidate.path) else { return candidate }

        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var index = 2

        repeat {
            let indexedName = ext.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(ext)"
            candidate = directory.appendingPathComponent(indexedName)
            index += 1
        } while fileManager.fileExists(atPath: candidate.path)

        return candidate
    }

    private static func runDitto(stageURL: URL, partialURL: URL) -> (output: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = [
            "-c",
            "-k",
            "--sequesterRsrc",
            "--keepParent",
            stageURL.path,
            partialURL.path
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (error.localizedDescription, -1)
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (output, process.terminationStatus)
    }
}
