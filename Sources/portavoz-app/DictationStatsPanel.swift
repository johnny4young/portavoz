import PortavozCore
import SwiftUI

/// The top of the Dictations page while statistics are on: totals for the
/// last 7 or 30 days, words per day and the apps you dictate into most.
struct DictationStatsPanel: View {
    let model: DictationStatsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Your dictation").font(.headline)
                Spacer()
                Picker("Period", selection: Binding(
                    get: { model.range },
                    set: { value in Task { await model.show(range: value) } })) {
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("dictation-stats-range")
            }
            let totals = model.summary.totals
            if totals.dictations == 0 {
                Text("No dictations counted in this period yet.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("dictation-stats-empty")
            } else {
                tiles(totals)
                bars
                applications
            }
            Text("Time saved assumes typing at 40 words per minute.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: PVDesign.radiusSmall))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dictation-stats")
    }

    private func tiles(_ totals: DictationStatsTotals) -> some View {
        HStack(alignment: .top, spacing: 24) {
            tile(L10n.text("Dictations"), "\(totals.dictations)", identifier: "dictation-stats-dictations")
            tile(L10n.text("Words"), "\(totals.words)", identifier: "dictation-stats-words")
            tile(L10n.text("Speaking"), minutes(totals.spokenDuration), identifier: "dictation-stats-speaking")
            tile(L10n.text("Time saved"), "~" + minutes(totals.estimatedTimeSaved), identifier: "dictation-stats-saved")
            if totals.notDelivered > 0 {
                tile(L10n.text("Not delivered"), "\(totals.notDelivered)", identifier: "dictation-stats-not-delivered")
            }
        }
    }

    private func tile(_ title: String, _ value: String, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }

    private var bars: some View {
        let days = model.summary.days
        let peak = max(days.map(\.totals.words).max() ?? 0, 1)
        return HStack(alignment: .bottom, spacing: days.count > 10 ? 2 : 6) {
            ForEach(days, id: \.day) { day in
                RoundedRectangle(cornerRadius: 2)
                    .fill(day.totals.words > 0 ? PVDesign.accent : Color.secondary.opacity(0.2))
                    .frame(height: max(3, 48 * CGFloat(day.totals.words) / CGFloat(peak)))
                    .frame(maxWidth: .infinity)
                    .help(L10n.format("%@: %d words", day.day, day.totals.words))
            }
        }
        .frame(height: 48)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var applications: some View {
        if !model.summary.topApplications.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Where you dictate most").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(Array(model.summary.topApplications.enumerated()), id: \.offset) { index, app in
                    HStack {
                        Text(app.name)
                        Spacer()
                        Text("\(app.dictations)").monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("dictation-stats-app-\(index)")
                }
            }
        }
    }

    private func minutes(_ duration: TimeInterval) -> String {
        L10n.format("%d min", Int((duration / 60).rounded()))
    }
}
