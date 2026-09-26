import SwiftUI

/// Shared Settings surface for the two independent live speech routes.
/// The durable post-capture transcription engine does not change here.
struct AppleSpeechChoiceControls: View {
    @Environment(AppServices.self) private var services
    @Binding var selection: String
    let language: String
    let identifierPrefix: String

    private var model: AppleSpeechPreparationModel { services.appleSpeechPreparation }
    private var selectedApple: Bool { selection == LiveSpeechSelection.appleSpeech.rawValue }
    private var languageHint: String? { ["en", "es"].contains(language) ? language : nil }

    var body: some View {
        Picker("Live transcription engine", selection: $selection) {
            Text("Parakeet (multilingual)").tag(LiveSpeechSelection.parakeet.rawValue)
            Text("Apple Speech (fixed language)")
                .tag(LiveSpeechSelection.appleSpeech.rawValue)
                .disabled(!ProcessInfo.processInfo.isOperatingSystemAtLeast(
                    OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)))
        }
        .accessibilityIdentifier("\(identifierPrefix)-engine")
        .task(id: "\(selection)-\(language)") {
            if selectedApple { await model.refresh(language: languageHint) }
        }

        if selectedApple {
            let phase = model.phase(for: languageHint)
            Text(statusText(for: phase))
                .font(.caption)
                .foregroundStyle(phase == .ready ? Color.secondary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(statusText(for: phase))
                .accessibilityIdentifier("\(identifierPrefix)-apple-status")
            if phase == .needsDownload || phase == .blockedByCapture {
                if model.isPreparingAnotherLanguage(languageHint) {
                    ProgressView("Preparing the Apple Speech language asset…")
                        .controlSize(.small)
                        .accessibilityIdentifier("\(identifierPrefix)-apple-progress")
                } else {
                    Button(phase == .blockedByCapture
                        ? L10n.text("Try preparing Apple Speech again")
                        : L10n.text("Prepare Apple Speech")) {
                        Task { await model.prepare(language: languageHint) }
                    }
                    .accessibilityIdentifier("\(identifierPrefix)-apple-prepare")
                }
            } else if phase == .failed {
                Button("Check Apple Speech again") {
                    Task { await model.refresh(language: languageHint) }
                }
                .accessibilityIdentifier("\(identifierPrefix)-apple-retry")
            } else if phase == .checking || phase == .preparing {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityIdentifier("\(identifierPrefix)-apple-progress")
            }
        } else if #unavailable(macOS 26.0) {
            Text("Apple Speech requires macOS Tahoe or later. Parakeet remains available here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("\(identifierPrefix)-apple-requirement")
        }
    }

    private func statusText(for phase: AppleSpeechPreparationModel.Phase) -> String {
        switch phase {
        case .checking: L10n.text("Checking Apple Speech availability…")
        case .languageRequired:
            L10n.text("Choose English or Spanish above. Apple Speech cannot auto-detect a mixed-language session.")
        case .unavailable:
            L10n.text("Apple Speech is unavailable on this Mac. Choose Parakeet to continue.")
        case .unsupported:
            L10n.text("Apple Speech does not support this language on this Mac. Choose Parakeet to continue.")
        case .needsDownload:
            L10n.text("This language needs an Apple-hosted download. Prepare it explicitly before recording.")
        case .blockedByCapture:
            L10n.text("Finish the current recording before preparing Apple Speech.")
        case .preparing: L10n.text("Preparing the Apple Speech language asset…")
        case .ready: L10n.text("Apple Speech is ready for this language on this Mac.")
        case .failed:
            L10n.text("Apple Speech could not be checked or prepared. Choose Parakeet or try again.")
        }
    }
}
