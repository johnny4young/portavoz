import SwiftUI

/// Onboarding step for system-wide dictation. The switch starts off, so
/// continuing past the step never registers a global shortcut.
struct OnboardingDictationStep: View {
    @Environment(AppServices.self) private var services
    @AppStorage(DictationController.defaultsKey) private var enabled = false
    let modelPhase: OnboardingModelPreparation.Phase
    let prepareModels: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Dictate anywhere")
                    .font(.largeTitle.bold())
                    .accessibilityIdentifier("onboarding-dictation")
                Text(L10n.format(
                    "Press %@ in any app, speak, and press it again. Your words appear where your cursor is.",
                    services.dictation.shortcut.setting.label))
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Turn on dictation", isOn: $enabled)
                    .toggleStyle(.switch)
                    .accessibilityIdentifier("onboarding-dictation-toggle")
                    .onChange(of: enabled) { services.applyDictationEnabled(enabled) }
                if enabled {
                    DictationShortcutSettings(shortcut: services.dictation.shortcut) {
                        services.dictation.syncHotkey(services: services)
                    }
                    DictationAccessibilityRow()
                }
                Divider()
                DictationPracticeView(
                    identifierPrefix: "onboarding-dictation",
                    readiness: readiness,
                    prepareModel: prepareModels)
            }
        }
    }

    private var readiness: DictationPracticeReadiness {
        switch modelPhase {
        case .ready: .ready
        case .preparing: .preparingModel
        case .idle: .needsModel(failure: nil)
        case .failed(let failure): .needsModel(failure: failure.message)
        }
    }
}

/// macOS posts no change notification for Accessibility, so the row checks
/// once a second while it is visible.
private struct DictationAccessibilityRow: View {
    @Environment(AppServices.self) private var services
    @State private var granted = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "accessibility").foregroundStyle(PVDesign.accent).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text("Accessibility").font(.callout.weight(.medium))
                Text(granted
                    ? L10n.text("Allowed. Dictation can type into other apps.")
                    : L10n.text("Lets dictation type into other apps. You can try it here without it."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("onboarding-dictation-accessibility-status")
            }
            Spacer()
            if granted {
                Image(systemName: PVSymbol.success)
                    .foregroundStyle(.green)
                    .accessibilityLabel(L10n.text("Allowed"))
            } else {
                Button("Allow") { services.requestDictationAccessibility() }
                    .controlSize(.small)
                    .accessibilityIdentifier("onboarding-dictation-accessibility-allow")
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .task {
            while !Task.isCancelled {
                granted = services.dictationAccessibilityGranted
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}
