import AppKit
import DictationOwnership
import SwiftUI

/// What to say when dictation is on here but this app may not capture. Nothing turns
/// on the microphone by itself, and only the user's action moves ownership.
enum DictationOwnerStatus: Equatable {
    case ownedHere
    case otherApp(identifier: String?)
    case nobody
    case switching
    case olderBuildActive
    case damaged
    case needsUpdate
    case unavailable

    init(state: ParticipantState, owner: String?) {
        switch state {
        case .owned, .off: self = .ownedHere
        case .transferring: self = .switching
        case .available, .preparing: self = owner.map { .otherApp(identifier: $0) } ?? .nobody
        case .unavailable(.legacyPeerActive): self = .olderBuildActive
        case .unavailable(.corruptState): self = .damaged
        case .unavailable(.newerProtocol): self = .needsUpdate
        case .unavailable: self = .unavailable
        }
    }

    /// Names only the apps this protocol knows; an unknown owner stays "another app".
    static func appName(for identifier: String?) -> String? {
        switch identifier {
        case "com.johnny4young.secreteo": "Secreteo"
        case "com.johnny4young.secreteo.dev": "Secreteo Dev"
        case "app.portavoz.mac": "Portavoz"
        case "app.portavoz.mac.dev": "Portavoz Dev"
        default: nil
        }
    }

    var message: String? {
        switch self {
        case .ownedHere:
            nil
        case .otherApp(let identifier):
            Self.appName(for: identifier).map { L10n.format("%@ is handling dictation.", $0) }
                ?? L10n.text("Another app is handling dictation.")
        case .nobody:
            L10n.text("No app is handling dictation.")
        case .switching:
            L10n.text("Switching dictation…")
        case .olderBuildActive:
            L10n.text("An older Portavoz is dictating. Update it, or turn off dictation in it.")
        case .damaged:
            L10n.text("The state dictation shares between apps is damaged.")
        case .needsUpdate:
            L10n.text("Update Portavoz to dictate here.")
        case .unavailable:
            L10n.text("Dictation is unavailable on this Mac right now.")
        }
    }

    var offersToComeBack: Bool {
        switch self {
        case .otherApp, .nobody: true
        default: false
        }
    }
}

/// Where the user decides who dictates. Shown only while dictation is on here.
struct DictationOwnerRow: View {
    @Environment(AppServices.self) private var services
    let identifierPrefix: String

    private var status: DictationOwnerStatus { services.dictationOwnership.ownerStatus }

    var body: some View {
        if let message = status.message {
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .accessibilityIdentifier("\(identifierPrefix)-owner-status")
                HStack {
                    if status.offersToComeBack {
                        Button("Use Portavoz") { services.takeDictationOwnership() }
                            .accessibilityIdentifier("\(identifierPrefix)-owner-use-portavoz")
                    }
                    if case .otherApp(let identifier) = status, let url = Self.applicationURL(identifier),
                       let name = DictationOwnerStatus.appName(for: identifier) {
                        Button(L10n.format("Open %@", name)) { NSWorkspace.shared.open(url) }
                            .accessibilityIdentifier("\(identifierPrefix)-owner-open")
                    }
                    if status == .damaged {
                        Button("Reset") { services.resetDictationOwnership() }
                            .accessibilityIdentifier("\(identifierPrefix)-owner-reset")
                    }
                }
                if let problem = services.dictationOwnership.handoffProblem {
                    Text(problem.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("\(identifierPrefix)-owner-problem")
                }
            }
        }
    }

    private static func applicationURL(_ identifier: String?) -> URL? {
        identifier.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    }
}

/// Why the user's own request to come back did not go through.
enum DictationHandoffProblem: Equatable {
    case busy
    case shortcutConflict
    case failed

    init?(_ outcome: HandoffOutcome) {
        switch outcome {
        case .completed, .alreadyOwner: return nil
        case .timedOut, .busy: self = .busy
        case .triggerConflict: self = .shortcutConflict
        default: self = .failed
        }
    }

    var message: String {
        switch self {
        case .busy: L10n.text("Another dictation is still running. Try again when it ends.")
        case .shortcutConflict: L10n.text("Another app is using a dictation shortcut, so nothing changed.")
        case .failed: L10n.text("Dictation could not switch. Try again.")
        }
    }
}

extension DictationAdmissionRefusal {
    /// For a visible control; a global trigger that is refused stays silent.
    var message: String {
        switch self {
        case .busy, .transferring: L10n.text("Dictation is busy. Try again in a moment.")
        case .dictationOff: L10n.text("Dictation is off. Turn it on in Settings.")
        case .notOwner: L10n.text("Another app is handling dictation.")
        case .unavailable: L10n.text("Dictation is unavailable on this Mac right now.")
        }
    }
}
