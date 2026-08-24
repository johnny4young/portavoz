import ApplicationKit
import PortavozCore
import XCTest

final class AskWebTests: XCTestCase {
    func testAnswerPreservesSourceOrderAndPartialFailure() async throws {
        let firstURL = try XCTUnwrap(URL(string: "https://example.com/first"))
        let secondURL = try XCTUnwrap(URL(string: "https://example.org/down"))
        let retrieval = WebRetrievalStub(results: [
            firstURL: .success(citation(firstURL, text: "Harbor launches.")),
            secondURL: .failure(.providerUnavailable),
        ])
        let answering = WebAnsweringStub(
            snapshots: ["Harbor launches [1]."],
            result: "Harbor launches [1].")
        let evidence = WebEvidenceRecorder()
        let answers = WebAnswerRecorder()

        let result = try await AskWeb(
            retrieval: retrieval,
            answering: answering
        ).answer(AskWebRequest(
            question: "When?",
            sourceURLs: [firstURL, secondURL],
            consent: .approvedForSingleRequest
        ), onEvidence: { update in
            await evidence.record(update)
        }, onAnswer: { update in
            await answers.record(update)
        })

        XCTAssertEqual(result.generatedText, "Harbor launches [1].")
        XCTAssertEqual(result.generationOutcome, .generated)
        XCTAssertEqual(result.citations.map(\.url), [firstURL])
        XCTAssertEqual(result.sourceFailures, [AskWebSourceFailure(
            url: secondURL,
            kind: .providerUnavailable)])
        let publishedEvidence = await evidence.values
        let publishedAnswers = await answers.values
        XCTAssertEqual(publishedEvidence.count, 1)
        XCTAssertEqual(publishedEvidence[0].citations.map(\.url), [firstURL])
        XCTAssertEqual(publishedAnswers.map(\.text), ["Harbor launches [1]."])
    }

