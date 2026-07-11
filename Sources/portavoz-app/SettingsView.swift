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
///
/// The individual `Section`s live in `extension SettingsView` blocks below
/// (same file, so they keep access to the private `@State`); the struct body
/// itself is just the stored state and the `Form` that composes them.
struct SettingsView: View {
    @Environment(AppServices.self) private var services

    @AppStorage(AppLanguage.storageKey) private var appLanguageRaw = AppLanguage.system.rawValue

    @State private var token = ""
    @State private var hasStoredToken = false
    @State private var tokenMessage: String?

    @State private var voiceprint: Voiceprint?
    @State private var enrolling = false
    @State private var voiceMessage: String?

    @AppStorage("meetingReminderMinutes") private var reminderMinutes = 5
    @AppStorage("aecEnabled") private var aecEnabled = true
    @AppStorage("customVocabulary") private var customVocabulary = ""
    @State private var newTerm = ""
    /// Domain terms mined from past transcripts (VocabularyMiner). A chip
    /// PRE-FILLS the add field for review — the miner surfaces what the
    /// transcriber HEARD, which can be misheard (field case: "Qord2M" for
    /// the real "Kord2m") — so the user confirms or fixes before adding.
    @State private var suggestedTerms: [String] = []
    /// The suggestion currently under review in the add field; adding it
    /// (edited or not) retires it, and a corrected spelling also rejects
    /// the raw misheard form so it never comes back.
    @State private var pendingSuggestion: String?
    /// Dismissed suggestions ("don't suggest again"), comma-separated like
    /// the vocabulary itself; the miner excludes them.
    @AppStorage("vocabularyRejectedSuggestions") private var rejectedSuggestions = ""
    @FocusState private var termFieldFocused: Bool

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
    @State private var whisperVariants: [AppServices.WhisperVariant] = []

    var body: some View {
        Form {
            languageSection
            audioSection
            DictationSection()
            AutomationSection()
            agendaSection
            recordingsSection
            titleSection
            vocabularySection
            summaryEngineSection
            voiceSection
            RememberedVoicesSection()
            companionSection
            byokSection
            gitHubSection
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .frame(minHeight: 620)
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("-use-temp-store") {
                hasStoredToken = false
                hasStoredBYOKKey = false
                voiceprint = nil
            } else {
                hasStoredToken =
                    ((try? SecretStore.get(service: SecretStore.gitHubTokenService))) != nil
                hasStoredBYOKKey =
                    ((try? SecretStore.get(service: SecretStore.byokAPIKeyService))) != nil
                voiceprint = (try? VoiceprintStore().load())
                // Mined chips arrive async and shift the Form's layout —
                // skipped under XCUITest (like the Keychain reads above) so
                // coordinate clicks in tests don't land on moved controls.
                Task { suggestedTerms = await services.mineVocabularySuggestions() }
            }
            if summaryEngine == "ollama" { detectOllama() }
            whisperVariants = services.whisperVariants()
            Task { advice = HardwareRecommender.advise(await services.currentHardwareProfile()) }
        }
    }
}

// MARK: - Language, Audio & Recordings

extension SettingsView {
    // MARK: - Language

