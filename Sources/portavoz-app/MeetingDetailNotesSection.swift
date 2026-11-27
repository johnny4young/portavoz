import ApplicationKit
import IntelligenceKit
import PortavozCore
import SwiftUI

struct MeetingDetailNotesValues {
    let notes: MeetingReviewNotes
    /// Without transcript lines, notes list here instead of beside a line.
    let listsNotes: Bool
    let hasTranscript: Bool
    let isEnhancing: Bool
    let notice: String?
    let alternateEngine: MeetingGeneratedDocumentAlternateEngine?
    let presentation: MeetingDetailPresentation

    var hasContent: Bool {
        !notes.contextItems.isEmpty || notes.enhanced != nil
    }
}

struct MeetingDetailNotesActions {
    let enhance: @MainActor (LanguageCode, SummaryEngine?) -> Void
}

/// User-authored notes in the margin: their optional local enhancement and any
/// note without a transcript line to sit beside.
///
/// Raw notes remain immutable presentation input. The section selects only a
/// requested language/provider; generation and persistence stay above it.
struct MeetingDetailNotesSection: View {
    let values: MeetingDetailNotesValues
    let actions: MeetingDetailNotesActions

    var body: some View {
        Group {
            if values.hasContent {
                VStack(alignment: .leading, spacing: 8) {
                    header
                    content
                    if let notice = values.notice {
                        Text(notice)
                            .font(.caption)
                            .foregroundStyle(.ink3)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("detail-notes-section")
            }
        }
    }

    private var header: some View {
        HStack {
            PVCardCaption(text: L10n.text("My notes"), systemImage: "note.text", tint: PVDesign.ink2)
                .accessibilityIdentifier("detail-notes-title")
            Spacer()
            if values.isEnhancing {
                ProgressView().controlSize(.small)
            } else if values.hasTranscript {
                enhancementMenu
            }
        }
    }

    private var enhancementMenu: some View {
        Menu {
            Button("Tidy up in Spanish") { actions.enhance(.spanish, nil) }
            Button("Tidy up in English") { actions.enhance(.english, nil) }
            if let alternate = values.alternateEngine {
                Divider()
                Menu(alternate.label) {
                    Button("Español") { actions.enhance(.spanish, alternate.engine) }
                    Button("English") { actions.enhance(.english, alternate.engine) }
                }
            }
        } label: {
            Label("Tidy up", systemImage: PVSymbol.generate)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityIdentifier("detail-enhance-notes")
        .help(L10n.text(
            "Expand each note with what the transcript shows around its moment"))
    }

    @ViewBuilder
    private var content: some View {
        if let enhanced = values.notes.enhanced {
            MarkdownText(text: enhanced.markdown)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if values.listsNotes {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(values.notes.contextItems) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(values.presentation.clock(item.timestamp))
                            .font(PVFont.timeCode(.caption))
                            .foregroundStyle(.ink3)
                        Text(item.content)
                            .font(.callout)
                            .textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
