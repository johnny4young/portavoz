import ModelStoreKit
import PortavozCore

/// Exact input identity for the post-capture attribution operation. Pending or
/// incomplete system-audio evidence cannot produce a runnable fingerprint.
public enum DiarizationOperationFingerprint {
    private static let version = "diarization-v1"

    /// Initial durable work created after the captured snapshot commits.
    /// Keeping the execution policy beside the exact fingerprint prevents
    /// producers from inventing a second idempotency or retry contract.
    public static func request(
        meetingID: MeetingID,
        transcriptRevision: Int,
        segments: [TranscriptSegment],
        systemAsset: AudioAsset?,
        voiceprint: Voiceprint?
    ) -> ProcessingJobRequest? {
        guard let fingerprint = compute(
            meetingID: meetingID,
            transcriptRevision: transcriptRevision,
            segments: segments,
            systemAsset: systemAsset,
            voiceprint: voiceprint)
        else { return nil }
        return ProcessingJobRequest(
            kind: .diarization,
            inputFingerprint: fingerprint,
            priority: 20,
            maxAttempts: 3)
    }

    public static func compute(
        meetingID: MeetingID,
        transcriptRevision: Int,
        segments: [TranscriptSegment],
        systemAsset: AudioAsset?,
        voiceprint: Voiceprint?
    ) -> String? {
        guard transcriptRevision >= 0,
            let audioIdentity = audioIdentity(systemAsset)
        else { return nil }
        let model = ModelCatalog.speakerDiarization
        let components = [
            meetingID.rawValue.uuidString,
            String(transcriptRevision),
            model.id,
            model.revision,
            floatIdentity(PyannoteDiarizer.defaultClusteringThreshold),
            audioIdentity,
            voiceIdentity(voiceprint)
        ] + segments.sorted(by: segmentOrder).map(segmentIdentity)
        return OperationFingerprint.make(version: version, components: components)
    }

    private static func audioIdentity(_ asset: AudioAsset?) -> String? {
        guard let asset else { return "system:none" }
        guard asset.channel == .system, asset.role == .capture else { return nil }
        switch asset.healthStatus {
        case .pending:
            return nil
        case .healthy, .silent, .clipped:
            guard let sha256 = asset.sha256, let duration = asset.durationSeconds else {
                return nil
            }
            return [
                "system", asset.id.rawValue.uuidString, asset.healthStatus.rawValue,
                sha256, doubleIdentity(duration)
            ].joined(separator: ":")
        case .corrupt, .missing:
            return [
                "system", asset.id.rawValue.uuidString, asset.healthStatus.rawValue
            ].joined(separator: ":")
        }
    }

    private static func voiceIdentity(_ voiceprint: Voiceprint?) -> String {
        guard let voiceprint else { return "voice:none" }
        let components = [
            doubleIdentity(voiceprint.createdAt.timeIntervalSince1970)
        ] + voiceprint.embedding.map(floatIdentity)
        return OperationFingerprint.make(version: "voiceprint-v1", components: components)
    }

    private static func segmentIdentity(_ segment: TranscriptSegment) -> String {
        OperationFingerprint.make(
            version: "transcript-segment-v1",
            components: [
                segment.id.uuidString,
                segment.channel.rawValue,
                segment.text,
                segment.language ?? "",
                doubleIdentity(segment.startTime),
                doubleIdentity(segment.endTime),
                segment.confidence.map(doubleIdentity) ?? "",
                segment.isFinal ? "final" : "partial"
            ])
    }

    private static func segmentOrder(
        _ lhs: TranscriptSegment,
        _ rhs: TranscriptSegment
    ) -> Bool {
        if lhs.startTime != rhs.startTime { return lhs.startTime < rhs.startTime }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func doubleIdentity(_ value: Double) -> String {
        String(value.bitPattern, radix: 16)
    }

    private static func floatIdentity(_ value: Float) -> String {
        String(value.bitPattern, radix: 16)
    }
}
