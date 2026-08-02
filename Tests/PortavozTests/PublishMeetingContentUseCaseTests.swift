import ApplicationKit
import Foundation
import PortavozCore
import XCTest

final class PublishMeetingContentUseCaseTests: XCTestCase {
    func testPrepareDocumentPreservesReleasedFilenameAndExactBytes() async throws {
        let fixture = PublishingFixture(title: "Weekly Sync / Q3")
        let useCase = PrepareMeetingDocument(
            library: fixture.library,
            documents: MeetingDocumentsFake())

        let markdown = try await useCase.execute(.init(
            meetingID: fixture.meetingID,
            format: .markdown))
        let pdf = try await useCase.execute(.init(
            meetingID: fixture.meetingID,
            format: .pdf))
        let srt = try await useCase.execute(.init(
            meetingID: fixture.meetingID,
            format: .srt))
        let vtt = try await useCase.execute(.init(
            meetingID: fixture.meetingID,
            format: .vtt))

        XCTAssertEqual(markdown.filename, "Weekly Sync / Q3.md")
        XCTAssertEqual(markdown.data, Data("# Weekly Sync".utf8))
        XCTAssertEqual(pdf.filename, "Weekly Sync / Q3.pdf")
        XCTAssertEqual(pdf.data, Data([1, 2, 3]))
        XCTAssertEqual(srt.filename, "Weekly Sync / Q3.srt")
        XCTAssertEqual(srt.data, Data("1\nfixture".utf8))
        XCTAssertEqual(vtt.filename, "Weekly Sync / Q3.vtt")
        XCTAssertEqual(vtt.data, Data("WEBVTT\n\nfixture".utf8))
    }

    func testDocumentFormatsOwnTheirAcceptedFileExtensions() {
        XCTAssertEqual(MeetingDocumentFormat(fileExtension: "md"), .markdown)
        XCTAssertEqual(MeetingDocumentFormat(fileExtension: "MARKDOWN"), .markdown)
        XCTAssertEqual(MeetingDocumentFormat(fileExtension: "PDF"), .pdf)
        XCTAssertEqual(MeetingDocumentFormat(fileExtension: "srt"), .srt)
        XCTAssertEqual(MeetingDocumentFormat(fileExtension: "VTT"), .vtt)
        XCTAssertNil(MeetingDocumentFormat(fileExtension: "txt"))
        XCTAssertEqual(MeetingDocumentFormat.markdown.filenameExtension, "md")
        XCTAssertEqual(MeetingDocumentFormat.srt.subtitleFormat, .srt)
        XCTAssertNil(MeetingDocumentFormat.pdf.subtitleFormat)
    }

