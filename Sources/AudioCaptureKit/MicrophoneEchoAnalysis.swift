import Accelerate
import AVFAudio
import Foundation
import PortavozCore

/// Offline loudspeaker-echo measurement for a recorded meeting. It reads both
/// channel files back from disk and never touches the live call graph (D125).
///
/// The system channel is exactly what the speakers played. Laptop speakers
/// run level-dependent processing that defeats a linear canceller, so the
/// echo is modelled per frequency band in magnitude only: a delayed, scaled
/// copy of the system spectrum. Microphone energy beyond that prediction is
/// the person at the microphone.
public enum MicrophoneEchoAnalysis {
    static let sampleRate: Double = 16_000
    static let frameLength = 512
    static let hopLength = 256
    /// Echo delays up to ~640 ms cover built-in, wired and HDMI speakers.
    static let maximumDelayFrames = 40
    /// Below this envelope correlation the microphone did not hear the
    /// speakers (headphones, muted speakers, or no remote speech).
    static let minimumCoupling = 0.5
    /// About ten seconds of remote speech before trusting any estimate.
    static let minimumActiveFrames = 600

    /// Returns nil when the microphone carries no measurable speaker echo.
    public static func profile(microphone: URL, system: URL) throws -> MicrophoneEchoProfile? {
        let envelopes = try BandFrameStream.envelopes(microphone: microphone, system: system)
        guard let delay = envelopes.echoDelay() else { return nil }

        var model = BandEchoModel(
            delayFrames: delay, microphoneNoise: envelopes.microphoneNoiseFloor())
        try BandFrameStream.forEachFrame(microphone: microphone, system: system) { mic, system in
            model.learn(microphone: mic, system: system)
        }
        model.restartHistory()
        var microphoneEnergy: [Float] = []
        var nearEndEnergy: [Float] = []
        microphoneEnergy.reserveCapacity(envelopes.frameCount)
        nearEndEnergy.reserveCapacity(envelopes.frameCount)
        try BandFrameStream.forEachFrame(microphone: microphone, system: system) { mic, system in
            let energy = model.classify(microphone: mic, system: system)
            microphoneEnergy.append(energy.microphone)
            nearEndEnergy.append(energy.nearEnd)
        }
        return MicrophoneEchoProfile(
            frameDuration: Double(hopLength) / sampleRate,
            microphoneEnergy: microphoneEnergy,
            nearEndEnergy: nearEndEnergy)
    }
}

/// Per-band echo gains tracked as a high quantile of microphone/system
/// ratios while the system channel is loud, plus the near-end decision.
struct BandEchoModel {
    /// Quantile of the echo ratio the gain tracks. High so ordinary echo
    /// level swings stay under the prediction.
    static let quantile: Float = 0.8
    static let learningRate: Float = 0.05
    /// Microphone energy must exceed the predicted echo by 6 dB to count.
    static let nearEndMargin: Float = 4
    /// The echo tail spans one frame early to six frames (~100 ms) late.
    static let tailFrames = -1...6

    let delayFrames: Int
    let microphoneNoise: [Float]
    private var logGains: [Float]
    private var history: [[Float]] = []

    init(delayFrames: Int, microphoneNoise: [Float]) {
        self.delayFrames = delayFrames
        self.microphoneNoise = microphoneNoise
        logGains = Array(repeating: -1, count: microphoneNoise.count)
    }

    mutating func restartHistory() {
        history.removeAll(keepingCapacity: true)
    }

    mutating func learn(microphone: [Float], system: [Float]) {
        let predicted = push(system)
        for band in microphone.indices
        where predicted[band] > 30 * microphoneNoise[band]
            && microphone[band] > 2 * microphoneNoise[band] {
            let ratio = log10(microphone[band] / predicted[band])
            logGains[band] += ratio > logGains[band]
                ? Self.learningRate * Self.quantile
                : -Self.learningRate * (1 - Self.quantile)
        }
    }

    mutating func classify(
        microphone: [Float],
        system: [Float]
    ) -> (microphone: Float, nearEnd: Float) {
        learn(microphone: microphone, system: system)
        let predicted = predictedSystem()
        var total: Float = 0
        var nearEnd: Float = 0
        for band in microphone.indices {
            let echo = pow(10, logGains[band]) * predicted[band]
            total += microphone[band]
            nearEnd += max(
                0, microphone[band] - Self.nearEndMargin * echo - 2 * microphoneNoise[band])
        }
        return (total, nearEnd)
    }

    /// Appends the newest system frame and returns the predicted echo bands.
    private mutating func push(_ system: [Float]) -> [Float] {
        history.append(system)
        let needed = delayFrames + Self.tailFrames.upperBound + 1
        if history.count > needed { history.removeFirst(history.count - needed) }
        return predictedSystem()
    }

