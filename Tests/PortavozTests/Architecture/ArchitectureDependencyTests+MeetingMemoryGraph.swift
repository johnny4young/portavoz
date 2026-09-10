import ApplicationKit
import Foundation
import XCTest

extension ArchitectureDependencyTests {
    func testCommitmentContinuityStoresOnlyExplicitConfirmedTruth() throws {
        let core = try Self.contents(
            of: "Sources/PortavozCore/CommitmentContinuity.swift")
        let schema = try Self.contents(
            of: "Sources/StorageKit/Schema+CommitmentContinuity.swift")
        let storage = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+CommitmentContinuity.swift")
        let bundle = try Self.contents(
            of: "Sources/IntegrationsKit/MeetingBundle.swift")
        let meetingSync = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+SyncAggregate.swift")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertTrue(core.contains("case confirmed"))
        XCTAssertFalse(core.contains("case proposed"))
        XCTAssertTrue(core.contains("case generatedActionItem(UUID)"))
        XCTAssertTrue(core.contains("case userNote(UUID)"))
        XCTAssertTrue(schema.contains("status IN ('confirmed', 'done', 'dismissed')"))
        XCTAssertTrue(schema.contains("commitment history is immutable"))
        XCTAssertTrue(storage.contains(
            "generated ActionItem lacks current direct transcript evidence"))
        XCTAssertTrue(storage.contains(
            "canonical owner must be an exact live PersonID"))
        XCTAssertTrue(storage.contains("applyCommitmentContinuityEnvelope"))
        XCTAssertFalse(bundle.contains("CommitmentContinuityEnvelope"))
        XCTAssertFalse(meetingSync.contains("CommitmentContinuityEnvelope"))
        XCTAssertTrue(decisions.contains("## D237"))
        XCTAssertTrue(decisions.contains(
            "Persist only explicitly confirmed commitment continuity"))
    }

    func testMeetingMemoryGraphStartsWithQueriesEvidenceAndAbstention() throws {
        let harness = try Self.contents(
            of: "scripts/meeting_memory_graph_quality.py")
        let fixture = try Self.jsonObject(
            at: "Fixtures/MeetingMemoryGraph/public-synthetic-v1.json")
        let cases = try XCTUnwrap(fixture["cases"] as? [[String: Any]])
        let makefile = try Self.contents(of: "Makefile")
        let hygiene = try Self.contents(
            of: "scripts/check-repository-hygiene.sh")
        let package = try Self.contents(of: "Package.swift")
        let schema = try Self.contents(of: "Sources/StorageKit/Schema.swift")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertEqual(cases.count, 36)
        for required in [
            "decisionHistory", "changeSince", "personCommitments",
            "commitmentBlockers", "firstDiscussion", "decisionConflicts",
            "current confirmed/manual truth", "ABSTENTION_REASON_BY_JOB",
        ] {
            XCTAssertTrue(
                harness.contains(required),
                "Meeting Memory Graph query contract is missing \(required)")
        }
        XCTAssertTrue(makefile.contains("test-meeting-memory-graph-quality:"))
        XCTAssertTrue(hygiene.contains(
            "Tests.Tooling.test_meeting_memory_graph_quality"))
        XCTAssertFalse(package.localizedCaseInsensitiveContains("graph database"))
        XCTAssertFalse(package.localizedCaseInsensitiveContains("neo4j"))
        XCTAssertTrue(schema.contains("public static let version = 51"))
        XCTAssertTrue(decisions.contains("## D270"))
    }


    /// GRAPH-5a: the decision-topic edge derives only from the explicit
    /// authority. Co-occurrence — a decision source and topic evidence sharing
    /// a meeting — must never appear in either rebuild site, and the confirm
    /// trigger keeps the ownership check that makes the rule hold below Swift.
    func testDecisionTopicEdgeDerivesOnlyFromExplicitAuthority() throws {
        let topicRebuild = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+MeetingMemoryGraphTopics.swift")
        let migration = try Self.contents(
            of: "Sources/StorageKit/Schema+DecisionTopicAuthority.swift")
        let store = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+DecisionTopicLink.swift")

        XCTAssertTrue(topicRebuild.contains(
            "func rebuildMeetingMemoryGraphDecisionTopics"))
        for insert in [
            // Decision scope selects from the authority…
            "SELECT DISTINCT link.topicID\n                FROM decisionTopicLink AS link",
            // …and so does the topic scope.
            "SELECT DISTINCT link.decisionID, ?\n                FROM decisionTopicLink AS link",
        ] {
            XCTAssertTrue(
                topicRebuild.contains(insert),
                "decision-topic edges must derive from decisionTopicLink")
        }
        // The rebuild never reaches for co-occurrence to fill this edge.
        XCTAssertFalse(topicRebuild.contains(
            "INSERT OR IGNORE INTO meetingMemoryGraphDecisionTopic (\n"
                + "                        decisionID, topicID\n"
                + "                    )\n"
                + "                    SELECT DISTINCT source"))
        XCTAssertTrue(migration.contains(
            "owned.summaryDecisionID = source.summaryDecisionID"),
            "the confirm trigger keeps its evidence-ownership check")
        for helper in [
            "createDecisionTopicLinkProjectionImmutabilityTriggers",
            "createDecisionTopicLinkHistoryImmutabilityTriggers",
            "createDecisionTopicLinkConfirmationSourceTrigger",
            "createDecisionTopicLinkRetractionTrigger"
        ] {
            XCTAssertTrue(
                migration.contains(helper),
                "decision-topic schema constraints keep a focused owner: \(helper)")
        }
        XCTAssertFalse(migration.contains(
            "swiftlint:disable:next function_body_length"))
        XCTAssertTrue(store.contains(
            "evidence must already belong to the decision"))
        XCTAssertTrue(store.contains(
            "private struct DecisionTopicLinkConfirmationWrite"))
        XCTAssertTrue(store.contains(
            "validateUnusedDecisionTopicLinkConfirmationIdentities"))
        XCTAssertTrue(store.contains(
            "let context = try decisionTopicLinkConfirmationContext"))
        XCTAssertTrue(store.contains("return try write.insert(in: database)"))
        XCTAssertFalse(store.contains(
            "swiftlint:disable:next function_body_length"))
        XCTAssertTrue(migration.contains(
            "decisionTopicLink_one_active"))
    }

    func testTopicGraphProjectionKeepsAFocusedOwner() throws {
        let rebuild = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+MeetingMemoryGraph.swift")
        let topicRebuild = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+MeetingMemoryGraphTopics.swift")

        XCTAssertTrue(rebuild.contains(
            "try rebuildMeetingMemoryGraphTopic(scope.id, in: database)"))
        XCTAssertTrue(rebuild.contains(
            "let topicEdges = try rebuildMeetingMemoryGraphDecisionTopics"))
        for helper in [
            "clearMeetingMemoryGraphTopicEvidenceEdges",
            "publishMeetingMemoryGraphTopicMeetings",
            "publishMeetingMemoryGraphTopicQuestions",
            "rebuildMeetingMemoryGraphTopicDecisions"
        ] {
            XCTAssertTrue(
                topicRebuild.contains(helper),
                "topic graph projection keeps a focused owner: \(helper)")
        }
        XCTAssertFalse(topicRebuild.contains(
            "swiftlint:disable:next function_body_length"))
    }


    /// GRAPH-5b: decisionConflicts and changeSince answer only from the
    /// decision-topic authority and decision continuity, rehydrated with
    /// current evidence. The anchor resolves before topology, and both jobs'
    /// canonical abstention reasons exist as typed cases.
    func testDecisionRelationshipQueriesDeriveFromAuthorityOnly() throws {
        let core = try Self.contents(
            of: "Sources/PortavozCore/MeetingMemoryGraphQuery.swift")
        let storage = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+DecisionRelationshipQuery.swift")
        let application = try Self.contents(
            of: "Sources/ApplicationKit/LoadDecisionRelationships.swift")

        let history = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+DecisionHistoryQuery.swift")
        XCTAssertTrue(core.contains("decisionSupersededDecision"))
        XCTAssertTrue(core.contains("decisionAboutTopic"))
        XCTAssertTrue(core.contains("unsupportedConflict"))
        XCTAssertTrue(core.contains("missingTemporalBaseline"))
        XCTAssertTrue(core.contains("insufficientConfirmedDecision"))
        XCTAssertTrue(history.contains("DecisionTopicLinkRecord"))
        XCTAssertFalse(
            history.contains("topicMeetingEvidence"),
            "decision history never derives from meeting co-occurrence")
        XCTAssertTrue(
            history.contains("continuity.decision.status == .confirmed"),
            "superseded truth never answers what was decided")
        XCTAssertTrue(history.contains("private struct DecisionHistoryPage"))
        XCTAssertTrue(history.contains("guard page.needsHydration else { continue }"))
        XCTAssertTrue(storage.contains("FROM decisionTopicLink AS link"))
        XCTAssertFalse(
            storage.contains("topicMeetingEvidence"),
            "aboutness never derives from meeting co-occurrence")
        XCTAssertTrue(storage.contains("loadDecisionContinuity"))
        XCTAssertTrue(storage.contains("timelineEvidence(for:"))
        XCTAssertTrue(storage.contains("graphContainsDecisionTopicEdge"))
        XCTAssertTrue(storage.contains("private struct DecisionRelationshipPage"))
        XCTAssertTrue(storage.contains("guard page.needsHydration else { break }"))
        XCTAssertFalse(storage.contains("swiftlint:disable:next function_body_length"))
        XCTAssertTrue(
            storage.contains("return .abstained(.missingTemporalBaseline)"),
            "an unresolvable anchor abstains before topology")
        XCTAssertTrue(application.contains("LoadDecisionConflicts"))
        XCTAssertTrue(application.contains("LoadChangeSince"))
        XCTAssertTrue(application.contains("LoadDecisionHistory"))
    }

