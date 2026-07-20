import SwiftUI

/// One selectable Whisper variant with app-scoped download status. Download
/// ownership lives in AppServices, so this row can disappear without stopping
/// verified preparation.
struct WhisperModelRow: View {
    let variant: AppServices.WhisperVariant
    let active: Bool
    let downloadState: AppServices.WhisperDownloadState
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
        if case .downloading(let id, _, let percent) = downloadState,
            id == variant.id {
            VStack(alignment: .leading, spacing: 3) {
                ProgressView(value: Double(percent), total: 100)
                    .frame(width: 150)
                Text(L10n.format(
                    "Downloading in background… %d%%",
                    percent))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier(
                "settings-whisper-progress-\(variant.accessibilitySuffix)")
        } else if case .failed(let id, let message) = downloadState,
            id == variant.id {
            Text(L10n.format("Download failed: %@", message))
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
        } else if !variant.downloaded && !isThisVariantDownloading {
            Button(action: download) {
                Text(L10n.text(isThisVariantFailed ? "Try again" : "Download now"))
            }
                .controlSize(.small)
                .disabled(downloadState.isDownloading)
                .accessibilityIdentifier(
                    "settings-whisper-download-\(variant.accessibilitySuffix)")
        }
    }

    private var isThisVariantDownloading: Bool {
        guard case .downloading(let id, _, _) = downloadState else { return false }
        return id == variant.id
    }

    private var isThisVariantFailed: Bool {
        guard case .failed(let id, _) = downloadState else { return false }
        return id == variant.id
    }
}
