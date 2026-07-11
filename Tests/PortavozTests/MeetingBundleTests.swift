import Foundation
import PortavozCore
import XCTest

@testable import IntegrationsKit

final class MeetingBundleTests: XCTestCase {
    private func sample() -> MeetingBundle {
        let meeting = Meeting(
            title: "Sprint Demo · Zephyr",
            startedAt: Date(timeIntervalSince1970: 1_783_695_600),
            endedAt: Date(timeIntervalSince1970: 1_783_698_120),
            language: "es",
            audioDirectory: "Audio/abc")
        let me = Speaker(meetingID: meeting.id, label: "Me", isMe: true)
        var marta = Speaker(meetingID: meeting.id, label: "S1")
        marta.displayName = "Marta"
        let segments = [
            TranscriptSegment(
                meetingID: meeting.id, speakerID: marta.id, channel: .system,
                text: "Arranquemos con Zephyr.", startTime: 0, endTime: 3, isFinal: true),
            TranscriptSegment(
                meetingID: meeting.id, speakerID: me.id, channel: .microphone,
                text: "Perfecto.", startTime: 3, endTime: 4, isFinal: true)
        ]
        let summary = SummaryDraft(
            meetingID: meeting.id, recipeID: Recipe.general.id, language: "es",
            markdown: "## Decisiones\n- Beta el lunes.",
            actionItems: [ActionItem(text: "Preparar demo", ownerSpeakerID: marta.id)])
        let note = ContextItem(
            meetingID: meeting.id, kind: .note, content: "congelar scope", timestamp: 12)
        return MeetingBundle(
            meeting: meeting, speakers: [me, marta], segments: segments,
            summary: summary, contextItems: [note])
    }

    func testRoundTripPreservesContent() throws {
        let bundle = sample()
        let decoded = try MeetingBundle.decode(try bundle.encoded())

        XCTAssertEqual(decoded.formatVersion, MeetingBundle.currentFormatVersion)
        XCTAssertEqual(decoded.meeting.title, "Sprint Demo · Zephyr")
        XCTAssertEqual(decoded.speakers.map(\.label), ["Me", "S1"])
        XCTAssertEqual(decoded.segments.count, 2)
        XCTAssertEqual(decoded.summary?.actionItems.first?.text, "Preparar demo")
        XCTAssertEqual(decoded.contextItems.first?.content, "congelar scope")
    }

    func testAudioPathNeverTravels() throws {
        let decoded = try MeetingBundle.decode(try sample().encoded())
        XCTAssertNil(decoded.meeting.audioDirectory, "machine-local paths must not travel (D4)")
    }

    func testFutureFormatVersionIsRejected() throws {
        var data = try sample().encoded()
        var json = try XCTUnwrap(String(data: data, encoding: .utf8))
        json = json.replacingOccurrences(
            of: "\"formatVersion\" : 1", with: "\"formatVersion\" : 99")
        data = Data(json.utf8)
        XCTAssertThrowsError(try MeetingBundle.decode(data)) { error in
            XCTAssertEqual(
                error as? MeetingBundle.BundleError, .unsupportedVersion(99))
        }
    }

    func testRemapMintsFreshIDsAndPreservesRelations() {
        let original = sample()
        let remapped = original.remappedForImport()

        XCTAssertNotEqual(remapped.meeting.id, original.meeting.id)
        XCTAssertTrue(remapped.speakers.allSatisfy { $0.meetingID == remapped.meeting.id })
        XCTAssertTrue(remapped.segments.allSatisfy { $0.meetingID == remapped.meeting.id })
        XCTAssertTrue(
            Set(remapped.speakers.map(\.id)).isDisjoint(with: original.speakers.map(\.id)))

        // Marta still owns her segment and her action item.
        let newMarta = remapped.speakers.first { $0.displayName == "Marta" }!
        XCTAssertEqual(remapped.segments[0].speakerID, newMarta.id)
        XCTAssertEqual(remapped.summary?.actionItems.first?.ownerSpeakerID, newMarta.id)
        // "Me" flag survives.
        XCTAssertTrue(remapped.speakers.contains { $0.isMe })
    }

    func testAudioAttachmentsRideAlongAndSurviveRemap() throws {
        var bundle = sample()
        bundle.audioFiles = [
            MeetingBundle.AudioAttachment(
                name: "system", fileExtension: "m4a", data: Data([0x01, 0x02, 0x03]))
        ]
        let decoded = try MeetingBundle.decode(try bundle.encoded())
        XCTAssertEqual(decoded.audioFiles?.count, 1)
        XCTAssertEqual(decoded.audioFiles?.first?.data, Data([0x01, 0x02, 0x03]))

        let remapped = decoded.remappedForImport()
        XCTAssertEqual(remapped.audioFiles?.first?.name, "system", "audio survives the remap")
    }

    func testTextOnlyFileDecodesWithoutAudioField() throws {
        // A pre-audio (0.3.0) file has no audioFiles key at all.
        var json = String(data: try sample().encoded(), encoding: .utf8)!
        XCTAssertFalse(json.contains("audioFiles"), "text-only export omits the field")
        let decoded = try MeetingBundle.decode(Data(json.utf8))
        XCTAssertNil(decoded.audioFiles)
    }

    func testImportingTwiceYieldsIndependentMeetings() {
        let bundle = sample()
        let first = bundle.remappedForImport()
        let second = bundle.remappedForImport()
        XCTAssertNotEqual(first.meeting.id, second.meeting.id)
        XCTAssertTrue(
            Set(first.segments.map(\.id)).isDisjoint(with: second.segments.map(\.id)))
    }
}
