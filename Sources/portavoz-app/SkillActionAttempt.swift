/// One retryable action on one subject. A failure stays beside its subject until
/// another attempt or a verified read clears it, so a failed action never reads
/// as finished and its row keeps its retry.
struct SkillActionAttempt<Subject: Equatable>: Equatable {
    private(set) var inFlight: Subject?
    private(set) var failed: Subject?

    var isInFlight: Bool { inFlight != nil }
    var hasFailed: Bool { failed != nil }

    func isInFlight(_ subject: Subject) -> Bool { inFlight == subject }

    mutating func begin(_ subject: Subject) {
        inFlight = subject
        failed = nil
    }

    mutating func finish(_ subject: Subject) {
        if inFlight == subject { inFlight = nil }
    }

    /// An attempt for another subject owns the state, so this report no longer counts.
    mutating func fail(_ subject: Subject) {
        guard inFlight == nil || inFlight == subject else { return }
        inFlight = nil
        failed = subject
    }

    mutating func clearFailure() {
        failed = nil
    }

    mutating func keepFailure(where stillExists: (Subject) -> Bool) {
        if let failed, !stillExists(failed) { self.failed = nil }
    }
}

/// The controls are one subject: a change and the durable read that verifies it.
enum SkillControlsSubject: Equatable {
    case controls
}

/// Reads never lock the controls; only a change, or a state no read has verified, does.
func skillControlsAreLocked(
    hasSnapshot: Bool,
    isChanging: Bool,
    hasUnverifiedChange: Bool
) -> Bool {
    !hasSnapshot || isChanging || hasUnverifiedChange
}
