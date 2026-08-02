import ApplicationKit
import Foundation
import IntegrationsKit
import PortavozCore

enum AppMeetingDocumentError: Error, LocalizedError {
    case missingGitHubToken
    case unexpectedResult

    var errorDescription: String? {
        switch self {
        case .missingGitHubToken:
            "Configure your GitHub token in Settings (⌘,) first."
        case .unexpectedResult:
            "The meeting document could not be prepared."
        }
    }
}

extension AppServices {
    /// Builds a coherent in-memory document while SwiftUI retains only the
    /// native save panel and its presentation state.
    func prepareMeetingDetailDocument(
        _ meetingID: MeetingID,
        format: MeetingDocumentFormat,
        options: MeetingDocumentOptions
    ) async throws -> PreparedMeetingDocument {
        try await PrepareMeetingDocument(
            library: .local(store: store),
            documents: AppMeetingDocumentRenderer())
            .execute(.init(
                meetingID: meetingID,
                format: format,
                options: options))
    }

    /// Publishes only after the application workflow has admitted and rendered
    /// one current local meeting snapshot. Credential resolution stays lazy.
    func publishMeetingDetailGist(
        _ meetingID: MeetingID,
        options: MeetingDocumentOptions
    ) async throws -> URL {
        let useCase = ExportMeetingDocument(
            library: .local(store: store),
            documents: AppMeetingDocumentRenderer(),
            publisher: AppGistDocumentPublisher(
                secrets: secrets,
                gateway: dataEgressGateway))
        guard case .published(let url) = try await useCase.execute(
            ExportMeetingDocumentRequest(
                meetingID: meetingID,
                format: .markdown,
                options: options))
        else { throw AppMeetingDocumentError.unexpectedResult }
        return url
    }
}

private struct AppMeetingDocumentRenderer: MeetingDocumentRendering {
    func markdown(from content: MeetingDocumentContent) async throws -> String {
        MeetingExporter.markdown(
            meeting: content.meeting,
            speakers: content.speakers,
            segments: content.segments,
            summary: content.summary,
            summaryVersion: content.summaryVersion,
            correctionProvenance: content.correctionProvenance)
    }

    func pdf(fromMarkdown markdown: String) async throws -> Data {
        try await Task.detached(priority: .utility) {
            try MeetingExporter.pdf(fromMarkdown: markdown)
        }.value
    }

    func subtitles(
        from content: MeetingDocumentContent,
        format: MeetingSubtitleFormat
    ) async throws -> String {
        let exportFormat: SubtitleExport.Format = switch format {
        case .srt: .srt
        case .vtt: .vtt
        }
        return SubtitleExport.render(
            exportFormat,
            segments: content.segments,
            speakers: content.speakers,
            correctionProvenance: content.correctionProvenance)
    }
}

private actor AppGistDocumentPublisher: MeetingDocumentPublishing {
    let secrets: ManageSecrets
    let gateway: any DataEgressGateway
    private var publisher: GistPublisher?

    init(secrets: ManageSecrets, gateway: any DataEgressGateway) {
        self.secrets = secrets
        self.gateway = gateway
    }

    func prepare() async throws {
        guard publisher == nil else { return }
        guard let token = try await secrets.value(for: .gitHubToken), !token.isEmpty else {
            throw AppMeetingDocumentError.missingGitHubToken
        }
        publisher = GistPublisher(token: token, gateway: gateway)
    }

    func publish(
        meetingID: MeetingID,
        markdown: String,
        filename: String,
        description: String
    ) async throws -> URL {
        guard let publisher else { throw AppMeetingDocumentError.unexpectedResult }
        return try await publisher.publish(
            meetingID: meetingID,
            markdown: markdown,
            filename: filename,
            description: description,
            isPublic: false)
    }
}
