import ApplicationKit
import Foundation
import PortavozCore
import StorageKit

extension AppServices {
    func makeInsightsModel(
        clock: @escaping @MainActor () -> Date = Date.init
    ) -> InsightsModel {
        InsightsModel(client: self, clock: clock)
    }
}

extension AppServices: InsightsModelClient {
    func observeInsights(
        scope: InsightsScope,
        now: Date
    ) -> AsyncStream<InsightsUpdate> {
        makeApplicationInsightsStream(
            meetings: store.observeInsightsMeetings(),
            facts: store.observeInsightsFacts(),
            balance: store.observeInsightsVoiceBalance(),
            findings: store.observeInsightsFindingInputs(
                in: scope.currentInterval(now: now)))
    }
}

private func makeApplicationInsightsStream(
    meetings: AsyncThrowingStream<[Meeting], Error>,
    facts: AsyncThrowingStream<MeetingStore.LibraryFacts, Error>,
    balance: AsyncThrowingStream<MeetingStore.VoiceBalance, Error>,
    findings: AsyncThrowingStream<[MeetingID: MeetingStore.FindingInput], Error>
) -> AsyncStream<InsightsUpdate> {
    AsyncStream { continuation in
        let task = Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await forward(meetings, to: continuation, section: .meetings) {
                        .meetings($0)
                    }
                }
                group.addTask {
                    await forward(facts, to: continuation, section: .facts) {
                        .facts(makeApplicationInsightsFacts($0))
                    }
                }
                group.addTask {
                    await forward(balance, to: continuation, section: .voiceBalance) {
                        .voiceBalance(makeApplicationVoiceBalance($0))
                    }
                }
                group.addTask {
                    await forward(findings, to: continuation, section: .findings) {
                        .findingInputs($0.mapValues(makeApplicationFindingInput))
                    }
                }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}

private func forward<Input: Sendable>(
    _ stream: AsyncThrowingStream<Input, Error>,
    to continuation: AsyncStream<InsightsUpdate>.Continuation,
    section: InsightsSection,
    transform: @escaping @Sendable (Input) -> InsightsUpdate
) async {
    do {
        for try await value in stream {
            continuation.yield(transform(value))
        }
    } catch is CancellationError {
        // Parent cancellation ends the complete merged stream.
    } catch {
        continuation.yield(.failed(section))
    }
}

private func makeApplicationInsightsFacts(
    _ facts: MeetingStore.LibraryFacts
) -> InsightsLibraryFacts {
    InsightsLibraryFacts(
        topParticipants: facts.topParticipants.map {
            InsightsParticipant(name: $0.name, meetings: $0.meetings)
        },
        openActionItems: facts.openActionItems,
        doneActionItems: facts.doneActionItems)
}

private func makeApplicationVoiceBalance(
    _ balance: MeetingStore.VoiceBalance
) -> InsightsVoiceBalance {
    InsightsVoiceBalance(
        participants: balance.participants.map {
            InsightsParticipantVoice(
                name: $0.name,
                meetings: $0.meetings,
                theirSeconds: $0.theirSeconds,
                myShareWithThem: $0.myShareWithThem)
        },
        myOverallShare: balance.myOverallShare,
        hasData: balance.hasData)
}

private func makeApplicationFindingInput(
    _ input: MeetingStore.FindingInput
) -> InsightsFindingInput {
    InsightsFindingInput(
        transcript: input.transcript,
        summaryMarkdown: input.summaryMarkdown,
        actionItemCount: input.actionItemCount)
}
