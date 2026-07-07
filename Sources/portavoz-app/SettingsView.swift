import AppKit
import AudioCaptureKit
import DiarizationKit
import IntegrationsKit
import PortavozCore
import StorageKit
import SwiftUI
import TranscriptionKit

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

    @AppStorage("aecEnabled") private var aecEnabled = true
    @AppStorage("customVocabulary") private var customVocabulary = ""
    @State private var newTerm = ""

    @AppStorage("titleTemplate") private var titleTemplate = TitleTemplate.defaultTemplate

    @State private var recordingsRoot = RecordingsLocation.shared.currentRoot()
    @State private var migrationStatus: String?
    @State private var migrating = false

    var body: some View {
        Form {
            audioSection
            recordingsSection
            titleSection
            vocabularySection
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

    // MARK: - Audio

    private var audioSection: some View {
        Section("Audio") {
            Toggle("Cancelación de eco (recomendado)", isOn: $aecEnabled)
            Text(
                "Elimina del micrófono el audio que sale por tus parlantes, para que los demás participantes no aparezcan como \"Yo\". Aplica desde la próxima grabación. Desactívala solo si notas problemas con tu micrófono."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Grabaciones

    private var recordingsSection: some View {
        Section("Grabaciones") {
            LabeledContent("Guardar las grabaciones en") {
                Text(recordingsRoot.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                    .help(recordingsRoot.path)
            }
            HStack {
                Button("Cambiar…") { chooseRecordingsFolder() }
                    .disabled(migrating)
                if RecordingsLocation.shared.isCustom {
                    Button("Usar carpeta por defecto") {
                        moveRecordings(to: RecordingsLocation.shared.defaultRoot, custom: false)
                    }
                    .disabled(migrating)
                }
                if migrating {
                    ProgressView().controlSize(.small)
                }
            }
            Text(
                "El audio de las reuniones vive en Audio/ dentro de esta carpeta. Al cambiarla, las grabaciones existentes se mueven a la nueva ubicación; la base de datos y los transcripts se quedan donde están."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            if let migrationStatus {
                Text(migrationStatus).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func chooseRecordingsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = recordingsRoot
        panel.prompt = "Elegir"
        panel.message = "Elige la carpeta donde Portavoz guardará tus grabaciones"
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        moveRecordings(to: chosen, custom: true)
    }

    private func moveRecordings(to destination: URL, custom: Bool) {
        guard !migrating else { return }
        migrating = true
        migrationStatus = "Preparando…"
        let origin = RecordingsLocation.shared.currentRoot()
        Task.detached(priority: .userInitiated) {
            let location = RecordingsLocation.shared
            do {
                let moved = try location.migrateAudio(from: origin, to: destination) {
                    index, total in
                    Task { @MainActor in
                        migrationStatus = "Moviendo grabación \(index) de \(total)…"
                    }
                }
                try location.setRoot(custom ? destination : nil)
                await MainActor.run {
                    recordingsRoot = location.currentRoot()
                    migrationStatus =
                        moved > 0
                        ? "Listo: \(moved) grabación(es) movidas." : "Listo: carpeta actualizada."
                    migrating = false
                }
            } catch {
                await MainActor.run {
                    migrationStatus =
                        "La migración falló: \(error.localizedDescription). Nada se perdió — las grabaciones sin mover siguen leyéndose de la carpeta anterior; puedes reintentar."
                    migrating = false
                }
            }
        }
    }

    // MARK: - Títulos

    private var titleSection: some View {
        Section("Títulos de grabación") {
            TextField("Plantilla", text: $titleTemplate)
                .font(.body.monospaced())
            LabeledContent(
                "Vista previa",
                value: TitleTemplate.render(titleTemplate, date: .now, sequence: 3))
            Text(
                "Tokens: {date} → 2026-07-07 · {time} → 10.47 · {seq} → secuencia del día (01, 02…) · {weekday} → día de la semana. La fecha ISO primero hace que la biblioteca ordene sola."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Vocabulario

    /// Stored as the same comma-separated string the pipeline parses; the
    /// UI just gives it list ergonomics (Enter to add, − to remove).
    private var vocabularyTerms: [String] {
        var seen = Set<String>()
        return VocabularyPrompt.parse(customVocabulary).filter {
            seen.insert($0.lowercased()).inserted
        }
    }

    private var vocabularySection: some View {
        Section("Vocabulario") {
            ForEach(vocabularyTerms, id: \.self) { term in
                HStack {
                    Text(term)
                    Spacer()
                    Button {
                        customVocabulary = vocabularyTerms.filter { $0 != term }
                            .joined(separator: ", ")
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Quitar \"\(term)\"")
                }
            }
            HStack {
                TextField("Añadir término (LVGT, Vishakha…)", text: $newTerm)
                    .onSubmit(addTerm)
                Button("Añadir", action: addTerm)
                    .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text(
                "Siglas, productos y nombres propios de tus reuniones. Guían la transcripción de calidad y los resúmenes para que \"LVGT\" no se convierta en otra cosa."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func addTerm() {
        let term = newTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        var terms = vocabularyTerms
        if !terms.contains(where: { $0.caseInsensitiveCompare(term) == .orderedSame }) {
            terms.append(term)
        }
        customVocabulary = terms.joined(separator: ", ")
        newTerm = ""
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