    func testBlockerQueryUsesGraphTopologyButRehydratesAuthority() throws {
        let core = try Self.contents(
            of: "Sources/PortavozCore/MeetingMemoryGraphQuery.swift")
        let storage = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+MeetingMemoryGraphQuery.swift")
        let application = try Self.contents(
            of: "Sources/ApplicationKit/LoadCommitmentBlockers.swift")
        let askServices = try Self.contents(
            of: "Sources/portavoz-app/AppServices+Ask.swift")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertFalse(core.contains("import StorageKit"))
        XCTAssertTrue(core.contains("decisionBlocksCommitment"))
        XCTAssertTrue(core.contains("unsupportedCausalLink"))
        XCTAssertTrue(core.contains("candidateBudgetExceeded"))
        XCTAssertTrue(storage.contains(
            "meetingMemoryGraphDecisionCommitmentBlocker"))
        XCTAssertTrue(storage.contains(
            "loadDecisionCommitmentBlockerContinuity"))
        XCTAssertTrue(storage.contains("loadCommitmentContinuity"))
        XCTAssertTrue(storage.contains("timelineEvidence("))
        XCTAssertTrue(storage.contains(
            "blocker.decisionID = edge.decisionID"))
        XCTAssertTrue(storage.contains(
            "blocker.commitmentID = edge.commitmentID"))
        XCTAssertTrue(storage.contains("keys: Array(keys.prefix(limit))"))
        XCTAssertTrue(storage.contains(
            "facts: Array(hydration.facts.prefix(query.itemLimit))"))
        XCTAssertTrue(application.contains(
            "protocol CommitmentBlockerFactReading"))
        XCTAssertTrue(application.contains("struct LoadCommitmentBlockers"))
        XCTAssertTrue(askServices.contains("LoadCommitmentBlockers"))
        XCTAssertTrue(decisions.contains("## D278"))
    }

    func testCanonicalBlockerCorpusTraversesPublicProductBoundaries() throws {
        let adapter = try Self.contents(
            of: "Tests/PortavozTests/MeetingMemoryGraphProductConformanceTests.swift")
        let fixture = try Self.jsonObject(
            at: "Fixtures/MeetingMemoryGraph/public-synthetic-v1.json")
        let cases = try XCTUnwrap(fixture["cases"] as? [[String: Any]])
        let blockerCases = cases.filter {
            $0["job"] as? String == "commitmentBlockers"
        }
        let askServices = try Self.contents(
            of: "Sources/portavoz-app/AppServices+Ask.swift")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertEqual(blockerCases.count, 6)
        for boundary in [
            "saveSummary(",
            "confirmCommitment(",
            "confirmDecision(",
            "confirmDecisionCommitmentBlocker(",
            "ProjectMeetingMemoryGraph(",
            "LoadCommitmentBlockers(",
        ] {
            XCTAssertTrue(
                adapter.contains(boundary),
                "canonical blocker mapping bypasses \(boundary)")
        }
        XCTAssertTrue(adapter.contains("public-synthetic-v1.json"))
        XCTAssertTrue(adapter.contains("unsupportedCausalLink"))
        XCTAssertFalse(adapter.contains("import IntelligenceKit"))
        XCTAssertFalse(adapter.contains("database.write"))
        XCTAssertTrue(askServices.contains("LoadCommitmentBlockers"))
        XCTAssertTrue(decisions.contains("## D279"))
    }

    func testFirstDiscussionQueryKeepsEarliestAuthorityOutsideGraph() throws {
        let core = try Self.contents(
            of: "Sources/PortavozCore/MeetingMemoryGraphQuery.swift")
        let storage = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+TopicFirstDiscussionQuery.swift")
        let evidenceStorage = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+TopicContinuityEvidence.swift")
        let application = try Self.contents(
            of: "Sources/ApplicationKit/LoadTopicFirstDiscussion.swift")
        let adapter = try Self.contents(
            of: "Tests/PortavozTests/TopicFirstDiscussionProductConformanceTests.swift")
        let fixture = try Self.jsonObject(
            at: "Fixtures/MeetingMemoryGraph/public-synthetic-v1.json")
        let cases = try XCTUnwrap(fixture["cases"] as? [[String: Any]])
        let firstDiscussionCases = cases.filter {
            $0["job"] as? String == "firstDiscussion"
        }
        let askServices = try Self.contents(
            of: "Sources/portavoz-app/AppServices+Ask.swift")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertEqual(firstDiscussionCases.count, 6)
        XCTAssertFalse(core.contains("import StorageKit"))
        XCTAssertTrue(core.contains("struct TopicFirstDiscussionQuery"))
        XCTAssertTrue(core.contains("enum MeetingMemoryGraphFactID"))
        XCTAssertTrue(core.contains("case topicDiscussedInMeeting"))
        XCTAssertTrue(core.contains("case projectionInconsistent"))
        XCTAssertTrue(storage.contains("loadTopicEvidenceOccurrences("))
        XCTAssertTrue(storage.contains("for occurrence in occurrences"))
        XCTAssertTrue(storage.contains("switch earliestEvidence.availability"))
        XCTAssertTrue(evidenceStorage.contains("topicEvidencePrecedes("))
        XCTAssertTrue(storage.contains("meetingMemoryGraphMeetingTopic"))
        XCTAssertTrue(storage.contains("graphContainsTopicMeetingEdge"))
        XCTAssertTrue(storage.contains("meetingID: earliestEvidence.meetingID"))
        XCTAssertTrue(storage.contains("id: .topicEvidence(earliestEvidence.id)"))
        XCTAssertTrue(storage.contains("timelineEvidence("))
        XCTAssertTrue(application.contains("protocol TopicFirstDiscussionReading"))
        XCTAssertTrue(application.contains("struct LoadTopicFirstDiscussion"))
        for boundary in [
            "createTopicAndLink(",
            "linkTopic(",
            "ProjectMeetingMemoryGraph(",
            "LoadTopicFirstDiscussion(",
        ] {
            XCTAssertTrue(
                adapter.contains(boundary),
                "canonical first-discussion mapping bypasses \(boundary)")
        }
        XCTAssertTrue(adapter.contains("public-synthetic-v1.json"))
        XCTAssertTrue(adapter.contains("staleEvidenceOnly"))
        XCTAssertFalse(adapter.contains("import GRDB"))
        XCTAssertFalse(adapter.contains("@testable"))
        XCTAssertFalse(adapter.contains("database.write"))
        XCTAssertFalse(adapter.contains("import IntelligenceKit"))
        XCTAssertTrue(askServices.contains("LoadTopicFirstDiscussion"))
        XCTAssertTrue(decisions.contains("## D280"))
    }

    func testPersonCommitmentFactsRequireExactCurrentOwnership() throws {
        let core = try Self.contents(
            of: "Sources/PortavozCore/MeetingMemoryGraphQuery.swift")
        let storage = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+PersonCommitmentsQuery.swift")
        let application = try Self.contents(
            of: "Sources/ApplicationKit/LoadPersonCommitments.swift")
        let askServices = try Self.contents(
            of: "Sources/portavoz-app/AppServices+Ask.swift")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertFalse(core.contains("import StorageKit"))
        XCTAssertTrue(core.contains("struct PersonCommitmentsQuery"))
        XCTAssertTrue(core.contains("case personCommittedTo"))
        XCTAssertTrue(core.contains("case personUnavailable"))
        XCTAssertTrue(core.contains("case noActiveCommitments"))
        XCTAssertTrue(storage.contains("meetingMemoryGraphCommitmentPerson"))
        XCTAssertTrue(storage.contains(
            "commitment.canonicalPersonID = edge.personID"))
        XCTAssertTrue(storage.contains("activeCommitmentCount"))
        XCTAssertTrue(storage.contains("loadCommitmentContinuity"))
        XCTAssertTrue(storage.contains("latestReassignment"))
        XCTAssertTrue(storage.contains("reassignmentEvidence + sourceEvidence"))
        XCTAssertTrue(storage.contains("timelineEvidence(for:"))
        XCTAssertTrue(storage.contains("projectionInconsistent"))
        XCTAssertTrue(application.contains("protocol PersonCommitmentFactReading"))
        XCTAssertTrue(application.contains("struct LoadPersonCommitments"))
        XCTAssertTrue(askServices.contains("LoadPersonCommitments"))
        XCTAssertTrue(decisions.contains("## D281"))
    }

