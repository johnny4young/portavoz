import Foundation

/// Pure decision table for the mouse-button push-to-talk trigger. A spare
/// mouse button is a dedicated PTT surface: press starts capture, release
/// delivers. Unlike the keyboard hotkey there is no tap-vs-hold
/// discriminator — the capture-minimum policy already cancels an
/// accidental click's too-short session. Lives here (not in the app
/// executable) so it is unit-testable.
public enum MousePTTGesture {
    public enum Event: Sendable {
        case press
        case release
    }

    public enum Action: Equatable, Sendable {
        case start
        case finish
        case ignore
    }

    /// - Parameters:
    ///   - isListening: a dictation session is currently capturing.
    ///   - mouseOwnsSession: the active session was started by this mouse
    ///     button (false when the keyboard hotkey started it).
    public static func action(
        for event: Event,
        isListening: Bool,
        mouseOwnsSession: Bool
    ) -> Action {
        switch event {
        case .press:
            // Pressing while a hotkey-started session listens acts as the
            // finish gesture — one physical control always ends capture.
            return isListening ? .finish : .start
        case .release:
            // Only the button that started the session may deliver on
            // release; a stray release (session already finished at press,
            // or hotkey owns it) must not double-finish.
            return isListening && mouseOwnsSession ? .finish : .ignore
        }
    }
}
