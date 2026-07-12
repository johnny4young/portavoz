import IntegrationsKit
import SwiftUI

/// Settings section: the GitHub personal token used to publish gists.
/// Self-contained (its Keychain state lives here, not in SettingsView);
/// the secret goes to the Keychain — never the database (D8).
struct GitHubSection: View {
    @State private var token = ""
    @State private var hasStoredToken = false
    @State private var tokenMessage: String?

    var body: some View {
        Section("GitHub") {
            SecureField("Personal token (scope: gist)", text: $token)
            HStack {
                Button("Save in Keychain") {
                    do {
                        try SecretStore.set(token, service: SecretStore.gitHubTokenService)
                        token = ""
                        hasStoredToken = true
                        tokenMessage = L10n.text("Token saved.")
                    } catch {
                        tokenMessage = error.localizedDescription
                    }
                }
                .disabled(token.isEmpty)
                if hasStoredToken {
                    Button("Delete token", role: .destructive) {
                        try? SecretStore.delete(service: SecretStore.gitHubTokenService)
                        hasStoredToken = false
                        tokenMessage = L10n.text("Token deleted.")
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
            hasStoredToken =
                ((try? SecretStore.get(service: SecretStore.gitHubTokenService))) != nil
        }
    }
}
