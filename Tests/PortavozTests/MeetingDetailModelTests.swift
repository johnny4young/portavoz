import ApplicationKit
import Foundation
import PortavozCore
import XCTest

@testable import portavoz_app

@MainActor
final class MeetingDetailModelTests: XCTestCase {
    func testObservationPublishesOneCompleteReviewProjection() async throws {
        let fixture = MeetingDetailModelFixture()
        let client = MeetingDetailModelClientFake(updates: fixture.updates)
        let model = MeetingDetailModel(meetingID: fixture.meeting.id, client: client)

        await model.observe()

        XCTAssertEqual(model.state.phase, .loaded)
        XCTAssertEqual(model.state.readModel?.meeting.id, fixture.meeting.id)
        XCTAssertEqual(model.state.readModel?.speakers.map(\.id), [fixture.speaker.id])
        XCTAssertEqual(model.state.readModel?.segments.map(\.id), [fixture.segment.id])
        XCTAssertEqual(model.state.readModel?.summary?.version, 2)
        XCTAssertEqual(model.state.readModel?.companionCards.map(\.id), [fixture.card.id])
        XCTAssertEqual(
            model.state.readModel?.privacyReceipt?.status,
            .allContentStayedOnDevice)
        XCTAssertTrue(model.state.readModel?.processingJobs.isEmpty == true)
        XCTAssertEqual(client.calls, [.observe(fixture.meeting.id)])
    }

    func testPartialFailurePreservesHealthySections() async {
        let fixture = MeetingDetailModelFixture()
        let client = MeetingDetailModelClientFake(updates: [
            .core(fixture.core),
            .failed(.summary),
            .companionCards([fixture.card]),
            .privacyReceipt(fixture.receipt),
            .processingJobs([]),
        ])
        let model = MeetingDetailModel(meetingID: fixture.meeting.id, client: client)

        await model.observe()

        XCTAssertEqual(model.state.phase, .degraded(failures: 1))
        XCTAssertEqual(model.state.readModel?.segments.map(\.id), [fixture.segment.id])
        XCTAssertNil(model.state.readModel?.summary)
        XCTAssertEqual(model.state.readModel?.companionCards.map(\.id), [fixture.card.id])
    }

    func testMissingMeetingIsDistinctFromReadFailure() async {
        let fixture = MeetingDetailModelFixture()
        let missingClient = MeetingDetailModelClientFake(updates: [
            .core(nil), .summary(nil), .companionCards([]), .privacyReceipt(nil),
            .processingJobs([]),
        ])
        let missing = MeetingDetailModel(
            meetingID: fixture.meeting.id,
            client: missingClient)
        await missing.observe()

        let failedClient = MeetingDetailModelClientFake(
            updates: MeetingReviewSection.allCases.map(MeetingReviewUpdate.failed))
        let failed = MeetingDetailModel(
            meetingID: fixture.meeting.id,
            client: failedClient)
        await failed.observe()

        XCTAssertEqual(missing.state.phase, .missing)
        XCTAssertNil(missing.state.readModel)
        XCTAssertEqual(failed.state.phase, .failed)
        XCTAssertNil(failed.state.readModel)
    }

    func testLaterUpdateReplacesOnlyItsProjection() async {
        let fixture = MeetingDetailModelFixture()
        let replacement = MeetingReviewSummary(
            draft: SummaryDraft(
                meetingID: fixture.meeting.id,
                recipeID: Recipe.standup.id,
                language: "es",
                markdown: "## Nuevo",
                actionItems: []),
            version: 1)
        let client = MeetingDetailModelClientFake(updates: fixture.updates + [
            .summary(replacement),
        ])
        let model = MeetingDetailModel(meetingID: fixture.meeting.id, client: client)

        await model.observe()

        XCTAssertEqual(model.state.readModel?.summary?.draft.recipeID, Recipe.standup.id)
        XCTAssertEqual(model.state.readModel?.summary?.version, 1)
        XCTAssertEqual(model.state.readModel?.segments.map(\.id), [fixture.segment.id])
        XCTAssertEqual(model.state.readModel?.companionCards.map(\.id), [fixture.card.id])
        XCTAssertEqual(model.state.revision, 6)
    }