    func testCanonicalPersonCommitmentsResolveAmbiguityBeforeStorage() throws {
        let core = try Self.contents(
            of: "Sources/PortavozCore/MeetingMemoryGraphQuery.swift")
        let identity = try Self.contents(
            of: "Sources/ApplicationKit/CanonicalPeople.swift")
        let application = try Self.contents(
            of: "Sources/ApplicationKit/LoadPersonCommitments.swift")
        let adapter = try Self.contents(
            of: "Tests/PortavozTests/PersonCommitmentsProductConformanceTests.swift")
        let fixture = try Self.jsonObject(
            at: "Fixtures/MeetingMemoryGraph/public-synthetic-v1.json")
        let cases = try XCTUnwrap(fixture["cases"] as? [[String: Any]])
        let personCommitmentCases = cases.filter {
            $0["job"] as? String == "personCommitments"
        }
        let askServices = try Self.contents(
            of: "Sources/portavoz-app/AppServices+Ask.swift")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertEqual(personCommitmentCases.count, 6)
        XCTAssertTrue(core.contains("case ambiguousPerson"))
        XCTAssertTrue(identity.contains(
            "protocol CanonicalPersonCandidateReading"))
        XCTAssertTrue(identity.contains(
            "protocol CanonicalPeopleStore: CanonicalPersonCandidateReading"))
        XCTAssertTrue(application.contains("struct PersonCommitmentsAliasQuery"))
        XCTAssertTrue(application.contains("struct LoadPersonCommitmentsByAlias"))
        XCTAssertTrue(application.contains("guard candidates.count == 1"))
        for boundary in [
            "createPersonAndLink(",
            "linkSpeaker(",
            "saveSummary(",
            "confirmCommitment(",
            "applyCommitmentTransition(",
            "ProjectMeetingMemoryGraph(",
            "LoadPersonCommitmentsByAlias(",
        ] {
            XCTAssertTrue(
                adapter.contains(boundary),
                "canonical person-commitment mapping bypasses \(boundary)")
        }
        XCTAssertTrue(adapter.contains("public-synthetic-v1.json"))
        XCTAssertTrue(adapter.contains("ambiguousPerson"))
        XCTAssertFalse(adapter.contains("import GRDB"))
        XCTAssertFalse(adapter.contains("@testable"))
        XCTAssertFalse(adapter.contains("database.write"))
        XCTAssertFalse(adapter.contains("import IntelligenceKit"))
        XCTAssertFalse(askServices.contains("LoadPersonCommitmentsByAlias"))
        XCTAssertTrue(decisions.contains("## D282"))
    }

    func testMeetingMemoryGraphProjectTruthTracksDeliveredSystem() throws {
        let architecture = try Self.contents(of: "docs/ARCHITECTURE.md")
        let intelligence = try Self.contents(
            of: "docs/specs/04-intelligence.md")
        let quality = try Self.contents(of: "docs/specs/08-quality.md")
        let gaps = try Self.contents(of: "docs/GAPS.md")

        XCTAssertTrue(architecture.contains(
            "delegates to all six source-backed"))
        XCTAssertTrue(architecture.contains(
            "reduced the same 10,000-meeting\n"
                + "rebuild from 17.6 minutes to 27.2 seconds"))
        XCTAssertTrue(intelligence.contains(
            "same-generation profile return re-admit the exact completed"))
        XCTAssertTrue(quality.contains(
            "### Complete graph product truth, scale, and profile recovery "
                + "(D308–D314/D360)"))
        XCTAssertTrue(gaps.contains(
            "| T30 | Meeting Memory Graph serves all six source-backed jobs"))
        XCTAssertTrue(gaps.contains(
            "ordinary free-form Ask, command palette, CLI, MCP, and meeting briefs "
                + "remain transcript-only"))
        XCTAssertTrue(gaps.contains(
            "makes same-generation profile re-admission deterministic"))
        XCTAssertFalse(gaps.contains(
            "source generation stalls until the next authority write"))
        XCTAssertFalse(gaps.contains(
            "the other three D270 job adapters"))
        XCTAssertFalse(gaps.contains(
            "Finish the remaining exact query adapters"))
    }

    func testReleasedAskMemoryRequiresExactPersonSelection() throws {
        let model = try Self.contents(
            of: "Sources/portavoz-app/AskMemoryModel.swift")
        let view = try Self.contents(
            of: "Sources/portavoz-app/AskMemoryView.swift")
        let askView = try Self.contents(
            of: "Sources/portavoz-app/AskView.swift")
        let composition = try Self.contents(
            of: "Sources/portavoz-app/AppServices+Ask.swift")
        let fixture = try Self.contents(
            of: "Sources/portavoz-app/AppServices+UITestFixtures.swift")
        let uiTest = try Self.contents(
            of: "Tests/PortavozUITests/LibraryUITests.swift")
        let architecture = try Self.contents(of: "docs/ARCHITECTURE.md")
        let intelligence = try Self.contents(
            of: "docs/specs/04-intelligence.md")
        let quality = try Self.contents(of: "docs/specs/08-quality.md")
        let gaps = try Self.contents(of: "docs/GAPS.md")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertTrue(model.contains("final class AskMemoryModel"))
        XCTAssertTrue(model.contains("static let visiblePersonLimit = 20"))
        XCTAssertTrue(model.contains(
            "personRequestLimit = visiblePersonLimit + 1"))
        XCTAssertTrue(model.contains(
            "PersonCommitmentsQuery.maximumItemLimit"))
        XCTAssertTrue(model.contains("AskGraphFactSynthesisPage(page: page)"))
        XCTAssertTrue(model.contains("fact.kind == .personCommittedTo"))
        XCTAssertTrue(model.contains("subjectID == expectedPersonID"))
        XCTAssertTrue(model.contains("objectID == id"))
        XCTAssertFalse(model.contains("import StorageKit"))
        XCTAssertFalse(model.contains("import IntelligenceKit"))

        XCTAssertTrue(composition.contains(
            "memoryEntities = LoadAutomationEntities(catalog: store)"))
        XCTAssertTrue(composition.contains(
            "memoryCommitments = LoadPersonCommitments("))
        XCTAssertTrue(composition.contains(
            "PersonCommitmentsQuery("))
        XCTAssertTrue(askView.contains("ask-surface-person-commitments"))
        XCTAssertTrue(view.contains("ask-memory-person-search"))
        XCTAssertTrue(view.contains("ask-memory-load"))
        XCTAssertTrue(view.contains("ask-memory-evidence-"))
        XCTAssertTrue(view.contains("onOpenCitation(citation)"))
        XCTAssertFalse(view.contains("answerBundle("))
        XCTAssertFalse(view.contains("AskGraphFactFilterRequest"))

        XCTAssertTrue(fixture.contains("-seed-ask-memory"))
        XCTAssertTrue(fixture.contains("ProjectMeetingMemoryGraph("))
        XCTAssertTrue(uiTest.contains(
            "testAskConfirmedMemoryLoadsExactPersonCommitmentsAndEvidence"))
        XCTAssertTrue(uiTest.contains("ask-memory-load"))
        XCTAssertTrue(uiTest.contains("player-current-time"))

        XCTAssertTrue(architecture.contains(
            "explicit confirmed-memory surface"))
        XCTAssertTrue(intelligence.contains(
            "## Released exact-person commitment explorer (D361)"))
        XCTAssertTrue(quality.contains(
            "### First released exact graph query surface (D361)"))
        XCTAssertTrue(gaps.contains("D361 ships **By person**"))
        XCTAssertTrue(gaps.contains(
            "physical VoiceOver/Sequoia/Tahoe validation remain absent"))
        XCTAssertTrue(decisions.contains("## D361"))
    }

