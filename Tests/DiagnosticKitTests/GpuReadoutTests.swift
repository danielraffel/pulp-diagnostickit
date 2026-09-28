import XCTest
@testable import DiagnosticKit

final class GpuReadoutTests: XCTestCase {
    private func inspector() -> InstallInspector {
        InstallInspector(config: AppConfig.load()) { _, _, _ in ("", 0, false, nil) }
    }

    /// Lines as a Pulp build with start-up diagnostics prints them.
    private let healthy = """
    [pulp:info]  GpuSurface: adapter name="Apple M5 Max" vendor="apple" architecture="metal-3" description="Metal driver on macOS Version 26.6.2 (Build 25G83)" type=integrated backend=Metal null=false
    [pulp:info]  GpuSurface: startup_ms instance=0.8 adapter=0.8 device=0.8 surface=5.9 graphite=5.1 first_frame=59.0
    [pulp:info]  Standalone: frame_ms frames=59 p50=0.02 p95=0.02 max=26.16 over16=1 over33=0
    [pulp:info]  GpuDiagnostics: skia_bridge=installed skia_records=0 gpu_diagnostics_emitted=0 truncated=0 skia_text_suppressed=0
    """

    func testHealthyRunReadsEveryLineAndRaisesNothing() {
        var section = Section(markdown: "")
        let md = inspector().gpuReadout(healthy, into: &section)
        XCTAssertTrue(md.contains("**Apple M5 Max** (apple, metal-3, integrated, backend Metal)"), md)
        XCTAssertTrue(md.contains("first_frame 59.0"), md)
        XCTAssertTrue(md.contains("p95 0.02 ms"), md)
        XCTAssertTrue(md.contains("Skia log bridge: installed"), md)
        XCTAssertTrue(section.findings.isEmpty, "\(section.findings.map { $0.message })")
    }

    func testSoftwareAdapterSlowStartAndStutterAreFindings() {
        let log = healthy
            .replacingOccurrences(of: "type=integrated", with: "type=cpu")
            .replacingOccurrences(of: "first_frame=59.0", with: "first_frame=4200.0")
            .replacingOccurrences(of: "p95=0.02", with: "p95=48.50")
        var section = Section(markdown: "")
        _ = inspector().gpuReadout(log, into: &section)
        let messages = section.findings.map { $0.message }.joined(separator: "\n")
        XCTAssertTrue(messages.contains("software renderer"), messages)
        XCTAssertTrue(messages.contains("4.2 s"), messages)
        XCTAssertTrue(messages.contains("48.50 ms"), messages)
    }

    func testNullBackendAndDawnErrorAreProblems() {
        let log = healthy.replacingOccurrences(of: "null=false", with: "null=true")
            + "\n[pulp:error] Dawn uncaptured error: Validation error in CreateTexture"
        var section = Section(markdown: "")
        _ = inspector().gpuReadout(log, into: &section)
        XCTAssertEqual(section.findings.filter { $0.severity == .problem }.count, 2,
                       "\(section.findings.map { $0.message })")
    }

    /// A build that predates the diagnostics lines says so and invents nothing.
    func testOlderBuildWithoutLinesIsReportedNotFlagged() {
        // Real lines from a Pulp 0.873 standalone, including the "adapter offers"
        // line that shares the identity line's prefix.
        let old = """
        [pulp:info]  GpuSurface: created Metal surface from CAMetalLayer
        [pulp:info]  GpuSurface: adapter offers timestamp-query but GPU timing was not requested — keeping full device validation
        [pulp:info]  GpuSurface: backend_type=Metal
        [gpu-host] first frame: logical=990x645 gpu=1980x1290 scale=2.0
        """
        var section = Section(markdown: "")
        let md = inspector().gpuReadout(old, into: &section)
        XCTAssertTrue(md.contains("not logged by this build"), md)
        XCTAssertTrue(section.findings.isEmpty)
    }
}
