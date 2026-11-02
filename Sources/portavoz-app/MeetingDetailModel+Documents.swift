import ApplicationKit

extension MeetingDetailModel {
    func prepareDocument(
        _ format: MeetingDocumentFormat,
        options: MeetingDocumentOptions
    ) async -> Effect {
        do {
            return .documentPrepared(try await client.prepareMeetingDetailDocument(
                meetingID,
                format: format,
                options: options))
        } catch {
            return .operationFailed(UseCaseErrorMessages.describe(error))
        }
    }

    func publishGist(options: MeetingDocumentOptions) async -> Effect {
        do {
            return .gistPublished(try await client.publishMeetingDetailGist(
                meetingID,
                options: options))
        } catch {
            return .operationFailed(UseCaseErrorMessages.describe(error))
        }
    }
}
