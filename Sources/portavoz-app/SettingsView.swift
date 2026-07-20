import AppKit
import ApplicationKit
import IntegrationsKit
import IntelligenceKit
import PortavozCore
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

    @State private var voiceEnrollmentDate: Date?
    @State private var enrolling = false
    @State private var voiceMessage: String?

    @AppStorage("meetingReminderMinutes") private var reminderMinutes = 5
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

    @State private var recordingStorage: RecordingStorageLocation?
    @State private var migrationStatus: String?
    @State private var migrating = false

    @AppStorage(BYOKSettings.endpointKey) private var byokEndpoint = ""
    @AppStorage(BYOKSettings.modelKey) private var byokModel = ""
    @AppStorage(BYOKSettings.companionEnabledKey) private var companionBYOKEnabled = false
    @State private var byokKey = ""
    @State private var hasStoredBYOKKey = false
    @State private var byokMessage: String?

    @AppStorage("companionUserName") private var companionUserName = ""
    @AppStorage("mirrorAfterMeeting") private var mirrorAfterMeeting = false

    // Internal (not private) so the intelligence-pane extension in
    // SettingsView+Intelligence.swift can reach them.
    @AppStorage(MeetingLanguagePreferences.transcriptKey) var transcriptionLanguage = "auto"
    @AppStorage(MeetingLanguagePreferences.summaryKey) var summaryLanguage = "spoken"
    @State var customStructures: [Recipe] = CustomRecipeStore.custom()
    @State var editingStructure: Recipe?
    @State var showingStructureSheet = false
    @AppStorage("summaryEngine") private var summaryEngine = SummaryEngine.mlx.rawValue
    @AppStorage("ollamaModel") private var ollamaModel = ""
    @AppStorage("whisperCompact") private var whisperCompact = false
    @State private var ollamaModels: [LocalSummaryModel] = []
    @State private var ollamaStatus: String?
    @State private var detectingOllama = false
    @State private var providerRecommendation: LocalSummaryProviderRecommendation?
    @State private var whisperVariants: [AppServices.WhisperVariant] = []

    /// 2a: category navigation instead of one endless scroll. The search
    /// field filters categories by what each pane contains.
    @State private var category: SettingsCategory? = .general
    @State private var settingsQuery = ""

    var body: some View {
        // A fixed two-pane layout, NOT a NavigationSplitView: the settings
        // window is a fixed size with a permanent sidebar (design system 2a),
        // so the collapsible split view only added a misplaced toggle button
        // and — with the fixed window width — crashed on collapse/expand. The
        // NavigationStack is just for the centered titlebar title; it adds no
        // collapse chrome.
        NavigationStack {
            settingsBody
        }
    }

    private var settingsBody: some View {
        HStack(spacing: 0) {
            SettingsSidebar(category: $category, query: $settingsQuery)
                .frame(width: 224)
            Divider()
            Form {
                switch category ?? .general {
                case .general:
                    languageSection
                    MenuBarSection()
                case .audio:
                    AudioSection()
                    DictationSection()
                case .intelligence:
                    transcriptionLanguageSection
                    summaryLanguageSection
                    summaryEngineSection
                    customStructuresSection
                    vocabularySection
                case .voice:
                    voiceSection
                    RememberedVoicesSection()
                    companionSection
                case .agenda:
                    agendaSection
                    AutomationSection()
                    titleSection
                case .integrations:
                    byokSection
                    GitHubSection()
                case .sync:
                    MeetingSyncSettingsSection()
                case .data:
                    LedgerSection(model: services.localDataLedger)
                    SupportDiagnosticsSection()
                    BackupSection()
                    recordingsSection
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity)
        }
        .frame(width: 760)
        .frame(minHeight: 620)
        .navigationTitle((category ?? .general).title)
        .sheet(isPresented: $showingStructureSheet) {
            CustomStructureSheet(existing: editingStructure) { recipe in
                CustomRecipeStore.upsert(recipe)
                customStructures = CustomRecipeStore.custom()
            }
        }
        .onAppear {
            applyPendingCategory()
            if ProcessInfo.processInfo.arguments.contains("-use-temp-store") {
                hasStoredBYOKKey = false
                voiceEnrollmentDate = nil
            } else {
                Task {
                    hasStoredBYOKKey =
                        (try? await services.secrets.contains(.byokAPIKey)) ?? false
                    voiceEnrollmentDate = try? await services
                        .localVoiceIdentityStatus()?.createdAt
                    // Mined chips arrive async and shift the Form's layout —
                    // skipped under XCUITest so coordinate clicks remain stable.
                    suggestedTerms = await services.mineVocabularySuggestions()
                }
            }
            Task {
                whisperVariants = await services.whisperVariants()
                recordingStorage = await services.recordingStorageLocation()
                await refreshLocalSummaryProviders(
                    showOllamaStatus: summaryEngine == SummaryEngine.ollama.rawValue)
            }
        }
        .onChange(of: services.whisperDownloadState) { _, state in
            if case .ready = state {
                Task {
                    whisperVariants = await services.whisperVariants()
                }
            }
        }
        .onChange(of: services.pendingSettingsCategory) { _, _ in
            applyPendingCategory()
        }
    }

    private func applyPendingCategory() {
        guard let requested = services.pendingSettingsCategory else { return }
        category = requested
        services.pendingSettingsCategory = nil
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
            Text(
                // One-line UI copy.
                // swiftlint:disable:next line_length
                "This changes the Portavoz interface only. Transcript and summary language policies stay in Intelligence settings and each meeting's overrides."
            )
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
                if let recordingStorage {
                    Text(recordingStorage.currentRoot.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                        .help(recordingStorage.currentRoot.path)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            HStack {
                Button("Change…") { chooseRecordingsFolder() }
                    .disabled(migrating || recordingStorage == nil)
                    .accessibilityIdentifier("settings-recordings-change")
                if recordingStorage?.isCustom == true {
                    Button("Use default folder") {
                        moveRecordings(to: nil)
                    }
                    .disabled(migrating)
                    .accessibilityIdentifier("settings-recordings-use-default")
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
        panel.directoryURL = recordingStorage?.currentRoot
        panel.prompt = L10n.text("Choose")
        panel.message = L10n.text("Choose the folder where Portavoz will store your recordings")
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        moveRecordings(to: chosen)
    }

    private func moveRecordings(to destination: URL?) {
        guard !migrating else { return }
        migrating = true
        migrationStatus = L10n.text("Preparing…")
        Task {
            do {
                let update = try await services.updateRecordingStorage(to: destination) { progress in
                    migrationStatus = L10n.format(
                        "Moving recording %d of %d…",
                        progress.completed,
                        progress.total)
                }
                recordingStorage = update.location
                migrationStatus =
                    update.recordingCount > 0
                    ? L10n.format(
                        "Done: moved %d recording(s).",
                        update.recordingCount)
                    : L10n.text("Done: folder updated.")
                migrating = false
            } catch {
                migrationStatus =
                    // One-line UI error.
                    // swiftlint:disable:next line_length
                    L10n.format("Migration failed: %@. Nothing was lost — recordings that were not moved are still read from the previous folder; you can retry.", error.localizedDescription)
                migrating = false
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
            if let voiceEnrollmentDate {
                LabeledContent(
                    "Enrolled voice",
                    value: voiceEnrollmentDate.formatted(date: .abbreviated, time: .shortened))
                Button("Delete my voice", role: .destructive) {
                    Task { await deleteVoice() }
                }
                .accessibilityIdentifier("settings-voice-delete")
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
                .accessibilityIdentifier("settings-voice-enroll")
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
            let voiceprint = try await services.recordAndEnrollLocalVoice(
                seconds: 12,
                mode: .echoCancelled)
            voiceEnrollmentDate = voiceprint.createdAt
            voiceMessage = L10n.text("Done: your interventions will be tagged as “Me” on any channel.")
        } catch {
            voiceMessage = L10n.format("Could not enroll: %@", UseCaseErrorMessages.describe(error))
        }
    }

    private func deleteVoice() async {
        do {
            try await services.deleteLocalVoiceIdentity()
            voiceEnrollmentDate = nil
            voiceMessage = L10n.text("Voiceprint and key deleted.")
        } catch {
            voiceMessage = L10n.text(
                "Could not delete your voice. Nothing was reported as deleted; try again.")
        }
    }

    // MARK: - Summary engine (D25/M12)

    private var summaryEngineSection: some View {
        Section("Summary engine") {
            if let providerRecommendation {
                VStack(alignment: .leading, spacing: 4) {
                    Label(
                        providerRecommendation.localizedHeadline,
                        systemImage: "wand.and.stars.inverse")
                        .font(.callout.weight(.medium))
                    ForEach(providerRecommendation.localizedReasons, id: \.self) { reason in
                        Text("• \(reason)").font(.caption).foregroundStyle(.secondary)
                    }
                    if providerRecommendation.selection != nil {
                        Button("Apply recommendation") {
                            applyRecommendation(providerRecommendation)
                        }
                            .controlSize(.small)
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("settings-apply-summary-recommendation")
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
                if engine == SummaryEngine.ollama.rawValue {
                    Task { await refreshLocalSummaryProviders() }
                }
            }
            SummaryEngineCapabilityNotice(
                engine: summaryEngine,
                capability: services.foundationModelsCapability)
            if summaryEngine == "ollama" {
                HStack {
                    Button {
                        Task { await refreshLocalSummaryProviders() }
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
            if whisperVariants.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Verifying model integrity…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("settings-whisper-verifying")
            }
            ForEach(whisperVariants) { variant in
                WhisperModelRow(
                    variant: variant,
                    active: variant.compact == whisperCompact,
                    downloadState: services.whisperDownloadState,
                    select: { whisperCompact = variant.compact },
                    download: { services.prepareWhisperVariant(variant.id) },
                    delete: {
                        Task {
                            await services.deleteWhisperVariant(variant.id)
                            whisperVariants = await services.whisperVariants()
                        }
                    })
            }
            Text(
                // One-line UI help text.
                // swiftlint:disable:next line_length
                "Download Whisper here before your first Refine. Preparation continues when Settings closes, and Refine joins the same verified download instead of starting another one. Turbo is the default; Compact saves about 1 GB of disk."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func refreshLocalSummaryProviders(
        showOllamaStatus: Bool = true
    ) async {
        detectingOllama = true
        if showOllamaStatus { ollamaStatus = nil }
        defer { detectingOllama = false }
        let discovery = await services.discoverLocalSummaryProviders()
        providerRecommendation = discovery.recommendation
        ollamaModels = discovery.profile.ollama.models
        if showOllamaStatus {
            ollamaStatus = discovery.localizedOllamaStatus
        }
    }

    private func applyRecommendation(_ recommendation: LocalSummaryProviderRecommendation) {
        guard let selection = recommendation.selection else { return }
        summaryEngine = selection.engine.rawValue
        if let model = selection.ollamaModel {
            ollamaModel = model
        }
        if recommendation.preferCompactWhisper { whisperCompact = true }
    }
}

// MARK: - Companion, BYOK & GitHub

extension SettingsView {
    // MARK: - Companion (D26)

    private var companionSection: some View {
        CompanionSettingsSection(
            capability: services.foundationModelsCapability,
            companionEnabled: companionEnabledBinding,
            companionUserName: $companionUserName,
            mirrorAfterMeeting: $mirrorAfterMeeting)
    }

    private var companionEnabledBinding: Binding<Bool> {
        Binding(
            get: { services.recording.companionEnabled },
            set: { services.recording.companionEnabled = $0 })
    }

    private var byokSection: some View {
        BYOKSettingsSection(
            endpoint: $byokEndpoint,
            model: $byokModel,
            key: $byokKey,
            isEnabled: $companionBYOKEnabled,
            hasStoredKey: $hasStoredBYOKKey,
            message: $byokMessage,
            secrets: services.secrets,
            companionAvailable: services.companionAvailable)
    }

    // MARK: - GitHub

}
