import SwiftUI

/// What Apuntador is doing in this recording, always visible in the assist
/// panel so the feature never disappears: it says why it is quiet and offers
/// the one action that changes that.
enum RecordingApuntadorState: Equatable {
    case listening
    case questionsOnly
    case off
    case unavailable

    static func resolve(
        enabled: Bool,
        detectorAvailable: Bool,
        answersAvailable: Bool
    ) -> RecordingApuntadorState {
        guard detectorAvailable else { return .unavailable }
        guard enabled else { return .off }
        return answersAvailable ? .listening : .questionsOnly
    }

    var title: String {
        switch self {
        case .listening: L10n.text("Listening for questions")
        case .questionsOnly: L10n.text("Questions only")
        case .off: L10n.text("Apuntador is off")
        case .unavailable: L10n.text("Apuntador is unavailable")
        }
    }

    var explanation: String {
        switch self {
        case .listening: L10n.text("Questions the meeting asks you show up here.")
        case .questionsOnly: L10n.text("Questions show up here. Answers need an engine you enable in Settings.")
        case .off: L10n.text("Turn Apuntador on to see the questions the meeting asks you.")
        case .unavailable: L10n.text("Reinstall Portavoz to restore its bundled offline question detector.")
        }
    }

    /// The chip's word; `title` stays the full name for VoiceOver.
    var shortTitle: String {
        switch self {
        case .listening: L10n.text("Listening")
        case .questionsOnly: L10n.text("Questions only")
        case .off: L10n.text("Off")
        case .unavailable: L10n.text("Unavailable")
        }
    }

    var tint: Color {
        switch self {
        case .listening: PVDesign.green
        case .questionsOnly, .unavailable: PVDesign.caution
        case .off: PVDesign.ink3
        }
    }

    var fill: Color {
        switch self {
        case .listening: PVDesign.greenBg
        case .questionsOnly, .unavailable: PVDesign.caution.opacity(0.12)
        case .off: PVDesign.line
        }
    }
}

/// The chip beside the assist tabs: a short state that opens the one action
/// that changes it. It is the only Apuntador toggle while recording.
struct RecordingApuntadorStateChip: View {
    let state: RecordingApuntadorState
    let turnOn: @MainActor () -> Void
    let turnOff: @MainActor () -> Void
    let openSettings: @MainActor () -> Void

    var body: some View {
        Menu {
            switch state {
            case .off:
                Button(L10n.text("Turn on"), action: turnOn)
                    .accessibilityIdentifier("recording-apuntador-turn-on")
            case .questionsOnly:
                Button(L10n.text("Settings"), action: openSettings)
                    .accessibilityIdentifier("recording-apuntador-settings")
                Button(L10n.text("Turn off"), action: turnOff)
                    .accessibilityIdentifier("recording-apuntador-turn-off")
            case .unavailable:
                Button(L10n.text("Settings"), action: openSettings)
                    .accessibilityIdentifier("recording-apuntador-settings")
            case .listening:
                Button(L10n.text("Turn off"), action: turnOff)
                    .accessibilityIdentifier("recording-apuntador-turn-off")
            }
        } label: {
            Text(state.shortTitle)
                .foregroundStyle(state.tint)
                .lineLimit(1)
                .pvPill(state.fill)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(state.explanation)
        .accessibilityLabel(state.title)
        .accessibilityValue(state.explanation)
        .accessibilityIdentifier("recording-apuntador-state")
    }
}
