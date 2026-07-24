import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// Dynamic exported types retain the exact filename extension while still
    /// advertising that subtitle payloads are UTF-8 text.
    static let portavozSRT = UTType(
        filenameExtension: "srt",
        conformingTo: .plainText) ?? .plainText
    static let portavozVTT = UTType(
        filenameExtension: "vtt",
        conformingTo: .plainText) ?? .plainText
}

/// Write-only wrapper so `fileExporter` can save bytes we already built.
struct ExportDocument: FileDocument {
    static let readableContentTypes: [UTType] = [
        .plainText, .pdf, .meetingBundle, .portavozSRT, .portavozVTT
    ]
    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
