import ApplicationKit
import IntegrationsKit
import IntelligenceKit
import PortavozCore
import TranscriptionKit
import UniformTypeIdentifiers

extension MeetingDetailCoordinator {
    var recipes: [Recipe] {
        CustomRecipeStore.all()
    }

    func createStructure(
        _ recipe: Recipe,
        detail: MeetingReviewReadModel,
        summary: MeetingReviewSummary?
    ) {
        CustomRecipeStore.upsert(recipe)
        regenerate(
            language: summaryLanguage(
                summary?.draft.language,
                spokenLanguage: detail.meeting.language),
            recipe: recipe,
            detail: detail,
            summary: summary)
    }

    func handleExportAction(
        _ action: MeetingDetailExportAction,
        detail: MeetingReviewReadModel
    ) {
        switch action {
        case .recap:
            flow.sheet = .recap
        case .markdown:
            export(as: .markdown)
        case .pdf:
            export(as: .pdf)
        case .srt:
            export(as: .srt)
        case .vtt:
            export(as: .vtt)
        case .meetingBundle(let includeAudio):
            Task { await exportBundle(detail, includeAudio: includeAudio) }
        case .gist:
            flow.dialog = .publishGist
        }
    }

    func generatedDocumentActions(
        summary: MeetingReviewSummary,
        detail: MeetingReviewReadModel,
        focusEvidence: @escaping @MainActor (TranscriptSegment) -> Void
    ) -> MeetingGeneratedDocumentActions {
        MeetingGeneratedDocumentActions(
            copy: { format in
                let exportFormat: MeetingExporter.SummaryFormat = switch format {
                case .plainText: .plainText
                case .markdown: .markdown
                case .slack: .slack
                }
                copySummary(summary.draft, speakers: detail.speakers, as: exportFormat)
            },
            regenerate: { language, engine, recipe in
                regenerate(
                    language: language,
                    engine: engine,
                    recipe: recipe,
                    detail: detail,
                    summary: summary)
            },
            createStructure: { flow.sheet = .newStructure },
            dismissRecipeSuggestion: model.dismissSuggestedRecipe,
            dismissThinSuggestion: {
                model.dismissThinSummarySuggestion(version: summary.version)
            },
            setActionItem: { item, done in
                Task { await model.send(.setActionItem(item.id, done: done)) }
            },
            focusEvidence: focusEvidence,
            setClaimFeedback: { claimID, feedback in
                let effect = await model.send(.setSummaryClaimFeedback(claimID, feedback))
                guard case .summaryClaimFeedbackSaved(let savedID) = effect else {
                    return false
                }
                return savedID == claimID
            },
            confirmDecision: { evidence, statement in
                // Both are required or the affordance was never offered: the
                // confirm button renders only over current, resolvable
                // evidence.
                guard let segmentID = evidence.evidenceSegmentIDs.first,
                      let revision = evidence.sourceTranscriptRevision
                else { return }
                flow.decisionConfirmTarget = MeetingDetailFlowState
                    .DecisionConfirmTarget(
                        observationID: evidence.id,
                        statement: statement,
                        meetingID: detail.meeting.id,
                        evidenceSegmentID: segmentID,
                        sourceTranscriptRevision: revision)
                flow.sheet = .confirmDecision
            },
            decisionsDidAppear: {
                Task { await model.send(.loadDecisionConfirmations) }
            })
    }

    /// Runs the composed gesture and reports success so the sheet can close
    /// only when the confirmation actually landed.
    func confirmDecision(
        _ target: MeetingDetailFlowState.DecisionConfirmTarget,
        _ choice: DecisionTopicChoice
    ) async -> Bool {
        let effect = await model.send(.confirmDecision(
            ConfirmDecisionAboutTopicRequest(
                observationID: target.observationID,
                meetingID: target.meetingID,
                evidenceSegmentID: target.evidenceSegmentID,
                sourceTranscriptRevision: target.sourceTranscriptRevision,
                topic: choice)))
        guard case .decisionConfirmed = effect else { return false }
        return true
    }

    func shouldSuggestThinSummary(
        _ summary: MeetingReviewSummary,
        detail: MeetingReviewReadModel
    ) -> Bool {
        guard !flow.isRegenerating,
              detail.summaryFreshness == .current,
              sceneValues.summaryEngine != .mlx,
              sceneValues.mlxDownloaded,
              model.state.dismissedThinSummaryVersion != summary.version,
              let ended = detail.meeting.endedAt
        else { return false }
        return ThinSummaryPolicy.isThin(
            summaryCharacters: summary.draft.markdown.count,
            actionItems: summary.draft.actionItems.count,
            meetingSeconds: ended.timeIntervalSince(detail.meeting.startedAt))
    }

