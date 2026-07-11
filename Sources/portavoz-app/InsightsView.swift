import Charts
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
            VStack(alignment: .leading, spacing: 20) {
                Text("Insights")
                    .font(.largeTitle.bold())
                if let stats {
                    tiles(stats)
                    cadenceChart(stats)
                }
                if let facts {
                    HStack(alignment: .top, spacing: 16) {
                        participantsCard(facts)
                        commitmentsCard(facts)
                    }
                }
                Text("Computed on your Mac, from your library — nothing leaves it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
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
                label: L10n.text("meetings"))
            tile(
                value: hours(stats.totalSeconds),
                label: L10n.text("recorded"))
            tile(
                value: minutes(stats.averageSeconds),
                label: L10n.text("avg length"))
            tile(
                value: "\(stats.weeklyStreak)",
                label: L10n.text("week streak"))
            if let weekday = stats.busiestWeekday {
                tile(
                    value: weekdayName(weekday),
                    label: L10n.text("busiest day"))
            }
        }
    }

    private func tile(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title2.bold())
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Cadence

    private func cadenceChart(_ stats: LibraryStats) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Meetings per week")
                .font(.headline)
            Chart(stats.perWeek) { bucket in
                BarMark(
                    x: .value("Week", bucket.weekStart, unit: .weekOfYear),
                    y: .value("Meetings", bucket.count)
                )
                .foregroundStyle(Color.accentColor.gradient)
                .cornerRadius(3)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .weekOfYear, count: 2)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                }
            }
            .frame(height: 160)
        }
        .padding(16)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
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
                .tint(Color.accentColor)
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