    private func predictedSystem() -> [Float] {
        var predicted = Array(repeating: Float(0), count: microphoneNoise.count)
        for lag in Self.tailFrames {
            let index = history.count - 1 - (delayFrames + lag)
            guard history.indices.contains(index) else { continue }
            for band in predicted.indices {
                predicted[band] = max(predicted[band], history[index][band])
            }
        }
        return predicted
    }
}

/// Whole-file statistics from the first pass.
struct EchoEnvelopes {
    var microphone: [Float] = []
    var system: [Float] = []
    var microphoneBandHistograms: [[Int]] = []

    var frameCount: Int { microphone.count }

    /// Frames of delay maximizing the log-envelope correlation, or nil when
    /// the channels are not coupled.
    func echoDelay() -> Int? {
        let microphoneLog = microphone.map { log10($0 + 1e-6) }
        let systemLog = system.map { log10($0 + 1e-6) }
        // Only frames where the speakers played something above -60 dBFS.
        let active = systemLog.indices.filter { systemLog[$0] > -3 }
        guard active.count >= MicrophoneEchoAnalysis.minimumActiveFrames else { return nil }

        var best: (correlation: Double, delay: Int)?
        for delay in 0...MicrophoneEchoAnalysis.maximumDelayFrames {
            var pairs: [(Double, Double)] = []
            pairs.reserveCapacity(active.count)
            for frame in active where frame + delay < microphoneLog.count {
                pairs.append((Double(microphoneLog[frame + delay]), Double(systemLog[frame])))
            }
            guard let correlation = Self.pearson(pairs) else { continue }
            if correlation > best?.correlation ?? -.infinity { best = (correlation, delay) }
        }
        guard let best, best.correlation >= MicrophoneEchoAnalysis.minimumCoupling else {
            return nil
        }
        return best.delay
    }

    /// Tenth-percentile microphone energy per band.
    func microphoneNoiseFloor() -> [Float] {
        microphoneBandHistograms.map { histogram in
            let target = max(1, histogram.reduce(0, +) / 10)
            var seen = 0
            for (bin, count) in histogram.enumerated() {
                seen += count
                if seen >= target { return BandFrameStream.energy(forHistogramBin: bin) }
            }
            return 0
        }
    }

    private static func pearson(_ pairs: [(Double, Double)]) -> Double? {
        guard pairs.count > 1 else { return nil }
        let count = Double(pairs.count)
        let meanX = pairs.reduce(0) { $0 + $1.0 } / count
        let meanY = pairs.reduce(0) { $0 + $1.1 } / count
        var covariance = 0.0
        var varianceX = 0.0
        var varianceY = 0.0
        for (x, y) in pairs {
            covariance += (x - meanX) * (y - meanY)
            varianceX += (x - meanX) * (x - meanX)
            varianceY += (y - meanY) * (y - meanY)
        }
        guard varianceX > 0, varianceY > 0 else { return nil }
        return covariance / (varianceX * varianceY).squareRoot()
    }
}

/// Streams both channels as aligned per-band energy frames at 16 kHz.
enum BandFrameStream {
    /// Histogram bins are 1 dB wide from -160 dB to +40 dB band energy.
    static let histogramFloorDB: Float = -160
    static let histogramBins = 200

    static func energy(forHistogramBin bin: Int) -> Float {
        pow(10, (histogramFloorDB + Float(bin)) / 10)
    }

    static func envelopes(microphone: URL, system: URL) throws -> EchoEnvelopes {
        var envelopes = EchoEnvelopes()
        try forEachFrame(microphone: microphone, system: system) { mic, system in
            if envelopes.microphoneBandHistograms.isEmpty {
                envelopes.microphoneBandHistograms = Array(
                    repeating: Array(repeating: 0, count: histogramBins), count: mic.count)
            }
            envelopes.microphone.append(mic.reduce(0, +))
            envelopes.system.append(system.reduce(0, +))
            for band in mic.indices {
                let decibels = 10 * log10(max(mic[band], 1e-30))
                let bin = Int(decibels - histogramFloorDB)
                envelopes.microphoneBandHistograms[band][min(max(bin, 0), histogramBins - 1)] += 1
            }
        }
        return envelopes
    }

    static func forEachFrame(
        microphone: URL,
        system: URL,
        _ body: (_ microphone: [Float], _ system: [Float]) throws -> Void
    ) throws {
        let frameLength = MicrophoneEchoAnalysis.frameLength
        let hopLength = MicrophoneEchoAnalysis.hopLength
        let rate = MicrophoneEchoAnalysis.sampleRate
        let microphoneReader = try MonoResamplingReader(url: microphone, sampleRate: rate)
        let systemReader = try MonoResamplingReader(url: system, sampleRate: rate)
        guard let bands = BandSpectrum(frameLength: frameLength, sampleRate: rate) else {
            throw MonoResamplingReaderError.unsupportedFormat
        }
        var nearEnd: [Float] = []
        var farEnd: [Float] = []
        var nearEndDone = false
        var farEndDone = false
        while true {
            try Task.checkCancellation()
            if nearEnd.count < frameLength * 8, !nearEndDone {
                let chunk = try microphoneReader.read()
                nearEndDone = chunk.isEmpty
                nearEnd += chunk
            }
            if farEnd.count < frameLength * 8, !farEndDone {
                let chunk = try systemReader.read()
                farEndDone = chunk.isEmpty
                farEnd += chunk
            }
            let available = min(nearEnd.count, farEnd.count)
            guard available >= frameLength else {
                if nearEndDone || farEndDone { return }
                continue
            }
            var start = 0
            while start + frameLength <= available {
                try body(
                    bands.energies(nearEnd[start..<start + frameLength]),
                    bands.energies(farEnd[start..<start + frameLength]))
                start += hopLength
            }
            nearEnd.removeFirst(start)
            farEnd.removeFirst(start)
        }
    }
}