    func testMutationActionsOwnPersistenceEffectsAndSearchInvalidation() async {
        let fixture = MeetingDetailModelFixture()
        let client = MeetingDetailModelClientFake(updates: [], person: fixture.person)
        let model = MeetingDetailModel(meetingID: fixture.meeting.id, client: client)

        await model.send(.renameMeeting(fixture.meeting, title: "Weekly planning"))
        let nameEffect = await model.send(
            .acceptNameSuggestion(fixture.speaker, name: "Ana"))
        let voiceEffect = await model.send(
            .acceptVoiceSuggestion(fixture.speaker, name: "Bea"))
        let renameEffect = await model.send(
            .renameSpeaker(fixture.speaker, name: "Carla"))
        let peopleEffect = await model.send(
            .findCanonicalPeople(fixture.speaker, source: .manualName))
        let linkEffect = await model.send(
            .linkCanonicalPerson(
                fixture.speaker,
                source: .manualName,
                selection: .existing(fixture.person.id)))
        await model.send(.setActionItem(fixture.actionItem.id, done: true))
        let feedbackEffect = await model.send(
            .setSummaryClaimFeedback(fixture.claimID, .unsupported))
        await model.send(.removeCompanionCard(fixture.card.id))
        await model.send(.searchableContentChanged)
        let deleteEffect = await model.send(.deleteMeeting)
        await model.send(.retryProcessing)

        XCTAssertEqual(client.calls, [
            .renameMeeting("Weekly planning"),
            .renameSpeaker("Ana"),
            .renameSpeaker("Bea"),
            .renameSpeaker("Carla"),
            .findPeople("Ana"),
            .linkPerson(fixture.speaker.id, fixture.person.id),
            .setActionItem(fixture.actionItem.id, true),
            .setClaimFeedback(fixture.claimID, .unsupported, fixture.meeting.id),
            .deleteCompanion(fixture.card.id),
            .deleteMeeting(fixture.meeting.id),
            .retryProcessing(fixture.meeting.id),
        ])
        XCTAssertEqual(client.searchReindexRequests, 8)
        XCTAssertEqual(effectSpeakerName(nameEffect), "Ana")
        XCTAssertEqual(effectSpeakerName(voiceEffect), "Bea")
        XCTAssertEqual(effectSpeakerName(renameEffect), "Carla")
        guard case .canonicalPeopleFound(_, .manualName, let people) = peopleEffect else {
            return XCTFail("candidate lookup must preserve its explicit source")
        }
        XCTAssertEqual(people.map(\.id), [fixture.person.id])
        guard case .canonicalPersonLinked(let link) = linkEffect else {
            return XCTFail("explicit linking must preserve its result")
        }
        XCTAssertEqual(link.person.id, fixture.person.id)
        guard case .summaryClaimFeedbackSaved(let claimID) = feedbackEffect else {
            return XCTFail("claim feedback must preserve its successful mutation effect")
        }
        XCTAssertEqual(claimID, fixture.claimID)
        guard case .meetingDeleted(let id) = deleteEffect else {
            return XCTFail("delete must preserve the navigation effect")
        }
        XCTAssertEqual(id, fixture.meeting.id)
        XCTAssertNil(model.state.lastActionError)
    }

    func testDocumentNameAndVoiceActionsStayBehindTheFeatureOwner() async {
        let fixture = MeetingDetailModelFixture()
        let client = MeetingDetailModelClientFake(updates: [])
        let model = MeetingDetailModel(meetingID: fixture.meeting.id, client: client)

        let document = await model.send(.prepareDocument(.markdown))
        let gist = await model.send(.publishGist)
        let names = await model.send(.loadNameSuggestions)
        await model.send(.loadVoiceSuggestions)
        await model.send(.loadVoiceSuggestions)
        let offer = await model.send(.checkVoiceMemoryOffer(name: "Ana"))
        let remembered = await model.send(.rememberVoice(fixture.speaker.id))
        _ = await model.send(.acceptVoiceSuggestion(fixture.speaker, name: "Ana"))

        guard case .documentPrepared(let prepared) = document else {
            return XCTFail("the native save surface must receive a prepared document effect")
        }
        XCTAssertEqual(prepared.filename, "planning.md")
        XCTAssertEqual(String(decoding: prepared.data, as: UTF8.self), "prepared")
        guard case .gistPublished(let url) = gist else {
            return XCTFail("explicit publication must return its URL as an effect")
        }
        XCTAssertEqual(url.absoluteString, "https://gist.github.com/portavoz/test")
        guard case .nameSuggestionsLoaded = names else {
            return XCTFail("name generation must return a typed loaded effect")
        }
        // Voice evidence outranks the text proposal for the same label (the
        // text chip is suppressed), and the accepted voice suggestion above
        // consumed its own chip — both arrays end empty.
        XCTAssertEqual(model.state.nameSuggestions.map(\.name), [])
        XCTAssertEqual(model.state.voiceSuggestions.map(\.name), [])
        XCTAssertFalse(model.state.isSuggestingNames)
        guard case .voiceMemoryOfferChecked(true) = offer else {
            return XCTFail("the feature owner must preserve duplicate-offer admission")
        }
        guard case .voiceRemembered = remembered else {
            return XCTFail("the feature owner must preserve explicit voice-memory success")
        }
        XCTAssertTrue(model.state.voiceSuggestions.isEmpty)
        XCTAssertEqual(client.calls, [
            .prepareDocument(fixture.meeting.id, .markdown),
            .publishGist(fixture.meeting.id),
            .loadNameSuggestions(fixture.meeting.id),
            .loadVoiceSuggestions(fixture.meeting.id),
            .checkVoiceMemoryOffer("Ana"),
            .rememberVoice(fixture.meeting.id, fixture.speaker.id),
            .renameSpeaker("Ana"),
        ])
    }

