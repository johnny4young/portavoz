import ApplicationKit
import IntelligenceKit
import PortavozCore
import SwiftUI

struct MeetingVoicesPlayback: Equatable {
    /// The voice playback is limited to.
    let focus: SpeakerID?
}

struct MeetingVoicesTableActions {
    let stepThroughTurns: @MainActor (MeetingVoiceTable.Row) -> Void
    let toggleOnly: @MainActor (MeetingVoiceTable.Row) -> Void
    let rename: @MainActor (Speaker) -> Void
    let acceptVoiceSuggestion: @MainActor (MeetingVoiceSuggestion) -> Void
    let dismissVoiceSuggestion: @MainActor (String) -> Void
}

/// Who spoke in a meeting, by talk share: each voice with its share, talk
/// time and turns on its own strip. You and five voices keep a row; the rest
/// fold into "Others · n", which opens to their rows.
struct MeetingVoicesTable<Trailing: View>: View {
    let table: MeetingVoiceTable
    let speakers: [Speaker]
    let voiceSuggestions: [MeetingVoiceSuggestion]
    /// Nil without audio.
    let playback: MeetingVoicesPlayback?
    var health: MeetingHealth?
    let actions: MeetingVoicesTableActions
    @ViewBuilder let trailing: Trailing
    @State private var showsOthers = false
    @State private var isNarrow = false
    /// The widest row's trailing controls, so every strip ends on one edge.
    @State private var trailingWidth: CGFloat = 0

    private var columnSpacing: CGFloat { isNarrow ? 8 : 12 }
    private var nameWidth: CGFloat { isNarrow ? 92 : 104 }

