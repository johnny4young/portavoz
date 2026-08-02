import Foundation
import GRDB
import IntegrationsKit
import PortavozCore
import XCTest

@testable import StorageKit

final class MeetingSyncAggregateTests: XCTestCase {
    func testEnvelopeRequiresNewestGenerationAndStripsDeviceLocalState() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(
            title: "Portable",
            startedAt: Date(timeIntervalSince1970: 100),
            audioDirectory: "Audio/local-only")
        try await store.save(meeting)
        let initialPending = try await store.pendingMeetingSyncChanges()
        let stale = try XCTUnwrap(initialPending.first)

        let speaker = Speaker(
            meetingID: meeting.id,
            label: "S1",
            displayName: "Ana")
        let segment = TranscriptSegment(
            meetingID: meeting.id,
            speakerID: speaker.id,
            channel: .system,
            text: "Ship the sync seam.",
            language: "en",
            startTime: 0,
            endTime: 2,
            isFinal: true)
        try await store.save([speaker])
        try await store.save([segment])
        try await installDeviceLocalDerivations(
            store: store,
            speakerID: speaker.id,
            segmentID: segment.id)

        await XCTAssertMeetingSyncThrowsAsync {
            _ = try await store.meetingSyncEnvelope(
                for: stale,
                sourceDeviceID: self.deviceID)
        }

        let envelope = try await latestEnvelope(in: store)
        guard case .upsert(let aggregate) = envelope.mutation else {
            return XCTFail("Expected a live aggregate")
        }

        XCTAssertEqual(envelope.meetingID, meeting.id)
        XCTAssertNil(aggregate.meeting.value.audioDirectory)
        XCTAssertNil(try XCTUnwrap(aggregate.speakers.first).value.personID)
        XCTAssertEqual(aggregate.segments.map(\.value.text), ["Ship the sync seam."])

