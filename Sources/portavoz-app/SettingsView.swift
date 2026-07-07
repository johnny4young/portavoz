import IntegrationsKit
import SwiftUI

/// App settings (⌘,). The GitHub token lives in the Keychain and nowhere
/// else — the field never shows a stored token back, only its presence.
struct SettingsView: View {
    @State private var token = ""
    @State private var hasStoredToken = false
    @State private var message: String?

    var body: some View {
        Form {
            Section("GitHub") {
                SecureField("Token personal (scope: gist)", text: $token)
                HStack {
                    Button("Guardar en el Keychain") {
                        do {
                            try SecretStore.set(token, service: SecretStore.gitHubTokenService)
                            token = ""
                            hasStoredToken = true
                            message = "Token guardado."
                        } catch {
                            message = error.localizedDescription
                        }
                    }
                    .disabled(token.isEmpty)
                    if hasStoredToken {
                        Button("Eliminar token", role: .destructive) {
                            try? SecretStore.delete(service: SecretStore.gitHubTokenService)
                            hasStoredToken = false
                            message = "Token eliminado."
                        }
                    }
                }
                Text(
                    hasStoredToken
                        ? "Hay un token guardado en el Keychain de este equipo. Se usa solo cuando publicas un gist."
                        : "Necesario solo para publicar gists. Se guarda en el Keychain — nunca en la base de datos ni en la nube."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                if let message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onAppear {
            hasStoredToken =
                ((try? SecretStore.get(service: SecretStore.gitHubTokenService)) ?? nil) != nil
        }
    }
}
