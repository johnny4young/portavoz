import SwiftUI

/// Copy is an explicit clipboard operation, never a second paste attempt.
struct DictationUnverifiedDeliveryView: View {
    let controller: DictationController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label("Sent — insertion not verified", systemImage: "paperplane.circle")
                    .font(.headline)
                    .foregroundStyle(.orange)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("dictation-panel-delivery-status")
                Spacer()
                Button(action: controller.dismissFeedback) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.text("Close"))
                .accessibilityIdentifier("dictation-unverified-close")
            }
            Text(L10n.text("Check the destination before pasting again.") + " " + controller.deliveryPrivacyLine)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("dictation-panel-delivery-detail")
            if let notice = controller.polishNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("dictation-panel-polish-notice")
            }
            // Like recovery, the complete output stays reachable when Copy
            // fails: it scrolls inside the bounded panel and can be selected.
            ScrollView {
                Text(controller.recoveryText)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("dictation-unverified-text")
            }
            .frame(maxHeight: .infinity)
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