    var alternateEngine: MeetingGeneratedDocumentAlternateEngine? {
        switch sceneValues.summaryEngine {
        case .appleOnDevice:
            if let model = sceneValues.ollamaModel {
                return MeetingGeneratedDocumentAlternateEngine(
                    engine: .ollama,
                    label: "Regenerar con Ollama · \(model)")
            }
            return nil
        case .ollama, .mlx:
            if sceneValues.appleSummaryAvailable {
                return MeetingGeneratedDocumentAlternateEngine(
                    engine: .appleOnDevice,
                    label: "Regenerar con Apple (on-device)")
            }
            return nil
        }
    }

    func summaryLanguage(
        _ stored: String? = nil,
        spokenLanguage: String?
    ) -> LanguageCode {
        LanguageCode(stored)
            ?? MeetingLanguagePreferences.resolvedSummaryLanguage(
                spokenLanguage: spokenLanguage)
    }

    func regenerate(
        language: LanguageCode,
        engine: SummaryEngine? = nil,
        recipe: Recipe? = nil,
        detail: MeetingReviewReadModel,
        summary: MeetingReviewSummary?,
        segments: [TranscriptSegment]? = nil,
        speakers: [Speaker]? = nil,
        sourceTranscriptRevision: Int? = nil
    ) {
        guard !flow.isRegenerating else { return }
        model.dismissSuggestedRecipe()
        let material: MeetingTranscriptGenerationMaterial
        if let segments {
            material = MeetingTranscriptGenerationMaterial(
                segments: segments,
                sourceSegmentIDsByGeneratedID: Dictionary(
                    uniqueKeysWithValues: segments.map { ($0.id, [$0.id]) }),
                baseTranscriptRevision: sourceTranscriptRevision
                    ?? detail.meeting.transcriptRevision,
                correctionRevision: .accepted)
        } else {
            material = detail.transcriptGenerationMaterial()
        }
        let sourceSpeakers = speakers ?? detail.speakers
        flow.isRegenerating = true
        let activeRecipe = recipe
            ?? summary.flatMap { CustomRecipeStore.byID($0.draft.recipeID) }
            ?? .general
        Task {
            defer { flow.isRegenerating = false }
            let request = RegenerateSummaryRequest(
                meetingID: meetingID,
                segments: material.segments,
                speakers: sourceSpeakers,
                recipe: activeRecipe,
                targetLanguage: language.identifier,
                sourceTranscriptRevision: material.baseTranscriptRevision,
                sourceCorrectionRevision: material.correctionRevision,
                providerOverride: engine,
                evidenceSourceIDsByGeneratedID: material.sourceSegmentIDsByGeneratedID)
            await applyRegenerateResult(await sceneActions.regenerateSummary(request))
        }
    }

    func enhanceNotes(
        language: LanguageCode,
        engine: SummaryEngine? = nil,
        detail: MeetingReviewReadModel
    ) {
        guard !flow.isEnhancingNotes else { return }
        flow.isEnhancingNotes = true
        flow.notesNotice = nil
        Task {
            defer { flow.isEnhancingNotes = false }
            let request = EnhanceMeetingNotesRequest(
                meetingID: meetingID,
                segments: detail.segments,
                speakers: detail.speakers,
                targetLanguage: language.identifier,
                providerOverride: engine)
            applyEnhanceNotesResult(await sceneActions.enhanceNotes(request))
        }
    }

    func startRefine(
        _ detail: MeetingReviewReadModel,
        languagePolicy: TranscriptLanguagePolicy? = nil
    ) {
        sceneActions.startRefine(detail, languagePolicy)
    }

    func applyRefineDraft(
        _ draft: RefineDraft,
        detail: MeetingReviewReadModel,
        summary: MeetingReviewSummary?
    ) {
        sceneActions.clearRefine()
        flow.applyingStatus = L10n.text("Applying the refined transcript…")
        Task {
            defer { flow.applyingStatus = nil }
            do {
                let result = try await sceneActions.applyRefine(
                    ApplyRefinedMeetingRequest(meetingID: meetingID, draft: draft) { phase in
                        if phase == .refreshingCompanion {
                            await MainActor.run {
                                flow.applyingStatus = L10n.text(
                                    "Re-checking the Apuntador's answers…")
                            }
                        }
                    })
                if result.companion == .persistenceFailed {
                    flow.operationError = L10n.text(
                        "The transcript was refined, but Apuntador cards could not be refreshed.")
                }
                await model.send(.searchableContentChanged)
                regenerate(
                    language: summaryLanguage(
                        summary?.draft.language,
                        spokenLanguage: detail.meeting.language),
                    detail: detail,
                    summary: summary,
                    segments: draft.segments,
                    speakers: draft.speakers,
                    sourceTranscriptRevision: result.transcriptRevision)
            } catch MeetingDetailRefineApplyError.staleDraft {
                flow.operationError = L10n.text(
                    "The transcript changed while you reviewed this draft. Run refine again.")
            } catch {
                flow.operationError = L10n.format(
                    "Could not apply refine: %@",
                    UseCaseErrorMessages.describe(error))
            }
        }
    }

