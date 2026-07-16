import ApplicationKit
import SwiftUI

struct SummaryEngineCapabilityNotice: View {
    let engine: String
    let capability: FoundationModelsCapability

    @ViewBuilder
    var body: some View {
        if engine == SummaryEngine.appleOnDevice.rawValue {
            switch capability {
            case .available:
                EmptyView()
            case .requiresMacOS26:
                Label(
                    "Apple summaries are unavailable on this Mac. Choose Ollama or Built-in (MLX).",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .accessibilityIdentifier("settings-summary-apple-unavailable")
            case .unavailable(let reason):
                Label(
                    L10n.format(
                        "Apple summaries are unavailable: %@. Choose Ollama or Built-in (MLX).",
                        reason),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .accessibilityIdentifier("settings-summary-apple-unavailable")
            }
        }
    }
}
