import ApplicationKit
import Foundation
import XCTest

extension ArchitectureDependencyTests {
    func testCommitmentReviewFeedbackRemainsSourceBoundAndTransient() throws {
        let core = try Self.contents(
            of: "Sources/PortavozCore/CommitmentReview.swift")
        let schema = try Self.contents(
            of: "Sources/StorageKit/Schema+CommitmentReview.swift")
        let projection = try Self.contents(
            of: "Sources/ApplicationKit/MeetingCommitmentInbox.swift")
        let appComposition = try Self.contents(
            of: "Sources/portavoz-app/AppServices+MeetingDetail.swift")
        let bundle = try Self.contents(
            of: "Sources/IntegrationsKit/MeetingBundle.swift")
        let meetingSync = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+SyncAggregate.swift")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertTrue(core.contains("case dismissed"))
        XCTAssertTrue(core.contains("case deferred"))
        XCTAssertTrue(schema.contains("primaryKey(\"actionItemID\""))
        XCTAssertTrue(schema.contains("references(\"actionItem\""))
        XCTAssertFalse(schema.contains("title"))
        XCTAssertFalse(schema.contains("canonicalPersonID"))
        XCTAssertFalse(schema.contains("suggestedDueAt"))
        XCTAssertTrue(projection.contains("speaker.personID"))
        XCTAssertTrue(projection.contains("suggestedDueAt: nil"))
        XCTAssertTrue(appComposition.contains(
            "observeCommitmentReviewStates(for: meetingID)"))
        XCTAssertFalse(bundle.contains("CommitmentReviewDecision"))
        XCTAssertFalse(meetingSync.contains("CommitmentReviewDecision"))
        XCTAssertTrue(decisions.contains("## D238"))
        XCTAssertTrue(decisions.contains(
            "Keep commitment review feedback source-bound"))
    }

