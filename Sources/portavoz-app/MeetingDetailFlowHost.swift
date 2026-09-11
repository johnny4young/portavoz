import ApplicationKit
import IntelligenceKit
import PortavozCore
import SwiftUI
import TranscriptionKit

struct MeetingDetailRefinePresentation {
    let status: String?
    let error: String?
    let draft: RefineDraft?

    init(_ phase: RefineService.Phase?) {
        if case .running(let status) = phase { self.status = status } else { self.status = nil }
        if case .failed(let message) = phase { error = message } else { error = nil }
        if case .draft(let draft) = phase { self.draft = draft } else { self.draft = nil }
    }
}

struct MeetingDetailMirrorValues {
    let myShare: Double
    let myQuestions: Int
    let myInterruptions: Int
    let language: String
    let averageShare: Double?

    static func qualifying(
        detail: MeetingReviewReadModel,
        enabled: Bool,
        justRecorded: MeetingID?,
        language: String,
        averageShare: Double?
    ) -> Self? {
        guard enabled, justRecorded == detail.meeting.id else { return nil }
        let health = MeetingHealth.compute(segments: detail.segments)
        guard let me = detail.speakers.first(where: \.isMe),
              let mine = health.stats.first(where: { $0.speakerID == me.id })
        else { return nil }
        let duration = detail.meeting.endedAt?.timeIntervalSince(detail.meeting.startedAt)
            ?? health.totalSpeechSeconds
        guard MirrorStats.qualifies(
            speakerCount: health.stats.count,
            seconds: duration)
        else { return nil }
        return Self(
            myShare: mine.share,
            myQuestions: mine.questions,
            myInterruptions: mine.interruptionsMade,
            language: language,
            averageShare: averageShare)
    }
}

struct MeetingDetailFlowValues {
    let detail: MeetingReviewReadModel
    let summary: MeetingReviewSummary?
    let refineDraft: RefineDraft?
    let mirror: MeetingDetailMirrorValues?
    let presentation: MeetingDetailPresentation
}

struct MeetingDetailFlowActions {
    let renameMeeting: @MainActor (String) -> Void
    let renameSpeaker: @MainActor (Speaker, String) -> Void
    let createStructure: @MainActor (Recipe) -> Void
    let publishGist: @MainActor () -> Void
    let linkPerson: @MainActor (PersonRememberOffer, CanonicalPersonSelection) -> Void
    let clearRefine: @MainActor () -> Void
    let applyRefine: @MainActor (RefineDraft) -> Void
    let copyText: @MainActor (String) -> Void
    let openURL: @MainActor (URL) -> Void
    let openIntelligenceSettings: @MainActor () -> Void
    let dismissMirror: @MainActor () -> Void
    let showMirrorTrend: @MainActor () -> Void
    let turnOffMirror: @MainActor () -> Void
    let confirmDecision:
        @MainActor (MeetingDetailFlowState.DecisionConfirmTarget, DecisionTopicChoice)
            async -> Bool
    let linkableTopics: [LinkableTopic]
    let confirmSkill:
        @MainActor (MeetingDetailFlowState.SkillConfirmTarget)
            async -> MeetingDetailFlowState.SkillConfirmationResult
    let prepareGitHubIssue:
        @MainActor (MeetingDetailFlowState.GitHubIssueTarget, String)
            async -> MeetingDetailFlowState.GitHubIssueDraftResult
    let confirmGitHubIssue:
        @MainActor (GitHubIssueDraft, UUID, Date)
            async -> MeetingDetailFlowState.GitHubIssueConfirmationResult
    let correctTranscript: @MainActor (
        MeetingTranscriptContent.Row,
        String,
        SpeakerID?,
        Int
    ) async -> String?
    let restructureTranscript: @MainActor (
        MeetingTranscriptContent,
        Int,
        TranscriptStructuralCorrectionOperation
    ) async -> String?
}

/// Presentation host for all Meeting Detail sheets, dialogs, alerts, and
/// file-export panels.
///
/// The host consumes scene-owned flow state but receives every application
/// effect as an explicit action. It cannot reach the detail model, services,
/// providers, or storage.
struct MeetingDetailFlowHost<Content: View>: View {
    let flow: MeetingDetailFlowState
    let values: MeetingDetailFlowValues
    let actions: MeetingDetailFlowActions
    @ViewBuilder let content: Content

