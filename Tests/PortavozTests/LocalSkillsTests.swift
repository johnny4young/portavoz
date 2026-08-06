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

    // MARK: - Effects delegate; they do not reimplement

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
