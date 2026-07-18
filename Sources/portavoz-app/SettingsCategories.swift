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
    case sync
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
        case .sync: L10n.text("Sync")
        case .data: L10n.text("Your data")
        }
    }

    var icon: String {
        switch self {
        case .general: "globe"
        case .audio: "mic"
        case .intelligence: "sparkles"
        case .voice: "person.wave.2"
        case .agenda: "calendar.badge.clock"
        case .integrations: "link"
        case .sync: "icloud"
        case .data: "lock.shield"
        }
    }

    /// The one-line preview under each nav item (design system 2a): the
    /// pane's contents at a glance, so the sidebar tells you where to go.
    var subtitle: String {
        switch self {
        case .general: L10n.text("System language · English/Spanish · menu bar")
        case .audio: L10n.text("Echo cancellation · dictate anywhere · ⌥⌘D")
        case .intelligence: L10n.text("Summary engine · Whisper refine · vocabulary")
        case .voice: L10n.text("Enrolled voice · your name · Companion")
        case .agenda: L10n.text("Reminder · end-of-meeting Shortcut · title template")
        case .integrations: L10n.text("BYOK OpenAI-compatible · GitHub gists · MCP")
        case .sync: L10n.text("iCloud · status · existing library")
        case .data: L10n.text("Export Markdown · recordings folder · trash")
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
        case .sync:
            "icloud cloud sync status existing library encrypted devices pause remove"
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
            // The DS's privacy ledger: four tiles read from the real disk
            // and database — never a promise. The "to the network" tile is
            // a structural fact (nothing auto-uploads), the green receipt.
            HStack(spacing: 10) {
                tile(audioText, "audio on your disk")
                tile(meetingText, "meetings in your database")
                tile("0 B", "to the network", tint: .green)
                tile(voiceText, "voices, encrypted here")
            }
            .padding(.vertical, 4)
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

    /// One ledger tile: a big tabular number over a quiet caption.
    private func tile(_ value: String, _ label: LocalizedStringKey, tint: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.title3.weight(.bold).monospacedDigit())
                .foregroundStyle(tint)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .topLeading)
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
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
