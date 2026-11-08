import AVFAudio
import FluidAudio
import Foundation
import ModelStoreKit
import PortavozCore
import Testing

@testable import TranscriptionKit

@Suite(.timeLimit(.minutes(1)))
struct ParakeetModelLeaseTests {
    enum PreparationFailure: Error { case fixture }
    private enum RecognitionStage: Equatable, Sendable { case cancelled, joining, cleaned }

    @Test func anObserverCopyKeepsTheInstallationUntilItUnloads() async throws {
        let fixture = try ModelStoreLeaseTests.Fixture()
        defer { fixture.remove() }
        let store = fixture.store()
        _ = try await store.ensureAvailable(fixture.descriptor)
        var engine: ParakeetEngine? = ParakeetEngine(
            prepareLiveManager: { _ in throw PreparationFailure.fixture },
            prepareBatchManager: { _ in throw PreparationFailure.fixture },
            installationLease: try await store.lease(fixture.descriptor))
        var observed = engine?.observingLiveWork { _ in }
        engine = nil

        #expect(try await fixture.store().remove(fixture.descriptor) == .deferred)
        withExtendedLifetime(observed) {}
        observed = nil
        #expect(try await fixture.store().remove(fixture.descriptor) == .removed)
    }

    @Test func aLiveJobKeepsTheInstallationAfterItsEngineUnloadsAndReleasesItOnFailure() async throws {
        let fixture = try ModelStoreLeaseTests.Fixture()
        defer { fixture.remove() }
        let store = fixture.store()
        _ = try await store.ensureAvailable(fixture.descriptor)
        let entered = AsyncStream<Void>.makeStream()
        let gate = AsyncStream<Void>.makeStream()
        var engine: ParakeetEngine? = ParakeetEngine(
            prepareLiveManager: { _ in
                entered.continuation.yield(())
                for await _ in gate.stream { break }
                throw PreparationFailure.fixture
            },
            prepareBatchManager: { _ in throw PreparationFailure.fixture },
            installationLease: try await store.lease(fixture.descriptor))
        let stream = try #require(engine).transcribe(AsyncStream { $0.finish() }, hints: .init())
        engine = nil
        let job = Task {
            await #expect(throws: PreparationFailure.fixture) {
                for try await _ in stream { Issue.record("Preparation must fail before yielding text") }
            }
        }
        for await _ in entered.stream { break }

        #expect(try await fixture.store().remove(fixture.descriptor) == .deferred)
        gate.continuation.finish()
        _ = await job.value
        #expect(try await removeAfterTeardown(fixture) == .removed)
    }

    @Test func cancellationJoinsBlockedRecognitionBeforeCleanupOrReleasingTheLease() async throws {
        let fixture = try ModelStoreLeaseTests.Fixture()
        defer { fixture.remove() }
        let store = fixture.store()
        _ = try await store.ensureAvailable(fixture.descriptor)
        let events = AsyncStream<RecognitionStage>.makeStream()
        let manager = BlockedRecognitionManager(events: events.continuation)
        var engine: ParakeetEngine? = ParakeetEngine(
            prepareLiveManager: { _ in manager },
            prepareBatchManager: { _ in throw PreparationFailure.fixture },
            installationLease: try await store.lease(fixture.descriptor))
        let audio = AsyncStream<AudioChunk> {
            $0.yield(AudioChunk(channel: .microphone, samples: [0.1], sampleRate: .nan, timestamp: 0))
            $0.finish()
        }
        let stream = try #require(engine).transcribe(audio, hints: .init())
        engine = nil
        let job = Task {
            do {
                for try await _ in stream { Issue.record("Invalid PCM must not yield text") }
                Issue.record("Invalid PCM must end the job with an error")
            } catch {
                #expect(error is CancellationError || error is ParakeetStreamChannel.Failure)
            }
        }
        var stages = events.stream.makeAsyncIterator()
        #expect(await stages.next() == .cancelled)
        #expect(await stages.next() == .joining)
        #expect(await manager.didCleanup == false)
        await job.value
        #expect(try await fixture.store().remove(fixture.descriptor) == .deferred)

        await manager.releaseInference()
        #expect(await stages.next() == .cleaned)
        #expect(await manager.didCleanup)
        #expect(try await removeAfterTeardown(fixture) == .removed)
    }

    /// Output termination can precede the internal job's final defer.
    private func removeAfterTeardown(
        _ fixture: ModelStoreLeaseTests.Fixture
    ) async throws -> ModelStore.RemovalOutcome {
        let store = fixture.store()
        var outcome = try await store.remove(fixture.descriptor)
        for _ in 0..<100 where outcome == .deferred {
            try await Task.sleep(for: .milliseconds(10))
            outcome = try await store.remove(fixture.descriptor)
        }
        return outcome
    }

    /// Mirrors the pinned native manager: cancellation closes output while an
    /// already-started prediction ignores cancellation until its own completion.
    private actor BlockedRecognitionManager: ParakeetLiveManaging {
        private let events: AsyncStream<RecognitionStage>.Continuation
        private let output = AsyncThrowingStream<SlidingWindowTokenUpdate, Error>.makeStream()
        private let inference = InferenceGate()
        private var recognizer: Task<Void, Never>?
        private(set) var didCleanup = false

        init(events: AsyncStream<RecognitionStage>.Continuation) { self.events = events }

        var tokenUpdates: AsyncThrowingStream<SlidingWindowTokenUpdate, Error> { output.stream }

        func startStreaming(source: AudioSource) async throws {
            recognizer = Task { await inference.wait() }
        }

        func streamAudio(_ buffer: AVAudioPCMBuffer) {}

        func cancel() {
            recognizer?.cancel()
            output.continuation.finish(throwing: CancellationError())
            events.yield(.cancelled)
        }

        func finish() async throws -> String {
            events.yield(.joining)
            await recognizer?.value
            return ""
        }

        func cleanup() {
            didCleanup = true
            events.yield(.cleaned)
        }

        func releaseInference() async { await inference.release() }
    }

    private actor InferenceGate {
        private var released = false
        private var waiter: CheckedContinuation<Void, Never>?

        func wait() async {
            guard !released else { return }
            await withCheckedContinuation { waiter = $0 }
        }

        func release() {
            released = true
            waiter?.resume()
            waiter = nil
        }
    }
}
