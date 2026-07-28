import UniformTypeIdentifiers
import XCTest

@testable import portavoz_app

final class ExportDocumentTypesTests: XCTestCase {
    func testSubtitleContentTypesPreserveExtensionsAndTextConformance() {
        XCTAssertEqual(UTType.portavozSRT.preferredFilenameExtension, "srt")
        XCTAssertEqual(UTType.portavozVTT.preferredFilenameExtension, "vtt")
        XCTAssertTrue(UTType.portavozSRT.conforms(to: .plainText))
        XCTAssertTrue(UTType.portavozVTT.conforms(to: .plainText))
        XCTAssertTrue(ExportDocument.readableContentTypes.contains(.portavozSRT))
        XCTAssertTrue(ExportDocument.readableContentTypes.contains(.portavozVTT))
    }
}
