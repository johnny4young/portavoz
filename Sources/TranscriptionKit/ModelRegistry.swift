import Foundation
import PortavozCore

/// What a downloadable model is for. One model never serves every task:
/// live STT wants speed, the final pass wants quality, titles want a tiny
/// LLM, summaries a bigger one.
public enum ModelTask: String, Codable, Sendable, CaseIterable {
    case liveTranscription
    case finalTranscription
    case diarization
    case summarization
    case embedding
}

/// An entry in the curated model registry. Downloads are verified against
/// `sha256` and pinned to an exact upstream `revision` — a model file is
/// code we execute, so integrity is not optional.
public struct ModelDescriptor: Codable, Sendable, Identifiable {
    public let id: String
    public let task: ModelTask
    public let displayName: String
    public let downloadURL: URL
    public let sha256: String
    public let revision: String
    public let sizeMB: Int
    public let minimumRAMGB: Int
    public let license: String

    public init(
        id: String,
        task: ModelTask,
        displayName: String,
        downloadURL: URL,
        sha256: String,
        revision: String,
        sizeMB: Int,
        minimumRAMGB: Int,
        license: String
    ) {
        self.id = id
        self.task = task
        self.displayName = displayName
        self.downloadURL = downloadURL
        self.sha256 = sha256
        self.revision = revision
        self.sizeMB = sizeMB
        self.minimumRAMGB = minimumRAMGB
        self.license = license
    }
}
