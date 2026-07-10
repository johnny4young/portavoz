import CoreGraphics
import Foundation
import PortavozCore
import XCTest

@testable import IntegrationsKit

final class MeetingExporterTests: XCTestCase {
    private let meeting = MeetingID()

    private func fixture() -> (Meeting, [Speaker], [TranscriptSegment], SummaryDraft) {
        let record = Meeting(
            id: meeting,
            title: "Planning Q3",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_001_800)
        )
        let me = Speaker(meetingID: meeting, label: "Me", isMe: true)
        let ana = Speaker(meetingID: meeting, label: "S1", displayName: "Ana")
        let segments = [
            TranscriptSegment(
                meetingID: meeting, speakerID: me.id, channel: .microphone,
                text: "revisemos el roadmap", startTime: 0, endTime: 3, isFinal: true),
            TranscriptSegment(
                meetingID: meeting, speakerID: ana.id, channel: .system,
                text: "el deploy queda para el viernes", startTime: 65, endTime: 70, isFinal: true),
        ]
        let summary = SummaryDraft(
            meetingID: meeting, recipeID: "general", language: "es",
            markdown: "Summary corto.\n\n## Decisiones\n- Deploy el viernes",
            actionItems: [
                ActionItem(text: "preparar el deploy", ownerSpeakerID: ana.id),
                ActionItem(text: "ya hecho", isDone: true),
            ])
        return (record, [me, ana], segments, summary)
    }

    func testMarkdownContainsEverySection() {
        let (record, speakers, segments, summary) = fixture()
        let markdown = MeetingExporter.markdown(
            meeting: record, speakers: speakers, segments: segments,
            summary: summary, summaryVersion: 2)

        XCTAssertTrue(markdown.hasPrefix("# Planning Q3\n"))
        XCTAssertTrue(markdown.contains("30 min"))
        XCTAssertTrue(markdown.contains("2 speaker(s)"))
        XCTAssertTrue(markdown.contains("## Summary (v2 · es)"))
        // The summary's own h2 must be demoted to h3 under "## Summary".
        XCTAssertTrue(markdown.contains("### Decisiones"))
        XCTAssertFalse(markdown.contains("\n## Decisiones"))
        XCTAssertTrue(markdown.contains("- [ ] preparar el deploy — Ana"))
        XCTAssertTrue(markdown.contains("- [x] ya hecho"))
        XCTAssertTrue(markdown.contains("- **[00:00] Me:** revisemos el roadmap"))
        XCTAssertTrue(markdown.contains("- **[01:05] Ana:** el deploy queda para el viernes"))
    }

    func testSummaryCopyFormats() {
        let (_, speakers, _, _) = fixture()
        let ana = speakers[1]
        let summary = SummaryDraft(
            meetingID: meeting, recipeID: "general", language: "es",
            markdown: "Summary **corto**.\n\n## Decisiones\n- Deploy el viernes\n▸ Nota del usuario",
            actionItems: [ActionItem(text: "preparar el deploy", ownerSpeakerID: ana.id)])

        let markdown = MeetingExporter.summary(summary, speakers: speakers, format: .markdown)
        XCTAssertTrue(markdown.contains("## Decisiones"))
        XCTAssertTrue(markdown.contains("- Deploy el viernes"))
        XCTAssertTrue(markdown.contains("- [ ] preparar el deploy — Ana"))

        let slack = MeetingExporter.summary(summary, speakers: speakers, format: .slack)
        XCTAssertFalse(slack.contains("#"), "Slack mrkdwn no renderiza headings")
        XCTAssertTrue(slack.contains("*Decisiones*"), "heading → bold")
        XCTAssertTrue(slack.contains("Summary *corto*."), "**bold** → *bold*")
        XCTAssertTrue(slack.contains("• Deploy el viernes"))
        XCTAssertTrue(slack.contains("• Nota del usuario"), "coauthoring ▸ → bullet")
        XCTAssertTrue(slack.contains("• ☐ preparar el deploy — Ana"))

        let plain = MeetingExporter.summary(summary, speakers: speakers, format: .plainText)
        XCTAssertFalse(plain.contains("#"))
        XCTAssertFalse(plain.contains("*"))
        XCTAssertTrue(plain.contains("Summary corto."))
        XCTAssertTrue(plain.contains("Decisiones"))
        XCTAssertTrue(plain.contains("• Deploy el viernes"))
    }

    func testMarkdownWithoutSummarySkipsThatSection() {
        let (record, speakers, segments, _) = fixture()
        let markdown = MeetingExporter.markdown(
            meeting: record, speakers: speakers, segments: segments)
        XCTAssertFalse(markdown.contains("## Summary"))
        XCTAssertTrue(markdown.contains("## Transcript"))
    }

    func testPDFIsValidAndPaginates() throws {
        let (record, speakers, _, summary) = fixture()
        // Enough transcript to overflow one US Letter page.
        let many = (0..<200).map { index in
            TranscriptSegment(
                meetingID: meeting, speakerID: speakers[index % 2].id, channel: .system,
                text: "línea de transcript número \(index) con contenido suficiente para ocupar espacio",
                startTime: Double(index), endTime: Double(index) + 1, isFinal: true)
        }
        let markdown = MeetingExporter.markdown(
            meeting: record, speakers: speakers, segments: many, summary: summary)
        let data = try MeetingExporter.pdf(fromMarkdown: markdown)

        XCTAssertTrue(data.starts(with: Data("%PDF".utf8)))
        guard
            let provider = CGDataProvider(data: data as CFData),
            let document = CGPDFDocument(provider)
        else {
            return XCTFail("CGPDFDocument could not parse the export")
        }
        XCTAssertGreaterThan(document.numberOfPages, 1, "200 segments must paginate")
    }
}

