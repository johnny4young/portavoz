import IntegrationsKit
import PortavozCore
import StorageKit
import SwiftUI

/// The Insights dashboard: what your meeting life looks like, computed
/// 100% locally from the library — scoped totals, cadence, and who you
/// talk with (and how much). Design system 3a.
struct InsightsView: View {
    @Environment(AppServices.self) private var services

    @State private var meetings: [Meeting] = []
    @State private var stats: LibraryStats?
    @State private var facts: MeetingStore.LibraryFacts?
    @State private var balance: MeetingStore.VoiceBalance?
    @AppStorage("insightsScope") private var scopeRaw = InsightsScope.week.rawValue

    private var scope: InsightsScope { InsightsScope(rawValue: scopeRaw) ?? .week }

    /// Violet for "them" in the participation bar — amber (VoicePalette.me)
    /// stays reserved for you.
    private let themViolet = Color(.sRGB, red: 0.545, green: 0.486, blue: 0.941, opacity: 1)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let stats {
                    tiles(stats)
                    HStack(alignment: .top, spacing: 16) {
                        rhythmHeatmap(stats)
                        if let balance, !balance.participants.isEmpty {
                            participationCard(balance)
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 920, alignment: .leading)
        }
        .task(id: services.libraryVersion) { await reload() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Insights")
                .font(.largeTitle.bold())
                .accessibilityIdentifier("insights-title")
            Picker("", selection: $scopeRaw) {
                Text("Week").tag(InsightsScope.week.rawValue)
                Text("Month").tag(InsightsScope.month.rawValue)
                Text("Year").tag(InsightsScope.year.rawValue)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("insights-scope")
            Spacer()
            Label("Computed on your Mac — nothing leaves it.", systemImage: "lock.fill")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func reload() async {
        meetings = (try? await services.store.meetings()) ?? []
        stats = LibraryStats.compute(meetings: meetings)
        facts = try? await services.store.libraryFacts()
        balance = try? await services.store.voiceBalance()
    }

    // MARK: - Tiles

    private func tiles(_ stats: LibraryStats) -> some View {
        let totals = ScopedTotals.compute(meetings: meetings, scope: scope)
        return HStack(spacing: 12) {
            tile(
                value: "\(totals.count)",
                label: L10n.format("meetings · vs %@", previousPeriodName),
                delta: totals.deltaCount,  // tile() hides a zero delta on its own
                waveform: true)
            tile(
                value: hours(totals.seconds),
                label: L10n.format("recorded · %@ avg", minutes(totals.averageSeconds)))
            balanceTile
            commitmentsTile
        }
    }

    /// The talk-balance tile: a small amber ring + "you speak X% · listen Y%".
    @ViewBuilder private var balanceTile: some View {
        if let balance, balance.hasData {
            let share = balance.myOverallShare
            HStack(spacing: 10) {
                ZStack {
                    Circle().stroke(themViolet.opacity(0.35), lineWidth: 5)
                    Circle()
                        .trim(from: 0, to: share)
                        .stroke(VoicePalette.me, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text("\(percent(share))")
                        .font(.caption2.weight(.bold).monospacedDigit())
                }
                .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Talk balance").font(.caption.weight(.medium))
                    Text(L10n.format(
                        "you %d%% · listen %d%%",
                        Int((share * 100).rounded()), Int(((1 - share) * 100).rounded())))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(balanceHint(share))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityIdentifier("insights-balance")
        } else {
            tile(value: "—", label: L10n.text("talk balance"))
        }
    }

    /// The commitments tile ("Pendientes"): open/total, amber when overdue.
    @ViewBuilder private var commitmentsTile: some View {
        if let facts {
            let total = facts.openActionItems + facts.doneActionItems
            HStack(spacing: 10) {
                if total > 0 {
                    ZStack {
                        Circle().stroke(.quaternary, lineWidth: 5)
                        Circle()
                            .trim(from: 0, to: Double(facts.doneActionItems) / Double(total))
                            .stroke(PVDesign.accent, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 40, height: 40)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text("\(facts.doneActionItems)/\(max(total, facts.doneActionItems))")
                            .font(.title3.bold().monospacedDigit())
                        if facts.openActionItems > 0 {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(PVDesign.brandAmber)
                        }
                    }
                    Text(facts.openActionItems > 0
                        ? L10n.format("%d open — review", facts.openActionItems)
                        : L10n.text("action items"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityIdentifier("insights-commitments")
        }
    }

    private var previousPeriodName: String {
        switch scope {
        case .week: return L10n.text("last week")
        case .month: return L10n.text("last month")
        case .year: return L10n.text("last year")
        }
    }

    private func balanceHint(_ share: Double) -> String {
        if share > 0.6 { return L10n.text("you speak more") }
        if share < 0.25 { return L10n.text("you listen more") }
        return L10n.text("balanced")
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
        .frame(maxWidth: .infinity, alignment: .leading)
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

    // MARK: - Who you talk with, and how much

    private func participationCard(_ balance: MeetingStore.VoiceBalance) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Identifier on the title leaf, not the container: a container
            // `.accessibilityIdentifier` stamps every descendant on macOS,
            // which would clobber each participant bar's own id.
            Text("Who you talk with, and how")
                .font(.headline)
                .accessibilityIdentifier("insights-participants")
            ForEach(balance.participants) { person in
                participantRow(person)
            }
            Text("violet = they speak · amber = you. The bar is your share of talk with them.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
        }
        .frame(width: 320, alignment: .leading)
        .padding(16)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    private func participantRow(_ person: MeetingStore.ParticipantVoice) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                avatar(person.name)
                Text(person.name)
                    .font(.callout.weight(.medium))
                    .accessibilityIdentifier("insights-participant-\(person.id)")
                Spacer()
                Text(L10n.format("%d meetings · %@", person.meetings, minutes(person.theirSeconds)))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            participationBar(share: person.myShareWithThem)
        }
    }

    /// The amber/violet split bar: amber (you) grows from the left to
    /// `share`, violet (them) fills the rest.
    private func participationBar(share: Double) -> some View {
        GeometryReader { geometry in
            let clamped = min(max(share, 0), 1)
            HStack(spacing: 0) {
                Rectangle().fill(VoicePalette.me)
                    .frame(width: geometry.size.width * clamped)
                Rectangle().fill(themViolet)
            }
        }
        .frame(height: 7)
        .clipShape(Capsule())
    }

    private func avatar(_ name: String) -> some View {
        Text(String(name.prefix(1)).uppercased())
            .font(.caption2.weight(.bold))
            .frame(width: 22, height: 22)
            .background(themViolet.opacity(0.25), in: Circle())
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

    private func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }
}