    func testPrepareDocumentRejectsMissingMeetingBeforeRendering() async {
        let documents = MeetingDocumentsFake()
        let useCase = PrepareMeetingDocument(
            library: QueryMeetingLibrary(reader: PublishingReaderFake(detail: nil)),
            documents: documents)

        do {
            _ = try await useCase.execute(.init(
                meetingID: MeetingID(),
                format: .markdown))
            XCTFail("expected missing meeting")
        } catch let error as ExportMeetingDocumentError {
            XCTAssertEqual(error, .meetingNotFound)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        let markdownCalls = await documents.markdownCalls
        XCTAssertEqual(markdownCalls, 0)
    }

    func testPrepareSubtitleDoesNotRenderAnUnrelatedMarkdownDocument() async throws {
        let fixture = PublishingFixture()
        let documents = MeetingDocumentsFake()
        let useCase = PrepareMeetingDocument(
            library: fixture.library,
            documents: documents)

        let document = try await useCase.execute(.init(
            meetingID: fixture.meetingID,
            format: .srt))

        XCTAssertEqual(document.filename, "Weekly Sync.srt")
        let markdownCalls = await documents.markdownCalls
        let subtitleFormats = await documents.subtitleFormats
        XCTAssertEqual(markdownCalls, 0)
        XCTAssertEqual(subtitleFormats, [.srt])
    }

    func testExportReturnsMarkdownWithoutTouchingFilesystem() async throws {
        let fixture = PublishingFixture()
        let files = OutputFilesSpy()
        let useCase = ExportMeetingDocument(
            library: fixture.library,
            documents: MeetingDocumentsFake(),
            files: files)

        let result = try await useCase.execute(ExportMeetingDocumentRequest(
            meetingID: fixture.meetingID,
            format: .markdown))

        XCTAssertEqual(result, .markdown("# Weekly Sync"))
        let writes = await files.writes
        XCTAssertTrue(writes.isEmpty)
    }

    func testExportWritesRequestedFormatAndRequiresPDFDestination() async throws {
        let fixture = PublishingFixture()
        let files = OutputFilesSpy()
        let useCase = ExportMeetingDocument(
            library: fixture.library,
            documents: MeetingDocumentsFake(),
            files: files)
        let destination = URL(fileURLWithPath: "/tmp/meeting.pdf")

        let result = try await useCase.execute(ExportMeetingDocumentRequest(
            meetingID: fixture.meetingID,
            format: .pdf,
            outputURL: destination))

        XCTAssertEqual(result, .written(path: destination.path, bytes: 3))
        let writes = await files.writes
        XCTAssertEqual(writes.map(\.url), [destination])
        do {
            _ = try await useCase.execute(ExportMeetingDocumentRequest(
                meetingID: fixture.meetingID,
                format: .pdf))
            XCTFail("expected output requirement")
        } catch let error as ExportMeetingDocumentError {
            XCTAssertEqual(error, .outputFileRequired)
        }
    }

    func testSubtitleExportDoesNotRenderAnUnrelatedMarkdownDocument() async throws {
        let fixture = PublishingFixture()
        let documents = MeetingDocumentsFake()
        let files = OutputFilesSpy()
        let useCase = ExportMeetingDocument(
            library: fixture.library,
            documents: documents,
            files: files)
        let destination = URL(fileURLWithPath: "/tmp/meeting.vtt")

        let result = try await useCase.execute(ExportMeetingDocumentRequest(
            meetingID: fixture.meetingID,
            format: .vtt,
            outputURL: destination))

        XCTAssertEqual(
            result,
            .written(path: destination.path, bytes: Data("WEBVTT\n\nfixture".utf8).count))
        let markdownCalls = await documents.markdownCalls
        let subtitleFormats = await documents.subtitleFormats
        XCTAssertEqual(markdownCalls, 0)
        XCTAssertEqual(subtitleFormats, [.vtt])
    }

    func testCorrectedDocumentUsesComposedRowsAndOmitsAStaleSummary() async throws {
        let meeting = correctionMeeting()
        let source = correctionSegment(meeting: meeting, id: correctionID(2))
        let correction = correctionEvent(
            meeting: meeting,
            id: correctionID(10),
            sourceID: source.id,
            kind: .replaceText(text: "Hola, probando.", language: "es"))
        let detail = MeetingLibraryDetail(
            meeting: meeting,
            speakers: [],
            segments: [source],
            corrections: [correction],
            summary: SummaryDraft(
                meetingID: meeting.id,
                recipeID: Recipe.general.id,
                language: "en",
                markdown: "Stale summary",
                actionItems: []),
            summaryVersion: 3)
        let documents = MeetingDocumentsFake()
        let useCase = PrepareMeetingDocument(
            library: QueryMeetingLibrary(reader: PublishingReaderFake(detail: detail)),
            documents: documents)

        _ = try await useCase.execute(.init(
            meetingID: meeting.id,
            format: .markdown,
            options: MeetingDocumentOptions(includeCorrectionProvenance: true)))

        let renderedContents = await documents.contents
        let content = try XCTUnwrap(renderedContents.first)
        XCTAssertEqual(content.segments.map(\.text), ["Hola, probando."])
        XCTAssertEqual(content.segments.map(\.language), ["es"])
        XCTAssertEqual(content.segments.map(\.startTime), [12])
        XCTAssertEqual(content.segments.map(\.endTime), [18])
        XCTAssertNil(content.summary)
        XCTAssertNil(content.summaryVersion)
        let provenance = try XCTUnwrap(content.correctionProvenance)
        let exportedSegment = try XCTUnwrap(content.segments.first)
        XCTAssertEqual(provenance.baseTranscriptRevision, meeting.transcriptRevision)
        XCTAssertEqual(provenance.activeCorrectionIDs, [correction.id])
        XCTAssertEqual(
            provenance.sourceSegmentIDsByExportedSegmentID[exportedSegment.id],
            [source.id])
    }

    func testSplitExportPreservesOriginalTimelineAndMakesProvenanceOptIn() async throws {
        let meeting = correctionMeeting()
        let source = correctionSegment(meeting: meeting, id: correctionID(2))
        let firstPartID = correctionID(11)
        let secondPartID = correctionID(12)
        let split = correctionEvent(
            meeting: meeting,
            id: correctionID(10),
            sourceID: source.id,
            kind: .split([
                TranscriptCorrectionPart(
                    id: firstPartID,
                    text: "Primera parte",
                    speakerID: nil,
                    language: "es",
                    startTime: 12,
                    endTime: 14.5),
                TranscriptCorrectionPart(
                    id: secondPartID,
                    text: "segunda parte",
                    speakerID: nil,
                    language: "es",
                    startTime: 14.5,
                    endTime: 18),
            ]))
        let revision = try TranscriptCorrectionRevision.current(
            meetingID: meeting.id,
            baseTranscriptRevision: meeting.transcriptRevision,
            history: [split])
        let summary = SummaryDraft(
            meetingID: meeting.id,
            recipeID: Recipe.general.id,
            language: "es",
            markdown: "Resumen vigente",
            actionItems: [])
        let detail = MeetingLibraryDetail(
            meeting: meeting,
            speakers: [],
            segments: [source],
            corrections: [split],
            summary: summary,
            summaryVersion: 4,
            summaryCorrectionSource: .revision(revision))
        let documents = MeetingDocumentsFake()
        let useCase = PrepareMeetingDocument(
            library: QueryMeetingLibrary(reader: PublishingReaderFake(detail: detail)),
            documents: documents)

        _ = try await useCase.execute(.init(
            meetingID: meeting.id,
            format: .markdown))
        _ = try await useCase.execute(.init(
            meetingID: meeting.id,
            format: .markdown,
            options: MeetingDocumentOptions(includeCorrectionProvenance: true)))

        let contents = await documents.contents
        XCTAssertEqual(contents.count, 2)
        XCTAssertEqual(contents[0].segments.map(\.id), [firstPartID, secondPartID])
        XCTAssertEqual(contents[0].segments.map(\.startTime), [12, 14.5])
        XCTAssertEqual(contents[0].segments.map(\.endTime), [14.5, 18])
        XCTAssertEqual(contents[0].summary?.meetingID, summary.meetingID)
        XCTAssertEqual(contents[0].summary?.markdown, summary.markdown)
        XCTAssertEqual(contents[0].summaryVersion, 4)
        XCTAssertNil(contents[0].correctionProvenance)
        let provenance = try XCTUnwrap(contents[1].correctionProvenance)
        XCTAssertEqual(provenance.sourceSegmentIDsByExportedSegmentID, [
            firstPartID: [source.id],
            secondPartID: [source.id],
        ])
    }

    func testDocumentProjectionRejectsCorrectionRevisionMismatch() async {
        let meeting = correctionMeeting()
        let source = correctionSegment(meeting: meeting, id: correctionID(2))
        let correction = correctionEvent(
            meeting: meeting,
            id: correctionID(10),
            sourceID: source.id,
            kind: .replaceText(text: "Corrected", language: "en"))
        let detail = MeetingLibraryDetail(
            meeting: meeting,
            speakers: [],
            segments: [source],
            corrections: [correction],
            correctionRevision: .accepted,
            summary: nil,
            summaryVersion: nil)
        let documents = MeetingDocumentsFake()
        let useCase = PrepareMeetingDocument(
            library: QueryMeetingLibrary(reader: PublishingReaderFake(detail: detail)),
            documents: documents)

        do {
            _ = try await useCase.execute(.init(
                meetingID: meeting.id,
                format: .markdown))
            XCTFail("expected fail-closed correction projection")
        } catch let error as ExportMeetingDocumentError {
            XCTAssertEqual(error, .invalidCorrectionSnapshot)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        let renderedContents = await documents.contents
        XCTAssertTrue(renderedContents.isEmpty)
    }

    func testOutputRequirementCopyAppliesToEveryNonStreamingFormat() {
        XCTAssertEqual(
            ExportMeetingDocumentError.outputFileRequired.errorDescription,
            "this export format requires --out <path>")
    }

    func testExplicitPublisherReceivesSluggedCurrentDocument() async throws {
        let fixture = PublishingFixture(title: "Weekly Sync / Q3")
        let publisher = MeetingDocumentPublisherSpy()
        let progress = DocumentPublishingProgressRecorder()
        let useCase = ExportMeetingDocument(
            library: fixture.library,
            documents: MeetingDocumentsFake(),
            publisher: publisher)

        let result = try await useCase.execute(ExportMeetingDocumentRequest(
            meetingID: fixture.meetingID,
            format: .markdown
        ) { event in
            await progress.append(event)
        })

        XCTAssertEqual(result, .published(URL(string: "https://example.test/gist")!))
        let publishedCall = await publisher.call
        let call = try XCTUnwrap(publishedCall)
        XCTAssertEqual(call.meetingID, fixture.meetingID)
        XCTAssertEqual(call.markdown, "# Weekly Sync")
        XCTAssertEqual(call.filename, "weekly-sync-q3.md")
        XCTAssertEqual(call.description, "Weekly Sync / Q3")
        let progressEvents = await progress.events
        XCTAssertEqual(progressEvents, [.publishing])
        let preparationCount = await publisher.preparationCount
        XCTAssertEqual(preparationCount, 1)
    }

    func testExportRejectsMissingMeetingBeforeRendering() async {
        let reader = PublishingReaderFake(detail: nil)
        let documents = MeetingDocumentsFake()
        let useCase = ExportMeetingDocument(
            library: QueryMeetingLibrary(reader: reader),
            documents: documents,
            files: OutputFilesSpy())

        do {
            _ = try await useCase.execute(ExportMeetingDocumentRequest(
                meetingID: MeetingID(),
                format: .markdown))
            XCTFail("expected missing meeting")
        } catch let error as ExportMeetingDocumentError {
            XCTAssertEqual(error, .meetingNotFound)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        let markdownCalls = await documents.markdownCalls
        XCTAssertEqual(markdownCalls, 0)
    }

    func testActionItemPublishingKeepsPendingOrderAndOwnerNames() async throws {
        let fixture = PublishingFixture(includeSummary: true)
        let publisher = ActionItemPublisherSpy()
        let progress = PublishingProgressRecorder()
        let useCase = PublishMeetingActionItems(
            library: fixture.library,
            publisher: publisher)

        let result = try await useCase.execute(PublishMeetingActionItemsRequest(
            meetingID: fixture.meetingID
        ) { event in
            await progress.append(event)
        })

        guard case .published(let published) = result
        else { return XCTFail("expected published actions") }
        XCTAssertEqual(published.map(\.text), ["Ship build", "Write notes"])
        let progressEvents = await progress.events
        XCTAssertEqual(progressEvents, [.publishing(count: 2)])
        let calls = await publisher.calls
        XCTAssertEqual(calls.map(\.ownerName), ["Ana", nil])
        XCTAssertEqual(calls.map(\.meetingTitle), ["Weekly Sync", "Weekly Sync"])
        let preparationCount = await publisher.preparationCount
        XCTAssertEqual(preparationCount, 1)
    }

    func testActionItemPublishingReturnsTypedEmptyAndMissingStates() async throws {
        let noPending = PublishingFixture(includeSummary: true, allDone: true)
        let publisher = ActionItemPublisherSpy()
        let useCase = PublishMeetingActionItems(
            library: noPending.library,
            publisher: publisher)
        let result = try await useCase.execute(.init(meetingID: noPending.meetingID))
        XCTAssertEqual(result, .noPendingItems)
        let publishedCalls = await publisher.calls
        XCTAssertTrue(publishedCalls.isEmpty)
        let noPendingPreparationCount = await publisher.preparationCount
        XCTAssertEqual(noPendingPreparationCount, 0)

        let missing = PublishMeetingActionItems(
            library: QueryMeetingLibrary(reader: PublishingReaderFake(detail: nil)),
            publisher: publisher)
        do {
            _ = try await missing.execute(.init(meetingID: MeetingID()))
            XCTFail("expected missing summary")
        } catch let error as PublishMeetingActionItemsError {
            XCTAssertEqual(error, .meetingOrSummaryNotFound)
        }
        let missingPreparationCount = await publisher.preparationCount
        XCTAssertEqual(missingPreparationCount, 0)
    }
}

private func correctionMeeting() -> Meeting {
    Meeting(
        id: MeetingID(rawValue: correctionID(1)),
        title: "Correction export",
        startedAt: Date(timeIntervalSince1970: 1_800_000_000),
        endedAt: Date(timeIntervalSince1970: 1_800_000_030),
        language: "es",
        transcriptRevision: 4)
}

private func correctionSegment(meeting: Meeting, id: UUID) -> TranscriptSegment {
    TranscriptSegment(
        id: id,
        meetingID: meeting.id,
        channel: .system,
        text: "Original words",
        language: "en",
        startTime: 12,
        endTime: 18,
        confidence: 0.8,
        isFinal: true)
}

private func correctionEvent(
    meeting: Meeting,
    id: UUID,
    sourceID: UUID,
    kind: TranscriptCorrectionKind
) -> TranscriptCorrectionEvent {
    TranscriptCorrectionEvent(
        id: id,
        meetingID: meeting.id,
        baseTranscriptRevision: meeting.transcriptRevision,
        targetSegmentIDs: [sourceID],
        kind: kind,
        sourceDeviceID: correctionID(999),
        createdAt: Date(timeIntervalSince1970: 1_800_000_010))
}

private func correctionID(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", value))!
}

private struct PublishingFixture {
    let meetingID = MeetingID(rawValue: UUID(
        uuidString: "00000000-0000-0000-0000-000000000421")!)
    let library: QueryMeetingLibrary

    init(
        title: String = "Weekly Sync",
        includeSummary: Bool = false,
        allDone: Bool = false
    ) {
        let meeting = Meeting(
            id: meetingID,
            title: title,
            startedAt: Date(timeIntervalSince1970: 10),
            endedAt: Date(timeIntervalSince1970: 20),
            language: "en")
        let speaker = Speaker(
            meetingID: meetingID,
            label: "S1",
            displayName: "Ana")
        let summary = includeSummary ? SummaryDraft(
            meetingID: meetingID,
            recipeID: "general",
            language: "en",
            markdown: "# Weekly Sync",
            actionItems: [
                ActionItem(
                    text: "Ship build",
                    ownerSpeakerID: speaker.id,
                    isDone: allDone),
                ActionItem(text: "Write notes", isDone: allDone),
                ActionItem(text: "Already done", isDone: true),
            ]) : nil
        let detail = MeetingLibraryDetail(
            meeting: meeting,
            speakers: [speaker],
            segments: [],
            summary: summary,
            summaryVersion: summary == nil ? nil : 2)
        library = QueryMeetingLibrary(reader: PublishingReaderFake(detail: detail))
    }
}

private actor PublishingReaderFake: MeetingLibraryQueryReading {
    let detail: MeetingLibraryDetail?
    init(detail: MeetingLibraryDetail?) { self.detail = detail }

    func meetingLibraryMeetings(limit: Int?) -> [Meeting] {
        _ = limit
        return []
    }

    func meetingLibraryDetail(_ id: MeetingID) -> MeetingLibraryDetail? {
        _ = id
        return detail
    }

    func meetingLibrarySearch(_ query: String, limit: Int) -> [LibrarySearchHit] {
        _ = query
        _ = limit
        return []
    }

    func meetingLibraryOpenItems(limit: Int) -> [LibraryOpenItem] {
        _ = limit
        return []
    }
}

private actor MeetingDocumentsFake: MeetingDocumentRendering {
    private(set) var markdownCalls = 0
    private(set) var subtitleFormats: [MeetingSubtitleFormat] = []
    private(set) var contents: [MeetingDocumentContent] = []

    func markdown(from content: MeetingDocumentContent) -> String {
        contents.append(content)
        markdownCalls += 1
        return "# Weekly Sync"
    }

    func pdf(fromMarkdown markdown: String) -> Data {
        _ = markdown
        return Data([1, 2, 3])
    }

    func subtitles(
        from content: MeetingDocumentContent,
        format: MeetingSubtitleFormat
    ) -> String {
        contents.append(content)
        subtitleFormats.append(format)
        return format == .vtt ? "WEBVTT\n\nfixture" : "1\nfixture"
    }
}

private actor OutputFilesSpy: ApplicationOutputFileWriting {
    struct Write: Sendable {
        let data: Data
        let url: URL
    }
    private(set) var writes: [Write] = []

    func write(_ data: Data, to url: URL) {
        writes.append(Write(data: data, url: url))
    }
}

private actor MeetingDocumentPublisherSpy: MeetingDocumentPublishing {
    struct Call: Sendable {
        let meetingID: MeetingID
        let markdown: String
        let filename: String
        let description: String
    }
    private(set) var call: Call?
    private(set) var preparationCount = 0

    func prepare() {
        preparationCount += 1
    }

    func publish(
        meetingID: MeetingID,
        markdown: String,
        filename: String,
        description: String
    ) -> URL {
        call = Call(
            meetingID: meetingID,
            markdown: markdown,
            filename: filename,
            description: description)
        return URL(string: "https://example.test/gist")!
    }
}

private actor ActionItemPublisherSpy: MeetingActionItemPublishing {
    struct Call: Sendable {
        let text: String
        let meetingTitle: String
        let ownerName: String?
    }
    private(set) var calls: [Call] = []
    private(set) var preparationCount = 0

    func prepare() {
        preparationCount += 1
    }

    func publish(
        _ item: ActionItem,
        meetingID: MeetingID,
        meetingTitle: String,
        ownerName: String?
    ) -> URL {
        _ = meetingID
        calls.append(Call(
            text: item.text,
            meetingTitle: meetingTitle,
            ownerName: ownerName))
        return URL(string: "https://example.test/issues/\(calls.count)")!
    }
}

private actor DocumentPublishingProgressRecorder {
    private(set) var events: [ExportMeetingDocumentProgress] = []
    func append(_ event: ExportMeetingDocumentProgress) { events.append(event) }
}

private actor PublishingProgressRecorder {
    private(set) var events: [PublishMeetingActionItemsProgress] = []
    func append(_ event: PublishMeetingActionItemsProgress) { events.append(event) }
}
