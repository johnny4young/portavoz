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

    var symbol: String {
        switch self {
        case .listening: PVSymbol.apuntador
        case .questionsOnly: PVSymbol.warning
        case .off: PVSymbol.apuntadorOff
        case .unavailable: PVSymbol.error
        }
    }

    var tint: Color {
        switch self {
        case .listening: PVDesign.accent
        case .questionsOnly: .orange
        case .off: .secondary
        case .unavailable: .red
        }
    }
}

/// The chip beside the assist tabs: state, and the one action that changes it.
struct RecordingApuntadorStateChip: View {
    let state: RecordingApuntadorState
    let turnOn: @MainActor () -> Void
    let openSettings: @MainActor () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Label(state.title, systemImage: state.symbol)
                .font(.caption.weight(.medium))
                .foregroundStyle(state.tint)
                .lineLimit(1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(state.title)
                .accessibilityValue(state.explanation)
                .accessibilityIdentifier("recording-apuntador-state")
                .help(state.explanation)
            switch state {
            case .off:
                Button(L10n.text("Turn on"), action: turnOn)
                    .buttonStyle(.plain)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PVDesign.accent)
                    .accessibilityIdentifier("recording-apuntador-turn-on")
            case .questionsOnly, .unavailable:
                Button(L10n.text("Settings"), action: openSettings)
                    .buttonStyle(.plain)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PVDesign.accent)
                    .accessibilityIdentifier("recording-apuntador-settings")
            case .listening:
                EmptyView()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(state.tint.opacity(0.10), in: Capsule())
    }
}
