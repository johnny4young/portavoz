/// Storage-independent facts used to decide whether first-run setup should
/// appear. Composition gathers these facts; presentation renders the result.
public struct FirstRunOnboardingContext: Equatable, Sendable {
    public let forceRequested: Bool
    public let automationSuppressed: Bool
    public let hasCompleted: Bool
    public let hasExistingMeetings: Bool

    public init(
        forceRequested: Bool,
        automationSuppressed: Bool,
        hasCompleted: Bool,
        hasExistingMeetings: Bool
    ) {
        self.forceRequested = forceRequested
        self.automationSuppressed = automationSuppressed
        self.hasCompleted = hasCompleted
        self.hasExistingMeetings = hasExistingMeetings
    }
}

public enum FirstRunOnboardingDecision: Equatable, Sendable {
    case show
    case hide
    /// An existing library proves setup happened in an older build. Remember
    /// that fact so later launches avoid another database read.
    case hideAndRememberCompleted
}

/// Deterministic first-run policy. A forced developer/test presentation wins
/// over every suppression rule; onboarding never owns model readiness.
public enum FirstRunOnboardingPolicy {
    public static func decide(
        _ context: FirstRunOnboardingContext
    ) -> FirstRunOnboardingDecision {
        if context.forceRequested { return .show }
        if context.automationSuppressed || context.hasCompleted { return .hide }
        if context.hasExistingMeetings { return .hideAndRememberCompleted }
        return .show
    }
}
