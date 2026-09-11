import ApplicationKit
import PortavozCore
import SwiftUI

struct MeetingDetailHeaderValues {
    let title: String
    let date: String
    let duration: String?
    let segmentCount: String
    let titleSuggestion: String?
    let speakers: [Speaker]
    let isSuggestingNames: Bool
    let nameSuggestions: [MeetingNameSuggestion]
    let voiceSuggestions: [MeetingVoiceSuggestion]
    let personOffer: MeetingDetailRememberOffer?
    let voiceOffer: MeetingDetailRememberOffer?
}

struct MeetingDetailRememberOffer {
    let name: String
    let isBusy: Bool
}

private struct MeetingDetailRememberOfferPresentation {
    let label: String
    let systemImage: String
    let acceptIdentifier: String
    let dismissLabel: String
    let dismissIdentifier: String
    let help: String
}

struct MeetingDetailHeaderActions {
    let renameMeeting: @MainActor () -> Void
    let acceptTitleSuggestion: @MainActor (String) -> Void
    let dismissTitleSuggestion: @MainActor () -> Void
    let renameSpeaker: @MainActor (Speaker) -> Void
    let suggestNames: @MainActor () -> Void
    let acceptNameSuggestion: @MainActor (MeetingNameSuggestion) -> Void
    let dismissNameSuggestion: @MainActor (String) -> Void
    let acceptVoiceSuggestion: @MainActor (MeetingVoiceSuggestion) -> Void
    let dismissVoiceSuggestion: @MainActor (String) -> Void
    let acceptPersonOffer: @MainActor () -> Void
    let dismissPersonOffer: @MainActor () -> Void
    let acceptVoiceOffer: @MainActor () -> Void
    let dismissVoiceOffer: @MainActor () -> Void
}

/// Meeting identity, facts, participants, and optional inert suggestions.
///
/// The section renders immutable values and emits explicit gestures. It has no
/// meeting model, application service, persistence, or provider dependency.
struct MeetingDetailHeaderSection<ActionContent: View>: View {
    let values: MeetingDetailHeaderValues
    let actions: MeetingDetailHeaderActions
    private let actionContent: ActionContent

    init(
        values: MeetingDetailHeaderValues,
        actions: MeetingDetailHeaderActions,
        @ViewBuilder actionContent: () -> ActionContent
    ) {
        self.values = values
        self.actions = actions
        self.actionContent = actionContent()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            titleRow
            actionContent
            factsRow
            participantsRow
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail-header-section")
    }

