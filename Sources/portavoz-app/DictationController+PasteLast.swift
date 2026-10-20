import Foundation

extension DictationController {
    /// Whether Paste last has words to deliver, including ones left in recovery.
    var hasPastableText: Bool {
        if case .recovery = phase, !recoveryText.isEmpty { return true }
        return lastText.current != nil
    }

    /// Undelivered words in recovery are the last dictation, so they paste first.
    func pastableText() -> String? {
        if case .recovery = phase, !recoveryText.isEmpty { return recoveryText }
        return lastText.takeCurrent()
    }
}
