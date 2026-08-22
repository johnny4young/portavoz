import ApplicationKit
import Foundation
import PortavozCore
import XCTest

@testable import portavoz_app

@MainActor
final class AskPresentationModelTests: XCTestCase {
    func testFullAskOwnsDraftAnswerAndEvidenceFallbackPresentation() async throws {
        let fixture = AskPresentationFixture()
        let client = ControlledAskModelClient()
        let model = AskModel(client: client)

        model.updateDraft("  presupuesto  ")
        model.submit()
        try await waitUntil { client.answerRequests == ["presupuesto"] }
        client.completeAnswer(
            "presupuesto",
            with: AskMeetingAnswer(
                question: "presupuesto",
                generatedText: nil,
                citations: [fixture.citation]))
        try await waitUntil { model.state.exchanges.count == 1 }

        XCTAssertEqual(model.state.draft, "")
        XCTAssertFalse(model.state.isAsking)
        XCTAssertEqual(model.state.exchanges.first?.question, "presupuesto")
        XCTAssertEqual(
            model.state.exchanges.first?.answer,
            L10n.text("Closest passages from your meetings:"))
        XCTAssertEqual(model.state.exchanges.first?.citations, [fixture.citation])
    }

    func testFullAskPublishesProgressiveEvidenceThenFencesFinalAnswer() async throws {
        let fixture = AskPresentationFixture()
        let client = ControlledAskModelClient()
        let model = AskModel(client: client)

        model.updateDraft("presupuesto")
        model.submit()
        XCTAssertEqual(model.state.pendingPhase, .findingEvidence)
        try await waitUntil { client.answerRequests == ["presupuesto"] }

        await client.publishEvidence(
            "presupuesto",
            update: AskEvidenceUpdate(
                phase: .lexical,
                citations: [fixture.citation]))
        try await waitUntil { model.state.pendingPhase == .refiningEvidence }
        XCTAssertEqual(model.state.pendingCitations, [fixture.citation])

        await client.publishEvidence(
            "presupuesto",
            update: AskEvidenceUpdate(
                phase: .fused,
                citations: [fixture.citation]))
        try await waitUntil { model.state.pendingPhase == .generatingAnswer }

        client.completeAnswer(
            "presupuesto",
            with: AskMeetingAnswer(
                question: "presupuesto",
                generatedText: "El viernes.",
                citations: [fixture.citation]))
        try await waitUntil { model.state.exchanges.count == 1 }

        XCTAssertFalse(model.state.isAsking)
        XCTAssertNil(model.state.pendingQuestion)
        XCTAssertNil(model.state.pendingPhase)
        XCTAssertEqual(model.state.pendingCitations, [])
        XCTAssertEqual(model.state.exchanges.first?.answer, "El viernes.")
    }

    func testFullAskCancellationRejectsLateProgressAndCompletion() async throws {
        let fixture = AskPresentationFixture()
        let client = ControlledAskModelClient()
        let model = AskModel(client: client)

        model.updateDraft("old")
        model.submit()
        try await waitUntil { client.answerRequests == ["old"] }
        await client.publishEvidence(
            "old",
            update: AskEvidenceUpdate(
                phase: .lexical,
                citations: [fixture.citation]))
        try await waitUntil { model.state.pendingPhase == .refiningEvidence }

        model.cancelPendingAnswer()
        await client.publishEvidence(
            "old",
            update: AskEvidenceUpdate(
                phase: .fused,
                citations: [fixture.citation]))
        client.completeAnswer(
            "old",
            with: AskMeetingAnswer(
                question: "old",
                generatedText: "stale",
                citations: [fixture.citation]))
        await Task.yield()

        XCTAssertFalse(model.state.isAsking)
        XCTAssertNil(model.state.pendingQuestion)
        XCTAssertNil(model.state.pendingPhase)
        XCTAssertTrue(model.state.pendingCitations.isEmpty)
        XCTAssertTrue(model.state.exchanges.isEmpty)
    }

    func testMemoryPersonSearchPublishesOnlyLatestBoundedExactCandidates() async throws {
        let ask = ControlledAskModelClient()
        let memory = ControlledAskMemoryModelClient()
        let model = AskModel(
            client: ask,
            memoryClient: memory,
            memorySearchDelay: .zero)
        let memoryModel = try XCTUnwrap(model.memory)

        model.selectSurface(.personCommitments)
        try await waitUntil { memory.peopleRequests == [""] }
        XCTAssertEqual(memory.peopleLimits, [21])
        memoryModel.updatePersonQuery("Ana")
        try await waitUntil { memory.peopleRequests == ["", "Ana"] }
        XCTAssertEqual(memory.peopleLimits, [21, 21])

        let stale = Person(preferredName: "Stale person")
        memory.completePeople("", with: [stale])
        await Task.yield()
        XCTAssertEqual(memoryModel.state.peoplePhase, .loading)
        XCTAssertTrue(memoryModel.state.people.isEmpty)

        let candidates = (0..<21).map {
            Person(preferredName: "Ana \($0 + 1)")
        }
        memory.completePeople("Ana", with: candidates)
        try await waitUntil { memoryModel.state.peoplePhase == .ready }

        XCTAssertEqual(memoryModel.state.people.count, 20)
        XCTAssertEqual(
            memoryModel.state.people.map(\.id),
            candidates.prefix(20).map(\.id))
        XCTAssertTrue(memoryModel.state.peopleHasMore)

        memoryModel.selectPerson(candidates[3].id)
        XCTAssertEqual(memoryModel.state.selectedPerson?.id, candidates[3].id)
        XCTAssertEqual(memoryModel.state.personQuery, "Ana 4")
        XCTAssertTrue(memoryModel.state.people.isEmpty)
    }

    func testMemoryPersonSearchFailsClosedForAnOversizedCatalogResponse() async throws {
        let memory = ControlledAskMemoryModelClient()
        let model = AskMemoryModel(
            client: memory,
            searchDelay: .zero)

        model.activate()
        try await waitUntil { memory.peopleRequests == [""] }
        memory.completePeople(
            "",
            with: (0..<22).map { Person(preferredName: "Person \($0)") })
        try await waitUntil { model.state.peoplePhase == .unavailable }

        XCTAssertTrue(model.state.people.isEmpty)
        XCTAssertFalse(model.state.peopleHasMore)
    }

    func testMemoryPersonCommitmentsExposeOnlyExactTypedEvidence() async throws {
        let fixture = AskMemoryPresentationFixture()
        let ask = ControlledAskModelClient()
        let memory = ControlledAskMemoryModelClient()
        let model = AskModel(
            client: ask,
            memoryClient: memory,
            memorySearchDelay: .zero)
        let memoryModel = try XCTUnwrap(model.memory)

        model.selectSurface(.personCommitments)
        try await waitUntil { memory.peopleRequests == [""] }
        memory.completePeople("", with: [fixture.person])
        try await waitUntil { memoryModel.state.peoplePhase == .ready }
        memoryModel.selectPerson(fixture.person.id)
        memoryModel.loadSelectedPersonCommitments()
        try await waitUntil {
            memory.commitmentRequests == [fixture.person.id]
        }
        XCTAssertEqual(memory.commitmentLimits, [100])
        memory.completeCommitments(
            for: fixture.person.id,
            with: .facts(fixture.page()))
        try await waitUntil {
            if case .facts = memoryModel.state.outcome { return true }
            return false
        }

        guard case .facts(let values, let disclosure) = memoryModel.state.outcome
        else { return XCTFail("Expected exact person commitment facts") }
        let value = try XCTUnwrap(values.first)
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(value.id, fixture.commitmentID)
        XCTAssertEqual(value.personName, "Ana")
        XCTAssertEqual(value.title, "Prepare the rollout")
        XCTAssertEqual(value.citations, [fixture.citation])
        XCTAssertEqual(value.primaryCitation, fixture.citation)
        XCTAssertFalse(disclosure.hasMore)
        XCTAssertEqual(disclosure.omittedStaleCount, 0)
        XCTAssertEqual(disclosure.omittedUnavailableCount, 0)
    }