    func testDocumentNameAndVoiceEffectsPreserveFailureAndDegradationPolicy() async {
        let fixture = MeetingDetailModelFixture()
        let client = MeetingDetailModelClientFake(updates: [])
        client.failures = [
            .prepareDocument, .publishGist, .loadNameSuggestions, .loadVoiceSuggestions,
        ]
        client.canRememberVoiceResult = false
        client.rememberVoiceResult = .insufficientAudio
        let model = MeetingDetailModel(meetingID: fixture.meeting.id, client: client)

        let document = await model.send(.prepareDocument(.pdf))
        let gist = await model.send(.publishGist)
        let names = await model.send(.loadNameSuggestions)
        await model.send(.loadVoiceSuggestions)
        let offer = await model.send(.checkVoiceMemoryOffer(name: "Ana"))
        let remembered = await model.send(.rememberVoice(fixture.speaker.id))

        guard case .operationFailed(let documentError) = document else {
            return XCTFail("document failure must remain visible")
        }
        XCTAssertTrue(documentError.contains("prepareDocument"))
        guard case .operationFailed(let gistError) = gist else {
            return XCTFail("Gist failure must remain visible")
        }
        XCTAssertTrue(gistError.contains("publishGist"))
        guard case .operationFailed(let nameError) = names else {
            return XCTFail("name-generation failure must remain visible")
        }
        XCTAssertTrue(nameError.contains("loadNameSuggestions"))
        XCTAssertTrue(model.state.nameSuggestions.isEmpty)
        XCTAssertFalse(model.state.isSuggestingNames)
        XCTAssertTrue(model.state.voiceSuggestions.isEmpty)
        guard case .voiceMemoryOfferChecked(false) = offer else {
            return XCTFail("duplicate-offer admission must remain explicit")
        }
        guard case .voiceMemoryInsufficientAudio = remembered else {
            return XCTFail("insufficient audio must remain a typed effect")
        }
    }

    func testAudioPreparationAndClipExportStayBehindTheFeatureOwner() async {
        let fixture = MeetingDetailModelFixture()
        var meeting = fixture.meeting
        meeting.audioDirectory = "Audio/meeting"
        let client = MeetingDetailModelClientFake(updates: [
            .core(MeetingReviewCore(
                meeting: meeting,
                speakers: [fixture.speaker],
                segments: [fixture.segment])),
            .summary(fixture.summary),
            .companionCards([fixture.card]),
            .privacyReceipt(fixture.receipt),
            .processingJobs([]),
        ])
        let model = MeetingDetailModel(meetingID: meeting.id, client: client)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-clip-\(UUID().uuidString).m4a")

        await model.observe()
        await model.send(.loadPlayback)
        await model.send(.loadPlayback)
        let exported = await model.send(.exportAudioClip(1...2, to: destination))

        guard case .audioClipExported(let url) = exported else {
            return XCTFail("successful export must return a typed destination effect")
        }
        XCTAssertEqual(url, destination)
        XCTAssertEqual(client.calls, [
            .observe(meeting.id),
            .preparePlayback("Audio/meeting"),
            .exportAudioClip("Audio/meeting", 1...2, destination),
        ])

        client.failures.insert(.exportAudioClip)
        let failed = await model.send(.exportAudioClip(1...2, to: destination))
        guard case .operationFailed(let message) = failed else {
            return XCTFail("clip failure must remain visible to presentation")
        }
        XCTAssertTrue(message.contains("exportAudioClip"))
    }