    var body: some View {
        content
            .sheet(isPresented: refineDraftBinding) {
                if let draft = values.refineDraft {
                    MeetingDetailRefineReviewSheet(
                        values: MeetingDetailRefineReviewValues(
                            draft: draft,
                            presentation: values.presentation),
                        actions: MeetingDetailRefineReviewActions(
                            discard: actions.clearRefine,
                            apply: actions.applyRefine))
                }
            }
            .sheet(isPresented: mirrorBinding) {
                if let mirror = values.mirror {
                    MirrorCard(
                        myShare: mirror.myShare,
                        myQuestions: mirror.myQuestions,
                        myInterruptions: mirror.myInterruptions,
                        language: mirror.language,
                        averageShare: mirror.averageShare,
                        onSeeTrend: actions.showMirrorTrend,
                        onDismiss: actions.dismissMirror,
                        onTurnOff: actions.turnOffMirror)
                }
            }
            .sheet(item: sheetRouteBinding) { route in
                sheetContent(route)
            }
            .fileExporter(
                isPresented: exportBinding,
                document: flow.export?.document,
                contentType: flow.export?.contentType ?? .plainText,
                defaultFilename: flow.export?.defaultFilename ?? "reunion"
            ) { _ in
                flow.export = nil
            }
            .confirmationDialog(
                dialogTitle,
                isPresented: dialogBinding,
                titleVisibility: .visible
            ) {
                dialogButtons
            } message: {
                if let message = dialogMessage {
                    Text(message)
                }
            }
            .alert(alertTitle, isPresented: alertBinding) {
                alertButtons
            } message: {
                Text(alertMessage)
            }
    }

    @ViewBuilder
    private func sheetContent(_ route: MeetingDetailFlowState.SheetRoute) -> some View {
        switch route {
        case .renameMeeting:
            renameSheet
        case .recap:
            if let summary = values.summary {
                MeetingRecapSheet(
                    meeting: values.detail.meeting,
                    speakers: values.detail.speakers,
                    summary: summary.draft,
                    dismiss: { flow.sheet = nil })
            }
        case .newStructure:
            CustomStructureSheet(existing: nil, onSave: actions.createStructure)
        case .confirmDecision:
            if let target = flow.decisionConfirmTarget {
                DecisionConfirmSheet(
                    target: target,
                    topics: actions.linkableTopics,
                    confirm: { choice in
                        await actions.confirmDecision(target, choice)
                    },
                    dismiss: {
                        flow.decisionConfirmTarget = nil
                        flow.sheet = nil
                    })
            }
        case .confirmSkill:
            if let target = flow.skillConfirmTarget {
                SkillConfirmSheet(
                    target: target,
                    confirm: { await actions.confirmSkill(target) },
                    copyText: actions.copyText,
                    openURL: actions.openURL,
                    dismiss: {
                        flow.skillConfirmTarget = nil
                        flow.sheet = nil
                    })
            }
        case .githubIssueSkill:
            if let target = flow.githubIssueTarget {
                GitHubIssueSkillSheet(
                    target: target,
                    prepare: { repository in
                        await actions.prepareGitHubIssue(target, repository)
                    },
                    confirm: actions.confirmGitHubIssue,
                    copyText: actions.copyText,
                    openURL: actions.openURL,
                    dismiss: {
                        flow.githubIssueTarget = nil
                        flow.sheet = nil
                    })
            }
        case .correctTranscript:
            transcriptCorrectionSheet
        }
    }

    @ViewBuilder
    private var transcriptCorrectionSheet: some View {
        if let target = flow.transcriptCorrectionTarget,
           let editorContext = target.editorContext {
            TranscriptCorrectionEditor(
                context: editorContext,
                structuralContext: target.structuralContext,
                speakers: values.detail.speakers,
                save: { text, speakerID in
                    await actions.correctTranscript(
                        editorContext.original,
                        text,
                        speakerID,
                        target.baseTranscriptRevision)
                },
                undo: {
                    await actions.correctTranscript(
                        editorContext.original,
                        editorContext.original.text,
                        editorContext.original.speakerID,
                        target.baseTranscriptRevision)
                },
                restructure: {
                    await actions.restructureTranscript(
                        target.accepted,
                        target.baseTranscriptRevision,
                        $0)
                })
        } else if let target = flow.transcriptCorrectionTarget,
                  let structuralContext = target.structuralContext {
            TranscriptStructuralCorrectionEditor(
                context: structuralContext,
                perform: {
                    await actions.restructureTranscript(
                        target.accepted,
                        target.baseTranscriptRevision,
                        $0)
                })
        } else {
            ContentUnavailableView(
                "Couldn’t complete",
                systemImage: "exclamationmark.triangle",
                description: Text(
                    "This transcript line no longer matches the accepted recording."))
                .accessibilityIdentifier("transcript-correction-unavailable")
        }
    }

