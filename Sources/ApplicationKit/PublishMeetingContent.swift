import Foundation
import PortavozCore

public enum MeetingDocumentFormat: String, Equatable, Sendable {
    case markdown
    case pdf
    case srt
    case vtt

    public init?(fileExtension: String) {
        switch fileExtension.lowercased() {
        case "md", "markdown":
            self = .markdown
        case "pdf":
            self = .pdf
        case "srt":
            self = .srt
        case "vtt":
            self = .vtt
        default:
            return nil
        }
    }

    public var filenameExtension: String {
        self == .markdown ? "md" : rawValue
    }

    public var subtitleFormat: MeetingSubtitleFormat? {
        switch self {
        case .srt:
            .srt
        case .vtt:
            .vtt
        case .markdown, .pdf:
            nil
        }
    }
}

/// Narrows the subtitle-rendering port so callers cannot accidentally route a
/// Markdown or PDF request through an adapter that silently emits SRT.
public enum MeetingSubtitleFormat: String, Equatable, Sendable {
    case srt
    case vtt
}

public protocol MeetingDocumentRendering: Sendable {
    func markdown(from content: MeetingDocumentContent) async throws -> String
    func pdf(fromMarkdown markdown: String) async throws -> Data
    func subtitles(
        from content: MeetingDocumentContent,
        format: MeetingSubtitleFormat
    ) async throws -> String
}

public struct MeetingDocumentOptions: Equatable, Sendable {
    public let includeCorrectionProvenance: Bool

    public init(includeCorrectionProvenance: Bool = false) {
        self.includeCorrectionProvenance = includeCorrectionProvenance
    }
}

/// One correction-aware, read-consistent projection consumed by every local
/// document renderer. The accepted transcript and audio remain immutable;
/// exported rows are ephemeral views that retain their source coordinates.
public struct MeetingDocumentContent: Sendable {
    public let meeting: Meeting
    public let speakers: [Speaker]
    public let segments: [TranscriptSegment]
    public let summary: SummaryDraft?
    public let summaryVersion: Int?
    public let correctionProvenance: TranscriptCorrectionExportProvenance?

    public init(
        meeting: Meeting,
        speakers: [Speaker],
        segments: [TranscriptSegment],
        summary: SummaryDraft?,
        summaryVersion: Int?,
        correctionProvenance: TranscriptCorrectionExportProvenance?
    ) {
        self.meeting = meeting
        self.speakers = speakers
        self.segments = segments
        self.summary = summary
        self.summaryVersion = summaryVersion
        self.correctionProvenance = correctionProvenance
    }
}

public protocol ApplicationOutputFileWriting: Sendable {
    func write(_ data: Data, to url: URL) async throws
}

public protocol MeetingDocumentPublishing: Sendable {
    /// Resolves credentials and validates destination configuration after the
    /// local document exists but before presentation announces remote egress.
    func prepare() async throws
    func publish(
        meetingID: MeetingID,
        markdown: String,
        filename: String,
        description: String
    ) async throws -> URL
}

public extension MeetingDocumentPublishing {
    func prepare() async throws {}
}

public enum ExportMeetingDocumentError: Error, Equatable, LocalizedError, Sendable {
    case meetingNotFound
    case outputFileRequired
    case invalidCorrectionSnapshot

    public var errorDescription: String? {
        switch self {
        case .meetingNotFound:
            "no such meeting"
        case .outputFileRequired:
            "this export format requires --out <path>"
        case .invalidCorrectionSnapshot:
            "the corrected transcript could not be exported safely"
        }
    }
}

public struct ExportMeetingDocumentRequest: Sendable {
    public let meetingID: MeetingID
    public let format: MeetingDocumentFormat
    public let outputURL: URL?
    public let options: MeetingDocumentOptions
    public let progress: ExportMeetingDocumentProgressHandler

    public init(
        meetingID: MeetingID,
        format: MeetingDocumentFormat,
        outputURL: URL? = nil,
        options: MeetingDocumentOptions = MeetingDocumentOptions(),
        progress: @escaping ExportMeetingDocumentProgressHandler = { _ in }
    ) {
        self.meetingID = meetingID
        self.format = format
        self.outputURL = outputURL
        self.options = options
        self.progress = progress
    }
}

public enum ExportMeetingDocumentProgress: Equatable, Sendable {
    case publishing
}

public typealias ExportMeetingDocumentProgressHandler =
    @Sendable (ExportMeetingDocumentProgress) async -> Void