    func testReleasedAskTopicMemoryRequiresExactTopicSelection() throws {
        let model = try Self.contents(
            of: "Sources/portavoz-app/AskTopicMemoryModel.swift")
        let view = try Self.contents(
            of: "Sources/portavoz-app/AskTopicMemoryView.swift")
        let askView = try Self.contents(
            of: "Sources/portavoz-app/AskView.swift")
        let catalog = try Self.contents(
            of: "Sources/ApplicationKit/LoadConfirmedTopicCatalog.swift")
        let storage = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+ConfirmedTopicCatalog.swift")
        let composition = try Self.contents(
            of: "Sources/portavoz-app/AppServices+Ask.swift")
        let fixture = try Self.contents(
            of: "Sources/portavoz-app/AppServices+UITestFixtures.swift")
        let topicMemoryFixture = try Self.contents(
            of: "Sources/portavoz-app/AppServices+AskTopicMemoryUITestFixture.swift")
        let uiTest = try Self.contents(
            of: "Tests/PortavozUITests/LibraryUITests.swift")
        let architecture = try Self.contents(of: "docs/ARCHITECTURE.md")
        let intelligence = try Self.contents(
            of: "docs/specs/04-intelligence.md")
        let storageSpec = try Self.contents(
            of: "docs/specs/05-storage.md")
        let appSpec = try Self.contents(
            of: "docs/specs/06-app-macos.md")
        let quality = try Self.contents(of: "docs/specs/08-quality.md")
        let gaps = try Self.contents(of: "docs/GAPS.md")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertTrue(model.contains("final class AskTopicMemoryModel"))
        XCTAssertTrue(model.contains("static let visibleTopicLimit = 20"))
        XCTAssertTrue(model.contains(
            "topicRequestLimit = visibleTopicLimit + 1"))
        XCTAssertTrue(model.contains(
            "DecisionHistoryQuery.maximumItemLimit"))
        XCTAssertTrue(model.contains("AskGraphFactSynthesisPage(page: page)"))
        XCTAssertTrue(model.contains("fact.kind == .decisionAboutTopic"))
        XCTAssertTrue(model.contains("topicID == expectedTopic.id"))
        XCTAssertTrue(model.contains("fact.status == .confirmed"))
        XCTAssertFalse(model.contains("import StorageKit"))
        XCTAssertFalse(model.contains("import IntelligenceKit"))

        XCTAssertTrue(catalog.contains("maximumResultCount = 50"))
        XCTAssertTrue(catalog.contains("maximumQueryCharacterCount = 120"))
        XCTAssertTrue(catalog.contains("protocol ConfirmedTopicCatalogReading"))
        XCTAssertTrue(storage.contains("WITH RECURSIVE"))
        XCTAssertTrue(storage.contains(
            "maximumConfirmedTopicCatalogQueryCharacterCount = 120"))
        XCTAssertTrue(storage.contains("alias.normalizedAlias"))
        XCTAssertTrue(storage.contains("mergedIntoTopicID IS NULL"))
        XCTAssertTrue(storage.contains("LIMIT :limit"))
        XCTAssertTrue(composition.contains(
            "memoryTopics = LoadConfirmedTopicCatalog(catalog: store)"))
        XCTAssertTrue(composition.contains(
            "memoryDecisionHistory = LoadDecisionHistory("))
        XCTAssertTrue(composition.contains("DecisionHistoryQuery("))

        XCTAssertTrue(askView.contains("ask-surface-topic-decisions"))
        XCTAssertTrue(view.contains("ask-topic-search"))
        XCTAssertTrue(view.contains("ask-topic-load"))
        XCTAssertTrue(view.contains("ask-topic-evidence-"))
        XCTAssertTrue(view.contains("onOpenCitation(citation)"))
        XCTAssertFalse(view.contains("answerBundle("))
        XCTAssertFalse(view.contains("AskGraphFactFilterRequest"))

        XCTAssertTrue(topicMemoryFixture.contains("-seed-ask-topic-memory"))
        XCTAssertTrue(topicMemoryFixture.contains(
            "ConfirmDecisionAboutTopic(store: store)"))
        XCTAssertTrue(fixture.contains("ProjectMeetingMemoryGraph("))
        XCTAssertTrue(uiTest.contains(
            "testAskConfirmedMemoryLoadsExactTopicDecisionsAndEvidence"))
        XCTAssertTrue(uiTest.contains("ask-topic-load"))
        XCTAssertTrue(uiTest.contains("player-current-time"))

        XCTAssertTrue(architecture.contains(
            "exact confirmed-topic/current-decisions"))
        XCTAssertTrue(intelligence.contains(
            "## Released exact-topic decision explorer (D362)"))
        XCTAssertTrue(storageSpec.contains(
            "## Bounded confirmed-topic catalog (D362)"))
        XCTAssertTrue(appSpec.contains(
            "## Exact decisions by topic in Ask (D362)"))
        XCTAssertTrue(quality.contains(
            "### Second released exact graph query surface (D362)"))
        XCTAssertTrue(gaps.contains("D362 adds **By topic**"))
        XCTAssertTrue(decisions.contains("## D362"))
    }

    func testReleasedTopicFirstDiscussionRequiresOneCompleteExactFact() throws {
        let client = try Self.contents(
            of: "Sources/portavoz-app/AskMemoryModel.swift")
        let model = try Self.contents(
            of: "Sources/portavoz-app/AskTopicMemoryModel.swift")
        let view = try Self.contents(
            of: "Sources/portavoz-app/AskTopicMemoryView.swift")
        let composition = try Self.contents(
            of: "Sources/portavoz-app/AppServices+Ask.swift")
        let topicMemoryFixture = try Self.contents(
            of: "Sources/portavoz-app/AppServices+AskTopicMemoryUITestFixture.swift")
        let uiTest = try Self.contents(
            of: "Tests/PortavozUITests/LibraryUITests.swift")
        let scope = try Self.contents(of: "scripts/ui_test_scope.py")
        let architecture = try Self.contents(of: "docs/ARCHITECTURE.md")
        let intelligence = try Self.contents(
            of: "docs/specs/04-intelligence.md")
        let appSpec = try Self.contents(
            of: "docs/specs/06-app-macos.md")
        let quality = try Self.contents(of: "docs/specs/08-quality.md")
        let gaps = try Self.contents(of: "docs/GAPS.md")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertTrue(client.contains("loadAskMemoryTopicFirstDiscussion"))
        XCTAssertTrue(model.contains("case firstConfirmedDiscussion"))
        XCTAssertTrue(model.contains("loadAskMemoryTopicFirstDiscussion"))
        XCTAssertTrue(model.contains("synthesis.isComplete"))
        XCTAssertTrue(model.contains("page.facts.count == 1"))
        XCTAssertTrue(model.contains("evidence.sourceSegments.count == 1"))
        XCTAssertTrue(model.contains("fact.kind == .topicDiscussedInMeeting"))
        XCTAssertTrue(model.contains("topicID == expectedTopic.id"))
        XCTAssertTrue(model.contains("source.meetingID == meetingID"))
        XCTAssertTrue(model.contains(
            "source.meetingStartedAt.addingTimeInterval(source.startTime)"))
        XCTAssertFalse(model.contains("import StorageKit"))
        XCTAssertFalse(model.contains("import IntelligenceKit"))

        XCTAssertTrue(composition.contains(
            "memoryTopicFirstDiscussion = LoadTopicFirstDiscussion("))
        XCTAssertTrue(composition.contains("TopicFirstDiscussionQuery("))
        XCTAssertTrue(view.contains("ask-topic-job-first-discussion"))
        XCTAssertTrue(view.contains("ask-topic-first-discussion-"))
        XCTAssertTrue(view.contains("ask-topic-first-discussion-evidence-"))
        XCTAssertTrue(view.contains("onOpenCitation(discussion.citation)"))
        XCTAssertTrue(topicMemoryFixture.contains("-seed-ask-topic-memory"))
        XCTAssertTrue(uiTest.contains(
            "testAskConfirmedMemoryLoadsExactTopicFirstDiscussionAndEvidence"))
        XCTAssertTrue(scope.contains("topicfirstdiscussion"))

        XCTAssertTrue(architecture.contains(
            "exact confirmed-topic/first-discussion"))
        XCTAssertTrue(intelligence.contains(
            "## Released exact-topic first-discussion explorer (D363)"))
        XCTAssertTrue(appSpec.contains(
            "## First confirmed discussion by topic in Ask (D363)"))
        XCTAssertTrue(quality.contains(
            "### Third released exact graph query surface (D363)"))
        XCTAssertTrue(gaps.contains(
            "D363 adds **First confirmed discussion**"))
        XCTAssertTrue(decisions.contains("## D363"))
    }

