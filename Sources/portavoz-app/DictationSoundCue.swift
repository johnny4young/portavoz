import AppKit

/// Optional audible capture edges: the microphone is live, then closed.
enum DictationSoundCue: Equatable, Sendable {
    case start
    case stop

    static let defaultsKey = "dictationSoundCues"

    /// Read once per session; off unless the user enabled it.
    @MainActor
    static func player(defaults: UserDefaults) -> (Self) -> Void {
        guard defaults.bool(forKey: defaultsKey) else { return { _ in } }
        return { cue in NSSound(named: cue.systemSoundName)?.play() }
    }

    private var systemSoundName: NSSound.Name {
        switch self {
        case .start: "Tink"
        case .stop: "Pop"
        }
    }
}
