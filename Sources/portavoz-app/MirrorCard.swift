import ApplicationKit
import SwiftUI

/// The post-meeting mirror (design system 6a-2): an opt-in card that shows
/// the user their own numbers next to their personal average — "measured,
/// not judged". Three tiles + one factual synthesis line + two actions.
/// Never blocks; never uses evaluative language.
struct MirrorCard: View {
    /// The user's own numbers, resolved by the caller from the meeting's
    /// health (the `isMe` speaker) — passed in so the card is pure layout.
    let myShare: Double
    let myQuestions: Int
    let myInterruptions: Int
    let language: String
    let averageShare: Double?
    let onSeeTrend: () -> Void
    let onDismiss: () -> Void
    let onTurnOff: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .foregroundStyle(PVDesign.accent)
                Text("Your mirror")
                    .font(.title2.bold())
                Spacer()
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.text("Close"))
            }

            HStack(spacing: 10) {
                tile(
                    percent(myShare),
                    L10n.text("you spoke"),
                    highlight: averageShare.map {
                        MirrorStats.isNotable(myShare: myShare, average: $0)
                    } ?? false)
                tile("\(myQuestions)", L10n.text("questions you asked"))
                tile("\(myInterruptions)", L10n.text("interruptions"))
            }

            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.caption)
                    .foregroundStyle(PVDesign.chipAISpark)
                Text(MirrorStats.synthesis(
                    myShare: myShare, average: averageShare,
                    questions: myQuestions, language: language))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button {
                    onSeeTrend()
                } label: {
                    Label("See my trend", systemImage: "chart.bar.xaxis")
                }
                .buttonStyle(.borderedProminent)
                .tint(PVDesign.accent)
                Spacer()
                Button(L10n.text("Don’t show after each meeting")) {
                    onTurnOff()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Text("Measured, not judged — computed on your Mac from this meeting and your library.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(width: 460)
        .accessibilityIdentifier("mirror-card")
    }

    private func tile(_ value: String, _ label: String, highlight: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.title.weight(.bold).monospacedDigit())
                .foregroundStyle(highlight ? VoicePalette.me : .primary)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 62, alignment: .topLeading)
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    private func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }
}