    func testReleasedTopicDecisionConflictsRequireExactReplacementEvidence() throws {
        let client = try Self.contents(
            of: "Sources/portavoz-app/AskMemoryModel.swift")
        let model = try Self.contents(
            of: "Sources/portavoz-app/AskTopicMemoryModel.swift")
        let view = try Self.contents(
            of: "Sources/portavoz-app/AskTopicMemoryView.swift")
        let relationship = try Self.contents(
            of: "Sources/portavoz-app/AskTopicDecisionRelationship.swift")
        let relationshipView = try Self.contents(
            of: "Sources/portavoz-app/AskTopicDecisionChangesView.swift")
        let composition = try Self.contents(
            of: "Sources/portavoz-app/AppServices+Ask.swift")
        let fixture = try Self.contents(
            of: "Sources/portavoz-app/AppServices+AskTopicMemoryUITestFixture.swift")
        let uiTest = try Self.contents(
            of: "Tests/PortavozUITests/LibraryUITests.swift")
        let scope = try Self.contents(of: "scripts/ui_test_scope.py")
        let architecture = try Self.contents(of: "docs/ARCHITECTURE.md")
        let intelligence = try Self.contents(
            of: "docs/specs/04-intelligence.md")
        let appSpec = try Self.contents(
            of: "docs/specs/06-app-macos.md")
        let quality = try Self.contents(of: "docs/specs/08-quality.md")
        let gaps = try Self.contents(of: "docs/GAPS.md")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertTrue(client.contains("loadAskMemoryDecisionConflicts"))
        XCTAssertTrue(model.contains("case decisionConflicts"))
        XCTAssertTrue(model.contains(
            "DecisionConflictsQuery.maximumItemLimit"))
        XCTAssertTrue(model.contains("loadAskMemoryDecisionConflicts"))
        XCTAssertTrue(relationship.contains(
            "fact.kind == .decisionSupersededDecision"))
        XCTAssertTrue(relationship.contains("successorID != replacedID"))
        XCTAssertTrue(relationship.contains(
            "evidence.sourceSegments.count >= 2"))
        XCTAssertTrue(relationship.contains(
            "$0.segmentID == fact.primaryEvidenceSegmentID"))
        XCTAssertFalse(model.contains("import StorageKit"))
        XCTAssertFalse(model.contains("import IntelligenceKit"))

        XCTAssertTrue(composition.contains(
            "memoryDecisionConflicts = LoadDecisionConflicts("))
        XCTAssertTrue(composition.contains("DecisionConflictsQuery("))
        XCTAssertTrue(view.contains("ask-topic-job-decision-conflicts"))
        XCTAssertTrue(relationshipView.contains("ask-topic-conflict"))
        XCTAssertTrue(relationshipView.contains("-replaced-"))
        XCTAssertTrue(relationshipView.contains("-evidence-"))
        XCTAssertTrue(relationshipView.contains("onOpenCitation(citation)"))
        XCTAssertTrue(fixture.contains("ConfirmDecisionRelationship(store: store)"))
        XCTAssertTrue(fixture.contains("topic: .none"))
        XCTAssertTrue(fixture.contains("guard usesTemporaryMeetingStore"))
        XCTAssertTrue(uiTest.contains(
            "testAskConfirmedMemoryLoadsExactTopicDecisionConflictsAndEvidence"))
        XCTAssertTrue(uiTest.contains(
            "ask-topic-conflict-B5D40000-0000-4000-8000-000000000005"))
        XCTAssertTrue(scope.contains("decisionrelationship"))

        XCTAssertTrue(architecture.contains(
            "exact confirmed-topic/decision-conflicts"))
        XCTAssertTrue(intelligence.contains(
            "## Released exact-topic decision-conflict explorer (D364)"))
        XCTAssertTrue(appSpec.contains(
            "## Confirmed decision changes by topic in Ask (D364)"))
        XCTAssertTrue(quality.contains(
            "### Fourth released exact graph query surface (D364)"))
        XCTAssertTrue(gaps.contains(
            "D364 adds **Decision changes**"))
        XCTAssertTrue(decisions.contains("## D364"))
    }

    func testReleasedCommitmentBlockersRequireOneExactSelectedCommitment() throws {
        let model = try Self.contents(
            of: "Sources/portavoz-app/AskMemoryModel.swift")
        let parentView = try Self.contents(
            of: "Sources/portavoz-app/AskMemoryView.swift")
        let blockerView = try Self.contents(
            of: "Sources/portavoz-app/AskMemoryBlockersView.swift")
        let composition = try Self.contents(
            of: "Sources/portavoz-app/AppServices+Ask.swift")
        let fixture = try Self.contents(
            of: "Sources/portavoz-app/AppServices+AskCommitmentBlockerUITestFixture.swift")
        let uiTest = try Self.contents(
            of: "Tests/PortavozUITests/LibraryUITests.swift")
        let scope = try Self.contents(of: "scripts/ui_test_scope.py")
        let architecture = try Self.contents(of: "docs/ARCHITECTURE.md")
        let intelligence = try Self.contents(
            of: "docs/specs/04-intelligence.md")
        let appSpec = try Self.contents(
            of: "docs/specs/06-app-macos.md")
        let quality = try Self.contents(of: "docs/specs/08-quality.md")
        let gaps = try Self.contents(of: "docs/GAPS.md")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertTrue(model.contains("loadAskMemoryCommitmentBlockers"))
        XCTAssertTrue(model.contains(
            "CommitmentBlockerQuery.maximumItemLimit"))
        XCTAssertTrue(model.contains("currentCommitment(id: commitmentID)"))
        XCTAssertTrue(model.contains("fact.kind == .decisionBlocksCommitment"))
        XCTAssertTrue(model.contains("commitmentID == expectedCommitment.id"))
        XCTAssertTrue(model.contains(
            "fact.objectText == expectedCommitment.title"))
        XCTAssertTrue(model.contains(
            "$0.segmentID == fact.primaryEvidenceSegmentID"))
        XCTAssertFalse(model.contains(
            "evidence.sourceSegments.count >= 2"))
        XCTAssertFalse(model.contains("import StorageKit"))
        XCTAssertFalse(model.contains("import IntelligenceKit"))

        XCTAssertTrue(composition.contains(
            "memoryCommitmentBlockers = LoadCommitmentBlockers("))
        XCTAssertTrue(composition.contains("CommitmentBlockerQuery("))
        XCTAssertTrue(parentView.contains("ask-memory-blockers-load-"))
        XCTAssertTrue(parentView.contains("Show active blockers for %@"))
        XCTAssertTrue(blockerView.contains("ask-memory-blocker-"))
        XCTAssertTrue(blockerView.contains("ask-memory-blocker-evidence-"))
        XCTAssertTrue(blockerView.contains("onOpenCitation(citation)"))

        XCTAssertTrue(fixture.contains("guard usesTemporaryMeetingStore"))
        XCTAssertTrue(fixture.contains("ConfirmObservedDecision(store: store)"))
        XCTAssertTrue(fixture.contains(
            "ConfirmDecisionCommitmentBlocker(store: store)"))
        XCTAssertTrue(uiTest.contains(
            "testAskConfirmedMemoryLoadsExactCommitmentBlockersAndEvidence"))
        XCTAssertTrue(uiTest.contains(
            "ask-memory-blocker-B5D50000-0000-4000-8000-000000000007"))
        XCTAssertTrue(uiTest.contains(
            "loadBlockers.label.contains(\"Prepare the rollout\")"))
        XCTAssertTrue(uiTest.contains("waitForValue(\"0:04\", timeout: 10)"))
        XCTAssertTrue(scope.contains("loadcommitmentblockers"))

        XCTAssertTrue(architecture.contains(
            "exact selected-commitment/active-blockers"))
        XCTAssertTrue(intelligence.contains(
            "## Released exact commitment-blocker explorer (D365)"))
        XCTAssertTrue(appSpec.contains(
            "## Active blockers for one exact commitment in Ask (D365)"))
        XCTAssertTrue(quality.contains(
            "### Fifth released exact graph query surface (D365)"))
        XCTAssertTrue(gaps.contains(
            "D365 adds **Active blockers**"))
        XCTAssertTrue(decisions.contains("## D365"))
    }