    func testMemoryPersonCommitmentsFailClosedForOversizeWrongPersonOrUnreadyGraph() async throws {
        let fixture = AskMemoryPresentationFixture()
        let ask = ControlledAskModelClient()
        let memory = ControlledAskMemoryModelClient()
        let model = AskModel(
            client: ask,
            memoryClient: memory,
            memorySearchDelay: .zero)
        let memoryModel = try XCTUnwrap(model.memory)

        model.selectSurface(.personCommitments)
        try await waitUntil { memory.peopleRequests == [""] }
        memory.completePeople("", with: [fixture.person])
        try await waitUntil { memoryModel.state.peoplePhase == .ready }
        memoryModel.selectPerson(fixture.person.id)
        memoryModel.loadSelectedPersonCommitments()
        try await waitUntil { memory.commitmentRequests.count == 1 }
        memory.completeCommitments(
            for: fixture.person.id,
            with: .facts(fixture.page(count: 101)))
        try await waitUntil { memoryModel.state.outcome == .invalidEvidence }

        memoryModel.loadSelectedPersonCommitments()
        try await waitUntil { memory.commitmentRequests.count == 2 }
        memory.completeCommitments(
            for: fixture.person.id,
            with: .facts(fixture.page(subjectID: PersonID())))
        try await waitUntil { memoryModel.state.outcome == .invalidEvidence }

        memoryModel.loadSelectedPersonCommitments()
        try await waitUntil { memory.commitmentRequests.count == 3 }
        memory.completeCommitments(
            for: fixture.person.id,
            with: .abstained(.projectionNotReady))
        try await waitUntil {
            memoryModel.state.outcome == .abstained(.projectionNotReady)
        }
    }

    func testMemoryCommitmentBlockersExposeExactActiveEvidenceWithPrimaryFirst() async throws {
        let fixture = AskMemoryPresentationFixture()
        let memory = ControlledAskMemoryModelClient()
        let model = AskMemoryModel(client: memory, searchDelay: .zero)

        try await loadCommitments(fixture: fixture, in: model, using: memory)
        model.loadCommitmentBlockers(for: fixture.commitmentID)
        try await waitUntil {
            memory.blockerRequests == [fixture.commitmentID]
        }
        XCTAssertEqual(memory.blockerLimits, [100])
        memory.completeBlockers(
            for: fixture.commitmentID,
            with: .facts(fixture.blockerPage()))
        try await waitUntil {
            if case .facts = model.state.blockerOutcome { return true }
            return false
        }

        guard case .facts(let blockers, let disclosure) = model.state.blockerOutcome
        else { return XCTFail("Expected exact commitment blocker facts") }
        let blocker = try XCTUnwrap(blockers.first)
        XCTAssertEqual(blockers.count, 1)
        XCTAssertEqual(blocker.id, fixture.blockerID)
        XCTAssertEqual(blocker.decisionID, fixture.decisionID)
        XCTAssertEqual(blocker.commitmentID, fixture.commitmentID)
        XCTAssertEqual(blocker.decisionStatement, "Security review must pass")
        XCTAssertEqual(blocker.commitmentTitle, "Prepare the rollout")
        XCTAssertEqual(
            blocker.citations,
            [fixture.commitmentCitation, fixture.blockerCitation])
        XCTAssertEqual(blocker.primaryCitation, fixture.blockerCitation)
        XCTAssertFalse(disclosure.hasMore)
        XCTAssertEqual(disclosure.omittedStaleCount, 0)
        XCTAssertEqual(disclosure.omittedUnavailableCount, 0)
    }

    func testMemoryCommitmentBlockersAllowOneExactSharedSource() async throws {
        let fixture = AskMemoryPresentationFixture()
        let memory = ControlledAskMemoryModelClient()
        let model = AskMemoryModel(client: memory, searchDelay: .zero)

        try await loadCommitments(fixture: fixture, in: model, using: memory)
        model.loadCommitmentBlockers(for: fixture.commitmentID)
        try await waitUntil { memory.blockerRequests.count == 1 }
        memory.completeBlockers(
            for: fixture.commitmentID,
            with: .facts(fixture.blockerPage(sharedSource: true)))
        try await waitUntil {
            if case .facts = model.state.blockerOutcome { return true }
            return false
        }

        guard case .facts(let blockers, _) = model.state.blockerOutcome
        else { return XCTFail("Expected one source-backed blocker") }
        XCTAssertEqual(blockers.first?.citations, [fixture.blockerCitation])
        XCTAssertEqual(blockers.first?.primaryCitation, fixture.blockerCitation)
    }

    func testMemoryCommitmentBlockersRejectMalformedOrUnselectedFacts() async throws {
        let fixture = AskMemoryPresentationFixture()
        let memory = ControlledAskMemoryModelClient()
        let model = AskMemoryModel(client: memory, searchDelay: .zero)

        try await loadCommitments(fixture: fixture, in: model, using: memory)
        model.loadCommitmentBlockers(for: CommitmentID())
        await Task.yield()
        XCTAssertTrue(memory.blockerRequests.isEmpty)

        let malformedPages = [
            fixture.blockerPage(count: 101),
            fixture.blockerPage(kind: .personCommittedTo),
            fixture.blockerPage(factID: .commitment(fixture.commitmentID)),
            fixture.blockerPage(subject: .person(fixture.person.id)),
            fixture.blockerPage(object: .commitment(CommitmentID())),
            fixture.blockerPage(objectText: "Different commitment"),
            fixture.blockerPage(status: .confirmed),
            fixture.blockerPage(primarySegmentID: UUID()),
        ]
        for (index, page) in malformedPages.enumerated() {
            model.loadCommitmentBlockers(for: fixture.commitmentID)
            try await waitUntil { memory.blockerRequests.count == index + 1 }
            memory.completeBlockers(
                for: fixture.commitmentID,
                with: .facts(page))
            try await waitUntil {
                model.state.blockerOutcome == .invalidEvidence
            }
        }
    }