    private var languageSection: some View {
        Section("Language") {
            Toggle("Use system language", isOn: systemLanguageBinding)
                .accessibilityIdentifier("settings-language-system-toggle")
            Picker("Language", selection: manualLanguageBinding) {
                Text("English").tag(AppLanguage.english)
                Text("Español").tag(AppLanguage.spanish)
            }
            .pickerStyle(.segmented)
            .disabled(AppLanguage.fromStorage(appLanguageRaw) == .system)
            .accessibilityIdentifier("settings-language-picker")
            // One-line UI copy.
            // swiftlint:disable:next line_length
            Text("This changes the Portavoz interface only. Meeting transcription and summary languages stay controlled by each meeting.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var systemLanguageBinding: Binding<Bool> {
        Binding(
            get: { AppLanguage.fromStorage(appLanguageRaw) == .system },
            set: { useSystem in
                appLanguageRaw = useSystem ? AppLanguage.system.rawValue : AppLanguage.english.rawValue
            })
    }

    private var manualLanguageBinding: Binding<AppLanguage> {
        Binding(
            get: {
                let language = AppLanguage.fromStorage(appLanguageRaw)
                return language == .spanish ? .spanish : .english
            },
            set: { appLanguageRaw = $0.rawValue })
    }

    // MARK: - Audio

    private var audioSection: some View {
        Section("Audio") {
            Toggle("Echo cancellation (recommended with speakers)", isOn: $aecEnabled)
            Text(
                // One-line UI help text.
                // swiftlint:disable:next line_length
                "Subtracts speaker output from the microphone so other participants do not appear as “Me”. With HEADPHONES there is no echo, so you can turn it off safely. Applies from the next recording. (If you sound distant on the call, it is usually the Mac built-in microphone picking you up from far away — nearby headset microphones such as AirPods usually sound much better.)"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Agenda

    private var agendaSection: some View {
        Section("Agenda") {
            Picker("Remind me before meetings", selection: $reminderMinutes) {
                Text("Off").tag(0)
                Text("3 minutes before").tag(3)
                Text("5 minutes before").tag(5)
                Text("10 minutes before").tag(10)
            }
            Text(
                // One-line UI help text.
                // swiftlint:disable:next line_length
                "A floating banner appears before your next calendar meeting — one click starts a recording linked to it. Needs calendar access."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Recordings

    private var recordingsSection: some View {
        Section("Recordings") {
            LabeledContent("Save recordings in") {
                Text(recordingsRoot.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                    .help(recordingsRoot.path)
            }
            HStack {
                Button("Change…") { chooseRecordingsFolder() }
                    .disabled(migrating)
                if RecordingsLocation.shared.isCustom {
                    Button("Use default folder") {
                        moveRecordings(to: RecordingsLocation.shared.defaultRoot, custom: false)
                    }
                    .disabled(migrating)
                }
                if migrating {
                    ProgressView().controlSize(.small)
                }
            }
            Text(
                // One-line UI help text.
                // swiftlint:disable:next line_length
                "Meeting audio lives in Audio/ inside this folder. When you change it, existing recordings move to the new location; the database and transcripts stay where they are."
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
        panel.prompt = L10n.text("Choose")
        panel.message = L10n.text("Choose the folder where Portavoz will store your recordings")
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        moveRecordings(to: chosen, custom: true)
    }

    private func moveRecordings(to destination: URL, custom: Bool) {
        guard !migrating else { return }
        migrating = true
        migrationStatus = L10n.text("Preparing…")
        let origin = RecordingsLocation.shared.currentRoot()
        Task.detached(priority: .userInitiated) {
            let location = RecordingsLocation.shared
            do {
                let moved = try location.migrateAudio(from: origin, to: destination) { index, total in
                    Task { @MainActor in
                        migrationStatus = L10n.format("Moving recording %d of %d…", index, total)
                    }
                }
                try location.setRoot(custom ? destination : nil)
                await MainActor.run {
                    recordingsRoot = location.currentRoot()
                    migrationStatus =
                        moved > 0
                        ? L10n.format("Done: moved %d recording(s).", moved)
                        : L10n.text("Done: folder updated.")
                    migrating = false
                }
            } catch {
                await MainActor.run {
                    migrationStatus =
                        // One-line UI error.
                        // swiftlint:disable:next line_length
                        L10n.format("Migration failed: %@. Nothing was lost — recordings that were not moved are still read from the previous folder; you can retry.", error.localizedDescription)
                    migrating = false
                }
            }
        }
    }
}

// MARK: - Titles & Vocabulary

extension SettingsView {
    // MARK: - Titles

    /// The template tokens with a live example each, so the help and the
    /// insertable chips stay in sync from one source.
    private var titleTokens: [(token: String, example: String, hint: String)] {
        [
            ("{date}", "2026-07-07", "ISO date (sorts the library automatically)"),
            ("{time}", "10.47", "Start time"),
            ("{seq}", "01", "Daily sequence (01, 02…)"),
            ("{weekday}", "martes", "Weekday")
        ]
    }

    private var titleSection: some View {
        Section("Recording titles") {
            HStack {
                TextField("Template", text: $titleTemplate)
                    .font(.body.monospaced())
                Button {
                    showTitleHelp.toggle()
                } label: {
                    Image(systemName: "questionmark.circle")
                }
                .buttonStyle(.borderless)
                .help("Show available tokens and examples")
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
                    .help("\(item.hint) — e.g. \(item.example)")
                }
                Spacer()
                Button("Reset") { titleTemplate = TitleTemplate.defaultTemplate }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(titleTemplate == TitleTemplate.defaultTemplate)
            }
            LabeledContent(
                "Preview",
                value: TitleTemplate.render(titleTemplate, date: .now, sequence: 3))
        }
    }

    private var titleHelpPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Template tokens").font(.headline)
            ForEach(titleTokens, id: \.token) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.token)
                        .font(.callout.monospaced())
                        .frame(width: 90, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.hint)
                        Text("e.g. \(item.example)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            Text(
                // One-line UI help text.
                // swiftlint:disable:next line_length
                "The rest of the text is preserved as written. Putting the ISO date first makes the library sort meetings automatically."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 320)
    }

    // MARK: - Vocabulary

    /// Stored as the same comma-separated string the pipeline parses; the
    /// UI just gives it list ergonomics (Enter to add, − to remove).
    private var vocabularyTerms: [String] {
        var seen = Set<String>()
        return VocabularyPrompt.parse(customVocabulary).filter {
            seen.insert($0.lowercased()).inserted
        }
    }

    private var vocabularySection: some View {
        Section("Vocabulary") {
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
                    .help("Remove \"\(term)\"")
                }
            }
            HStack {
                TextField("Add term (QVTL, Ilarion…)", text: $newTerm)
                    .onSubmit(addTerm)
                    .focused($termFieldFocused)
                Button("Add", action: addTerm)
                    .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if !suggestedTerms.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Suggested from your meetings — click to review before adding")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        ForEach(suggestedTerms, id: \.self) { term in
                            suggestionChip(term)
                        }
                    }
                }
            }
            Text(
                // One-line UI help text.
                // swiftlint:disable:next line_length
                "Acronyms, products, and proper names from your meetings. They guide quality transcription and summaries so “QVTL” does not become something else."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func suggestionChip(_ term: String) -> some View {
        HStack(spacing: 2) {
            Button {
                review(term)
            } label: {
                Label(term, systemImage: "square.and.pencil")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Put \"\(term)\" in the field to review — fix the spelling if it was misheard, then Add")
            Button {
                reject(term)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Don't suggest \"\(term)\" again")
        }
    }

    /// Pre-fills the add field with the mined term so the user can fix the
    /// spelling before confirming — the miner only knows what was HEARD.
    private func review(_ term: String) {
        newTerm = term
        pendingSuggestion = term
        termFieldFocused = true
    }

    /// "Don't suggest again": persists so the next mining pass skips it.
    private func reject(_ term: String) {
        rejectedSuggestions = (VocabularyPrompt.parse(rejectedSuggestions) + [term])
            .joined(separator: ", ")
        suggestedTerms.removeAll { $0 == term }
        if pendingSuggestion == term { pendingSuggestion = nil }
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

        if let pending = pendingSuggestion {
            // The suggestion under review was handled. If the user CORRECTED
            // the spelling (field case: mined "Qord2M" → real "Kord2m"), also
            // reject the raw misheard form so mining never re-suggests it.
            if pending.caseInsensitiveCompare(term) != .orderedSame {
                rejectedSuggestions = (VocabularyPrompt.parse(rejectedSuggestions) + [pending])
                    .joined(separator: ", ")
            }
            suggestedTerms.removeAll { $0 == pending }
            pendingSuggestion = nil
        }
    }
}

// MARK: - My voice & Summary engine

extension SettingsView {
    // MARK: - My voice (M6)

    private var voiceSection: some View {
        Section("My voice") {
            if let voiceprint {
                LabeledContent(
                    "Enrolled voice",
                    value: voiceprint.createdAt.formatted(date: .abbreviated, time: .shortened))
                Button("Delete my voice", role: .destructive) {
                    try? VoiceprintStore().delete()
                    self.voiceprint = nil
                    services.invalidateDiarizer()
                    voiceMessage = L10n.text("Voiceprint and key deleted.")
                }
            } else if enrolling {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Recording 12 seconds — speak naturally…")
                }
            } else {
                Button {
                    Task { await enroll() }
                } label: {
                    Label("Enroll my voice (12 s)", systemImage: "person.wave.2")
                }
            }
            Text(
                // One-line UI help text.
                // swiftlint:disable:next line_length
                "With your voice enrolled, Portavoz also recognizes you when you arrive through system audio (hybrid meetings). Only an encrypted numeric fingerprint is stored on this device — never audio, never cloud data; delete it with one click."
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
                voiceMessage = L10n.text("The diarizer is not available.")
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
            voiceMessage = L10n.text("Done: your interventions will be tagged as “Me” on any channel.")
        } catch {
            voiceMessage = L10n.format("Could not enroll: %@", error.localizedDescription)
        }
    }

    // MARK: - Summary engine (D25/M12)

    private var summaryEngineSection: some View {
        Section("Summary engine") {
            if let advice {
                VStack(alignment: .leading, spacing: 4) {
                    Label(advice.headline, systemImage: "wand.and.stars.inverse")
                        .font(.callout.weight(.medium))
                    ForEach(advice.reasons, id: \.self) { reason in
                        Text("• \(reason)").font(.caption).foregroundStyle(.secondary)
                    }
                    if advice.engine != .none {
                        Button("Apply recommendation") { applyRecommendation(advice) }
                            .controlSize(.small)
                            .padding(.top, 2)
                    }
                }
            }
            Picker("Generate summaries with", selection: $summaryEngine) {
                Text("Apple (on-device)").tag("appleOnDevice")
                Text("Ollama (local)").tag("ollama")
                Text("Built-in (MLX)").tag("mlx")
            }
            .pickerStyle(.radioGroup)
            .accessibilityIdentifier("settings-summary-engine-picker")
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
                            Label("Detect models", systemImage: "arrow.clockwise")
                        }
                    }
                    .controlSize(.small)
                    .disabled(detectingOllama)
                    if let ollamaStatus {
                        Text(ollamaStatus).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !ollamaModels.isEmpty {
                    Picker("Model", selection: $ollamaModel) {
                        Text("Choose a model").tag("")
                        ForEach(ollamaModels) { model in
                            Text(
                                model.parameterSize.isEmpty
                                    ? model.name : "\(model.name) · \(model.parameterSize)"
                            ).tag(model.name)
                        }
                    }
                }
            }
            if summaryEngine == "mlx" {
                MLXModelRow(services: services)
            }
            Text(
                // One-line UI help text.
                // swiftlint:disable:next line_length
                "Apple uses Foundation Models (macOS 26 + Apple Intelligence). Ollama runs a 100% local model on your Mac. Built-in runs an embedded 4B model (one 3 GB verified download) with zero installs. Either way, nothing leaves the device. (The LIVE summary during recording always uses Apple.)"
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Divider()
            Text("Refine model (Whisper large-v3)")
                .font(.callout.weight(.medium))
            ForEach(whisperVariants) { variant in
                let active = variant.compact == whisperCompact
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: active ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(active ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(
                            variant.compact
                                ? "Compact — less disk" : "Turbo — best quality"
                        )
                        .font(.callout)
                        Text(
                            (variant.downloaded ? "Downloaded · " : "Downloads on refine · ")
                                + ByteCountFormatter.string(
                                    fromByteCount: variant.bytes, countStyle: .file)
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if variant.downloaded && !active {
                        Button("Delete") {
                            services.deleteWhisperVariant(variant.id)
                            whisperVariants = services.whisperVariants()
                        }
                        .controlSize(.small)
                        .help("Free disk used by the variant you do not use")
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { whisperCompact = variant.compact }
            }
            Text(
                // One-line UI help text.
                // swiftlint:disable:next line_length
                "The quality re-pass (Refine) uses Whisper. Turbo is the default; the compact variant saves about 1 GB of disk. Choose by selecting a row."
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
                    L10n.text("Ollama is not responding on localhost:11434. Install it and run “ollama serve”.")
                return
            }
            ollamaModels = await OllamaService.models()
            // When applying the recommendation, pick a sensible default
            // (skip OCR-only models, which can't chat).
            if autoSelect, ollamaModel.isEmpty,
                let first = ollamaModels.first(where: { !$0.name.contains("ocr") }) {
                ollamaModel = first.name
            }
            ollamaStatus =
                ollamaModels.isEmpty
                ? L10n.text("Ollama is running but has no models. Download one with “ollama pull llama3.2”.")
                : L10n.format("%d model(s) available.", ollamaModels.count)
        }
    }

    private func applyRecommendation(_ advice: EngineAdvice) {
        switch advice.engine {
        case .mlx:
            summaryEngine = "mlx"
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
}

// MARK: - Companion, BYOK & GitHub

extension SettingsView {
    // MARK: - Companion (D26)

    private var companionSection: some View {
        Section("Companion") {
            TextField("Your name in meetings", text: $companionUserName, prompt: Text(NSFullUserName()))
                .autocorrectionDisabled()
            Text(
                "When someone asks for you by name (\"\(companionUserName.isEmpty ? NSFullUserName() : companionUserName), what do you think?\"), Companion highlights the card as “asked you” even when it is not a technical question. Empty = use your macOS account name."
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
        Section("External model (BYOK)") {
            TextField(
                "Endpoint OpenAI-compatible", text: $byokEndpoint,
                prompt: Text("https://api.openai.com/v1")
            )
            .autocorrectionDisabled()
            TextField("Model", text: $byokModel, prompt: Text("gpt-4o-mini"))
                .autocorrectionDisabled()
            SecureField("API key", text: $byokKey)
            HStack {
                Button("Save key in Keychain") {
                    do {
                        try SecretStore.set(byokKey, service: SecretStore.byokAPIKeyService)
                        byokKey = ""
                        hasStoredBYOKKey = true
                        byokMessage = L10n.text("Key saved.")
                    } catch {
                        byokMessage = error.localizedDescription
                    }
                }
                .disabled(byokKey.isEmpty)
                if hasStoredBYOKKey {
                    Button("Delete key", role: .destructive) {
                        try? SecretStore.delete(service: SecretStore.byokAPIKeyService)
                        hasStoredBYOKKey = false
                        companionBYOKEnabled = false
                        byokMessage = L10n.text("Key deleted. Companion goes back to answering only on-device.")
                    }
                }
            }
            Toggle(
                "Answer Companion knowledge questions with this provider",
                isOn: $companionBYOKEnabled
            )
            .disabled(!byokReady)
            Text(
                // One-line UI help text.
                // swiftlint:disable:next line_length
                "Any /chat/completions endpoint works: OpenAI, OpenRouter, Groq, or a local Ollama/LM Studio server (http://localhost:11434/v1 — there, nothing leaves your device). When the switch is on, Companion sends ONLY the detected question text — never audio or the rest of the meeting — and each card says who answered. If the provider fails, the answer falls back to the local model."
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
    }
}
