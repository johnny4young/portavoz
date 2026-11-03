import Foundation

/// A meeting bundle written without the app's types, because the UI runner links no package.
/// `MeetingBundleTests` proves the production codec reads it.
enum MeetingBundleFixture {
    static let fileExtension = "portavoz"

    static func data(title: String, texts: [String]) throws -> Data {
        let meetingID = ["rawValue": UUID().uuidString]
        let speakerID = ["rawValue": UUID().uuidString]
        let segments = texts.enumerated().map { index, text -> [String: Any] in
            ["id": UUID().uuidString, "meetingID": meetingID, "speakerID": speakerID, "channel": "system",
             "text": text, "startTime": Double(index * 3), "endTime": Double(index * 3 + 2), "isFinal": true]
        }
        let bundle: [String: Any] = [
            "formatVersion": 1,
            "exportedAt": "2001-01-01T00:16:40Z",
            "meeting": ["id": meetingID, "title": title, "startedAt": "1970-01-01T00:16:40Z", "language": "es",
                        "retention": ["keep": [String: String]()], "visibility": "private",
                        "lifecycleState": "ready", "transcriptRevision": 0],
            "speakers": [["id": speakerID, "meetingID": meetingID, "label": "S1", "isMe": false]],
            "segments": segments,
            "contextItems": [[String: String]]()
        ]
        return try JSONSerialization.data(withJSONObject: bundle, options: [.sortedKeys])
    }
}
