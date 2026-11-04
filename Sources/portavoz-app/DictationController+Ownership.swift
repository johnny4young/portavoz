import Foundation

extension DictationController {
    func adopt(_ lease: DictationLease) {
        sessionLease = lease
        yieldsToHandoff = false
        ownershipIntentCleared()
    }

    /// Another app asked for ownership: each stage follows the protocol's handoff table.
    func ownershipIntentSeen() {
        guard isActive, phase != .delivering else { return }
        if sessionIsPractice || phase == .preparing {
            cancel()
            return
        }
        guard handoffGrace == nil, let grace = sessionHandoffGrace else { return }
        handoffGrace = Task { [weak self] in
            do {
                try await Task.sleep(for: grace, clock: .continuous)
            } catch {
                return
            }
            self?.yieldToHandoff()
        }
    }

    func ownershipIntentCleared() {
        handoffGrace?.cancel()
        handoffGrace = nil
    }

    /// The words go to recovery instead of the field, so a handoff never loses them.
    private func yieldToHandoff() {
        guard phase == .listening else { return }
        yieldsToHandoff = true
        finishAndInsert()
    }
}