    private var renameSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename meeting").font(.headline)
            AutoSelectTextField(
                text: Binding(
                    get: { flow.renameMeetingTitle },
                    set: { flow.renameMeetingTitle = $0 }),
                onSubmit: { actions.renameMeeting(flow.renameMeetingTitle) })
                .frame(width: 340, height: 22)
            HStack {
                Spacer()
                Button("Cancel") { flow.sheet = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { actions.renameMeeting(flow.renameMeetingTitle) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private var dialogTitle: String {
        switch flow.dialog {
        case .publishGist:
            L10n.text(
                "The full transcript will leave your Mac for GitHub as a SECRET (unlisted) gist.")
        case .choosePerson(let offer, _):
            L10n.format("Who is %@?", offer.speaker.displayName ?? "")
        case nil:
            ""
        }
    }

    private var dialogMessage: String? {
        guard case .choosePerson = flow.dialog else { return nil }
        return L10n.text(
            "Choose an existing person or keep this as a separate person. Portavoz never merges people automatically.")
    }

    @ViewBuilder
    private var dialogButtons: some View {
        switch flow.dialog {
        case .publishGist:
            Button("Publish secret gist", action: actions.publishGist)
            Button("Cancel", role: .cancel) {}
        case .choosePerson:
            personChoiceButtons
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder
    private var personChoiceButtons: some View {
        if let choice = flow.personChoice {
            ForEach(Array(choice.candidates.enumerated()), id: \.element.id) { index, person in
                Button(personCandidateLabel(person, index: index)) {
                    actions.linkPerson(choice.offer, .existing(person.id))
                }
                .accessibilityIdentifier("person-link-existing-\(index)")
            }
            Button(L10n.text("Create a separate person")) {
                actions.linkPerson(choice.offer, .createDistinct)
            }
            .accessibilityIdentifier("person-create-distinct")
        }
        Button(L10n.text("Cancel"), role: .cancel) {}
            .accessibilityIdentifier("person-link-cancel")
    }

    private func personCandidateLabel(_ person: Person, index: Int) -> String {
        if flow.personChoice?.candidates.count == 1 {
            return L10n.format("Use %@", person.preferredName)
        }
        return L10n.format("Use %@ (person %d)", person.preferredName, index + 1)
    }

    private var alertTitle: String {
        switch flow.alert {
        case .gistPublished: L10n.text("Gist published")
        case .summaryNotice: L10n.text("Summary")
        case .summarySetup: L10n.text("Summary needs setup")
        case .failure: L10n.text("Couldn’t complete")
        case .renameSpeaker: L10n.text("Rename speaker")
        case nil: ""
        }
    }

    private var alertMessage: String {
        switch flow.alert {
        case .gistPublished(let url):
            return url.absoluteString
        case .summaryNotice(let message), .failure(let message):
            return message
        case .summarySetup(let issue):
            return issue.message
        case .renameSpeaker(let speaker):
            return L10n.format("Current label: %@", speaker.label)
        case nil:
            return ""
        }
    }

    @ViewBuilder
    private var alertButtons: some View {
        switch flow.alert {
        case .gistPublished(let url):
            Button("Copy link") { actions.copyText(url.absoluteString) }
                .accessibilityIdentifier("gist-result-copy-link")
            Button("Open") { actions.openURL(url) }
                .accessibilityIdentifier("gist-result-open-link")
            Button("OK", role: .cancel) {}
                .accessibilityIdentifier("gist-result-dismiss")
        case .summaryNotice, .failure:
            Button("OK", role: .cancel) {}
        case .summarySetup:
            Button("Open Intelligence Settings", action: actions.openIntelligenceSettings)
                .accessibilityIdentifier("detail-summary-open-settings")
            Button("Not now", role: .cancel) {}
                .accessibilityIdentifier("detail-summary-not-now")
        case .renameSpeaker:
            renameSpeakerButtons
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder
    private var renameSpeakerButtons: some View {
        TextField(
            "Name",
            text: Binding(
                get: { flow.renameSpeakerName },
                set: { flow.renameSpeakerName = $0 }))
            .accessibilityIdentifier("speaker-name-field")
        Button("Save") {
            if let speaker = flow.renamingSpeaker {
                let name = flow.renameSpeakerName
                actions.renameSpeaker(speaker, name)
            }
        }
        .accessibilityIdentifier("speaker-rename-save")
        Button("Cancel", role: .cancel) {}
    }

    private var sheetRouteBinding: Binding<MeetingDetailFlowState.SheetRoute?> {
        Binding(get: { flow.sheet }, set: { flow.sheet = $0 })
    }

    private var dialogBinding: Binding<Bool> {
        Binding(get: { flow.dialog != nil }, set: { if !$0 { flow.dialog = nil } })
    }

    private var alertBinding: Binding<Bool> {
        Binding(get: { flow.alert != nil }, set: { if !$0 { flow.alert = nil } })
    }

    private var exportBinding: Binding<Bool> {
        Binding(get: { flow.export != nil }, set: { if !$0 { flow.export = nil } })
    }

    private var refineDraftBinding: Binding<Bool> {
        Binding(
            get: { values.refineDraft != nil },
            set: { if !$0 { actions.clearRefine() } })
    }

    private var mirrorBinding: Binding<Bool> {
        Binding(
            get: { values.mirror != nil },
            set: { if !$0 { actions.dismissMirror() } })
    }
}
