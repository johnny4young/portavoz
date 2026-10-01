import Foundation

/// Developer-requested, content-free observation of the controller, not a claim
/// about microphone hardware, ASR quality or text verified in another process.
struct DictationSessionMeasurement: Codable, Equatable, Sendable {
    enum Point: String, Codable, CaseIterable, Sendable {
        case runtimeReady
        case microphoneReady
        case firstBufferHandled
        case firstCaptionHandled
        case stopRequested
        case inputEnded
        case transcriptionEnded
        case textPrepared
        case deliveryStarted
        case deliveryReturned
    }

    enum Outcome: String, Codable, Sendable {
        case permissionDenied
        case cancelled
        case pipelineFailed
        case empty
        // TextInserter's legacy `.inserted` reports event dispatch, not readback.
        case dispatchReported
        case deliveryRejected
    }

    let schemaVersion: Int
    let elapsedSeconds: [String: Double]
    let terminalSeconds: Double
    let outcome: Outcome
    let verifiedDeliveryMeasured: Bool
}

/// One bounded accumulator per observed session. Retired tasks may retain it,
/// but cannot amend or emit a second receipt after cancellation/restart.
@MainActor
final class DictationSessionMeasurementRecorder {
    typealias Clock = () -> ContinuousClock.Instant
    typealias Sink = (DictationSessionMeasurement) -> Void

    private let now: Clock
    private var sink: Sink?
    private let started: ContinuousClock.Instant
    private var points: [String: Double] = [:]

    init(now: @escaping Clock, sink: @escaping Sink) {
        self.now = now
        self.sink = sink
        started = now()
    }

    func record(_ point: DictationSessionMeasurement.Point) {
        guard sink != nil, points[point.rawValue] == nil else { return }
        points[point.rawValue] = elapsed()
    }

    func finish(_ outcome: DictationSessionMeasurement.Outcome) {
        guard let sink else { return }
        self.sink = nil
        sink(DictationSessionMeasurement(
            schemaVersion: 1, elapsedSeconds: points, terminalSeconds: elapsed(),
            outcome: outcome, verifiedDeliveryMeasured: false))
    }

    func finishDelivery(_ result: TextInserter.InsertionResult) {
        record(.deliveryReturned)
        switch result {
        case .inserted: finish(.dispatchReported)
        case .cancelled: finish(.cancelled)
        default: finish(.deliveryRejected)
        }
    }

    private func elapsed() -> Double {
        let value = started.duration(to: now()).components
        return Double(value.seconds) + Double(value.attoseconds) / 1e18
    }
}