    func testCanceledAudioPreparationCanRetryForTheSameDirectory() async {
        let fixture = MeetingDetailModelFixture()
        var meeting = fixture.meeting
        meeting.audioDirectory = "Audio/meeting"
        let client = MeetingDetailModelClientFake(updates: [
            .core(MeetingReviewCore(
                meeting: meeting,
                speakers: [fixture.speaker],
                segments: [fixture.segment])),
            .summary(fixture.summary),
            .companionCards([fixture.card]),
            .privacyReceipt(fixture.receipt),
            .processingJobs([]),
        ])
        client.playbackCancellationsRemaining = 1
        let model = MeetingDetailModel(meetingID: meeting.id, client: client)

        await model.observe()
        await model.send(.loadPlayback)
        await model.send(.loadPlayback)

        XCTAssertEqual(
            client.calls.filter { call in
                if case .preparePlayback = call { return true }
                return false
            }.count,
            2,
            "cancellation must not consume the directory-scoped playback attempt")
    }

    func testMutationFailuresPreserveSilentAndVisiblePolicies() async {
        let fixture = MeetingDetailModelFixture()
        let client = MeetingDetailModelClientFake(updates: [])
        let model = MeetingDetailModel(meetingID: fixture.meeting.id, client: client)
        _ = await model.send(.loadNameSuggestions)
        await model.send(.loadVoiceSuggestions)
        client.failures = Set(MeetingDetailModelFailure.allCases)

        await model.send(.renameMeeting(fixture.meeting, title: "Ignored failure"))
        let nameEffect = await model.send(
            .acceptNameSuggestion(fixture.speaker, name: "Ana"))
        let voiceEffect = await model.send(
            .acceptVoiceSuggestion(fixture.speaker, name: "Bea"))
        await model.send(.setActionItem(fixture.actionItem.id, done: true))
        let deleteEffect = await model.send(.deleteMeeting)

        guard case .operationFailed(let nameMessage) = nameEffect else {
            return XCTFail("a failed name confirmation must stay visible")
        }
        XCTAssertEqual(nameMessage, L10n.text("Could not apply this name suggestion."))
        guard case .operationFailed(let voiceMessage) = voiceEffect else {
            return XCTFail("a failed voice confirmation must stay visible")
        }
        XCTAssertEqual(voiceMessage, L10n.text("Could not apply this voice suggestion."))
        // Same voice-wins policy: only the voice chip remains for S1.
        XCTAssertEqual(model.state.nameSuggestions.map(\.name), [])
        XCTAssertEqual(model.state.voiceSuggestions.map(\.name), ["Ana"])
        guard case .meetingDeleted = deleteEffect else {
            return XCTFail("best-effort delete must preserve its navigation effect")
        }
        XCTAssertEqual(
            model.state.lastActionError,
            L10n.text("Could not apply this voice suggestion."))
        XCTAssertEqual(client.searchReindexRequests, 2)
        let feedbackEffect = await model.send(
            .setSummaryClaimFeedback(fixture.claimID, .unsupported))
        XCTAssertNil(feedbackEffect)
        XCTAssertEqual(
            model.state.lastActionError,
            L10n.text("Could not save this summary feedback. The summary may have changed."))

        let renameEffect = await model.send(
            .renameSpeaker(fixture.speaker, name: "Carla"))
        XCTAssertNil(renameEffect)
        XCTAssertEqual(
            model.state.lastActionError,
            L10n.format(
                "Could not rename: %@",
                MeetingDetailModelFailure.renameSpeaker.localizedDescription))
        XCTAssertEqual(client.searchReindexRequests, 2)

        await model.send(.removeCompanionCard(fixture.card.id))
        XCTAssertEqual(
            model.state.lastActionError,
            L10n.text("Could not remove the card."))
        XCTAssertEqual(client.searchReindexRequests, 2)

        await model.send(.retryProcessing)
        XCTAssertEqual(
            model.state.lastActionError,
            L10n.text(
                "Could not restart processing. Export a support file from Settings and try again."))
    }

