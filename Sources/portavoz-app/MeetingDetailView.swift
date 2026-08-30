import ApplicationKit
import IntelligenceKit
import PortavozCore
import SwiftUI

/// Composition surface for one reviewed meeting.
///
/// Route effects live in `MeetingDetailCoordinator`, modal presentation in
/// `MeetingDetailFlowHost`, and feature rendering in explicit sections. This
/// view retains only observation lifecycle and transcript/playback navigation,
/// whose state spans multiple sections.
struct MeetingDetailView: View {
    let meetingID: MeetingID
    let model: MeetingDetailModel
    let flow: MeetingDetailFlowState
    let presentation: MeetingDetailPresentation
    let sceneValues: MeetingDetailSceneValues
    let sceneActions: MeetingDetailSceneActions

    @State private var playbackNavigation = MeetingDetailPlaybackNavigation()
    private var detail: MeetingReviewReadModel? { model.state.readModel }
    private var summary: MeetingReviewSummary? { detail?.summary }
    private var player: MeetingPlaybackSession? { model.state.playback?.session }
    private var waveform: [MeetingWaveformBucket] { model.state.playback?.waveform ?? [] }
    private var playbackTaskID: String? { detail?.meeting.audioDirectory }
    private var coordinator: MeetingDetailCoordinator {
        MeetingDetailCoordinator(
            meetingID: meetingID,
            model: model,
            flow: flow,
            sceneValues: sceneValues,
            sceneActions: sceneActions)
    }
    private var refine: MeetingDetailRefinePresentation {
        MeetingDetailRefinePresentation(sceneValues.refinePhase)
    }
    var body: some View {
        Group {
            if let detail {
                loaded(detail)
            } else {
                ProgressView()
            }
        }
        .task { await model.observe() }
        .task(id: playbackTaskID) { await refreshPlayback() }
        .task(id: model.state.revision) { await refreshPresentation() }
        .onChange(of: sceneValues.pendingSeek) { _, _ in
            deliverPendingMeetingSeekIfPossible()
        }
        .onDisappear { model.invalidatePlayback() }
    }
}

private extension MeetingDetailView {
    private func loaded(_ detail: MeetingReviewReadModel) -> some View {
        MeetingDetailFlowHost(
            flow: flow,
            values: flowValues(detail),
            actions: flowActions(detail)
        ) {
            loadedBody(detail)
        }
        .onAppear { model.firstContentDidAppear() }
        .navigationTitle("Portavoz")
        .task(id: mirrorTaskID) { await loadMirrorAverageIfNeeded() }
    }

