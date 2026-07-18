import Foundation
import PortavozCore
import XCTest

@testable import ApplicationKit

final class SuggestMeetingSpeakerNamesTests: XCTestCase {
    func testCoordinatesOneMeetingSnapshotAndVerifiesEveryProposal() async throws {
        let fixture = SpeakerNameFixture()
        let reader = SpeakerNameLibraryReader(detail: fixture.detail)
        let candidates = SpeakerNameCandidates(names: ["Pedro Gómez"])
        let proposer = SpeakerNameProposer(proposals: [
            .init(label: "S1", name: "Carolina"),
            .init(label: "S2", name: "Pedro"),
            .init(label: "S3", name: "Ignored"),
            .init(label: "Me", name: "Carolina"),
            .init(label: "S9", name: "Fabricated"),
        ])
        let useCase = SuggestMeetingSpeakerNames(
            library: QueryMeetingLibrary(reader: reader),
            candidates: candidates,
            proposer: proposer)

        let suggestions = try await useCase.execute(.init(meetingID: fixture.meeting.id))

        XCTAssertEqual(suggestions.map(\.label), ["S1", "S2"])
        XCTAssertEqual(suggestions.map(\.name), ["Carolina", "Pedro"])
        XCTAssertEqual(suggestions.map(\.evidence), [
            .transcript("Hola, soy Carolina."),
            .calendarCandidate("Pedro Gómez"),
        ])
        let detailRequests = await reader.detailRequests
        let requestedDates = await candidates.requestedDates
        XCTAssertEqual(detailRequests, [fixture.meeting.id])
        XCTAssertEqual(requestedDates, [fixture.meeting.startedAt])
        let calls = await proposer.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.attendees, ["Pedro Gómez"])
        XCTAssertEqual(calls.first?.speakers.map(\.label), ["Me", "S1", "S2", "S3"])
        XCTAssertEqual(calls.first?.segments.map(\.text), ["Hola, soy Carolina."])
    }

    func testNoUnnamedRemoteSpeakerSkipsCalendarAndGeneration() async throws {
        let fixture = SpeakerNameFixture(allRemoteSpeakersNamed: true)
        let candidates = SpeakerNameCandidates(names: ["Pedro"])
        let proposer = SpeakerNameProposer(proposals: [])
        let useCase = SuggestMeetingSpeakerNames(
            library: QueryMeetingLibrary(reader: SpeakerNameLibraryReader(detail: fixture.detail)),
            candidates: candidates,
            proposer: proposer)

        let suggestions = try await useCase.execute(.init(meetingID: fixture.meeting.id))

        XCTAssertTrue(suggestions.isEmpty)
        let requestedDates = await candidates.requestedDates
        let calls = await proposer.calls
        XCTAssertTrue(requestedDates.isEmpty)
        XCTAssertTrue(calls.isEmpty)
    }

    func testMissingMeetingIsTypedAndSkipsCapabilities() async {
        let candidates = SpeakerNameCandidates(names: [])
        let proposer = SpeakerNameProposer(proposals: [])
        let useCase = SuggestMeetingSpeakerNames(
            library: QueryMeetingLibrary(reader: SpeakerNameLibraryReader(detail: nil)),
            candidates: candidates,
            proposer: proposer)

        do {
            _ = try await useCase.execute(.init(meetingID: MeetingID()))
            XCTFail("a missing meeting must stop before calendar or generation")
        } catch {
            XCTAssertEqual(error as? SuggestMeetingSpeakerNamesError, .meetingNotFound)
        }
        let requestedDates = await candidates.requestedDates
        let calls = await proposer.calls
        XCTAssertTrue(requestedDates.isEmpty)
        XCTAssertTrue(calls.isEmpty)
    }

    func testGenerationFailurePropagatesWithoutReturningUnverifiedNames() async {
        let fixture = SpeakerNameFixture()
        let proposer = SpeakerNameProposer(
            proposals: [.init(label: "S1", name: "Carolina")],
            error: SpeakerNameTestError.generation)
        let useCase = SuggestMeetingSpeakerNames(
            library: QueryMeetingLibrary(reader: SpeakerNameLibraryReader(detail: fixture.detail)),
            candidates: SpeakerNameCandidates(names: []),
            proposer: proposer)

        do {
            _ = try await useCase.execute(.init(meetingID: fixture.meeting.id))
            XCTFail("generation failure must stay visible")
        } catch {
            XCTAssertEqual(error as? SpeakerNameTestError, .generation)
        }
    }

    func testVerificationNormalizesNamesRejectsSubstringsAndDeduplicatesLabels() {
        let proposals = [
            MeetingNameProposal(label: " S1 ", name: "  ANA  "),
            MeetingNameProposal(label: "S2", name: "Gómez"),
            MeetingNameProposal(label: "S2", name: "Pedro"),
            MeetingNameProposal(label: "S3", name: "Lysis"),
            MeetingNameProposal(label: "S4", name: "Ped"),
        ]

        let verified = SuggestMeetingSpeakerNames.verified(
            proposals,
            transcriptLines: ["Ana confirmó el plan.", "The analysis is complete."],
            unnamedLabels: ["S1", "S2", "S3", "S4"],
            attendeeCandidates: ["Pedro Gómez"])

        XCTAssertEqual(verified.map(\.label), ["S1", "S2"])
        XCTAssertEqual(verified.map(\.name), ["ANA", "Gómez"])
        XCTAssertEqual(verified.map(\.evidence), [
            .transcript("Ana confirmó el plan."),
            .calendarCandidate("Pedro Gómez"),
        ])
    }
}

