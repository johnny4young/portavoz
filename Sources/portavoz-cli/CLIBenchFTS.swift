import Foundation
import IntegrationsKit
import PortavozCore
import StorageKit

/// `portavoz-cli bench-fts [--meetings N] [--segments-per-meeting N]`
///
/// The T4 search harness: builds a synthetic corpus in a THROWAWAY
/// temporary database (never the user's library), then measures FTS5
/// query latency percentiles over a mixed query set. Target (PRODUCT.md):
/// search across 1,000 meetings in < 50 ms.
enum BenchFTSCommand {
    static func run(_ arguments: [String]) async {
        var meetings = 1_000
        var segmentsPerMeeting = 80

        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--meetings":
                index += 1
                if index < arguments.count { meetings = Int(arguments[index]) ?? meetings }
            case "--segments-per-meeting":
                index += 1
                if index < arguments.count {
                    segmentsPerMeeting = Int(arguments[index]) ?? segmentsPerMeeting
                }
            default:
                print("Unknown option: \(arguments[index])")
                return
            }
            index += 1
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("portavoz-bench-fts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let store = try MeetingStore(
                databaseURL: directory.appendingPathComponent("bench.sqlite"))

            print("Seeding \(meetings) meetings × \(segmentsPerMeeting) segments…")
            let seedStart = Date()
            try await seed(store: store, meetings: meetings, segments: segmentsPerMeeting)
            let seedElapsed = Date().timeIntervalSince(seedStart)
            let totalSegments = meetings * segmentsPerMeeting
            print(String(
                format: "Seeded %d segments in %.1f s (%.0f/s)",
                totalSegments, seedElapsed, Double(totalSegments) / seedElapsed))

            let sizeBytes = (try? FileManager.default.allocatedSizeOfDirectory(at: directory)) ?? 0
            print(String(format: "Database on disk: %.1f MB", Double(sizeBytes) / 1_048_576))

            try await measure(store: store, meetings: meetings)
        } catch {
            print("error: \(error)")
        }
    }

    /// Mixed workload: single word, phrase, AND of two words, and an OR
    /// question (the `ask` retrieval shape) — reported per query type.
    private static func measure(store: MeetingStore, meetings: Int) async throws {
        let queries: [(String, Bool)] = [
            ("presupuesto", true),
            ("action items", true),
            ("presupuesto transcripción", true),
            ("qué acordamos sobre el presupuesto del proyecto", false),
            ("deadline", true),
            ("Zephyr integración", true)
        ]
        var perQuery: [String: [Double]] = [:]
        for _ in 0..<20 {
            for (query, requireAll) in queries {
                let start = Date()
                if requireAll {
                    _ = try await store.search(query, limit: 20)
                } else {
                    _ = try await AskPipeline.retrieveLexical(
                        queries: [query], store: store, limit: 20)
                }
                let label = requireAll ? "exact search (AND)" : "question retrieval (OR)"
                perQuery[label, default: []].append(Date().timeIntervalSince(start) * 1_000)
            }
        }
        for (label, values) in perQuery.sorted(by: { $0.key < $1.key }) {
            let sorted = values.sorted()
            print(String(
                format: "%@ over %d meetings: p50 %.1f ms · p95 %.1f ms · max %.1f ms (%d runs)",
                label, meetings, sorted[sorted.count / 2],
                sorted[Int(Double(sorted.count) * 0.95)], sorted.last ?? 0, sorted.count))
        }
    }

    /// Deterministic synthetic Spanish/English meeting text — repeatable
    /// corpus, no random source, realistic word variety for bm25.
    private static func seed(store: MeetingStore, meetings: Int, segments: Int) async throws {
        let topics = [
            "presupuesto", "transcripción", "deadline", "integración", "Zephyr",
            "roadmap", "deploy", "cliente", "action", "items", "review", "pipeline",
            "modelo", "local", "resumen", "reunión", "proyecto", "equipo", "sprint",
            "release", "bug", "diarización", "audio", "calendario", "notas"
        ]
        for meetingIndex in 0..<meetings {
            let meetingID = MeetingID()
            let meeting = Meeting(
                id: meetingID,
                title: "Bench meeting \(meetingIndex)",
                startedAt: Date(timeIntervalSince1970: Double(meetingIndex) * 3_600))
            let speaker = Speaker(meetingID: meetingID, label: "S1")
            var rows: [TranscriptSegment] = []
            rows.reserveCapacity(segments)
            for segmentIndex in 0..<segments {
                // Rotating 8-word window over the topic list, salted with
                // the indices so bm25 sees varied documents.
                let base = (meetingIndex * 31 + segmentIndex * 7) % topics.count
                let words = (0..<8).map { topics[(base + $0) % topics.count] }
                rows.append(TranscriptSegment(
                    meetingID: meetingID, speakerID: speaker.id, channel: .system,
                    text: "Hablamos de \(words.joined(separator: " ")) en el punto \(segmentIndex).",
                    startTime: Double(segmentIndex) * 10,
                    endTime: Double(segmentIndex) * 10 + 9, isFinal: true))
            }
            try await store.save(meeting)
            try await store.save([speaker])
            try await store.save(rows)
        }
    }
}

extension FileManager {
    /// Total allocated bytes under a directory (sqlite + wal + shm).
    func allocatedSizeOfDirectory(at url: URL) throws -> Int64 {
        guard let enumerator = enumerator(
            at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
        else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
