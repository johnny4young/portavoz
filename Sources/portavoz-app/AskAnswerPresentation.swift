import ApplicationKit

enum AskAnswerPresentation {
    static func text(for result: AskMeetingAnswer) -> String {
        guard !result.citations.isEmpty else {
            return L10n.text("Nothing related in your meetings yet.")
        }
        return result.generatedText
            ?? L10n.text("Closest passages from your meetings:")
    }

    static func statusText(
        for outcome: AskGenerationOutcome,
        hasCitations: Bool
    ) -> String? {
        guard hasCitations else { return nil }
        switch outcome {
        case .notRequested, .generated:
            return nil
        case .unavailable:
            return L10n.text(
                "Your selected local answer engine is unavailable. Exact passages are still shown.")
        case .failed:
            return L10n.text(
                "Your selected local answer engine could not finish. Exact passages are still shown.")
        case .timedOut:
            return L10n.text(
                "Your selected local answer engine took too long. Exact passages are still shown.")
        }
    }
}