    func testCommitmentRadarRemainsBoundedAndApplicationOwned() throws {
        let core = try Self.contents(
            of: "Sources/PortavozCore/CommitmentRadar.swift")
        let application = try Self.contents(
            of: "Sources/ApplicationKit/LoadCommitmentRadar.swift")
        let management = try Self.contents(
            of: "Sources/ApplicationKit/ManageCommitmentRadar.swift")
        let storage = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+CommitmentRadar.swift")
        let model = try Self.contents(
            of: "Sources/portavoz-app/CommitmentRadarModel.swift")
        let view = try Self.contents(
            of: "Sources/portavoz-app/CommitmentRadarView.swift")
        let dueDateSheet = try Self.contents(
            of: "Sources/portavoz-app/CommitmentRadarDueDateSheet.swift")
        let composition = try Self.contents(
            of: "Sources/portavoz-app/AppServices+CommitmentRadar.swift")
        let root = try Self.contents(of: "Sources/portavoz-app/ContentView.swift")
        let scaleBenchmark = try Self.contents(
            of: "Tests/PortavozTests/CommitmentRadarScaleBenchmarkTests.swift")
        let scaleRunner = try Self.contents(
            of: "scripts/run-commitment-radar-benchmark.sh")
        let makefile = try Self.contents(of: "Makefile")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertTrue(core.contains("maximumItemCount = 200"))
        XCTAssertTrue(core.contains("maximumRelatedRowCount = 20"))
        XCTAssertTrue(application.contains("calendar.startOfDay(for: now())"))
        XCTAssertTrue(application.contains("private static let dueSoonDays = 7"))
        XCTAssertTrue(application.contains("private static let newActivityDays = 7"))
        XCTAssertTrue(management.contains("protocol CommitmentRadarMutating"))
        XCTAssertTrue(management.contains("enum CommitmentRadarMutation"))
        XCTAssertTrue(management.contains("case complete"))
        XCTAssertTrue(management.contains("case reopen"))
        XCTAssertTrue(management.contains("case reschedule(Date?)"))
        XCTAssertTrue(management.contains("sourceMeetingID: nil"))
        XCTAssertFalse(management.contains("case snooze"))
        XCTAssertTrue(storage.contains("database.read"))
        XCTAssertTrue(storage.contains("ROW_NUMBER() OVER"))
        XCTAssertTrue(storage.contains("COUNT(*) OVER"))
        XCTAssertTrue(storage.contains("commitmentRadarPersonNames"))
        XCTAssertFalse(storage.contains("meetingDetail"))
        XCTAssertTrue(model.contains("protocol CommitmentRadarModelClient"))
        XCTAssertTrue(model.contains("private var radarRequestID = UUID()"))
        XCTAssertTrue(model.contains("private var reviewRequestID = UUID()"))
        XCTAssertTrue(model.contains("case ownerChanged"))
        XCTAssertTrue(model.contains("case groupingChanged"))
        XCTAssertTrue(model.contains("case complete(CommitmentID)"))
        XCTAssertTrue(model.contains("case reopen(CommitmentID)"))
        XCTAssertTrue(model.contains("case reschedule(CommitmentID, Date?)"))
        XCTAssertTrue(model.contains("requestCommitmentRadarSearchReindex"))
        XCTAssertTrue(composition.contains("LoadCommitmentRadar(repository: store)"))
        XCTAssertTrue(composition.contains("ManageCommitmentRadar(repository: store)"))
        XCTAssertTrue(composition.contains("requestSearchReconciliation()"))
        XCTAssertTrue(root.contains("@State private var commitmentRadarModel"))
        XCTAssertTrue(root.contains("case .commitments(let focus):"))
        XCTAssertTrue(view.contains(
            "let onOpenMeeting: (MeetingID, TimeInterval?) -> Void"))
        XCTAssertTrue(view.contains("case .owner:"))
        XCTAssertTrue(view.contains("case .meeting:"))
        XCTAssertFalse(view.contains("AppServices"))
        XCTAssertFalse(view.contains("MeetingStore"))
        XCTAssertFalse(view.contains("SummaryProvider"))
        XCTAssertFalse(view.contains("IntelligenceKit"))
        XCTAssertTrue(view.contains("commitment-radar-complete-"))
        XCTAssertTrue(view.contains("commitment-radar-reopen-"))
        XCTAssertTrue(dueDateSheet.contains("commitment-radar-due-editor"))
        XCTAssertTrue(scaleBenchmark.contains(
            "static let canonicalCorpusSizes = [1_000, 10_000]"))
        XCTAssertTrue(scaleBenchmark.contains("p95BudgetMilliseconds: 100"))
        XCTAssertTrue(scaleBenchmark.contains("guard selectCount == 4"))
        XCTAssertTrue(scaleBenchmark.contains(
            "PORTAVOZ_COMMITMENT_RADAR_REPORT"))
        XCTAssertFalse(scaleBenchmark.contains("MeetingStore.defaultDatabaseURL"))
        XCTAssertTrue(scaleRunner.contains("swift test -c release"))
        XCTAssertTrue(scaleRunner.contains("--runs must be between 3 and 20"))
        XCTAssertTrue(makefile.contains("commitment-radar-benchmark:"))
        XCTAssertTrue(decisions.contains("## D241"))
        XCTAssertTrue(decisions.contains(
            "Bound Commitment Radar as a confirmed-only read model"))
        XCTAssertTrue(decisions.contains("## D242"))
        XCTAssertTrue(decisions.contains(
            "Gate Commitment Radar with a content-free Release benchmark"))
        XCTAssertTrue(decisions.contains("## D256"))
        XCTAssertTrue(decisions.contains(
            "Route Radar lifecycle actions through append-only continuity"))
    }

