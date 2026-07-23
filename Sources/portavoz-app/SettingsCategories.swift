import ApplicationKit
import Foundation
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
        case .audio: L10n.text("Call-safe capture · dictate anywhere · ⌥⌘D")
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
            "call safe capture echo aec dictation hotkey microphone mic level"
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
    let model: LocalDataLedgerModel

    var body: some View {
        Section {
            // The DS's privacy ledger: three exact local facts plus the
            // explicit network policy. Sync makes a zero-byte claim untrue.
            HStack(spacing: 10) {
                tile(
                    audioText,
                    "audio on your disk",
                    identifier: "settings-ledger-audio")
                tile(
                    meetingText,
                    "meetings in your database",
                    identifier: "settings-ledger-meetings")
                tile(
                    L10n.text("Opt-in"),
                    "network transfers",
                    identifier: "settings-ledger-network-policy",
                    tint: .green)
                tile(
                    voiceText,
                    "voices, encrypted here",
                    identifier: "settings-ledger-voices")
            }
            .padding(.vertical, 4)
            Text(
                // One-line UI help text.
                // swiftlint:disable:next line_length
                "Nothing auto-uploads. Network transfers happen only after an action or opt-in, and Portavoz keeps local receipts."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        } header: {
            Text("Your data, on this Mac")
        }
        .task { await model.load() }
    }

    /// One ledger tile: a big tabular number over a quiet caption.
    private func tile(
        _ value: String,
        _ label: LocalizedStringKey,
        identifier: String,
        tint: Color = .primary
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.title3.weight(.bold).monospacedDigit())
                .foregroundStyle(tint)
                .accessibilityLabel(Text(verbatim: value))
                .accessibilityIdentifier(identifier)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .topLeading)
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    private var snapshot: LocalDataLedgerSnapshot? { model.snapshot }

    private var audioText: String {
        guard let snapshot else { return "…" }
        guard let audioBytes = snapshot.audioBytes else { return L10n.text("Unavailable") }
        return ByteCountFormatter.string(fromByteCount: audioBytes, countStyle: .file)
    }

    private var meetingText: String {
        guard let snapshot else { return "…" }
        guard let meetingCount = snapshot.meetingCount else { return L10n.text("Unavailable") }
        return String(meetingCount)
    }

    private var voiceText: String {
        guard let snapshot else { return "…" }
        guard let voiceCount = snapshot.voiceCount else { return L10n.text("Unavailable") }
        return String(voiceCount)
    }
}
