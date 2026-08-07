import ApplicationKit
import Foundation
import PortavozCore
import XCTest

final class LocalSkillsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func proposal(
        _ definition: SkillDefinition,
        requesting: Set<SkillCapability>,
        arguments: [SkillArgument]
    ) -> SkillProposal {
        SkillProposal(
            definition: definition,
            requestedCapabilities: requesting,
            arguments: arguments,
            proposedAt: now)
    }

    // MARK: - The catalogue's own invariant

    /// The tier's whole promise. Asserted rather than assumed, because the
    /// catalogue is exactly where a future skill would quietly gain egress.
    func testEveryLocalSkillIsValidAndCannotLeaveTheMac() {
        XCTAssertTrue(LocalSkills.isEntirelyLocal)
        XCTAssertEqual(LocalSkills.definitions.count, 4)
        for definition in LocalSkills.definitions {
            XCTAssertTrue(definition.isValid, definition.id)
            XCTAssertFalse(definition.declaresExternalEffect, definition.id)
            XCTAssertFalse(
                definition.capabilities.contains(.sendRemote),
                definition.id)
        }
        XCTAssertEqual(
            Set(LocalSkills.definitions.map(\.id)).count,
            LocalSkills.definitions.count,
            "two skills sharing an id would share a receipt")
    }

    /// Exporting a file is irreversible, so a standing rule can never cover it
    /// even though the skill is local.
    func testOnlyReversibleSkillsCouldEverBeAutomated() {
        XCTAssertFalse(MeetingPackageExportSkill.definition.isReversible)
        XCTAssertTrue(RecapDraftSkill.definition.isReversible)
        XCTAssertTrue(ReminderDraftSkill.definition.isReversible)
        XCTAssertTrue(PreMeetingBriefSkill.definition.isReversible)

        let automated = SkillDefinition(
            id: MeetingPackageExportSkill.id,
            version: 1,
            capabilities: MeetingPackageExportSkill.definition.capabilities,
            confirmationPolicy: .standingRule)
        XCTAssertFalse(automated.isValid)
    }

    // MARK: - Idempotency keys identify one intended effect

    func testKeysDistinguishDifferentIntendedEffects() {
        let first = MeetingID()
        let second = MeetingID()
        XCTAssertNotEqual(
            RecapDraftSkill.idempotencyKey(for: first),
            RecapDraftSkill.idempotencyKey(for: second))
        XCTAssertEqual(
            RecapDraftSkill.idempotencyKey(for: first),
            RecapDraftSkill.idempotencyKey(for: first),
            "the same intent must claim the same slot")

        // The destination is part of the effect: the same meeting exported to
        // two folders is two different effects.
        XCTAssertNotEqual(
            MeetingPackageExportSkill.idempotencyKey(
                for: first, destination: "/a"),
            MeetingPackageExportSkill.idempotencyKey(
                for: first, destination: "/b"))

        // Different skills never collide even on the same subject.
        XCTAssertNotEqual(
            RecapDraftSkill.idempotencyKey(for: first),
            MeetingPackageExportSkill.idempotencyKey(
                for: first, destination: "/a"))

        // The key normalizes the destination exactly as the projection does,
        // so one intended write can never claim two slots.
        XCTAssertEqual(
            MeetingPackageExportSkill.idempotencyKey(
                for: first, destination: "  /a  "),
            MeetingPackageExportSkill.idempotencyKey(
                for: first, destination: "/a"))
        XCTAssertEqual(
            try MeetingPackageExportSkill.idempotencyKey(
                for: first,
                destination: MeetingPackageExportSkill.destination(from: [
                    .meeting(first), .text("  /a  "),
                ])),
            MeetingPackageExportSkill.idempotencyKey(
                for: first, destination: "  /a  "),
            "key and projection agree on the same argument")
    }

    // MARK: - Argument projection refuses rather than guesses

    func testRecapRequiresExactlyOneMeeting() throws {
        let meeting = MeetingID()
        XCTAssertEqual(
            try RecapDraftSkill.meeting(from: [
                .meeting(meeting), .text("ignored"),
            ]),
            meeting)

        for arguments in [
            [SkillArgument.text("no meeting")],
            [.meeting(MeetingID()), .meeting(MeetingID())],
        ] {
            XCTAssertThrowsError(
                try RecapDraftSkill.meeting(from: arguments)
            ) { error in
                XCTAssertEqual(
                    error as? RecapDraftError,
                    .missingMeeting,
                    "a recap of two meetings is not a recap")
            }
        }
    }

    func testPackageExportRequiresExactlyOneMeeting() {
        XCTAssertThrowsError(
            try MeetingPackageExportSkill.meeting(from: [
                .meeting(MeetingID()), .meeting(MeetingID()),
            ])
        ) { error in
            XCTAssertEqual(
                error as? MeetingPackageExportError, .missingMeeting)
        }
    }

    /// The key claims "this meeting, to this destination". The claim only holds
    /// if the destination is in the proposal — otherwise two keys that differ
    /// would name one write, and one confirmation would authorise a path the
    /// user never saw.
    func testPackageExportRequiresTheDestinationItsKeyIsScopedBy() {
        XCTAssertEqual(
            try MeetingPackageExportSkill.destination(from: [
                .meeting(MeetingID()), .text("  /Users/me/Desktop  "),
            ]),
            "/Users/me/Desktop",
            "the destination is trimmed exactly once, here")

        for arguments in [
            [SkillArgument.meeting(MeetingID())],
            [.meeting(MeetingID()), .text("/a"), .text("/b")],
            [.meeting(MeetingID()), .text("   ")],
        ] {
            XCTAssertThrowsError(
                try MeetingPackageExportSkill.destination(from: arguments)
            ) { error in
                XCTAssertEqual(
                    error as? MeetingPackageExportError, .missingDestination)
            }
        }
    }

    // MARK: - Effects delegate; they do not reimplement

    func testPackageExportWritesTextOnlyBytesToTheConfirmedDestination() async throws {
        let meeting = MeetingID()
        let writer = RecordingPackageWriter()
        let source = StubBundleExport()
        let effect = MeetingPackageExportEffect(
            export: ExportMeetingBundle(
                store: source, files: source, documents: source),
            destination: writer)

        try await effect.perform(proposal(
            MeetingPackageExportSkill.definition,
            requesting: [.readMeetingMaterial, .writeLocalFile],
            arguments: [.meeting(meeting), .text("/Users/me/Desktop")]))

        let writes = await writer.writes
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes.first?.meetingID, meeting)
        XCTAssertEqual(
            writes.first?.destination,
            "/Users/me/Desktop",
            "the bytes land where the confirmed key said they would")
        let requested = await source.requests
        XCTAssertEqual(requested.map(\.includeAudio), [false],
            "one confirmation must not move far more than was previewed")
    }

    func testPackageExportWritesNothingWhenTheExportFails() async {
        let writer = RecordingPackageWriter()
        let source = StubBundleExport(content: nil)
        let effect = MeetingPackageExportEffect(
            export: ExportMeetingBundle(
                store: source, files: source, documents: source),
            destination: writer)

        do {
            try await effect.perform(proposal(
                MeetingPackageExportSkill.definition,
                requesting: [.readMeetingMaterial, .writeLocalFile],
                arguments: [.meeting(MeetingID()), .text("/tmp/out")]))
            XCTFail("an export with no content cannot be written")
        } catch {}

        let writes = await writer.writes
        XCTAssertTrue(writes.isEmpty, "a failed export leaves no partial file")
    }

    func testBriefEffectDeliversForTheOneResolvedEvent() async throws {
        let events = StubUpcomingEvents(identifier: "event-42")
        let delivery = RecordingBriefDelivery()
        let effect = PreMeetingBriefEffect(
            events: events,
            brief: PrepareMeetingBrief(
                ask: AskMeetings(
                    retrieval: EmptyBriefRetrieval(),
                    answering: EmptyBriefAnswering()),
                library: EmptyBriefLibrary(),
                synthesizer: EmptyBriefSynthesizer()),
            delivery: delivery)

        try await effect.perform(proposal(
            PreMeetingBriefSkill.definition,
            requesting: [.readMeetingMaterial, .writeLocalDraft],
            arguments: [.text("event-42")]))

        let delivered = await delivery.briefs
        XCTAssertEqual(delivered.map(\.event.title), ["Platform sync"])
    }

    /// An unresolved or ambiguous event must refuse, never brief on a guess:
    /// the brief names a meeting to the user, and briefing the wrong one is
    /// worse than briefing none.
    func testBriefEffectRefusesRatherThanGuessingTheEvent() async {
        let events = StubUpcomingEvents(identifier: "event-42")
        let delivery = RecordingBriefDelivery()
        let effect = PreMeetingBriefEffect(
            events: events,
            brief: PrepareMeetingBrief(
                ask: AskMeetings(
                    retrieval: EmptyBriefRetrieval(),
                    answering: EmptyBriefAnswering()),
                library: EmptyBriefLibrary(),
                synthesizer: EmptyBriefSynthesizer()),
            delivery: delivery)

        for arguments: [SkillArgument] in [
            [.text("event-42"), .text("event-43")],
            [.meeting(MeetingID())],
            [.text("no-such-event")],
        ] {
            do {
                try await effect.perform(proposal(
                    PreMeetingBriefSkill.definition,
                    requesting: [.readMeetingMaterial, .writeLocalDraft],
                    arguments: arguments))
                XCTFail("must not brief on \(arguments)")
            } catch {
                XCTAssertEqual(error as? PreMeetingBriefError, .missingEvent)
            }
        }
        let delivered = await delivery.briefs
        XCTAssertTrue(delivered.isEmpty)
    }

    func testRecapEffectComposesThroughTheExistingComposer() async throws {
        let meeting = Meeting(
            title: "Platform sync",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let speaker = Speaker(meetingID: meeting.id, label: "Me", isMe: true)
        let summary = SummaryDraft(
            meetingID: meeting.id,
            recipeID: "general",
            language: "en",
            markdown: "## Decisions\n\n- Ship the signed export.",
            actionItems: [])
        let delivery = RecordingRecapDelivery()
        let effect = RecapDraftEffect(
            material: StubRecapMaterial(
                meeting: meeting, speakers: [speaker], summary: summary),
            delivery: delivery)

        try await effect.perform(proposal(
            RecapDraftSkill.definition,
            requesting: [.readMeetingMaterial, .writeLocalDraft],
            arguments: [.meeting(meeting.id)]))

        let delivered = await delivery.recaps
        XCTAssertEqual(delivered.count, 1)
        let expected = RecapComposer.compose(
            meeting: meeting, speakers: [speaker], summary: summary)
        XCTAssertEqual(
            delivered.first?.markdown,
            expected.markdown,
            "the composer stays the only place deciding recap text")
        XCTAssertEqual(delivered.first?.subject, expected.subject)
    }

    func testRecapEffectFailsDegradablyWithoutASummary() async {
        let delivery = RecordingRecapDelivery()
        let effect = RecapDraftEffect(
            material: StubRecapMaterial(meeting: nil, speakers: [], summary: nil),
            delivery: delivery)

        do {
            try await effect.perform(proposal(
                RecapDraftSkill.definition,
                requesting: [.readMeetingMaterial, .writeLocalDraft],
                arguments: [.meeting(MeetingID())]))
            XCTFail("a meeting with no summary cannot be recapped")
        } catch {
            XCTAssertEqual(error as? RecapDraftError, .noSummaryToRecap)
            XCTAssertEqual(
                (error as? CategorizedFailure)?.category,
                .degradable,
                "a missing summary is not a critical failure")
        }
        let delivered = await delivery.recaps
        XCTAssertTrue(delivered.isEmpty)
    }
}

