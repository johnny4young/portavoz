import PortavozCore
import SwiftUI

/// Global, confirmed-only continuity. Generated candidates stay in Meeting
/// Detail until the user explicitly promotes them to commitment truth.
struct CommitmentRadarView: View {
    let model: CommitmentRadarModel
    let onOpenMeeting: (MeetingID) -> Void

    @State private var expandedItems: Set<CommitmentID> = []

    private var state: CommitmentRadarModel.State { model.state }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                filters
                content
            }
            .padding(24)
            .frame(maxWidth: 980, alignment: .leading)
        }
        .accessibilityIdentifier("commitment-radar")
        .task { await model.send(.load) }
    }
}

private extension CommitmentRadarView {
    var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Commitment Radar")
                    .font(.largeTitle.bold())
                    .accessibilityIdentifier("commitment-radar-title")
                Text("Confirmed work, with its source and history.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Label("Local and confirmed by you", systemImage: "checkmark.shield.fill")
                .font(.caption)
                .foregroundStyle(.green)
        }
    }

    var filters: some View {
        HStack(spacing: 12) {
            ownerMenu
            dueMenu
            activityMenu
            groupingMenu
        }
        .padding(14)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
    }

    var ownerMenu: some View {
        filterMenu(
            title: "Owner",
            value: ownerSelectionTitle,
            identifier: "commitment-radar-owner-filter"
        ) {
            filterButton("All", identifier: "commitment-radar-owner-all") {
                ownerBinding.wrappedValue = .all
            }
            filterButton("Mine", identifier: "commitment-radar-owner-mine") {
                ownerBinding.wrappedValue = .mine
            }
            filterButton("Others", identifier: "commitment-radar-owner-others") {
                ownerBinding.wrappedValue = .others
            }
            filterButton("Unassigned", identifier: "commitment-radar-owner-unassigned") {
                ownerBinding.wrappedValue = .unassigned
            }
        }
    }

    var dueMenu: some View {
        filterMenu(
            title: "Due date",
            value: dueSelectionTitle,
            identifier: "commitment-radar-due-filter"
        ) {
            filterButton("Any date", identifier: "commitment-radar-due-all") {
                dueBinding.wrappedValue = .all
            }
            filterButton("Due soon", identifier: "commitment-radar-due-soon") {
                dueBinding.wrappedValue = .dueSoon
            }
            filterButton("Overdue", identifier: "commitment-radar-due-overdue") {
                dueBinding.wrappedValue = .overdue
            }
            filterButton("No date", identifier: "commitment-radar-due-none") {
                dueBinding.wrappedValue = .noDate
            }
        }
    }

    var activityMenu: some View {
        filterMenu(
            title: "Activity",
            value: activitySelectionTitle,
            identifier: "commitment-radar-activity-filter"
        ) {
            filterButton("Any activity", identifier: "commitment-radar-activity-all") {
                activityBinding.wrappedValue = .all
            }
            filterButton("New", identifier: "commitment-radar-activity-new") {
                activityBinding.wrappedValue = .new
            }
            filterButton("Unchanged", identifier: "commitment-radar-activity-unchanged") {
                activityBinding.wrappedValue = .unchanged
            }
            filterButton("Completed", identifier: "commitment-radar-activity-completed") {
                activityBinding.wrappedValue = .completed
            }
            filterButton("Reopened", identifier: "commitment-radar-activity-reopened") {
                activityBinding.wrappedValue = .reopened
            }
        }
    }

    var groupingMenu: some View {
        filterMenu(
            title: "Group by",
            value: groupingTitle,
            identifier: "commitment-radar-grouping"
        ) {
            filterButton("Owner", identifier: "commitment-radar-group-owner") {
                groupingBinding.wrappedValue = .owner
            }
            filterButton("Source meeting", identifier: "commitment-radar-group-meeting") {
                groupingBinding.wrappedValue = .meeting
            }
        }
    }

    func filterMenu<Content: View>(
        title: LocalizedStringKey,
        value: String,
        identifier: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Menu(content: content) {
                Text(value)
                    .lineLimit(1)
                    .frame(minWidth: 88, alignment: .leading)
            }
            .accessibilityIdentifier(identifier)
        }
    }

    func filterButton(
        _ title: LocalizedStringKey,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(title, action: action)
            .accessibilityIdentifier(identifier)
    }

    @ViewBuilder var content: some View {
        switch state.phase {
        case .idle, .loading:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Loading confirmed commitments…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 180)
        case .failed:
            ContentUnavailableView {
                Label("Couldn’t load commitments", systemImage: "exclamationmark.triangle")
            } description: {
                Text("Your confirmed commitments are still safe on this Mac.")
            } actions: {
                Button("Try again") {
                    Task { await model.send(.load) }
                }
                .accessibilityIdentifier("commitment-radar-retry")
            }
        case .empty:
            ContentUnavailableView {
                Label("No confirmed commitments", systemImage: "scope")
            } description: {
                Text(emptyDescription)
            }
            .accessibilityIdentifier("commitment-radar-empty")
        case .loaded:
            if let page = state.page {
                radarPage(page)
            }
        }
    }

    func radarPage(_ page: CommitmentRadarPage) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L10n.format(
                    "Showing %d of %d commitments",
                    page.items.count,
                    page.totalCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if page.hasMore {
                    Text("Refine the filters to see more.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(groups(for: page.items)) { group in
                VStack(alignment: .leading, spacing: 10) {
                    Text(verbatim: group.title)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    ForEach(group.items) { item in
                        itemCard(item)
                    }
                }
            }
        }
    }

    func itemCard(_ item: CommitmentRadarItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(verbatim: item.commitment.title)
                    .font(.title3.weight(.semibold))
                Spacer()
                activityBadge(item.activity)
            }

            HStack(spacing: 14) {
                Label(ownerName(item), systemImage: "person.crop.circle")
                Label(dueLabel(item.commitment.dueAt), systemImage: "calendar")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                firstSourceLink(item)
                Spacer()
                Text(L10n.format("%d sources", item.sourceCount))
                Text("·")
                Text(L10n.format("%d changes", item.historyCount))
            }
            .font(.caption)

            DisclosureGroup(
                isExpanded: expansionBinding(item.id)
            ) {
                commitmentDetails(item)
                    .padding(.top, 8)
            } label: {
                Text("Review sources and history")
                    .font(.caption.weight(.medium))
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            "commitment-radar-item-\(item.id.rawValue.uuidString)")
    }

    @ViewBuilder func firstSourceLink(_ item: CommitmentRadarItem) -> some View {
        if let source = item.sources.first,
           let meetingID = source.meetingID,
           source.isMeetingAvailable {
            Button {
                onOpenMeeting(meetingID)
            } label: {
                Label(
                    source.meetingTitle ?? L10n.text("Source meeting"),
                    systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.link)
            .accessibilityIdentifier(
                "commitment-radar-source-\(source.id.rawValue.uuidString)")
        } else {
            Label("Source unavailable", systemImage: "exclamationmark.circle")
                .foregroundStyle(.secondary)
        }
    }

    func commitmentDetails(_ item: CommitmentRadarItem) -> some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Sources", systemImage: "doc.text.magnifyingglass")
                    .font(.subheadline.bold())
                ForEach(item.sources) { source in
                    sourceRow(source)
                }
                if item.hasMoreSources {
                    Text(L10n.format(
                        "%d more sources not shown",
                        item.sourceCount - item.sources.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 8) {
                Label("History", systemImage: "clock.arrow.circlepath")
                    .font(.subheadline.bold())
                ForEach(item.history) { event in
                    historyRow(event)
                }
                if item.hasMoreHistory {
                    Text(L10n.format(
                        "%d earlier changes not shown",
                        item.historyCount - item.history.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    func sourceRow(_ source: CommitmentRadarSource) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let meetingID = source.meetingID, source.isMeetingAvailable {
                Button(source.meetingTitle ?? L10n.text("Source meeting")) {
                    onOpenMeeting(meetingID)
                }
                .buttonStyle(.link)
            } else {
                Text("Source unavailable")
            }
            Text(L10n.format("First seen %@", shortDate(source.firstSeenAt)))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    func historyRow(_ event: CommitmentRadarHistoryEvent) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(historyLabel(event.kind))
                .font(.caption.weight(.medium))
            HStack(spacing: 5) {
                Text(verbatim: shortDate(event.occurredAt))
                if let meetingID = event.sourceMeetingID,
                   event.isSourceMeetingAvailable {
                    Text("·")
                    Button(event.sourceMeetingTitle ?? L10n.text("Source meeting")) {
                        onOpenMeeting(meetingID)
                    }
                    .buttonStyle(.link)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    func activityBadge(_ activity: CommitmentRadarActivity) -> some View {
        Text(activityLabel(activity))
            .font(.caption.weight(.semibold))
            .foregroundStyle(activityColor(activity))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                activityColor(activity).opacity(0.12),
                in: Capsule())
    }
}

private extension CommitmentRadarView {
    var ownerSelectionTitle: String {
        switch state.owner {
        case .all: L10n.text("All")
        case .mine: L10n.text("Mine")
        case .others: L10n.text("Others")
        case .unassigned: L10n.text("Unassigned")
        }
    }

    var dueSelectionTitle: String {
        switch state.due {
        case .all: L10n.text("Any date")
        case .dueSoon: L10n.text("Due soon")
        case .overdue: L10n.text("Overdue")
        case .noDate: L10n.text("No date")
        }
    }

    var activitySelectionTitle: String {
        switch state.activity {
        case .all: L10n.text("Any activity")
        case .new: L10n.text("New")
        case .unchanged: L10n.text("Unchanged")
        case .completed: L10n.text("Completed")
        case .reopened: L10n.text("Reopened")
        }
    }

    var groupingTitle: String {
        switch state.grouping {
        case .owner: L10n.text("Owner")
        case .meeting: L10n.text("Source meeting")
        }
    }

    var ownerBinding: Binding<CommitmentRadarModel.OwnerSelection> {
        Binding(
            get: { state.owner },
            set: { owner in Task { await model.send(.ownerChanged(owner)) } })
    }

    var dueBinding: Binding<CommitmentRadarModel.DueSelection> {
        Binding(
            get: { state.due },
            set: { due in Task { await model.send(.dueChanged(due)) } })
    }

    var activityBinding: Binding<CommitmentRadarModel.ActivitySelection> {
        Binding(
            get: { state.activity },
            set: { activity in Task { await model.send(.activityChanged(activity)) } })
    }

    var groupingBinding: Binding<CommitmentRadarModel.Grouping> {
        Binding(
            get: { state.grouping },
            set: { grouping in Task { await model.send(.groupingChanged(grouping)) } })
    }

    var emptyDescription: String {
        let hasFilter = state.owner != .all
            || state.due != .all
            || state.activity != .all
        return hasFilter
            ? L10n.text("No commitments match these filters.")
            : L10n.text("Confirm an action item in Meeting Detail to track it here.")
    }

    func expansionBinding(_ id: CommitmentID) -> Binding<Bool> {
        Binding(
            get: { expandedItems.contains(id) },
            set: { expanded in
                if expanded {
                    expandedItems.insert(id)
                } else {
                    expandedItems.remove(id)
                }
            })
    }

    func groups(
        for items: [CommitmentRadarItem]
    ) -> [CommitmentRadarGroup] {
        var groups: [CommitmentRadarGroup] = []
        var indexes: [String: Int] = [:]
        for item in items {
            let identity = groupIdentity(item)
            if let index = indexes[identity.key] {
                groups[index].items.append(item)
            } else {
                indexes[identity.key] = groups.count
                groups.append(CommitmentRadarGroup(
                    id: identity.key,
                    title: identity.title,
                    items: [item]))
            }
        }
        return groups
    }

    func groupIdentity(
        _ item: CommitmentRadarItem
    ) -> (key: String, title: String) {
        switch state.grouping {
        case .owner:
            switch item.commitment.assignee {
            case .me:
                ("owner-me", L10n.text("Me"))
            case .unassigned:
                ("owner-unassigned", L10n.text("Unassigned"))
            case .person(let id):
                ("owner-\(id.rawValue.uuidString)", ownerName(item))
            }
        case .meeting:
            if let source = item.sources.first,
               let meetingID = source.meetingID {
                (
                    "meeting-\(meetingID.rawValue.uuidString)",
                    source.meetingTitle ?? L10n.text("Source meeting")
                )
            } else {
                ("meeting-unavailable", L10n.text("Source unavailable"))
            }
        }
    }

    func ownerName(_ item: CommitmentRadarItem) -> String {
        switch item.commitment.assignee {
        case .me:
            L10n.text("Me")
        case .unassigned:
            L10n.text("Unassigned")
        case .person:
            item.assigneeDisplayName ?? L10n.text("Unknown person")
        }
    }

    func dueLabel(_ date: Date?) -> String {
        guard let date else { return L10n.text("No due date") }
        return L10n.format("Due %@", shortDate(date))
    }

    func shortDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }

    func activityLabel(_ activity: CommitmentRadarActivity) -> String {
        switch activity {
        case .new: L10n.text("New")
        case .unchanged: L10n.text("Unchanged")
        case .completed: L10n.text("Completed")
        case .reopened: L10n.text("Reopened")
        }
    }

    func historyLabel(_ kind: CommitmentEventKind) -> String {
        switch kind {
        case .confirm: L10n.text("Confirmed")
        case .reassign: L10n.text("Reassigned")
        case .reschedule: L10n.text("Rescheduled")
        case .complete: L10n.text("Completed")
        case .reopen: L10n.text("Reopened")
        case .dismiss: L10n.text("Dismissed")
        }
    }

    func activityColor(_ activity: CommitmentRadarActivity) -> Color {
        switch activity {
        case .new: PVDesign.accent
        case .unchanged: .secondary
        case .completed: .green
        case .reopened: PVDesign.brandAmber
        }
    }
}

private struct CommitmentRadarGroup: Identifiable {
    let id: String
    let title: String
    var items: [CommitmentRadarItem]
}
