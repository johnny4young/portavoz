import AVFoundation
import ApplicationKit
import Foundation
import IntelligenceKit
import PortavozCore

extension AppServices {
    /// Seeds one deterministic meeting for `make test-ui`, including audio,
    /// summary, action-item, chapter, and Companion evidence.
    func seedDemoIfRequested(
        reconcileSearchAfterSeed: Bool = true
    ) async {
        guard ProcessInfo.processInfo.arguments.contains("-seed-demo") else { return }
        defer { markUITestSeedReady() }
        guard ((try? await store.meetings()) ?? []).isEmpty else { return }

        let audioDirectory = Self.prepareSeedAudio()
        let meeting = Meeting(
            title: seedDemoMeetingTitle,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_001_800),
            language: "es",
            audioDirectory: audioDirectory)
        try? await store.save(meeting)

        let me = Speaker(meetingID: meeting.id, label: "Me", isMe: true)
        let ana = Speaker(
            meetingID: meeting.id,
            label: "S1",
            displayName: ProcessInfo.processInfo.arguments.contains("-seed-unnamed-speaker")
                ? nil
                : "Ana")
        try? await store.save([me, ana])
        let canonicalPersonID = await seedCanonicalPersonIfNeeded(ana)
        let citedSegmentID = UUID(uuidString: "B5B00000-0000-4000-8000-000000000002")!
        let companionQuestionID = UUID(
            uuidString: "B5F00000-0000-4000-8000-000000000001")!
        let seedSegments = Self.seedDemoTranscript(
            meetingID: meeting.id,
            meID: me.id,
            remoteID: ana.id,
            citedSegmentID: citedSegmentID,
            companionQuestionID: companionQuestionID)
        try? await store.save(seedSegments)
        await seedSummaryIfRequested(
            meetingID: meeting.id,
            ownerID: ana.id,
            citedSegmentID: citedSegmentID)
        await seedCommitmentRadarIfRequested(
            meetingID: meeting.id,
            canonicalPersonID: canonicalPersonID)
        await seedAskGraphFixtures(
            canonicalPersonID: canonicalPersonID,
            meetingID: meeting.id,
            citedSegmentID: citedSegmentID,
            audioDirectory: audioDirectory)
        await seedDemoContext(for: meeting.id)
        await seedCompanionCards(
            meetingID: meeting.id,
            questionSegmentID: companionQuestionID,
            answerSegmentID: citedSegmentID)
        await seedStaleDerivedArtifactsIfRequested(
            meetingID: meeting.id,
            sourceSegmentID: citedSegmentID,
            transcriptRevision: meeting.transcriptRevision)
        await seedPrivacyReceipt(for: meeting.id)
        await seedProcessingFailureIfRequested(for: meeting.id)
        await seedAbandonedSummaryIfRequested(for: meeting.id)
        await seedSkillHistoryIfRequested(for: meeting.id)
        await seedWaitingSkillExecutionIfRequested(for: meeting.id)
        await seedFailedSkillExecutionIfRequested(for: meeting.id)
        seedRunningRefineIfRequested(for: meeting.id)
        seedJustRecordedIfRequested(for: meeting.id)
        if reconcileSearchAfterSeed { requestSearchReconciliation() }
    }

    private func seedDemoContext(for meetingID: MeetingID) async {
        try? await store.save([ContextItem(
            meetingID: meetingID,
            kind: .note,
            content: "revisar budget Q3",
            timestamp: 12)])
    }

    private static func seedDemoTranscript(
        meetingID: MeetingID,
        meID: SpeakerID,
        remoteID: SpeakerID,
        citedSegmentID: UUID,
        companionQuestionID: UUID
    ) -> [TranscriptSegment] {
        [
            TranscriptSegment(
                meetingID: meetingID, speakerID: meID, channel: .microphone,
                text: "Revisemos el presupuesto de transcripción.",
                startTime: 0, endTime: 3, isFinal: true),
            TranscriptSegment(
                id: citedSegmentID,
                meetingID: meetingID, speakerID: remoteID, channel: .system,
                text: "El rollout del modelo queda para el viernes.",
                startTime: 3, endTime: 6, isFinal: true),
            TranscriptSegment(
                id: companionQuestionID,
                meetingID: meetingID, speakerID: remoteID, channel: .system,
                text: "¿Cuándo es el rollout?",
                startTime: 6, endTime: 8, isFinal: true),
            TranscriptSegment(
                meetingID: meetingID, speakerID: meID, channel: .microphone,
                text: "Cerremos con los próximos pasos del rollout.",
                startTime: 200, endTime: 205, isFinal: true)
        ]
    }

    private var seedDemoMeetingTitle: String {
        ProcessInfo.processInfo.arguments.contains("-seed-ai-suggestions")
            ? "2026-07-27 Meeting"
            : "Test meeting"
    }

    /// XCUITest waits for the complete aggregate rather than racing the first
    /// meeting-row write while summary, evidence, and receipts are still being
    /// inserted. Production launches never provide this scratch path.
    func markUITestSeedReady() {
        guard ProcessInfo.processInfo.arguments.contains("-use-temp-store"),
              let path = ProcessInfo.processInfo.environment[
                  "PORTAVOZ_UI_TEST_SEED_READY_PATH"]
        else { return }
        _ = FileManager.default.createFile(atPath: path, contents: Data())
    }

    private func seedCompanionCards(
        meetingID: MeetingID,
        questionSegmentID: UUID,
        answerSegmentID: UUID
    ) async {
        let cardID = UUID(uuidString: "B5F00000-0000-4000-8000-000000000002")!
        try? await store.save([
            CompanionCard(
                id: cardID,
                question: "¿Cuándo es el rollout?", answer: "El rollout queda para el viernes.",
                kind: .context, source: "on-device", askedAt: 6,
                evidence: CompanionCardEvidence(
                    cardID: cardID,
                    questionSegmentIDs: [questionSegmentID],
                    answerSegmentIDs: [answerSegmentID])),
            CompanionCard(
                question: "Ana, ¿te encargas del presupuesto?", answer: "",
                kind: .context, source: "on-device", directed: true, askedAt: 200)
        ], for: meetingID)
    }

    private func seedCanonicalPersonIfNeeded(_ speaker: Speaker) async -> PersonID? {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-seed-commitment-inbox")
                || arguments.contains("-seed-commitment-radar")
                || arguments.contains("-seed-ask-memory")
        else { return nil }
        return try? await store.createPersonAndLink(
            speakerID: speaker.id,
            preferredName: "Ana",
            source: .manualName).person.id
    }

    private func seedStaleDerivedArtifactsIfRequested(
        meetingID: MeetingID,
        sourceSegmentID: UUID,
        transcriptRevision: Int
    ) async {
        guard ProcessInfo.processInfo.arguments.contains("-seed-stale-derived") else {
            return
        }
        let correction = TranscriptCorrectionEvent(
            id: UUID(uuidString: "B5C00000-0000-4000-8000-000000000001")!,
            meetingID: meetingID,
            baseTranscriptRevision: transcriptRevision,
            targetSegmentIDs: [sourceSegmentID],
            kind: .replaceText(
                text: "El rollout corregido queda para el lunes.",
                language: "es"),
            sourceDeviceID: UUID(
                uuidString: "B5C00000-0000-4000-8000-000000000002")!,
            createdAt: Date(timeIntervalSince1970: 1_700_000_100))
        _ = try? await store.appendTranscriptCorrection(correction)
    }

    private func seedSummaryIfRequested(
        meetingID: MeetingID,
        ownerID: SpeakerID,
        citedSegmentID: UUID
    ) async {
        guard !ProcessInfo.processInfo.arguments.contains("-seed-without-summary") else { return }
        let seedsReviewQueue = ProcessInfo.processInfo.arguments.contains(
            "-seed-commitment-radar")
        var actionItems = [ActionItem(
            id: Self.seedActionItemID,
            text: "Prepare the rollout",
            ownerSpeakerID: ownerID)]
        var actionItemEvidence = [SummaryActionItemEvidence(
            actionItemID: Self.seedActionItemID,
            evidenceSegmentIDs: [citedSegmentID])]
        if seedsReviewQueue {
            actionItems.append(ActionItem(
                id: Self.seedReviewActionItemID,
                text: "Send the launch checklist",
                ownerSpeakerID: ownerID))
            actionItemEvidence.append(SummaryActionItemEvidence(
                actionItemID: Self.seedReviewActionItemID,
                evidenceSegmentIDs: [citedSegmentID]))
        }
        let reviewQueueMarkdown = seedsReviewQueue
            ? "\n- [ ] Send the launch checklist — S1"
            : ""
        _ = try? await store.saveSummary(
            SummaryDraft(
                meetingID: meetingID, recipeID: Recipe.general.id, language: "es",
                markdown: """
                    El equipo revisó el presupuesto y fijó el rollout.

                    ## Decisiones
                    - ▸ El rollout del modelo queda para el viernes.
                    - Se revisará el presupuesto de transcripción.

                    ## Pendientes
                    - [ ] Prepare the rollout — S1
                    \(reviewQueueMarkdown)
                    """,
                actionItems: actionItems,
                claims: [SummaryClaim(
                    kind: .overview,
                    evidenceSegmentIDs: [citedSegmentID])],
                decisionEvidence: [SummaryDecisionEvidence(
                    id: Self.seedDecisionObservationID,
                    sectionOrdinal: 0,
                    bulletOrdinal: 0,
                    evidenceSegmentIDs: [citedSegmentID])],
                actionItemEvidence: actionItemEvidence))
        await seedLatestRecipeSummaryIfRequested(for: meetingID)
    }

    private func seedProcessingFailureIfRequested(for meetingID: MeetingID) async {
        guard ProcessInfo.processInfo.arguments.contains("-seed-processing-failure") else {
            return
        }
        let owner = "ui-test-processing-failure"
        do {
            _ = try await store.enqueueProcessingJobs(
                for: meetingID,
                requests: [ProcessingJobRequest(
                    kind: .transcription,
                    inputFingerprint: "ui-test-processing-failure",
                    maxAttempts: 1)])
            guard let job = try await store.claimNextProcessingJob(
                kinds: [.transcription],
                owner: owner,
                leaseDuration: 60)
            else { return }
            _ = try await store.failProcessingJob(
                job.id,
                owner: owner,
                failure: ProcessingJobFailure(
                    code: "processing.transcription.failed",
                    message: "fixture detail must never reach diagnostics"))
        } catch {
            assertionFailure("Could not seed processing failure: \(error)")
        }
    }

    /// A content-free, confirmed execution that deliberately stops before
    /// `begin`. It lets XCUITest exercise the real Waiting revocation path
    /// without invoking a platform effect or touching the user's library.
    private func seedWaitingSkillExecutionIfRequested(
        for meetingID: MeetingID
    ) async {
        guard usesTemporaryMeetingStore,
              ProcessInfo.processInfo.arguments.contains("-seed-skill-waiting")
        else { return }
        do {
            let outcome = try await store.confirmSkillExecution(SkillExecutionConfirmation(
                proposalID: Self.seedWaitingSkillProposalID,
                skillID: RecapDraftSkill.id,
                skillVersion: RecapDraftSkill.version,
                subject: .meeting(meetingID),
                offerKey: RecapDraftSkill.idempotencyKey(for: meetingID),
                idempotencyKey: RecapDraftSkill.idempotencyKey(for: meetingID),
                occurredAt: Date(timeIntervalSince1970: 1_700_000_400)))
            switch outcome {
            case .admitted(let record), .alreadySettled(let record):
                guard record.state == .confirmed else {
                    assertionFailure("Waiting Skill fixture was already settled")
                    return
                }
            case .rejected(let rejection):
                assertionFailure("Could not seed Waiting Skill: \(rejection)")
            }
        } catch {
            assertionFailure("Could not seed Waiting Skill: \(error)")
        }
    }

    /// Twenty-five content-free approvals prove that Settings initially reads
    /// only twenty rows and performs one explicit, bounded expansion to fifty.
    /// Every row is a separate destination-scoped package export approval, so
    /// the fixture preserves the production offer/effect-key relationship.
    private func seedSkillHistoryIfRequested(
        for meetingID: MeetingID
    ) async {
        guard usesTemporaryMeetingStore,
              ProcessInfo.processInfo.arguments.contains("-seed-skill-history")
        else { return }
        do {
            for ordinal in 1...25 {
                let offerKey = "\(MeetingPackageExportSkill.id):"
                    + meetingID.rawValue.uuidString
                let effectKey = offerKey
                    + ":/tmp/ui-test-skill-history-\(ordinal).portavoz"
                let outcome = try await store.confirmSkillExecution(
                    SkillExecutionConfirmation(
                        proposalID: Self.skillHistoryProposalID(ordinal),
                        skillID: MeetingPackageExportSkill.id,
                        skillVersion: MeetingPackageExportSkill.version,
                        subject: .meeting(meetingID),
                        offerKey: offerKey,
                        idempotencyKey: effectKey,
                        occurredAt: Date(
                            timeIntervalSince1970:
                                1_700_000_600 + TimeInterval(ordinal))))
                switch outcome {
                case .admitted(let record), .alreadySettled(let record):
                    guard record.state == .confirmed else {
                        assertionFailure(
                            "Skill history fixture was already settled")
                        return
                    }
                case .rejected(let rejection):
                    assertionFailure(
                        "Could not seed Skill history: \(rejection)")
                    return
                }
            }
        } catch {
            assertionFailure("Could not seed Skill history: \(error)")
        }
    }

    /// A real failed local receipt with an exact meeting subject. It stops
    /// after settlement, so Settings can prove that recovery only navigates
    /// back to the subject surface and never performs or confirms an effect.
    private func seedFailedSkillExecutionIfRequested(
        for meetingID: MeetingID
    ) async {
        guard usesTemporaryMeetingStore,
              ProcessInfo.processInfo.arguments.contains(
                  "-seed-skill-failed-recoverable")
        else { return }
        let timestamp = Date(timeIntervalSince1970: 1_700_000_500)
        let key = RecapDraftSkill.idempotencyKey(for: meetingID)
        do {
            let confirmation = try await store.confirmSkillExecution(SkillExecutionConfirmation(
                proposalID: Self.seedFailedSkillProposalID,
                skillID: RecapDraftSkill.id,
                skillVersion: RecapDraftSkill.version,
                subject: .meeting(meetingID),
                offerKey: key,
                idempotencyKey: key,
                occurredAt: timestamp))
            guard case .admitted = confirmation else {
                assertionFailure("Failed Skill fixture could not confirm")
                return
            }
            let begin = try await store.beginSkillExecution(
                proposalID: Self.seedFailedSkillProposalID,
                at: timestamp.addingTimeInterval(1))
            guard case .admitted = begin else {
                assertionFailure("Failed Skill fixture could not begin")
                return
            }
            let settlement = try await store.settleSkillExecution(
                proposalID: Self.seedFailedSkillProposalID,
                succeeded: false,
                failureCategory: .recoverable,
                at: timestamp.addingTimeInterval(2))
            guard case .admitted = settlement else {
                assertionFailure("Failed Skill fixture could not settle")
                return
            }
        } catch {
            assertionFailure("Could not seed failed Skill: \(error)")
        }
    }

    /// A meeting whose automatic summary was cancelled and never replaced. The
    /// meeting stays `ready` — audio and transcript are intact — so the summary
    /// pane is the only place that can say the summary is not coming.
    private func seedAbandonedSummaryIfRequested(for meetingID: MeetingID) async {
        guard ProcessInfo.processInfo.arguments.contains("-seed-abandoned-summary") else {
            return
        }
        let owner = "ui-test-abandoned-summary"
        do {
            _ = try await store.enqueueProcessingJobs(
                for: meetingID,
                requests: [ProcessingJobRequest(
                    kind: .summary,
                    inputFingerprint: "ui-test-abandoned-summary",
                    maxAttempts: 1)])
            guard let job = try await store.claimNextProcessingJob(
                kinds: [.summary],
                owner: owner,
                leaseDuration: 60)
            else { return }
            _ = try await store.cancelProcessingJob(
                job.id,
                owner: owner,
                reason: ProcessingJobFailure(
                    code: "processing.input.superseded",
                    message: "The processing input changed before execution."))
        } catch {
            assertionFailure("Could not seed the abandoned summary: \(error)")
        }
    }

    private func seedCommitmentRadarIfRequested(
        meetingID: MeetingID,
        canonicalPersonID: PersonID?
    ) async {
        guard ProcessInfo.processInfo.arguments.contains("-seed-commitment-radar") else {
            return
        }
        guard let canonicalPersonID else {
            assertionFailure("Could not seed the Radar's canonical person")
            return
        }

        let now = Date()
        let old = now.addingTimeInterval(-10 * 86_400)
        do {
            try await seedNewRadarCommitment(
                personID: canonicalPersonID,
                now: now)
            try await seedReopenedRadarCommitment(
                meetingID: meetingID,
                old: old,
                now: now)
            try await seedUnchangedRadarCommitment(meetingID: meetingID, old: old)
            try await seedCompletedRadarCommitment(
                meetingID: meetingID,
                personID: canonicalPersonID,
                old: old)
        } catch {
            assertionFailure("Could not seed Commitment Radar: \(error)")
        }
    }

    private func seedAskGraphFixtures(
        canonicalPersonID: PersonID?,
        meetingID: MeetingID,
        citedSegmentID: UUID,
        audioDirectory: String?
    ) async {
        await seedAskMemoryIfRequested(
            canonicalPersonID: canonicalPersonID,
            audioDirectory: audioDirectory)
        await seedAskTopicMemoryIfRequested(
            meetingID: meetingID,
            citedSegmentID: citedSegmentID)
    }

    func projectAskMemoryGraph(
        at timestamp: Date,
        owner: String
    ) async throws {
        _ = try await store.admitMeetingMemoryGraphMaintenance(at: timestamp)
        guard let job = try await store.claimMeetingMemoryGraphMaintenance(
            owner: owner,
            leaseDuration: 120,
            at: timestamp)
        else {
            throw UITestFixtureError.couldNotClaimAskMemoryProjection
        }
        let result = try await ProjectMeetingMemoryGraph(
            store: store,
            now: { timestamp }).all(
            job: job,
            owner: owner)
        guard !result.pausedByPolicy else {
            throw UITestFixtureError.askMemoryProjectionPaused
        }
        _ = try await store.completeMeetingMemoryGraphMaintenance(
            job.id,
            owner: owner,
            at: timestamp)
    }

    private func seedNewRadarCommitment(
        personID: PersonID,
        now: Date
    ) async throws {
        _ = try await store.confirmCommitment(
            CommitmentConfirmation(
                commitmentID: Self.radarCommitmentID(1),
                sourceID: Self.radarSourceID(1),
                eventID: Self.radarEventID(1),
                title: "Send the rollout brief",
                assignee: .person(personID),
                dueAt: now.addingTimeInterval(2 * 86_400),
                origin: .generatedActionItem(Self.seedActionItemID)),
            at: now.addingTimeInterval(-3_600))
    }

    private func seedReopenedRadarCommitment(
        meetingID: MeetingID,
        old: Date,
        now: Date
    ) async throws {
        let reopened = try await store.confirmCommitment(
            CommitmentConfirmation(
                commitmentID: Self.radarCommitmentID(2),
                sourceID: Self.radarSourceID(2),
                eventID: Self.radarEventID(2),
                title: "Recheck the launch checklist",
                assignee: .me,
                dueAt: now.addingTimeInterval(-86_400),
                origin: .manual(meetingID: meetingID)),
            at: old)
        _ = try await store.applyCommitmentTransition(
            .complete,
            to: reopened.commitment.id,
            eventID: Self.radarEventID(3),
            sourceMeetingID: meetingID,
            at: old.addingTimeInterval(60))
        _ = try await store.applyCommitmentTransition(
            .reopen,
            to: reopened.commitment.id,
            eventID: Self.radarEventID(4),
            sourceMeetingID: meetingID,
            at: now.addingTimeInterval(-7_200))
    }

    private func seedUnchangedRadarCommitment(
        meetingID: MeetingID,
        old: Date
    ) async throws {
        _ = try await store.confirmCommitment(
            CommitmentConfirmation(
                commitmentID: Self.radarCommitmentID(3),
                sourceID: Self.radarSourceID(3),
                eventID: Self.radarEventID(5),
                title: "Clarify the budget owner",
                assignee: .unassigned,
                origin: .manual(meetingID: meetingID)),
            at: old.addingTimeInterval(120))
    }

    private func seedCompletedRadarCommitment(
        meetingID: MeetingID,
        personID: PersonID,
        old: Date
    ) async throws {
        let completed = try await store.confirmCommitment(
            CommitmentConfirmation(
                commitmentID: Self.radarCommitmentID(4),
                sourceID: Self.radarSourceID(4),
                eventID: Self.radarEventID(6),
                title: "Archive the approved plan",
                assignee: .person(personID),
                origin: .manual(meetingID: meetingID)),
            at: old.addingTimeInterval(180))
        _ = try await store.applyCommitmentTransition(
            .complete,
            to: completed.commitment.id,
            eventID: Self.radarEventID(7),
            sourceMeetingID: meetingID,
            at: old.addingTimeInterval(240))
    }

    static let seedActionItemID = UUID(
        uuidString: "B5E00000-0000-4000-8000-000000000001")!
    static let seedDecisionObservationID = SummaryDecisionID(rawValue: UUID(
        uuidString: "B5D40000-0000-4000-8000-000000000001")!)
    private static let seedReviewActionItemID = UUID(
        uuidString: "B5E00000-0000-4000-8000-000000000002")!
    private static let seedWaitingSkillProposalID = UUID(
        uuidString: "B5E00000-0000-4000-8000-000000000003")!
    private static let seedFailedSkillProposalID = UUID(
        uuidString: "B5E00000-0000-4000-8000-000000000004")!
    private static func skillHistoryProposalID(_ ordinal: Int) -> UUID {
        UUID(uuidString: String(
            format: "B5E10000-0000-4000-8000-%012d",
            ordinal))!
    }
    private static func radarCommitmentID(_ ordinal: Int) -> CommitmentID {
        CommitmentID(rawValue: UUID(uuidString: String(
            format: "B5D10000-0000-4000-8000-%012d",
            ordinal))!)
    }

    private static func radarSourceID(_ ordinal: Int) -> CommitmentSourceID {
        CommitmentSourceID(rawValue: UUID(uuidString: String(
            format: "B5D20000-0000-4000-8000-%012d",
            ordinal))!)
    }

    private static func radarEventID(_ ordinal: Int) -> CommitmentEventID {
        CommitmentEventID(rawValue: UUID(uuidString: String(
            format: "B5D30000-0000-4000-8000-%012d",
            ordinal))!)
    }

    private func seedPrivacyReceipt(for meetingID: MeetingID) async {
        try? await store.recordDataEgressEvent(DataEgressEvent(
            meetingID: meetingID,
            operation: .summaryGeneration,
            destinationScope: .remote,
            destinationHost: "api.example.com",
            dataClassification: .meetingSummaryMaterial,
            consentSource: .summaryEngineSettings,
            providerID: "api.example.com",
            modelID: "fixture-summary",
            attemptedAt: Date(timeIntervalSince1970: 1_700_000_300)))
        // Acknowledge one journal generation so the receipt's private-iCloud
        // disclosure line is deterministically visible to UI tests.
        do {
            let changes = try await store.pendingMeetingSyncChanges()
            guard let change = changes.first(where: { $0.meetingID == meetingID }) else {
                assertionFailure("Could not find the seeded meeting's sync generation")
                return
            }
            try await store.acknowledgeMeetingSync(change)
        } catch {
            assertionFailure("Could not seed private-iCloud receipt: \(error)")
        }
    }

    /// Adopts isolated real audio when supplied; otherwise creates a short
    /// deterministic two-channel waveform for UI coverage.
    static func prepareSeedAudio() -> String? {
        let manager = FileManager.default
        let audioBase = audioRoot.appendingPathComponent("Audio", isDirectory: true)
        if let existing = try? manager.contentsOfDirectory(
            at: audioBase, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]),
            let dir = existing.first(where: { url in
                ["microphone.caf", "microphone.wav", "system.caf", "system.wav"]
                    .contains { manager.fileExists(atPath: url.appendingPathComponent($0).path) }
            }) {
            return "Audio/\(dir.lastPathComponent)"
        }

        let uuid = UUID().uuidString
        let dir = audioBase.appendingPathComponent(uuid, isDirectory: true)
        guard (try? manager.createDirectory(at: dir, withIntermediateDirectories: true)) != nil
        else { return nil }
        let ok =
            writeTone(dir.appendingPathComponent("microphone.wav"), frequency: 220, activeHalf: .first)
            && writeTone(dir.appendingPathComponent("system.wav"), frequency: 440, activeHalf: .second)
        return ok ? "Audio/\(uuid)" : nil
    }

    private enum ActiveHalf { case first, second }

    private static func writeTone(_ url: URL, frequency: Double, activeHalf: ActiveHalf) -> Bool {
        let rate = 16_000.0
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
            let file = try? AVAudioFile(forWriting: url, settings: format.settings),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * 6))
        else { return false }
        let frames = Int(rate * 6)
        buffer.frameLength = AVAudioFrameCount(frames)
        let samples = buffer.floatChannelData![0]
        let half = frames / 2
        for index in 0..<frames {
            let active = activeHalf == .first ? index < half : index >= half
            samples[index] = active
                ? 0.5 * Float(sin(2 * Double.pi * frequency * Double(index) / rate))
                : 0
        }
        return (try? file.write(from: buffer)) != nil
    }

    /// Adds a second recipe only for the D45 disposable UI fixture.
    func seedLatestRecipeSummaryIfRequested(for meetingID: MeetingID) async {
        guard ProcessInfo.processInfo.arguments.contains("-seed-latest-recipe") else { return }
        _ = try? await store.saveSummary(
            SummaryDraft(
                meetingID: meetingID, recipeID: Recipe.standup.id, language: "es",
                markdown: """
                    El resumen de standup sigue visible después de recargar.

                    ## Progreso
                    - El presupuesto de transcripción ya fue revisado.

                    ## Bloqueos
                    - Ninguno para el rollout del viernes.
                    """,
                actionItems: []))
    }

    func seedRunningRefineIfRequested(for meetingID: MeetingID) {
        refines.seedRunningForUITest(meetingID)
    }

    /// Marks the disposable seed as freshly recorded so XCUITest can exercise
    /// the one-shot post-meeting mirror without starting capture hardware.
    func seedJustRecordedIfRequested(for meetingID: MeetingID) {
        guard ProcessInfo.processInfo.arguments.contains("-seed-just-recorded") else { return }
        justRecorded = meetingID
    }
}

private enum UITestFixtureError: Error {
    case couldNotClaimAskMemoryProjection
    case askMemoryProjectionPaused
}
