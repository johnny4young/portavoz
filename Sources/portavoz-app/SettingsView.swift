import AudioCaptureKit
import DiarizationKit
import IntegrationsKit
import PortavozCore
import SwiftUI

/// App settings (⌘,): voice enrollment and the GitHub token. Both secrets
/// live in the Keychain / encrypted files — never in the database.
struct SettingsView: View {
    @Environment(AppServices.self) private var services

    @State private var token = ""
    @State private var hasStoredToken = false
    @State private var tokenMessage: String?

    @State private var voiceprint: Voiceprint?
    @State private var enrolling = false
    @State private var voiceMessage: String?

    var body: some View {
        Form {
            voiceSection
            gitHubSection
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .onAppear {
            hasStoredToken =
                ((try? SecretStore.get(service: SecretStore.gitHubTokenService)) ?? nil) != nil
            voiceprint = (try? VoiceprintStore().load()) ?? nil
        }
    }

    // MARK: - Mi voz (M6)

    private var voiceSection: some View {
        Section("Mi voz") {
            if let voiceprint {
                LabeledContent(
                    "Voz enrolada",
                    value: voiceprint.createdAt.formatted(date: .abbreviated, time: .shortened))
                Button("Eliminar mi voz", role: .destructive) {
                    try? VoiceprintStore().delete()
                    self.voiceprint = nil
                    services.invalidateDiarizer()
                    voiceMessage = "Voiceprint y llave eliminados."
                }
            } else if enrolling {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Grabando 12 segundos — habla con naturalidad…")
                }
            } else {
                Button {
                    Task { await enroll() }
                } label: {
                    Label("Enrolar mi voz (12 s)", systemImage: "person.wave.2")
                }
            }
            Text(
                "Con tu voz enrolada, Portavoz te reconoce también cuando llegas por el audio del sistema (reuniones híbridas). Solo se guarda una huella numérica cifrada en este equipo — nunca el audio, nunca en la nube; se borra con un clic."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            if let voiceMessage {
                Text(voiceMessage).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func enroll() async {
        enrolling = true
        defer { enrolling = false }
        do {
            try await services.loadEnginesIfNeeded()
            guard let diarizer = services.diarizer else {
                voiceMessage = "El diarizador no está disponible."
                return
            }
            let microphone = MicrophoneSource()
            let stream = try await microphone.start()
            var samples: [Float] = []
            var sampleRate = 16_000.0
            let deadline = Date().addingTimeInterval(12)
            for try await chunk in stream {
                samples.append(contentsOf: chunk.samples)
                sampleRate = chunk.sampleRate
                if Date() >= deadline { break }
            }
            await microphone.stop()

            let print = try await diarizer.extractVoiceprint(
                fromSamples: samples, sampleRate: sampleRate)
            try VoiceprintStore().save(print)
            voiceprint = print
            services.invalidateDiarizer()
            voiceMessage = "Listo: tus intervenciones se etiquetarán como \"Me\" en cualquier canal."
        } catch {
            voiceMessage = "No se pudo enrolar: \(error.localizedDescription)"
        }
    }

    // MARK: - GitHub

    private var gitHubSection: some View {
        Section("GitHub") {
            SecureField("Token personal (scope: gist)", text: $token)
            HStack {
                Button("Guardar en el Keychain") {
                    do {
                        try SecretStore.set(token, service: SecretStore.gitHubTokenService)
                        token = ""
                        hasStoredToken = true
                        tokenMessage = "Token guardado."
                    } catch {
                        tokenMessage = error.localizedDescription
                    }
                }
                .disabled(token.isEmpty)
                if hasStoredToken {
                    Button("Eliminar token", role: .destructive) {
                        try? SecretStore.delete(service: SecretStore.gitHubTokenService)
                        hasStoredToken = false
                        tokenMessage = "Token eliminado."
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
            if let tokenMessage {
                Text(tokenMessage).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
