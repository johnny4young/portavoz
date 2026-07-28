import SwiftUI

/// One selectable Whisper variant with app-scoped download status. Download
/// ownership lives in AppServices, so this row can disappear without stopping
/// verified preparation.
struct WhisperModelRow: View {
    let variant: AppServices.WhisperVariant
    let active: Bool
    let preparationState: AppServices.WhisperPreparationState
    let select: () -> Void
    let download: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Button(action: select) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: active ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(
                            active ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.text(
                            variant.compact
                                ? "Compact — less disk" : "Turbo — best quality"))
                            .font(.callout)
                        status
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(
                "settings-whisper-\(variant.accessibilitySuffix)")

            trailingAction
        }
    }

    @ViewBuilder
    private var status: some View {
        if case .preparing(let id, _, let percent, let isDownloading) = preparationState,
            id == variant.id {
            VStack(alignment: .leading, spacing: 3) {
                if isDownloading {
                    ProgressView(value: Double(percent), total: 100)
                } else {
                    ProgressView()
                }
                Text(isDownloading
                    ? L10n.format("Downloading in background… %d%%", percent)
                    : L10n.text("Checking files already on this Mac…"))
                    .frame(width: 150)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier(
                "settings-whisper-progress-\(variant.accessibilitySuffix)")
        } else if case .failed(let id, let message) = preparationState,
            id == variant.id {
            Text(L10n.format("Preparation failed: %@", message))
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
        } else {
            HStack(spacing: 0) {
                Text(L10n.text(
                    variant.downloaded ? "Downloaded · " : "Not downloaded · "))
                Text(ByteCountFormatter.string(
                    fromByteCount: variant.bytes,
                    countStyle: .file))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var trailingAction: some View {
        if variant.downloaded && !active {
            Button("Delete", role: .destructive, action: delete)
                .controlSize(.small)
                .help("Free disk used by the variant you do not use")
                .accessibilityIdentifier(
                    "settings-whisper-delete-\(variant.accessibilitySuffix)")
        } else if !variant.downloaded && !isThisVariantPreparing {
            Button(action: download) {
                Text(L10n.text(isThisVariantFailed ? "Try again" : "Download now"))
            }
                .controlSize(.small)
                .disabled(preparationState.isPreparing)
                .accessibilityIdentifier(
                    "settings-whisper-download-\(variant.accessibilitySuffix)")
        }
    }

    private var isThisVariantPreparing: Bool {
        guard case .preparing(let id, _, _, _) = preparationState else { return false }
        return id == variant.id
    }

    private var isThisVariantFailed: Bool {
        guard case .failed(let id, _) = preparationState else { return false }
        return id == variant.id
    }
}
