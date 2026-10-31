import Foundation

enum SummarySetupIssue: Equatable {
    case appleUnavailable(String)
    case ollamaModelNotSelected
    case mlxModelNotDownloaded
    case localEngineFailed

    // Localization keys remain whole so the runtime catalog lookup and its
    // placeholder test see the exact user-facing sentence.
    // swiftlint:disable line_length
    var message: String {
        switch self {
        case .appleUnavailable(let reason):
            return L10n.format(
                "Apple summaries are unavailable: %@. Choose Ollama or Built-in (MLX) in Intelligence Settings.",
                reason)
        case .ollamaModelNotSelected:
            return L10n.text(
                "Ollama is selected, but no chat model is configured. Open Intelligence Settings, detect your local models, and choose one.")
        case .mlxModelNotDownloaded:
            return L10n.text(
                "The Built-in summary model has not been downloaded. Open Intelligence Settings and download it once (about 3 GB).")
        case .localEngineFailed:
            return L10n.text(
                "The local model couldn’t finish this summary. Try again with a shorter detail level, or check its model in Intelligence Settings.")
        }
    }

    var title: String {
        self == .localEngineFailed
            ? L10n.text("Summary couldn’t finish")
            : L10n.text("Summary needs setup")
    }
    // swiftlint:enable line_length
}