public enum ExportMeetingDocumentResult: Equatable, Sendable {
    case markdown(String)
    case written(path: String, bytes: Int)
    case published(URL)
}

public struct PreparedMeetingDocument: Equatable, Sendable {
    public let data: Data
    public let filename: String

    public init(data: Data, filename: String) {
        self.data = data
        self.filename = filename
    }
}

public struct PrepareMeetingDocumentRequest: Sendable {
    public let meetingID: MeetingID
    public let format: MeetingDocumentFormat
    public let options: MeetingDocumentOptions

    public init(
        meetingID: MeetingID,
        format: MeetingDocumentFormat,
        options: MeetingDocumentOptions = MeetingDocumentOptions()
    ) {
        self.meetingID = meetingID
        self.format = format
        self.options = options
    }
}

/// Produces an in-memory document from one read-consistent meeting snapshot.
/// Native presentation surfaces retain ownership of save panels and clipboard
/// access; document selection, rendering, and suggested naming stay here.
public struct PrepareMeetingDocument: ApplicationUseCase {
    private let library: QueryMeetingLibrary
    private let documents: any MeetingDocumentRendering

    public init(
        library: QueryMeetingLibrary,
        documents: any MeetingDocumentRendering
    ) {
        self.library = library
        self.documents = documents
    }

    public func execute(
        _ request: PrepareMeetingDocumentRequest
    ) async throws -> PreparedMeetingDocument {
        guard let detail = try await library.detail(request.meetingID) else {
            throw ExportMeetingDocumentError.meetingNotFound
        }
        let content = try MeetingDocumentProjection.make(
            detail: detail,
            options: request.options)
        switch request.format {
        case .markdown:
            let markdown = try await documents.markdown(from: content)
            return PreparedMeetingDocument(
                data: Data(markdown.utf8),
                filename: "\(detail.meeting.title).md")
        case .pdf:
            let markdown = try await documents.markdown(from: content)
            return PreparedMeetingDocument(
                data: try await documents.pdf(fromMarkdown: markdown),
                filename: "\(detail.meeting.title).pdf")
        case .srt, .vtt:
            guard let subtitleFormat = request.format.subtitleFormat else {
                preconditionFailure("subtitle branch requires a subtitle format")
            }
            let subtitles = try await documents.subtitles(
                from: content, format: subtitleFormat)
            return PreparedMeetingDocument(
                data: Data(subtitles.utf8),
                filename: "\(detail.meeting.title).\(request.format.filenameExtension)")
        }
    }
}

/// Read one coherent meeting document, then return it, publish it explicitly,
/// or write it through an injected filesystem port.
public struct ExportMeetingDocument: ApplicationUseCase {
    private let library: QueryMeetingLibrary
    private let documents: any MeetingDocumentRendering
    private let files: (any ApplicationOutputFileWriting)?
    private let publisher: (any MeetingDocumentPublishing)?

    public init(
        library: QueryMeetingLibrary,
        documents: any MeetingDocumentRendering,
        files: (any ApplicationOutputFileWriting)? = nil,
        publisher: (any MeetingDocumentPublishing)? = nil
    ) {
        self.library = library
        self.documents = documents
        self.files = files
        self.publisher = publisher
    }

    public func execute(
        _ request: ExportMeetingDocumentRequest
    ) async throws -> ExportMeetingDocumentResult {
        guard let detail = try await library.detail(request.meetingID) else {
            throw ExportMeetingDocumentError.meetingNotFound
        }
        let content = try MeetingDocumentProjection.make(
            detail: detail,
            options: request.options)
        if let publisher {
            let markdown = try await documents.markdown(from: content)
            try await publisher.prepare()
            await request.progress(.publishing)
            return .published(try await publisher.publish(
                meetingID: request.meetingID,
                markdown: markdown,
                filename: "\(Self.slug(detail.meeting.title)).md",
                description: detail.meeting.title))
        }

        switch request.format {
        case .markdown:
            let markdown = try await documents.markdown(from: content)
            guard let outputURL = request.outputURL else {
                return .markdown(markdown)
            }
            guard let files else {
                throw ExportMeetingDocumentError.outputFileRequired
            }
            let data = Data(markdown.utf8)
            try await files.write(data, to: outputURL)
            return .written(path: outputURL.path, bytes: data.count)
        case .pdf:
            guard let outputURL = request.outputURL else {
                throw ExportMeetingDocumentError.outputFileRequired
            }
            guard let files else {
                throw ExportMeetingDocumentError.outputFileRequired
            }
            let markdown = try await documents.markdown(from: content)
            let data = try await documents.pdf(fromMarkdown: markdown)
            try await files.write(data, to: outputURL)
            return .written(path: outputURL.path, bytes: data.count)
        case .srt, .vtt:
            guard let outputURL = request.outputURL, let files else {
                throw ExportMeetingDocumentError.outputFileRequired
            }
            guard let subtitleFormat = request.format.subtitleFormat else {
                preconditionFailure("subtitle branch requires a subtitle format")
            }
            let subtitles = try await documents.subtitles(
                from: content, format: subtitleFormat)
            let data = Data(subtitles.utf8)
            try await files.write(data, to: outputURL)
            return .written(path: outputURL.path, bytes: data.count)
        }
    }
}

