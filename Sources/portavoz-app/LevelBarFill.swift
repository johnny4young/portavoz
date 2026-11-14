import SwiftUI

/// Leading capsule fill for a level bar, drawn as a fraction of its bounds.
/// Host it in an overlay of the fixed-size track: a changing shape placed
/// directly in a stack still invalidates the layout around it.
struct LevelBarFill: Shape {
    var fraction: CGFloat

    var animatableData: CGFloat {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let width = rect.width * Self.clamped(fraction)
        guard width > 0 else { return Path() }
        return Capsule().path(in: CGRect(
            x: rect.minX, y: rect.minY, width: width, height: rect.height))
    }

    static func clamped(_ fraction: CGFloat) -> CGFloat {
        fraction.isFinite ? max(0, min(1, fraction)) : 0
    }

    /// Maps a linear peak onto the bar: −60 dBFS is empty, 0 dBFS is full.
    static func fraction(forLevel level: Float) -> CGFloat {
        guard level > 0.0001 else { return 0 }
        let decibels = 20 * log10(level)
        return CGFloat(max(0, min(1, (Double(decibels) + 60) / 60)))
    }
}

/// Same-width stand-in for the recording clock: every digit becomes a zero,
/// so it only changes when the clock gains a digit.
enum RecordingClockTemplate {
    static func placeholder(for clock: String) -> String {
        String(clock.map { $0.isNumber ? "0" : $0 })
    }
}
