import Foundation

extension DictationController {
    func adopt(_ lease: DictationLease) {
        sessionLease = lease
        yieldsToHandoff = false
        ownershipIntentCleared()
    }

    /// Another app asked for ownership: each stage follows the protocol's handoff table.
    func ownershipIntentSeen() {
        guard isActive else { return }
        if sessionIsPractice || phase == .preparing {
            cancel()
            return
        }
        guard microphoneIsOpen, handoffGrace == nil, let grace = sessionHandoffGrace else { return }
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

    /// A trigger going away during a handoff would strand its release: end the session now and
    /// keep the words. With no handoff, this is an ordinary rebind or disable.
    func retireTriggerOwnedSession() {
        guard isActive else { return }
        if handoffGrace != nil || yieldsToHandoff {
            yieldToHandoff()
        } else {
            cancel()
        }
    }

    /// The words go to recovery instead of the field, so a handoff never loses them.
    func yieldToHandoff() {
        guard microphoneIsOpen else { return }
        yieldsToHandoff = true
        finishAndInsert()
    }
}
