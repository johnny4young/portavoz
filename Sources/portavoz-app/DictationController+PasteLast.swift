import Foundation

extension DictationController {
    /// Words in recovery are the last dictation too, so they follow its lifetime:
    /// sleep, lock or 15 minutes end Paste last, while the panel keeps Copy.
    var hasPastableText: Bool { lastText.current != nil }

    func pastableText() -> String? { lastText.takeCurrent() }
}
