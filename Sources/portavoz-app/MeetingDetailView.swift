import PortavozCore
import StorageKit
import SwiftUI

/// Transcript with editable speaker pills (the M3 leftover), the latest
/// summary snapshot, and its checkable action items.
struct MeetingDetailView: View {
    @Environment(AppServices.self) private var services
    let meetingID: MeetingID
    @Binding var route: Route?

    @State private var detail: MeetingDetail?
    @State private var summary: (draft: SummaryDraft, version: Int)?
    @State private var renamingSpeaker: Speaker?
    @State private var newName = ""

    var body: some View {
        Group {
            if let detail {
                loaded(detail)
            } else {
                ProgressView()
            }
        }
        .task(id: services.libraryVersion) { await reload() }
    }

    @ViewBuilder
    private func loaded(_ detail: MeetingDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(detail)

                if let summary {
                    summarySection(summary)
                }

                Text("Transcript")
                    .font(.headline)
                ForEach(detail.segments) { segment in
                    segmentRow(segment, speakers: detail.speakers)
                }
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .navigationTitle(detail.meeting.title)
        .toolbar {
            Button(role: .destructive) {
                Task {
                    try? await services.store.delete(meetingID)
                    services.libraryVersion += 1
                    route = nil
                }
            } label: {
                Label("Eliminar", systemImage: "trash")
            }
        }
        .alert("Renombrar hablante", isPresented: renameBinding) {
            TextField("Nombre", text: $newName)
            Button("Guardar") { Task { await rename() } }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Etiqueta actual: \(renamingSpeaker?.label ?? "")")
        }
    }

    private func header(_ detail: MeetingDetail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(detail.meeting.title).font(.title2.bold())
            HStack(spacing: 12) {
                Text(detail.meeting.startedAt.formatted(date: .long, time: .shortened))
                if let ended = detail.meeting.endedAt {
                    let minutes = Int(ended.timeIntervalSince(detail.meeting.startedAt) / 60)
                    Text("\(minutes) min")
                }
                Text("\(detail.segments.count) segmentos")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private func summarySection(_ summary: (draft: SummaryDraft, version: Int)) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Resumen")
                    .font(.headline)
                Text("v\(summary.version) · \(summary.draft.language)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            MarkdownLite(text: summary.draft.markdown)
            ForEach(summary.draft.actionItems) { item in
                Toggle(isOn: actionBinding(item)) {
                    Text(item.text)
                        .strikethrough(item.isDone)
                }
                .toggleStyle(.checkbox)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private func segmentRow(_ segment: TranscriptSegment, speakers: [Speaker]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(timestamp(segment.startTime))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 44, alignment: .trailing)
            SpeakerPill(
                speaker: speakers.first { $0.id == segment.speakerID }
            ) { speaker in
                renamingSpeaker = speaker
                newName = speaker.displayName ?? ""
            }
            Text(segment.text)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Actions

    private var renameBinding: Binding<Bool> {
        Binding(
            get: { renamingSpeaker != nil },
            set: { if !$0 { renamingSpeaker = nil } }
        )
    }

    private func rename() async {
        guard var speaker = renamingSpeaker else { return }
        speaker.displayName = newName.isEmpty ? nil : newName
        try? await services.store.save([speaker])
        renamingSpeaker = nil
        services.libraryVersion += 1
    }

    private func actionBinding(_ item: ActionItem) -> Binding<Bool> {
        Binding(
            get: { item.isDone },
            set: { done in
                Task {
                    try? await services.store.setActionItem(item.id, done: done)
                    services.libraryVersion += 1
                }
            }
        )
    }

    private func reload() async {
        detail = try? await services.store.detail(meetingID)
        summary = try? await services.store.summary(meetingID)
    }

    private func timestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// One speaker chip; "Me" gets the accent color. Click to rename — the
/// M3 "editable speaker pills" acceptance piece.
struct SpeakerPill: View {
    let speaker: Speaker?
    let onRename: (Speaker) -> Void

    var body: some View {
        Button {
            if let speaker { onRename(speaker) }
        } label: {
            Text(speaker.map { $0.displayName ?? $0.label } ?? "?")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(
                    (speaker?.isMe == true ? Color.accentColor : Color.secondary).opacity(0.18),
                    in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(speaker == nil)
    }
}

/// Just enough markdown for our own summaries: `##` headings and `-`
/// bullets. The real renderer arrives with the polish pass.
struct MarkdownLite: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()),
                    id: \.offset) { _, line in
                if line.hasPrefix("## ") {
                    Text(line.dropFirst(3)).font(.subheadline.bold()).padding(.top, 6)
                } else if line.hasPrefix("- ") {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•")
                        Text(line.dropFirst(2))
                    }
                } else if !line.isEmpty {
                    Text(line)
                }
            }
        }
        .textSelection(.enabled)
    }
}