        let encoded = try MeetingSyncEnvelopeCodec.encode(envelope)
        let decoded = try MeetingSyncEnvelopeCodec.decode(encoded)
        let reencoded = try MeetingSyncEnvelopeCodec.encode(decoded)
        XCTAssertEqual(encoded, reencoded)
        XCTAssertEqual(decoded.meetingID, envelope.meetingID)
        XCTAssertEqual(decoded.generation, envelope.generation)
        XCTAssertEqual(decoded.sourceDeviceID, deviceID)
        XCTAssertEqual(MeetingSyncEnvelopeCodec.sha256(encoded).count, 64)
        let json = String(decoding: encoded, as: UTF8.self)
        for forbidden in [
            "Audio/local-only", "personID", "embedding",
            "embeddingFingerprint", "generationRunID",
        ] {
            XCTAssertFalse(json.contains(forbidden), "sync envelope leaked \(forbidden)")
        }
    }

    func testRemoteAggregateRoundTripPreservesPortableHistoryAndSettlesEcho() async throws {
        let source = try MeetingStore.inMemory()
        let seed = try await seedMeeting(in: source)
        let envelope = try await latestEnvelope(in: source)
        let transported = try MeetingSyncEnvelopeCodec.decode(
            MeetingSyncEnvelopeCodec.encode(envelope))
        let destination = try MeetingStore.inMemory()

        let result = try await destination.applyRemoteMeetingSyncEnvelope(transported)

        XCTAssertEqual(result, .applied)
        let storedDetail = try await destination.detail(seed.meeting.id)
        let detail = try XCTUnwrap(storedDetail)
        XCTAssertEqual(detail.meeting.title, seed.meeting.title)
        XCTAssertNil(detail.meeting.audioDirectory)
        XCTAssertEqual(detail.speakers.map(\.displayName), ["Ana"])
        XCTAssertEqual(detail.segments.map(\.text), ["Hola", "Hello"])
        XCTAssertEqual(detail.summaries.map(\.version), [2, 1])
        let newestSnapshot = try await destination.summary(seed.meeting.id)
        let newest = try XCTUnwrap(newestSnapshot?.draft)
        XCTAssertEqual(newest.claims.first?.feedback?.kind, .unsupported)
        XCTAssertEqual(newest.claims.first?.evidenceSegmentIDs, [seed.segments[0].id])
        XCTAssertEqual(
            newest.decisionEvidence.first?.evidenceSegmentIDs,
            [seed.segments[1].id])
        XCTAssertEqual(
            newest.actionItemEvidence.first?.actionItemID,
            newest.actionItems.first?.id)
        XCTAssertEqual(
            newest.actionItemEvidence.first?.evidenceSegmentIDs,
            [seed.segments[1].id])
        let contextItems = try await destination.contextItems(for: seed.meeting.id)
        XCTAssertEqual(contextItems.map(\.content), ["Keep every language"])
        let cards = try await destination.companionCards(for: seed.meeting.id)
        XCTAssertEqual(cards.map(\.question), ["What should remain?"])
        XCTAssertEqual(cards.first?.evidence?.questionSegmentIDs, [seed.segments[1].id])
        let pending = try await destination.pendingMeetingSyncChanges()
        XCTAssertTrue(pending.isEmpty)

        let replay = try await destination.applyRemoteMeetingSyncEnvelope(transported)
        let replayPending = try await destination.pendingMeetingSyncChanges()
        let replayedDetail = try await destination.detail(seed.meeting.id)

        XCTAssertEqual(replay, .applied)
        XCTAssertTrue(replayPending.isEmpty)
        XCTAssertEqual(replayedDetail?.segments.map(\.text), ["Hola", "Hello"])
    }

    func testRemoteRefreshPreservesLocalPathsPeopleAndDerivedSegmentState() async throws {
        let source = try MeetingStore.inMemory()
        let seed = try await seedMeeting(in: source)
        let destination = try MeetingStore.inMemory()
        _ = try await destination.applyRemoteMeetingSyncEnvelope(latestEnvelope(in: source))
        try await installDeviceLocalDerivations(
            store: destination,
            speakerID: seed.speaker.id,
            segmentID: seed.segments[0].id)
        try await destination.database.write { db in
            try db.execute(
                sql: "UPDATE meeting SET audioDirectory = ? WHERE id = ?",
                arguments: ["Audio/on-this-device", seed.meeting.id.rawValue.uuidString])
        }

        var renamed = seed.meeting
        renamed.title = "Portable — refreshed"
        try await source.save(renamed)
        let refresh = try await latestEnvelope(in: source)
        let refreshResult = try await destination.applyRemoteMeetingSyncEnvelope(refresh)
        XCTAssertEqual(refreshResult, .applied)

        let stored = try await destination.database.read { db -> (
            MeetingRecord, SpeakerRecord, SegmentRecord
        ) in
            (
                try XCTUnwrap(MeetingRecord.fetchOne(
                    db,
                    key: seed.meeting.id.rawValue.uuidString)),
                try XCTUnwrap(SpeakerRecord.fetchOne(
                    db,
                    key: seed.speaker.id.rawValue.uuidString)),
                try XCTUnwrap(SegmentRecord.fetchOne(
                    db,
                    key: seed.segments[0].id.uuidString))
            )
        }
        XCTAssertEqual(stored.0.audioDirectory, "Audio/on-this-device")
        XCTAssertNotNil(stored.1.personID)
        XCTAssertEqual(stored.2.embedding, Data([1, 2, 3, 4]))
        XCTAssertEqual(stored.2.embeddingFingerprint, "local-semantic-profile")
        XCTAssertEqual(try stored.0.meeting.title, "Portable — refreshed")
        let pending = try await destination.pendingMeetingSyncChanges()
        XCTAssertTrue(pending.isEmpty)
    }

    func testCorrectionHistoryRoundTripsAndTombstoneConverges() async throws {
        let source = try MeetingStore.inMemory()
        let seed = try await seedMeeting(in: source)
        let correction = correctionEvent(
            id: "00000000-0000-4000-9000-000000000101",
            seed: seed,
            kind: .replaceText(text: "Hola corregida", language: "es"))
        _ = try await source.appendTranscriptCorrection(correction)
        let destination = try MeetingStore.inMemory()

        let firstEnvelope = try await latestEnvelope(in: source)
        guard case .upsert(let firstAggregate) = firstEnvelope.mutation else {
            return XCTFail("Expected a live aggregate")
        }
        XCTAssertEqual(firstAggregate.formatVersion, 2)
        XCTAssertEqual(firstAggregate.transcriptCorrections, [correction])
        let firstResult = try await destination.applyRemoteMeetingSyncEnvelope(
            firstEnvelope)
        XCTAssertEqual(firstResult, .applied)
        var destinationHistory = try await destination.transcriptCorrectionHistory(
            for: seed.meeting.id)
        XCTAssertEqual(destinationHistory, [correction])
        var destinationPending = try await destination.pendingMeetingSyncChanges()
        XCTAssertTrue(destinationPending.isEmpty)

        let tombstone = try await source.tombstoneTranscriptCorrection(
            correction.id,
            meetingID: seed.meeting.id,
            at: correction.createdAt.addingTimeInterval(100))
        let tombstoneEnvelope = try await latestEnvelope(in: source)
        let tombstoneResult = try await destination.applyRemoteMeetingSyncEnvelope(
            tombstoneEnvelope)
        XCTAssertEqual(tombstoneResult, .applied)
        destinationHistory = try await destination.transcriptCorrectionHistory(
            for: seed.meeting.id)
        XCTAssertEqual(destinationHistory, [tombstone])
        destinationPending = try await destination.pendingMeetingSyncChanges()
        XCTAssertTrue(destinationPending.isEmpty)
    }

    func testCorrectionHistoryCodecRejectsNoncanonicalOrder() async throws {
        let source = try MeetingStore.inMemory()
        let seed = try await seedMeeting(in: source)
        let first = correctionEvent(
            id: "00000000-0000-4000-9000-000000000111",
            seed: seed,
            kind: .suppress)
        let second = TranscriptCorrectionEvent(
            id: UUID(uuidString: "00000000-0000-4000-9000-000000000112")!,
            meetingID: seed.meeting.id,
            baseTranscriptRevision: seed.meeting.transcriptRevision,
            targetSegmentIDs: [seed.segments[1].id],
            kind: .suppress,
            sourceDeviceID: deviceID,
            createdAt: first.createdAt.addingTimeInterval(1))
        _ = try await source.appendTranscriptCorrection(first)
        _ = try await source.appendTranscriptCorrection(second)
        let envelope = try await latestEnvelope(in: source)

        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: MeetingSyncEnvelopeCodec.encode(envelope)) as? [String: Any])
        var mutation = try XCTUnwrap(root["mutation"] as? [String: Any])
        var upsert = try XCTUnwrap(mutation["upsert"] as? [String: Any])
        var aggregate = try XCTUnwrap(upsert["_0"] as? [String: Any])
        aggregate["transcriptCorrections"] = Array(
            try XCTUnwrap(
                aggregate["transcriptCorrections"] as? [[String: Any]])
                .reversed())
        upsert["_0"] = aggregate
        mutation["upsert"] = upsert
        root["mutation"] = mutation

        XCTAssertThrowsError(try MeetingSyncEnvelopeCodec.decode(
            JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])))
    }

    func testLegacyAggregateReplayDoesNotEraseLocalCorrectionHistory() async throws {
        let source = try MeetingStore.inMemory()
        let seed = try await seedMeeting(in: source)
        let correction = correctionEvent(
            id: "00000000-0000-4000-9000-000000000102",
            seed: seed,
            kind: .suppress)
        _ = try await source.appendTranscriptCorrection(correction)
        let destination = try MeetingStore.inMemory()
        let currentEnvelope = try await latestEnvelope(in: source)
        _ = try await destination.applyRemoteMeetingSyncEnvelope(currentEnvelope)

        let legacyEnvelope = try legacyAggregateEnvelope(from: currentEnvelope)
        guard case .upsert(let legacyAggregate) = legacyEnvelope.mutation else {
            return XCTFail("Expected a live aggregate")
        }
        XCTAssertEqual(legacyAggregate.formatVersion, 1)
        XCTAssertTrue(legacyAggregate.transcriptCorrections.isEmpty)
        let legacyResult = try await destination.applyRemoteMeetingSyncEnvelope(
            legacyEnvelope)
        XCTAssertEqual(legacyResult, .applied)

        let history = try await destination.transcriptCorrectionHistory(
            for: seed.meeting.id)
        XCTAssertEqual(history, [correction])
        let destinationPending = try await destination.pendingMeetingSyncChanges()
        XCTAssertTrue(destinationPending.isEmpty)
    }

    func testRemoteCorrectionIdentityRewriteRollsBackAggregate() async throws {
        let source = try MeetingStore.inMemory()
        let seed = try await seedMeeting(in: source)
        let correction = correctionEvent(
            id: "00000000-0000-4000-9000-000000000103",
            seed: seed,
            kind: .replaceText(text: "Original", language: "en"))
        _ = try await source.appendTranscriptCorrection(correction)
        let destination = try MeetingStore.inMemory()
        let envelope = try await latestEnvelope(in: source)
        _ = try await destination.applyRemoteMeetingSyncEnvelope(envelope)
        guard case .upsert(let aggregate) = envelope.mutation else {
            return XCTFail("Expected a live aggregate")
        }
        let rewritten = TranscriptCorrectionEvent(
            id: correction.id,
            meetingID: correction.meetingID,
            baseTranscriptRevision: correction.baseTranscriptRevision,
            targetSegmentIDs: correction.targetSegmentIDs,
            kind: .replaceText(text: "Rewritten", language: "en"),
            sourceDeviceID: correction.sourceDeviceID,
            createdAt: correction.createdAt)
        let rewrittenAggregate = MeetingSyncAggregate(
            meeting: aggregate.meeting,
            speakers: aggregate.speakers,
            segments: aggregate.segments,
            summaries: aggregate.summaries,
            contextItems: aggregate.contextItems,
            companionCards: aggregate.companionCards,
            transcriptCorrections: [rewritten])
        let rewrittenEnvelope = MeetingSyncEnvelope(
            meetingID: envelope.meetingID,
            sourceDeviceID: envelope.sourceDeviceID,
            generation: envelope.generation + 1,
            changedAt: envelope.changedAt.addingTimeInterval(1),
            mutation: .upsert(rewrittenAggregate))

        await XCTAssertMeetingSyncThrowsAsync {
            _ = try await destination.applyRemoteMeetingSyncEnvelope(rewrittenEnvelope)
        }
        let history = try await destination.transcriptCorrectionHistory(
            for: seed.meeting.id)
        XCTAssertEqual(history, [correction])
        let detail = try await destination.detail(seed.meeting.id)
        XCTAssertEqual(detail?.meeting.title, seed.meeting.title)
    }

    func testLiveRemoteChangeWaitsBehindPendingLocalGeneration() async throws {
        let source = try MeetingStore.inMemory()
        let seed = try await seedMeeting(in: source)
        let destination = try MeetingStore.inMemory()
        _ = try await destination.applyRemoteMeetingSyncEnvelope(latestEnvelope(in: source))

        var local = seed.meeting
        local.title = "Local edit"
        try await destination.save(local)
        let localPending = try await destination.pendingMeetingSyncChanges()
        let pending = try XCTUnwrap(localPending.first)

        var remote = seed.meeting
        remote.title = "Remote edit"
        try await source.save(remote)
        let result = try await destination.applyRemoteMeetingSyncEnvelope(
            latestEnvelope(in: source))

        XCTAssertEqual(result, .localChangePending(generation: pending.generation))
        let detail = try await destination.detail(seed.meeting.id)
        let remaining = try await destination.pendingMeetingSyncChanges()
        XCTAssertEqual(detail?.meeting.title, "Local edit")
        XCTAssertEqual(remaining.first?.generation, pending.generation)
    }

    func testRemoteDeletionWinsPendingLocalEditAndLeavesRecoverableTombstone() async throws {
        let source = try MeetingStore.inMemory()
        let seed = try await seedMeeting(in: source)
        let destination = try MeetingStore.inMemory()
        _ = try await destination.applyRemoteMeetingSyncEnvelope(latestEnvelope(in: source))

        var local = seed.meeting
        local.title = "Unsynced local edit"
        try await destination.save(local)
        let localPending = try await destination.pendingMeetingSyncChanges()
        let pending = try XCTUnwrap(localPending.first)
        try await source.delete(seed.meeting.id)
        let deletion = try await latestEnvelope(in: source)
        guard case .delete = deletion.mutation else {
            return XCTFail("Expected a deletion envelope")
        }

        let result = try await destination.applyRemoteMeetingSyncEnvelope(deletion)

        XCTAssertEqual(
            result,
            .deletionWon(discardedLocalGeneration: pending.generation))
        let detail = try await destination.detail(seed.meeting.id)
        XCTAssertNil(detail)
        let deletedAt = try await destination.database.read { db in
            try MeetingRecord.fetchOne(
                db,
                key: seed.meeting.id.rawValue.uuidString)?.deletedAt
        }
        XCTAssertNotNil(deletedAt)
        let remaining = try await destination.pendingMeetingSyncChanges()
        XCTAssertTrue(remaining.isEmpty)

        try await destination.restore(seed.meeting.id)

        let restored = try await destination.detail(seed.meeting.id)
        let restoredPending = try await destination.pendingMeetingSyncChanges()
        XCTAssertEqual(restored?.meeting.title, "Unsynced local edit")
        XCTAssertFalse(restoredPending.isEmpty)
    }

    func testInvalidRemoteRelationRollsBackWithoutCreatingMeeting() async throws {
        let source = try MeetingStore.inMemory()
        let seed = try await seedMeeting(in: source)
        let envelope = try await latestEnvelope(in: source)
        guard case .upsert(let aggregate) = envelope.mutation else {
            return XCTFail("Expected aggregate")
        }
        let foreignNote = ContextItem(
            meetingID: MeetingID(),
            kind: .note,
            content: "Foreign",
            timestamp: 0)
        let invalid = MeetingSyncAggregate(
            meeting: aggregate.meeting,
            speakers: aggregate.speakers,
            segments: aggregate.segments,
            summaries: aggregate.summaries,
            contextItems: [MeetingSyncTimed(
                value: foreignNote,
                createdAt: Date(),
                updatedAt: Date())],
            companionCards: aggregate.companionCards)
        let remote = MeetingSyncEnvelope(
            meetingID: seed.meeting.id,
            sourceDeviceID: UUID(),
            generation: envelope.generation,
            changedAt: envelope.changedAt,
            mutation: .upsert(invalid))
        let destination = try MeetingStore.inMemory()

        await XCTAssertMeetingSyncThrowsAsync {
            _ = try await destination.applyRemoteMeetingSyncEnvelope(remote)
        }
        let detail = try await destination.detail(seed.meeting.id)
        let pending = try await destination.pendingMeetingSyncChanges()
        XCTAssertNil(detail)
        XCTAssertTrue(pending.isEmpty)
    }

    func testImmutableSummaryCollisionFailsBeforeReplacingLocalAggregate() async throws {
        let source = try MeetingStore.inMemory()
        let seed = try await seedMeeting(in: source)
        let envelope = try await latestEnvelope(in: source)
        let destination = try MeetingStore.inMemory()
        _ = try await destination.applyRemoteMeetingSyncEnvelope(envelope)
        let summaryID = try await destination.database.write { db -> String in
            let record = try XCTUnwrap(SummaryRecord
                .filter(Column("meetingID") == seed.meeting.id.rawValue.uuidString)
                .order(Column("version"))
                .fetchOne(db))
            try db.execute(
                sql: "UPDATE summary SET markdown = ? WHERE id = ?",
                arguments: ["## Locally corrupted identity", record.id])
            return record.id
        }
        try await acknowledgeAll(in: destination)

        await XCTAssertMeetingSyncThrowsAsync {
            _ = try await destination.applyRemoteMeetingSyncEnvelope(envelope)
        }
        let markdown = try await destination.database.read { db in
            try SummaryRecord.fetchOne(db, key: summaryID)?.markdown
        }
        XCTAssertEqual(markdown, "## Locally corrupted identity")
        let detail = try await destination.detail(seed.meeting.id)
        XCTAssertEqual(detail?.meeting.title, "Portable")
    }

    func testImmutableSummaryChildCollisionFailsBeforeReplacingLocalAggregate() async throws {
        let source = try MeetingStore.inMemory()
        let seed = try await seedMeeting(in: source)
        let envelope = try await latestEnvelope(in: source)
        let destination = try MeetingStore.inMemory()
        _ = try await destination.applyRemoteMeetingSyncEnvelope(envelope)
        let actionID = try await destination.database.write { db -> String in
            let record = try XCTUnwrap(ActionItemRecord
                .filter(Column("meetingID") == seed.meeting.id.rawValue.uuidString)
                .order(Column("createdAt").desc)
                .fetchOne(db))
            try db.execute(
                sql: "UPDATE actionItem SET text = ? WHERE id = ?",
                arguments: ["Locally corrupted child identity", record.id])
            return record.id
        }
        try await acknowledgeAll(in: destination)

        await XCTAssertMeetingSyncThrowsAsync {
            _ = try await destination.applyRemoteMeetingSyncEnvelope(envelope)
        }

        let text = try await destination.database.read { db in
            try ActionItemRecord.fetchOne(db, key: actionID)?.text
        }
        let detail = try await destination.detail(seed.meeting.id)
        XCTAssertEqual(text, "Locally corrupted child identity")
        XCTAssertEqual(detail?.meeting.title, "Portable")
    }

    private let deviceID = UUID(
        uuidString: "00000000-0000-0000-0000-0000000000D1")!

    private struct Seed {
        let meeting: Meeting
        let speaker: Speaker
        let segments: [TranscriptSegment]
    }

    private func seedMeeting(in store: MeetingStore) async throws -> Seed {
        let meeting = Meeting(
            title: "Portable",
            startedAt: Date(timeIntervalSince1970: 1_784_300_000),
            language: nil)
        let speaker = Speaker(
            meetingID: meeting.id,
            label: "S1",
            displayName: "Ana")
        let segments = [
            TranscriptSegment(
                meetingID: meeting.id,
                speakerID: speaker.id,
                channel: .system,
                text: "Hola",
                language: "es",
                startTime: 0,
                endTime: 1,
                isFinal: true),
            TranscriptSegment(
                meetingID: meeting.id,
                speakerID: speaker.id,
                channel: .system,
                text: "Hello",
                language: "en",
                startTime: 1,
                endTime: 2,
                isFinal: true),
        ]
        try await store.save(meeting)
        try await store.save([speaker])
        try await store.save(segments)
        _ = try await store.saveSummary(SummaryDraft(
            meetingID: meeting.id,
            recipeID: Recipe.general.id,
            language: "es",
            markdown: "## Resumen\nPrimero",
            actionItems: [ActionItem(text: "Primero", ownerSpeakerID: speaker.id)]))
        let actionItem = ActionItem(text: "Second", ownerSpeakerID: speaker.id)
        let claim = SummaryClaim(
            kind: .overview,
            evidenceSegmentIDs: [segments[0].id])
        _ = try await store.saveSummary(SummaryDraft(
            meetingID: meeting.id,
            recipeID: Recipe.general.id,
            language: "en",
            markdown: "## Summary\nSecond\n\n## Decisions\n- Preserve every language.",
            actionItems: [actionItem],
            claims: [claim],
            decisionEvidence: [SummaryDecisionEvidence(
                sectionOrdinal: 1,
                bulletOrdinal: 0,
                evidenceSegmentIDs: [segments[1].id])],
            actionItemEvidence: [SummaryActionItemEvidence(
                actionItemID: actionItem.id,
                evidenceSegmentIDs: [segments[1].id])]))
        try await store.setSummaryClaimFeedback(
            .unsupported,
            for: claim.id,
            meetingID: meeting.id)
        try await store.save([ContextItem(
            meetingID: meeting.id,
            kind: .note,
            content: "Keep every language",
            timestamp: 1)])
        let cardID = UUID()
        try await store.save([CompanionCard(
            id: cardID,
            question: "What should remain?",
            answer: "Each speaker's language.",
            kind: .context,
            source: "on-device",
            askedAt: 2,
            evidence: CompanionCardEvidence(
                cardID: cardID,
                questionSegmentIDs: [segments[1].id]))], for: meeting.id)
        // SQLite stores dates at millisecond precision. Force the real tie
        // that exposed nondeterministic Meeting Detail summary ordering.
        try await store.database.write { db in
            try db.execute(
                sql: "UPDATE summary SET createdAt = ? WHERE meetingID = ?",
                arguments: [
                    Date(timeIntervalSince1970: 1_784_300_100),
                    meeting.id.rawValue.uuidString,
                ])
        }
        return Seed(meeting: meeting, speaker: speaker, segments: segments)
    }

    private func correctionEvent(
        id: String,
        seed: Seed,
        kind: TranscriptCorrectionKind
    ) -> TranscriptCorrectionEvent {
        TranscriptCorrectionEvent(
            id: UUID(uuidString: id)!,
            meetingID: seed.meeting.id,
            baseTranscriptRevision: seed.meeting.transcriptRevision,
            targetSegmentIDs: [seed.segments[0].id],
            kind: kind,
            sourceDeviceID: deviceID,
            createdAt: Date(timeIntervalSince1970: 1_784_300_200))
    }

    private func legacyAggregateEnvelope(
        from envelope: MeetingSyncEnvelope
    ) throws -> MeetingSyncEnvelope {
        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: MeetingSyncEnvelopeCodec.encode(envelope)) as? [String: Any])
        var mutation = try XCTUnwrap(root["mutation"] as? [String: Any])
        var upsert = try XCTUnwrap(mutation["upsert"] as? [String: Any])
        var aggregate = try XCTUnwrap(upsert["_0"] as? [String: Any])
        aggregate["formatVersion"] = 1
        aggregate.removeValue(forKey: "transcriptCorrections")
        upsert["_0"] = aggregate
        mutation["upsert"] = upsert
        root["mutation"] = mutation
        return try MeetingSyncEnvelopeCodec.decode(
            JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]))
    }

    private func latestEnvelope(in store: MeetingStore) async throws -> MeetingSyncEnvelope {
        let pending = try await store.pendingMeetingSyncChanges()
        let change = try XCTUnwrap(pending.first)
        return try await store.meetingSyncEnvelope(
            for: change,
            sourceDeviceID: deviceID)
    }

    private func acknowledgeAll(in store: MeetingStore) async throws {
        for change in try await store.pendingMeetingSyncChanges() {
            try await store.acknowledgeMeetingSync(change)
        }
    }

    private func installDeviceLocalDerivations(
        store: MeetingStore,
        speakerID: SpeakerID,
        segmentID: UUID
    ) async throws {
        try await store.database.write { db in
            let now = Date()
            let person = Person(preferredName: "Ana")
            try PersonRecord(person, createdAt: now, updatedAt: now).insert(db)
            try db.execute(
                sql: "UPDATE speaker SET personID = ? WHERE id = ?",
                arguments: [person.id.rawValue.uuidString, speakerID.rawValue.uuidString])
            try db.execute(
                sql: """
                    UPDATE segment
                    SET embedding = ?, embeddingFingerprint = ?
                    WHERE id = ?
                    """,
                arguments: [
                    Data([1, 2, 3, 4]),
                    "local-semantic-profile",
                    segmentID.uuidString,
                ])
        }
    }
}

private func XCTAssertMeetingSyncThrowsAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {
        // Expected.
    }
}
