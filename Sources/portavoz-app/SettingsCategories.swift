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
    case agenda
    case skills
    case integrations
    case data

    var id: String { rawValue }

    var title: String { L10n.text(titleKey) }

    var titleKey: String {
        switch self {
        case .general: "General & language"
        case .audio: "Audio & dictation"
        case .intelligence: "Intelligence"
        case .agenda: "Agenda & automation"
        case .skills: "Automations"
        case .integrations: "Integrations"
        case .data: "Your data"
        }
    }

    var icon: String {
        switch self {
        case .general: "globe"
        case .audio: "mic"
        case .intelligence: PVSymbol.intelligence
        case .agenda: "calendar.badge.clock"
        case .skills: PVSymbol.automations
        case .integrations: "link"
        case .data: PVSymbol.privacy
        }
    }

    /// The one-line preview under each nav item (design system 2a): the
    /// pane's contents at a glance, so the sidebar tells you where to go.
    var subtitle: String { L10n.text(subtitleKey) }

    var subtitleKey: String {
        switch self {
        case .general: "System language · English/Spanish · menu bar"
        case .audio: "Call-safe capture · global dictation"
        case .intelligence: "Summary engine · Apuntador · your voice"
        case .agenda: "Reminder · end-of-meeting Shortcut · title template"
        case .skills: "Review · enable · history"
        case .integrations: "BYOK OpenAI-compatible · GitHub gists · MCP"
        case .data: "Privacy · iCloud sync · storage · background activity"
        }
    }

    /// Lowercased match targets for the sidebar search: English words for
    /// what each pane contains; the localized twin lives in the catalog
    /// (each string IS its own key), so Spanish queries land too. Merged
    /// panes keep one group per former pane, each localized on its own.
    var keywordGroups: [String] {
        switch self {
        case .general:
            ["language english spanish menu bar launch login"]
        case .audio:
            ["call safe capture echo aec dictation hotkey microphone mic level"]
        case .intelligence:
            [
                "summary engine apple ollama mlx whisper refine vocabulary",
                "voice enroll apuntador name remembered"
            ]
        case .agenda:
            ["reminder calendar shortcut title template"]
        case .skills:
            ["actions suggestions skills automation automations pause enable history local drafts exports"]
        case .integrations:
            ["byok api key github gist token mcp endpoint openai"]
        case .data:
            [
                "export markdown backup folder recordings trash privacy local",
                "icloud cloud sync status existing library encrypted devices pause remove",
                "background activity recovery processing jobs spotlight semantic index graph retry progress"
            ]
        }
    }

    func matches(_ query: String, language: AppLanguage = .current) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return true }
        return L10n.text(titleKey, language: language).lowercased().contains(query)
            || keywordGroups.contains { group in
                group.contains(query) || L10n.text(group, language: language).lowercased().contains(query)
            }
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
                "Nothing is sent unless you ask for it. Every transfer is logged here."
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
