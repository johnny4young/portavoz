import ApplicationKit
import Foundation
import XCTest

extension ArchitectureDependencyTests {
    func testTranscriptCorrectionCompositionStaysPureAndPolicyExplicit() throws {
        let content = try Self.contents(
            of: "Sources/ApplicationKit/MeetingTranscriptContent.swift")
        let composer = try Self.contents(
            of: "Sources/ApplicationKit/ComposeTranscript.swift")
        let corrector = try Self.contents(
            of: "Sources/ApplicationKit/CorrectMeetingTranscript.swift")
        let core = try Self.contents(
            of: "Sources/PortavozCore/TranscriptCorrection.swift")
        let revision = try Self.contents(
            of: "Sources/PortavozCore/TranscriptCorrectionRevision.swift")
        let store = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+TranscriptCorrections.swift")
        let readingStore = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+TranscriptCorrectionReading.swift")
        let projection = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+TranscriptProjection.swift")
        let schema = try Self.contents(
            of: "Sources/StorageKit/Schema+TranscriptCorrection.swift")
        let syncAggregate = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+SyncAggregate.swift")
        let syncReplay = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+SyncReplay.swift")
        let editor = try Self.contents(
            of: "Sources/portavoz-app/TranscriptCorrectionEditor.swift")

        XCTAssertEqual(
            composer.components(separatedBy: .newlines)
                .filter { $0.hasPrefix("import ") },
            ["import Foundation", "import PortavozCore"])
        XCTAssertEqual(
            core.components(separatedBy: .newlines)
                .filter { $0.hasPrefix("import ") },
            ["import Foundation"])
        for correctionKind in [
            "case replaceText", "case changeSpeaker", "case split",
            "case merge", "case suppress", "case restore"
        ] {
            XCTAssertTrue(core.contains(correctionKind), correctionKind)
        }
        XCTAssertTrue(core.contains("struct TranscriptCorrectionEvent"))
        XCTAssertTrue(core.contains("struct TranscriptCorrectionSyncEnvelope"))
        XCTAssertTrue(core.contains("enum TranscriptCorrectionPolicy"))
        XCTAssertTrue(core.contains("validateHistory("))
        XCTAssertTrue(core.contains("let sourceDeviceID:"))
        XCTAssertTrue(core.contains("let deletedAt:"))
        XCTAssertTrue(revision.contains("struct TranscriptCorrectionRevision"))
        XCTAssertTrue(revision.contains("TranscriptCorrectionArtifactSource"))
        XCTAssertTrue(revision.contains("effectiveCorrections("))
        XCTAssertTrue(composer.contains("enum TranscriptReadingPolicy"))
        XCTAssertTrue(composer.contains("case accepted"))
        XCTAssertTrue(composer.contains("case composed"))
        XCTAssertTrue(composer.contains("baseTranscriptRevision"))
        XCTAssertTrue(composer.contains("activeCorrectionIDs"))
        XCTAssertTrue(content.contains("MeetingTranscriptBaseMaterial"))
        XCTAssertTrue(content.contains("MeetingTranscriptProjection"))
        XCTAssertTrue(content.contains("MeetingTranscriptLineage"))
        XCTAssertTrue(content.contains("sourceSegmentIDs"))
        XCTAssertTrue(store.contains("appendTranscriptCorrection("))
        XCTAssertTrue(store.contains("appendTranscriptCorrections("))
        XCTAssertTrue(store.contains("transcriptCorrectionHistory("))
        XCTAssertTrue(store.contains("tombstoneTranscriptCorrection("))
        // A batch validates every event against the same accepted transcript:
        // corrections never write `segment`, so the read is hoisted out of the
        // per-event loop and passed in. Reverting to a per-event fetch makes a
        // 20k-segment meeting reload the whole transcript once per edit.
        XCTAssertTrue(store.contains("var acceptedTranscripts: [MeetingID: [SegmentRecord]]"))
        XCTAssertTrue(store.contains("static func acceptedTranscriptRecords("))
        XCTAssertTrue(store.contains("accepted acceptedRecords: [SegmentRecord]"))
        XCTAssertTrue(
            store.contains("accepted: accepted,"),
            "the batch loop must validate against the hoisted snapshot")
        XCTAssertTrue(store.contains("transcriptCorrectionSyncEnvelope("))
        XCTAssertTrue(store.contains("invalidateAcceptedOnlyDerivedWork("))
        XCTAssertFalse(store.contains("assembleTranscriptCorrections("))
        XCTAssertTrue(readingStore.contains("fetchTranscriptCorrectionHistory("))
        XCTAssertTrue(readingStore.contains("fetchTranscriptCorrection("))
        XCTAssertTrue(readingStore.contains("assembleTranscriptCorrections("))
        XCTAssertTrue(readingStore.contains("validatePortable(event)"))
        XCTAssertTrue(readingStore.contains("requireContiguousOrdinals("))
        XCTAssertTrue(projection.contains("acceptedSegmentHasNoActiveCorrectionSQL"))
        XCTAssertTrue(projection.contains("kind IN ('summary', 'index')"))
        XCTAssertFalse(projection.contains("kind IN ('transcription', 'diarization')"))
        for table in [
            "transcriptCorrection", "transcriptCorrectionTarget",
            "transcriptCorrectionPayload", "transcriptCorrectionPart"
        ] {
            XCTAssertTrue(schema.contains("\"\(table)\""), table)
        }
        XCTAssertTrue(schema.contains("createTranscriptCorrectionSyncTriggers"))
        XCTAssertTrue(syncAggregate.contains("currentFormatVersion = 2"))
        XCTAssertTrue(syncAggregate.contains("transcriptCorrections"))
        XCTAssertTrue(syncReplay.contains("aggregate.formatVersion >= 2"))
        XCTAssertTrue(syncReplay.contains("includingTranscriptCorrections"))
        XCTAssertTrue(syncReplay.contains("validateTombstoneTransition"))
        XCTAssertTrue(corrector.contains("struct CorrectMeetingTranscript"))
        XCTAssertTrue(corrector.contains("func transcriptContent("))
        XCTAssertTrue(corrector.contains("appendTranscriptCorrections(events)"))
        XCTAssertTrue(editor.contains("Original evidence"))
        XCTAssertTrue(editor.contains("Undo correction"))
        XCTAssertFalse(editor.contains("StorageKit"))
        XCTAssertFalse(editor.contains("MeetingStore"))

        XCTAssertEqual(
            try Self.sourceMatches(
                under: "Sources",
                pattern: #"\bTranscriptReadingPolicy\b|content\s*\(\s*for:\s*\.composed\s*\)"#),
            ["ApplicationKit/ComposeTranscript.swift"])

        let decisions = try Self.contents(of: "docs/DECISIONS.md")
        let gaps = try Self.contents(of: "docs/GAPS.md")
        XCTAssertTrue(decisions.contains("D229 — Define correction composition before persistence"))
        XCTAssertTrue(decisions.contains(
            "D230 — Persist and synchronize correction history without product adoption"))
        XCTAssertTrue(decisions.contains(
            "D231 — Adopt focused text and speaker corrections in Meeting Detail"))
        XCTAssertTrue(decisions.contains(
            "D232 — Make structural transcript corrections explicit and recoverable"))
        XCTAssertTrue(decisions.contains(
            "D233 — Fence derived artifacts by effective correction lineage"))
        XCTAssertTrue(decisions.contains(
            "D234 — Export corrected readings and converge private replicas without guessing"))
        XCTAssertTrue(decisions.contains("all current product paths remain on accepted content"))
        XCTAssertTrue(gaps.contains(
            "Meeting Detail composes current-revision text, speaker, split, explicit adjacent merge"))
        XCTAssertTrue(gaps.contains(
            "every active split part its part UUID and every merge its correction UUID"))

        for forbidden in [
            "import SwiftUI", "import StorageKit", "import GRDB",
            "AppServices", "MeetingStore", "UserDefaults", "@State", "@Environment"
        ] {
            XCTAssertFalse(composer.contains(forbidden), forbidden)
            XCTAssertFalse(core.contains(forbidden), forbidden)
        }
    }

    func testCanonicalPeopleRequireConfirmationAndStayOutOfAutomaticEvidencePaths() throws {
        let core = try Self.contents(of: "Sources/PortavozCore/PersonIdentity.swift")
        let application = try Self.contents(of: "Sources/ApplicationKit/CanonicalPeople.swift")
        let storage = try Self.contents(of: "Sources/StorageKit/MeetingStore+People.swift")
        let schema = try Self.contents(of: "Sources/StorageKit/Schema.swift")
        let bundle = try Self.contents(of: "Sources/IntegrationsKit/MeetingBundle.swift")
        let calendar = try Self.contents(
            of: "Sources/IntegrationsKit/CalendarAttendeeSource.swift")
        let gallery = try Self.contents(of: "Sources/DiarizationKit/VoiceGallery.swift")

        XCTAssertTrue(core.contains("enum PersonAliasNormalizer"))
        XCTAssertTrue(core.contains("never authority to merge people"))
        XCTAssertTrue(application.contains("func people(matchingAlias"))
        XCTAssertTrue(application.contains("case createDistinct"))
        XCTAssertTrue(application.contains("case existing(PersonID)"))
        XCTAssertTrue(storage.contains("Duplicate aliases across people are deliberate"))
        XCTAssertTrue(storage.contains("guard !speaker.isMe"))
        XCTAssertTrue(schema.contains("registerMigration(\"v8\")"))
        XCTAssertTrue(schema.contains("registerMigration(\"v9\")"))
        XCTAssertTrue(schema.contains("t.add(column: \"personID\", .text)"))
        XCTAssertTrue(bundle.contains("personID: nil"))
        XCTAssertFalse(calendar.contains("linkSpeaker("))
        XCTAssertFalse(calendar.contains("createPersonAndLink("))
        XCTAssertFalse(gallery.contains("linkSpeaker("))
        XCTAssertFalse(gallery.contains("createPersonAndLink("))
    }

    func testSummaryEvidenceStaysTypedRevisionFencedAndPortable() throws {
        let core = try Self.contents(of: "Sources/PortavozCore/SummaryTypes.swift")
        let schema = try Self.contents(of: "Sources/StorageKit/Schema.swift")
            + Self.contents(of: "Sources/StorageKit/Schema+SummaryClaim.swift")
        let storage = try Self.contents(of: "Sources/StorageKit/MeetingStore+Summaries.swift")
            + Self.contents(of: "Sources/StorageKit/MeetingStore+SummaryDecisionEvidence.swift")
        let formatter = try Self.contents(of: "Sources/IntelligenceKit/TranscriptFormatter.swift")
        let provider = try Self.contents(
            of: "Sources/IntelligenceKit/OpenAICompatibleSummaryProvider.swift")
        let bundle = try Self.contents(of: "Sources/IntegrationsKit/MeetingBundle.swift")
        let generatedDocument = try Self.contents(
            of: "Sources/portavoz-app/MeetingGeneratedDocumentSection.swift")

        XCTAssertTrue(core.contains("enum SummaryClaimKind"))
        XCTAssertTrue(core.contains("currentTranscriptRevision"))
        XCTAssertTrue(core.contains("case stale"))
        XCTAssertTrue(core.contains("case unavailable"))
        XCTAssertTrue(schema.contains("registerMigration(\"v9\")"))
        XCTAssertTrue(schema.contains("table: \"summaryClaim\""))
        XCTAssertTrue(schema.contains("table: \"summaryClaimSegment\""))
        XCTAssertTrue(storage.contains("evidence must reference a live segment"))
        XCTAssertTrue(storage.contains("meeting.transcriptRevision"))
        XCTAssertTrue(formatter.contains("formatWithEvidence"))
        XCTAssertTrue(formatter.contains("resolveEvidenceTags"))
        XCTAssertTrue(provider.contains("overviewEvidence"))
        XCTAssertTrue(bundle.contains("segmentMap"))
        XCTAssertTrue(bundle.contains("sourceTranscriptRevision: nil"))
        XCTAssertTrue(generatedDocument.contains("summary-evidence-stale"))
        XCTAssertTrue(generatedDocument.contains("focus: actions.focusEvidence"))
    }

    func testClaimFeedbackStaysSeparatePrivateAndExplicitlyPortable() throws {
        let core = try Self.contents(of: "Sources/PortavozCore/SummaryTypes.swift")
        let schema = try Self.contents(
            of: "Sources/StorageKit/Schema+SummaryClaimFeedback.swift")
        let storage = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+SummaryClaimFeedback.swift")
        let summaries = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+Summaries.swift")
        let bundle = try Self.contents(of: "Sources/IntegrationsKit/MeetingBundle.swift")
        let model = try Self.meetingDetailModelContents()
        let diagnostics = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+SupportDiagnostics.swift")

        XCTAssertTrue(core.contains("enum SummaryClaimFeedbackKind"))
        XCTAssertTrue(core.contains("maximumCorrectionLength = 2_000"))
        XCTAssertTrue(schema.contains("table: \"summaryClaimFeedback\""))
        XCTAssertTrue(schema.contains("deletedAt IS NOT NULL AND correctionText IS NULL"))
        XCTAssertTrue(storage.contains("ORDER BY createdAt DESC, rowid DESC"))
        XCTAssertTrue(storage.contains("current.correctionText = nil"))
        XCTAssertTrue(summaries.contains("generated summaries cannot write user feedback"))
        XCTAssertTrue(bundle.contains("feedback: claim.feedback"))
        XCTAssertTrue(model.contains("case setSummaryClaimFeedback"))
        XCTAssertFalse(diagnostics.contains("SummaryClaimFeedback"))
        XCTAssertTrue(try Self.sourceMatches(
            under: "Sources/IntelligenceKit",
            pattern: #"SummaryClaimFeedback"#).isEmpty)
    }

    func testActionItemEvidenceStaysIdentityTypedRevisionFencedAndPortable() throws {
        let core = try Self.contents(of: "Sources/PortavozCore/SummaryTypes.swift")
        let schema = try Self.contents(
            of: "Sources/StorageKit/Schema+SummaryActionItemEvidence.swift")
        let storage = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+SummaryActionItemEvidence.swift")
        let structured = try Self.contents(
            of: "Sources/IntelligenceKit/StructuredSummary.swift")
        let provider = try Self.contents(
            of: "Sources/IntelligenceKit/OpenAICompatibleSummaryProvider.swift")
        let bundle = try Self.contents(of: "Sources/IntegrationsKit/MeetingBundle.swift")
        let generatedDocument = try Self.contents(
            of: "Sources/portavoz-app/MeetingGeneratedDocumentSection.swift")
        let actionItems = try Self.contents(
            of: "Sources/portavoz-app/MeetingActionItemsView.swift")
        let companion = try Self.contents(of: "Sources/IntelligenceKit/Companion.swift")
        let diagnostics = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+SupportDiagnostics.swift")

        XCTAssertTrue(core.contains("struct SummaryActionItemEvidence"))
        XCTAssertTrue(core.contains("actionItemID: UUID"))
        XCTAssertTrue(schema.contains("table: \"summaryActionItemEvidence\""))
        XCTAssertTrue(schema.contains("table: \"summaryActionItemEvidenceSegment\""))
        XCTAssertTrue(storage.contains("action-item evidence identities and targets"))
        XCTAssertTrue(storage.contains("validatedSummaryEvidence"))
        XCTAssertTrue(structured.contains("typedActionItemEvidence"))
        XCTAssertTrue(structured.contains("translatedActionItemEvidence"))
        XCTAssertTrue(provider.contains("\"evidence\": [\"E3\"]"))
        XCTAssertTrue(bundle.contains("actionItemMap[evidence.actionItemID]"))
        XCTAssertTrue(generatedDocument.contains("MeetingActionItemsView"))
        XCTAssertTrue(actionItems.contains("summary-action-item-"))
        XCTAssertFalse(companion.contains("SummaryActionItemEvidence"))
        XCTAssertFalse(diagnostics.contains("SummaryActionItemEvidence"))
    }

    func testShareableRecapStaysSummaryDerivedReviewedAndUnsent() throws {
        let composer = try Self.contents(of: "Sources/ApplicationKit/MeetingRecap.swift")
        let sheet = try Self.contents(of: "Sources/portavoz-app/MeetingRecapSheet.swift")
        let exporter = try Self.contents(of: "Sources/IntegrationsKit/MeetingExporter.swift")
        let detail = try Self.contents(of: "Sources/portavoz-app/MeetingDetailFlowHost.swift")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        // The transcript cannot reach a recap: the composer never receives
        // one, which is a stronger guarantee than filtering it out later.
        XCTAssertFalse(composer.contains("TranscriptSegment"))
        XCTAssertFalse(sheet.contains("TranscriptSegment"))
        XCTAssertFalse(sheet.contains("detail.segments"))
        // Nothing is sent from the review sheet: no transport, no gateway,
        // no credential. The destinations are the clipboard and the system
        // share sheet, both chosen by the user.
        for transport in ["URLSession", "DataEgress", "gateway", "secrets", "publish"] {
            XCTAssertFalse(
                sheet.contains(transport),
                "the recap sheet must not reach \(transport)")
        }
        XCTAssertTrue(sheet.contains("ShareLink("))
        // One channel renderer for every shared surface.
        XCTAssertTrue(exporter.contains("public static func render("))
        XCTAssertTrue(composer.contains("isActionItemsHeading"))
        XCTAssertTrue(detail.contains("MeetingRecapSheet("))
        XCTAssertTrue(decisions.contains("## D136"))
    }

    func testMeetingSyncJournalStaysContentFreeGenerationFencedAndAdapterFree() throws {
        let manifest = try Self.contents(of: "Package.swift")
        let schema = try Self.contents(of: "Sources/StorageKit/Schema.swift")
        let journal = try Self.contents(of: "Sources/StorageKit/Schema+MeetingSync.swift")
        let storage = try Self.contents(of: "Sources/StorageKit/MeetingStore+Sync.swift")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertTrue(schema.contains("registerMigration(\"v14\")"))
        XCTAssertTrue(schema.contains("createMeetingSyncState(in: db)"))
        XCTAssertTrue(journal.contains("createEvidenceTriggers(in: db)"))
        XCTAssertTrue(journal.contains("localGeneration"))
        XCTAssertTrue(journal.contains("acknowledgedGeneration"))
        XCTAssertTrue(journal.contains("meetingSyncState.localGeneration + 1"))
        XCTAssertTrue(journal.contains(#"OLD.\($0) IS NOT NEW.\($0)"#))
        XCTAssertFalse(journal.contains(".references(\"meeting\""))
        for deviceLocalField in [
            "audioDirectory", "embedding", "generationRunID", "personID",
        ] {
            XCTAssertFalse(
                journal.contains(deviceLocalField),
                "sync triggers must not react to \(deviceLocalField)")
        }
        let tableStart = try XCTUnwrap(journal.range(
            of: "db.create(table: \"meetingSyncState\")"))
        let indexStart = try XCTUnwrap(journal.range(
            of: "try db.create(\n            index: \"meetingSyncState_on_pending\"",
            range: tableStart.upperBound..<journal.endIndex))
        let tableDefinition = journal[tableStart.lowerBound..<indexStart.lowerBound]
        for contentField in [
            "payload", "transcript", "markdown", "question", "answer", "voiceprint",
        ] {
            XCTAssertFalse(
                tableDefinition.contains(contentField),
                "sync journal must not persist \(contentField)")
        }
        XCTAssertTrue(storage.contains("markMeetingsForInitialSync"))
        XCTAssertTrue(storage.contains("initial seed limit must be positive"))
        XCTAssertTrue(storage.contains("change.generation <= record.localGeneration"))
        XCTAssertTrue(storage.contains("max("))
        XCTAssertFalse(manifest.contains("CloudKit"))
        let cloudKitImports = try Self.imports(under: "Sources")
            .filter { $0.module == "CloudKit" }
        XCTAssertEqual(
            cloudKitImports.map(\.file),
            [
                "IntegrationsKit/CloudKitMeetingSyncPlatform.swift",
                "IntegrationsKit/CloudMeetingRecordCodec.swift",
                "IntegrationsKit/CloudMeetingSyncCoordinator.swift",
                "IntegrationsKit/CloudMeetingSyncEngineDelegate.swift",
                "IntegrationsKit/CloudMeetingSyncRuntime.swift",
                "IntegrationsKit/CloudMeetingSyncStateStore+CorrectionReplay.swift",
                "IntegrationsKit/CloudMeetingSyncStateStore+Persistence.swift",
                "IntegrationsKit/CloudMeetingSyncStateStore.swift",
                "IntegrationsKit/CloudRecordSystemFieldsCodec.swift",
                "IntegrationsKit/CloudSyncFailureClassifier.swift",
                "portavoz-app/MeetingSyncModel.swift",
            ])
        XCTAssertTrue(decisions.contains("## D92"))
    }

    func testEnhancedNotesStayAtomicPortableAndProvenanceFenced() throws {
        let schema = try Self.contents(of: "Sources/StorageKit/Schema.swift")
        let notesSchema = try Self.contents(of: "Sources/StorageKit/Schema+EnhancedNotes.swift")
        let storage = try Self.contents(of: "Sources/StorageKit/MeetingStore+EnhancedNotes.swift")
        let useCase = try Self.contents(of: "Sources/ApplicationKit/EnhanceMeetingNotes.swift")
        let observation = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+MeetingDetailObservation.swift")
        let detail = try Self.contents(of: "Sources/portavoz-app/MeetingDetailView.swift")
        let coordinator = try Self.contents(
            of: "Sources/portavoz-app/MeetingDetailCoordinator+Documents.swift")
        let scene = try Self.contents(of: "Sources/portavoz-app/MeetingDetailScene.swift")

        // v15 owns its own triggers — the registered v14 list is never edited.
        XCTAssertTrue(schema.contains("registerMigration(\"v15\")"))
        XCTAssertTrue(schema.contains("createEnhancedNotes(in: db)"))
        XCTAssertTrue(schema.contains("createEnhancedNoteSyncTriggers(in: db)"))
        // One regenerable document per meeting, replaced in place.
        XCTAssertTrue(notesSchema.contains(
            "t.column(\"meetingID\", .text).notNull().unique().indexed()"))
        // Provenance stays device-local: severed on run pruning, never synced.
        XCTAssertTrue(notesSchema.contains(
            ".references(\"generationRun\", onDelete: .setNull)"))
        XCTAssertTrue(notesSchema.contains(
            "let portableColumns = [\"markdown\", \"language\", \"inputFingerprint\", \"deletedAt\"]"))
        // The succeeded run commits atomically WITH its artifact (D62-D78),
        // and replacement is an explicit update — never ON CONFLICT REPLACE.
        XCTAssertTrue(storage.contains("requires a succeeded run"))
        XCTAssertFalse(storage.contains("onConflict: .replace"))
        // Exact fingerprint + language reuse performs no model operation, so
        // it creates no GenerationRun (D62).
        XCTAssertTrue(useCase.contains("existing.inputFingerprint == fingerprint"))
        // Notes refresh independently: a notes failure degrades only its own
        // section, never the transcript root.
        XCTAssertTrue(observation.contains("func observeMeetingReviewNotes("))
        XCTAssertTrue(observation.contains(
            "regions: [\n                Table(\"meeting\"), Table(\"contextItem\"), Table(\"enhancedNote\")\n            ]"))
        // The view reaches enhancement through the use case, never the store.
        XCTAssertTrue(coordinator.contains("sceneActions.enhanceNotes"))
        XCTAssertFalse(detail.contains("services.enhanceMeetingNotes.execute"))
        XCTAssertTrue(scene.contains("services.enhanceMeetingNotes.execute"))
        XCTAssertFalse(detail.contains("saveEnhancedNote"))
    }

    func testMeetingSyncEnvelopeKeepsPortableReplayOutsideCloudKitCallbacks() throws {
        let manifest = try Self.contents(of: "Package.swift")
        let aggregate = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+SyncAggregate.swift")
        let replay = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+SyncReplay.swift")
        let codec = try Self.contents(
            of: "Sources/IntegrationsKit/MeetingSyncEnvelopeCodec.swift")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")
        let storageBoundary = aggregate + replay

        XCTAssertTrue(storageBoundary.contains("state.localGeneration == change.generation"))
        XCTAssertTrue(storageBoundary.contains("meeting.audioDirectory = nil"))
        XCTAssertTrue(storageBoundary.contains("speaker.personID = nil"))
        XCTAssertTrue(storageBoundary.contains("localChangePending"))
        XCTAssertTrue(storageBoundary.contains("deletionWon"))
        XCTAssertTrue(storageBoundary.contains("validateImmutableRemoteSummaries"))
        XCTAssertTrue(storageBoundary.contains(
            "state.acknowledgedGeneration = state.localGeneration"))
        for forbiddenType in [
            "AudioAsset", "GenerationRun", "DataEgressEvent", "ProcessingJob", "Voiceprint",
        ] {
            XCTAssertFalse(
                aggregate.contains("[MeetingSyncTimed<\(forbiddenType)"),
                "portable aggregate must not carry \(forbiddenType)")
        }
        XCTAssertTrue(codec.contains(".millisecondsSince1970"))
        XCTAssertTrue(codec.contains(".sortedKeys"))
        XCTAssertFalse(codec.contains("import CloudKit"))
        XCTAssertFalse(manifest.contains("SyncKit"))
        XCTAssertTrue(decisions.contains("## D93"))
    }

    func testCloudMeetingRecordCodecEncryptsContentWithoutOwningRuntime() throws {
        let codec = try Self.contents(
            of: "Sources/IntegrationsKit/CloudMeetingRecordCodec.swift")
        let protectedFile = try Self.contents(
            of: "Sources/IntegrationsKit/CloudSyncProtectedFile.swift")
        let storage = try Self.imports(under: "Sources/StorageKit")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertTrue(codec.contains("record.encryptedValues[Field.inlinePayload]"))
        XCTAssertTrue(codec.contains("CKAsset(fileURL: assetURL)"))
        XCTAssertTrue(codec.contains("CloudSyncProtectedFile.write"))
        XCTAssertTrue(protectedFile.contains("struct PublicationCapabilities"))
        XCTAssertTrue(protectedFile.contains("publicationCapabilities(in: directory)"))
        XCTAssertTrue(protectedFile.contains("FileProtectionType.complete"))
        XCTAssertTrue(protectedFile.contains(".posixPermissions: 0o600"))
        XCTAssertTrue(protectedFile.contains("Darwin.write"))
        XCTAssertTrue(protectedFile.contains("Darwin.fsync"))
        XCTAssertFalse(protectedFile.contains("FileHandle"))
        XCTAssertTrue(protectedFile.contains("Darwin.rename"))
        XCTAssertTrue(protectedFile.contains("catch where isUnsupportedMetadataError(error)"))
        XCTAssertTrue(protectedFile.contains("NSUnderlyingErrorKey"))
        XCTAssertTrue(protectedFile.contains("Int(EINVAL)"))
        XCTAssertTrue(protectedFile.contains("Int(ENOTSUP)"))
        XCTAssertTrue(protectedFile.contains("!capabilities.completeProtection"))
        XCTAssertTrue(protectedFile.contains("!capabilities.backupExclusion"))
        let protection = try XCTUnwrap(protectedFile.range(of: ".protectionKey"))
        let contentWrite = try XCTUnwrap(protectedFile.range(of: "try write(data"))
        XCTAssertLessThan(protection.lowerBound, contentWrite.lowerBound)
        XCTAssertTrue(codec.contains("payloadSHA256"))
        XCTAssertTrue(codec.contains("existingRecord.recordID == recordID"))
        XCTAssertFalse(codec.contains("recordIDsToDelete"))
        XCTAssertFalse(storage.contains(where: { $0.module == "CloudKit" }))
        XCTAssertTrue(decisions.contains("## D94"))
        XCTAssertTrue(decisions.contains("## D116"))
    }

    func testCloudMeetingTransportStateStaysDurableAccountScopedAndDomainFree() throws {
        let state = try Self.contents(
            of: "Sources/IntegrationsKit/CloudMeetingSyncState.swift")
        let store = try Self.contents(
            of: "Sources/IntegrationsKit/CloudMeetingSyncStateStore.swift")
        let persistence = try Self.contents(
            of: "Sources/IntegrationsKit/CloudMeetingSyncStateStore+Persistence.swift")
        let protectedFile = try Self.contents(
            of: "Sources/IntegrationsKit/CloudSyncProtectedFile.swift")
        let coordinator = try Self.contents(
            of: "Sources/IntegrationsKit/CloudMeetingSyncCoordinator.swift")
        let delegate = try Self.contents(
            of: "Sources/IntegrationsKit/CloudMeetingSyncEngineDelegate.swift")
        let runtime = try Self.contents(
            of: "Sources/IntegrationsKit/CloudMeetingSyncRuntime.swift")
        let cloudTransport = state + store + persistence + protectedFile
            + coordinator + delegate + runtime
        let storageImports = try Self.imports(under: "Sources/StorageKit")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertTrue(state.contains("accountScopeFingerprint"))
        XCTAssertTrue(state.contains("initialSeedCursorMeetingID"))
        XCTAssertTrue(state.contains("initialSeedPreparedAt"))
        XCTAssertTrue(state.contains("deferredReplays"))
        XCTAssertTrue(store.contains("persistEngineState"))
        XCTAssertTrue(store.contains("stageDeferredReplay"))
        XCTAssertTrue(store.contains("CloudSyncProtectedFile.write"))
        XCTAssertTrue(protectedFile.contains("FileProtectionType.complete"))
        XCTAssertTrue(protectedFile.contains(".posixPermissions: 0o600"))
        XCTAssertTrue(protectedFile.contains("Darwin.write"))
        XCTAssertTrue(protectedFile.contains("Darwin.fsync"))
        XCTAssertFalse(protectedFile.contains("FileHandle"))
        XCTAssertTrue(protectedFile.contains("Darwin.rename"))
        XCTAssertTrue(coordinator.contains("applyRemoteMeetingSyncEnvelope"))
        XCTAssertTrue(coordinator.contains("markMeetingsForInitialSync"))
        XCTAssertTrue(coordinator.contains("maintenanceGate.disposition("))
        XCTAssertTrue(coordinator.contains("shouldProceed(at: .checkpoint)"))
        XCTAssertTrue(coordinator.contains("recordInitialSeedProgress"))
        XCTAssertTrue(coordinator.contains("stageDeferredReplay"))
        XCTAssertTrue(coordinator.contains("shouldRetry: false"))
        XCTAssertTrue(delegate.contains("CKSyncEngineDelegate"))
        XCTAssertTrue(delegate.contains("preparePendingChanges"))
        XCTAssertFalse(delegate.contains("applyRemoteMeetingSyncEnvelope"))
        XCTAssertTrue(runtime.contains("configuration.automaticallySync = false"))
        XCTAssertTrue(runtime.contains("stateSerialization: try await"))
        XCTAssertFalse(cloudTransport.contains("CKContainer("))
        XCTAssertFalse(storageImports.contains(where: { $0.module == "CloudKit" }))
        XCTAssertTrue(decisions.contains("## D95"))
        XCTAssertTrue(decisions.contains("## D116"))
    }

    func testCloudSyncLifecycleKeepsConsentStatusAndUserActionsOutsideViews() throws {
        let lifecycle = try Self.contents(
            of: "Sources/IntegrationsKit/CloudMeetingSyncLifecycle.swift")
        let observation = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+SyncObservation.swift")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertTrue(lifecycle.contains("resumeIfConsented"))
        XCTAssertTrue(lifecycle.contains("guard snapshot.consentedAccountFingerprint != nil"))
        XCTAssertTrue(lifecycle.contains("protocol CloudMeetingSyncPlatform"))
        XCTAssertTrue(lifecycle.contains("includeExistingLibrary"))
        XCTAssertTrue(lifecycle.contains("coordinator.prepareInitialSeed()"))
        XCTAssertTrue(lifecycle.contains("retryPendingAttempts"))
        XCTAssertTrue(lifecycle.contains("removeThisDeviceState"))
        XCTAssertTrue(observation.contains("observeMeetingSyncJournalStatus"))
        XCTAssertFalse(lifecycle.contains("import CloudKit"))
        XCTAssertTrue(decisions.contains("## D96"))
    }

    func testCloudKitCompositionIsProvisionedLazyAndExplicitlyControlled() throws {
        let platform = try Self.contents(
            of: "Sources/IntegrationsKit/CloudKitMeetingSyncPlatform.swift")
        let model = try Self.contents(of: "Sources/portavoz-app/MeetingSyncModel.swift")
        let composition = try Self.contents(
            of: "Sources/portavoz-app/AppServices+MeetingSync.swift")
        let resourceAdapter = try Self.contents(
            of: "Sources/portavoz-app/AppServices+ResourceGovernor.swift")
        let settings = try Self.contents(
            of: "Sources/portavoz-app/MeetingSyncSettingsSection.swift")
        let entitlements = try Self.contents(of: "packaging/portavoz.entitlements")
        let localEntitlements = try Self.contents(
            of: "packaging/portavoz-local.entitlements")
        let builder = try Self.contents(of: "scripts/make-app.sh")
        let verifier = try Self.contents(
            of: "scripts/verify-cloudkit-capabilities.sh")
        let release = try Self.contents(of: "scripts/make-release.sh")
        let diskImage = try Self.contents(of: "scripts/make-dmg.sh")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        let capabilityCheck = try XCTUnwrap(platform.range(
            of: "CloudKitMeetingSyncCapabilityProbe.current()"))
        XCTAssertNotNil(platform.range(
            of: "CKContainer(\n            identifier:",
            range: capabilityCheck.upperBound..<platform.endIndex))
        let accountStatus = try XCTUnwrap(platform.range(of: "container.accountStatus()"))
        XCTAssertNotNil(platform.range(
            of: "container.userRecordID()",
            range: accountStatus.upperBound..<platform.endIndex))
        XCTAssertFalse(platform.contains("automaticallySync = true"))
        XCTAssertTrue(platform.contains("engine.sendChanges()"))
        XCTAssertTrue(platform.contains("engine.fetchChanges()"))

        XCTAssertTrue(model.contains("guard !didStart"))
        XCTAssertTrue(model.contains("guard status.isEnabled"))
        XCTAssertTrue(model.contains("func maintenanceMayResume()"))
        XCTAssertTrue(model.contains("status.initialSeedState == .requested"))
        XCTAssertTrue(model.contains("UITestMeetingSyncClient"))
        XCTAssertTrue(composition.contains("usesTemporaryStore"))
        XCTAssertTrue(composition.contains("CloudKitMeetingSyncPlatform()"))
        XCTAssertTrue(composition.contains(
            "AppResourceGovernorMaintenanceGate.make("))
        XCTAssertTrue(composition.contains("maintenanceGate: maintenanceGate"))
        XCTAssertFalse(composition.contains("CKContainer("))
        XCTAssertTrue(resourceAdapter.contains(
            "meetingSync.maintenanceMayResume()"))

        for identifier in [
            "settings-sync-status", "settings-sync-enable", "settings-sync-now",
            "settings-sync-seed", "settings-sync-retry", "settings-sync-pause",
            "settings-sync-remove",
        ] {
            XCTAssertTrue(settings.contains(identifier))
        }
        XCTAssertTrue(settings.contains("Audio, local file paths, voiceprints"))

        for capability in [
            "com.apple.developer.icloud-container-identifiers",
            "iCloud.app.portavoz.mac",
            "com.apple.developer.icloud-services",
            "CloudKit",
            "com.apple.developer.icloud-container-environment",
            "com.apple.developer.aps-environment",
        ] {
            XCTAssertTrue(entitlements.contains(capability))
            if capability.hasPrefix("com.apple.developer") {
                XCTAssertFalse(localEntitlements.contains(capability))
            }
        }
        XCTAssertTrue(builder.contains("PORTAVOZ_PROVISIONING_PROFILE"))
        XCTAssertTrue(builder.contains("packaging/portavoz-local.entitlements"))
        XCTAssertTrue(verifier.contains("embedded.provisionprofile"))
        XCTAssertTrue(verifier.contains("security cms -D"))
        XCTAssertTrue(verifier.contains("profile.get(\"ExpirationDate\")"))
        XCTAssertTrue(verifier.contains("allow_icloud_services_wildcard=True"))
        XCTAssertTrue(verifier.contains("actual.get(key) in (\"*\", [\"*\"])"))
        XCTAssertTrue(release.contains("PORTAVOZ_SIGN_IDENTITY:?"))
        XCTAssertTrue(release.contains("PORTAVOZ_NOTARY_PROFILE:?"))
        let preflight = try XCTUnwrap(diskImage.range(
            of: "scripts/verify-cloudkit-capabilities.sh dist/Portavoz.app"))
        XCTAssertNotNil(diskImage.range(
            of: "notarytool submit \"$APP_ARCHIVE\"",
            range: preflight.upperBound..<diskImage.endIndex))
        XCTAssertTrue(decisions.contains("## D97"))
        XCTAssertTrue(decisions.contains(
            "## D179 — Checkpoint existing-library sync"))
    }

    func testHostedQualificationToolingStaysPortableAndBounded() throws {
        let scope = try Self.contents(of: "scripts/ui_test_scope.py")
        let scopeTests = try Self.contents(
            of: "Tests/Tooling/test_ui_test_scope.py")
        let collector = try Self.contents(
            of: "scripts/collect-field-evidence.py")
        let collectorTests = try Self.contents(
            of: "Tests/Tooling/test_collect_field_evidence.py")
        let architecture = try Self.contents(of: "docs/ARCHITECTURE.md")
        let quality = try Self.contents(of: "docs/specs/08-quality.md")

        XCTAssertTrue(scope.contains("MAX_SUMMARY_BYTES = 16 * 1024"))
        XCTAssertTrue(scope.contains(#"tests = " ".join(selection.tests)"#))
        XCTAssertTrue(scope.contains(#"locales = " ".join(selection.locales)"#))
        XCTAssertTrue(scope.contains("full-summary-sha256="))
        XCTAssertTrue(scope.contains("summary = bounded_summary(selection.reasons)"))
        XCTAssertTrue(scopeTests.contains(
            "test_github_summary_is_bounded_without_weakening_selected_evidence"))

        XCTAssertTrue(collector.contains(#"["/usr/bin/sw_vers", flag]"#))
        XCTAssertTrue(collector.contains(
            "def main(argv=None, system_observer=current_macos):"))
        XCTAssertTrue(collector.contains(
            #""macOS": validate_macos_observation(system_observer())"#))
        XCTAssertFalse(collector.contains(#""--macos""#))
        XCTAssertTrue(collectorTests.contains(
            "test_current_macos_uses_only_the_exact_system_binary"))

        XCTAssertTrue(architecture.contains(
            "GitHub summary is capped at 16 KiB on whole-reason boundaries"))
        XCTAssertTrue(architecture.contains(
            "exact `/usr/bin/sw_vers` binary"))
        XCTAssertTrue(quality.contains(
            "selector never truncates tests or locales"))
        XCTAssertTrue(quality.contains(
            "accepts no version"))
        XCTAssertTrue(quality.contains(
            "override. Its in-process Python composition boundary"))
    }

    func testSupportDiagnosticsRemainRedactedLocalEvidence() throws {
        let exporter = try Self.contents(
            of: "Sources/ApplicationKit/ExportSupportDiagnostics.swift")
        for forbidden in [
            "title:", "segments:", "transcriptText", "summaryMarkdown", "actionItem",
            "companionCard", "configJSON", "metricsJSON", "errorMessage",
            "audioDirectory", "relativePath", "sha256", "sourceAssetID",
            "destinationURL", "apiKey"
        ] {
            XCTAssertFalse(exporter.contains(forbidden), "Exporter contains \(forbidden)")
        }
        XCTAssertTrue(exporter.contains("meeting.referenceDigest.prefix(12)"))
        XCTAssertTrue(exporter.contains("job.inputFingerprintDigest"))
        XCTAssertTrue(exporter.contains("run.inputFingerprintDigest"))
        XCTAssertTrue(exporter.contains("durationSeconds"))
        XCTAssertTrue(exporter.contains("systemSegmentCount"))

        let storage = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+SupportDiagnostics.swift")
        XCTAssertTrue(storage.contains("supportDigest(meetingID.rawValue.uuidString)"))
        XCTAssertTrue(storage.contains("supportDigest(job.inputFingerprint)"))
        XCTAssertTrue(storage.contains("supportDigest(run.inputFingerprint)"))
        XCTAssertFalse(storage.contains("errorMessage:"))
        XCTAssertFalse(storage.contains("configJSON:"))
        XCTAssertFalse(storage.contains("metricsJSON:"))
        XCTAssertTrue(storage.contains("FROM audioAsset"))
        XCTAssertTrue(storage.contains("FROM segment"))
        XCTAssertFalse(storage.contains("SELECT *"))

        let settings = try Self.contents(
            of: "Sources/portavoz-app/SupportDiagnosticsSection.swift")
        XCTAssertTrue(settings.contains("NSSavePanel"))
        XCTAssertFalse(settings.contains("URLSession"))
        XCTAssertFalse(settings.contains("DataEgressGateway"))

        let worker = try Self.contents(
            of: "Sources/portavoz-app/PostCaptureProcessingCoordinator.swift")
        guard let telemetryStart = worker.range(
            of: "private final class PostCaptureProcessingTelemetry"),
            let compositionStart = worker.range(
                of: "extension AppServices",
                range: telemetryStart.upperBound..<worker.endIndex)
        else {
            return XCTFail("Durable-processing signpost boundary is missing")
        }
        let signpostedExecution = worker[
            telemetryStart.lowerBound..<compositionStart.lowerBound]
        XCTAssertTrue(signpostedExecution.contains("kind.rawValue"))
        XCTAssertTrue(signpostedExecution.contains("attempt"))
        XCTAssertTrue(signpostedExecution.contains("outcome.rawValue"))
        XCTAssertFalse(signpostedExecution.contains("job.id"))
        XCTAssertFalse(signpostedExecution.contains("job.meetingID"))
        XCTAssertFalse(signpostedExecution.contains("localizedDescription"))
    }

    func testD329CorrectionFencedSpotlightStaysBoundedAndStorageOwned() throws {
        let schema = try Self.contents(of: "Sources/StorageKit/Schema.swift")
        let correctionSchema = try Self.contents(
            of: "Sources/StorageKit/Schema+TranscriptCorrectionSearch.swift")
        let correctionProjection = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+SegmentCorrectedText.swift")
        let spotlight = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+Spotlight.swift")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertTrue(schema.contains("registerTranscriptCorrectionSearchMigration"))
        XCTAssertTrue(correctionSchema.contains("transcriptCorrectionSearchState"))
        XCTAssertTrue(correctionSchema.contains("SELECT DISTINCT meetingID"))
        XCTAssertTrue(correctionProjection.contains(
            "refreshTranscriptCorrectionSearchProjection"))
        XCTAssertTrue(correctionProjection.contains("TranscriptCorrectionRevision.current"))
        XCTAssertTrue(correctionProjection.contains(
            "guard hasCorrectionState else { return }"))
        XCTAssertTrue(correctionProjection.contains(
            "guard !correctionRevision.isAccepted else { return }"))
        XCTAssertTrue(spotlight.contains("activeCorrectionMeeting"))
        XCTAssertTrue(spotlight.contains("spotlightRequiresCorrectionProjectionSQL"))
        XCTAssertTrue(spotlight.contains("spotlightAcceptedDocumentsSQL"))
        XCTAssertTrue(spotlight.contains("correctionAwareSegment"))
        XCTAssertTrue(spotlight.contains("segmentCorrectedText AS corrected"))
        XCTAssertTrue(spotlight.contains("acceptedSegmentHasNoActiveTextCorrectionSQL"))
        XCTAssertTrue(spotlight.contains("json_valid(generationRun.configJSON)"))
        XCTAssertTrue(spotlight.contains("segmentRank <= 40"))
        XCTAssertTrue(spotlight.contains("prefix(4_000)"))
        XCTAssertFalse(spotlight.contains("import ApplicationKit"))
        XCTAssertFalse(spotlight.contains("ComposeTranscript"))
        XCTAssertFalse(spotlight.contains("meetingLibraryDetail"))
        XCTAssertTrue(decisions.contains(
            "## D329 — Spotlight adopts correction-fenced text without expanding identity"))
    }

    func testD330CorrectedSemanticLaneIsFencedBoundedAndStorageOwned() throws {
        let schema = try Self.contents(of: "Sources/StorageKit/Schema.swift")
        let correctedSchema = try Self.contents(
            of: "Sources/StorageKit/Schema+SegmentCorrectedText.swift")
        let correctionProjection = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+SegmentCorrectedText.swift")
        let embedding = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+SemanticEmbedding.swift")
        let search = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+SemanticSearch.swift")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")
        let architecture = try Self.contents(of: "docs/ARCHITECTURE.md")
        let storageSpec = try Self.contents(of: "docs/specs/05-storage.md")
        let intelligenceSpec = try Self.contents(
            of: "docs/specs/04-intelligence.md")

        XCTAssertTrue(schema.contains("registerSegmentCorrectedEmbeddingMigration"))
        XCTAssertTrue(correctedSchema.contains("registerMigration(\"v37\")"))
        XCTAssertTrue(correctedSchema.contains("table.add(column: \"embedding\", .blob)"))
        XCTAssertTrue(correctedSchema.contains(
            "table.add(column: \"embeddingFingerprint\", .text)"))
        XCTAssertTrue(correctionProjection.contains("preservedCorrectedEmbeddings"))
        XCTAssertTrue(correctionProjection.contains("existing.matches("))
        XCTAssertTrue(embedding.contains("case corrected(correctionID: UUID)"))
        XCTAssertTrue(embedding.contains("guard limit > 0 else { return [] }"))
        XCTAssertTrue(embedding.contains("currentCorrectedTextSourceSQL"))
        XCTAssertTrue(embedding.contains("corrected.correctionID = ?"))
        XCTAssertTrue(embedding.contains("corrected.text = ?"))
        XCTAssertTrue(embedding.contains("UPDATE segmentCorrectedText"))
        XCTAssertTrue(search.contains("acceptedSemanticScanSQL"))
        XCTAssertTrue(search.contains("correctedSemanticScanSQL"))
        XCTAssertTrue(search.contains("let hasCorrectionVectors"))
        XCTAssertTrue(search.contains("UNION ALL"))
        XCTAssertTrue(search.contains("currentCorrectedTextSourceSQL"))
        XCTAssertTrue(search.contains(
            "research identity carries no correction UUID/revision"))
        XCTAssertFalse(embedding.contains("import ApplicationKit"))
        XCTAssertFalse(search.contains("import ApplicationKit"))
        XCTAssertTrue(decisions.contains(
            "## D330 — Corrected transcript text owns a fenced semantic lane"))
        XCTAssertTrue(architecture.contains("Replacement and structural projections"))
        XCTAssertTrue(storageSpec.contains(
            "Correction-aware semantic lanes (D330/D334)"))
        XCTAssertTrue(intelligenceSpec.contains(
            "Correction-aware semantic maintenance (D330/D334)"))
    }

    func testStructuralSearchIdentityStaysDerivedFencedAndStorageOwned() throws {
        let schema = try Self.contents(of: "Sources/StorageKit/Schema.swift")
        let structuralSchema = try Self.contents(
            of: "Sources/StorageKit/Schema+SegmentCorrectedText.swift")
        let projection = try Self.contents(
            of: "Sources/PortavozCore/TranscriptStructuralSearchProjection.swift")
        let refresh = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+SegmentCorrectedText.swift")
        let lexical = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+Search.swift")
        let embedding = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+SemanticEmbedding.swift")
        let semantic = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+SemanticSearch.swift")
        let spotlight = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+Spotlight.swift")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertTrue(schema.contains("registerTranscriptStructuralSearchMigration"))
        XCTAssertTrue(structuralSchema.contains("registerMigration(\"v38\")"))
        XCTAssertTrue(structuralSchema.contains("transcriptStructuralSearchRow"))
        XCTAssertTrue(structuralSchema.contains("transcriptStructuralSearchSource"))
        XCTAssertTrue(structuralSchema.contains("transcriptStructuralSearch"))
        XCTAssertTrue(projection.contains("resultID: part.id"))
        XCTAssertTrue(projection.contains("resultID: correction.id"))
        XCTAssertTrue(projection.contains("case .replaceText, .changeSpeaker, .suppress"))
        XCTAssertTrue(refresh.contains("preservedStructuralEmbeddings"))
        XCTAssertTrue(refresh.contains("insertStructuralSearchRow"))
        XCTAssertTrue(lexical.contains("transcriptStructuralSearch MATCH ?"))
        XCTAssertTrue(lexical.contains("sourceSegmentIDs"))
        XCTAssertTrue(embedding.contains("case structural(correctionID: UUID)"))
        XCTAssertTrue(embedding.contains("currentStructuralTextSourceSQL"))
        XCTAssertTrue(semantic.contains("semanticStructuralHits"))
        XCTAssertTrue(spotlight.contains("transcriptStructuralSearchRow AS structural"))
        for source in [structuralSchema, refresh, lexical, embedding, semantic, spotlight] {
            XCTAssertFalse(source.contains("import ApplicationKit"))
            XCTAssertFalse(source.contains("ComposeTranscript"))
        }
        XCTAssertTrue(decisions.contains(
            "## D334 — Structural transcript rows own shared search identity"))
    }

    func testDatabaseLaunchFailureIsRecoverablePrivateAndFailClosed() throws {
        let services = try Self.contents(
            of: "Sources/portavoz-app/AppServices.swift")
        let launch = try Self.contents(
            of: "Sources/portavoz-app/AppLaunchModel.swift")
        let view = try Self.contents(
            of: "Sources/portavoz-app/AppLaunchRecoveryView.swift")
        let storage = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+LaunchRecovery.swift")
        let app = try Self.contents(
            of: "Sources/portavoz-app/PortavozApp.swift")
        let intents = try Self.contents(
            of: "Sources/portavoz-app/PortavozAppIntents.swift")
        let architecture = try Self.contents(of: "docs/ARCHITECTURE.md")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")
        let gaps = try Self.contents(of: "docs/GAPS.md")
        let uiTests = try Self.contents(
            of: "Tests/PortavozUITests/LibraryUITests.swift")

        XCTAssertFalse(services.contains("fatalError"))
        XCTAssertTrue(services.contains(") throws {"))
        let storeOpen = try XCTUnwrap(services.range(
            of: "store = try Self.makeMeetingStore"))
        let telemetryInstall = try XCTUnwrap(services.range(
            of: "IntelligenceScheduler.installSharedTelemetry"))
        XCTAssertLessThan(storeOpen.lowerBound, telemetryInstall.lowerBound)

        XCTAssertTrue(launch.contains("case databaseUnavailable"))
        XCTAssertTrue(launch.contains("private var activatedServices = false"))
        XCTAssertTrue(launch.contains("guard !activatedServices"))
        XCTAssertTrue(launch.contains("func retry() async"))
        XCTAssertTrue(launch.contains("MeetingStore.openFailureEvidence"))
        XCTAssertFalse(launch.contains("String(describing: error)"))
        XCTAssertFalse(launch.contains("localizedDescription"))
        XCTAssertTrue(launch.contains(
            "PortavozAppIntentBridge.notifyPendingStartRecordingRequest()"))
        XCTAssertTrue(intents.contains(
            "static func notifyPendingStartRecordingRequest()"))
        XCTAssertTrue(app.contains("AppLaunchRecoveryView(model: model)"))

        for identifier in [
            "launch-recovery-title",
            "launch-recovery-retry",
            "launch-recovery-save-copy",
            "launch-recovery-export-diagnostics",
        ] {
            XCTAssertTrue(view.contains(identifier))
        }
        XCTAssertTrue(storage.contains("sourceConfiguration.readonly = true"))
        XCTAssertTrue(storage.contains("source.backup(to: destination"))
        XCTAssertTrue(storage.contains("case sourceChanged"))
        XCTAssertTrue(storage.contains("sourceSnapshotEvidence("))
        XCTAssertTrue(storage.contains("PRAGMA quick_check"))
        XCTAssertTrue(storage.contains(".posixPermissions: 0o700"))
        XCTAssertTrue(storage.contains(".posixPermissions: 0o600"))
        XCTAssertTrue(storage.contains(".portavoz-recovery-"))
        XCTAssertTrue(storage.contains("manager.moveItem(at: stageURL, to: finalURL)"))
        XCTAssertFalse(storage.contains("removeItem(at: canonicalSource"))
        XCTAssertTrue(uiTests.contains(
            "let leakedStages = destinationArtifacts.filter"))
        XCTAssertTrue(uiTests.contains(
            "one activation must publish one visible recovery directory"))
        XCTAssertTrue(uiTests.contains(
            "let recoveryCopy = try XCTUnwrap(copies.first)"))

        XCTAssertTrue(architecture.contains("Database launch recovery"))
        XCTAssertTrue(decisions.contains("## D319"))
        XCTAssertTrue(decisions.contains("## D423"))
        XCTAssertTrue(gaps.contains("T32 | ~~Database-open failure"))
        XCTAssertTrue(gaps.contains("RESOLVED in code (D319)"))
    }

    func testBackgroundWorkCenterRemainsOneContentFreeOwnerFedProjection() throws {
        let model = try Self.contents(
            of: "Sources/portavoz-app/BackgroundWorkCenterModel.swift")
        let services = try Self.contents(of: "Sources/portavoz-app/AppServices.swift")
        let ask = try Self.contents(of: "Sources/portavoz-app/AppServices+Ask.swift")
        let recovery = try Self.contents(
            of: "Sources/portavoz-app/RecordingRecoveryCoordinator.swift")
        let processing = try Self.contents(
            of: "Sources/portavoz-app/PostCaptureProcessingCoordinator.swift")
        let spotlight = try Self.contents(
            of: "Sources/portavoz-app/SpotlightIndexer.swift")
        let view = try Self.contents(
            of: "Sources/portavoz-app/BackgroundWorkCenterView.swift")
        let scope = try Self.contents(of: "scripts/ui_test_scope.py")
        let architecture = try Self.contents(of: "docs/ARCHITECTURE.md")
        let appSpec = try Self.contents(of: "docs/specs/06-app-macos.md")
        let qualitySpec = try Self.contents(of: "docs/specs/08-quality.md")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")
        let gaps = try Self.contents(of: "docs/GAPS.md")

        XCTAssertTrue(model.contains("@MainActor\n@Observable\nfinal class BackgroundWorkCenterModel"))
        XCTAssertFalse(model.contains("Task {"))
        XCTAssertFalse(model.contains("Task.sleep"))
        XCTAssertFalse(model.contains("Timer"))
        XCTAssertFalse(model.contains("0.25"))
        XCTAssertEqual(
            services.components(separatedBy:
                "let backgroundWork: BackgroundWorkCenterModel").count - 1,
            1,
            "AppServices must own exactly one process-wide projection")

        let metricsStart = try XCTUnwrap(model.range(
            of: "struct BackgroundWorkMetrics"))
        let tokenStart = try XCTUnwrap(model.range(
            of: "struct BackgroundWorkRunToken",
            range: metricsStart.upperBound..<model.endIndex))
        let projectionContract = model[
            metricsStart.lowerBound..<tokenStart.lowerBound]
        for forbidden in [
            "String", "URL", "MeetingID", "Transcript", "relativePath",
            "localizedDescription", "Error",
        ] {
            XCTAssertFalse(
                projectionContract.contains(forbidden),
                "Background status must not admit content field \(forbidden)")
        }

        XCTAssertTrue(recovery.contains("backgroundWork.begin(\n            .recovery"))
        XCTAssertTrue(recovery.contains("backgroundWork.finishRecovery"))
        XCTAssertTrue(processing.contains("backgroundWork.begin(\n                .processing"))
        XCTAssertTrue(processing.contains("backgroundWork.finishProcessingJob"))
        XCTAssertTrue(processing.contains("backgroundWork?.finishProcessingDrain"))
        XCTAssertEqual(
            processing.components(separatedBy:
                "guard generation == kickGeneration, drainTask == nil else { return }")
                .count - 1,
            2,
            "both wake success and failure must fence an obsolete drain")
        XCTAssertTrue(spotlight.contains("statusChanged: @Sendable (Status, Date?)"))
        XCTAssertTrue(spotlight.contains("await statusChanged(status, retryAt)"))
        XCTAssertTrue(ask.contains("backgroundWork.model.observeSemantic"))
        XCTAssertTrue(ask.contains("backgroundWork.model.finishSemantic"))
        XCTAssertTrue(ask.contains("backgroundWork.model.observeMemoryGraph"))
        XCTAssertTrue(ask.contains("backgroundWork.model.finishMemoryGraph"))

        for identifier in [
            "background-work-row-\\(snapshot.owner.rawValue)",
            "background-work-status-\\(snapshot.owner.rawValue)",
            "background-work-detail-\\(snapshot.owner.rawValue)",
            "background-work-action-\\(snapshot.owner.rawValue)",
        ] {
            XCTAssertTrue(view.contains(identifier))
        }
        XCTAssertTrue(scope.contains(#""background-work": ("#))
        XCTAssertEqual(
            scope.components(separatedBy: #""BackgroundWorkUITests""#).count - 1,
            2)
        XCTAssertTrue(scope.contains(
            #""testBackgroundWorkCenterShowsAllOwnersAndRecoversExactFailures""#))
        XCTAssertTrue(scope.contains(
            #""testRecordingDefersDerivedWorkAndStopResumesIt""#))
        XCTAssertTrue(model.contains("arguments.contains(\"-use-temp-store\")"))
        XCTAssertTrue(model.contains("arguments.contains(\"-seed-background-work\")"))
        XCTAssertTrue(architecture.contains("### Background work projection"))
        XCTAssertTrue(appSpec.contains("### Background activity center (D427)"))
        XCTAssertTrue(qualitySpec.contains("D427 background-owner projection evidence"))
        XCTAssertTrue(decisions.contains("## D427"))
        XCTAssertTrue(gaps.contains("BACKGROUND WORK CENTER IMPLEMENTED IN CODE (D427)"))
    }
}