    private func loadedBody(_ detail: MeetingReviewReadModel) -> some View {
        let transcript = transcriptContent(detail)
        let accepted = detail.acceptedTranscriptContent(
            chapterTitles: model.state.chapterTitles)
        let structureProjection = detail.transcriptStructureProjection(
            current: transcript,
            accepted: accepted)
        return VStack(alignment: .leading, spacing: 12) {
            headerSection(detail)
            MeetingDetailOperationStatus(
                progress: refine.status ?? flow.applyingStatus,
                error: refine.error ?? flow.operationError ?? model.state.lastActionError)
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    MeetingDetailArtifactsSection {
                        summaryOrGenerate(detail)
                        commitmentInboxSection(detail)
                        notesSection(detail)
                    }
                    transcriptSection(
                        detail,
                        content: transcript,
                        structureProjection: structureProjection)
                        .layoutPriority(1)
                    playerSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                detailRail(detail, transcript: transcript)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(16)
        .frame(maxWidth: 1060, maxHeight: .infinity, alignment: .topLeading)
    }

    private func transcriptContent(_ detail: MeetingReviewReadModel) -> MeetingTranscriptContent {
        detail.transcriptContent(chapterTitles: model.state.chapterTitles)
    }

    private func transcriptSection(
        _ detail: MeetingReviewReadModel,
        content: MeetingTranscriptContent,
        structureProjection: MeetingTranscriptStructureProjection
    ) -> some View {
        MeetingTranscriptSection(
            values: MeetingTranscriptValues(
                content: content,
                speakers: detail.speakers,
                correctionContext: {
                    detail.transcriptCorrectionEditorContext(for: $0)
                },
                structureProjection: structureProjection,
                player: player,
                focusedRowID: playbackNavigation.focusedRowID,
                performanceScrollEnabled: sceneValues.performanceProfile
                    .shouldExerciseTranscriptScroll),
            actions: MeetingTranscriptActions(
                seekAndPlay: seekAndPlay,
                renameSpeaker: flow.presentRenameSpeaker,
                presentCorrection: { row in
                    flow.presentTranscriptCorrection(
                        editorContext: detail.transcriptCorrectionEditorContext(for: row),
                        structuralContext: structureProjection.context(for: row),
                        accepted: structureProjection.accepted,
                        baseTranscriptRevision: detail.meeting.transcriptRevision)
                },
                restructure: { operation in
                    await coordinator.restructureTranscript(
                        accepted: structureProjection.accepted,
                        revision: detail.meeting.transcriptRevision,
                        operation: operation)
                }))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var playerSection: some View {
        MeetingDetailPlayerSection(
            values: MeetingDetailPlayerValues(
                player: player,
                waveform: waveform,
                canCompressAudio: canCompressAudio,
                isCompressingAudio: model.state.isCompressingAudio,
                compressionMessage: model.state.audioCompressionMessage),
            actions: MeetingDetailPlayerActions(
                exportClip: coordinator.exportClip,
                compressAudio: compressAudio))
    }

    private func detailRail(
        _ detail: MeetingReviewReadModel,
        transcript: MeetingTranscriptContent
    ) -> some View {
        let trust = MeetingDetailTrustValues.make(
            detail: detail,
            skillReceipts: model.state.skillReceipts,
            presentation: presentation)
        return MeetingDetailRailSection(
            values: MeetingDetailRailValues(
                trust: trust,
                hasHealth: detail.segments.contains { $0.speakerID != nil },
                speakers: detail.speakers,
                segments: detail.segments,
                chapters: transcript.chapters,
                companionCards: detail.companionCards,
                companionFreshness: Dictionary(
                    uniqueKeysWithValues: detail.companionCards.map {
                        ($0.id, detail.companionFreshness($0))
                    }),
                transcriptRevision: detail.meeting.transcriptRevision,
                hasPlayback: player != nil,
                isRefreshingCompanion: flow.isRefreshingCompanion,
                presentation: presentation),
            actions: MeetingDetailRailActions(
                retryProcessing: coordinator.retryProcessing,
                refineSavedAudio: { coordinator.startRefine(detail) },
                openSupportDiagnostics: { sceneActions.openSettings(.data) },
                seekAndPlay: seekAndPlay,
                focusEvidence: focusEvidence,
                copyAnswer: coordinator.copyAnswer,
                refreshCompanionCards: { coordinator.refreshCompanionCards(detail) },
                removeCompanionCard: coordinator.removeCompanionCard))
    }

    @ViewBuilder
    private func summaryOrGenerate(_ detail: MeetingReviewReadModel) -> some View {
        if let summary {
            generatedDocumentSection(summary, detail: detail)
        } else if flow.isRegenerating {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Generating summary…").foregroundStyle(.secondary)
            }
        } else if !detail.segments.isEmpty {
            MeetingDetailSummaryPlaceholder(
                processingJobs: detail.processingJobs,
                generate: {
                    coordinator.regenerate(
                        language: summaryLanguage(in: detail),
                        detail: detail,
                        summary: nil)
                })
        }
    }

    private func generatedDocumentSection(
        _ summary: MeetingReviewSummary,
        detail: MeetingReviewReadModel
    ) -> some View {
        MeetingGeneratedDocumentSection(
            values: MeetingGeneratedDocumentValues(
                summary: summary,
                transcriptRevision: detail.meeting.transcriptRevision,
                segments: detail.segments,
                recipes: coordinator.recipes,
                summaryLanguage: summaryLanguage(summary.draft.language, in: detail),
                suggestedRecipe: model.state.suggestedRecipe,
                showThinSuggestion: coordinator.shouldSuggestThinSummary(
                    summary,
                    detail: detail),
                regenerating: flow.isRegenerating,
                alternateEngine: coordinator.alternateEngine,
                presentation: presentation,
                freshness: detail.summaryFreshness,
                decisionConfirmations: model.state.decisionConfirmations),
            actions: coordinator.generatedDocumentActions(
                summary: summary,
                detail: detail,
                focusEvidence: focusEvidence))
    }

    private func notesSection(_ detail: MeetingReviewReadModel) -> some View {
        MeetingDetailNotesSection(
            values: MeetingDetailNotesValues(
                notes: detail.notes,
                hasTranscript: !detail.segments.isEmpty,
                isEnhancing: flow.isEnhancingNotes,
                notice: flow.notesNotice,
                alternateEngine: coordinator.alternateEngine,
                presentation: presentation),
            actions: MeetingDetailNotesActions(
                enhance: { language, engine in
                    coordinator.enhanceNotes(
                        language: language,
                        engine: engine,
                        detail: detail)
                }))
    }

    private func commitmentInboxSection(
        _ detail: MeetingReviewReadModel
    ) -> some View {
        MeetingCommitmentInboxSection(
            values: MeetingCommitmentInboxValues(
                candidates: detail.commitmentInboxCandidates(),
                ownerChoices: detail.commitmentOwnerChoices(),
                presentation: presentation),
            actions: MeetingCommitmentInboxActions(
                focusEvidence: focusEvidence,
                confirm: coordinator.confirmCommitment,
                dismiss: coordinator.dismissCommitment,
                deferUntil: coordinator.deferCommitment))
    }

    private func headerSection(_ detail: MeetingReviewReadModel) -> some View {
        MeetingDetailHeaderSection(
            values: headerValues(detail),
            actions: MeetingDetailHeaderActions(
                renameMeeting: { flow.presentRenameMeeting(title: detail.meeting.title) },
                acceptTitleSuggestion: {
                    coordinator.acceptSuggestedTitle($0, meeting: detail.meeting)
                },
                dismissTitleSuggestion: coordinator.dismissSuggestedTitle,
                renameSpeaker: flow.presentRenameSpeaker,
                suggestNames: coordinator.suggestNames,
                acceptNameSuggestion: {
                    coordinator.acceptNameSuggestion($0, in: detail)
                },
                dismissNameSuggestion: coordinator.dismissNameSuggestion,
                acceptVoiceSuggestion: {
                    coordinator.acceptVoiceSuggestion($0, in: detail)
                },
                dismissVoiceSuggestion: coordinator.dismissVoiceSuggestion,
                acceptPersonOffer: acceptPersonOffer,
                dismissPersonOffer: { flow.personOffer = nil },
                acceptVoiceOffer: acceptVoiceOffer,
                dismissVoiceOffer: { flow.rememberedVoiceOffer = nil }),
            actionContent: { actionRow(detail) })
    }

    private func headerValues(_ detail: MeetingReviewReadModel) -> MeetingDetailHeaderValues {
        MeetingDetailHeaderValues(
            title: detail.meeting.title,
            date: presentation.meetingDate(detail.meeting.startedAt),
            duration: presentation.meetingDuration(
                startedAt: detail.meeting.startedAt,
                endedAt: detail.meeting.endedAt),
            segmentCount: presentation.segmentCount(detail.segments.count),
            titleSuggestion: model.state.suggestedTitle,
            speakers: detail.speakers,
            isSuggestingNames: model.state.isSuggestingNames,
            nameSuggestions: model.state.nameSuggestions,
            voiceSuggestions: model.state.voiceSuggestions,
            personOffer: flow.personOffer.flatMap { offer in
                offer.speaker.displayName.map {
                    MeetingDetailRememberOffer(name: $0, isBusy: flow.isFindingPerson)
                }
            },
            voiceOffer: flow.rememberedVoiceOffer.flatMap { offer in
                offer.displayName.map {
                    MeetingDetailRememberOffer(name: $0, isBusy: flow.isRememberingVoice)
                }
            })
    }

    private func actionRow(_ detail: MeetingReviewReadModel) -> some View {
        MeetingDetailActionSection(
            values: MeetingDetailActionValues(
                isRefining: refine.status != nil,
                hasAudio: detail.meeting.audioDirectory != nil,
                hasSummary: summary != nil,
                hasCorrections: !detail.correctionRevision.isAccepted,
                includeCorrectionProvenance: flow.includeCorrectionProvenance,
                skillOffers: model.state.skillOffers),
            actions: MeetingDetailActionActions(
                startRefine: { coordinator.startRefine(detail) },
                startSpanishRefine: {
                    coordinator.startRefine(detail, languagePolicy: .fixed(.spanish))
                },
                startEnglishRefine: {
                    coordinator.startRefine(detail, languagePolicy: .fixed(.english))
                },
                cancelRefine: sceneActions.cancelRefine,
                setIncludeCorrectionProvenance: {
                    flow.includeCorrectionProvenance = $0
                },
                export: { coordinator.handleExportAction($0, detail: detail) },
                deleteMeeting: { Task { await deleteMeeting() } },
                openSkillOffer: { coordinator.openSkillOffer($0, detail: detail) },
                dismissSkillOffer: coordinator.dismissSkillOffer,
                loadSkillOffers: coordinator.loadSkillOffers))
    }

    private func acceptPersonOffer() {
        guard let offer = flow.personOffer else { return }
        coordinator.findOrCreatePerson(for: offer)
    }

    private func acceptVoiceOffer() {
        guard let offer = flow.rememberedVoiceOffer else { return }
        coordinator.rememberVoice(of: offer)
    }

    private func deleteMeeting() async {
        if await coordinator.deleteMeeting() {
            sceneActions.closeDetail()
        }
    }

    private func flowValues(_ detail: MeetingReviewReadModel) -> MeetingDetailFlowValues {
        MeetingDetailFlowValues(
            detail: detail,
            summary: summary,
            refineDraft: refine.draft,
            mirror: MeetingDetailMirrorValues.qualifying(
                detail: detail,
                enabled: sceneValues.mirrorAfterMeeting,
                justRecorded: sceneValues.justRecorded,
                language: presentation.languageIdentifier,
                averageShare: flow.mirrorAverageShare),
            presentation: presentation)
    }

    private func flowActions(_ detail: MeetingReviewReadModel) -> MeetingDetailFlowActions {
        MeetingDetailFlowActions(
            renameMeeting: { coordinator.renameMeeting(detail.meeting, title: $0) },
            renameSpeaker: coordinator.renameSpeaker,
            createStructure: { recipe in
                coordinator.createStructure(
                    recipe,
                    detail: detail,
                    summary: summary)
            },
            publishGist: coordinator.publishGist,
            linkPerson: coordinator.linkPerson,
            clearRefine: sceneActions.clearRefine,
            applyRefine: {
                coordinator.applyRefineDraft($0, detail: detail, summary: summary)
            },
            copyText: coordinator.copyText,
            openURL: coordinator.openURL,
            openIntelligenceSettings: { sceneActions.openSettings(.intelligence) },
            dismissMirror: sceneActions.clearJustRecorded,
            showMirrorTrend: {
                sceneActions.clearJustRecorded()
                sceneActions.showInsights()
            },
            turnOffMirror: {
                sceneActions.disableMirrorAfterMeeting()
                sceneActions.clearJustRecorded()
            },
            confirmDecision: coordinator.confirmDecision,
            linkableTopics: model.state.linkableTopics,
            confirmSkill: coordinator.confirmSkill,
            prepareGitHubIssue: coordinator.prepareGitHubIssueSkill,
            confirmGitHubIssue: coordinator.confirmGitHubIssueSkill,
            correctTranscript: coordinator.correctTranscript,
            restructureTranscript: coordinator.restructureTranscript)
    }

    private func summaryLanguage(
        _ stored: String? = nil,
        in detail: MeetingReviewReadModel
    ) -> LanguageCode {
        coordinator.summaryLanguage(stored, spokenLanguage: detail.meeting.language)
    }

    private func focusEvidence(_ segment: TranscriptSegment) {
        guard let detail else { return }
        playbackNavigation.focusEvidence(
            segment,
            content: transcriptContent(detail),
            player: player)
    }

    private func refreshPresentation() async {
        guard detail != nil else { return }
        deliverPendingMeetingSeekIfPossible()
        await coordinator.loadPresentationSuggestions()
    }

    private func deliverPendingMeetingSeekIfPossible() {
        guard let detail,
              let request = sceneValues.pendingSeek,
              request.meetingID == meetingID
        else { return }
        let didApply = playbackNavigation.requestSeek(
            to: request.timestamp,
            content: transcriptContent(detail),
            player: player)
        if didApply {
            sceneActions.acknowledgePendingSeek(request.id)
        }
    }

    private func refreshPlayback() async {
        guard playbackTaskID != nil else { return }
        await coordinator.loadPlayback()
        guard !Task.isCancelled else { return }
        deliverPendingMeetingSeekIfPossible()
        playbackNavigation.applyPendingSeek(to: player)
        playbackNavigation.runPerformanceSeekIfRequested(
            profile: sceneValues.performanceProfile,
            player: player)
    }

    private func seekAndPlay(_ seconds: TimeInterval) {
        guard let detail else { return }
        playbackNavigation.seekAndPlay(
            seconds,
            content: transcriptContent(detail),
            player: player)
    }

    private var canCompressAudio: Bool {
        !model.state.isCompressingAudio
            && model.state.playback?.canCompressAudio == true
    }

    private func compressAudio() {
        Task {
            await coordinator.compressAudio()
            playbackNavigation.applyPendingSeek(to: player)
        }
    }

    private var mirrorTaskID: MeetingID? { sceneValues.justRecorded }

    private func loadMirrorAverageIfNeeded() async {
        guard sceneValues.mirrorAfterMeeting,
              sceneValues.justRecorded == meetingID,
              flow.mirrorAverageLoadedFor != meetingID
        else { return }
        flow.mirrorAverageLoadedFor = meetingID
        flow.mirrorAverageShare = await sceneActions.averageMyShare()
    }
}