    func testMemoryCommitmentBlockerSelectionFencesLateResults() async throws {
        let fixture = AskMemoryPresentationFixture()
        let memory = ControlledAskMemoryModelClient()
        let model = AskMemoryModel(client: memory, searchDelay: .zero)

        try await loadCommitments(
            fixture: fixture,
            count: 2,
            in: model,
            using: memory)
        guard case .facts(let commitments, _) = model.state.outcome,
              commitments.count == 2
        else { return XCTFail("Expected two exact commitments") }
        let nextCommitmentID = commitments[1].id

        model.loadCommitmentBlockers(for: fixture.commitmentID)
        try await waitUntil { memory.blockerRequests.count == 1 }
        model.loadCommitmentBlockers(for: nextCommitmentID)
        try await waitUntil { memory.blockerRequests.count == 2 }

        memory.completeBlockers(
            for: fixture.commitmentID,
            with: .facts(fixture.blockerPage()))
        await Task.yield()
        XCTAssertEqual(
            model.state.selectedCommitmentIDForBlockers,
            nextCommitmentID)
        XCTAssertEqual(model.state.blockerOutcome, .loading)

        memory.completeBlockers(
            for: nextCommitmentID,
            with: .facts(fixture.blockerPage(
                commitmentID: nextCommitmentID)))
        try await waitUntil {
            if case .facts = model.state.blockerOutcome { return true }
            return false
        }
        guard case .facts(let blockers, _) = model.state.blockerOutcome
        else { return XCTFail("Expected latest exact blocker result") }
        XCTAssertEqual(blockers.first?.commitmentID, nextCommitmentID)
    }

    func testMemoryPendingReadDoesNotRetainClosedWindowModel() async throws {
        let memory = ControlledAskMemoryModelClient()
        var model: AskMemoryModel? = AskMemoryModel(
            client: memory,
            searchDelay: .zero)
        weak let retainedModel = model

        model?.activate()
        try await waitUntil { memory.peopleRequests == [""] }
        model = nil

        XCTAssertNil(
            retainedModel,
            "an in-flight local read must not retain a closed Ask window")
        memory.completePeople("", with: [])
        await Task.yield()
    }

    func testTopicMemorySearchPublishesOnlyLatestBoundedExactCandidates() async throws {
        let ask = ControlledAskModelClient()
        let memory = ControlledAskMemoryModelClient()
        let model = AskModel(
            client: ask,
            memoryClient: memory,
            memorySearchDelay: .zero)
        let topicModel = try XCTUnwrap(model.topicMemory)

        model.selectSurface(.topicDecisions)
        try await waitUntil { memory.topicRequests == [""] }
        XCTAssertEqual(memory.topicLimits, [21])
        topicModel.updateTopicQuery("rollout")
        try await waitUntil { memory.topicRequests == ["", "rollout"] }
        XCTAssertEqual(memory.topicLimits, [21, 21])

        memory.completeTopics("", with: [Topic(preferredLabel: "Stale")])
        await Task.yield()
        XCTAssertEqual(topicModel.state.topicsPhase, .loading)
        XCTAssertTrue(topicModel.state.topics.isEmpty)

        let candidates = (0..<21).map {
            Topic(preferredLabel: "Rollout \($0 + 1)")
        }
        memory.completeTopics("rollout", with: candidates)
        try await waitUntil { topicModel.state.topicsPhase == .ready }

        XCTAssertEqual(topicModel.state.topics.count, 20)
        XCTAssertEqual(
            topicModel.state.topics.map(\.id),
            candidates.prefix(20).map(\.id))
        XCTAssertTrue(topicModel.state.topicsHaveMore)

        topicModel.selectTopic(candidates[4].id)
        XCTAssertEqual(topicModel.state.selectedTopic?.id, candidates[4].id)
        XCTAssertEqual(topicModel.state.topicQuery, "Rollout 5")
        XCTAssertTrue(topicModel.state.topics.isEmpty)
    }

    func testTopicMemorySearchFailsClosedForAnOversizedCatalogResponse() async throws {
        let memory = ControlledAskMemoryModelClient()
        let model = AskTopicMemoryModel(
            client: memory,
            searchDelay: .zero)

        model.activate()
        try await waitUntil { memory.topicRequests == [""] }
        memory.completeTopics(
            "",
            with: (0..<22).map { Topic(preferredLabel: "Topic \($0)") })
        try await waitUntil { model.state.topicsPhase == .unavailable }

        XCTAssertTrue(model.state.topics.isEmpty)
        XCTAssertFalse(model.state.topicsHaveMore)
    }

    func testTopicMemoryDecisionsExposeOnlyExactTypedEvidence() async throws {
        let fixture = AskTopicMemoryPresentationFixture()
        let ask = ControlledAskModelClient()
        let memory = ControlledAskMemoryModelClient()
        let model = AskModel(
            client: ask,
            memoryClient: memory,
            memorySearchDelay: .zero)
        let topicModel = try XCTUnwrap(model.topicMemory)

        model.selectSurface(.topicDecisions)
        try await waitUntil { memory.topicRequests == [""] }
        memory.completeTopics("", with: [fixture.topic])
        try await waitUntil { topicModel.state.topicsPhase == .ready }
        topicModel.selectTopic(fixture.topic.id)
        topicModel.loadSelectedTopicDecisions()
        try await waitUntil { memory.decisionRequests == [fixture.topic.id] }
        XCTAssertEqual(memory.decisionLimits, [100])
        memory.completeDecisions(
            for: fixture.topic.id,
            with: .facts(fixture.page()))
        try await waitUntil {
            if case .decisions = topicModel.state.outcome { return true }
            return false
        }

        guard case .decisions(let values, let disclosure) = topicModel.state.outcome
        else { return XCTFail("Expected exact topic decision facts") }
        let value = try XCTUnwrap(values.first)
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(value.id, fixture.linkID)
        XCTAssertEqual(value.decisionID, fixture.decisionID)
        XCTAssertEqual(value.topicLabel, "Model rollout")
        XCTAssertEqual(value.statement, "Ship the model on Friday")
        XCTAssertEqual(value.citations, [fixture.citation])
        XCTAssertEqual(value.primaryCitation, fixture.citation)
        XCTAssertFalse(disclosure.hasMore)
        XCTAssertEqual(disclosure.omittedStaleCount, 0)
        XCTAssertEqual(disclosure.omittedUnavailableCount, 0)
    }

    func testTopicMemoryDecisionsFailClosedForOversizeWrongTopicOrUnreadyGraph() async throws {
        let fixture = AskTopicMemoryPresentationFixture()
        let memory = ControlledAskMemoryModelClient()
        let model = AskTopicMemoryModel(
            client: memory,
            searchDelay: .zero)

        model.activate()
        try await waitUntil { memory.topicRequests == [""] }
        memory.completeTopics("", with: [fixture.topic])
        try await waitUntil { model.state.topicsPhase == .ready }
        model.selectTopic(fixture.topic.id)
        model.loadSelectedTopicDecisions()
        try await waitUntil { memory.decisionRequests.count == 1 }
        memory.completeDecisions(
            for: fixture.topic.id,
            with: .facts(fixture.page(count: 101)))
        try await waitUntil { model.state.outcome == .invalidEvidence }

        model.loadSelectedTopicDecisions()
        try await waitUntil { memory.decisionRequests.count == 2 }
        memory.completeDecisions(
            for: fixture.topic.id,
            with: .facts(fixture.page(topicID: TopicID())))
        try await waitUntil { model.state.outcome == .invalidEvidence }

        model.loadSelectedTopicDecisions()
        try await waitUntil { memory.decisionRequests.count == 3 }
        memory.completeDecisions(
            for: fixture.topic.id,
            with: .abstained(.projectionNotReady))
        try await waitUntil {
            model.state.outcome == .abstained(.projectionNotReady)
        }
    }