final class GistPublisherTests: XCTestCase {
    func testRequestShape() throws {
        let request = try GistPublisher.request(
            markdown: "# hola", filename: "reunion.md",
            description: "Planning Q3", isPublic: false, token: "ghp_x")

        XCTAssertEqual(request.url?.absoluteString, "https://api.github.com/gists")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer ghp_x")

        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        XCTAssertEqual(body["public"] as? Bool, false)
        let files = body["files"] as! [String: [String: String]]
        XCTAssertEqual(files["reunion.md"]?["content"], "# hola")
    }

    func testParsesGistURL() throws {
        let payload = #"{"html_url": "https://gist.github.com/johnny/abc123", "id": "abc123"}"#
        let url = try GistPublisher.parseResponse(Data(payload.utf8))
        XCTAssertEqual(url.absoluteString, "https://gist.github.com/johnny/abc123")
    }

    func testRejectsMalformedResponse() {
        XCTAssertThrowsError(try GistPublisher.parseResponse(Data("{}".utf8)))
    }
}

final class IssueExporterTests: XCTestCase {
    private let item = ActionItem(text: "Preparar el rollback plan")

    func testGitHubRequestShape() throws {
        let request = try GitHubIssuesExporter.request(
            item: item, meetingTitle: "Planning Q3", ownerName: "Ana",
            repository: "johnny4young/portavoz", token: "ghp_x")

        XCTAssertEqual(
            request.url?.absoluteString,
            "https://api.github.com/repos/johnny4young/portavoz/issues")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer ghp_x")
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String]
        XCTAssertEqual(body["title"], "Preparar el rollback plan")
        XCTAssertTrue(body["body"]!.contains("Planning Q3"))
        XCTAssertTrue(body["body"]!.contains("Ana"))
    }

    func testGitHubParsesIssueURL() throws {
        let url = try GitHubIssuesExporter.parseResponse(
            Data(#"{"html_url": "https://github.com/o/r/issues/7", "number": 7}"#.utf8))
        XCTAssertEqual(url.absoluteString, "https://github.com/o/r/issues/7")
        XCTAssertThrowsError(try GitHubIssuesExporter.parseResponse(Data("{}".utf8)))
    }

    func testLinearRequestShape() throws {
        let request = try LinearExporter.request(
            item: item, meetingTitle: "Planning Q3", ownerName: nil,
            teamID: "TEAM-1", token: "lin_x")

        XCTAssertEqual(request.url?.absoluteString, "https://api.linear.app/graphql")
        // Linear keys go bare, not as Bearer.
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "lin_x")
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        XCTAssertTrue((body["query"] as! String).contains("issueCreate"))
        let input = ((body["variables"] as! [String: Any])["input"] as! [String: String])
        XCTAssertEqual(input["teamId"], "TEAM-1")
        XCTAssertEqual(input["title"], "Preparar el rollback plan")
    }

    func testLinearParsesIssueURLAndRejectsFailure() throws {
        let ok = #"{"data":{"issueCreate":{"success":true,"issue":{"url":"https://linear.app/t/issue/T-1"}}}}"#
        XCTAssertEqual(
            try LinearExporter.parseResponse(Data(ok.utf8)).absoluteString,
            "https://linear.app/t/issue/T-1")

        let failed = #"{"data":{"issueCreate":{"success":false,"issue":null}}}"#
        XCTAssertThrowsError(try LinearExporter.parseResponse(Data(failed.utf8)))
    }
}

final class SecretStoreTests: XCTestCase {
    /// Uses a throwaway service name so it never touches real tokens.
    private let service = "app.portavoz.tests.\(UUID().uuidString)"

    override func tearDown() {
        try? SecretStore.delete(service: service)
        super.tearDown()
    }

    func testRoundTripAndDelete() throws {
        do {
            try SecretStore.set("secreto-123", service: service)
        } catch {
            throw XCTSkip("keychain unavailable in this environment: \(error)")
        }
        XCTAssertEqual(try SecretStore.get(service: service), "secreto-123")

        // Overwrite replaces.
        try SecretStore.set("secreto-456", service: service)
        XCTAssertEqual(try SecretStore.get(service: service), "secreto-456")

        try SecretStore.delete(service: service)
        XCTAssertNil(try SecretStore.get(service: service))
    }
}

/// Exports append "## Pendientes" with the library's real done-state; the
/// snapshot's own "## Action Items" block must not ride along duplicated.
final class ExporterActionItemsDedupTests: XCTestCase {
    func testSnapshotActionItemsBlockIsReplacedByPendientes() {
        let markdown = """
            Overview text.

            ## Decisions
            - ship on Monday

            ## Action Items
            - [ ] own the rollout — S1
            """
        let stripped = MeetingExporter.removingActionItemsBlock(from: markdown)
        XCTAssertFalse(stripped.contains("## Action Items"))
        XCTAssertTrue(stripped.contains("## Decisions"))
        XCTAssertTrue(stripped.hasSuffix("- ship on Monday"))
    }

    func testMarkdownWithoutTheBlockIsUntouched() {
        let markdown = "Overview.\n\n## Decisions\n- a"
        XCTAssertEqual(MeetingExporter.removingActionItemsBlock(from: markdown), markdown)
    }
}
