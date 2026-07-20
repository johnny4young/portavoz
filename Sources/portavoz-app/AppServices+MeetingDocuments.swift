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
        format: MeetingDocumentFormat
    ) async throws -> PreparedMeetingDocument {
        try await PrepareMeetingDocument(
            library: .local(store: store),
            documents: AppMeetingDocumentRenderer())
            .execute(.init(meetingID: meetingID, format: format))
    }

    /// Publishes only after the application workflow has admitted and rendered
    /// one current local meeting snapshot. Credential resolution stays lazy.
    func publishMeetingDetailGist(_ meetingID: MeetingID) async throws -> URL {
        let useCase = ExportMeetingDocument(
            library: .local(store: store),
            documents: AppMeetingDocumentRenderer(),
            publisher: AppGistDocumentPublisher(
                secrets: secrets,
                gateway: dataEgressGateway))
        guard case .published(let url) = try await useCase.execute(
            ExportMeetingDocumentRequest(
                meetingID: meetingID,
                format: .markdown))
        else { throw AppMeetingDocumentError.unexpectedResult }
        return url
    }
}

private struct AppMeetingDocumentRenderer: MeetingDocumentRendering {
    func markdown(from detail: MeetingLibraryDetail) async throws -> String {
        MeetingExporter.markdown(
            meeting: detail.meeting,
            speakers: detail.speakers,
            segments: detail.segments,
            summary: detail.summary,
            summaryVersion: detail.summaryVersion)
    }

    func pdf(fromMarkdown markdown: String) async throws -> Data {
        try await Task.detached(priority: .utility) {
            try MeetingExporter.pdf(fromMarkdown: markdown)
        }.value
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
