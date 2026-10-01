import Foundation

/// Which DiagnosticKit build produced this app.
///
/// A product ships the app under its own version (CFBundleShortVersionString),
/// so that number says nothing about the kit's code. Scripts/build_app.sh
/// records the kit's own version (the repository's VERSION file), the exact
/// commit and whether the checkout had uncommitted changes in three
/// Info.plist keys. Every report and uploaded summary carries them, so a
/// report can always be traced to the source that built it.
struct KitIdentity: Equatable {
    static let versionKey = "DiagnosticKitVersion"
    static let commitKey = "DiagnosticKitCommit"
    static let dirtyKey = "DiagnosticKitDirty"

    let version: String
    let commit: String
    let dirty: Bool

    static let unknown = KitIdentity(version: "unknown", commit: "unknown", dirty: false)

    static var current: KitIdentity { from(info: Bundle.main.infoDictionary ?? [:]) }

    static func from(info: [String: Any]) -> KitIdentity {
        let version = (info[versionKey] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
        let commit = (info[commitKey] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
        let dirty: Bool
        switch info[dirtyKey] {
        case let value as Bool: dirty = value
        case let value as String: dirty = value.lowercased() == "true"
        default: dirty = false
        }
        return KitIdentity(version: version, commit: commit, dirty: dirty)
    }

    /// "1.1.0 (3f2a9c1d04e7)", with ", modified" when built from a dirty tree.
    var label: String {
        let short = commit == "unknown" ? commit : String(commit.prefix(12))
        return "\(version) (\(short)\(dirty ? ", modified" : ""))"
    }

    var summary: [String: Any] { ["version": version, "commit": commit, "dirty": dirty] }
}
