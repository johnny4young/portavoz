import SwiftUI

/// Embedded-model state row for Settings (same pattern as the Whisper
/// variants): downloaded + size + delete, or a one-click verified download
/// (D32). Owns its download state so SettingsView only decides when to
/// show it.
struct MLXModelRow: View {
    let services: AppServices
    @State private var downloaded = false
    @State private var downloading = false
    @State private var status: String?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: downloaded ? "checkmark.circle.fill" : "arrow.down.circle")
                .foregroundStyle(downloaded ? Color.green : Color.secondary)
            if downloaded {
                Text("Qwen3.5 4B · downloaded · 3 GB").font(.caption)
                Spacer()
                Button("Delete", role: .destructive) {
                    services.deleteMLXModel()
                    downloaded = false
                }
                .controlSize(.small)
                .accessibilityIdentifier("settings-mlx-delete")
            } else if downloading {
                ProgressView().controlSize(.small)
                Text(status ?? "").font(.caption).foregroundStyle(.secondary)
            } else {
                Button("Download model (3 GB)") { download() }
                    .controlSize(.small)
                    .accessibilityIdentifier("settings-mlx-download")
            }
        }
        .onAppear { downloaded = services.mlxDownloaded }
    }

    private func download() {
        downloading = true
        Task { @MainActor in
            defer { downloading = false }
            do {
                try await services.downloadMLX { status in self.status = status }
                downloaded = true
                status = nil
            } catch {
                status = error.localizedDescription
            }
        }
    }
}