    func testTopicMemoryPendingReadDoesNotRetainClosedWindowModel() async throws {
        let memory = ControlledAskMemoryModelClient()
        var model: AskTopicMemoryModel? = AskTopicMemoryModel(
            client: memory,
            searchDelay: .zero)
        weak let retainedModel = model

        model?.activate()
        try await waitUntil { memory.topicRequests == [""] }
        model = nil

        XCTAssertNil(
            retainedModel,
            "an in-flight topic read must not retain a closed Ask window")
        memory.completeTopics("", with: [])
        await Task.yield()
    }

    func testTopicMemoryFirstDiscussionExposesOneExactSourceBackedFact() async throws {
        let fixture = AskTopicMemoryPresentationFixture()
        let memory = ControlledAskMemoryModelClient()
        let model = AskTopicMemoryModel(
            client: memory,
            searchDelay: .zero)

        try await selectTopic(fixture.topic, in: model, using: memory)
        model.selectJob(.firstConfirmedDiscussion)
        model.loadSelectedTopicMemory()
        try await waitUntil {
            memory.firstDiscussionRequests == [fixture.topic.id]
        }
        memory.completeFirstDiscussion(
            for: fixture.topic.id,
            with: .facts(fixture.firstDiscussionPage()))
        try await waitUntil {
            if case .firstDiscussion = model.state.outcome { return true }
            return false
        }

        guard case .firstDiscussion(let discussion) = model.state.outcome
        else { return XCTFail("Expected exact topic first discussion") }
        XCTAssertEqual(discussion.id, fixture.topicEvidenceID)
        XCTAssertEqual(discussion.topicLabel, "Model rollout")
        XCTAssertEqual(discussion.meetingID, fixture.meetingID)
        XCTAssertEqual(discussion.meetingTitle, "Test meeting")
        XCTAssertEqual(
            discussion.occurredAt,
            fixture.meetingStartedAt.addingTimeInterval(3))
        XCTAssertEqual(discussion.citation, fixture.citation)
    }

    func testTopicMemoryFirstDiscussionFailsClosedForPartialOrMismatchedEvidence() async throws {
        let fixture = AskTopicMemoryPresentationFixture()
        let memory = ControlledAskMemoryModelClient()
        let model = AskTopicMemoryModel(
            client: memory,
            searchDelay: .zero)

        try await selectTopic(fixture.topic, in: model, using: memory)
        model.selectJob(.firstConfirmedDiscussion)

        let malformedPages = [
            fixture.firstDiscussionPage(factCount: 0),
            fixture.firstDiscussionPage(factCount: 2),
            fixture.firstDiscussionPage(sourceCount: 2),
            fixture.firstDiscussionPage(hasMore: true),
            fixture.firstDiscussionPage(omittedStaleCount: 1),
            fixture.firstDiscussionPage(topicID: TopicID()),
            fixture.firstDiscussionPage(meetingID: MeetingID()),
            fixture.firstDiscussionPage(occurredAtOffset: 4)
        ]
        for (index, page) in malformedPages.enumerated() {
            model.loadSelectedTopicMemory()
            try await waitUntil {
                memory.firstDiscussionRequests.count == index + 1
            }
            memory.completeFirstDiscussion(
                for: fixture.topic.id,
                with: .facts(page))
            try await waitUntil { model.state.outcome == .invalidEvidence }
        }
    }

    func testTopicMemoryJobChangeFencesLateFirstDiscussionResult() async throws {
        let fixture = AskTopicMemoryPresentationFixture()
        let memory = ControlledAskMemoryModelClient()
        let model = AskTopicMemoryModel(
            client: memory,
            searchDelay: .zero)

        try await selectTopic(fixture.topic, in: model, using: memory)
        model.selectJob(.firstConfirmedDiscussion)
        model.loadSelectedTopicMemory()
        try await waitUntil { memory.firstDiscussionRequests.count == 1 }

        model.selectJob(.currentDecisions)
        XCTAssertEqual(model.state.outcome, .idle)
        memory.completeFirstDiscussion(
            for: fixture.topic.id,
            with: .facts(fixture.firstDiscussionPage()))
        await Task.yield()

        XCTAssertEqual(model.state.selectedJob, .currentDecisions)
        XCTAssertEqual(model.state.outcome, .idle)
    }

    func testTopicMemoryPendingFirstDiscussionDoesNotRetainClosedWindowModel() async throws {
        let fixture = AskTopicMemoryPresentationFixture()
        let memory = ControlledAskMemoryModelClient()
        var model: AskTopicMemoryModel? = AskTopicMemoryModel(
            client: memory,
            searchDelay: .zero)

        try await selectTopic(
            fixture.topic,
            in: try XCTUnwrap(model),
            using: memory)
        model?.selectJob(.firstConfirmedDiscussion)
        model?.loadSelectedTopicMemory()
        try await waitUntil { memory.firstDiscussionRequests.count == 1 }
        weak let retainedModel = model
        model = nil

        XCTAssertNil(
            retainedModel,
            "an in-flight first-discussion read must not retain a closed Ask window")
        memory.completeFirstDiscussion(
            for: fixture.topic.id,
            with: .facts(fixture.firstDiscussionPage()))
        await Task.yield()
    }

