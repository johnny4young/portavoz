import PortavozCore
import SwiftUI

/// Exact temporal-baseline selector for ChangeSince. Titles are discovery
/// hints only; the selected MeetingID is the sole query authority.
struct AskMeetingAnchorView: View {
    let topicModel: AskTopicMemoryModel

    private var model: AskMeetingAnchorModel { topicModel.meetingAnchors }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Since meeting")
                .font(.subheadline.weight(.semibold))
                .accessibilityIdentifier("ask-topic-anchor-title")
            if let selected = model.state.selectedMeeting {
                selectedMeeting(selected)
            } else {
                meetingSearch
                meetingResults
            }
        }
        .padding(.top, 2)
    }

    private var meetingSearch: some View {
        TextField(
            "Find a meeting…",
            text: Binding(
                get: { model.state.query },
                set: { topicModel.updateMeetingAnchorQuery($0) }))
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("ask-topic-anchor-search")
    }

    @ViewBuilder
    private var meetingResults: some View {
        switch model.state.phase {
        case .idle:
            EmptyView()
        case .loading:
            statusRow("Searching meetings…", showsProgress: true)
        case .empty:
            statusRow(
                "No meetings match this search.",
                systemImage: "questionmark.folder")
        case .unavailable:
            VStack(alignment: .leading, spacing: 8) {
                statusRow(
                    "Could not search meetings.",
                    systemImage: "exclamationmark.triangle")
                Button("Try again") { topicModel.retryMeetingAnchorSearch() }
                    .accessibilityIdentifier("ask-topic-anchor-retry")
            }
        case .ready:
            VStack(alignment: .leading, spacing: 8) {
                ForEach(
                    Array(model.state.meetings.enumerated()),
                    id: \.element.id
                ) { index, meeting in
                    meetingButton(meeting, position: index + 1)
                }
                if model.state.hasMore {
                    Label(
                        "More meetings match. Refine the title to choose the right one.",
                        systemImage: "magnifyingglass")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("ask-topic-anchor-overflow")
                }
            }
        }
    }

    private func meetingButton(
        _ meeting: AskMemoryMeetingAnchor,
        position: Int
    ) -> some View {
        Button {
            topicModel.selectMeetingAnchor(meeting.id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "calendar")
                VStack(alignment: .leading, spacing: 2) {
                    Text(meeting.title)
                    Text(boundaryText(meeting))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
        .accessibilityLabel(Text(selectionLabel(
            meeting,
            position: position)))
        .accessibilityIdentifier(
            "ask-topic-anchor-option-\(meeting.id.rawValue.uuidString)")
    }

    private func selectedMeeting(
        _ meeting: AskMemoryMeetingAnchor
    ) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Label(meeting.title, systemImage: "calendar.circle.fill")
                    .font(.headline)
                    .accessibilityIdentifier("ask-topic-anchor-selected")
                Text(boundaryText(meeting))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Change") { topicModel.clearMeetingAnchorSelection() }
                .accessibilityLabel(Text(L10n.format(
                    "Change meeting anchor from %@",
                    meeting.title)))
                .accessibilityIdentifier("ask-topic-anchor-change")
        }
    }

    private func boundaryText(_ meeting: AskMemoryMeetingAnchor) -> String {
        let formatted = meeting.boundaryAt.formatted(
            date: .abbreviated,
            time: .shortened)
        return meeting.usesEndBoundary
            ? L10n.format("Ended %@", formatted)
            : L10n.format("Started %@", formatted)
    }

    private func selectionLabel(
        _ meeting: AskMemoryMeetingAnchor,
        position: Int
    ) -> String {
        meeting.usesEndBoundary
            ? L10n.format(
                "Select meeting %lld: %@, ended %@",
                position,
                meeting.title,
                meeting.boundaryAt.formatted(
                    date: .abbreviated,
                    time: .shortened))
            : L10n.format(
                "Select meeting %lld: %@, started %@",
                position,
                meeting.title,
                meeting.boundaryAt.formatted(
                    date: .abbreviated,
                    time: .shortened))
    }

    private func statusRow(
        _ message: String,
        systemImage: String? = nil,
        showsProgress: Bool = false
    ) -> some View {
        HStack(spacing: 8) {
            if showsProgress {
                ProgressView().controlSize(.small)
            } else if let systemImage {
                Image(systemName: systemImage)
            }
            Text(L10n.text(message))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("ask-topic-anchor-status")
    }
}