private enum MeetingDocumentProjection {
    private struct CorrectionSnapshot {
        let content: MeetingTranscriptContent
        let effectiveCorrections: [TranscriptCorrectionEvent]
        let revision: TranscriptCorrectionRevision
    }

    static func make(
        detail: MeetingLibraryDetail,
        options: MeetingDocumentOptions
    ) throws -> MeetingDocumentContent {
        let meeting = detail.meeting
        let snapshot = try correctionSnapshot(for: detail)
        let segments = exportedSegments(
            from: snapshot.content,
            meetingID: meeting.id)
        let summaryIsCurrent = detail.summaryCorrectionSource.matches(snapshot.revision)
        let provenance = options.includeCorrectionProvenance
            ? correctionProvenance(
                content: snapshot.content,
                meeting: meeting,
                revision: snapshot.revision,
                effectiveCorrections: snapshot.effectiveCorrections)
            : nil
        return MeetingDocumentContent(
            meeting: meeting,
            speakers: detail.speakers,
            segments: segments,
            summary: summaryIsCurrent ? detail.summary : nil,
            summaryVersion: summaryIsCurrent ? detail.summaryVersion : nil,
            correctionProvenance: provenance)
    }

    private static func correctionSnapshot(
        for detail: MeetingLibraryDetail
    ) throws -> CorrectionSnapshot {
        let meeting = detail.meeting
        let currentCorrections = detail.corrections.filter {
            $0.baseTranscriptRevision == meeting.transcriptRevision
        }
        let baseMaterial: MeetingTranscriptBaseMaterial = detail.isRefinedTranscript
            ? .refined
            : .raw
        let content: MeetingTranscriptContent
        let effectiveCorrections: [TranscriptCorrectionEvent]
        let currentRevision: TranscriptCorrectionRevision

        do {
            effectiveCorrections = try TranscriptCorrectionPolicy.effectiveCorrections(
                in: detail.corrections,
                meetingID: meeting.id,
                baseTranscriptRevision: meeting.transcriptRevision)
            currentRevision = try TranscriptCorrectionRevision.current(
                meetingID: meeting.id,
                baseTranscriptRevision: meeting.transcriptRevision,
                history: detail.corrections)
            guard currentRevision == detail.correctionRevision else {
                throw ExportMeetingDocumentError.invalidCorrectionSnapshot
            }
            content = try transcriptContent(
                detail: detail,
                baseMaterial: baseMaterial,
                currentCorrections: currentCorrections)
        } catch let error as ExportMeetingDocumentError {
            throw error
        } catch {
            throw ExportMeetingDocumentError.invalidCorrectionSnapshot
        }
        return CorrectionSnapshot(
            content: content,
            effectiveCorrections: effectiveCorrections,
            revision: currentRevision)
    }

    private static func transcriptContent(
        detail: MeetingLibraryDetail,
        baseMaterial: MeetingTranscriptBaseMaterial,
        currentCorrections: [TranscriptCorrectionEvent]
    ) throws -> MeetingTranscriptContent {
        guard !currentCorrections.isEmpty else {
            return MeetingTranscriptContent.accepted(
                baseTranscriptRevision: detail.meeting.transcriptRevision,
                segments: detail.segments,
                chapterTitles: [:],
                baseMaterial: baseMaterial)
        }
        return try ComposeTranscript().execute(
            baseTranscriptRevision: detail.meeting.transcriptRevision,
            baseMaterial: baseMaterial,
            segments: detail.segments,
            corrections: currentCorrections).composed
    }

    private static func exportedSegments(
        from content: MeetingTranscriptContent,
        meetingID: MeetingID
    ) -> [TranscriptSegment] {
        content.rows.map { row in
            TranscriptSegment(
                id: row.id,
                meetingID: meetingID,
                speakerID: row.speakerID,
                channel: row.channel,
                text: row.text,
                language: row.language,
                startTime: row.startTime,
                endTime: row.endTime,
                confidence: row.confidence,
                isFinal: row.isFinal)
        }
    }