    func testTopicMemoryDecisionConflictsExposeExactReplacementAndPrimaryEvidence() async throws {
        let fixture = AskTopicMemoryPresentationFixture()
        let memory = ControlledAskMemoryModelClient()
        let model = AskTopicMemoryModel(
            client: memory,
            searchDelay: .zero)

        try await selectTopic(fixture.topic, in: model, using: memory)
        model.selectJob(.decisionConflicts)
        model.loadSelectedTopicMemory()
        try await waitUntil {
            memory.conflictRequests == [fixture.topic.id]
        }
        XCTAssertEqual(memory.conflictLimits, [100])
        memory.completeConflicts(
            for: fixture.topic.id,
            with: .facts(fixture.conflictPage()))
        try await waitUntil {
            if case .conflicts = model.state.outcome { return true }
            return false
        }

        guard case .conflicts(let conflicts, let disclosure) = model.state.outcome
        else { return XCTFail("Expected exact topic decision conflicts") }
        let conflict = try XCTUnwrap(conflicts.first)
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflict.id, fixture.relationshipEventID)
        XCTAssertEqual(conflict.successorDecisionID, fixture.decisionID)
        XCTAssertEqual(conflict.replacedDecisionID, fixture.replacedDecisionID)
        XCTAssertEqual(conflict.successorStatement, "Ship the model on Friday")
        XCTAssertEqual(conflict.replacedStatement, "Ship the model on Thursday")
        XCTAssertEqual(
            conflict.citations,
            [fixture.replacedCitation, fixture.citation])
        XCTAssertEqual(conflict.primaryCitation, fixture.citation)
        XCTAssertFalse(disclosure.hasMore)
        XCTAssertEqual(disclosure.omittedStaleCount, 0)
        XCTAssertEqual(disclosure.omittedUnavailableCount, 0)
    }

    func testTopicMemoryDecisionConflictsRejectMalformedRelationshipEvidence() async throws {
        let fixture = AskTopicMemoryPresentationFixture()
        let memory = ControlledAskMemoryModelClient()
        let model = AskTopicMemoryModel(
            client: memory,
            searchDelay: .zero)

        try await selectTopic(fixture.topic, in: model, using: memory)
        model.selectJob(.decisionConflicts)
        let malformedPages = [
            fixture.conflictPage(factCount: 101),
            fixture.conflictPage(kind: .decisionAboutTopic),
            fixture.conflictPage(replacedDecisionID: fixture.decisionID),
            fixture.conflictPage(sourceCount: 1),
            fixture.conflictPage(primarySegmentID: UUID()),
            fixture.conflictPage(successorStatement: "  "),
            fixture.conflictPage(status: .active),
            fixture.conflictPage(usesRelationshipID: false)
        ]
        for (index, page) in malformedPages.enumerated() {
            model.loadSelectedTopicMemory()
            try await waitUntil { memory.conflictRequests.count == index + 1 }
            memory.completeConflicts(
                for: fixture.topic.id,
                with: .facts(page))
            try await waitUntil { model.state.outcome == .invalidEvidence }
        }
    }

    func testTopicMemoryJobChangeFencesLateDecisionConflictResult() async throws {
        let fixture = AskTopicMemoryPresentationFixture()
        let memory = ControlledAskMemoryModelClient()
        let model = AskTopicMemoryModel(
            client: memory,
            searchDelay: .zero)

        try await selectTopic(fixture.topic, in: model, using: memory)
        model.selectJob(.decisionConflicts)
        model.loadSelectedTopicMemory()
        try await waitUntil { memory.conflictRequests.count == 1 }

        model.selectJob(.firstConfirmedDiscussion)
        XCTAssertEqual(model.state.outcome, .idle)
        memory.completeConflicts(
            for: fixture.topic.id,
            with: .facts(fixture.conflictPage()))
        await Task.yield()

        XCTAssertEqual(model.state.selectedJob, .firstConfirmedDiscussion)
        XCTAssertEqual(model.state.outcome, .idle)
    }

    private func selectTopic(
        _ topic: Topic,
        in model: AskTopicMemoryModel,
        using memory: ControlledAskMemoryModelClient
    ) async throws {
        model.activate()
        try await waitUntil { memory.topicRequests == [""] }
        memory.completeTopics("", with: [topic])
        try await waitUntil { model.state.topicsPhase == .ready }
        model.selectTopic(topic.id)
    }

    private func loadCommitments(
        fixture: AskMemoryPresentationFixture,
        count: Int = 1,
        in model: AskMemoryModel,
        using memory: ControlledAskMemoryModelClient
    ) async throws {
        model.activate()
        try await waitUntil { memory.peopleRequests == [""] }
        memory.completePeople("", with: [fixture.person])
        try await waitUntil { model.state.peoplePhase == .ready }
        model.selectPerson(fixture.person.id)
        model.loadSelectedPersonCommitments()
        try await waitUntil { memory.commitmentRequests.count == 1 }
        memory.completeCommitments(
            for: fixture.person.id,
            with: .facts(fixture.page(count: count)))
        try await waitUntil {
            if case .facts = model.state.outcome { return true }
            return false
        }
    }

    func testPaletteResetPreventsClosedGenerationFromPublishingIntoReopen() async throws {
        let fixture = AskPresentationFixture()
        let client = ControlledAskModelClient()
        let model = CommandPaletteModel(client: client)

        model.updateQuery("old")
        try await waitUntil { client.searchRequests.contains("old") }
        model.reset()
        model.updateQuery("new")
        try await waitUntil { client.searchRequests.contains("new") }

        client.completeSearch("old", with: [fixture.oldHit])
        client.completeSearch("new", with: [fixture.newHit])
        try await waitUntil { model.state.hits == [fixture.newHit] }

        model.submit()
        try await waitUntil { client.answerRequests.contains("new") }
        model.reset()
        model.updateQuery("newer")
        try await waitUntil { client.searchRequests.contains("newer") }
        client.completeAnswer(
            "new",
            with: AskMeetingAnswer(
                question: "new",
                generatedText: "stale",
                citations: [fixture.citation]))
        client.completeSearch("newer", with: [fixture.newerHit])
        try await waitUntil { model.state.hits == [fixture.newerHit] }

        XCTAssertNil(model.state.answer)
        XCTAssertFalse(model.state.isAnswering)
        XCTAssertEqual(model.state.query, "newer")
    }

    /// SwiftUI can deliver a trailing text update after `onSubmit` — coalesced
    /// typing, an IME commit, a re-render with the same value. Treating that as
    /// a new query cancelled the answer already running for it, leaving the
    /// palette showing hits, no answer, and nothing to restart it.
    func testAnEchoedQueryDoesNotCancelTheAnswerRunningForIt() async throws {
        let fixture = AskPresentationFixture()
        let client = ControlledAskModelClient()
        let model = CommandPaletteModel(client: client)

        model.updateQuery("rollout")
        try await waitUntil { client.searchRequests.contains("rollout") }
        client.completeSearch("rollout", with: [fixture.newHit])
        model.submit()
        try await waitUntil { client.answerRequests.contains("rollout") }

        // The same text arrives again while the answer is in flight.
        model.updateQuery("rollout")

        client.completeAnswer(
            "rollout",
            with: AskMeetingAnswer(
                question: "rollout",
                generatedText: "El viernes.",
                citations: [fixture.citation]))
        try await waitUntil { model.state.answer != nil }
        XCTAssertEqual(model.state.answer?.text, "El viernes.")
        XCTAssertFalse(model.state.isAnswering)
    }

    /// `isAnswering` gates `submit`, so a palette that leaked it would refuse
    /// every further Enter. Characterization: this pins the property rather
    /// than a fix — the behaviour already held before the defer that now
    /// guarantees it.
    func testAnAnswerThatFailsStillLetsTheUserAskAgain() async throws {
        let fixture = AskPresentationFixture()
        let client = ControlledAskModelClient()
        let model = CommandPaletteModel(client: client)

        model.updateQuery("rollout")
        try await waitUntil { client.searchRequests.contains("rollout") }
        client.completeSearch("rollout", with: [fixture.newHit])
        model.submit()
        try await waitUntil { client.answerRequests.contains("rollout") }

        // The request fails outright rather than answering.
        client.failAnswer("rollout")
        try await waitUntil { !model.state.isAnswering }

        // Enter works again, on the same question.
        model.submit()
        try await waitUntil { client.answerRequests.filter { $0 == "rollout" }.count == 2 }
        client.completeAnswer(
            "rollout",
            with: AskMeetingAnswer(
                question: "rollout",
                generatedText: "El viernes.",
                citations: [fixture.citation]))
        try await waitUntil { model.state.answer?.text == "El viernes." }
    }

    func testPaletteMarkdownKeepsQuestionAnswerAndReceipts() async throws {
        let fixture = AskPresentationFixture()
        let client = ControlledAskModelClient()
        let model = CommandPaletteModel(client: client)

        model.updateQuery("rollout")
        try await waitUntil { client.searchRequests.contains("rollout") }
        client.completeSearch("rollout", with: [fixture.newHit])
        model.submit()
        try await waitUntil { client.answerRequests.contains("rollout") }
        client.completeAnswer(
            "rollout",
            with: AskMeetingAnswer(
                question: "rollout",
                generatedText: "El viernes.",
                citations: [fixture.citation]))
        try await waitUntil { model.state.answer != nil }

        XCTAssertEqual(
            model.markdownAnswer(),
            "> rollout\n\nEl viernes.\n\n- Test meeting · 00:03")
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else { throw AskPresentationTestError.timeout }
            await Task.yield()
        }
    }
}

