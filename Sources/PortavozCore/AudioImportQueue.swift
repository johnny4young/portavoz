import Foundation

/// Queue presentation never carries the selected-file bookmark or transcript.
public struct AudioImportQueueEntry: Equatable, Sendable, Identifiable {
    public let title: String
    public let job: ProcessingJob
    public var id: MeetingID { job.meetingID }

    public init(title: String, job: ProcessingJob) {
        self.title = title
        self.job = job
    }
}

public struct AudioImportQueuePage: Equatable, Sendable {
    public let entries: [AudioImportQueueEntry]
    public let total: Int
    public let unfinished: Int
    public let offset: Int
    public var hasNext: Bool { offset + entries.count < total }

    public init(entries: [AudioImportQueueEntry], total: Int, unfinished: Int, offset: Int) {
        self.entries = entries
        self.total = total
        self.unfinished = unfinished
        self.offset = offset
    }
}
