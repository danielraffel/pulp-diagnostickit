import XCTest
@testable import DiagnosticKit

final class SupportSenderTests: XCTestCase {
    func testBodyCarriesEveryFieldAndTheExactArchiveBytes() {
        let archive = Data([0x50, 0x4B, 0x03, 0x04, 0x00, 0xFF])
        let body = SupportSender.body(boundary: "B", product: "Spectr", summary: Data("{\"findings\":[]}".utf8),
                                      note: "Logic can't see it", archiveName: "Spectr-Diagnostics-1.zip", archive: archive)
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("name=\"product\"\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nSpectr\r\n"), text)
        XCTAssertTrue(text.contains("name=\"note\"\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nLogic can't see it\r\n"), text)
        XCTAssertTrue(text.contains("name=\"archive\"; filename=\"Spectr-Diagnostics-1.zip\""), text)
        XCTAssertTrue(text.hasSuffix("--B--\r\n"))
        XCTAssertNotNil(body.range(of: archive), "archive bytes must be carried unchanged")
    }

    func testOnlyPassingFailuresAreRetried() {
        XCTAssertTrue(SupportSender.isTransient(URLError(.notConnectedToInternet)))
        XCTAssertTrue(SupportSender.isTransient(URLError(.timedOut)))
        XCTAssertTrue(SupportSender.isTransient(SupportSender.Failure.rejected(502, "")))
        XCTAssertTrue(SupportSender.isTransient(SupportSender.Failure.rejected(429, "")))
        XCTAssertFalse(SupportSender.isTransient(SupportSender.Failure.rejected(401, "")))
        XCTAssertFalse(SupportSender.isTransient(SupportSender.Failure.rejected(413, "")))
        XCTAssertFalse(SupportSender.isTransient(SupportSender.Failure.notConfigured))
    }

    func testMessagesAreInPlainWords() {
        XCTAssertTrue(SupportSender.userMessage(for: URLError(.notConnectedToInternet)).contains("connected to the internet"))
        XCTAssertTrue(SupportSender.userMessage(for: SupportSender.Failure.rejected(401, "unauthorized")).contains("updated build"))
        XCTAssertTrue(SupportSender.userMessage(for: SupportSender.Failure.rejected(413, "")).contains("too large"))
        XCTAssertTrue(SupportSender.userMessage(for: SupportSender.Failure.rejected(502, "could not send: x")).contains("could not send: x"))
    }

    func testUnconfiguredBuildDoesNotTry() async {
        let sender = SupportSender(endpoint: "", key: "", timeout: 1)
        do {
            _ = try await sender.send(archive: URL(fileURLWithPath: "/nonexistent.zip"), product: "P", summary: Data(), note: "")
            XCTFail("expected notConfigured")
        } catch SupportSender.Failure.notConfigured {
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}
