import AudioCaptureKit
import DiarizationKit
import PortavozCore
import StorageKit
import SwiftUI

/// The Settings categories (design system 2a: "from an endless scroll to
/// navigation"). Each case knows its label, icon and the search words
/// that should land on it — the search field filters this list, nothing
/// fancier.
enum SettingsCategory: String, CaseIterable, Identifiable {
    case general
    case audio
    case intelligence
    case voice
    case agenda
    case integrations
    case data

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: L10n.text("General & language")
        case .audio: L10n.text("Audio & dictation")
        case .intelligence: L10n.text("Intelligence")
        case .voice: L10n.text("My voice & Companion")
        case .agenda: L10n.text("Agenda & automation")
        case .integrations: L10n.text("Integrations")
        case .data: L10n.text("Your data")
        }
    }

    var icon: String {
        switch self {
        case .general: "globe"
        case .audio: "mic"
        case .intelligence: "sparkles"
        case .voice: "person.wave.2"
        case .agenda: "calendar"
        case .integrations: "link"
        case .data: "lock"
        }
    }

    /// Lowercased match targets for the sidebar search: English words for
    /// what each pane contains; the localized twin lives in the catalog
    /// (the string IS its own key), so Spanish queries land too.
    private var keywords: String {
        switch self {
        case .general:
            "language english spanish menu bar launch login"
        case .audio:
            "echo aec dictation hotkey microphone mic level"
        case .intelligence:
            "summary engine apple ollama mlx whisper refine vocabulary"
        case .voice:
            "voice enroll companion name remembered"
        case .agenda:
            "reminder calendar shortcut title template"
        case .integrations:
            "byok api key github gist token mcp endpoint openai"
        case .data:
            "export markdown backup folder recordings trash privacy local"
        }
    }

    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return true }
        return title.lowercased().contains(query)
            || keywords.contains(query)
            || L10n.text(keywords).contains(query)
    }
}

/// The privacy ledger (design system 2a: "your history is never hostage"
/// made interface): what exists, where it lives, in numbers read from the
/// real disk and database — never a promise.
struct LedgerSection: View {
    @Environment(AppServices.self) private var services
    @State private var audioBytes: Int64?
    @State private var meetingCount: Int?
    @State private var rememberedVoices = 0
    @State private var voiceEnrolled = false

    var body: some View {
        Section {
            LabeledContent("Audio on your disk", value: audioText)
            LabeledContent("Meetings in your database", value: meetingText)
            LabeledContent(
                "Voices remembered — encrypted on this Mac",
                value: voiceText)
            Text(
                // One-line UI help text.
                // swiftlint:disable:next line_length
                "Nothing leaves this Mac except what you send yourself: gists you export, questions you ask an external model, and the update check."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        } header: {
            Text("Your data, on this Mac")
        }
        .task { await load() }
    }

    private var audioText: String {
        guard let audioBytes else { return "…" }
        return ByteCountFormatter.string(fromByteCount: audioBytes, countStyle: .file)
    }

    private var meetingText: String {
        guard let meetingCount else { return "…" }
        return String(meetingCount)
    }

    private var voiceText: String {
        String(rememberedVoices + (voiceEnrolled ? 1 : 0))
    }

    private func load() async {
        meetingCount = (try? await services.store.meetings().count) ?? 0
        if !ProcessInfo.processInfo.arguments.contains("-use-temp-store") {
            rememberedVoices = (try? VoiceGallery().voices().count) ?? 0
            voiceEnrolled = (try? VoiceprintStore().load()) != nil
        }
        let root = RecordingsLocation.shared.currentRoot()
        audioBytes = await Task.detached(priority: .utility) {
            directorySize(of: root)
        }.value
    }
}

/// Total on-disk size of a directory tree; the ledger's "audio on your
/// disk" number comes from the real file system, not bookkeeping.
private func directorySize(of root: URL) -> Int64 {
    let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
    guard
        let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: Array(keys))
    else { return 0 }
    var total: Int64 = 0
    for case let url as URL in enumerator {
        guard let values = try? url.resourceValues(forKeys: keys),
            values.isRegularFile == true
        else { continue }
        total += Int64(values.totalFileAllocatedSize ?? 0)
    }
    return total
}
