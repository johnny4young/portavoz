import XCTest

extension ArchitectureDependencyTests {
    func testAudioImportKeepsOneApplicationModalChooserOutsideMenuTracking() throws {
        let source = try Self.contents(of: "Sources/portavoz-app/LibraryView.swift")
        let start = try XCTUnwrap(source.range(of: "private func chooseAudioToImport()"))
        let end = try XCTUnwrap(source.range(
            of: "private func importAudio(from urls:", range: start.upperBound..<source.endIndex))
        let chooser = String(source[start.lowerBound..<end.lowerBound])
        let admission = try XCTUnwrap(chooser.range(
            of: "guard !isChoosingAudio, state.importStatus == nil else { return }"))
        let reservation = try XCTUnwrap(chooser.range(of: "isChoosingAudio = true"))
        let dispatch = try XCTUnwrap(chooser.range(of: "DispatchQueue.main.async {"))
        let release = try XCTUnwrap(chooser.range(of: "defer { isChoosingAudio = false }"))
        let response = try XCTUnwrap(chooser.range(of: "guard panel.runModal() == .OK else { return }"))
        let submission = try XCTUnwrap(chooser.range(of: "importAudio(from: panel.urls)"))
        XCTAssertLessThan(admission.lowerBound, reservation.lowerBound)
        XCTAssertLessThan(reservation.lowerBound, dispatch.lowerBound)
        XCTAssertLessThan(dispatch.lowerBound, release.lowerBound)
        XCTAssertLessThan(release.lowerBound, response.lowerBound)
        XCTAssertLessThan(response.lowerBound, submission.lowerBound)
        XCTAssertEqual(chooser.components(separatedBy: "panel.runModal()").count - 1, 1)
        XCTAssertFalse(chooser.contains("panel.begin"), "A modeless window cannot replace modal ownership")
        XCTAssertTrue(source.contains(".disabled(state.importStatus != nil || isChoosingAudio)"))
    }
}