    func testAnswerRejectsUncitedAndOutOfRangeModelOutput() async throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/source"))
        for answer in ["Unsupported claim.", "Unsupported claim [2]."] {
            let recorder = WebAnswerRecorder()
            let result = try await AskWeb(
                retrieval: WebRetrievalStub(results: [
                    url: .success(citation(url, text: "Exact source")),
                ]),
                answering: WebAnsweringStub(
                    snapshots: [answer],
                    result: answer)
            ).answer(AskWebRequest(
                question: "What?",
                sourceURLs: [url],
                consent: .approvedForSingleRequest
            ), onAnswer: { update in
                await recorder.record(update)
            })

            XCTAssertNil(result.generatedText)
            XCTAssertEqual(result.generationOutcome, .failed)
            XCTAssertEqual(result.citations.count, 1)
            let published = await recorder.values
            XCTAssertEqual(published, [])
        }
    }

    func testAnswerRejectsGeneratedLinksButKeepsDirectCitation() async throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/source"))
        let generated = "See https://attacker.invalid [1]."
        let result = try await AskWeb(
            retrieval: WebRetrievalStub(results: [
                url: .success(citation(url, text: "Exact source")),
            ]),
            answering: WebAnsweringStub(
                snapshots: [generated],
                result: generated)
        ).answer(AskWebRequest(
            question: "What?",
            sourceURLs: [url],
            consent: .approvedForSingleRequest))

        XCTAssertNil(result.generatedText)
        XCTAssertEqual(result.generationOutcome, .failed)
        XCTAssertEqual(result.citations.map(\.url), [url])
    }

    func testAnswerRejectsForgedRetrievedCitation() async throws {
        let requested = try XCTUnwrap(URL(string: "https://example.com/source"))
        let forged = try XCTUnwrap(URL(string: "https://attacker.invalid/source"))
        let result = try await AskWeb(
            retrieval: WebRetrievalStub(results: [
                requested: .success(citation(forged, text: "Forged source")),
            ]),
            answering: WebAnsweringStub(
                snapshots: ["Forged [1]."],
                result: "Forged [1].")
        ).answer(AskWebRequest(
            question: "What?",
            sourceURLs: [requested],
            consent: .approvedForSingleRequest))

        XCTAssertTrue(result.citations.isEmpty)
        XCTAssertEqual(result.sourceFailures, [AskWebSourceFailure(
            url: requested,
            kind: .transport)])
        XCTAssertNil(result.generatedText)
        XCTAssertEqual(result.generationOutcome, .notRequested)
    }

    func testAnswerRejectsMalformedRetrievedCitationAtApplicationBoundary() async throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/source"))
        let retrievedAt = Date(timeIntervalSince1970: 200)
        let malformed: [(String, AskWebCitation)] = [
            ("blank title", citation(url, title: "   ", text: "Evidence")),
            (
                "oversized title",
                citation(
                    url,
                    title: String(
                        repeating: "t",
                        count: AskWebEvidenceLimits.maximumTitleCharacters + 1),
                    text: "Evidence")),
            ("blank text", citation(url, text: " \n ")),
            (
                "oversized UTF-8 text",
                citation(
                    url,
                    text: String(
                        repeating: "a\u{301}\u{302}\u{303}\u{304}",
                        count: 8_000))),
            (
                "non-finite retrieval time",
                citation(
                    url,
                    retrievedAt: Date(
                        timeIntervalSinceReferenceDate: .infinity),
                    text: "Evidence")),
            (
                "date missing for declared kind",
                citation(
                    url,
                    observedDate: nil,
                    observedDateKind: .published,
                    freshness: .unknown,
                    text: "Evidence")),
            (
                "date present for unavailable kind",
                citation(
                    url,
                    observedDateKind: .unavailable,
                    freshness: .unknown,
                    text: "Evidence")),
            (
                "freshness claimed without date",
                citation(
                    url,
                    observedDate: nil,
                    observedDateKind: .unavailable,
                    freshness: .recent,
                    text: "Evidence")),
            (
                "future date claimed fresh",
                citation(
                    url,
                    observedDate: retrievedAt.addingTimeInterval(1),
                    retrievedAt: retrievedAt,
                    text: "Evidence")),
        ]

        for (label, forged) in malformed {
            let result = try await AskWeb(
                retrieval: WebRetrievalStub(results: [
                    url: .success(forged),
                ]),
                answering: WebAnsweringStub(
                    snapshots: ["Must not run [1]."],
                    result: "Must not run [1].")
            ).answer(AskWebRequest(
                question: "What?",
                sourceURLs: [url],
                consent: .approvedForSingleRequest))

            XCTAssertTrue(result.citations.isEmpty, label)
            XCTAssertEqual(
                result.sourceFailures,
                [AskWebSourceFailure(url: url, kind: .transport)],
                label)
            XCTAssertNil(result.generatedText, label)
            XCTAssertEqual(result.generationOutcome, .notRequested, label)
        }
    }

    func testTimeoutClosesLateAnswerPublication() async throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/source"))
        let recorder = WebAnswerRecorder()
        let result = try await AskWeb(
            retrieval: WebRetrievalStub(results: [
                url: .success(citation(url, text: "Exact source")),
            ]),
            answering: SlowIgnoringCancellationWebAnswering(),
            answerTimeout: .milliseconds(10)
        ).answer(AskWebRequest(
            question: "What?",
            sourceURLs: [url],
            consent: .approvedForSingleRequest
        ), onAnswer: { update in
            await recorder.record(update)
        })

        XCTAssertNil(result.generatedText)
        XCTAssertEqual(result.generationOutcome, .timedOut)
        let published = await recorder.values
        XCTAssertEqual(published, [])
    }

    func testCancellationStopsBeforeEvidencePublication() async throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/slow"))
        let evidence = WebEvidenceRecorder()
        let task = Task {
            try await AskWeb(
                retrieval: BlockingWebRetrieval(),
                answering: WebAnsweringStub(snapshots: [], result: nil)
            ).answer(AskWebRequest(
                question: "What?",
                sourceURLs: [url],
                consent: .approvedForSingleRequest
            ), onEvidence: { update in
                await evidence.record(update)
            })
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("cancelled Web Ask must not complete")
        } catch is CancellationError {
        }
        let published = await evidence.values
        XCTAssertEqual(published, [])
    }

    func testRequestRejectsMissingDuplicateAndOversizedSources() async throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/source"))
        let ask = AskWeb(
            retrieval: WebRetrievalStub(results: [:]),
            answering: WebAnsweringStub(snapshots: [], result: nil))

        await XCTAssertThrowsErrorAsync(try await ask.answer(AskWebRequest(
            question: "   ",
            sourceURLs: [url],
            consent: .approvedForSingleRequest))) { error in
            XCTAssertEqual(error as? AskWebRequestError, .emptyQuestion)
        }
        await XCTAssertThrowsErrorAsync(try await ask.answer(AskWebRequest(
            question: "What?",
            sourceURLs: [],
            consent: .approvedForSingleRequest))) { error in
            XCTAssertEqual(error as? AskWebRequestError, .noSources)
        }
        await XCTAssertThrowsErrorAsync(try await ask.answer(AskWebRequest(
            question: "What?",
            sourceURLs: [url, url],
            consent: .approvedForSingleRequest))) { error in
            XCTAssertEqual(error as? AskWebRequestError, .duplicateSource)
        }
        await XCTAssertThrowsErrorAsync(try await ask.answer(AskWebRequest(
            question: "What?",
            sourceURLs: Array(repeating: url, count: AskWeb.maximumSources + 1),
            consent: .approvedForSingleRequest))) { error in
            XCTAssertEqual(error as? AskWebRequestError, .tooManySources)
        }
    }

    private func citation(
        _ url: URL,
        title: String = "Source",
        observedDate: Date? = Date(timeIntervalSince1970: 100),
        observedDateKind: AskWebObservedDateKind = .published,
        retrievedAt: Date = Date(timeIntervalSince1970: 200),
        freshness: AskWebFreshness = .recent,
        text: String
    ) -> AskWebCitation {
        AskWebCitation(
            url: url,
            title: title,
            observedDate: observedDate,
            observedDateKind: observedDateKind,
            retrievedAt: retrievedAt,
            freshness: freshness,
            text: text,
            isExcerptTruncated: false)
    }
}

