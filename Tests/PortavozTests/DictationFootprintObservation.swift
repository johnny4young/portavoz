import Foundation
import os

@testable import portavoz_app

/// Whole XCTest-process footprint, including harness/model caches; not an
/// allocation attribution or proof of an unsampled instantaneous peak/leak.
@MainActor
final class DictationFootprintObservation {
    struct Receipt: Codable, Equatable, Sendable {
        let baselineBytes: UInt64
        let peakObservedBytes: UInt64
        let endingBytes: UInt64
        let sampleCount: Int
        let cadenceMilliseconds: Int
        let initialThermalState: ResourceProbeThermalState
        let finalThermalState: ResourceProbeThermalState
    }

    typealias Usage = @Sendable () throws -> ResourceProbeUsage
    private struct State: Sendable {
        var peak: UInt64
        var count = 1
        var failed = false
    }

    private let before: ResourceProbeUsage
    private let usage: Usage
    private let state: OSAllocatedUnfairLock<State>
    private let sampler: Task<Void, Never>

    init(usage: @escaping Usage = ResourceProbeUsage.current) throws {
        self.usage = usage
        before = try usage()
        let state = OSAllocatedUnfairLock(initialState: State(peak: before.physicalFootprintBytes))
        self.state = state
        sampler = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                guard !Task.isCancelled else { return }
                do {
                    let value = try usage().physicalFootprintBytes
                    state.withLock { $0.peak = max($0.peak, value); $0.count += 1 }
                } catch { state.withLock { $0.failed = true }; return }
            }
        }
    }

    func finish() async throws -> Receipt {
        sampler.cancel()
        await sampler.value
        let after = try usage()
        let sampled = state.withLock { $0 }
        guard !sampled.failed else { throw DictationModelProbe.Failure.invalidInput }
        return Receipt(
            baselineBytes: before.physicalFootprintBytes,
            peakObservedBytes: max(sampled.peak, after.physicalFootprintBytes),
            endingBytes: after.physicalFootprintBytes, sampleCount: sampled.count + 1,
            cadenceMilliseconds: 100, initialThermalState: before.thermalState,
            finalThermalState: after.thermalState)
    }

    deinit { sampler.cancel() }
}