    func testReleasedTopicChangesSinceRequiresExactMeetingAnchor() throws {
        let client = try Self.contents(
            of: "Sources/portavoz-app/AskMemoryModel.swift")
        let model = try Self.contents(
            of: "Sources/portavoz-app/AskTopicMemoryModel.swift")
        let anchorModel = try Self.contents(
            of: "Sources/portavoz-app/AskMeetingAnchorModel.swift")
        let relationship = try Self.contents(
            of: "Sources/portavoz-app/AskTopicDecisionRelationship.swift")
        let view = try Self.contents(
            of: "Sources/portavoz-app/AskTopicMemoryView.swift")
        let anchorView = try Self.contents(
            of: "Sources/portavoz-app/AskMeetingAnchorView.swift")
        let relationshipView = try Self.contents(
            of: "Sources/portavoz-app/AskTopicDecisionChangesView.swift")
        let composition = try Self.contents(
            of: "Sources/portavoz-app/AppServices+Ask.swift")
        let fixture = try Self.contents(
            of: "Sources/portavoz-app/AppServices+AskTopicMemoryUITestFixture.swift")
        let uiTest = try Self.contents(
            of: "Tests/PortavozUITests/LibraryUITests.swift")
        let scope = try Self.contents(of: "scripts/ui_test_scope.py")
        let architecture = try Self.contents(of: "docs/ARCHITECTURE.md")
        let intelligence = try Self.contents(
            of: "docs/specs/04-intelligence.md")
        let appSpec = try Self.contents(
            of: "docs/specs/06-app-macos.md")
        let quality = try Self.contents(of: "docs/specs/08-quality.md")
        let gaps = try Self.contents(of: "docs/GAPS.md")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertTrue(client.contains("searchAskMemoryMeetingAnchors"))
        XCTAssertTrue(client.contains("loadAskMemoryChangesSince"))
        XCTAssertTrue(model.contains("case changesSince"))
        XCTAssertTrue(model.contains("ChangeSinceQuery.maximumItemLimit"))
        XCTAssertTrue(model.contains("sinceMeetingID: anchor.id"))
        XCTAssertTrue(model.contains("anchorIsCurrent(anchor, for: job)"))
        XCTAssertTrue(model.contains("state.selectedTopic?.id == topic.id"))
        XCTAssertFalse(model.contains("import StorageKit"))
        XCTAssertFalse(model.contains("import IntelligenceKit"))

        XCTAssertTrue(anchorModel.contains("visibleMeetingLimit = 20"))
        XCTAssertTrue(anchorModel.contains("visibleMeetingLimit + 1"))
        XCTAssertTrue(anchorModel.contains("Task { [weak self, client]"))
        XCTAssertTrue(anchorModel.contains("ids.insert(meeting.id).inserted"))
        XCTAssertTrue(anchorModel.contains(
            "meeting.endedAt.map({ $0 >= meeting.startedAt })"))
        XCTAssertFalse(anchorModel.contains("import StorageKit"))
        XCTAssertFalse(anchorModel.contains("import IntelligenceKit"))

        XCTAssertTrue(relationship.contains(
            "AskGraphFactSynthesisPage(page: page)"))
        XCTAssertTrue(relationship.contains(
            "fact.kind == .decisionSupersededDecision"))
        XCTAssertTrue(relationship.contains(
            "evidence.sourceSegments.count >= 2"))
        XCTAssertTrue(relationship.contains(
            "$0.segmentID == fact.primaryEvidenceSegmentID"))

        XCTAssertTrue(composition.contains(
            "memoryEntities = LoadAutomationEntities(catalog: store)"))
        XCTAssertTrue(composition.contains(
            "memoryChangesSince = LoadChangeSince("))
        XCTAssertTrue(composition.contains("memoryEntities.meetings("))
        XCTAssertTrue(composition.contains("ChangeSinceQuery("))

        XCTAssertTrue(view.contains("ask-topic-job-changes-since"))
        XCTAssertTrue(view.contains(".pickerStyle(.radioGroup)"))
        XCTAssertTrue(view.contains("ask-topic-change-since-anchor"))
        XCTAssertTrue(anchorView.contains("ask-topic-anchor-search"))
        XCTAssertTrue(anchorView.contains("ask-topic-anchor-option-"))
        XCTAssertTrue(anchorView.contains("ask-topic-anchor-selected"))
        XCTAssertTrue(anchorView.contains(
            "Select meeting %lld: %@, ended %@"))
        XCTAssertTrue(relationshipView.contains("ask-topic-change-since"))
        XCTAssertTrue(relationshipView.contains("onOpenCitation(citation)"))

        XCTAssertTrue(fixture.contains("Planning baseline"))
        XCTAssertTrue(fixture.contains("guard usesTemporaryMeetingStore"))
        XCTAssertTrue(uiTest.contains(
            "testAskConfirmedMemoryLoadsExactTopicChangesSinceMeetingAndEvidence"))
        XCTAssertTrue(uiTest.contains(
            "ask-topic-anchor-option-B5D40000-0000-4000-8000-000000000003"))
        XCTAssertTrue(uiTest.contains("waitForValue(\"0:03\", timeout: 10)"))
        XCTAssertTrue(scope.contains(
            "testAskConfirmedMemoryLoadsExactTopicChangesSinceMeetingAndEvidence"))

        XCTAssertTrue(architecture.contains(
            "exact confirmed-topic/meeting-anchor change-since"))
        XCTAssertTrue(intelligence.contains(
            "## Released exact-topic change-since explorer (D366)"))
        XCTAssertTrue(appSpec.contains(
            "## Confirmed changes since one exact meeting in Ask (D366)"))
        XCTAssertTrue(quality.contains(
            "### Sixth released exact graph query surface (D366)"))
        XCTAssertTrue(gaps.contains(
            "D366 adds **Changes since**"))
        XCTAssertTrue(gaps.contains(
            "All six dedicated exact graph surfaces are released"))
        XCTAssertTrue(decisions.contains("## D366"))
    }

    func testExactGraphQueryTelemetryIsClosedContentFreeAndComposed() throws {
        let telemetry = try Self.contents(
            of: "Sources/ApplicationKit/MeetingMemoryGraphQueryTelemetry.swift")
        let blockers = try Self.contents(
            of: "Sources/ApplicationKit/LoadCommitmentBlockers.swift")
        let firstDiscussion = try Self.contents(
            of: "Sources/ApplicationKit/LoadTopicFirstDiscussion.swift")
        let commitments = try Self.contents(
            of: "Sources/ApplicationKit/LoadPersonCommitments.swift")
        let decisionsUseCases = try Self.contents(
            of: "Sources/ApplicationKit/LoadDecisionRelationships.swift")
        let graphLane = try Self.contents(
            of: "Sources/ApplicationKit/AskGraphFacts.swift")
        let adapter = try Self.contents(
            of: "Sources/portavoz-app/AppMeetingMemoryGraphQueryTelemetry.swift")
        let composition = try Self.contents(
            of: "Sources/portavoz-app/AppServices+Ask.swift")
        let tests = try Self.contents(
            of: "Tests/PortavozTests/MeetingMemoryGraphQueryTelemetryTests.swift")
        let architecture = try Self.contents(of: "docs/ARCHITECTURE.md")
        let intelligence = try Self.contents(
            of: "docs/specs/04-intelligence.md")
        let appSpec = try Self.contents(
            of: "docs/specs/06-app-macos.md")
        let quality = try Self.contents(of: "docs/specs/08-quality.md")
        let gaps = try Self.contents(of: "docs/GAPS.md")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertTrue(telemetry.contains("enum MeetingMemoryGraphQueryJob"))
        for job in [
            "case commitmentBlockers",
            "case topicFirstDiscussion",
            "case personCommitments",
            "case decisionConflicts",
            "case changeSince",
            "case decisionHistory",
        ] {
            XCTAssertTrue(telemetry.contains(job), "missing graph job \(job)")
        }
        for outcome in [
            "case facts", "case abstained", "case cancelled", "case failed",
        ] {
            XCTAssertTrue(
                telemetry.contains(outcome),
                "missing graph telemetry outcome \(outcome)")
        }
        for forbidden in [
            "MeetingID", "TopicID", "PersonID", "CommitmentID",
            "subjectText", "objectText", "localizedDescription",
        ] {
            XCTAssertFalse(
                telemetry.contains(forbidden),
                "graph telemetry admits payload field \(forbidden)")
        }

        XCTAssertTrue(blockers.contains(
            "telemetry.measure(.commitmentBlockers)"))
        XCTAssertTrue(firstDiscussion.contains(
            "telemetry.measure(.topicFirstDiscussion)"))
        XCTAssertTrue(commitments.contains(
            "telemetry.measure(.personCommitments)"))
        XCTAssertTrue(commitments.contains(
            "guard candidates.count == 1"))
        XCTAssertTrue(decisionsUseCases.contains(
            "telemetry.measure(.decisionHistory)"))
        XCTAssertTrue(decisionsUseCases.contains(
            "telemetry.measure(.decisionConflicts)"))
        XCTAssertTrue(decisionsUseCases.contains(
            "telemetry.measure(.changeSince)"))
        XCTAssertTrue(graphLane.contains(
            "telemetry: MeetingMemoryGraphQueryTelemetry = .disabled"))
        XCTAssertTrue(graphLane.contains("telemetry: telemetry"))

        XCTAssertTrue(adapter.contains("OSSignposter("))
        XCTAssertTrue(adapter.contains("category: .pointsOfInterest"))
        XCTAssertTrue(adapter.contains(
            "job=\\(trace.job.rawValue, privacy: .public)"))
        XCTAssertTrue(adapter.contains(
            "outcome=\\(outcome.rawValue, privacy: .public)"))
        XCTAssertFalse(adapter.contains("localizedDescription"))
        XCTAssertTrue(composition.contains(
            "graphTelemetry: MeetingMemoryGraphQueryTelemetry"))
        XCTAssertEqual(
            composition.components(
                separatedBy: "telemetry: graphTelemetry").count - 1,
            6)

        XCTAssertTrue(tests.contains(
            "testEveryExactUseCaseEmitsItsStableJob"))
        XCTAssertTrue(tests.contains(
            "testAliasResolutionStartsTelemetryOnlyAfterExactIdentity"))
        XCTAssertTrue(tests.contains(
            "testAppAdapterObserverHasExplicitLifetime"))
        XCTAssertTrue(architecture.contains(
            "Every released exact graph read emits one content-free"))
        XCTAssertTrue(intelligence.contains(
            "## Content-free exact graph query telemetry (D367)"))
        XCTAssertTrue(appSpec.contains(
            "## Exact graph query timing in the app (D367)"))
        XCTAssertTrue(quality.contains(
            "### Content-free exact graph query telemetry (D367)"))
        XCTAssertTrue(gaps.contains(
            "D367 adds content-free local timing spans"))
        XCTAssertFalse(gaps.contains("graph telemetry remain absent"))
        XCTAssertTrue(decisions.contains("## D367"))
    }

