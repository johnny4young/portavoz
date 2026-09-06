import PortavozCore
import SwiftUI

/// Capture loss never disappears when a derived processing job succeeds.
struct CaptureReportNotice: View {
    let report: CaptureReport

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(L10n.text("Recording interrupted"), systemImage: "waveform.badge.exclamationmark")
                .font(.callout.weight(.semibold))
            Text(L10n.text("Review the available audio. Retranscribing cannot restore missing audio."))
                .font(.callout)
            ForEach(report.channels.filter(\.requiresAttention), id: \.channel) { channel in
                Text(channel.channel == .microphone ? L10n.text("Microphone audio is incomplete.")
                     : channel.channel == .room ? L10n.text("Room audio is incomplete.")
                     : L10n.text("Remote audio is incomplete."))
                    .font(.caption)
                    .accessibilityIdentifier("detail-capture-failure-\(channel.channel.rawValue)")
            }
        }
        .foregroundStyle(.orange)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail-capture-report")
    }
}
