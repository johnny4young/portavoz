import SwiftUI
import TranscriptionKit

struct MeetingDetailRefineReviewActions {
    let discard: @MainActor () -> Void
    let apply: @MainActor (RefineDraft) -> Void
}

struct MeetingDetailRefineReviewValues {
    let draft: RefineDraft
    let presentation: MeetingDetailPresentation
}

/// Read-only comparison for a proposed Refine result.
///
/// The draft remains owned by `RefineService`; this sheet receives one
/// snapshot and explicit confirmation actions, so closing it cannot mutate the
/// accepted transcript accidentally.
struct MeetingDetailRefineReviewSheet: View {
    let values: MeetingDetailRefineReviewValues
    let actions: MeetingDetailRefineReviewActions

    private var draft: RefineDraft { values.draft }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Review the refined transcript", systemImage: "wand.and.stars")
                .font(.title3.weight(.semibold))

            if draft.looksLossy {
                Label(
                    // One-line UI text.
                    // swiftlint:disable:next line_length
                    "The refine covers much less speech than the current transcript — it probably failed. Do not apply it.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.red)
            }

            comparisonGrid
            Text("Sample")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            sample
            HStack {
                Spacer()
                Button("Discard", role: .cancel, action: actions.discard)
                Button("Apply") { actions.apply(draft) }
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.segments.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail-refine-review")
    }

    private var comparisonGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
            GridRow {
                Text("").font(.caption)
                Text("Current").font(.caption.weight(.semibold))
                Text("Refined").font(.caption.weight(.semibold))
            }
            GridRow {
                Text("Segments").foregroundStyle(.secondary)
                Text("\(draft.oldSegmentCount)")
                Text("\(draft.segments.count)")
            }
            GridRow {
                Text("Speakers").foregroundStyle(.secondary)
                Text("\(draft.oldSpeakerCount)")
                Text("\(draft.speakers.count)")
            }
            GridRow {
                Text("Covered speech").foregroundStyle(.secondary)
                Text(values.presentation.refinedDuration(draft.oldSpeechSeconds))
                Text(values.presentation.refinedDuration(draft.newSpeechSeconds))
            }
        }
    }

    private var sample: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(draft.segments.prefix(8)) { segment in
                    Text(segment.text)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxHeight: 180)
        .padding(8)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }
}