    func testCommitmentReminderHistoryIsDurableAndSeparateFromDueDate() throws {
        let core = try Self.contents(
            of: "Sources/PortavozCore/CommitmentReminder.swift")
        let schema = try Self.contents(
            of: "Sources/StorageKit/Schema+CommitmentReminder.swift")
        let storage = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+CommitmentReminder.swift")
        let radar = try Self.contents(
            of: "Sources/ApplicationKit/ManageCommitmentRadar.swift")
        let app = try Self.contents(
            of: "Sources/portavoz-app/ContentView.swift")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertTrue(core.contains("enum CommitmentReminderTransition"))
        XCTAssertTrue(core.contains("case snooze(until: Date)"))
        XCTAssertTrue(core.contains("case cancel"))
        XCTAssertTrue(core.contains("previousEventID"))
        XCTAssertTrue(schema.contains("registerMigration(\"v23\")"))
        XCTAssertTrue(schema.contains("commitmentReminderEvent_immutable_bu"))
        XCTAssertTrue(schema.contains("commitmentReminderState_on_due"))
        XCTAssertTrue(storage.contains("database.write"))
        XCTAssertTrue(storage.contains("CommitmentReminderPolicy.applying"))
        XCTAssertTrue(storage.contains("commitment.status == .confirmed"))
        XCTAssertTrue(storage.contains(
            "canonicalDueAt == sourceDueAt"))
        XCTAssertFalse(radar.contains("case snooze"))
        XCTAssertFalse(app.contains("CommitmentReminderTransition"))
        XCTAssertTrue(decisions.contains("## D257"))
    }

    func testCommitmentFieldQualityPersistenceIsContentFreeAndBounded() throws {
        let core = try Self.contents(
            of: "Sources/PortavozCore/CommitmentFieldQuality.swift")
        let schema = try Self.contents(
            of: "Sources/StorageKit/Schema+CommitmentFieldQuality.swift")
        let storage = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+CommitmentFieldQuality.swift")
        let bundle = try Self.contents(
            of: "Sources/IntegrationsKit/MeetingBundle.swift")
        let meetingSync = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+SyncAggregate.swift")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertTrue(core.contains("case withdrawn"))
        XCTAssertTrue(core.contains("case otherOrUnknown"))
        XCTAssertTrue(schema.contains("registerMigration(\"v24\")"))
        XCTAssertTrue(schema.contains("commitmentFieldPresentation_immutable_bu"))
        XCTAssertFalse(schema.contains("column(\"meetingID\""))
        XCTAssertFalse(schema.contains("column(\"text\""))
        XCTAssertFalse(schema.contains("column(\"title\""))
        XCTAssertFalse(schema.contains("column(\"provider"))
        XCTAssertTrue(storage.contains("SHA256.hash"))
        XCTAssertTrue(storage.contains(
            "CommitmentFieldQualityEvaluator.maximumObservationCount + 1"))
        XCTAssertTrue(storage.contains("firstConfirmation.occurredAt"))
        XCTAssertTrue(storage.contains("THEN 'withdrawn'"))
        XCTAssertFalse(bundle.contains("CommitmentFieldPresentation"))
        XCTAssertFalse(meetingSync.contains("commitmentFieldPresentation"))
        XCTAssertTrue(decisions.contains("## D268"))
    }

