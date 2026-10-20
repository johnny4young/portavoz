import SwiftUI

/// Whether a practice dictation may open the microphone.
enum DictationPracticeReadiness: Equatable {
    case ready
    /// The speech model is prepared first; `failure` explains a failed attempt.
    case needsModel(failure: String?)
    case preparingModel
}

/// Dictation with the real microphone and model, delivered to an in-app field
/// instead of another app, so a user can try it before granting Accessibility.
struct DictationPracticeView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.controlActiveState) private var activeState
    @State private var holder = UUID()
    let identifierPrefix: String
    var readiness: DictationPracticeReadiness = .ready
    var prepareModel: () -> Void = {}

    private var practice: DictationPracticeField { services.dictationPractice }
    private var controller: DictationController { services.dictation }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Try it here").font(.callout.weight(.medium))
            field
            controls
            Text("Uses your microphone and the on-device model. The words stay in this field and are not saved.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(identifier("practice-hint"))
            if controller.shortcut.availability == .registered {
                Text(L10n.format(
                    "You can also press %@ while this window is in front.", controller.shortcut.setting.label))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(identifier("practice-shortcut-hint"))
            }
        }
        .onAppear { practice.show(holder, isKey: activeState == .key) }
        .onChange(of: activeState) { practice.show(holder, isKey: activeState == .key) }
        .onDisappear { practice.hide(holder) }
    }

    private var field: some View {
        Text(practice.text.isEmpty ? L10n.text("Your words appear here.") : practice.text)
            .foregroundStyle(practice.text.isEmpty ? .secondary : .primary)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
            .padding(8)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            .textSelection(.enabled)
            .accessibilityIdentifier(identifier("practice-field"))
    }

    @ViewBuilder private var controls: some View {
        switch readiness {
        case .ready:
            HStack {
                Button {
                    controller.toggle(services: services)
                } label: {
                    Label(
                        controller.isActive ? L10n.text("Finish") : L10n.text("Dictate here"),
                        systemImage: controller.isActive ? PVSymbol.stop : "mic.fill")
                }
                .disabled(controller.phase == .delivering)
                .accessibilityIdentifier(identifier("practice-start"))
                if !practice.text.isEmpty {
                    Button("Clear") { practice.clear() }
                        .accessibilityIdentifier(identifier("practice-clear"))
                }
            }
        case .needsModel(let failure):
            Button("Prepare the speech model", action: prepareModel)
                .accessibilityIdentifier(identifier("practice-prepare"))
            Text(failure ?? L10n.text("The microphone stays off until the model is ready."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(identifier("practice-model-status"))
        case .preparingModel:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Preparing the speech model…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(identifier("practice-preparing"))
            }
        }
    }

    private func identifier(_ suffix: String) -> String {
        "\(identifierPrefix)-\(suffix)"
    }
}