    func testMetadataSuggestionsAreOwnedByTheModelAndRunOncePerCompletedInput() async {
        let fixture = MeetingDetailModelFixture()
        let later = TranscriptSegment(
            meetingID: fixture.meeting.id,
            speakerID: fixture.speaker.id,
            channel: .system,
            text: "Ahora revisamos los siguientes pasos del proyecto.",
            startTime: 310,
            endTime: 313,
            isFinal: true)
        let segments = [fixture.segment, later]
        let chapterStarts = ChapterExtractor.chapters(from: segments).map(\.startTime)
        XCTAssertEqual(chapterStarts, [0, 310])
        let client = MeetingDetailModelClientFake(
            updates: metadataUpdates(
                fixture,
                title: "2026-07-18 09.00 Meeting",
                segments: segments))
        client.metadataSuggestionsResult = MeetingReviewMetadataSuggestions(
            chapterTitles: Dictionary(
                uniqueKeysWithValues: chapterStarts.map { ($0, "Chapter \($0)") }),
            meetingTitle: "Plan del trimestre",
            recipe: .standup)
        let model = MeetingDetailModel(meetingID: fixture.meeting.id, client: client)

        await model.observe()
        await model.send(.loadMetadataSuggestions)
        await model.send(.loadMetadataSuggestions)

        XCTAssertEqual(model.state.suggestedTitle, "Plan del trimestre")
        XCTAssertEqual(model.state.suggestedRecipe?.id, Recipe.standup.id)
        XCTAssertEqual(Set(model.state.chapterTitles.keys), Set(chapterStarts))
        XCTAssertEqual(client.calls, [
            .observe(fixture.meeting.id),
            .loadMetadataSuggestions(
                suggestTitle: true,
                suggestRecipe: true,
                titledChapterStarts: []),
        ])

        model.dismissSuggestedRecipe()
        XCTAssertNil(model.state.suggestedRecipe)
        var meeting = fixture.meeting
        meeting.title = "2026-07-18 09.00 Meeting"
        await model.send(.renameMeeting(meeting, title: "Plan del trimestre"))
        XCTAssertNil(model.state.suggestedTitle)
        XCTAssertNil(model.state.lastActionError)
        XCTAssertEqual(client.searchReindexRequests, 1)
    }

    func testDocumentFailuresUseLocalizedPresentationMessages() async {
        let fixture = MeetingDetailModelFixture()
        let client = MeetingDetailModelClientFake(updates: [])
        client.prepareDocumentError = ExportMeetingDocumentError.meetingNotFound
        client.publishGistError = ExportMeetingDocumentError.meetingNotFound
        let model = MeetingDetailModel(meetingID: fixture.meeting.id, client: client)

        let document = await model.send(.prepareDocument(.markdown))
        let gist = await model.send(.publishGist)

        guard case .operationFailed(let documentMessage) = document else {
            return XCTFail("a missing export meeting must produce a visible failure")
        }
        guard case .operationFailed(let gistMessage) = gist else {
            return XCTFail("a missing gist meeting must produce a visible failure")
        }
        let expected = L10n.text("The meeting could not be found.")
        XCTAssertEqual(documentMessage, expected)
        XCTAssertEqual(gistMessage, expected)
    }

    func testMetadataCancellationRetriesInsteadOfConsumingOneShotSuggestions() async {
        let fixture = MeetingDetailModelFixture()
        let client = MeetingDetailModelClientFake(
            updates: metadataUpdates(
                fixture,
                title: "2026-07-18 Meeting",
                segments: [fixture.segment]))
        client.metadataCancellationsRemaining = 1
        client.metadataSuggestionsResult = MeetingReviewMetadataSuggestions(
            meetingTitle: "Plan del trimestre",
            recipe: .planning)
        let model = MeetingDetailModel(meetingID: fixture.meeting.id, client: client)

        await model.observe()
        await model.send(.loadMetadataSuggestions)
        XCTAssertNil(model.state.suggestedTitle)
        XCTAssertNil(model.state.suggestedRecipe)

        await model.send(.loadMetadataSuggestions)

        XCTAssertEqual(model.state.suggestedTitle, "Plan del trimestre")
        XCTAssertEqual(model.state.suggestedRecipe?.id, Recipe.planning.id)
        XCTAssertEqual(
            client.calls.filter { call in
                if case .loadMetadataSuggestions = call { return true }
                return false
            }.count,
            2)
    }

