/// Exact local facts shown in Settings. Nil means that one source was
/// unavailable; zero remains a verified zero and is never used as a fallback.
public struct LocalDataLedgerSnapshot: Equatable, Sendable {
    public let audioBytes: Int64?
    public let meetingCount: Int?
    public let voiceCount: Int?

    public init(
        audioBytes: Int64?,
        meetingCount: Int?,
        voiceCount: Int?
    ) {
        self.audioBytes = audioBytes
        self.meetingCount = meetingCount
        self.voiceCount = voiceCount
    }
}

public protocol LocalMeetingCounting: Sendable {
    func liveMeetingCount() async throws -> Int
}

public protocol LocalAudioUsageMeasuring: Sendable {
    func localAudioBytes() async throws -> Int64
}

public protocol LocalVoiceCounting: Sendable {
    func localVoiceCount() async throws -> Int
}

/// Loads independent local-only ledger metrics concurrently. One unavailable
/// source degrades only its tile; cancellation remains cancellation.
public struct LoadLocalDataLedger: ApplicationUseCase {
    private let meetings: any LocalMeetingCounting
    private let audio: any LocalAudioUsageMeasuring
    private let voices: any LocalVoiceCounting

    public init(
        meetings: any LocalMeetingCounting,
        audio: any LocalAudioUsageMeasuring,
        voices: any LocalVoiceCounting
    ) {
        self.meetings = meetings
        self.audio = audio
        self.voices = voices
    }

    public func execute(_ request: Void) async throws -> LocalDataLedgerSnapshot {
        async let meetingCount = optionalMeetingCount()
        async let audioBytes = optionalAudioBytes()
        async let voiceCount = optionalVoiceCount()
        return try await LocalDataLedgerSnapshot(
            audioBytes: audioBytes,
            meetingCount: meetingCount,
            voiceCount: voiceCount)
    }

    private func optionalMeetingCount() async throws -> Int? {
        do {
            return try await meetings.liveMeetingCount()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }

    private func optionalAudioBytes() async throws -> Int64? {
        do {
            return try await audio.localAudioBytes()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }

    private func optionalVoiceCount() async throws -> Int? {
        do {
            return try await voices.localVoiceCount()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }
}
