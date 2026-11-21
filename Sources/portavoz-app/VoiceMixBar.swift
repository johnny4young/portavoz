import ApplicationKit
import SwiftUI

/// The sidebar's signature (design system): a thin capsule under each
/// meeting row split into voice-colored segments proportional to who
/// spoke. Voices past the cast share one grey segment at the end.
struct VoiceMixBar: View {
    let slices: [LibraryVoiceMixSlice]
    let colorScheme: ColorScheme

    private var segments: [(tint: VoiceCast.Tint, fraction: Double)] {
        let cast = VoiceCast(mix: slices)
        let voices = cast.voices.map { (tint: $0.tint, fraction: $0.share) }
        return cast.others.isEmpty ? voices : voices + [(tint: .grey, fraction: cast.othersShare)]
    }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 1.5) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    Capsule()
                        .fill(VoicePalette.color(segment.tint, colorScheme: colorScheme))
                        .frame(width: max(2, geo.size.width * segment.fraction))
                        .opacity(segment.tint == .you ? 1 : 0.8)
                }
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}
