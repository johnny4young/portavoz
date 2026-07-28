import ApplicationKit
import AppKit
import IntegrationsKit
import PortavozCore
import SwiftUI

/// Review-before-share (FEATURE-003/D136): Portavoz drafts the recap, you
/// read and edit it, and YOU choose where it goes. Nothing is sent from
/// here — the actions are the clipboard and the system share sheet.
struct MeetingRecapSheet: View {
    let meeting: Meeting
    let speakers: [Speaker]
    let summary: SummaryDraft
    let dismiss: () -> Void

    @State private var audience: RecapAudience = .everyone
    @State private var channel: RecapChannel = .email
    @State private var subject: String
    @State private var text: String
    /// The last text WE generated. Comparing against it tells a user edit
    /// apart from our own redraft without guessing at event ordering.
    @State private var generatedText: String
    @State private var hasPendingChoices = false

    private var isEdited: Bool { text != generatedText }

    init(
        meeting: Meeting,
        speakers: [Speaker],
        summary: SummaryDraft,
        dismiss: @escaping () -> Void
    ) {
        self.meeting = meeting
        self.speakers = speakers
        self.summary = summary
        self.dismiss = dismiss
        let recap = RecapComposer.compose(
            meeting: meeting, speakers: speakers, summary: summary)
        let drafted = MeetingExporter.render(
            recap.markdown, format: RecapChannel.email.format)
        _subject = State(initialValue: recap.subject)
        _text = State(initialValue: drafted)
        _generatedText = State(initialValue: drafted)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            choices
            if hasPendingChoices { redraftNotice }
            if channel == .email { subjectField }
            editor
            footer
        }
        .padding(20)
        .frame(width: 560, height: 620)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Share a recap")
                .font(.headline)
                .accessibilityIdentifier("recap-title")
            Text("Read it, edit anything, then choose where it goes.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var choices: some View {
        HStack(spacing: 12) {
            Picker("For", selection: $audience) {
                Text("Everyone").tag(RecapAudience.everyone)
                ForEach(speakers) { speaker in
                    Text(speaker.displayName ?? speaker.label)
                        .tag(RecapAudience.participant(speaker.id))
                }
            }
            .accessibilityIdentifier("recap-audience")
            .onChange(of: audience) { redraft() }
            Picker("As", selection: $channel) {
                ForEach(RecapChannel.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .accessibilityIdentifier("recap-channel")
            .onChange(of: channel) { redraft() }
        }
    }

    private var redraftNotice: some View {
        HStack(spacing: 8) {
            Text("Your edits are kept — the new choices are not applied yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Redraft") { redraft(force: true) }
                .controlSize(.small)
                .accessibilityIdentifier("recap-redraft")
            Spacer()
        }
    }

    private var subjectField: some View {
        TextField("Subject", text: $subject)
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("recap-subject")
    }

    private var editor: some View {
        TextEditor(text: $text)
            .font(.body)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(
                RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            .accessibilityIdentifier("recap-body")
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("Portavoz sends nothing. The transcript is never included.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("recap-privacy-note")
            Spacer()
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            .accessibilityIdentifier("recap-copy")
            ShareLink(item: text, subject: Text(subject)) {
                Label("Share…", systemImage: "square.and.arrow.up")
            }
            .accessibilityIdentifier("recap-share")
            Button("Done", action: dismiss)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("recap-done")
        }
    }

    /// Recomposes for the current audience and channel. An untouched draft
    /// refreshes silently; an edited one is never overwritten without the
    /// user asking for it.
    private func redraft(force: Bool = false) {
        guard force || !isEdited else {
            hasPendingChoices = true
            return
        }
        let recap = RecapComposer.compose(
            meeting: meeting,
            speakers: speakers,
            summary: summary,
            audience: audience)
        subject = recap.subject
        generatedText = MeetingExporter.render(recap.markdown, format: channel.format)
        text = generatedText
        hasPendingChoices = false
    }
}

/// Where the recap is headed. Only the shaping differs — the content is the
/// same reviewed draft.
enum RecapChannel: String, CaseIterable, Identifiable {
    case email
    case slack
    case markdown

    var id: String { rawValue }

    var format: MeetingExporter.SummaryFormat {
        switch self {
        case .email: .plainText
        case .slack: .slack
        case .markdown: .markdown
        }
    }

    var title: String {
        switch self {
        case .email: L10n.text("Email")
        case .slack: L10n.text("Slack")
        case .markdown: L10n.text("Markdown")
        }
    }
}
