import Foundation

/// Cuts a live chunk stream into the fixed windows the diarization model reads,
/// anchoring each one to the session clock.
///
/// Live diarization attaches *after* capture has begun and reads a bounded
/// stream that drops audio under back-pressure. Counting consumed windows would
/// therefore place every turn earlier than it happened and drift further with
/// each drop, so window positions come from the timestamp the capture layer
/// stamps on each chunk instead.
///
/// Pure and synchronous on purpose: the timeline is the part that must be
/// exactly right, and it is testable here without the model.
struct DiarizationWindowCutter {
    struct Window: Equatable {
        let samples: [Float]
        /// Seconds since the recording session started.
        let start: TimeInterval
    }

    private let windowSamples: Int
    private let sampleRate: Int
    private let minimumSamples: Int
    private let tolerance: TimeInterval
    private var buffer: [Float] = []
    private var bufferStart: TimeInterval?

    init(
        windowSeconds: TimeInterval = PyannoteDiarizer.windowSeconds,
        sampleRate: Int = PyannoteDiarizer.modelSampleRate,
        // A fragment under the model's 1 s minimum speech duration carries no
        // turn; anything longer the model zero-pads.
        minimumSeconds: TimeInterval = 1,
        tolerance: TimeInterval = PyannoteDiarizer.continuityTolerance
    ) {
        windowSamples = Int(windowSeconds) * sampleRate
        self.sampleRate = sampleRate
        minimumSamples = Int(minimumSeconds * TimeInterval(sampleRate))
        self.tolerance = tolerance
    }

    /// The windows this chunk completes, in order.
    ///
    /// When a chunk does not continue where the held audio ends — the stream
    /// dropped some — the held audio is released as its own window rather than
    /// spliced onto the new chunk, so no window ever contains a jump cut.
    mutating func accept(
        _ samples: [Float],
        at timestamp: TimeInterval
    ) -> [Window] {
        var released: [Window] = []
        if let start = bufferStart {
            let expected = start
                + TimeInterval(buffer.count) / TimeInterval(sampleRate)
            if !timestamp.isFinite || abs(timestamp - expected) > tolerance {
                if let gapped = flush() { released.append(gapped) }
                reset()
            }
        }
        guard timestamp.isFinite else { return released }
        if bufferStart == nil { bufferStart = timestamp }
        buffer.append(contentsOf: samples)
        while buffer.count >= windowSamples, let start = bufferStart {
            released.append(Window(
                samples: Array(buffer.prefix(windowSamples)),
                start: start))
            buffer.removeFirst(windowSamples)
            bufferStart = start
                + TimeInterval(windowSamples) / TimeInterval(sampleRate)
        }
        return released
    }

    /// The final partial window, if it is long enough to carry a turn. Consumes
    /// it, so calling twice does not emit the same audio twice.
    mutating func flush() -> Window? {
        defer { reset() }
        guard buffer.count >= minimumSamples, let start = bufferStart else {
            return nil
        }
        return Window(samples: buffer, start: start)
    }

    private mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
        bufferStart = nil
    }
}