    func testCommitmentFieldQualityCompositionIsAggregateAndAdvisory() throws {
        let workflow = try Self.contents(
            of: "Sources/ApplicationKit/CommitmentFieldQuality.swift")
        let composition = try Self.contents(
            of: "Sources/portavoz-app/AppServices+CommitmentRadar.swift")
        let model = try Self.contents(
            of: "Sources/portavoz-app/CommitmentRadarModel.swift")
        let review = try Self.contents(
            of: "Sources/portavoz-app/CommitmentReviewQueueView.swift")
        let quality = try Self.contents(
            of: "Sources/portavoz-app/CommitmentFieldQualityView.swift")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertTrue(workflow.contains("struct LoadCommitmentFieldQuality"))
        XCTAssertTrue(workflow.contains("struct RecordCommitmentFieldPresentation"))
        XCTAssertTrue(workflow.contains("CommitmentFieldQualityEvaluator.evaluate"))
        XCTAssertTrue(composition.contains("LoadCommitmentFieldQuality"))
        XCTAssertTrue(composition.contains("RecordCommitmentFieldPresentation"))
        XCTAssertTrue(model.contains("case quality"))
        XCTAssertTrue(model.contains("qualityRequestID"))
        XCTAssertTrue(model.contains("state.mode == .quality"))
        XCTAssertTrue(model.contains("presentationTasks"))
        XCTAssertTrue(model.contains("reviewCandidatePresented"))
        XCTAssertTrue(review.contains("reviewCandidatePresented"))
        XCTAssertTrue(review.contains(".onAppear"))
        XCTAssertFalse(review.contains(".task(id: item.id)"))
        XCTAssertTrue(quality.contains("Advisory only"))
        XCTAssertFalse(quality.contains("suggestedOwnerToken"))
        XCTAssertFalse(quality.contains("CommitmentFieldQualityObservation"))
        XCTAssertFalse(quality.contains("import StorageKit"))
        XCTAssertTrue(decisions.contains("## D269"))
    }

    func testCommitmentReminderReconciliationIsBoundedAndAdapterNeutral() throws {
        let core = try Self.contents(
            of: "Sources/PortavozCore/CommitmentReminder.swift")
        let workflow = try Self.contents(
            of: "Sources/ApplicationKit/ReconcileCommitmentReminders.swift")
        let storage = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+CommitmentReminder.swift")
        let app = try Self.contents(
            of: "Sources/portavoz-app/ContentView.swift")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertTrue(core.contains(
            "struct CommitmentReminderReconciliationQuery"))
        XCTAssertTrue(core.contains("maximumItemCount = 256"))
        XCTAssertTrue(workflow.contains(
            "protocol CommitmentReminderDeliveryScheduling"))
        XCTAssertTrue(workflow.contains("incompleteSnapshot"))
        XCTAssertTrue(workflow.contains("minimumSchedulingDelay"))
        XCTAssertTrue(workflow.contains("try? await scheduler.cancelCommitmentReminder"))
        XCTAssertFalse(workflow.contains("UserNotifications"))
        XCTAssertFalse(workflow.contains("UNUserNotificationCenter"))
        XCTAssertTrue(storage.contains("COUNT(*) OVER () AS totalCount"))
        XCTAssertTrue(storage.contains("replaceCommitmentReminderSchedule"))
        XCTAssertTrue(storage.contains("commitment.deletedAt == nil"))
        XCTAssertFalse(app.contains("ReconcileCommitmentReminders"))
        XCTAssertTrue(decisions.contains("## D258"))
    }

    func testMacOSCommitmentReminderAdapterIsDeliveryAwareAndPrivate() throws {
        let workflow = try Self.contents(
            of: "Sources/ApplicationKit/ReconcileCommitmentReminders.swift")
        let adapter = try Self.contents(
            of: "Sources/portavoz-app/AppCommitmentReminderNotificationScheduler.swift")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertTrue(workflow.contains(
            "enum CommitmentReminderDeliveryUpsertOutcome"))
        XCTAssertTrue(workflow.contains(
            "case alreadyPresented(scheduledFor: Date, deliveredAt: Date)"))
        XCTAssertTrue(adapter.contains("import UserNotifications"))
        XCTAssertTrue(adapter.contains(
            "portavoz.commitment-reminder."))
        XCTAssertTrue(adapter.contains(
            "case .authorized, .provisional, .ephemeral"))
        XCTAssertTrue(adapter.contains("func requestAuthorization()"))
        XCTAssertTrue(adapter.contains("removePending(identifier:"))
        XCTAssertTrue(adapter.contains("removeDelivered(identifier:"))
        XCTAssertTrue(adapter.contains("L10n.text(\"Commitment reminder\")"))
        XCTAssertFalse(adapter.contains("Commitment.title"))
        XCTAssertFalse(adapter.contains("TranscriptSegment"))
        XCTAssertTrue(decisions.contains("## D259"))
    }

