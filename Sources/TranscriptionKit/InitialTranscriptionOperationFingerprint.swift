import ModelStoreKit
import PortavozCore

/// Exact, content-free identity for recovering a complete first-pass
/// transcript from finalized capture audio. Recovery deliberately uses
/// Parakeet's automatic multilingual mode without vocabulary: it is a stable
/// safety net when the live engine was unavailable, not a replacement for the
/// user's reviewable Whisper Refine pass.
public enum InitialTranscriptionOperationFingerprint {
    private static let version = "initial-transcription-v1"

    public static let providerID = "fluid-audio/coreml"

    public static func request(
        meetingID: MeetingID,
        transcriptRevision: Int,
        assets: [AudioAsset]
    ) -> ProcessingJobRequest? {
        guard let fingerprint = compute(
            meetingID: meetingID,
            transcriptRevision: transcriptRevision,
            assets: assets)
        else { return nil }
        return ProcessingJobRequest(
            kind: .transcription,
            inputFingerprint: fingerprint,
            priority: 30,
            maxAttempts: 3)
    }

    public static func compute(
        meetingID: MeetingID,
        transcriptRevision: Int,
        assets: [AudioAsset]
    ) -> String? {
        guard transcriptRevision >= 0 else { return nil }
        let captures = currentCaptures(in: assets)
        guard !captures.isEmpty,
              captures.contains(where: isTranscribable),
              let audio = audioIdentity(captures)
        else { return nil }

        let model = ModelCatalog.parakeetTdtV3
        return OperationFingerprint.make(
            version: version,
            components: [
                meetingID.rawValue.uuidString,
                String(transcriptRevision),
                providerID,
                model.id,
                model.revision,
                "language:automatic",
                "vocabulary:none"
            ] + audio)
    }

    private static func currentCaptures(in assets: [AudioAsset]) -> [AudioAsset] {
        Dictionary(grouping: assets.filter {
            $0.role == .capture && $0.supersededAt == nil && $0.deletedAt == nil
        }, by: \.channel)
        .compactMap { _, candidates in
            candidates.max { $0.updatedAt < $1.updatedAt }
        }
        .sorted { $0.channel.rawValue < $1.channel.rawValue }
    }

    private static func isTranscribable(_ asset: AudioAsset) -> Bool {
        guard [.healthy, .clipped].contains(asset.healthStatus),
              let duration = asset.durationSeconds,
              duration > 1,
              asset.sha256?.isEmpty == false,
              asset.byteCount.map({ $0 > 0 }) == true
        else { return false }
        return true
    }

    private static func audioIdentity(_ assets: [AudioAsset]) -> [String]? {
        var components: [String] = [String(assets.count)]
        for asset in assets {
            guard asset.healthStatus != .pending else { return nil }
            switch asset.healthStatus {
            case .healthy, .silent, .clipped:
                guard let sha256 = asset.sha256,
                      !sha256.isEmpty,
                      let duration = asset.durationSeconds,
                      duration.isFinite,
                      duration >= 0,
                      let byteCount = asset.byteCount,
                      byteCount >= 0
                else { return nil }
                components += [
                    asset.channel.rawValue,
                    asset.id.rawValue.uuidString,
                    asset.healthStatus.rawValue,
                    sha256,
                    String(duration.bitPattern, radix: 16),
                    String(byteCount)
                ]
            case .corrupt, .missing:
                components += [
                    asset.channel.rawValue,
                    asset.id.rawValue.uuidString,
                    asset.healthStatus.rawValue
                ]
            case .pending:
                return nil
            }
        }
        return components
    }
}
