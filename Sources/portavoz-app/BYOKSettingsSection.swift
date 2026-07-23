import ApplicationKit
import Foundation
import IntelligenceKit
import SwiftUI

/// External intelligence credentials stay behind the application secret
/// workflow; this view owns only the user's visible preferences and feedback.
struct BYOKSettingsSection: View {
    @Binding var endpoint: String
    @Binding var model: String
    @Binding var key: String
    @Binding var isEnabled: Bool
    @Binding var hasStoredKey: Bool
    @Binding var message: String?

    let secrets: ManageSecrets
    let companionAvailable: Bool

    private var isReady: Bool {
        hasStoredKey
            && BYOKSettings.endpointURL(from: endpoint) != nil
            && !model.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        Section("External model (BYOK)") {
            TextField(
                "Endpoint OpenAI-compatible", text: $endpoint,
                prompt: Text("https://api.openai.com/v1")
            )
            .autocorrectionDisabled()
            TextField("Model", text: $model, prompt: Text("gpt-4o-mini"))
                .autocorrectionDisabled()
            SecureField("API key", text: $key)
            HStack {
                Button("Save key in Keychain") {
                    saveKey()
                }
                .disabled(key.isEmpty)
                if hasStoredKey {
                    Button("Delete key", role: .destructive) {
                        deleteKey()
                    }
                }
            }
            Toggle(
                "Answer Apuntador knowledge questions with this provider",
                isOn: $isEnabled
            )
            .disabled(!isReady || !companionAvailable)
            Text(
                // One-line UI help text.
                // swiftlint:disable:next line_length
                "Any /chat/completions endpoint works: OpenAI, OpenRouter, Groq, or a local Ollama/LM Studio server (http://localhost:11434/v1 — there, nothing leaves your device). When the switch is on, Apuntador sends ONLY the detected question text — never audio or the rest of the meeting — and each card says who answered. If the provider fails, the answer falls back to the local model."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func saveKey() {
        let value = key
        Task {
            do {
                try await secrets.set(value, for: .byokAPIKey)
                key = ""
                hasStoredKey = true
                message = L10n.text("Key saved.")
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func deleteKey() {
        Task {
            try? await secrets.delete(.byokAPIKey)
            hasStoredKey = false
            isEnabled = false
            message = L10n.text(
                "Key deleted. Apuntador goes back to answering only on-device.")
        }
    }
}