private struct StubRecapMaterial: RecapMaterialReading {
    let meeting: Meeting?
    let speakers: [Speaker]
    let summary: SummaryDraft?

    func recapMaterial(
        for meetingID: MeetingID
    ) async throws -> (meeting: Meeting, speakers: [Speaker], summary: SummaryDraft)? {
        guard let meeting, let summary else { return nil }
        return (meeting, speakers, summary)
    }
}

private actor RecordingRecapDelivery: RecapDraftDelivering {
    private(set) var recaps: [MeetingRecap] = []

    func deliver(_ recap: MeetingRecap) {
        recaps.append(recap)
    }
}

// MARK: - Package export doubles

private actor RecordingPackageWriter: MeetingPackageWriting {
    private(set) var writes: [(meetingID: MeetingID, destination: String)] = []

    func write(_ package: Data, for meetingID: MeetingID, to destination: String) {
        writes.append((meetingID, destination))
    }
}

private enum LocalSkillFakeError: Error { case expected }

private actor StubBundleExport:
    ExportMeetingBundleStore,
    ExportMeetingBundleFiles,
    ExportMeetingBundleDocuments {
    private let content: ExportMeetingBundleContent?
    private(set) var requests: [ExportMeetingBundleRequest] = []

    init(content: ExportMeetingBundleContent? = .stub) {
        self.content = content
    }

    func meetingBundleExportContent(
        for meetingID: MeetingID
    ) throws -> ExportMeetingBundleContent? {
        requests.append(ExportMeetingBundleRequest(
            meetingID: meetingID,
            includeAudio: content?.meeting.audioDirectory != nil))
        return content
    }

    func readBundleAudio(
        from relativeDirectory: String
    ) -> [ExportMeetingBundleAttachment] { [] }

    func encodeMeetingBundle(_ document: ExportMeetingBundleDocument) -> Data {
        Data("encoded-portavoz".utf8)
    }
}