    func publishGist() {
        Task {
            switch await model.send(.publishGist(options: documentOptions)) {
            case .gistPublished(let url):
                flow.alert = .gistPublished(url)
            case .operationFailed(let message):
                flow.alert = .failure(message)
            default:
                break
            }
        }
    }

    private enum ExportFormat {
        case markdown
        case pdf
        case srt
        case vtt
    }

    private func exportBundle(
        _ detail: MeetingReviewReadModel,
        includeAudio: Bool
    ) async {
        guard let data = try? await sceneActions.exportBundle(includeAudio) else {
            flow.alert = .failure(L10n.text("Could not encode the meeting file."))
            return
        }
        flow.export = MeetingDetailExportRoute(
            document: ExportDocument(data: data),
            contentType: .meetingBundle,
            defaultFilename: "\(detail.meeting.title).portavoz")
    }

    private func export(as format: ExportFormat) {
        Task {
            let documentFormat: MeetingDocumentFormat = switch format {
            case .markdown: .markdown
            case .pdf: .pdf
            case .srt: .srt
            case .vtt: .vtt
            }
            let effect = await model.send(.prepareDocument(
                documentFormat,
                options: documentOptions))
            switch effect {
            case .documentPrepared(let document):
                let contentType: UTType = switch format {
                case .markdown: .plainText
                case .pdf: .pdf
                case .srt: .portavozSRT
                case .vtt: .portavozVTT
                }
                flow.export = MeetingDetailExportRoute(
                    document: ExportDocument(data: document.data),
                    contentType: contentType,
                    defaultFilename: document.filename)
            case .operationFailed(let message):
                flow.alert = .failure(message)
            default:
                break
            }
        }
    }

    private var documentOptions: MeetingDocumentOptions {
        MeetingDocumentOptions(
            includeCorrectionProvenance: flow.includeCorrectionProvenance)
    }

    private func copySummary(
        _ draft: SummaryDraft,
        speakers: [Speaker],
        as format: MeetingExporter.SummaryFormat
    ) {
        let text = MeetingExporter.summary(draft, speakers: speakers, format: format)
        copyText(text)
    }

    private func applyRegenerateResult(_ result: SummaryRegenerationResult) async {
        switch result {
        case .completed:
            await model.send(.searchableContentChanged)
        case .unchanged(let version):
            flow.alert = .summaryNotice(
                L10n.format(
                    // One-line UI notice.
                    // swiftlint:disable:next line_length
                    "Summary v%d already matches this material — there is nothing to regenerate. Change the transcript, notes, or vocabulary to produce a new one.",
                    version))
        case .unavailable(.requiresMacOS26):
            flow.alert = .summarySetup(.appleRequiresMacOS26)
        case .unavailable(.appleOnDevice(let reason)):
            flow.alert = .summarySetup(.appleUnavailable(reason))
        case .unavailable(.ollamaModelNotSelected):
            flow.alert = .summarySetup(.ollamaModelNotSelected)
        case .unavailable(.mlxModelNotDownloaded):
            flow.alert = .summarySetup(.mlxModelNotDownloaded)
        case .generationFailed(.localModelNotice):
            flow.alert = .summarySetup(.localEngineFailed)
        case .generationFailed(.silent):
            break
        }
    }

    private func applyEnhanceNotesResult(_ result: EnhanceMeetingNotesResult) {
        switch result {
        case .completed(persisted: true):
            break
        case .completed(persisted: false):
            flow.notesNotice = L10n.text("The enhanced notes could not be saved. Try again.")
        case .unchanged:
            flow.notesNotice = L10n.text(
                // One-line UI notice.
                // swiftlint:disable:next line_length
                "Your enhanced notes already match this material — change the transcript or your notes to produce new ones.")
        case .noNotes:
            flow.notesNotice = L10n.text("Add notes during the recording to enhance them here.")
        case .unavailable(.requiresMacOS26):
            flow.alert = .summarySetup(.appleRequiresMacOS26)
        case .unavailable(.appleOnDevice(let reason)):
            flow.alert = .summarySetup(.appleUnavailable(reason))
        case .unavailable(.ollamaModelNotSelected):
            flow.alert = .summarySetup(.ollamaModelNotSelected)
        case .unavailable(.mlxModelNotDownloaded):
            flow.alert = .summarySetup(.mlxModelNotDownloaded)
        case .generationFailed(.localModelNotice):
            flow.alert = .summarySetup(.localEngineFailed)
        case .generationFailed(.silent):
            flow.notesNotice = L10n.text(
                "Enhancing didn't work this time. Try again in a moment.")
        }
    }
}