    func testMetadataFailureCompletesOneShotsAndFailedRenamePreservesTheChip() async {
        let fixture = MeetingDetailModelFixture()
        let client = MeetingDetailModelClientFake(
            updates: metadataUpdates(
                fixture,
                title: "2026-07-18 Meeting",
                segments: [fixture.segment]))
        client.failures.insert(.loadMetadataSuggestions)
        let model = MeetingDetailModel(meetingID: fixture.meeting.id, client: client)

        await model.observe()
        await model.send(.loadMetadataSuggestions)
        await model.send(.loadMetadataSuggestions)

        XCTAssertEqual(
            client.calls.filter { call in
                if case .loadMetadataSuggestions = call { return true }
                return false
            }.count,
            1)

        let retryClient = MeetingDetailModelClientFake(
            updates: metadataUpdates(
                fixture,
                title: "2026-07-18 Meeting",
                segments: [fixture.segment]))
        retryClient.metadataSuggestionsResult = MeetingReviewMetadataSuggestions(
            meetingTitle: "Plan del trimestre")
        let retryModel = MeetingDetailModel(
            meetingID: fixture.meeting.id,
            client: retryClient)
        await retryModel.observe()
        await retryModel.send(.loadMetadataSuggestions)
        retryClient.failures.insert(.renameMeeting)

        var meeting = fixture.meeting
        meeting.title = "2026-07-18 Meeting"
        await retryModel.send(.renameMeeting(meeting, title: "Plan del trimestre"))

        XCTAssertEqual(retryModel.state.suggestedTitle, "Plan del trimestre")
        XCTAssertEqual(
            retryModel.state.lastActionError,
            L10n.format(
                "Could not rename: %@",
                MeetingDetailModelFailure.renameMeeting.localizedDescription))
        XCTAssertEqual(retryClient.searchReindexRequests, 0)
    }

    private func metadataUpdates(
        _ fixture: MeetingDetailModelFixture,
        title: String,
        segments: [TranscriptSegment]
    ) -> [MeetingReviewUpdate] {
        var meeting = fixture.meeting
        meeting.title = title
        return [
            .core(MeetingReviewCore(
                meeting: meeting,
                speakers: [fixture.speaker],
                segments: segments)),
            .summary(fixture.summary),
            .companionCards([fixture.card]),
            .privacyReceipt(fixture.receipt),
            .processingJobs([]),
        ]
    }

    private func effectSpeakerName(_ effect: MeetingDetailModel.Effect?) -> String? {
        switch effect {
        case .nameSuggestionAccepted(let speaker),
            .voiceSuggestionAccepted(let speaker),
            .speakerRenamed(let speaker):
            speaker.displayName
        default:
            nil
        }
    }
}

private struct MeetingDetailModelFixture {
    let meeting: Meeting
    let speaker: Speaker
    let segment: TranscriptSegment
    let card: CompanionCard
    let actionItem: ActionItem
    let person: Person
    let claimID = SummaryClaimID()

    init() {
        meeting = Meeting(title: "Planning", startedAt: Date())
        speaker = Speaker(meetingID: meeting.id, label: "S1", displayName: "Ana")
        segment = TranscriptSegment(
            meetingID: meeting.id,
            speakerID: speaker.id,
            channel: .system,
            text: "El viernes.",
            startTime: 0,
            endTime: 2,
            isFinal: true)
        card = CompanionCard(
            question: "¿Cuándo?",
            answer: "El viernes.",
            kind: .context,
            source: "meeting",
            askedAt: 1)
        actionItem = ActionItem(text: "Publicar")
        person = Person(preferredName: "Ana")
    }

    var core: MeetingReviewCore {
        MeetingReviewCore(
            meeting: meeting,
            speakers: [speaker],
            segments: [segment])
    }

    var summary: MeetingReviewSummary {
        MeetingReviewSummary(
            draft: SummaryDraft(
                meetingID: meeting.id,
                recipeID: Recipe.general.id,
                language: "es",
                markdown: "## Resumen",
                actionItems: []),
            version: 2)
    }

    var updates: [MeetingReviewUpdate] {
        [
            .core(core), .summary(summary), .companionCards([card]),
            .privacyReceipt(receipt), .processingJobs([])
        ]
    }

    var receipt: PrivacyReceipt {
        let trackingStartedAt = meeting.startedAt.addingTimeInterval(-1)
        return PrivacyReceipt(
            meetingID: meeting.id,
            meetingStoredAt: meeting.startedAt,
            trackingStartedAt: trackingStartedAt,
            generationRuns: [],
            egressEvents: [],
            syncDisclosure: .noCloudCopyRecorded)
    }
}