/// Hann-windowed band energies on log-spaced bands from 150 Hz to 7 kHz.
final class BandSpectrum {
    let bands: [Range<Int>]
    private let transform: vDSP.DiscreteFourierTransform<Float>
    private let window: [Float]
    private var inputReal: [Float]
    private var inputImaginary: [Float]
    private var outputReal: [Float]
    private var outputImaginary: [Float]

    init?(frameLength: Int, sampleRate: Double, bandCount: Int = 20) {
        guard let transform = try? vDSP.DiscreteFourierTransform(
            count: frameLength, direction: .forward, transformType: .complexComplex,
            ofType: Float.self)
        else { return nil }
        self.transform = transform
        window = vDSP.window(
            ofType: Float.self, usingSequence: .hanningDenormalized, count: frameLength,
            isHalfWindow: false)
        inputReal = Array(repeating: 0, count: frameLength)
        inputImaginary = inputReal
        outputReal = inputReal
        outputImaginary = inputReal

        let binWidth = sampleRate / Double(frameLength)
        let low = log(150.0)
        let high = log(7_000.0)
        let edges = (0...bandCount).map { index in
            Int((exp(low + (high - low) * Double(index) / Double(bandCount)) / binWidth)
                .rounded())
        }
        bands = (0..<bandCount).compactMap { index in
            edges[index + 1] > edges[index] ? edges[index]..<edges[index + 1] : nil
        }
    }

    func energies(_ samples: ArraySlice<Float>) -> [Float] {
        guard samples.contains(where: { $0 != 0 }) else {
            return Array(repeating: 0, count: bands.count)
        }
        vDSP.multiply(samples, window, result: &inputReal)
        inputImaginary.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
        transform.transform(
            inputReal: inputReal, inputImaginary: inputImaginary,
            outputReal: &outputReal, outputImaginary: &outputImaginary)
        return bands.map { range in
            var energy: Float = 0
            for bin in range {
                energy += outputReal[bin] * outputReal[bin]
                    + outputImaginary[bin] * outputImaginary[bin]
            }
            return energy
        }
    }
}

/// Streams any readable audio file as mono Float samples at one rate.
/// `@unchecked Sendable`: `convert(to:)` runs its input block synchronously on
/// the calling thread, and one instance belongs to one offline pass.
final class MonoResamplingReader: @unchecked Sendable {
    private let file: AVAudioFile
    private let converter: AVAudioConverter
    private let input: AVAudioPCMBuffer
    private let output: AVAudioPCMBuffer
    private var reachedEnd = false
    private var readError: Error?

    init(url: URL, sampleRate: Double, chunkFrames: AVAudioFrameCount = 48_000) throws {
        file = try AVAudioFile(forReading: url)
        guard let target = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1,
                interleaved: false),
            let converter = AVAudioConverter(from: file.processingFormat, to: target),
            let input = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat, frameCapacity: chunkFrames),
            let output = AVAudioPCMBuffer(
                pcmFormat: target,
                frameCapacity: AVAudioFrameCount(
                    (Double(chunkFrames) * sampleRate / file.processingFormat.sampleRate)
                        .rounded(.up)) + 1024)
        else { throw MonoResamplingReaderError.unsupportedFormat }
        converter.downmix = true
        self.converter = converter
        self.input = input
        self.output = output
    }

    /// Next chunk of samples; empty once the file is exhausted.
    func read() throws -> [Float] {
        guard !reachedEnd else { return [] }
        output.frameLength = 0
        var conversionError: NSError?
        readError = nil
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            guard self.file.framePosition < self.file.length else {
                inputStatus.pointee = .endOfStream
                return nil
            }
            do {
                self.input.frameLength = 0
                try self.file.read(into: self.input)
            } catch {
                self.readError = error
                inputStatus.pointee = .endOfStream
                return nil
            }
            guard self.input.frameLength > 0 else {
                inputStatus.pointee = .endOfStream
                return nil
            }
            inputStatus.pointee = .haveData
            return self.input
        }
        if let readError { throw readError }
        if let conversionError { throw conversionError }
        if status == .endOfStream || status == .error { reachedEnd = true }
        guard let channel = output.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}

enum MonoResamplingReaderError: Error {
    case unsupportedFormat
}
