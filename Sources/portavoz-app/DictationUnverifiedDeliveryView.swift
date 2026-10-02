import SwiftUI

/// Copy is an explicit clipboard operation, never a second paste attempt.
struct DictationUnverifiedDeliveryView: View {
    let controller: DictationController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Sent — insertion not verified", systemImage: "paperplane.circle")
                .font(.headline)
                .foregroundStyle(.orange)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("dictation-panel-delivery-status")
            Text("Check the destination before pasting again. Nothing was saved in Portavoz.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("dictation-panel-delivery-detail")
            Text(controller.recoveryText)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("dictation-unverified-text")
            DictationCopyStatusLabel(status: controller.copyStatus)
                .accessibilityIdentifier("dictation-unverified-copy-status")
            HStack(spacing: 8) {
                Button("Copy", action: controller.copyPendingText)
                    .accessibilityIdentifier("dictation-unverified-copy")
                Spacer()
                Button("Discard", role: .cancel, action: controller.cancel)
                    .accessibilityIdentifier("dictation-unverified-discard")
            }
            .controlSize(.large)
            .frame(minHeight: 44)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}
