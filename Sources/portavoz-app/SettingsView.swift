import AppKit
import AudioCaptureKit
import DiarizationKit
import IntegrationsKit
import IntelligenceKit
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
    @State private var showTitleHelp = false

    @State private var recordingsRoot = RecordingsLocation.shared.currentRoot()
    @State private var migrationStatus: String?
    @State private var migrating = false

    @AppStorage(BYOKSettings.endpointKey) private var byokEndpoint = ""
    @AppStorage(BYOKSettings.modelKey) private var byokModel = ""
    @AppStorage(BYOKSettings.companionEnabledKey) private var companionBYOKEnabled = false
    @State private var byokKey = ""
    @State private var hasStoredBYOKKey = false
    @State private var byokMessage: String?

    @AppStorage("companionUserName") private var companionUserName = ""

    @AppStorage("summaryEngine") private var summaryEngine = "appleOnDevice"
    @AppStorage("ollamaModel") private var ollamaModel = ""
    @AppStorage("whisperCompact") private var whisperCompact = false
    @State private var ollamaModels: [OllamaService.Model] = []
    @State private var ollamaStatus: String?
    @State private var detectingOllama = false
    @State private var advice: EngineAdvice?

    var body: some View {
        Form {
            audioSection
            recordingsSection
            titleSection
            vocabularySection
            summaryEngineSection
            voiceSection
            companionSection
            byokSection
            gitHubSection
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .onAppear {
            hasStoredToken =
                ((try? SecretStore.get(service: SecretStore.gitHubTokenService)) ?? nil) != nil
            hasStoredBYOKKey =
                ((try? SecretStore.get(service: SecretStore.byokAPIKeyService)) ?? nil) != nil
            voiceprint = (try? VoiceprintStore().load()) ?? nil
            if summaryEngine == "ollama" { detectOllama() }
            Task { advice = HardwareRecommender.advise(await services.currentHardwareProfile()) }
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

    /// The template tokens with a live example each, so the help and the
    /// insertable chips stay in sync from one source.
    private var titleTokens: [(token: String, example: String, hint: String)] {
        [
            ("{date}", "2026-07-07", "Fecha ISO (ordena sola la biblioteca)"),
            ("{time}", "10.47", "Hora de inicio"),
            ("{seq}", "01", "Secuencia del día (01, 02…)"),
            ("{weekday}", "martes", "Día de la semana"),
        ]
    }

    private var titleSection: some View {
        Section("Títulos de grabación") {
            HStack {
                TextField("Plantilla", text: $titleTemplate)
                    .font(.body.monospaced())
                Button {
                    showTitleHelp.toggle()
                } label: {
                    Image(systemName: "questionmark.circle")
                }
                .buttonStyle(.borderless)
                .help("Ver los tokens disponibles y ejemplos")
                .popover(isPresented: $showTitleHelp, arrowEdge: .bottom) {
                    titleHelpPopover
                }
            }
            // Insertable chips: click to append the token to the template.
            // Discoverability beats a buried caption — you see and use the
            // tokens without reading anything.
            HStack(spacing: 6) {
                ForEach(titleTokens, id: \.token) { item in
                    Button {
                        titleTemplate += item.token
                    } label: {
                        Text(item.token).font(.caption.monospaced())
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("\(item.hint) — ej. \(item.example)")
                }
                Spacer()
                Button("Restablecer") { titleTemplate = TitleTemplate.defaultTemplate }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(titleTemplate == TitleTemplate.defaultTemplate)
            }
            LabeledContent(
                "Vista previa",
                value: TitleTemplate.render(titleTemplate, date: .now, sequence: 3))
        }
    }

    private var titleHelpPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tokens de plantilla").font(.headline)
            ForEach(titleTokens, id: \.token) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.token)
                        .font(.callout.monospaced())
                        .frame(width: 90, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.hint)
                        Text("ej. \(item.example)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            Text(
                "El resto del texto se conserva tal cual. Poner la fecha ISO primero hace que la biblioteca ordene las reuniones sola."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 320)
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

    // MARK: - Motor de resúmenes (D25/M12)

    private var summaryEngineSection: some View {
        Section("Motor de resúmenes") {
            if let advice {
                VStack(alignment: .leading, spacing: 4) {
                    Label(advice.headline, systemImage: "wand.and.stars.inverse")
                        .font(.callout.weight(.medium))
                    ForEach(advice.reasons, id: \.self) { reason in
                        Text("• \(reason)").font(.caption).foregroundStyle(.secondary)
                    }
                    if advice.engine != .none {
                        Button("Aplicar recomendación") { applyRecommendation(advice) }
                            .controlSize(.small)
                            .padding(.top, 2)
                    }
                }
            }
            Picker("Generar resúmenes con", selection: $summaryEngine) {
                Text("Apple (on-device)").tag("appleOnDevice")
                Text("Ollama (local)").tag("ollama")
            }
            .pickerStyle(.radioGroup)
            .onChange(of: summaryEngine) { _, engine in
                if engine == "ollama" { detectOllama() }
            }
            if summaryEngine == "ollama" {
                HStack {
                    Button {
                        detectOllama()
                    } label: {
                        if detectingOllama {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Detectar modelos", systemImage: "arrow.clockwise")
                        }
                    }
                    .controlSize(.small)
                    .disabled(detectingOllama)
                    if let ollamaStatus {
                        Text(ollamaStatus).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !ollamaModels.isEmpty {
                    Picker("Modelo", selection: $ollamaModel) {
                        Text("Elige un modelo").tag("")
                        ForEach(ollamaModels) { model in
                            Text(
                                model.parameterSize.isEmpty
                                    ? model.name : "\(model.name) · \(model.parameterSize)"
                            ).tag(model.name)
                        }
                    }
                }
            }
            Text(
                "Apple usa Foundation Models (macOS 26 + Apple Intelligence). Ollama corre un modelo 100% local en tu Mac — ideal si no tienes Apple Intelligence. Con cualquiera, nada sale del equipo. (El resumen EN VIVO durante la grabación siempre usa Apple.)"
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Divider()
            Toggle("Whisper compacto para el refine (626 MB)", isOn: $whisperCompact)
            Text(
                "El re-pase de calidad (Refinar) usa Whisper large-v3: 626 MB en vez de 1.6 GB, ideal si tienes poco disco. Se descarga la primera vez que refinas."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func detectOllama(autoSelect: Bool = false) {
        detectingOllama = true
        ollamaStatus = nil
        Task {
            defer { detectingOllama = false }
            guard await OllamaService.isRunning() else {
                ollamaModels = []
                ollamaStatus =
                    "Ollama no responde en localhost:11434. Instálalo y corre «ollama serve»."
                return
            }
            ollamaModels = await OllamaService.models()
            // When applying the recommendation, pick a sensible default
            // (skip OCR-only models, which can't chat).
            if autoSelect, ollamaModel.isEmpty,
                let first = ollamaModels.first(where: { !$0.name.contains("ocr") })
            {
                ollamaModel = first.name
            }
            ollamaStatus =
                ollamaModels.isEmpty
                ? "Ollama corre pero no hay modelos. Descarga uno con «ollama pull llama3.2»."
                : "\(ollamaModels.count) modelo(s) disponibles."
        }
    }

    private func applyRecommendation(_ advice: EngineAdvice) {
        switch advice.engine {
        case .apple:
            summaryEngine = "appleOnDevice"
        case .ollama:
            summaryEngine = "ollama"
            detectOllama(autoSelect: true)
        case .none:
            break
        }
        // Low disk → the compact Whisper for the refine, too.
        if advice.whisperLowDisk { whisperCompact = true }
    }

    // MARK: - Companion (D26)

    private var companionSection: some View {
        Section("Companion") {
            TextField("Tu nombre en las reuniones", text: $companionUserName, prompt: Text(NSFullUserName()))
                .autocorrectionDisabled()
            Text(
                "Cuando alguien te pregunta por tu nombre (\"\(companionUserName.isEmpty ? NSFullUserName() : companionUserName), ¿qué opinas?\"), el Companion resalta la tarjeta con \"te preguntaron\" aunque no sea una pregunta técnica. Vacío = usa el nombre de tu cuenta de macOS."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - BYOK (D8/D26)

    /// The endpoint/model are visible preferences; the key is Keychain-only.
    /// The companion toggle is the ONLY thing that lets a question leave the
    /// device, and it stays disabled until everything is configured.
    private var byokReady: Bool {
        hasStoredBYOKKey
            && BYOKSettings.endpointURL(from: byokEndpoint) != nil
            && !byokModel.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var byokSection: some View {
        Section("Modelo externo (BYOK)") {
            TextField(
                "Endpoint OpenAI-compatible", text: $byokEndpoint,
                prompt: Text("https://api.openai.com/v1")
            )
            .autocorrectionDisabled()
            TextField("Modelo", text: $byokModel, prompt: Text("gpt-4o-mini"))
                .autocorrectionDisabled()
            SecureField("API key", text: $byokKey)
            HStack {
                Button("Guardar key en el Keychain") {
                    do {
                        try SecretStore.set(byokKey, service: SecretStore.byokAPIKeyService)
                        byokKey = ""
                        hasStoredBYOKKey = true
                        byokMessage = "Key guardada."
                    } catch {
                        byokMessage = error.localizedDescription
                    }
                }
                .disabled(byokKey.isEmpty)
                if hasStoredBYOKKey {
                    Button("Eliminar key", role: .destructive) {
                        try? SecretStore.delete(service: SecretStore.byokAPIKeyService)
                        hasStoredBYOKKey = false
                        companionBYOKEnabled = false
                        byokMessage = "Key eliminada. El Companion vuelve a responder solo on-device."
                    }
                }
            }
            Toggle(
                "Responder las preguntas de conocimiento del Companion con este proveedor",
                isOn: $companionBYOKEnabled
            )
            .disabled(!byokReady)
            Text(
                "Sirve cualquier endpoint /chat/completions: OpenAI, OpenRouter, Groq, o un Ollama/LM Studio local (http://localhost:11434/v1 — ahí nada sale de tu equipo). Con el interruptor activo, el Companion envía SOLO el texto de la pregunta detectada — nunca audio ni el resto de la reunión — y cada tarjeta dice quién respondió. Si el proveedor falla, la respuesta cae al modelo local."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            if let byokMessage {
                Text(byokMessage).font(.caption).foregroundStyle(.secondary)
            }
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
