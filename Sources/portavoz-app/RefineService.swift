import ApplicationKit
import Foundation
import Observation
import PortavozCore
import StorageKit
import TranscriptionKit

/// Presentation state for quality re-passes. The application workflow owns
/// engines and policy; this service only keeps work/drafts alive across views.
@MainActor
@Observable
final class RefineService {
    enum Phase {
        case running(String)
        case draft(RefineDraft)
        case failed(String)
    }

    private(set) var phases: [MeetingID: Phase] = [:]
    private var tasks: [MeetingID: Task<Void, Never>] = [:]
    private var runIDs: [MeetingID: UUID] = [:]

    func phase(for meetingID: MeetingID) -> Phase? { phases[meetingID] }

    func clear(_ meetingID: MeetingID) {
        if tasks[meetingID] != nil {
            cancel(meetingID)
        } else {
            phases[meetingID] = nil
        }
    }

    func cancel(_ meetingID: MeetingID) {
        guard let task = tasks[meetingID] else { return }
        task.cancel()
        phases[meetingID] = .running(L10n.text("Canceling refine…"))
    }

    var isRunning: Bool { !tasks.isEmpty }

    /// Deterministic temp-store fixture for XCUITest; never loads a model or
    /// touches a real meeting library.
    func seedRunningForUITest(_ meetingID: MeetingID) {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-use-temp-store"),
            arguments.contains("-seed-refine-running"),
            tasks.isEmpty
        else { return }
        let runID = UUID()
        runIDs[meetingID] = runID
        phases[meetingID] = .running(L10n.text("Re-transcribing participants (Whisper)…"))
        tasks[meetingID] = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(3_600))
            } catch {
                // Cancellation is the behavior this fixture exercises.
            }
            self?.finish(nil, meetingID: meetingID, runID: runID)
        }
    }

    func start(
        meetingID: MeetingID,
        meeting: Meeting,
        speakers: [Speaker],
        segments: [TranscriptSegment],
        useCase: RefineMeeting,
        languagePolicy: TranscriptLanguagePolicy? = nil
    ) {
        guard tasks[meetingID] == nil else { return }
        guard tasks.isEmpty else {
            phases[meetingID] = .failed(
                L10n.text("Another refine is already running — try again when it finishes."))
            return
        }

        let runID = UUID()
        runIDs[meetingID] = runID
        phases[meetingID] = .running(L10n.text("Preparing…"))
        let detail = MeetingDetail(
            meeting: meeting,
            speakers: speakers,
            segments: segments,
            summaries: [])
        tasks[meetingID] = Task { [weak self] in
            guard let self else { return }
            do {
                let draft = try await useCase(RefineMeetingRequest(
                    detail: detail,
                    languagePolicy: languagePolicy
                ) { [weak self] progress in
                    let message = await Self.localized(progress)
                    await self?.updateProgress(message, meetingID: meetingID, runID: runID)
                })
                finish(.draft(draft), meetingID: meetingID, runID: runID)
            } catch is CancellationError {
                finish(nil, meetingID: meetingID, runID: runID)
            } catch let error as RefineMeetingError {
                finish(
                    .failed(Self.localized(error)),
                    meetingID: meetingID,
                    runID: runID)
            } catch {
                finish(
                    .failed(L10n.format("Refine failed: %@", error.localizedDescription)),
                    meetingID: meetingID,
                    runID: runID)
            }
        }
    }
}

private extension RefineService {
    func updateProgress(_ message: String, meetingID: MeetingID, runID: UUID) {
        guard runIDs[meetingID] == runID else { return }
        phases[meetingID] = .running(message)
    }

    func finish(_ phase: Phase?, meetingID: MeetingID, runID: UUID) {
        guard runIDs[meetingID] == runID else { return }
        tasks[meetingID] = nil
        runIDs[meetingID] = nil
        phases[meetingID] = phase
    }

    static func localized(_ progress: RefineMeetingProgress) -> String {
        switch progress {
        case .preparingModels:
            L10n.text("Preparing…")
        case .downloadingWhisper(let size, let percent):
            L10n.format(
                "Downloading Whisper (%@, one time only)… %d%%",
                size,
                percent)
        case .transcribingParticipants:
            L10n.text("Re-transcribing participants (Whisper)…")
        case .transcribingMicrophone:
            L10n.text("Re-transcribing your channel (Whisper)…")
        case .identifyingSpeakers:
            L10n.text("Identifying speakers…")
        }
    }

    static func localized(_ error: RefineMeetingError) -> String {
        switch error {
        case .audioNotRetained:
            L10n.text("This meeting does not keep its audio.")
        case .audioUnavailable:
            L10n.text("Could not find the meeting audio.")
        }
    }
}