    func testCommitmentRemindersAreExplicitProcessOwnedAndSignalDriven() throws {
        let services = try Self.contents(
            of: "Sources/portavoz-app/AppServices.swift")
        let composition = try Self.contents(
            of: "Sources/portavoz-app/AppServices+CommitmentReminders.swift")
        let model = try Self.contents(
            of: "Sources/portavoz-app/CommitmentReminderModel.swift")
        let launch = try Self.contents(
            of: "Sources/portavoz-app/AppLaunchModel.swift")
        let radarClient = try Self.contents(
            of: "Sources/portavoz-app/AppServices+CommitmentRadar.swift")
        let radarView = try Self.contents(
            of: "Sources/portavoz-app/CommitmentRadarView.swift")
        let reminderCard = try Self.contents(
            of: "Sources/portavoz-app/CommitmentReminderStatusCard.swift")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertTrue(services.contains(
            "let commitmentReminders: CommitmentReminderModel"))
        XCTAssertTrue(services.contains("makeCommitmentReminderModel("))
        XCTAssertTrue(composition.contains(
            "AppReminderNotificationScheduler"))
        XCTAssertTrue(composition.contains(
            "UITestReminderNotificationCenter"))
        XCTAssertTrue(composition.contains(
            "commitmentReminders.kick()"))
        XCTAssertTrue(launch.contains(
            "commitmentReminders.send(.start)"))
        XCTAssertTrue(model.contains("case enable"))
        XCTAssertTrue(model.contains("rerunRequested"))
        XCTAssertTrue(model.contains("requestCommitmentReminderPermission"))
        XCTAssertFalse(model.contains("Task.sleep"))
        XCTAssertTrue(radarClient.contains("commitmentReminders.kick()"))
        XCTAssertTrue(radarView.contains("CommitmentReminderStatusCard"))
        XCTAssertTrue(reminderCard.contains(
            "commitment-reminder-enable"))
        XCTAssertTrue(reminderCard.contains(
            "commitment-reminder-enabled"))
        XCTAssertTrue(decisions.contains("## D260"))
    }

    func testReminderPresentationIsDurableAndDefaultTapRoutesToRadar() throws {
        let workflow = try Self.contents(
            of: "Sources/ApplicationKit/RecordCommitmentReminderPresentation.swift")
        let adapter = try Self.contents(
            of: "Sources/portavoz-app/AppCommitmentReminderNotificationScheduler.swift")
        let delegate = try Self.contents(
            of: "Sources/portavoz-app/PortavozAppDelegate.swift")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertTrue(workflow.contains(
            "protocol CommitmentReminderPresentationRepository"))
        XCTAssertTrue(workflow.contains(
            "state.scheduledFor == request.scheduledFor"))
        XCTAssertTrue(workflow.contains(
            "state.sourceDueAt == request.sourceDueAt"))
        XCTAssertTrue(workflow.contains("case .presented:"))
        XCTAssertTrue(workflow.contains(".ignoredStaleDelivery"))
        XCTAssertFalse(workflow.contains("UserNotifications"))
        XCTAssertTrue(adapter.contains(
            "categoryIdentifier = \"portavoz.commitment-reminder\""))
        XCTAssertTrue(adapter.contains("static func record("))
        XCTAssertTrue(adapter.contains("deliveredAt: Date?"))
        XCTAssertTrue(delegate.contains(
            "func applicationWillFinishLaunching"))
        XCTAssertTrue(delegate.contains("center.delegate = self"))
        XCTAssertTrue(adapter.contains(
            "case UNNotificationDefaultActionIdentifier:"))
        XCTAssertTrue(adapter.contains(".openRadar"))
        XCTAssertTrue(delegate.contains("case .openRadar:"))
        XCTAssertTrue(delegate.contains(
            "pendingRoute = .commitments(.commitment(record.commitmentID))"))
        XCTAssertTrue(decisions.contains("## D261"))
    }

