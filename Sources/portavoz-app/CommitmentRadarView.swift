import PortavozCore
import SwiftUI

/// One global review destination with two explicitly separated truth stages.
/// Generated candidates never inherit confirmed Radar semantics.
struct CommitmentRadarView: View {
    let model: CommitmentRadarModel
    let reminders: CommitmentReminderModel
    let reminderDrafts: ReminderDraftModel
    let focus: CommitmentRadarRouteFocus?
    let onClearFocus: () -> Void
    let onOpenMeeting: (MeetingID, TimeInterval?) -> Void

    @State private var expandedItems: Set<CommitmentID> = []
    @State private var appliedInitialRouteFocus = false
    @State private var rescheduleItem: CommitmentRadarItem?

    private var state: CommitmentRadarModel.State { model.state }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                modePicker
                if state.mode == .confirmed {
                    appEntityFocusBanner
                    CommitmentReminderStatusCard(model: reminders)
                    filters
                    confirmedContent
                } else if state.mode == .review {
                    CommitmentReviewQueueView(
                        model: model,
                        onOpenMeeting: onOpenMeeting)
                } else {
                    CommitmentFieldQualityView(model: model)
                }
            }
            .padding(24)
            .frame(maxWidth: 980, alignment: .leading)
        }
        .accessibilityIdentifier("commitment-radar")
        .task(id: focus) {
            // The route-owned model outlives this conditional view. Refresh an
            // unchanged focus when Radar is mounted again, but do not start a
            // duplicate read when a same-view clear/filter action already
            // applied the new focus before updating the parent route.
            let refreshesRemountedRoute = !appliedInitialRouteFocus
                && model.state.phase != .idle
                && model.state.routeFocus == focus
            appliedInitialRouteFocus = true
            if refreshesRemountedRoute {
                await model.send(.load)
            } else {
                await model.send(.routeFocusChanged(focus))
            }
        }
        .task(id: reminderDraftLoadIdentity) {
            await reminderDrafts.load(commitments: reminderDraftCommitments)
        }
        .sheet(item: $rescheduleItem) { item in
            CommitmentRadarDueDateSheet(
                item: item,
                cancel: { rescheduleItem = nil },
                save: { dueAt in
                    await model.send(.reschedule(item.id, dueAt))
                    rescheduleItem = nil
                })
        }
        .alert(
            "Couldn’t complete",
            isPresented: mutationFailureBinding
        ) {
            Button("OK") {
                Task { await model.send(.dismissMutationFailure) }
            }
            .accessibilityIdentifier("commitment-radar-mutation-error-dismiss")
        }
        .alert(
            "Couldn’t update review",
            isPresented: reviewMutationFailureBinding
        ) {
            Button("OK") {
                Task { await model.send(.dismissReviewMutationFailure) }
            }
            .accessibilityIdentifier("commitment-review-mutation-error-dismiss")
        } message: {
            Text("The suggestion is still safe on this Mac. Try again.")
        }
        .alert(
            "Couldn’t update reminder suggestion",
            isPresented: reminderDraftFailureBinding
        ) {
            Button("OK") { reminderDrafts.clearSurfaceFailure() }
                .accessibilityIdentifier(
                    "commitment-radar-reminder-dismiss-error")
        } message: {
            Text(reminderDrafts.state.surfaceFailure ?? "")
        }
        .sheet(isPresented: reminderDraftSheetBinding) {
            ReminderDraftSheet(model: reminderDrafts)
        }
    }
}

private extension CommitmentRadarView {
    @ViewBuilder
    var appEntityFocusBanner: some View {
        if state.routeFocus != nil {
            CommitmentRadarAppEntityFocusBanner(
                focus: state.routeFocus,
                page: state.page,
                clear: {
                    Task {
                        await model.send(.clearRouteFocus)
                        onClearFocus()
                    }
                })
        }
    }

