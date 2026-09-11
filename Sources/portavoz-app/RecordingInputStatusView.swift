import SwiftUI

struct RecordingInputStatusView: View {
    let controller: RecordingController

    var body: some View {
        if controller.inputPersistence.hasFailure {
            VStack(alignment: .leading, spacing: 8) {
                Label(L10n.text("Couldn’t save this change. Your input has been kept."),
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                if !controller.inputPersistence.retainedText.isEmpty {
                    Text(controller.inputPersistence.retainedText)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("recording-input-retained-text")
                }
                HStack {
                    Button(L10n.text("Retry saving")) {
                        Task { await controller.retryRecordingInput() }
                    }
                    .accessibilityIdentifier("recording-input-retry")
                    Button(L10n.text(controller.hasPendingInputStop
                        ? "Continue without this change" : "Discard unsaved change"), role: .destructive) {
                        Task { await controller.discardRecordingInput() }
                    }
                    .accessibilityIdentifier("recording-input-discard")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("recording-input-save-failure")
        } else if controller.inputPersistence.isSaving {
            ProgressView(L10n.text("Saving your change…"))
                .controlSize(.small)
                .accessibilityIdentifier("recording-input-saving")
        }
    }

}
