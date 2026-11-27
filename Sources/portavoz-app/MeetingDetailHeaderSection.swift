import ApplicationKit
import IntelligenceKit
import PortavozCore
import SwiftUI

struct MeetingDetailHeaderValues {
    let title: String
    /// Day · time · duration · spoken language.
    let kicker: String
    let titleSuggestion: String?
    let speakers: [Speaker]
    let voiceTable: MeetingVoiceTable
    let health: MeetingHealth
    /// Nil without audio.
    let playback: MeetingVoicesPlayback?
    let isSuggestingNames: Bool
    /// Suggested names wait in the margin's People tab.
    let hasNameSuggestions: Bool
    let voiceSuggestions: [MeetingVoiceSuggestion]
}

struct MeetingDetailHeaderActions {
    let renameMeeting: @MainActor () -> Void
    let acceptTitleSuggestion: @MainActor (String) -> Void
    let dismissTitleSuggestion: @MainActor () -> Void
    let renameSpeaker: @MainActor (Speaker) -> Void
    let stepThroughTurns: @MainActor (MeetingVoiceTable.Row) -> Void
    let toggleOnly: @MainActor (MeetingVoiceTable.Row) -> Void
    let suggestNames: @MainActor () -> Void
    let acceptVoiceSuggestion: @MainActor (MeetingVoiceSuggestion) -> Void
    let dismissVoiceSuggestion: @MainActor (String) -> Void
}

/// Meeting identity, facts, and participants.
///
/// The section renders immutable values and emits explicit gestures. It has no
/// meeting model, application service, persistence, or provider dependency.
struct MeetingDetailHeaderSection<Receipt: View>: View {
    let values: MeetingDetailHeaderValues
    let actions: MeetingDetailHeaderActions
    private let receipt: Receipt

    init(
        values: MeetingDetailHeaderValues,
        actions: MeetingDetailHeaderActions,
        @ViewBuilder receipt: () -> Receipt
    ) {
        self.values = values
        self.actions = actions
        self.receipt = receipt()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            kickerRow
            titleRow
            voicesTable
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail-header-section")
    }

    private var kickerRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            PVCardCaption(text: values.kicker, tint: PVDesign.ink3)
                .lineLimit(1)
                .accessibilityIdentifier("detail-kicker")
            Spacer(minLength: 8)
            receipt
        }
    }

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(values.title)
                .pvDisplay(.title)
                .contextMenu {
                    Button("Rename…", action: actions.renameMeeting)
                }
                .accessibilityAction(named: L10n.text("Rename…")) { actions.renameMeeting() }
                .accessibilityIdentifier("detail-title")
            if let suggestion = values.titleSuggestion {
                DismissibleSuggestionChip(
                    kind: .ai,
                    text: "“\(suggestion)”?",
                    acceptAccessibilityIdentifier: "detail-title-suggestion",
                    dismissAccessibilityIdentifier: "detail-title-suggestion-dismiss",
                    accept: { actions.acceptTitleSuggestion(suggestion) },
                    dismiss: actions.dismissTitleSuggestion)
            .help(
                "Suggested title from the summary — one click renames, nothing changes on its own")
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var voicesTable: some View {
        if !values.voiceTable.isEmpty {
            MeetingVoicesTable(
                table: values.voiceTable,
                speakers: values.speakers,
                voiceSuggestions: values.voiceSuggestions,
                playback: values.playback,
                health: values.health,
                actions: MeetingVoicesTableActions(
                    stepThroughTurns: actions.stepThroughTurns,
                    toggleOnly: actions.toggleOnly,
                    rename: actions.renameSpeaker,
                    acceptVoiceSuggestion: actions.acceptVoiceSuggestion,
                    dismissVoiceSuggestion: actions.dismissVoiceSuggestion)
            ) {
                if values.speakers.contains(where: { !$0.isMe && $0.displayName == nil }) {
                    suggestNamesControl
                }
            }
            .padding(.top, 6)
        }
    }

    @ViewBuilder
    private var suggestNamesControl: some View {
        if values.isSuggestingNames {
            ProgressView().controlSize(.small)
        } else if !values.hasNameSuggestions {
            Button(action: actions.suggestNames) {
                Label("Suggest names", systemImage: PVSymbol.generate)
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(PVDesign.accent)
            .accessibilityIdentifier("detail-suggest-names")
        }
    }
}