@MainActor
private final class MeetingDetailModelClientFake: MeetingDetailModelClient {
    let updates: [MeetingReviewUpdate]
    var calls: [MeetingDetailModelCall] = []
    var failures: Set<MeetingDetailModelFailure> = []
    var searchReindexRequests = 0
    var canRememberVoiceResult = true
    var rememberVoiceResult: ManageMeetingVoiceMemoryResult = .remembered
    var metadataSuggestionsResult = MeetingReviewMetadataSuggestions()
    var metadataCancellationsRemaining = 0
    var playbackCancellationsRemaining = 0
    var preparedPlaybackResult: PreparedMeetingPlayback?
    var compressionResult = MeetingAudioCompressionResult(bytesFreed: 1_024)
    var prepareDocumentError: (any Error)?
    var publishGistError: (any Error)?
    var nameSuggestionsResult: [MeetingNameSuggestion] = [
        MeetingNameSuggestion(
            label: "S1",
            name: "Ana",
            evidence: .transcript("soy Ana")),
    ]
    private let person: Person

    init(
        updates: [MeetingReviewUpdate],
        person: Person = Person(preferredName: "Ana")
    ) {
        self.updates = updates
        self.person = person
    }

    func observeMeetingReview(
        _ meetingID: MeetingID
    ) -> AsyncStream<MeetingReviewUpdate> {
        calls.append(.observe(meetingID))
        return AsyncStream { continuation in
            for update in updates { continuation.yield(update) }
            continuation.finish()
        }
    }

    func renameMeetingDetailMeeting(_ meeting: Meeting) throws {
        calls.append(.renameMeeting(meeting.title))
        try fail(.renameMeeting)
    }

    func renameMeetingDetailSpeaker(_ speaker: Speaker) throws {
        calls.append(.renameSpeaker(speaker.displayName))
        try fail(.renameSpeaker)
    }

    func findMeetingDetailPeople(matchingAlias alias: String) throws -> [Person] {
        calls.append(.findPeople(alias))
        try fail(.findPeople)
        return [person]
    }

    func linkMeetingDetailSpeaker(
        _ request: LinkObservedSpeakerRequest
    ) throws -> ConfirmedPersonLink {
        let selectedID: PersonID?
        switch request.selection {
        case .createDistinct:
            selectedID = nil
        case .existing(let personID):
            selectedID = personID
        }
        calls.append(.linkPerson(request.speakerID, selectedID))
        try fail(.linkPerson)
        let linkedPerson = selectedID.map { Person(id: $0, preferredName: request.observedName) }
            ?? person
        let speaker = Speaker(
            id: request.speakerID,
            meetingID: MeetingID(),
            label: "S1",
            displayName: linkedPerson.preferredName,
            personID: linkedPerson.id)
        return ConfirmedPersonLink(person: linkedPerson, speaker: speaker)
    }

    func setMeetingDetailActionItem(_ id: UUID, done: Bool) throws {
        calls.append(.setActionItem(id, done))
        try fail(.setActionItem)
    }

    func setMeetingDetailSummaryClaimFeedback(
        _ feedback: SummaryClaimFeedback?,
        for claimID: SummaryClaimID,
        meetingID: MeetingID
    ) throws {
        calls.append(.setClaimFeedback(claimID, feedback, meetingID))
        try fail(.setClaimFeedback)
    }

    func deleteMeetingDetailCompanionCard(_ id: UUID) throws {
        calls.append(.deleteCompanion(id))
        try fail(.deleteCompanion)
    }

    func deleteMeetingDetail(_ id: MeetingID) throws {
        calls.append(.deleteMeeting(id))
        try fail(.deleteMeeting)
    }

    func retryMeetingDetailProcessing(_ meetingID: MeetingID) throws {
        calls.append(.retryProcessing(meetingID))
        try fail(.retryProcessing)
    }

    func prepareMeetingDetailDocument(
        _ meetingID: MeetingID,
        format: MeetingDocumentFormat
    ) throws -> PreparedMeetingDocument {
        calls.append(.prepareDocument(meetingID, format))
        if let prepareDocumentError { throw prepareDocumentError }
        try fail(.prepareDocument)
        return PreparedMeetingDocument(
            data: Data("prepared".utf8),
            filename: "planning.\(format == .markdown ? "md" : "pdf")")
    }

    func publishMeetingDetailGist(_ meetingID: MeetingID) throws -> URL {
        calls.append(.publishGist(meetingID))
        if let publishGistError { throw publishGistError }
        try fail(.publishGist)
        return URL(string: "https://gist.github.com/portavoz/test")!
    }

    func meetingDetailNameSuggestions(
        _ meetingID: MeetingID
    ) throws -> [MeetingNameSuggestion] {
        calls.append(.loadNameSuggestions(meetingID))
        try fail(.loadNameSuggestions)
        return nameSuggestionsResult
    }

