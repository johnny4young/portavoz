import Foundation

/// Extensible semantic role for an audio file. The schema stores an open
/// value so future derived assets do not require destructive migrations.
public struct AudioAssetRole: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Original channel file produced by a recording source.
    public static let capture = AudioAssetRole(rawValue: "capture")
}

public enum AudioAssetHealthStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case healthy
    case silent
    case clipped
    case corrupt
    case missing
}

/// First-class durable audio metadata. Capture reserves a pending row before
/// a source starts; later workflow slices inspect and finalize its metadata.
public struct AudioAsset: Codable, Sendable, Identifiable {
    public var id: AudioAssetID
    public var meetingID: MeetingID
    public var channel: AudioChannel
    public var role: AudioAssetRole
    public var relativePath: String
    public var container: String?
    public var codec: String?
    public var sampleRate: Double?
    public var channelCount: Int?
    public var durationSeconds: TimeInterval?
    public var byteCount: Int64?
    public var sha256: String?
    public var healthStatus: AudioAssetHealthStatus
    public var peakDBFS: Double?
    public var rmsDBFS: Double?
    public var sourceAssetID: AudioAssetID?
    public var createdAt: Date
    public var updatedAt: Date
    public var supersededAt: Date?
    public var deletedAt: Date?

    public init(
        id: AudioAssetID = AudioAssetID(),
        meetingID: MeetingID,
        channel: AudioChannel,
        role: AudioAssetRole,
        relativePath: String,
        container: String? = nil,
        codec: String? = nil,
        sampleRate: Double? = nil,
        channelCount: Int? = nil,
        durationSeconds: TimeInterval? = nil,
        byteCount: Int64? = nil,
        sha256: String? = nil,
        healthStatus: AudioAssetHealthStatus = .pending,
        peakDBFS: Double? = nil,
        rmsDBFS: Double? = nil,
        sourceAssetID: AudioAssetID? = nil,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        supersededAt: Date? = nil,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.meetingID = meetingID
        self.channel = channel
        self.role = role
        self.relativePath = relativePath
        self.container = container
        self.codec = codec
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.durationSeconds = durationSeconds
        self.byteCount = byteCount
        self.sha256 = sha256
        self.healthStatus = healthStatus
        self.peakDBFS = peakDBFS
        self.rmsDBFS = rmsDBFS
        self.sourceAssetID = sourceAssetID
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.supersededAt = supersededAt
        self.deletedAt = deletedAt
    }

    public static func pendingCapture(
        meetingID: MeetingID,
        channel: AudioChannel,
        relativePath: String,
        at timestamp: Date = Date()
    ) -> AudioAsset {
        AudioAsset(
            meetingID: meetingID,
            channel: channel,
            role: .capture,
            relativePath: relativePath,
            createdAt: timestamp)
    }
}
