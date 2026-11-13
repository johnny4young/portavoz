import FluidAudio
import Foundation
import os
import PortavozCore
import Testing

@testable import TranscriptionKit

/// These tests enter the real engine methods and stop at model preparation.
/// They prove configuration routing, not recognition quality or backend decoding.
@Suite(.timeLimit(.minutes(1)))
struct ParakeetLanguageConfigurationTests {
    enum PreparationFailure: Error, Equatable { case live, batch, unexpectedRoute }

    @Test(arguments: [nil, "es", "en", "el", "ru", "", "ES", "es-ES", " es ", "日本語"] as [String?])
    func liveLanguageHintNeverFiltersScriptOrChangesWindow(_ language: String?) async throws {
        let observed = OSAllocatedUnfairLock<SlidingWindowAsrConfig?>(initialState: nil)
        let engine = ParakeetEngine(
            prepareLiveManager: { configuration in
                observed.withLock { $0 = configuration }
                throw PreparationFailure.live
            },
            prepareBatchManager: { _ in throw PreparationFailure.unexpectedRoute })
        let audio = AsyncStream<AudioChunk> { $0.finish() }

        await #expect(throws: PreparationFailure.live) {
            for try await _ in engine.transcribe(
                audio, hints: .init(language: language)) {
                Issue.record("Preparation failure must not emit a transcript segment")
            }
        }

        let configuration = try #require(observed.withLock { $0 })
        #expect(configuration.language == nil)
        #expect(configuration.chunkSeconds == 1)
        #expect(configuration.hypothesisChunkSeconds == 1)
        #expect(configuration.leftContextSeconds == 11)
        #expect(configuration.rightContextSeconds == 0.4)
        #expect(configuration.minContextForConfirmation == 10)
        #expect(configuration.confirmationThreshold == 0.8)
        #expect(configuration.tdtConfig == nil)
    }

    @Test(arguments: ["es", "en", "ru", "el"])
    func meetingLanguageLabelsSegmentsWithoutFilteringLiveScript(_ language: String) async throws {
        let observed = OSAllocatedUnfairLock<SlidingWindowAsrConfig?>(initialState: nil)
        let engine = ParakeetEngine(
            prepareLiveManager: { configuration in
                observed.withLock { $0 = configuration }
                throw PreparationFailure.live
            },
            prepareBatchManager: { _ in throw PreparationFailure.unexpectedRoute })

        await #expect(throws: PreparationFailure.live) {
            for try await _ in engine.transcribe(
                AsyncStream { $0.finish() }, hints: .init(language: language, meetingID: MeetingID())) {
                Issue.record("Preparation failure must not emit a transcript segment")
            }
        }
        #expect(try #require(observed.withLock { $0 }).language == nil)
    }

    @Test
    func concurrentJobsAndObserverWrapperNeverFilterLiveScript() async {
        let observed = OSAllocatedUnfairLock<[String]>(initialState: [])
        let receipts = OSAllocatedUnfairLock<[ParakeetLiveWorkSample]>(initialState: [])
        let engine = ParakeetEngine(
            prepareLiveManager: { configuration in
                observed.withLock { $0.append(configuration.language?.rawValue ?? "automatic") }
                throw PreparationFailure.live
            },
            prepareBatchManager: { _ in throw PreparationFailure.unexpectedRoute }
        ).observingLiveWork { receipt in receipts.withLock { $0.append(receipt) } }
        let languages: [String?] = ["es", nil, "en", "ru", nil, "es"]

        await withTaskGroup(of: Void.self) { group in
            for language in languages {
                group.addTask {
                    await #expect(throws: PreparationFailure.live) {
                        for try await _ in engine.transcribe(
                            AsyncStream { $0.finish() }, hints: .init(language: language)) {
                            Issue.record("Preparation failure must not yield a segment")
                        }
                    }
                }
            }
        }

        #expect(observed.withLock { $0 } == Array(repeating: "automatic", count: languages.count))
        #expect(receipts.withLock { $0.count } == languages.count)
        #expect(receipts.withLock { $0.allSatisfy { $0.outcome == .failed && $0.finishCalls == 0 } })
    }

    @Test
    func batchPreparationKeepsSerialPolicyAndPropagatesFailure() async throws {
        let observed = OSAllocatedUnfairLock<ASRConfig?>(initialState: nil)
        let engine = ParakeetEngine(
            prepareLiveManager: { _ in throw PreparationFailure.unexpectedRoute },
            prepareBatchManager: { configuration in
                observed.withLock { $0 = configuration }
                throw PreparationFailure.batch
            }).observingLiveWork { _ in Issue.record("Batch must not report live work") }

        await #expect(throws: PreparationFailure.batch) {
            _ = try await engine.transcribeFile(
                at: URL(fileURLWithPath: "/unused-dictation-fixture.wav"), hints: .init(language: "es"))
        }
        let configuration = try #require(observed.withLock { $0 })
        #expect(configuration.parallelChunkConcurrency == 1)
        #expect(configuration.melChunkContextOverride == false)
    }
}