    func meetingDetailVoiceSuggestions(
        _ meetingID: MeetingID
    ) throws -> [MeetingVoiceSuggestion] {
        calls.append(.loadVoiceSuggestions(meetingID))
        try fail(.loadVoiceSuggestions)
        return [MeetingVoiceSuggestion(speakerLabel: "S1", name: "Ana", distance: 0)]
    }

    func meetingDetailMetadataSuggestions(
        _ request: SuggestMeetingReviewMetadataRequest
    ) throws -> MeetingReviewMetadataSuggestions {
        calls.append(.loadMetadataSuggestions(
            suggestTitle: request.suggestMeetingTitle,
            suggestRecipe: request.suggestRecipe,
            titledChapterStarts: request.titledChapterStarts))
        if metadataCancellationsRemaining > 0 {
            metadataCancellationsRemaining -= 1
            throw CancellationError()
        }
        try fail(.loadMetadataSuggestions)
        return metadataSuggestionsResult
    }

    func prepareMeetingDetailPlayback(
        _ request: PrepareMeetingPlaybackRequest
    ) throws -> PreparedMeetingPlayback? {
        calls.append(.preparePlayback(request.relativeAudioDirectory))
        if playbackCancellationsRemaining > 0 {
            playbackCancellationsRemaining -= 1
            throw CancellationError()
        }
        try fail(.preparePlayback)
        return preparedPlaybackResult
    }

    func compressMeetingDetailAudio(
        _ request: CompressMeetingAudioRequest
    ) throws -> MeetingAudioCompressionResult {
        calls.append(.compressAudio(request.relativeAudioDirectory))
        try fail(.compressAudio)
        return compressionResult
    }

    func exportMeetingDetailAudioClip(
        _ request: ExportMeetingAudioClipRequest
    ) throws {
        calls.append(.exportAudioClip(
            request.relativeAudioDirectory,
            request.range,
            request.destination))
        try fail(.exportAudioClip)
    }

    func canRememberMeetingDetailVoice(named name: String) -> Bool {
        calls.append(.checkVoiceMemoryOffer(name))
        return canRememberVoiceResult
    }

    func rememberMeetingDetailVoice(
        meetingID: MeetingID,
        speakerID: SpeakerID
    ) throws -> ManageMeetingVoiceMemoryResult {
        calls.append(.rememberVoice(meetingID, speakerID))
        try fail(.rememberVoice)
        return rememberVoiceResult
    }

    func requestMeetingDetailSearchReindex() {
        searchReindexRequests += 1
    }

    private func fail(_ failure: MeetingDetailModelFailure) throws {
        if failures.contains(failure) { throw failure }
    }
}

private enum MeetingDetailModelFailure: String, CaseIterable, Error, LocalizedError {
    case renameMeeting
    case renameSpeaker
    case findPeople
    case linkPerson
    case setActionItem
    case setClaimFeedback
    case deleteCompanion
    case deleteMeeting
    case retryProcessing
    case prepareDocument
    case publishGist
    case loadNameSuggestions
    case loadVoiceSuggestions
    case loadMetadataSuggestions
    case preparePlayback
    case compressAudio
    case exportAudioClip
    case rememberVoice

    var errorDescription: String? { "meeting-detail-model-\(rawValue)" }
}

private enum MeetingDetailModelCall: Equatable {
    case observe(MeetingID)
    case renameMeeting(String)
    case renameSpeaker(String?)
    case findPeople(String)
    case linkPerson(SpeakerID, PersonID?)
    case setActionItem(UUID, Bool)
    case setClaimFeedback(SummaryClaimID, SummaryClaimFeedback?, MeetingID)
    case deleteCompanion(UUID)
    case deleteMeeting(MeetingID)
    case retryProcessing(MeetingID)
    case prepareDocument(MeetingID, MeetingDocumentFormat)
    case publishGist(MeetingID)
    case loadNameSuggestions(MeetingID)
    case loadVoiceSuggestions(MeetingID)
    case loadMetadataSuggestions(
        suggestTitle: Bool,
        suggestRecipe: Bool,
        titledChapterStarts: Set<TimeInterval>)
    case preparePlayback(String)
    case compressAudio(String)
    case exportAudioClip(String, ClosedRange<TimeInterval>, URL)
    case checkVoiceMemoryOffer(String)
    case rememberVoice(MeetingID, SpeakerID)
}