    func testReminderSnoozeIsDurablePrivateAndDoesNotRewriteDueDate() throws {
        let workflow = try Self.contents(
            of: "Sources/ApplicationKit/SnoozeCommitmentReminder.swift")
        let adapter = try Self.contents(
            of: "Sources/portavoz-app/AppCommitmentReminderNotificationScheduler.swift")
        let delegate = try Self.contents(
            of: "Sources/portavoz-app/PortavozAppDelegate.swift")
        let model = try Self.contents(
            of: "Sources/portavoz-app/CommitmentReminderModel.swift")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertTrue(workflow.contains("struct SnoozeCommitmentReminder"))
        XCTAssertTrue(workflow.contains(
            "RecordCommitmentReminderPresentation"))
        XCTAssertTrue(workflow.contains(
            "state.sourceDueAt == request.sourceDueAt"))
        XCTAssertTrue(workflow.contains(
            ".snooze(until: request.snoozeUntil)"))
        XCTAssertFalse(workflow.contains("CommitmentRadarMutation"))
        XCTAssertFalse(workflow.contains("UserNotifications"))
        XCTAssertTrue(adapter.contains(
            "snooze-15-minutes"))
        XCTAssertTrue(adapter.contains(
            "options: []"))
        XCTAssertTrue(delegate.contains(
            "AppReminderNotificationMetadata.responseAction"))
        XCTAssertTrue(delegate.contains("case .snooze:"))
        XCTAssertTrue(model.contains("func snooze("))
        XCTAssertTrue(model.contains("await refreshPermission()"))
        XCTAssertTrue(decisions.contains("## D263"))
    }

    func testReminderDismissalPersistsNativeClearingAsTerminalIntent() throws {
        let workflow = try Self.contents(
            of: "Sources/ApplicationKit/DismissCommitmentReminder.swift")
        let adapter = try Self.contents(
            of: "Sources/portavoz-app/AppCommitmentReminderNotificationScheduler.swift")
        let delegate = try Self.contents(
            of: "Sources/portavoz-app/PortavozAppDelegate.swift")
        let model = try Self.contents(
            of: "Sources/portavoz-app/CommitmentReminderModel.swift")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertTrue(workflow.contains("struct DismissCommitmentReminder"))
        XCTAssertTrue(workflow.contains(
            "RecordCommitmentReminderPresentation"))
        XCTAssertTrue(workflow.contains(
            "state.sourceDueAt == request.sourceDueAt"))
        XCTAssertTrue(workflow.contains(".dismiss,"))
        XCTAssertFalse(workflow.contains("CommitmentRadarMutation"))
        XCTAssertFalse(workflow.contains("UserNotifications"))
        XCTAssertTrue(adapter.contains(".customDismissAction"))
        XCTAssertTrue(adapter.contains(
            "case UNNotificationDismissActionIdentifier:"))
        XCTAssertTrue(delegate.contains("case .dismiss:"))
        XCTAssertTrue(model.contains("func dismiss("))
        XCTAssertTrue(decisions.contains("## D264"))
    }