    private static func correctionProvenance(
        content: MeetingTranscriptContent,
        meeting: Meeting,
        revision: TranscriptCorrectionRevision,
        effectiveCorrections: [TranscriptCorrectionEvent]
    ) -> TranscriptCorrectionExportProvenance? {
        guard !revision.isAccepted, !effectiveCorrections.isEmpty else { return nil }
        let affectedSources = Set(effectiveCorrections.flatMap(\.targetSegmentIDs))
        let pairs: [(UUID, [UUID])] = content.rows.compactMap { row in
            guard row.sourceSegmentIDs.contains(where: affectedSources.contains) else {
                return nil
            }
            return (row.id, row.sourceSegmentIDs)
        }
        let mappings = Dictionary(uniqueKeysWithValues: pairs)
        return TranscriptCorrectionExportProvenance(
            baseTranscriptRevision: meeting.transcriptRevision,
            correctionRevision: revision,
            activeCorrectionIDs: effectiveCorrections.map(\.id),
            sourceSegmentIDsByExportedSegmentID: mappings)
    }
}

public extension ExportMeetingDocument {
    static func slug(_ title: String) -> String {
        let allowed = title.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        return String(allowed).split(separator: "-").joined(separator: "-")
    }
}

public protocol MeetingActionItemPublishing: Sendable {
    /// Resolves credentials only after the meeting and pending work have been
    /// admitted, preserving local no-op and missing-meeting behavior.
    func prepare() async throws
    func publish(
        _ item: ActionItem,
        meetingID: MeetingID,
        meetingTitle: String,
        ownerName: String?
    ) async throws -> URL
}

public extension MeetingActionItemPublishing {
    func prepare() async throws {}
}

public enum PublishMeetingActionItemsError: Error, Equatable, LocalizedError, Sendable {
    case meetingOrSummaryNotFound

    public var errorDescription: String? {
        "the meeting does not exist or has no summary"
    }
}

public enum PublishMeetingActionItemsProgress: Equatable, Sendable {
    case publishing(count: Int)
}

public typealias PublishMeetingActionItemsProgressHandler =
    @Sendable (PublishMeetingActionItemsProgress) async -> Void

public struct PublishMeetingActionItemsRequest: Sendable {
    public let meetingID: MeetingID
    public let progress: PublishMeetingActionItemsProgressHandler

    public init(
        meetingID: MeetingID,
        progress: @escaping PublishMeetingActionItemsProgressHandler = { _ in }
    ) {
        self.meetingID = meetingID
        self.progress = progress
    }
}

public struct PublishedMeetingActionItem: Equatable, Sendable {
    public let text: String
    public let url: URL

    public init(text: String, url: URL) {
        self.text = text
        self.url = url
    }
}

public enum PublishMeetingActionItemsResult: Equatable, Sendable {
    case noPendingItems
    case published([PublishedMeetingActionItem])
}

/// Publish only pending actions from one read-consistent current summary.
public struct PublishMeetingActionItems: ApplicationUseCase {
    private let library: QueryMeetingLibrary
    private let publisher: any MeetingActionItemPublishing

    public init(
        library: QueryMeetingLibrary,
        publisher: any MeetingActionItemPublishing
    ) {
        self.library = library
        self.publisher = publisher
    }

    public func execute(
        _ request: PublishMeetingActionItemsRequest
    ) async throws -> PublishMeetingActionItemsResult {
        guard let detail = try await library.detail(request.meetingID),
              let summary = detail.summary
        else {
            throw PublishMeetingActionItemsError.meetingOrSummaryNotFound
        }
        let pending = summary.actionItems.filter { !$0.isDone }
        guard !pending.isEmpty else { return .noPendingItems }

        try await publisher.prepare()
        await request.progress(.publishing(count: pending.count))
        let namesByID = Dictionary(
            uniqueKeysWithValues: detail.speakers.map {
                ($0.id, $0.displayName ?? $0.label)
            })
        var published: [PublishedMeetingActionItem] = []
        published.reserveCapacity(pending.count)
        for item in pending {
            let owner = item.ownerSpeakerID.flatMap { namesByID[$0] }
            let url = try await publisher.publish(
                item,
                meetingID: request.meetingID,
                meetingTitle: detail.meeting.title,
                ownerName: owner)
            published.append(PublishedMeetingActionItem(text: item.text, url: url))
        }
        return .published(published)
    }
}
