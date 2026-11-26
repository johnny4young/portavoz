import ApplicationKit
import PortavozCore
import SwiftUI

/// Meetings to pick back up: each shows where listening stopped on its voice
/// strip, its open to-dos and who spoke. A row opens the meeting, which
/// resumes where listening stopped.
struct HomePickUp: View {
    let rows: [TodayPickUp.Row]
    let hasMeetings: Bool
    /// Draws each strip in the colours the rest of Today uses.
    let page: TodayPageCast
    let openItems: [LibraryOpenItem]
    let onOpen: (MeetingID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HomeSectionHeader(title: L10n.text("Pick up where you left off"))
            if rows.isEmpty { HomeSectionEmpty(key: hasMeetings ? "Nothing left to pick up" : "No meetings yet") }
            ForEach(rows) { row in
                HomeSectionRule()
                self.row(row)
            }
        }
    }

    private func row(_ row: TodayPickUp.Row) -> some View {
        let meeting = row.meeting
        let strip = page.strip(for: meeting.id) ?? .empty
        let progress = row.progress.map {
            PVFont.timeCoded(Self.progressText($0), time: Self.stoppedAt($0), weight: .semibold)
        }
        let openCount = openItems.count { $0.meetingID == meeting.id }
        return Button {
            onOpen(meeting.id)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(PVDesign.onInk)
                        .offset(x: 1)
                        .frame(width: 22, height: 22)
                        .background(PVDesign.ink, in: Circle())
                        .accessibilityHidden(true)
                    Text(MeetingRowTitle.display(meeting.title))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(PVDesign.ink)
                        .lineLimit(1)
                        .layoutPriority(1)
                    Text(meeting.recentDayAndLength())
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(PVDesign.ink3)
                        .lineLimit(1)
                    Spacer(minLength: PVDesign.space2)
                    lifecycleBadge(meeting.lifecycleState)
                    if let progress {
                        Text(progress)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(PVDesign.ink2)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    if openCount > 0 {
                        HomeChip(text: L10n.format("%d open", openCount))
                    }
                }
                // The row reads the cast below as its value instead.
                VoiceStrip(strip, size: .resume, progress: row.playedFraction(of: strip.duration))
                    .accessibilityHidden(true)
                    .padding(.top, 8)
                if !strip.columns.isEmpty {
                    FlowLayout(spacing: 12, rowSpacing: 4) { VoiceLegend(cast: strip.cast, font: .caption) }
                        .padding(.top, 6)
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(row.progress.flatMap(Self.stoppedHelp) ?? L10n.text("Open this meeting"))
        .accessibilityValue(VoiceStrip(strip).spokenCast)
        .accessibilityIdentifier("home-recent-\(meeting.id.rawValue.uuidString)")
    }

    @ViewBuilder
    private func lifecycleBadge(_ lifecycle: MeetingLifecycleState) -> some View {
        switch lifecycle {
        case .processing, .captured:
            Label("Processing", systemImage: "gearshape.2")
                .font(.caption)
                .foregroundStyle(PVDesign.ink3)
        case .needsAttention:
            Label("Needs attention", systemImage: PVSymbol.warning)
                .font(.caption)
                .cautionText()
        case .recording, .ready:
            EmptyView()
        }
    }

    nonisolated static func stoppedHelp(_ progress: TodayPickUp.Progress) -> String? {
        guard case .stopped = progress else { return nil }
        return L10n.text("Open this meeting where you stopped listening")
    }

    nonisolated static func progressText(_ progress: TodayPickUp.Progress) -> String {
        switch progress {
        case .stopped(let seconds):
            L10n.format("stopped at %@", clock(seconds))
        case .unheard:
            L10n.text("unheard")
        }
    }

    nonisolated static func stoppedAt(_ progress: TodayPickUp.Progress) -> String? {
        guard case .stopped(let seconds) = progress else { return nil }
        return clock(seconds)
    }

    nonisolated private static func clock(_ seconds: TimeInterval) -> String {
        ClockFormat.mmss(seconds, locale: AppLanguage.current.locale)
    }
}