    func testGraphQueryProductTimingReceiptStaysIsolatedContentFreeAndReproducible() throws {
        let probe = try Self.contents(
            of: "Sources/portavoz-app/MeetingMemoryGraphQueryRunProbe.swift")
        let runner = try Self.contents(
            of: "Sources/portavoz-app/BenchMemoryGraphQueryRunner.swift")
        let launch = try Self.contents(
            of: "Sources/portavoz-app/AppLaunchModel.swift")
        let script = try Self.contents(
            of: "scripts/run-meeting-memory-graph-query-receipt.sh")
        let assembler = try Self.contents(
            of: "scripts/meeting_memory_graph_query_receipt.py")
        let architecture = try Self.contents(of: "docs/ARCHITECTURE.md")
        let intelligence = try Self.contents(
            of: "docs/specs/04-intelligence.md")
        let appSpec = try Self.contents(
            of: "docs/specs/06-app-macos.md")
        let quality = try Self.contents(of: "docs/specs/08-quality.md")
        let gaps = try Self.contents(of: "docs/GAPS.md")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertTrue(probe.contains("iterationsPerJob: Int"))
        XCTAssertTrue(probe.contains("p50Milliseconds"))
        XCTAssertTrue(probe.contains("p95Milliseconds"))
        XCTAssertTrue(probe.contains("maximumMilliseconds"))
        XCTAssertTrue(probe.contains(".posixPermissions: 0o600"))
        XCTAssertFalse(probe.contains("MeetingID"))
        XCTAssertFalse(probe.contains("TopicID"))
        XCTAssertFalse(probe.contains("PersonID"))
        XCTAssertFalse(probe.contains("CommitmentID"))

        XCTAssertTrue(runner.contains("usesTemporaryMeetingStore"))
        XCTAssertTrue(runner.contains("-seed-demo"))
        XCTAssertTrue(runner.contains("-seed-ask-memory"))
        XCTAssertTrue(runner.contains("-seed-ask-topic-memory"))
        XCTAssertTrue(runner.contains(
            "reconcileSearchAfterSeed: false"))
        XCTAssertTrue(runner.contains("telemetry: .disabled"))
        XCTAssertTrue(runner.contains(
            "AppMeetingMemoryGraphQueryTelemetry"))
        XCTAssertTrue(runner.contains(".shared.telemetry"))
        XCTAssertTrue(runner.contains("Task.sleep(for: .seconds(360))"))
        XCTAssertTrue(launch.contains(
            "runMemoryGraphQueryBenchIfRequested"))
        XCTAssertTrue(launch.contains(
            "guard !runsIsolatedBenchmark else { return }"))

        XCTAssertTrue(script.contains(
            "git status --porcelain --untracked-files=all"))
        XCTAssertTrue(script.contains(
            "app.portavoz.mac.graph-query-bench"))
        XCTAssertTrue(script.contains("scripts/make-app.sh --release"))
        XCTAssertTrue(script.contains("(( RUNS >= 3 && RUNS <= 100 ))"))
        XCTAssertTrue(assembler.contains(
            "meeting-memory-graph-query-product-timing"))
        XCTAssertTrue(assembler.contains("reject_duplicate_keys"))
        XCTAssertTrue(assembler.contains("os.link(temporary, output)"))

        XCTAssertTrue(architecture.contains(
            "Content-free graph query product timing receipts"))
        XCTAssertTrue(intelligence.contains(
            "## Product-path graph query timing receipts (D368)"))
        XCTAssertTrue(appSpec.contains(
            "## Isolated graph query timing runner (D368)"))
        XCTAssertTrue(quality.contains(
            "### Product-path graph query timing receipt (D368)"))
        XCTAssertTrue(gaps.contains(
            "D368 adds a reproducible content-free product-path collector"))
        XCTAssertTrue(decisions.contains("## D368"))
    }

    func testMeetingMemoryGraphProjectionIsDisposableDurableAndSignalDriven() throws {
        let core = try Self.contents(
            of: "Sources/PortavozCore/MeetingMemoryGraphProjection.swift")
        let schema = try Self.contents(of: "Sources/StorageKit/Schema.swift")
        let migration = try Self.contents(
            of: "Sources/StorageKit/Schema+MeetingMemoryGraph.swift")
        let questionMigration = try Self.contents(
            of: "Sources/StorageKit/Schema+MeetingQuestionContinuity.swift")
        let blockerMigration = try Self.contents(
            of: "Sources/StorageKit/Schema+BlockerGraph.swift")
        let storage = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+MeetingMemoryGraph.swift")
        let maintenance = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+DerivedMaintenance.swift")
        let projector = try Self.contents(
            of: "Sources/ApplicationKit/ProjectMeetingMemoryGraph.swift")
        let workflow = try Self.contents(
            of: "Sources/ApplicationKit/ProcessMeetingMemoryGraphMaintenance.swift")
        let supervisor = try Self.contents(
            of: "Sources/portavoz-app/SemanticCorpusIndexingSupervisor.swift")
        let services = try Self.contents(of: "Sources/portavoz-app/AppServices.swift")
        let meetingDetail = try Self.contents(
            of: "Sources/portavoz-app/AppServices+MeetingDetail.swift")

        XCTAssertFalse(core.contains("import StorageKit"))
        XCTAssertFalse(core.contains("import ApplicationKit"))
        XCTAssertTrue(core.contains("meeting-memory-graph-projection-v3"))
        XCTAssertTrue(schema.contains(
            "registerMeetingMemoryGraphMigration(in: &migrator)"))
        XCTAssertTrue(migration.contains("registerMigration(\"v27\")"))
        for table in [
            "meetingMemoryGraphInvalidation",
            "meetingMemoryGraphMeetingPerson",
            "meetingMemoryGraphMeetingTopic",
            "meetingMemoryGraphMeetingDecision",
            "meetingMemoryGraphMeetingCommitment",
            "meetingMemoryGraphCommitmentPerson",
        ] {
            XCTAssertTrue(migration.contains(table), table)
        }
        for table in [
            "meetingMemoryGraphMeetingQuestion",
            "meetingMemoryGraphTopicQuestion",
        ] {
            XCTAssertTrue(questionMigration.contains(table), table)
        }
        for table in [
            "meetingMemoryGraphMeetingBlocker",
            "meetingMemoryGraphDecisionCommitmentBlocker"
        ] {
            XCTAssertTrue(blockerMigration.contains(table), table)
        }
        XCTAssertTrue(storage.contains(
            "validateOwnedDerivedMaintenancePublication"))
        XCTAssertTrue(storage.contains(
            "meetingMemoryGraphProjectionIsReady"))
        XCTAssertTrue(storage.contains(
            "readmissionPolicy: .whenMeetingMemoryGraphProjectionRequiresTarget"))
        XCTAssertTrue(maintenance.contains(
            "job.state == .succeeded || job.state == .cancelled"))
        XCTAssertTrue(maintenance.contains("record.attempt = 0"))
        XCTAssertFalse(maintenance.contains(
            "job.state == .failed || job.state == .cancelled"))
        XCTAssertTrue(projector.contains("kind: .memoryGraph"))
        XCTAssertTrue(projector.contains("shouldProceed(at: .checkpoint)"))
        XCTAssertTrue(workflow.contains(
            "recoverExpiredMeetingMemoryGraphMaintenance"))
        XCTAssertTrue(workflow.contains(
            "suspendMeetingMemoryGraphMaintenance"))
        XCTAssertTrue(workflow.contains(
            "completeMeetingMemoryGraphMaintenance"))
        XCTAssertTrue(supervisor.contains(
            "final class MeetingMemoryGraphProjectionSupervisor"))
        XCTAssertTrue(supervisor.contains(
            "struct AppMeetingMemoryGraphBackgroundProjector"))
        XCTAssertTrue(services.contains(
            "@ObservationIgnored let memoryGraphProjectionSupervisor:"))
        XCTAssertTrue(meetingDetail.contains("requestMemoryGraphReconciliation()"))

        let architecture = try Self.contents(of: "docs/ARCHITECTURE.md")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")
        let intelligenceSpec = try Self.contents(
            of: "docs/specs/04-intelligence.md")
        let storageSpec = try Self.contents(of: "docs/specs/05-storage.md")
        let appSpec = try Self.contents(of: "docs/specs/06-app-macos.md")
        XCTAssertTrue(architecture.contains(
            "disposable typed Meeting Memory Graph projection"))
        XCTAssertTrue(decisions.contains("## D273"))
        XCTAssertTrue(decisions.contains("## D360"))
        XCTAssertTrue(intelligenceSpec.contains(
            "## Disposable Meeting Memory Graph projection (D273)"))
        XCTAssertTrue(storageSpec.contains(
            "### Durable Meeting Memory Graph projection (D273)"))
        XCTAssertTrue(appSpec.contains(
            "### Signal-driven Meeting Memory Graph projection (D273)"))
    }

