import StorageKit
import SwiftUI

/// The sidebar's signature (design system): a thin capsule under each
/// meeting row split into voice-colored segments proportional to who
/// spoke — your amber always reads first. The library becomes a shelf of
/// conversations you can size up at a glance, no other meeting app has it.
struct VoiceMixBar: View {
    let slices: [MeetingStore.VoiceMixSlice]
    let colorScheme: ColorScheme

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 1.5) {
                ForEach(Array(slices.enumerated()), id: \.offset) { _, slice in
                    Capsule()
                        .fill(VoicePalette.color(for: slice, colorScheme: colorScheme))
                        .frame(width: max(2, geo.size.width * slice.fraction))
                        .opacity(slice.isMe ? 1 : 0.8)
                }
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}