private struct AskPresentationFixture {
    let meetingID = MeetingID()
    let oldHit: AskSearchResult
    let newHit: AskSearchResult
    let newerHit: AskSearchResult
    let citation: AskCitation

    init() {
        oldHit = AskSearchResult(
            meetingID: meetingID,
            meetingTitle: "Old",
            segmentID: UUID(),
            snippet: "old",
            timestamp: 1)
        newHit = AskSearchResult(
            meetingID: meetingID,
            meetingTitle: "New",
            segmentID: UUID(),
            snippet: "new",
            timestamp: 2)
        newerHit = AskSearchResult(
            meetingID: meetingID,
            meetingTitle: "Newer",
            segmentID: UUID(),
            snippet: "newer",
            timestamp: 4)
        citation = AskCitation(
            segmentID: UUID(),
            meetingID: meetingID,
            meetingTitle: "Test meeting",
            timestamp: 3,
            text: "El rollout queda para el viernes.")
    }
}

private struct AskMemoryPresentationFixture {
    let person = Person(preferredName: "Ana")
    let commitmentID = CommitmentID()
    let blockerID = DecisionCommitmentBlockerID()
    let decisionID = DecisionID()
    let meetingID = MeetingID()
    let segmentID = UUID()
    let blockerMeetingID = MeetingID()
    let blockerSegmentID = UUID()

    var citation: AskCitation {
        AskCitation(
            segmentID: segmentID,
            meetingID: meetingID,
            meetingTitle: "Test meeting",
            timestamp: 3,
            transcriptRevision: 0,
            text: "Ana will prepare the rollout.")
    }

    var commitmentCitation: AskCitation { citation }

    var blockerCitation: AskCitation {
        AskCitation(
            segmentID: blockerSegmentID,
            meetingID: blockerMeetingID,
            meetingTitle: "Security review",
            timestamp: 4,
            transcriptRevision: 0,
            text: "Security review must pass before the rollout.")
    }

    func page(
        subjectID: PersonID? = nil,
        count: Int = 1
    ) -> MeetingMemoryGraphFactPage {
        MeetingMemoryGraphFactPage(
            facts: (0..<count).map { index in
                let commitmentID = index == 0 ? self.commitmentID : CommitmentID()
                let segmentID = index == 0 ? self.segmentID : UUID()
                return MeetingMemoryGraphFact(
                id: .commitment(commitmentID),
                kind: .personCommittedTo,
                subject: .person(subjectID ?? person.id),
                object: .commitment(commitmentID),
                subjectText: "Ana",
                objectText: "Prepare the rollout",
                status: .active,
                occurredAt: Date(timeIntervalSince1970: 1_700_000_100),
                evidence: [MeetingMemoryGraphEvidence(
                    meetingID: meetingID,
                    meetingTitle: "Test meeting",
                    meetingStartedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    transcriptRevision: 0,
                    segmentID: segmentID,
                    startTime: 3,
                    endTime: 6,
                    text: "Ana will prepare the rollout.",
                    language: "en")],
                primaryEvidenceSegmentID: segmentID)
            },
            hasMore: false,
            projectionGeneration: 1,
            omittedStaleCount: 0,
            omittedUnavailableCount: 0)
    }

    func blockerPage(
        commitmentID: CommitmentID? = nil,
        count: Int = 1,
        kind: MeetingMemoryGraphFactKind = .decisionBlocksCommitment,
        factID: MeetingMemoryGraphFactID? = nil,
        subject: MeetingMemoryGraphFactEntity? = nil,
        object: MeetingMemoryGraphFactEntity? = nil,
        objectText: String = "Prepare the rollout",
        status: MeetingMemoryGraphFactStatus = .active,
        primarySegmentID: UUID? = nil,
        sharedSource: Bool = false
    ) -> MeetingMemoryGraphFactPage {
        let expectedCommitmentID = commitmentID ?? self.commitmentID
        let evidence = sharedSource
            ? [blockerEvidence]
            : [commitmentEvidence, blockerEvidence]
        return MeetingMemoryGraphFactPage(
            facts: (0..<count).map { _ in
                MeetingMemoryGraphFact(
                    id: factID ?? .blocker(blockerID),
                    kind: kind,
                    subject: subject ?? .decision(decisionID),
                    object: object ?? .commitment(expectedCommitmentID),
                    subjectText: "Security review must pass",
                    objectText: objectText,
                    status: status,
                    occurredAt: Date(timeIntervalSince1970: 1_700_000_200),
                    evidence: evidence,
                    primaryEvidenceSegmentID: primarySegmentID ?? blockerSegmentID)
            },
            hasMore: false,
            projectionGeneration: 1,
            omittedStaleCount: 0,
            omittedUnavailableCount: 0)
    }

    private var commitmentEvidence: MeetingMemoryGraphEvidence {
        MeetingMemoryGraphEvidence(
            meetingID: meetingID,
            meetingTitle: "Test meeting",
            meetingStartedAt: Date(timeIntervalSince1970: 1_700_000_000),
            transcriptRevision: 0,
            segmentID: segmentID,
            startTime: 3,
            endTime: 6,
            text: "Ana will prepare the rollout.",
            language: "en")
    }

    private var blockerEvidence: MeetingMemoryGraphEvidence {
        MeetingMemoryGraphEvidence(
            meetingID: blockerMeetingID,
            meetingTitle: "Security review",
            meetingStartedAt: Date(timeIntervalSince1970: 1_700_000_150),
            transcriptRevision: 0,
            segmentID: blockerSegmentID,
            startTime: 4,
            endTime: 8,
            text: "Security review must pass before the rollout.",
            language: "en")
    }
}

private struct AskTopicMemoryPresentationFixture {
    let topic = Topic(preferredLabel: "Model rollout")
    let decisionID = DecisionID()
    let linkID = DecisionTopicLinkID()
    let relationshipEventID = DecisionEventID()
    let replacedDecisionID = DecisionID()
    let topicEvidenceID = TopicMeetingEvidenceID()
    let meetingID = MeetingID()
    let replacedMeetingID = MeetingID()
    let segmentID = UUID()
    let replacedSegmentID = UUID()
    let meetingStartedAt = Date(timeIntervalSince1970: 1_700_000_000)

    var citation: AskCitation {
        AskCitation(
            segmentID: segmentID,
            meetingID: meetingID,
            meetingTitle: "Test meeting",
            timestamp: 3,
            transcriptRevision: 0,
            text: "We ship the model on Friday.")
    }

    var replacedCitation: AskCitation {
        AskCitation(
            segmentID: replacedSegmentID,
            meetingID: replacedMeetingID,
            meetingTitle: "Planning baseline",
            timestamp: 4,
            transcriptRevision: 0,
            text: "We ship the model on Thursday.")
    }

