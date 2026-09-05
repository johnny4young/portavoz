import ApplicationKit
import IntelligenceKit
import PortavozCore
import SwiftUI

struct MeetingDetailNotesValues {
    let notes: MeetingReviewNotes
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

/// User-authored notes and their optional local enhancement.
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
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(14)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("detail-notes-section")
            }
        }
    }

    private var header: some View {
        HStack {
            Text("My notes")
                .font(.headline)
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
            Button("Enhance in Spanish") { actions.enhance(.spanish, nil) }
            Button("Enhance in English") { actions.enhance(.english, nil) }
            if let alternate = values.alternateEngine {
                Divider()
                Menu(alternate.label) {
                    Button("Español") { actions.enhance(.spanish, alternate.engine) }
                    Button("English") { actions.enhance(.english, alternate.engine) }
                }
            }
        } label: {
            Label("Enhance", systemImage: "sparkles")
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
            ScrollView {
                MarkdownText(text: enhanced.markdown)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(values.notes.contextItems) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(values.presentation.clock(item.timestamp))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                            Text(item.content)
                                .font(.callout)
                                .textSelection(.enabled)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 140)
        }
    }
}
