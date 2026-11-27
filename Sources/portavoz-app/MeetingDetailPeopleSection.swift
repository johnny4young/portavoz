import ApplicationKit
import PortavozCore
import SwiftUI

struct MeetingDetailRememberOffer {
    let speakerID: SpeakerID
    let name: String
    let isBusy: Bool
}

struct MeetingDetailPeopleValues {
    let nameSuggestions: [MeetingNameSuggestion]
    /// Voice matches with no visible line to sit beside.
    let unplacedVoiceMatches: [MeetingVoiceSuggestion]
    let personOffer: MeetingDetailRememberOffer?
    let voiceOffer: MeetingDetailRememberOffer?

    /// What you asked for: suggested names and the offers a rename brings.
    /// Keyed by speaker so an offer replaced for another speaker reads as new.
    var followUps: Set<String> {
        var keys = Set(nameSuggestions.map { "name-\($0.label)" })
        if let personOffer { keys.insert("person-\(personOffer.speakerID.rawValue)") }
        if let voiceOffer { keys.insert("voice-\(voiceOffer.speakerID.rawValue)") }
        return keys
    }

    var count: Int {
        nameSuggestions.count + (personOffer == nil ? 0 : 1) + (voiceOffer == nil ? 0 : 1)
            + unplacedVoiceMatches.count
    }

    var isEmpty: Bool { count < 1 }
}

struct MeetingDetailPeopleActions {
    let acceptNameSuggestion: @MainActor (MeetingNameSuggestion) -> Void
    let dismissNameSuggestion: @MainActor (String) -> Void
    let undoVoiceAutoAssign: @MainActor (MeetingVoiceSuggestion) -> Void
    let keepVoiceAutoAssign: @MainActor (MeetingVoiceSuggestion) -> Void
    let acceptPersonOffer: @MainActor () -> Void
    let dismissPersonOffer: @MainActor () -> Void
    let acceptVoiceOffer: @MainActor () -> Void
    let dismissVoiceOffer: @MainActor () -> Void
}

private struct MeetingDetailRememberOfferPresentation {
    let label: String
    let systemImage: String
    let acceptIdentifier: String
    let dismissLabel: String
    let dismissIdentifier: String
    let help: String
}

/// Who spoke, still to confirm: suggested names, voice matches without a line,
/// and the offers to remember a person or a voice. Nothing changes on its own.
struct MeetingDetailPeopleSection: View {
    let values: MeetingDetailPeopleValues
    let actions: MeetingDetailPeopleActions

    var body: some View {
        FlowLayout(spacing: 8, rowSpacing: 8) {
            autoAssignedVoiceChips
            nameSuggestionChips
            rememberPersonOffer
            rememberVoiceOffer
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail-people")
    }

    @ViewBuilder
    private var nameSuggestionChips: some View {
        ForEach(values.nameSuggestions, id: \.label) { suggestion in
            DismissibleSuggestionChip(
                kind: .ai,
                text: "\(suggestion.label) → \(suggestion.name)?",
                acceptAccessibilityIdentifier: "detail-name-suggestion-\(suggestion.label)",
                dismissAccessibilityIdentifier: "detail-name-suggestion-dismiss-\(suggestion.label)",
                accept: { actions.acceptNameSuggestion(suggestion) },
                dismiss: { actions.dismissNameSuggestion(suggestion.label) })
            .help(nameSuggestionHelp(suggestion))
        }
    }

    @ViewBuilder
    private var autoAssignedVoiceChips: some View {
        ForEach(values.unplacedVoiceMatches, id: \.speakerLabel) { voice in
            UndoableAppliedChip(
                kind: .voice,
                text: L10n.format("%@ · by voice", voice.name),
                undoAccessibilityIdentifier: "detail-voice-auto-undo-\(voice.speakerLabel)",
                keepAccessibilityLabel: L10n.text("Keep name"),
                keepAccessibilityIdentifier: "detail-voice-auto-keep-\(voice.speakerLabel)",
                undo: { actions.undoVoiceAutoAssign(voice) },
                keep: { actions.keepVoiceAutoAssign(voice) })
            .help(L10n.format("Matches “%@” from your remembered voices", voice.name))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("detail-voice-auto-\(voice.speakerLabel)")
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
                    label: L10n.format("Recognize %@ in future meetings?", offer.name),
                    systemImage: "person.wave.2",
                    acceptIdentifier: "voice-remember-offer",
                    dismissLabel: L10n.text("Dismiss voice offer"),
                    dismissIdentifier: "voice-dismiss-offer",
                    help: L10n.text(
                        // One-line UI help text.
                        // swiftlint:disable:next line_length
                        "Suggests this name when the voice is heard again. The voiceprint stays encrypted on this Mac; remove it in Settings.")),
                accept: actions.acceptVoiceOffer,
                dismiss: actions.dismissVoiceOffer)
        }
    }

    /// An offer wraps inside the margin instead of truncating its question.
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
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Label(presentation.label, systemImage: presentation.systemImage)
                        .font(.caption)
                        .foregroundStyle(PVDesign.chipOfferInk)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(L10n.text("Remember"), action: accept)
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(PVDesign.accent)
                        .fixedSize()
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
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(PVDesign.chipOfferBg, in: RoundedRectangle(cornerRadius: PVDesign.radiusSmall))
                .help(presentation.help)
            }
        }
    }
}