    func page(
        topicID: TopicID? = nil,
        count: Int = 1
    ) -> MeetingMemoryGraphFactPage {
        MeetingMemoryGraphFactPage(
            facts: (0..<count).map { index in
                let linkID = index == 0 ? self.linkID : DecisionTopicLinkID()
                let decisionID = index == 0 ? self.decisionID : DecisionID()
                let segmentID = index == 0 ? self.segmentID : UUID()
                return MeetingMemoryGraphFact(
                id: .decisionAboutness(linkID),
                kind: .decisionAboutTopic,
                subject: .decision(decisionID),
                object: .topic(topicID ?? topic.id),
                subjectText: "Ship the model on Friday",
                objectText: "Model rollout",
                status: .confirmed,
                occurredAt: Date(timeIntervalSince1970: 1_700_000_100),
                evidence: [MeetingMemoryGraphEvidence(
                    meetingID: meetingID,
                    meetingTitle: "Test meeting",
                    meetingStartedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    transcriptRevision: 0,
                    segmentID: segmentID,
                    startTime: 3,
                    endTime: 6,
                    text: "We ship the model on Friday.",
                    language: "en")],
                primaryEvidenceSegmentID: segmentID)
            },
            hasMore: false,
            projectionGeneration: 1,
            omittedStaleCount: 0,
            omittedUnavailableCount: 0)
    }

    func firstDiscussionPage(
        topicID: TopicID? = nil,
        meetingID: MeetingID? = nil,
        occurredAtOffset: TimeInterval = 3,
        factCount: Int = 1,
        sourceCount: Int = 1,
        hasMore: Bool = false,
        omittedStaleCount: Int = 0
    ) -> MeetingMemoryGraphFactPage {
        let resolvedMeetingID = meetingID ?? self.meetingID
        return MeetingMemoryGraphFactPage(
            facts: (0..<factCount).map { factIndex in
                let factEvidenceID = factIndex == 0
                    ? topicEvidenceID
                    : TopicMeetingEvidenceID()
                let primarySegmentID = factIndex == 0 ? segmentID : UUID()
                let sources: [MeetingMemoryGraphEvidence] = (0..<sourceCount).map {
                    sourceIndex in
                    let sourceSegmentID: UUID = sourceIndex == 0
                        ? primarySegmentID
                        : UUID()
                    let sourceStart = TimeInterval(3 + sourceIndex)
                    return MeetingMemoryGraphEvidence(
                        meetingID: self.meetingID,
                        meetingTitle: "Test meeting",
                        meetingStartedAt: meetingStartedAt,
                        transcriptRevision: 0,
                        segmentID: sourceSegmentID,
                        startTime: sourceStart,
                        endTime: sourceStart + 3,
                        text: "We ship the model on Friday.",
                        language: "en")
                }
                return MeetingMemoryGraphFact(
                    id: .topicEvidence(factEvidenceID),
                    kind: .topicDiscussedInMeeting,
                    subject: .topic(topicID ?? topic.id),
                    object: .meeting(resolvedMeetingID),
                    subjectText: "Model rollout",
                    objectText: "Test meeting",
                    status: .confirmed,
                    occurredAt: meetingStartedAt.addingTimeInterval(
                        occurredAtOffset),
                    evidence: sources,
                    primaryEvidenceSegmentID: primarySegmentID)
            },
            hasMore: hasMore,
            projectionGeneration: 1,
            omittedStaleCount: omittedStaleCount,
            omittedUnavailableCount: 0)
    }

    func conflictPage(
        factCount: Int = 1,
        kind: MeetingMemoryGraphFactKind = .decisionSupersededDecision,
        replacedDecisionID: DecisionID? = nil,
        sourceCount: Int = 2,
        primarySegmentID: UUID? = nil,
        successorStatement: String = "Ship the model on Friday",
        status: MeetingMemoryGraphFactStatus = .confirmed,
        usesRelationshipID: Bool = true
    ) -> MeetingMemoryGraphFactPage {
        MeetingMemoryGraphFactPage(
            facts: (0..<factCount).map { index in
                let eventID = index == 0 ? relationshipEventID : DecisionEventID()
                let successorID = index == 0 ? decisionID : DecisionID()
                let replacedID = index == 0
                    ? (replacedDecisionID ?? self.replacedDecisionID)
                    : DecisionID()
                let oldSegmentID = index == 0 ? self.replacedSegmentID : UUID()
                let newSegmentID = index == 0 ? self.segmentID : UUID()
                let oldMeetingID = index == 0 ? self.replacedMeetingID : MeetingID()
                let newMeetingID = index == 0 ? self.meetingID : MeetingID()
                let evidence = [
                    MeetingMemoryGraphEvidence(
                        meetingID: oldMeetingID,
                        meetingTitle: "Planning baseline",
                        meetingStartedAt: meetingStartedAt.addingTimeInterval(-86_400),
                        transcriptRevision: 0,
                        segmentID: oldSegmentID,
                        startTime: 4,
                        endTime: 7,
                        text: "We ship the model on Thursday.",
                        language: "en"),
                    MeetingMemoryGraphEvidence(
                        meetingID: newMeetingID,
                        meetingTitle: "Test meeting",
                        meetingStartedAt: meetingStartedAt,
                        transcriptRevision: 0,
                        segmentID: newSegmentID,
                        startTime: 3,
                        endTime: 6,
                        text: "We ship the model on Friday.",
                        language: "en")
                ]
                return MeetingMemoryGraphFact(
                    id: usesRelationshipID
                        ? .decisionRelationship(eventID)
                        : .decisionAboutness(DecisionTopicLinkID()),
                    kind: kind,
                    subject: .decision(successorID),
                    object: .decision(replacedID),
                    subjectText: successorStatement,
                    objectText: "Ship the model on Thursday",
                    status: status,
                    occurredAt: Date(timeIntervalSince1970: 1_700_000_100),
                    evidence: Array(evidence.prefix(sourceCount)),
                    primaryEvidenceSegmentID: primarySegmentID ?? newSegmentID)
            },
            hasMore: false,
            projectionGeneration: 1,
            omittedStaleCount: 0,
            omittedUnavailableCount: 0)
    }
}

@MainActor
private final class ControlledAskModelClient: AskModelClient {
    private(set) var searchRequests: [String] = []
    private(set) var answerRequests: [String] = []
    private var searchContinuations: [String: CheckedContinuation<[AskSearchResult], Error>] = [:]
    private var answerContinuations: [String: CheckedContinuation<AskMeetingAnswer, Error>] = [:]
    private var evidenceReceivers: [String: AskEvidenceReceiver] = [:]

    func searchAskMeetings(
        _ query: String,
        limit _: Int
    ) async throws -> [AskSearchResult] {
        searchRequests.append(query)
        return try await withCheckedThrowingContinuation { continuation in
            searchContinuations[query] = continuation
        }
    }

    func answerAskMeetings(
        _ question: String,
        limit _: Int
    ) async throws -> AskMeetingAnswer {
        answerRequests.append(question)
        return try await withCheckedThrowingContinuation { continuation in
            answerContinuations[question] = continuation
        }
    }