    private var titleRow: some View {
        HStack(spacing: 8) {
            Text(values.title).font(.title2.bold())
            Button(action: actions.renameMeeting) {
                Image(systemName: "pencil").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Rename the meeting")
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

    private var factsRow: some View {
        HStack(spacing: 12) {
            Text(values.date)
            if let duration = values.duration {
                Text(duration)
            }
            Text(values.segmentCount)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private var participantsRow: some View {
        let unnamed = values.speakers.filter { !$0.isMe && $0.displayName == nil }
        return FlowLayout(spacing: 8, rowSpacing: 8) {
            ForEach(values.speakers) { speaker in
                SpeakerPill(
                    speaker: speaker,
                    cast: values.speakers,
                    accessibilityIdentifier: "cast-speaker-\(speaker.label)",
                    onRename: actions.renameSpeaker)
            }
            if !unnamed.isEmpty {
                suggestNamesControl
            }
            nameSuggestionChips
            voiceSuggestionChips
            rememberPersonOffer
            rememberVoiceOffer
        }
    }

    @ViewBuilder
    private var suggestNamesControl: some View {
        if values.isSuggestingNames {
            ProgressView().controlSize(.small)
        } else if values.nameSuggestions.isEmpty {
            Button(action: actions.suggestNames) {
                Label("Suggest names", systemImage: "sparkles")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(PVDesign.accent)
            .accessibilityIdentifier("detail-suggest-names")
        }
    }

    @ViewBuilder
    private var nameSuggestionChips: some View {
        ForEach(values.nameSuggestions, id: \.label) { suggestion in
            DismissibleSuggestionChip(
                kind: .ai,
                text: "\(suggestion.label) → \(suggestion.name)?",
                acceptAccessibilityIdentifier:
                    "detail-name-suggestion-\(suggestion.label)",
                dismissAccessibilityIdentifier:
                    "detail-name-suggestion-dismiss-\(suggestion.label)",
                accept: { actions.acceptNameSuggestion(suggestion) },
                dismiss: { actions.dismissNameSuggestion(suggestion.label) })
            .fixedSize()
            .help(nameSuggestionHelp(suggestion))
        }
    }

    @ViewBuilder
    private var voiceSuggestionChips: some View {
        ForEach(values.voiceSuggestions, id: \.speakerLabel) { suggestion in
            DismissibleSuggestionChip(
                kind: .voice,
                text: "\(suggestion.speakerLabel) → \(suggestion.name)?",
                acceptAccessibilityIdentifier:
                    "detail-voice-suggestion-\(suggestion.speakerLabel)",
                dismissAccessibilityIdentifier:
                    "detail-voice-suggestion-dismiss-\(suggestion.speakerLabel)",
                accept: { actions.acceptVoiceSuggestion(suggestion) },
                dismiss: {
                    actions.dismissVoiceSuggestion(suggestion.speakerLabel)
                })
            .fixedSize()
            .help(L10n.format(
                "Voice match: sounds like “%@” from your remembered voices.",
                suggestion.name))
        }
    }

    private func nameSuggestionHelp(_ suggestion: MeetingNameSuggestion) -> String {
        switch suggestion.evidence {
        case .transcript(let quote):
            L10n.format("Transcript: “%@”", quote)
        case .calendarCandidate(let candidate):
            L10n.format("Calendar candidate: %@", candidate)
        }
    }

    @ViewBuilder
    private var rememberPersonOffer: some View {
        if let offer = values.personOffer {
            rememberOffer(
                offer,
                presentation: MeetingDetailRememberOfferPresentation(
                    label: L10n.format("Remember %@ as a person?", offer.name),
                    systemImage: "person.crop.circle.badge.plus",
                    acceptIdentifier: "person-remember-offer",
                    dismissLabel: L10n.text("Dismiss person offer"),
                    dismissIdentifier: "person-dismiss-offer",
                    help: L10n.text(
                        "Links this meeting speaker to local, user-confirmed person memory.")),
                accept: actions.acceptPersonOffer,
                dismiss: actions.dismissPersonOffer)
        }
    }

    @ViewBuilder
    private var rememberVoiceOffer: some View {
        if let offer = values.voiceOffer {
            rememberOffer(
                offer,
                presentation: MeetingDetailRememberOfferPresentation(
                    label: L10n.format("Remember %@’s voice?", offer.name),
                    systemImage: "person.wave.2",
                    acceptIdentifier: "voice-remember-offer",
                    dismissLabel: L10n.text("Dismiss voice offer"),
                    dismissIdentifier: "voice-dismiss-offer",
                    help: L10n.text(
                        // One-line UI help text.
                        // swiftlint:disable:next line_length
                        "Stores only an encrypted numeric fingerprint of their voice on this Mac — never the audio, never synced — so future meetings can suggest their name. Removable in Settings.")),
                accept: actions.acceptVoiceOffer,
                dismiss: actions.dismissVoiceOffer)
        }
    }

    private func rememberOffer(
        _ offer: MeetingDetailRememberOffer,
        presentation: MeetingDetailRememberOfferPresentation,
        accept: @escaping @MainActor () -> Void,
        dismiss: @escaping @MainActor () -> Void
    ) -> some View {
        Group {
            if offer.isBusy {
                ProgressView().controlSize(.small)
            } else {
                HStack(spacing: 6) {
                    Label(presentation.label, systemImage: presentation.systemImage)
                        .font(.caption)
                        .foregroundStyle(PVDesign.chipOfferInk)
                    Button(L10n.text("Remember"), action: accept)
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(PVDesign.accent)
                        .accessibilityIdentifier(presentation.acceptIdentifier)
                    Button(action: dismiss) {
                        Image(systemName: "xmark")
                            .font(.caption2)
                            .foregroundStyle(PVDesign.chipOfferInk)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(presentation.dismissLabel)
                    .accessibilityIdentifier(presentation.dismissIdentifier)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(PVDesign.chipOfferBg, in: Capsule())
                .help(presentation.help)
            }
        }
    }
}
