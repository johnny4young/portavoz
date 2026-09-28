import PortavozCore

/// Canonical recording captions never contain replaceable OS speech text.
/// Stable presentation identity survives each volatile range rewrite.
enum RecordingSpeechPreview {
    static func admit(
        _ segment: TranscriptSegment,
        into previews: inout [AudioChannel: TranscriptSegment]
    ) -> Bool {
        if segment.isFinal {
            if let preview = previews[segment.channel], segment.endTime > preview.startTime {
                previews.removeValue(forKey: segment.channel)
            }
            return true
        }
        previews[segment.channel] = TranscriptSegment(
            id: previews[segment.channel]?.id ?? segment.id,
            meetingID: segment.meetingID,
            speakerID: segment.speakerID,
            channel: segment.channel,
            text: segment.text,
            language: segment.language,
            startTime: segment.startTime,
            endTime: segment.endTime,
            confidence: segment.confidence,
            isFinal: false,
            liveUpdateMode: .rangeRevision)
        return false
    }
}
