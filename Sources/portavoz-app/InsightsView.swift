import IntegrationsKit
import PortavozCore
import StorageKit
import SwiftUI

/// The Insights dashboard: what your meeting life looks like, computed
/// 100% locally from the library — totals, cadence, people, commitments.
struct InsightsView: View {
    @Environment(AppServices.self) private var services

    @State private var stats: LibraryStats?
    @State private var facts: MeetingStore.LibraryFacts?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Insights")
                        .font(.largeTitle.bold())
                        .accessibilityIdentifier("insights-title")
                    Spacer()
                    Label("Computed on your Mac — nothing leaves it.", systemImage: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if let stats {
                    tiles(stats)
                    rhythmHeatmap(stats)
                }
                if let facts {
                    HStack(alignment: .top, spacing: 16) {
                        participantsCard(facts)
                        commitmentsCard(facts)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 860, alignment: .leading)
        }
        .task(id: services.libraryVersion) { await reload() }
    }

    private func reload() async {
        let meetings = (try? await services.store.meetings()) ?? []
        stats = LibraryStats.compute(meetings: meetings)
        facts = try? await services.store.libraryFacts()
    }

    // MARK: - Tiles

    private func tiles(_ stats: LibraryStats) -> some View {
        HStack(spacing: 12) {
            tile(
                value: "\(stats.totalMeetings)",
                label: L10n.text("meetings"),
                delta: weeklyDelta(stats),
                waveform: true)
            tile(value: hours(stats.totalSeconds), label: L10n.text("recorded"))
            tile(value: minutes(stats.averageSeconds), label: L10n.text("avg length"))
            tile(value: "\(stats.weeklyStreak)", label: L10n.text("week streak"))
            if let weekday = stats.busiestWeekday {
                tile(value: weekdayName(weekday), label: L10n.text("busiest day"))
            }
        }
    }

    /// This week vs last week, from the two newest buckets — a real delta,
    /// nil when there isn't enough history to compare.
    private func weeklyDelta(_ stats: LibraryStats) -> Int? {
        guard stats.perWeek.count >= 2 else { return nil }
        return stats.perWeek[stats.perWeek.count - 1].count
            - stats.perWeek[stats.perWeek.count - 2].count
    }

    private func tile(
        value: String, label: String, delta: Int? = nil, waveform: Bool = false
    ) -> some View {
        HStack(spacing: 10) {
            if waveform {
                miniWaveform
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(value)
                        .font(.title2.bold())
                        .monospacedDigit()
                    if let delta, delta != 0 {
                        Text(delta > 0 ? "▲ +\(delta)" : "▼ \(delta)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(delta > 0 ? Color.green : .secondary)
                    }
                }
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    /// A tiny four-bar waveform whose peak is your amber — the brand mark
    /// as a stat accent.
    private var miniWaveform: some View {
        HStack(alignment: .bottom, spacing: 2.5) {
            ForEach(Array([0.4, 0.55, 0.7, 1.0].enumerated()), id: \.offset) { index, height in
                Capsule()
                    .fill(index == 3 ? PVDesign.accent : PVDesign.accent.opacity(0.4))
                    .frame(width: 4, height: 28 * height)
            }
        }
        .frame(height: 28)
    }

    // MARK: - Rhythm heatmap

    private func rhythmHeatmap(_ stats: LibraryStats) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Your rhythm · 12 weeks")
                    .font(.headline)
                    .accessibilityIdentifier("insights-heatmap")
                Text("column = week · row = weekday · more intense = more meetings")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 7) {
                VStack(alignment: .trailing, spacing: 4) {
                    ForEach(weekdayInitials, id: \.self) { day in
                        Text(day)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .frame(height: 13)
                    }
                }
                HStack(spacing: 4) {
                    ForEach(Array(stats.heatmap.enumerated()), id: \.offset) { _, week in
                        VStack(spacing: 4) {
                            ForEach(Array(week.enumerated()), id: \.offset) { _, count in
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(heatColor(count, max: stats.heatmapMax))
                                    .frame(height: 13)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    /// The intensity ramp: quiet fill → full accent as the cell's count
    /// approaches the busiest cell.
    private func heatColor(_ count: Int, max: Int) -> Color {
        guard count > 0, max > 0 else { return .primary.opacity(0.06) }
        let step = Double(count) / Double(max)
        return PVDesign.accent.opacity(0.18 + 0.82 * step)
    }

    /// Weekday initials starting at the calendar's first weekday, so the
    /// rows line up with `heatmap`'s ordering.
    private var weekdayInitials: [String] {
        let calendar = Calendar.current
        let symbols = calendar.veryShortWeekdaySymbols
        return (0..<7).map { symbols[(calendar.firstWeekday - 1 + $0) % 7] }
    }

    // MARK: - People & commitments

    private func participantsCard(_ facts: MeetingStore.LibraryFacts) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("People you meet with")
                .font(.headline)
            if facts.topParticipants.isEmpty {
                Text("Name speakers in your meetings and the people you meet most will show up here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(facts.topParticipants) { person in
                HStack {
                    Text(person.name)
                    Spacer()
                    Text(L10n.format("%d meetings", person.meetings))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    private func commitmentsCard(_ facts: MeetingStore.LibraryFacts) -> some View {
        let total = facts.openActionItems + facts.doneActionItems
        return VStack(alignment: .leading, spacing: 8) {
            Text("Action items")
                .font(.headline)
            if total == 0 {
                Text("Summaries with commitments will count here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Gauge(value: Double(facts.doneActionItems), in: 0...Double(total)) {
                    EmptyView()
                } currentValueLabel: {
                    Text("\(facts.doneActionItems)/\(total)")
                        .monospacedDigit()
                }
                .gaugeStyle(.accessoryCircularCapacity)
                .tint(PVDesign.accent)
                Text(L10n.format("%d still open", facts.openActionItems))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Formatting

    private func hours(_ seconds: TimeInterval) -> String {
        let hours = seconds / 3600
        return hours >= 10
            ? String(format: "%.0f h", hours)
            : String(format: "%.1f h", hours)
    }

    private func minutes(_ seconds: TimeInterval) -> String {
        String(format: "%.0f min", seconds / 60)
    }

    private func weekdayName(_ weekday: Int) -> String {
        let symbols = Calendar.current.shortWeekdaySymbols
        let index = weekday - 1
        return symbols.indices.contains(index) ? symbols[index] : "—"
    }
}
