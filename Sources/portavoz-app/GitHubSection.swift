import IntegrationsKit
import SwiftUI

/// Settings section: the GitHub personal token used to publish gists.
/// Self-contained (its Keychain state lives here, not in SettingsView);
/// the secret goes to the Keychain — never the database (D8).
struct GitHubSection: View {
    @Environment(AppServices.self) private var services
    @State private var token = ""
    @State private var hasStoredToken = false
    @State private var tokenMessage: String?

    var body: some View {
        Section("GitHub") {
            SecureField("Personal token (scope: gist)", text: $token)
            HStack {
                Button("Save in Keychain") {
                    let value = token
                    Task {
                        do {
                            try await services.secrets.set(value, for: .gitHubToken)
                            token = ""
                            hasStoredToken = true
                            tokenMessage = L10n.text("Token saved.")
                        } catch {
                            tokenMessage = error.localizedDescription
                        }
                    }
                }
                .disabled(token.isEmpty)
                if hasStoredToken {
                    Button("Delete token", role: .destructive) {
                        Task {
                            try? await services.secrets.delete(.gitHubToken)
                            hasStoredToken = false
                            tokenMessage = L10n.text("Token deleted.")
                        }
                    }
                }
            }
            Text(
                hasStoredToken
                    ? "A token is stored in this device’s Keychain. It is used only when you publish a gist."
                    : "Required only to publish gists. It is stored in Keychain — never in the database or cloud."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            if let tokenMessage {
                Text(tokenMessage).font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear {
            guard !ProcessInfo.processInfo.arguments.contains("-use-temp-store") else {
                hasStoredToken = false
                return
            }
            Task {
                hasStoredToken =
                    (try? await services.secrets.contains(.gitHubToken)) ?? false
            }
        }
    }
}
