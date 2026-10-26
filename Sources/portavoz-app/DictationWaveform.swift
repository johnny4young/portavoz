import SwiftUI

/// Overlapping sine waves whose height follows the microphone level. It
/// animates at 30 fps only while `isActive`, and stays a flat line in silence.
struct DictationWaveform: View {
    let level: Float
    let isActive: Bool
    var dimmed = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isActive)) { context in
            Canvas { canvas, size in
                let time = context.date.timeIntervalSinceReferenceDate
                let amplitude = DictationWaveformShape.amplitude(for: level)
                let color = dimmed ? Color.secondary : PVDesign.accent
                for wave in DictationWaveformShape.waves {
                    var path = Path()
                    for step in 0...Int(size.width) {
                        let x = Double(step) / max(1, Double(size.width))
                        let y = DictationWaveformShape.offset(at: x, time: time, wave: wave, amplitude: amplitude)
                        let point = CGPoint(x: CGFloat(step), y: size.height / 2 * CGFloat(1 - y))
                        if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                    canvas.stroke(path, with: .color(color.opacity(wave.opacity)), lineWidth: wave.lineWidth)
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(L10n.text("Audio level"))
    }
}

/// The waveform's pure geometry, kept off the main actor so it is testable anywhere.
enum DictationWaveformShape {
    struct Wave {
        let cycles: Double
        let speed: Double
        let scale: Double
        let opacity: Double
        let lineWidth: CGFloat
    }

    static let waves = [
        Wave(cycles: 1.5, speed: 5.0, scale: 1.0, opacity: 1.0, lineWidth: 1.8),
        Wave(cycles: 2.2, speed: -3.6, scale: 0.7, opacity: 0.55, lineWidth: 1.2),
        Wave(cycles: 3.1, speed: 7.2, scale: 0.45, opacity: 0.35, lineWidth: 1.0)
    ]

    /// The recording HUD's dB mapping (−60 dB → 0, 0 dB → 1), with a floor so silence still reads as a line.
    static func amplitude(for level: Float) -> Double {
        guard level > 0.0001 else { return 0.04 }
        let decibels = 20 * log10(Double(level))
        return max(0.04, min(1, (decibels + 60) / 60))
    }

    /// Vertical offset in −1…1; a sine envelope pins both ends to the center line.
    static func offset(at x: Double, time: Double, wave: Wave, amplitude: Double) -> Double {
        let envelope = sin(.pi * x)
        return envelope * amplitude * wave.scale * sin(2 * .pi * wave.cycles * x + time * wave.speed)
    }
}
