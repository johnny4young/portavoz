import AVFoundation
import Foundation
import IntelligenceKit
import PortavozCore

extension AppServices {
    /// Seeds one deterministic meeting for `make test-ui`, including audio,
    /// summary, action-item, chapter, and Companion evidence.
    func seedDemoIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains("-seed-demo") else { return }
        defer { markUITestSeedReady() }
        guard ((try? await store.meetings()) ?? []).isEmpty else { return }

        let audioDirectory = Self.prepareSeedAudio()
        let meeting = Meeting(
            title: "Test meeting",
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
        let citedSegmentID = UUID(uuidString: "B5B00000-0000-4000-8000-000000000002")!
        let companionQuestionID = UUID(
            uuidString: "B5F00000-0000-4000-8000-000000000001")!
        let seedSegments = [
            TranscriptSegment(
                meetingID: meeting.id, speakerID: me.id, channel: .microphone,
                text: "Revisemos el presupuesto de transcripción.",
                startTime: 0, endTime: 3, isFinal: true),
            TranscriptSegment(
                id: citedSegmentID,
                meetingID: meeting.id, speakerID: ana.id, channel: .system,
                text: "El rollout del modelo queda para el viernes.",
                startTime: 3, endTime: 6, isFinal: true),
            TranscriptSegment(
                id: companionQuestionID,
                meetingID: meeting.id, speakerID: ana.id, channel: .system,
                text: "¿Cuándo es el rollout?",
                startTime: 6, endTime: 8, isFinal: true),
            TranscriptSegment(
                meetingID: meeting.id, speakerID: me.id, channel: .microphone,
                text: "Cerremos con los próximos pasos del rollout.",
                startTime: 200, endTime: 205, isFinal: true)
        ]
        try? await store.save(seedSegments)
        await seedSummaryIfRequested(
            meetingID: meeting.id,
            ownerID: ana.id,
            citedSegmentID: citedSegmentID)
        try? await store.save([
            ContextItem(meetingID: meeting.id, kind: .note, content: "revisar budget Q3", timestamp: 12)
        ])
        await seedCompanionCards(
            meetingID: meeting.id,
            questionSegmentID: companionQuestionID,
            answerSegmentID: citedSegmentID)
        await seedPrivacyReceipt(for: meeting.id)
        await seedProcessingFailureIfRequested(for: meeting.id)
        seedRunningRefineIfRequested(for: meeting.id)
        seedJustRecordedIfRequested(for: meeting.id)
        requestSpotlightReindex()
    }

    /// XCUITest waits for the complete aggregate rather than racing the first
    /// meeting-row write while summary, evidence, and receipts are still being
    /// inserted. Production launches never provide this scratch path.
    private func markUITestSeedReady() {
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

    private func seedSummaryIfRequested(
        meetingID: MeetingID,
        ownerID: SpeakerID,
        citedSegmentID: UUID
    ) async {
        guard !ProcessInfo.processInfo.arguments.contains("-seed-without-summary") else { return }
        _ = try? await store.saveSummary(
            SummaryDraft(
                meetingID: meetingID, recipeID: Recipe.general.id, language: "es",
                markdown: """
                    El equipo revisó el presupuesto y fijó el rollout.

                    ## Decisiones
                    - ▸ El rollout del modelo queda para el viernes.
                    - Se revisará el presupuesto de transcripción.
                    """,
                actionItems: [ActionItem(
                    id: UUID(uuidString: "B5E00000-0000-4000-8000-000000000001")!,
                    text: "Prepare the rollout",
                    ownerSpeakerID: ownerID)],
                claims: [SummaryClaim(
                    kind: .overview,
                    evidenceSegmentIDs: [citedSegmentID])],
                decisionEvidence: [SummaryDecisionEvidence(
                    sectionOrdinal: 0,
                    bulletOrdinal: 0,
                    evidenceSegmentIDs: [citedSegmentID])],
                actionItemEvidence: [SummaryActionItemEvidence(
                    actionItemID: UUID(
                        uuidString: "B5E00000-0000-4000-8000-000000000001")!,
                    evidenceSegmentIDs: [citedSegmentID])]))
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
    }

    /// Adopts isolated real audio when supplied; otherwise creates a short
    /// deterministic two-channel waveform for UI coverage.
    private static func prepareSeedAudio() -> String? {
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