    var body: some View {
        let byID = Dictionary(speakers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let suggestions = Dictionary(
            voiceSuggestions.map { ($0.speakerLabel, $0) }, uniquingKeysWith: { first, _ in first })
        let healthBySpeaker = Dictionary(
            (health?.stats ?? []).map { ($0.speakerID, $0) }, uniquingKeysWith: { first, _ in first })
        Group {
            if table.count == 1, let onlyRow = table.rows.first, let speaker = byID[onlyRow.speakerID] {
                soloSummary(onlyRow, speaker: speaker, suggestion: suggestions[speaker.label])
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    heading.padding(.bottom, 6)
                    ForEach(table.rows) {
                        row($0, speaker: byID[$0.speakerID], stat: healthBySpeaker[$0.speakerID],
                            suggestions: suggestions)
                    }
                    if !table.others.isEmpty {
                        othersRow(names: table.others.compactMap { byID[$0.speakerID].map(VoiceName.of(_:)) })
                        // Collapsed, a folded voice still shows while it offers a name or plays alone.
                        ForEach(table.others.filter { other in
                            showsOthers || other.speakerID == playback?.focus
                                || byID[other.speakerID].map { suggestions[$0.label] != nil } == true
                        }) {
                            row($0, speaker: byID[$0.speakerID], stat: healthBySpeaker[$0.speakerID],
                                suggestions: suggestions)
                        }
                    }
                }
            }
        }
        .onGeometryChange(for: Bool.self) { $0.size.width < VoicesTableFormat.narrowWidth } action: {
            isNarrow = $0
        }
        .onPreferenceChange(TrailingWidthKey.self) { width in
            MainActor.assumeIsolated { trailingWidth = width }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail-voices")
    }

    private func soloSummary(
        _ row: MeetingVoiceTable.Row,
        speaker: Speaker,
        suggestion: MeetingVoiceSuggestion?
    ) -> some View {
        HStack(spacing: columnSpacing) {
            PVCardCaption(text: L10n.text("Voices"), tint: PVDesign.ink)
            nameButton(row, speaker: speaker)
            shareText(row.voice.share)
            timeText(row.voice.talkSeconds)
            if let suggestion {
                suggestionChip(suggestion)
            }
            trailing
            Spacer(minLength: 0)
        }
        .contextMenu {
            Button("Rename…") { actions.rename(speaker) }
                .accessibilityIdentifier("cast-speaker-rename-\(speaker.label)")
        }
    }

    private var heading: some View {
        HStack(spacing: 10) {
            PVCardCaption(text: L10n.text("Voices"), tint: PVDesign.ink)
            if table.count > 1 {
                Text(table.others.isEmpty
                    ? L10n.format("%d voices", table.count)
                    : L10n.format("%d voices · %d in colour", table.count, table.rows.count))
                    .font(.caption)
                    .foregroundStyle(PVDesign.ink3)
            }
            if let health, health.stats.count >= 2 {
                healthSummary(health)
            }
            trailing
            Spacer(minLength: 0)
        }
    }

    private func healthSummary(_ health: MeetingHealth) -> some View {
        HStack(spacing: 6) {
            if health.questionsTotal > 0 {
                healthChip(
                    PVSymbol.apuntador,
                    "\(health.questionsTotal)",
                    accessibilityLabel: L10n.format("%d questions", health.questionsTotal))
                    .help("Counts the questions asked in this meeting")
            }
            if health.interruptionsTotal > 0 {
                healthChip(
                    "exclamationmark.bubble",
                    "\(health.interruptionsTotal)",
                    accessibilityLabel: L10n.format("%d interruptions", health.interruptionsTotal))
                    .help("Counts how often someone talked over someone else")
            }
            if health.questionsTotal == 0 && health.interruptionsTotal == 0 {
                Text("No questions or interruptions.")
                    .font(.caption)
                    .foregroundStyle(PVDesign.ink3)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail-meeting-health")
    }

    private func healthChip(_ icon: String, _ value: String, accessibilityLabel: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .accessibilityHidden(true)
            Text(value).monospacedDigit()
        }
        .font(.caption2)
        .foregroundStyle(PVDesign.ink3)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.quaternary.opacity(0.6), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private func row(
        _ row: MeetingVoiceTable.Row,
        speaker: Speaker?,
        stat: MeetingHealth.SpeakerStat?,
        suggestions: [String: MeetingVoiceSuggestion]
    ) -> some View {
        if let speaker {
            HStack(spacing: columnSpacing) {
                nameButton(row, speaker: speaker)
                shareText(row.voice.share)
                if !isNarrow { timeText(row.voice.talkSeconds) }
                VoiceTurnsStrip(turns: row.turns, duration: table.duration, tint: row.voice.tint)
                    .frame(minWidth: 48, maxWidth: .infinity)
                    .layoutPriority(-1)
                    .accessibilityIdentifier("voice-turns-\(speaker.label)")
                HStack(spacing: 6) {
                    if !isNarrow, let stat, stat.questions > 0 {
                        healthChip(
                            PVSymbol.apuntador,
                            "\(stat.questions)",
                            accessibilityLabel: L10n.format("%d questions", stat.questions))
                            .help("Counts the questions this speaker asked")
                    }
                    if !isNarrow, let stat, stat.interruptionsMade > 0 {
                        healthChip(
                            "exclamationmark.bubble",
                            "\(stat.interruptionsMade)",
                            accessibilityLabel: L10n.format("%d interruptions", stat.interruptionsMade))
                            .help("Counts how often this speaker interrupted")
                    }
                    if let suggestion = suggestions[speaker.label] {
                        suggestionChip(suggestion)
                    }
                    if playback != nil && table.count > 1 {
                        onlyButton(row, speaker: speaker)
                    }
                }
                // The strip yields first; a long chip truncates only once the strip is at its minimum.
                .background {
                    GeometryReader { Color.clear.preference(key: TrailingWidthKey.self, value: $0.size.width) }
                }
                .frame(minWidth: trailingWidth, alignment: .trailing)
            }
            .modifier(VoicesTableRowShape())
            .contextMenu {
                Button("Rename…") { actions.rename(speaker) }
                    .accessibilityIdentifier("cast-speaker-rename-\(speaker.label)")
            }
        }
    }

    private func nameButton(_ row: MeetingVoiceTable.Row, speaker: Speaker) -> some View {
        let name = VoiceName.of(speaker)
        let isNamed = row.voice.isMe || row.voice.name != nil
        return Button {
            actions.stepThroughTurns(row)
        } label: {
            nameColumn(
                VoiceDot(tint: row.voice.tint, size: 10, isOpen: !isNamed), name: name,
                ink: isNamed ? PVDesign.ink : PVDesign.ink2)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Step through their turns · right-click to rename")
        .accessibilityLabel(name)
        .accessibilityValue(VoiceName.linkState(speaker))
        .accessibilityAction(named: L10n.text("Rename…")) { actions.rename(speaker) }
        .accessibilityIdentifier("cast-speaker-\(speaker.label)")
    }

    /// Dot and name at the table's name width; an unnamed voice reads in ink 2.
    private func nameColumn(_ dot: VoiceDot, name: String, ink: Color) -> some View {
        HStack(spacing: 7) {
            dot
            Text(name)
                .font(.system(size: 13.5, weight: .bold))
                .foregroundStyle(ink)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(width: nameWidth, alignment: .leading)
    }

    private func shareText(_ share: Double) -> some View {
        Text(share.formatted(VoiceStrip.percent))
            .font(.system(size: 13, weight: .semibold).monospacedDigit())
            .foregroundStyle(PVDesign.ink)
            .frame(width: isNarrow ? 34 : 38, alignment: .trailing)
    }

    private func timeText(_ seconds: TimeInterval) -> some View {
        Text(ClockFormat.mmss(seconds, paddedMinutes: false))
            .font(.caption.monospacedDigit())
            .foregroundStyle(PVDesign.ink3)
            .frame(width: 54, alignment: .leading)
    }

    private func suggestionChip(_ suggestion: MeetingVoiceSuggestion) -> some View {
        DismissibleSuggestionChip(
            kind: .voice,
            text: L10n.format("Sounds like %@ — name", suggestion.name),
            acceptAccessibilityIdentifier: "detail-voice-suggestion-\(suggestion.speakerLabel)",
            dismissAccessibilityIdentifier: "detail-voice-suggestion-dismiss-\(suggestion.speakerLabel)",
            accept: { actions.acceptVoiceSuggestion(suggestion) },
            dismiss: { actions.dismissVoiceSuggestion(suggestion.speakerLabel) })
            .help(L10n.format("Matches “%@” from your remembered voices", suggestion.name))
    }

    private func onlyButton(_ row: MeetingVoiceTable.Row, speaker: Speaker) -> some View {
        let selected = playback?.focus == row.speakerID
        return Button {
            actions.toggleOnly(row)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "play.fill").font(.system(size: 8, weight: .bold))
                if !isNarrow { Text("Only") }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(selected ? PVDesign.onInk : PVDesign.ink2)
            .padding(.horizontal, isNarrow ? 0 : 8)
            .frame(minWidth: 20, minHeight: 20)
            .background(selected ? PVDesign.ink : .clear, in: Capsule())
            .overlay { if !selected { Capsule().strokeBorder(PVDesign.line2, lineWidth: 1) } }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(selected ? "Play everyone again" : "Play only this voice")
        .accessibilityLabel(L10n.format("Play only %@", VoiceName.of(speaker)))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("voice-only-\(speaker.label)")
    }

    private func othersRow(names: [String]) -> some View {
        Button {
            showsOthers.toggle()
        } label: {
            HStack(spacing: columnSpacing) {
                nameColumn(
                    VoiceDot(tint: .grey, size: 10), name: L10n.format("Others · %d", table.others.count),
                    ink: PVDesign.ink2)
                shareText(table.othersShare)
                if !isNarrow { timeText(table.othersTalkSeconds) }
                HStack(spacing: 4) {
                    Text(VoicesTableFormat.summary(names))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: showsOthers ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .accessibilityHidden(true)
                }
                .font(.caption)
                .foregroundStyle(PVDesign.ink3)
                Spacer(minLength: 0)
            }
            .modifier(VoicesTableRowShape())
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.format("Others · %d", table.others.count))
        .accessibilityValue(showsOthers ? L10n.text("Expanded") : L10n.text("Collapsed"))
        .accessibilityIdentifier("cast-others")
    }
}

enum VoicesTableFormat {
    static let narrowWidth: CGFloat = 620

    /// "Elena, Bruno, S9 +3": the first three folded voices by talk share.
    static func summary(_ names: [String]) -> String {
        let shown = names.prefix(3).joined(separator: ", ")
        return names.count > 3 ? "\(shown) +\(names.count - 3)" : shown
    }
}

/// One voice's turns on the meeting's time axis, each at least a point wide
/// so a short turn still shows.
struct VoiceTurnsStrip: View {
    let turns: [ClosedRange<TimeInterval>]
    let duration: TimeInterval
    let tint: VoiceCast.Tint
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(PVDesign.line))
            guard duration > 0 else { return }
            let shading = context.resolve(
                GraphicsContext.Shading.color(VoicePalette.color(tint, colorScheme: colorScheme)))
            let scale = size.width / duration
            var path = Path()
            for turn in turns {
                let left = (turn.lowerBound * scale).rounded(.down)
                let right = max(left + 1, (turn.upperBound * scale).rounded(.up))
                path.addRect(CGRect(x: left, y: 0, width: right - left, height: size.height))
            }
            context.fill(path, with: shading)
        }
        .frame(height: 6)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .accessibilityElement()
        .accessibilityLabel(L10n.text("Turns"))
        .accessibilityValue(turns.count.formatted())
    }
}

private struct TrailingWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// A 28 pt table row under a hairline.
private struct VoicesTableRowShape: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(height: 28)
            .overlay(alignment: .top) {
                Rectangle().fill(PVDesign.line).frame(height: 1)
            }
    }
}
