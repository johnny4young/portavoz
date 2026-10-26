import Foundation

/// The session's capture claim. Polish ends it before the rewrite, so a local model
/// is never admitted against live capture; the session's own end is then a no-op.
@MainActor
final class DictationCaptureOwnership {
    private var finish: (() -> Void)?

    init(finish: @escaping () -> Void) {
        self.finish = finish
    }

    func end() {
        finish?()
        finish = nil
    }
}