private struct SpeakerNameFixture {
    let meeting: Meeting
    let detail: MeetingLibraryDetail

    init(allRemoteSpeakersNamed: Bool = false) {
        let meeting = Meeting(title: "Planning", startedAt: Date(timeIntervalSince1970: 1_000))
        let me = Speaker(meetingID: meeting.id, label: "Me", isMe: true)
        let carolina = Speaker(
            meetingID: meeting.id,
            label: "S1",
            displayName: allRemoteSpeakersNamed ? "Carolina" : nil)
        let pedro = Speaker(
            meetingID: meeting.id,
            label: "S2",
            displayName: allRemoteSpeakersNamed ? "Pedro" : nil)
        let named = Speaker(meetingID: meeting.id, label: "S3", displayName: "Named")
        let segment = TranscriptSegment(
            meetingID: meeting.id,
            speakerID: carolina.id,
            channel: .system,
            text: "Hola, soy Carolina.",
            startTime: 0,
            endTime: 2,
            isFinal: true)
        self.meeting = meeting
        detail = MeetingLibraryDetail(
            meeting: meeting,
            speakers: [me, carolina, pedro, named],
            segments: [segment],
            summary: nil,
            summaryVersion: nil)
    }
}

private actor SpeakerNameLibraryReader: MeetingLibraryQueryReading {
    let detail: MeetingLibraryDetail?
    private(set) var detailRequests: [MeetingID] = []

    init(detail: MeetingLibraryDetail?) {
        self.detail = detail
    }

    func meetingLibraryMeetings(limit: Int?) async throws -> [Meeting] { [] }

    func meetingLibraryDetail(_ id: MeetingID) async throws -> MeetingLibraryDetail? {
        detailRequests.append(id)
        return detail
    }

    func meetingLibrarySearch(
        _ query: String,
        limit: Int
    ) async throws -> [LibrarySearchHit] { [] }

    func meetingLibraryOpenItems(limit: Int) async throws -> [LibraryOpenItem] { [] }
}

private actor SpeakerNameCandidates: MeetingNameCandidateProviding {
    let names: [String]
    private(set) var requestedDates: [Date] = []

    init(names: [String]) {
        self.names = names
    }

    func names(around date: Date) async -> [String] {
        requestedDates.append(date)
        return names
    }
}

private actor SpeakerNameProposer: MeetingSpeakerNameProposing {
    struct Call: Sendable {
        let segments: [TranscriptSegment]
        let speakers: [Speaker]
        let attendees: [String]
    }

    let proposals: [MeetingNameProposal]
    let error: SpeakerNameTestError?
    private(set) var calls: [Call] = []

    init(
        proposals: [MeetingNameProposal],
        error: SpeakerNameTestError? = nil
    ) {
        self.proposals = proposals
        self.error = error
    }

    func proposeNames(
        segments: [TranscriptSegment],
        speakers: [Speaker],
        attendeeCandidates: [String]
    ) async throws -> [MeetingNameProposal] {
        calls.append(Call(
            segments: segments,
            speakers: speakers,
            attendees: attendeeCandidates))
        if let error { throw error }
        return proposals
    }
}

private enum SpeakerNameTestError: Error {
    case generation
}