extension ExportMeetingBundleContent {
    fileprivate static var stub: ExportMeetingBundleContent {
        ExportMeetingBundleContent(
            meeting: Meeting(
                title: "Platform sync",
                startedAt: Date(timeIntervalSince1970: 1_700_000_000)),
            speakers: [],
            segments: [],
            summary: nil,
            contextItems: [],
            companionCards: [])
    }
}

// MARK: - Pre-meeting brief doubles

private struct StubUpcomingEvents: UpcomingEventResolving {
    let identifier: String

    func upcomingEvent(matching candidate: String) async throws -> UpcomingEvent? {
        guard candidate == identifier else { return nil }
        return UpcomingEvent(
            title: "Platform sync",
            startDate: Date(timeIntervalSince1970: 1_789_000_000),
            attendees: ["Ana"])
    }
}

private actor RecordingBriefDelivery: MeetingBriefDelivering {
    private(set) var briefs: [MeetingBrief] = []

    func deliver(_ brief: MeetingBrief) {
        briefs.append(brief)
    }
}

private struct EmptyBriefRetrieval: AskMeetingRetrieving {
    func search(query: String, limit: Int) async throws -> [AskSearchResult] { [] }
    func retrieve(question: String, limit: Int) async throws -> [AskCitation] { [] }
}

private struct EmptyBriefAnswering: AskMeetingAnswering {
    func answer(question: String, citations: [AskCitation]) async throws -> String? {
        nil
    }
}

private struct EmptyBriefLibrary: MeetingBriefLibraryReading {
    func meetingBriefSummaryMarkdowns(
        for meetingIDs: [MeetingID]
    ) async throws -> [MeetingID: String] { [:] }

    func openMeetingBriefItems(limit: Int) async throws -> [MeetingBrief.OpenItem] {
        []
    }
}

private struct EmptyBriefSynthesizer: MeetingBriefSynthesizing {
    func synthesizeMeetingBrief(
        eventTitle: String,
        sources: [MeetingBrief.SynthesisSource]
    ) async throws -> [MeetingBrief.SynthesisPoint] { [] }
}