    var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Commitment Radar")
                    .font(.largeTitle.bold())
                    .accessibilityIdentifier("commitment-radar-title")
                Text(headerDescription)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Label(headerBadge, systemImage: headerBadgeIcon)
                .font(.caption)
                .foregroundStyle(state.mode == .confirmed ? .green : PVDesign.accent)
        }
    }

    var modePicker: some View {
        Picker("Commitment view", selection: modeBinding) {
            Text("Confirmed")
                .tag(CommitmentRadarModel.Mode.confirmed)
                .accessibilityIdentifier("commitment-radar-mode-confirmed")
            Text("To review")
                .tag(CommitmentRadarModel.Mode.review)
                .accessibilityIdentifier("commitment-radar-mode-review")
            Text("Quality")
                .tag(CommitmentRadarModel.Mode.quality)
                .accessibilityIdentifier("commitment-radar-mode-quality")
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 480)
        .accessibilityIdentifier("commitment-radar-mode")
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

    @ViewBuilder var confirmedContent: some View {
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
                Label(
                    dueLabel(item.commitment.dueAt),
                    systemImage: "calendar")
                    .accessibilityIdentifier(
                        "commitment-radar-due-value-\(item.id.rawValue.uuidString)-"
                            + (item.commitment.dueAt == nil ? "none" : "scheduled"))
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

            radarActions(item)

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

    @ViewBuilder func radarActions(_ item: CommitmentRadarItem) -> some View {
        HStack(spacing: 8) {
            Spacer()
            reminderDraftAction(item)
            switch item.commitment.status {
            case .confirmed:
                Button("Due date") {
                    rescheduleItem = item
                }
                .accessibilityIdentifier(
                    "commitment-radar-due-\(item.id.rawValue.uuidString)")
                Button("Done") {
                    Task { await model.send(.complete(item.id)) }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier(
                    "commitment-radar-complete-\(item.id.rawValue.uuidString)")
            case .done:
                Button("Restore") {
                    Task { await model.send(.reopen(item.id)) }
                }
                .accessibilityIdentifier(
                    "commitment-radar-reopen-\(item.id.rawValue.uuidString)")
            case .dismissed:
                EmptyView()
            }
        }
        .disabled(state.mutatingCommitmentID != nil)
    }

    @ViewBuilder func firstSourceLink(_ item: CommitmentRadarItem) -> some View {
        if let source = item.sources.first,
           let meetingID = source.meetingID,
           source.isMeetingAvailable {
            Button {
                onOpenMeeting(meetingID, nil)
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
                    onOpenMeeting(meetingID, nil)
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
                        onOpenMeeting(meetingID, nil)
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
    var headerDescription: LocalizedStringKey {
        switch state.mode {
        case .confirmed:
            "Confirmed work, with its source and history."
        case .review:
            "Generated suggestions waiting for your decision."
        case .quality:
            "Private signals from the suggestions you reviewed."
        }
    }

    var headerBadge: LocalizedStringKey {
        switch state.mode {
        case .confirmed:
            "Local and confirmed by you"
        case .review:
            "Suggestions, not commitments"
        case .quality:
            "Local and advisory only"
        }
    }

    var headerBadgeIcon: String {
        switch state.mode {
        case .confirmed: "checkmark.shield.fill"
        case .review: "sparkles.rectangle.stack"
        case .quality: "chart.bar.xaxis"
        }
    }

    var modeBinding: Binding<CommitmentRadarModel.Mode> {
        Binding(
            get: { state.mode },
            set: { mode in
                Task {
                    await model.send(.modeChanged(mode))
                    onClearFocus()
                }
            })
    }

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
            set: { owner in
                Task {
                    await model.send(.ownerChanged(owner))
                    onClearFocus()
                }
            })
    }

    var dueBinding: Binding<CommitmentRadarModel.DueSelection> {
        Binding(
            get: { state.due },
            set: { due in
                Task {
                    await model.send(.dueChanged(due))
                    onClearFocus()
                }
            })
    }

    var activityBinding: Binding<CommitmentRadarModel.ActivitySelection> {
        Binding(
            get: { state.activity },
            set: { activity in
                Task {
                    await model.send(.activityChanged(activity))
                    onClearFocus()
                }
            })
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

    var mutationFailureBinding: Binding<Bool> {
        Binding(
            get: { state.mutationFailed },
            set: { visible in
                if !visible {
                    Task { await model.send(.dismissMutationFailure) }
                }
            })
    }

    var reviewMutationFailureBinding: Binding<Bool> {
        Binding(
            get: { state.reviewMutationFailed },
            set: { visible in
                if !visible {
                    Task { await model.send(.dismissReviewMutationFailure) }
                }
            })
    }
}

private struct CommitmentRadarGroup: Identifiable {
    let id: String
    let title: String
    var items: [CommitmentRadarItem]
}
