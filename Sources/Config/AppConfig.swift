import Foundation

struct AppConfig {
    enum OutputMode {
        case github
        case localArchive
    }

    // App Info
    let appName: String
    let appIdentifier: String
    let appVersion: String

    // GitHub
    let githubRepo: String
    let githubPAT: String

    // Support
    let supportEmail: String
    let productName: String
    let productWebsite: String

    // Plugin Info
    let pluginName: String
    let pluginBundleId: String
    let pluginManufacturer: String

    // Plugin Formats
    let checkAU: Bool
    let checkVST3: Bool
    let checkCLAP: Bool
    let checkStandalone: Bool

    // Audio Unit specifics
    let auType: String
    let auSubtype: String
    let auManufacturer: String

    // Pulp specifics
    let pulpModelPath: String

    // UI Configuration
    let windowWidth: Int
    let windowHeight: Int
    let showTechnicalDetails: Bool
    let allowUserFeedback: Bool
    let showPrivacyNotice: Bool
    let autoSendOnSuccess: Bool

    // Privacy
    let excludeUserPaths: Bool
    let excludeSerialNumbers: Bool
    let anonymizeUsernames: Bool
    let maxLogSizeMB: Int
    let compressLogs: Bool

    // Timeouts
    let diagnosticTimeout: Int
    let githubAPITimeout: Int
    let githubAPIRetries: Int

    // Debug
    let debugMode: Bool

    var hasGitHubConfig: Bool { !githubRepo.isEmpty && !githubPAT.isEmpty }
    var outputMode: OutputMode { hasGitHubConfig ? .github : .localArchive }

    static func load() -> AppConfig {
        var env: [String: String] = [:]

        if let envPath = Bundle.main.path(forResource: ".env", ofType: nil),
           let envContent = try? String(contentsOfFile: envPath, encoding: .utf8) {
            env = parseEnv(envContent)
        }

        return AppConfig(
            appName: env["APP_NAME"] ?? "Diagnostics",
            appIdentifier: env["APP_IDENTIFIER"] ?? "com.pulp.diagnostics",
            appVersion: env["APP_VERSION"] ?? "1.0.0",
            githubRepo: env["GITHUB_REPO"] ?? "",
            githubPAT: env["GITHUB_PAT"] ?? "",
            supportEmail: env["SUPPORT_EMAIL"] ?? "",
            productName: env["PRODUCT_NAME"] ?? env["PLUGIN_NAME"] ?? "Plugin",
            productWebsite: env["PRODUCT_WEBSITE"] ?? "",
            pluginName: env["PLUGIN_NAME"] ?? "Plugin",
            pluginBundleId: env["PLUGIN_BUNDLE_ID"] ?? "",
            pluginManufacturer: env["PLUGIN_MANUFACTURER"] ?? "",
            checkAU: boolValue(env["CHECK_AU"], default: true),
            checkVST3: boolValue(env["CHECK_VST3"], default: true),
            checkCLAP: boolValue(env["CHECK_CLAP"], default: true),
            checkStandalone: boolValue(env["CHECK_STANDALONE"], default: true),
            auType: env["AU_TYPE"] ?? "aufx",
            auSubtype: env["AU_SUBTYPE"] ?? "",
            auManufacturer: env["AU_MANUFACTURER"] ?? "",
            pulpModelPath: env["PULP_MODEL_PATH"] ?? "",
            windowWidth: Int(env["WINDOW_WIDTH"] ?? "380") ?? 380,
            windowHeight: Int(env["WINDOW_HEIGHT"] ?? "550") ?? 550,
            showTechnicalDetails: boolValue(env["SHOW_TECHNICAL_DETAILS"], default: false),
            allowUserFeedback: boolValue(env["ALLOW_USER_FEEDBACK"], default: true),
            showPrivacyNotice: boolValue(env["SHOW_PRIVACY_NOTICE"], default: true),
            autoSendOnSuccess: boolValue(env["AUTO_SEND_ON_SUCCESS"], default: false),
            excludeUserPaths: boolValue(env["EXCLUDE_USER_PATHS"], default: false),
            excludeSerialNumbers: boolValue(env["EXCLUDE_SERIAL_NUMBERS"], default: false),
            anonymizeUsernames: boolValue(env["ANONYMIZE_USERNAMES"], default: false),
            maxLogSizeMB: Int(env["MAX_LOG_SIZE_MB"] ?? "10") ?? 10,
            compressLogs: boolValue(env["COMPRESS_LOGS"], default: true),
            diagnosticTimeout: Int(env["DIAGNOSTIC_TIMEOUT"] ?? "30") ?? 30,
            githubAPITimeout: Int(env["GITHUB_API_TIMEOUT"] ?? "10") ?? 10,
            githubAPIRetries: Int(env["GITHUB_API_RETRIES"] ?? "3") ?? 3,
            debugMode: boolValue(env["DEBUG_MODE"], default: false)
        )
    }

    private static func boolValue(_ value: String?, default defaultValue: Bool) -> Bool {
        guard let value else { return defaultValue }
        return value.lowercased() == "true"
    }

    private static func parseEnv(_ content: String) -> [String: String] {
        var result: [String: String] = [:]

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip comments and empty lines
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            // Parse KEY=VALUE or KEY="VALUE"
            let parts = trimmed.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }

            let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
            var value = String(parts[1]).trimmingCharacters(in: .whitespaces)

            // Remove quotes if present
            if value.hasPrefix("\"") && value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }

            result[key] = value
        }

        return result
    }
}