    func testCommitmentReviewQueueIsBoundedAndComposedAsSeparateReviewTruth() throws {
        let core = try Self.contents(
            of: "Sources/PortavozCore/CommitmentReviewQueue.swift")
        let application = try Self.contents(
            of: "Sources/ApplicationKit/LoadCommitmentReviewQueue.swift")
        let storage = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+CommitmentReviewQueue.swift")
        let bundle = try Self.contents(
            of: "Sources/IntegrationsKit/MeetingBundle.swift")
        let meetingSync = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+SyncAggregate.swift")
        let composition = try Self.contents(
            of: "Sources/portavoz-app/AppServices+CommitmentRadar.swift")
        let model = try Self.contents(
            of: "Sources/portavoz-app/CommitmentRadarModel.swift")
        let view = try Self.contents(
            of: "Sources/portavoz-app/CommitmentReviewQueueView.swift")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertTrue(core.contains("case library"))
        XCTAssertTrue(core.contains("case meetings([MeetingID])"))
        XCTAssertTrue(core.contains("maximumItemCount = 100"))
        XCTAssertTrue(core.contains("maximumEvidenceCount = 20"))
        XCTAssertTrue(core.contains("maximumMeetingScopeCount = 50"))
        XCTAssertTrue(core.contains("Confirmation must therefore reopen"))
        XCTAssertTrue(application.contains("reviewAt: now()"))
        XCTAssertFalse(application.contains("confirmCommitment"))
        XCTAssertFalse(application.contains("setCommitmentReviewDecision"))
        XCTAssertTrue(storage.contains("database.read"))
        XCTAssertTrue(storage.contains("COUNT(*) OVER () AS totalCount"))
        XCTAssertTrue(storage.contains("ROW_NUMBER() OVER"))
        XCTAssertTrue(storage.contains("HAVING COUNT(link.id) > 0"))
        XCTAssertTrue(storage.contains("ORDER BY newest.createdAt DESC"))
        XCTAssertFalse(storage.contains("meetingDetail"))
        XCTAssertFalse(bundle.contains("CommitmentReviewQueue"))
        XCTAssertFalse(meetingSync.contains("CommitmentReviewQueue"))
        XCTAssertTrue(composition.contains("LoadCommitmentReviewQueue"))
        XCTAssertTrue(composition.contains("makeCommitmentInboxManager()"))
        XCTAssertTrue(composition.contains(".review(request)"))
        XCTAssertTrue(model.contains("case confirmed"))
        XCTAssertTrue(model.contains("case review"))
        XCTAssertTrue(model.contains("reviewRequestID"))
        XCTAssertTrue(view.contains("Review in meeting"))
        XCTAssertTrue(view.contains("Dismiss"))
        XCTAssertTrue(view.contains("Review later"))
        XCTAssertFalse(view.contains("Confirm commitment"))
        XCTAssertTrue(decisions.contains("## D265"))
        XCTAssertTrue(decisions.contains("## D266"))
    }

