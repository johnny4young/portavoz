import Foundation
import PortavozCore

public enum MeetingDocumentFormat: String, Equatable, Sendable {
    case markdown
    case pdf
}

public protocol MeetingDocumentRendering: Sendable {
    func markdown(from detail: MeetingLibraryDetail) async throws -> String
    func pdf(fromMarkdown markdown: String) async throws -> Data
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

    public var errorDescription: String? {
        switch self {
        case .meetingNotFound:
            "no such meeting"
        case .outputFileRequired:
            "--format pdf requires --out <path>"
        }
    }
}

public struct ExportMeetingDocumentRequest: Sendable {
    public let meetingID: MeetingID
    public let format: MeetingDocumentFormat
    public let outputURL: URL?
    public let progress: ExportMeetingDocumentProgressHandler

    public init(
        meetingID: MeetingID,
        format: MeetingDocumentFormat,
        outputURL: URL? = nil,
        progress: @escaping ExportMeetingDocumentProgressHandler = { _ in }
    ) {
        self.meetingID = meetingID
        self.format = format
        self.outputURL = outputURL
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

    public init(meetingID: MeetingID, format: MeetingDocumentFormat) {
        self.meetingID = meetingID
        self.format = format
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
        let markdown = try await documents.markdown(from: detail)
        switch request.format {
        case .markdown:
            return PreparedMeetingDocument(
                data: Data(markdown.utf8),
                filename: "\(detail.meeting.title).md")
        case .pdf:
            return PreparedMeetingDocument(
                data: try await documents.pdf(fromMarkdown: markdown),
                filename: "\(detail.meeting.title).pdf")
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
        let markdown = try await documents.markdown(from: detail)
        if let publisher {
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
            let data = try await documents.pdf(fromMarkdown: markdown)
            try await files.write(data, to: outputURL)
            return .written(path: outputURL.path, bytes: data.count)
        }
    }

    public static func slug(_ title: String) -> String {
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
