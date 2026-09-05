import Foundation
import IntelligenceKit
import Observation
import PortavozCore

/// Recording-scoped owner for inert proactive cards. Evaluation is pure and
/// synchronous, so disable, pause, Stop, and reset cannot race a late model or
/// network callback into a closed recording lifecycle.
@MainActor
@Observable
final class RecordingProactiveAssistModel {
    private(set) var isEnabled = false
    private(set) var isPaused = false
    private(set) var suggestions: [ProactiveAssistSuggestion] = []

    private var emittedSignals: Set<ProactiveAssistSignalKey> = []
    private var lastEmissionOffset: TimeInterval?

    func setEnabled(
        _ enabled: Bool,
        captions: [TranscriptSegment],
        pendingObjectives: [ProactiveAssistObjective]
    ) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        isPaused = false
        guard enabled else {
            suggestions = []
            return
        }
        observe(captions: captions, pendingObjectives: pendingObjectives)
    }

    func setPaused(
        _ paused: Bool,
        captions: [TranscriptSegment],
        pendingObjectives: [ProactiveAssistObjective]
    ) {
        guard isEnabled, paused != isPaused else { return }
        isPaused = paused
        guard !paused else { return }
        observe(captions: captions, pendingObjectives: pendingObjectives)
    }

    func observe(
        captions: [TranscriptSegment],
        pendingObjectives: [ProactiveAssistObjective]
    ) {
        reconcileOpenObjectives(pendingObjectives)
        guard isEnabled, !isPaused,
              suggestions.count < ProactiveMeetingAssistPolicy.maximumVisibleSuggestions,
              let candidate = ProactiveMeetingAssistPolicy.nextSuggestion(
                captions: captions,
                pendingObjectives: pendingObjectives,
                emittedSignals: emittedSignals,
                lastEmissionOffset: lastEmissionOffset)
        else { return }
        suggestions.append(candidate)
        emittedSignals.insert(candidate.signalKey)
        lastEmissionOffset = candidate.evidence.endTime
    }

    func dismiss(_ id: ProactiveAssistSuggestion.ID) {
        suggestions.removeAll { $0.id == id }
    }

    func reset() {
        isEnabled = false
        isPaused = false
        suggestions = []
        emittedSignals = []
        lastEmissionOffset = nil
    }

    private func reconcileOpenObjectives(
        _ pendingObjectives: [ProactiveAssistObjective]
    ) {
        let pendingIDs = Set(pendingObjectives.map(\.id))
        suggestions.removeAll { suggestion in
            guard case .objective(let id) = suggestion.signalKey else { return false }
            return !pendingIDs.contains(id)
        }
    }
}
