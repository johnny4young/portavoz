import Foundation

/// Content-free capture authority, independent of processing and media health.
public enum CaptureFailure: String, Codable, Sendable {
    case overloaded
    case invalidFormat
    case sourceFailed
    case writerFailed
    case cancelled
}

public struct CaptureChannelReport: Codable, Equatable, Sendable {
    public let channel: AudioChannel
    /// Counts include timeline padding. Nil means the producer cannot prove it.
    public let acceptedFrames: Int64?
    public let paddingFrames: Int64?
    /// Frames rejected at admission, not an estimate of later unrecorded time.
    public let rejectedFrames: Int64?
    /// Successful native appends only; nil after an ambiguous native write error.
    public let writtenFrames: Int64?
    public let failure: CaptureFailure?
    public let publicationFailed: Bool

    public init(
        channel: AudioChannel, acceptedFrames: Int64? = nil,
        paddingFrames: Int64? = nil, rejectedFrames: Int64? = nil,
        writtenFrames: Int64? = nil, failure: CaptureFailure? = nil,
        publicationFailed: Bool = false
    ) {
        self.channel = channel
        self.acceptedFrames = acceptedFrames
        self.paddingFrames = paddingFrames
        self.rejectedFrames = rejectedFrames
        self.writtenFrames = writtenFrames
        self.failure = failure
        self.publicationFailed = publicationFailed
    }

    public var requiresAttention: Bool {
        failure != nil || publicationFailed || (paddingFrames ?? 0) > 0
            || (rejectedFrames ?? 0) > 0
            || (acceptedFrames != nil && writtenFrames != acceptedFrames)
    }

    public var hasValidCounts: Bool {
        let counts = [acceptedFrames, paddingFrames, rejectedFrames, writtenFrames].compactMap { $0 }
        guard counts.allSatisfy({ $0 >= 0 }) else { return false }
        if let acceptedFrames {
            if let paddingFrames, paddingFrames > acceptedFrames { return false }
            if let writtenFrames, writtenFrames > acceptedFrames { return false }
        }
        return true
    }
}

public struct CaptureReport: Codable, Equatable, Sendable {
    public let channels: [CaptureChannelReport]

    public init(channels: [CaptureChannelReport]) throws {
        guard !channels.isEmpty, channels.count <= AudioChannel.allCases.count,
              Set(channels.map(\.channel)).count == channels.count,
              channels.allSatisfy(\.hasValidCounts)
        else { throw InvalidReport.invalidChannels }
        self.channels = channels.sorted { $0.channel.rawValue < $1.channel.rawValue }
    }

    public static func unverified(channels: Set<AudioChannel>) -> CaptureReport? {
        guard !channels.isEmpty else { return nil }
        return CaptureReport(validatedChannels: channels.sorted { $0.rawValue < $1.rawValue }.map {
            CaptureChannelReport(channel: $0, failure: .sourceFailed)
        })
    }

    private init(validatedChannels: [CaptureChannelReport]) { channels = validatedChannels }

    public var requiresAttention: Bool { channels.contains(where: \.requiresAttention) }

    private enum CodingKeys: String, CodingKey { case channels }
    private enum InvalidReport: Error { case invalidChannels }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(channels: values.decode([CaptureChannelReport].self, forKey: .channels))
    }
}