    func answerAskMeetings(
        _ question: String,
        limit _: Int,
        onEvidence: @escaping AskEvidenceReceiver
    ) async throws -> AskMeetingAnswer {
        answerRequests.append(question)
        evidenceReceivers[question] = onEvidence
        return try await withCheckedThrowingContinuation { continuation in
            answerContinuations[question] = continuation
        }
    }

    func completeSearch(_ query: String, with hits: [AskSearchResult]) {
        searchContinuations.removeValue(forKey: query)?.resume(returning: hits)
    }

    func completeAnswer(_ question: String, with answer: AskMeetingAnswer) {
        evidenceReceivers.removeValue(forKey: question)
        answerContinuations.removeValue(forKey: question)?.resume(returning: answer)
    }

    func failAnswer(_ question: String) {
        evidenceReceivers.removeValue(forKey: question)
        answerContinuations.removeValue(forKey: question)?
            .resume(throwing: AskPresentationTestError.refused)
    }

    func publishEvidence(
        _ question: String,
        update: AskEvidenceUpdate
    ) async {
        await evidenceReceivers[question]?(update)
    }
}

@MainActor
private final class ControlledAskMemoryModelClient: AskMemoryModelClient {
    private(set) var peopleRequests: [String] = []
    private(set) var peopleLimits: [Int] = []
    private(set) var commitmentRequests: [PersonID] = []
    private(set) var commitmentLimits: [Int] = []
    private(set) var blockerRequests: [CommitmentID] = []
    private(set) var blockerLimits: [Int] = []
    private(set) var topicRequests: [String] = []
    private(set) var topicLimits: [Int] = []
    private(set) var decisionRequests: [TopicID] = []
    private(set) var decisionLimits: [Int] = []
    private(set) var firstDiscussionRequests: [TopicID] = []
    private(set) var conflictRequests: [TopicID] = []
    private(set) var conflictLimits: [Int] = []
    private var peopleContinuations:
        [String: CheckedContinuation<[Person], Error>] = [:]
    private var commitmentContinuations:
        [PersonID: [CheckedContinuation<MeetingMemoryGraphQueryResult, Error>]] = [:]
    private var blockerContinuations:
        [CommitmentID: [CheckedContinuation<MeetingMemoryGraphQueryResult, Error>]] = [:]
    private var topicContinuations:
        [String: CheckedContinuation<[Topic], Error>] = [:]
    private var decisionContinuations:
        [TopicID: [CheckedContinuation<MeetingMemoryGraphQueryResult, Error>]] = [:]
    private var firstDiscussionContinuations:
        [TopicID: [CheckedContinuation<MeetingMemoryGraphQueryResult, Error>]] = [:]
    private var conflictContinuations:
        [TopicID: [CheckedContinuation<MeetingMemoryGraphQueryResult, Error>]] = [:]

    func searchAskMemoryPeople(
        _ query: String,
        limit: Int
    ) async throws -> [Person] {
        peopleRequests.append(query)
        peopleLimits.append(limit)
        return try await withCheckedThrowingContinuation { continuation in
            peopleContinuations[query] = continuation
        }
    }

    func loadAskMemoryPersonCommitments(
        personID: PersonID,
        limit: Int
    ) async throws -> MeetingMemoryGraphQueryResult {
        commitmentRequests.append(personID)
        commitmentLimits.append(limit)
        return try await withCheckedThrowingContinuation { continuation in
            commitmentContinuations[personID, default: []].append(continuation)
        }
    }

    func loadAskMemoryCommitmentBlockers(
        commitmentID: CommitmentID,
        limit: Int
    ) async throws -> MeetingMemoryGraphQueryResult {
        blockerRequests.append(commitmentID)
        blockerLimits.append(limit)
        return try await withCheckedThrowingContinuation { continuation in
            blockerContinuations[commitmentID, default: []].append(continuation)
        }
    }

    func searchAskMemoryTopics(
        _ query: String,
        limit: Int
    ) async throws -> [Topic] {
        topicRequests.append(query)
        topicLimits.append(limit)
        return try await withCheckedThrowingContinuation { continuation in
            topicContinuations[query] = continuation
        }
    }

    func loadAskMemoryDecisionHistory(
        topicID: TopicID,
        limit: Int
    ) async throws -> MeetingMemoryGraphQueryResult {
        decisionRequests.append(topicID)
        decisionLimits.append(limit)
        return try await withCheckedThrowingContinuation { continuation in
            decisionContinuations[topicID, default: []].append(continuation)
        }
    }

    func loadAskMemoryTopicFirstDiscussion(
        topicID: TopicID
    ) async throws -> MeetingMemoryGraphQueryResult {
        firstDiscussionRequests.append(topicID)
        return try await withCheckedThrowingContinuation { continuation in
            firstDiscussionContinuations[topicID, default: []].append(continuation)
        }
    }

    func loadAskMemoryDecisionConflicts(
        topicID: TopicID,
        limit: Int
    ) async throws -> MeetingMemoryGraphQueryResult {
        conflictRequests.append(topicID)
        conflictLimits.append(limit)
        return try await withCheckedThrowingContinuation { continuation in
            conflictContinuations[topicID, default: []].append(continuation)
        }
    }

    func completePeople(_ query: String, with people: [Person]) {
        peopleContinuations.removeValue(forKey: query)?.resume(returning: people)
    }

    func completeCommitments(
        for personID: PersonID,
        with result: MeetingMemoryGraphQueryResult
    ) {
        guard var continuations = commitmentContinuations[personID],
              !continuations.isEmpty
        else { return }
        let continuation = continuations.removeFirst()
        commitmentContinuations[personID] = continuations
        continuation.resume(returning: result)
    }

    func completeBlockers(
        for commitmentID: CommitmentID,
        with result: MeetingMemoryGraphQueryResult
    ) {
        guard var continuations = blockerContinuations[commitmentID],
              !continuations.isEmpty
        else { return }
        let continuation = continuations.removeFirst()
        blockerContinuations[commitmentID] = continuations
        continuation.resume(returning: result)
    }

    func completeTopics(_ query: String, with topics: [Topic]) {
        topicContinuations.removeValue(forKey: query)?.resume(returning: topics)
    }

    func completeDecisions(
        for topicID: TopicID,
        with result: MeetingMemoryGraphQueryResult
    ) {
        guard var continuations = decisionContinuations[topicID],
              !continuations.isEmpty
        else { return }
        let continuation = continuations.removeFirst()
        decisionContinuations[topicID] = continuations
        continuation.resume(returning: result)
    }

    func completeFirstDiscussion(
        for topicID: TopicID,
        with result: MeetingMemoryGraphQueryResult
    ) {
        guard var continuations = firstDiscussionContinuations[topicID],
              !continuations.isEmpty
        else { return }
        let continuation = continuations.removeFirst()
        firstDiscussionContinuations[topicID] = continuations
        continuation.resume(returning: result)
    }

    func completeConflicts(
        for topicID: TopicID,
        with result: MeetingMemoryGraphQueryResult
    ) {
        guard var continuations = conflictContinuations[topicID],
              !continuations.isEmpty
        else { return }
        let continuation = continuations.removeFirst()
        conflictContinuations[topicID] = continuations
        continuation.resume(returning: result)
    }
}

private enum AskPresentationTestError: Error {
    case timeout
    case refused
}