    func testCommitmentFieldQualityIsContentFreeBoundedAndDecisionNeutral() throws {
        let core = try Self.contents(
            of: "Sources/PortavozCore/CommitmentFieldQuality.swift")
        let fixture = try Self.contents(
            of: "Fixtures/CommitmentFieldQuality/public-synthetic-v1.json")
        let architecture = try Self.contents(of: "docs/ARCHITECTURE.md")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertTrue(core.contains("windowDayCount = 90"))
        XCTAssertTrue(core.contains("maximumObservationCount = 50_000"))
        XCTAssertTrue(core.contains("reviewFalsePositiveRate"))
        XCTAssertTrue(core.contains("ownerPrecision"))
        XCTAssertTrue(core.contains("dueDatePrecision"))
        XCTAssertTrue(core.contains("evidenceCoverage"))
        XCTAssertTrue(core.contains("confirmationLatencyP95"))
        XCTAssertTrue(core.contains("case missing"))
        XCTAssertTrue(core.contains("suggestedOwnerToken: UUID?"))
        XCTAssertFalse(core.contains("StorageKit"))
        XCTAssertFalse(core.contains("ApplicationKit"))
        XCTAssertFalse(core.contains("SwiftUI"))
        XCTAssertFalse(core.contains("meetingTitle"))
        XCTAssertFalse(core.contains("transcriptText"))
        XCTAssertTrue(fixture.contains(#""contentSource": "synthetic-only""#))
        XCTAssertFalse(fixture.contains(#""text":"#))
        XCTAssertFalse(fixture.contains(#""meetingTitle":"#))
        XCTAssertTrue(architecture.contains("rolling 90-day commitment field cohort"))
        XCTAssertTrue(decisions.contains("## D267"))
    }

    func testReminderDraftUsesExplicitPermissionExactTargetAndBoundedReads() throws {
        let offers = try Self.contents(
            of: "Sources/ApplicationKit/ReminderDraftOffers.swift")
        let executionStore = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+SkillExecution.swift")
        let model = try Self.contents(
            of: "Sources/portavoz-app/ReminderDraftModel.swift")
        let adapter = try Self.contents(
            of: "Sources/portavoz-app/AppReminderDraftEventKitAdapter.swift")
        let services = try Self.contents(
            of: "Sources/portavoz-app/AppServices+ReminderDraft.swift")
        let sheet = try Self.contents(
            of: "Sources/portavoz-app/ReminderDraftSheet.swift")
        let shipping = try Self.contents(of: "scripts/make-app.sh")
        let uiHost = try Self.contents(of: "project.yml")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        for forbidden in ["import EventKit", "import SwiftUI", "import AppKit"] {
            XCTAssertFalse(offers.contains(forbidden), forbidden)
            XCTAssertFalse(model.contains(forbidden), forbidden)
        }
        XCTAssertTrue(offers.contains("maximumCommitmentCount = 200"))
        XCTAssertTrue(offers.contains("store.skillExecutions(idempotencyKeys: keys)"))
        XCTAssertTrue(executionStore.contains("idempotencyKeys.count <= 200"))
        XCTAssertTrue(adapter.contains("private let eventStore = EKEventStore()"))
        XCTAssertTrue(adapter.contains("defaultCalendarForNewReminders()"))
        XCTAssertTrue(adapter.contains("EKReminder(eventStore: eventStore)"))
        XCTAssertTrue(adapter.contains("eventStore.save(reminder, commit: true)"))
        XCTAssertTrue(adapter.contains("guard current == target"))
        XCTAssertTrue(services.contains("UITestReminderDraftPlatform()"))
        XCTAssertTrue(services.contains(": AppReminderDraftEventKitAdapter()"))
        XCTAssertTrue(services.contains("current == request.offer.commitment"))
        XCTAssertTrue(services.contains("identifier: request.target.identifier"))
        XCTAssertTrue(sheet.contains("reminder-draft-allow-access"))
        XCTAssertTrue(sheet.contains("reminder-draft-target-list"))
        XCTAssertTrue(sheet.contains("reminder-draft-confirm"))
        XCTAssertTrue(shipping.contains("NSRemindersFullAccessUsageDescription"))
        XCTAssertTrue(uiHost.contains("NSRemindersFullAccessUsageDescription"))
        XCTAssertTrue(decisions.contains("## D323"))
    }

    func testMeetingReminderEntersThroughApplicationKit() throws {
        let workflow = try Self.contents(
            of: "Sources/ApplicationKit/MeetingReminderWorkflow.swift")
        let adapter = try Self.contents(
            of: "Sources/portavoz-app/AppServices+MeetingReminder.swift")
        let controller = try Self.contents(
            of: "Sources/portavoz-app/MeetingReminder.swift")

        XCTAssertTrue(workflow.contains("protocol UpcomingMeetingListing"))
        XCTAssertTrue(workflow.contains("struct ResolveMeetingReminder"))
        XCTAssertFalse(workflow.contains("import EventKit"))
        XCTAssertFalse(workflow.contains("CalendarAttendeeSource"))
        XCTAssertTrue(adapter.contains("CalendarAttendeeSource().upcomingEvents()"))
        XCTAssertTrue(adapter.contains("Task.detached(priority: .utility)"))
        XCTAssertTrue(controller.contains("services?.nextMeetingReminder"))
        for bypass in [
            "import IntegrationsKit",
            "CalendarAttendeeSource",
            "ReminderPolicy.dueEvent",
            "UserDefaults.standard",
            "Date()",
            "timeIntervalSinceNow",
        ] {
            XCTAssertFalse(controller.contains(bypass), bypass)
        }
    }
}