    func testQuestionContinuityRequiresExplicitExactAuthority() throws {
        let core = try Self.contents(
            of: "Sources/PortavozCore/MeetingQuestionContinuity.swift")
        let application = try Self.contents(
            of: "Sources/ApplicationKit/MeetingQuestionContinuity.swift")
        let storage = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+MeetingQuestionContinuity.swift")
        let migration = try Self.contents(
            of: "Sources/StorageKit/Schema+MeetingQuestionContinuity.swift")
        let timeline = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+MeetingMemoryTimeline.swift")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertTrue(core.contains("enum MeetingQuestionStatus"))
        XCTAssertTrue(core.contains("struct MeetingQuestionEvidence"))
        XCTAssertTrue(core.contains("case resolve"))
        XCTAssertTrue(core.contains("case reopen"))
        XCTAssertTrue(core.contains("case dismiss"))
        XCTAssertTrue(application.contains("struct ConfirmMeetingQuestion"))
        XCTAssertTrue(application.contains("struct ManageMeetingQuestion"))
        XCTAssertFalse(application.contains("import IntelligenceKit"))
        XCTAssertTrue(storage.contains("validateMeetingQuestionEvidence"))
        XCTAssertTrue(storage.contains("acceptedSegmentHasNoActiveCorrectionSQL"))
        XCTAssertFalse(storage.contains("CompanionCard"))
        XCTAssertTrue(migration.contains("registerMigration(\"v29\")"))
        XCTAssertTrue(migration.contains("meetingQuestionEvent_project_ai"))
        XCTAssertTrue(timeline.contains("appendQuestionTimelineItems"))
        XCTAssertEqual(
            try Self.sourceMatches(
                under: "Sources/portavoz-app",
                pattern: #"ConfirmMeetingQuestion|ManageMeetingQuestion"#),
            [])
        XCTAssertTrue(decisions.contains("## D276"))
    }

    func testDecisionCommitmentBlockersRequireExplicitExactAuthority() throws {
        let core = try Self.contents(
            of: "Sources/PortavozCore/DecisionCommitmentBlocker.swift")
        let application = try Self.contents(
            of: "Sources/ApplicationKit/DecisionCommitmentBlocker.swift")
        let storage = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+DecisionCommitmentBlocker.swift")
        let migration = try Self.contents(
            of: "Sources/StorageKit/Schema+DecisionCommitmentBlocker.swift")
        let graphMigration = try Self.contents(
            of: "Sources/StorageKit/Schema+BlockerGraph.swift")
        let timeline = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+MeetingMemoryBlockerTimeline.swift")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertTrue(core.contains("enum DecisionCommitmentBlockerStatus"))
        XCTAssertTrue(core.contains("struct DecisionCommitmentBlockerEvidence"))
        XCTAssertTrue(core.contains("case clear"))
        XCTAssertTrue(core.contains("case reopen"))
        XCTAssertTrue(application.contains("struct ConfirmDecisionCommitmentBlocker"))
        XCTAssertTrue(application.contains("struct ManageDecisionCommitmentBlocker"))
        XCTAssertFalse(application.contains("import IntelligenceKit"))
        XCTAssertTrue(storage.contains("validateBlockerEvidence"))
        XCTAssertTrue(storage.contains("validateBlockerEndpoints"))
        XCTAssertTrue(storage.contains("acceptedSegmentHasNoActiveCorrectionSQL"))
        XCTAssertFalse(storage.contains("CompanionCard"))
        XCTAssertTrue(migration.contains("registerMigration(\"v30\")"))
        XCTAssertTrue(migration.contains("decisionCommitmentBlockerEvent_project_ai"))
        XCTAssertFalse(graphMigration.contains("AFTER UPDATE OF status"))
        XCTAssertTrue(timeline.contains(
            "appendDecisionCommitmentBlockerTimelineItems"))
        XCTAssertEqual(
            try Self.sourceMatches(
                under: "Sources/portavoz-app",
                pattern: #"ConfirmDecisionCommitmentBlocker|ManageDecisionCommitmentBlocker"#),
            ["AppServices+AskCommitmentBlockerUITestFixture.swift"])
        XCTAssertTrue(decisions.contains("## D277"))
    }

    func testDecisionContinuityPromotesOnlyExplicitCurrentEvidence() throws {
        let core = try Self.contents(
            of: "Sources/PortavozCore/DecisionContinuity.swift")
        let application = try Self.contents(
            of: "Sources/ApplicationKit/DecisionContinuity.swift")
        let observation = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+DecisionObservation.swift")
        let confirmation = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+DecisionConfirmation.swift")
        let relationship = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+DecisionRelationship.swift")
        let migration = try Self.contents(
            of: "Sources/StorageKit/Schema+DecisionContinuity.swift")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertTrue(core.contains("case observed"))
        XCTAssertTrue(core.contains("case confirmed"))
        XCTAssertTrue(core.contains("case superseded"))
        XCTAssertTrue(core.contains("case reversed"))
        XCTAssertTrue(core.contains("struct DecisionObservation:"))
        XCTAssertTrue(core.contains("struct DecisionSource:"))
        XCTAssertTrue(application.contains("struct ConfirmObservedDecision"))
        XCTAssertTrue(application.contains("struct ConfirmDecisionSource"))
        XCTAssertTrue(application.contains("struct ConfirmDecisionRelationship"))
        XCTAssertFalse(application.contains("import IntelligenceKit"))
        XCTAssertTrue(observation.contains("acceptedSegmentHasNoActiveCorrectionSQL"))
        XCTAssertTrue(confirmation.contains("decisionObservationForConfirmation"))
        XCTAssertTrue(confirmation.contains("replayDecisionConfirmation"))
        XCTAssertTrue(relationship.contains("both relationship decisions must still be confirmed"))
        XCTAssertTrue(migration.contains("registerMigration(\"v26\")"))
        XCTAssertTrue(migration.contains("decisionContinuitySource"))
        XCTAssertTrue(migration.contains("decisionContinuityEvent"))
        XCTAssertTrue(migration.contains("summaryDecisionID"))
        XCTAssertTrue(migration.contains("segmentID"))
        XCTAssertEqual(
            try Self.sourceMatches(
                under: "Sources/portavoz-app",
                pattern: #"ConfirmObservedDecision|ConfirmDecisionRelationship"#),
            [
                "AppServices+AskCommitmentBlockerUITestFixture.swift",
                "AppServices+AskTopicMemoryUITestFixture.swift",
            ],
            "only temporary-store XCUITest fixtures may confirm decisions or relationships")
        XCTAssertTrue(decisions.contains("## D272"))
    }

    func testAudioRouteChangesCannotReuseOrRaceMutableGraphs() throws {
        let microphone = try Self.contents(
            of: "Sources/AudioCaptureKit/MicrophoneSource.swift")
        let processTap = try Self.contents(
            of: "Sources/AudioCaptureKit/ProcessTapSource.swift")

        XCTAssertTrue(microphone.contains(
            "private var routeTransitions = AudioRouteTransitionGate()"))
        XCTAssertTrue(microphone.contains("self.engine = AVAudioEngine()"))
        XCTAssertTrue(microphone.contains(
            "self.routeTransitions.admits(ticket)"))
        XCTAssertTrue(processTap.contains(
            "private var routeTransitions = AudioRouteTransitionGate()"))
        XCTAssertTrue(processTap.contains(
            "private func startOnRebuildQueue() throws"))
        XCTAssertTrue(processTap.contains(
            "private func stopOnRebuildQueue()"))
        XCTAssertTrue(processTap.contains(
            "self.routeTransitions.admits(ticket)"))
    }

    func testDecisionEvidenceStaysPositionTypedRevisionFencedAndPortable() throws {
        let core = try Self.contents(of: "Sources/PortavozCore/SummaryTypes.swift")
        let outline = try Self.contents(
            of: "Sources/PortavozCore/SummaryMarkdownOutline.swift")
        let schema = try Self.contents(
            of: "Sources/StorageKit/Schema+SummaryDecisionEvidence.swift")
        let storage = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+SummaryDecisionEvidence.swift")
        let structured = try Self.contents(
            of: "Sources/IntelligenceKit/StructuredSummary.swift")
        let provider = try Self.contents(
            of: "Sources/IntelligenceKit/OpenAICompatibleSummaryProvider.swift")
        let translation = try Self.contents(
            of: "Sources/IntelligenceKit/FoundationModelSummaryProvider.swift")
        let bundle = try Self.contents(of: "Sources/IntegrationsKit/MeetingBundle.swift")
        let generatedDocument = try Self.contents(
            of: "Sources/portavoz-app/MeetingGeneratedDocumentSection.swift")
        let diagnostics = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+SupportDiagnostics.swift")

        XCTAssertTrue(core.contains("struct SummaryDecisionEvidence"))
        XCTAssertTrue(core.contains("decisionSectionIndexes"))
        XCTAssertTrue(outline.contains("bulletLines"))
        XCTAssertTrue(schema.contains("table: \"summaryDecisionEvidence\""))
        XCTAssertTrue(schema.contains("table: \"summaryDecisionEvidenceSegment\""))
        XCTAssertTrue(storage.contains("must address a rendered summary bullet"))
        XCTAssertTrue(storage.contains("validatedSummaryEvidence"))
        XCTAssertTrue(structured.contains("sections.count == request.recipe.sections.count"))
        XCTAssertTrue(structured.contains("resolveEvidenceTags"))
        XCTAssertTrue(provider.contains("bulletEvidence"))
        XCTAssertTrue(translation.contains("translatedDecisionEvidence"))
        XCTAssertTrue(translation.contains("Exactly one entry per instructed section heading"))
        XCTAssertFalse(translation.contains("Do NOT add a section for action items"))
        XCTAssertTrue(bundle.contains("decisionEvidence: summary.decisionEvidence.compactMap"))
        XCTAssertTrue(generatedDocument.contains("summary-decision-"))
        XCTAssertTrue(generatedDocument.contains("focus: actions.focusEvidence"))
        XCTAssertFalse(diagnostics.contains("SummaryDecisionEvidence"))
    }
}
