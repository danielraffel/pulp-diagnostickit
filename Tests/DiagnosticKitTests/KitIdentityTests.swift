import XCTest
@testable import DiagnosticKit

final class KitIdentityTests: XCTestCase {
    func testReadsTheThreeKeysBuildAppWrites() {
        let kit = KitIdentity.from(info: [
            "DiagnosticKitVersion": "1.1.0",
            "DiagnosticKitCommit": "0123456789abcdef0123456789abcdef01234567",
            "DiagnosticKitDirty": false,
        ])
        XCTAssertEqual(kit, KitIdentity(version: "1.1.0", commit: "0123456789abcdef0123456789abcdef01234567", dirty: false))
        XCTAssertEqual(kit.label, "1.1.0 (0123456789ab)")
    }

    func testDirtyBuildSaysSo() {
        let kit = KitIdentity.from(info: ["DiagnosticKitVersion": "1.1.0", "DiagnosticKitCommit": "abc", "DiagnosticKitDirty": true])
        XCTAssertEqual(kit.label, "1.1.0 (abc, modified)")
    }

    func testAnAppWithoutTheKeysIsUnknownNotBlank() {
        XCTAssertEqual(KitIdentity.from(info: [:]).label, "unknown (unknown)")
    }

    func testThePackagedVersionWinsOverTheEnvFile() {
        // A product's packaging restamps CFBundleShortVersionString after the
        // build; the report must name what was installed, not the .env value.
        XCTAssertEqual(AppConfig.resolveAppVersion(info: ["CFBundleShortVersionString": "1.0.6"],
                                                   env: ["APP_VERSION": "1.0.0"]), "1.0.6")
        XCTAssertEqual(AppConfig.resolveAppVersion(info: [:], env: ["APP_VERSION": "2.0.0"]), "2.0.0")
        XCTAssertEqual(AppConfig.resolveAppVersion(info: [:], env: [:]), "unknown")
    }
}
