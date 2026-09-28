import XCTest
@testable import DiagnosticKit

final class EmailComposerTests: XCTestCase {
    // A note with every character that breaks a naive query string.
    private let composer = EmailComposer(
        to: "support@example.com",
        subject: "Spectr-Diagnostics-20260927-163513",
        body: "Hi,\n\nWhat happened:\nLogic & GarageBand can't see it = 100% + \"weird\"?\n",
        archive: URL(fileURLWithPath: "/tmp/x.zip"))

    private func query(_ url: URL) -> [String: String] {
        var out: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            out[item.name] = item.value
        }
        return out
    }

    func testGmailComposeCarriesEveryFieldIntact() throws {
        let url = try XCTUnwrap(composer.composeURL(.gmail))
        XCTAssertEqual(url.host, "mail.google.com")
        let q = query(url)
        XCTAssertEqual(q["view"], "cm")
        XCTAssertEqual(q["to"], "support@example.com")
        XCTAssertEqual(q["su"], "Spectr-Diagnostics-20260927-163513")
        XCTAssertEqual(q["body"], composer.body, url.absoluteString)
    }

    func testOutlookWebComposeCarriesEveryFieldIntact() throws {
        let url = try XCTUnwrap(composer.composeURL(.outlook))
        XCTAssertEqual(url.host, "outlook.office.com")
        let q = query(url)
        XCTAssertEqual(q["to"], "support@example.com")
        XCTAssertEqual(q["subject"], "Spectr-Diagnostics-20260927-163513")
        XCTAssertEqual(q["body"], composer.body, url.absoluteString)
    }

    /// A web compose form decodes a raw "+" as a space.
    func testPlusSurvivesWebCompose() throws {
        for client in [EmailComposer.Client.gmail, .outlook] {
            let url = try XCTUnwrap(composer.composeURL(client))
            let raw = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery)
            XCTAssertTrue(raw.contains("100%25%20%2B%20"), raw)
            XCTAssertFalse(raw.contains("+"), raw)
        }
    }

    func testMailtoAddressesSupportAndKeepsTheNote() throws {
        let url = try XCTUnwrap(composer.composeURL(.defaultApp(name: "Mail")))
        XCTAssertEqual(url.scheme, "mailto")
        XCTAssertTrue(url.absoluteString.hasPrefix("mailto:support@example.com?"), url.absoluteString)
        // A literal "&" or "=" in the note must not split the query.
        XCTAssertFalse(url.absoluteString.contains("Logic & "), url.absoluteString)
        XCTAssertFalse(url.absoluteString.contains("see it = "), url.absoluteString)
        XCTAssertEqual(query(url)["body"], composer.body)
    }
}