private actor WebRetrievalStub: AskWebSourceRetrieving {
    let results: [URL: Result<AskWebCitation, AskWebRetrievalError>]

    init(results: [URL: Result<AskWebCitation, AskWebRetrievalError>]) {
        self.results = results
    }

    func retrieve(_ url: URL) async throws -> AskWebCitation {
        guard let result = results[url] else {
            throw AskWebRetrievalError.transport
        }
        return try result.get()
    }
}

private struct BlockingWebRetrieval: AskWebSourceRetrieving {
    func retrieve(_ url: URL) async throws -> AskWebCitation {
        try await Task.sleep(for: .seconds(30))
        throw AskWebRetrievalError.transport
    }
}

private struct WebAnsweringStub: AskWebAnswering {
    let snapshots: [String]
    let result: String?

    func answer(
        question _: String,
        citations _: [AskWebCitation]
    ) async throws -> String? {
        result
    }

    func answer(
        question _: String,
        citations _: [AskWebCitation],
        onAnswer: @escaping AskAnswerReceiver
    ) async throws -> String? {
        for snapshot in snapshots {
            await onAnswer(AskAnswerUpdate(text: snapshot))
        }
        return result
    }
}

private struct SlowIgnoringCancellationWebAnswering: AskWebAnswering {
    func answer(
        question _: String,
        citations _: [AskWebCitation]
    ) async throws -> String? {
        "Late [1]."
    }

    func answer(
        question _: String,
        citations _: [AskWebCitation],
        onAnswer: @escaping AskAnswerReceiver
    ) async throws -> String? {
        try? await Task.sleep(for: .milliseconds(100))
        await onAnswer(AskAnswerUpdate(text: "Late [1]."))
        return "Late [1]."
    }
}

private actor WebEvidenceRecorder {
    private(set) var values: [AskWebEvidenceUpdate] = []
    func record(_ value: AskWebEvidenceUpdate) { values.append(value) }
}

private actor WebAnswerRecorder {
    private(set) var values: [AskAnswerUpdate] = []
    func record(_ value: AskAnswerUpdate) { values.append(value) }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("expected an error")
    } catch {
        errorHandler(error)
    }
}
