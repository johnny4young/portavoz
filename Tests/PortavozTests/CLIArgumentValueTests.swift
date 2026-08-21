import Foundation
import XCTest

@testable import portavoz_cli

final class CLIArgumentValueTests: XCTestCase {
    func testStringValueRejectsMissingEmptyAndAnotherOption() throws {
        var index = 0
        XCTAssertEqual(
            try CLIOptionValue.string(
                ["--file", "meeting.wav"],
                index: &index,
                option: "--file"),
            "meeting.wav")
        XCTAssertEqual(index, 1)

        for arguments in [["--file"], ["--file", ""], ["--file", "--seconds", "10"]] {
            index = 0
            XCTAssertThrowsError(try CLIOptionValue.string(
                arguments,
                index: &index,
                option: "--file")) { error in
                if arguments.count == 2, arguments[1].isEmpty {
                    XCTAssertEqual(
                        error as? CLIArgumentError,
                        .invalidValue(
                            option: "--file",
                            value: "",
                            expected: "a non-empty value"))
                } else {
                    XCTAssertEqual(
                        error as? CLIArgumentError,
                        .missingValue(option: "--file"))
                }
            }
        }
    }

    func testIntegerValueRejectsMalformedNegativeAndOversizedInput() throws {
        var index = 0
        XCTAssertEqual(
            try CLIOptionValue.integer(
                ["--seconds", "86400"],
                index: &index,
                option: "--seconds",
                range: CLIOptionBounds.durationSeconds),
            86_400)

        for raw in ["not-a-number", "-1", "0", "86401", String(repeating: "9", count: 80)] {
            index = 0
            XCTAssertThrowsError(try CLIOptionValue.integer(
                ["--seconds", raw],
                index: &index,
                option: "--seconds",
                range: CLIOptionBounds.durationSeconds)) { error in
                XCTAssertEqual(
                    error as? CLIArgumentError,
                    .invalidValue(
                        option: "--seconds",
                        value: raw,
                        expected: "an integer from 1 through 86400"))
            }
        }
    }

    func testNumericValueDoesNotConsumeTheFollowingOptionAsItsValue() {
        var index = 0
        XCTAssertThrowsError(try CLIOptionValue.integer(
            ["--seconds", "--system"],
            index: &index,
            option: "--seconds",
            range: CLIOptionBounds.durationSeconds)) { error in
            XCTAssertEqual(
                error as? CLIArgumentError,
                .missingValue(option: "--seconds"))
        }
        XCTAssertEqual(index, 0)
    }

    func testFloatingPointValuesRejectNonFiniteAndUnsafeBounds() throws {
        var index = 0
        XCTAssertEqual(
            try CLIOptionValue.finiteFloat(
                ["--threshold", "0.45"],
                index: &index,
                option: "--threshold",
                expected: "a finite number greater than 0 and less than 1",
                accepting: CLIOptionBounds.acceptsDiarizationThreshold),
            0.45)

        for raw in ["nan", "inf", "-inf", "0", "1", "-0.1", "1.1"] {
            index = 0
            XCTAssertThrowsError(try CLIOptionValue.finiteFloat(
                ["--threshold", raw],
                index: &index,
                option: "--threshold",
                expected: "a finite number greater than 0 and less than 1",
                accepting: CLIOptionBounds.acceptsDiarizationThreshold))
        }

        index = 0
        XCTAssertEqual(
            try CLIOptionValue.finiteDouble(
                ["--collar", "60"],
                index: &index,
                option: "--collar",
                range: CLIOptionBounds.diarizationCollar),
            60)
        for raw in ["nan", "inf", "-1", "60.1"] {
            index = 0
            XCTAssertThrowsError(try CLIOptionValue.finiteDouble(
                ["--collar", raw],
                index: &index,
                option: "--collar",
                range: CLIOptionBounds.diarizationCollar))
        }
    }

    func testFTSCorpusCountIsCheckedAndBounded() {
        XCTAssertEqual(
            CLIOptionBounds.ftsSegmentCount(
                meetings: 1_000,
                segmentsPerMeeting: 80),
            80_000)
        XCTAssertEqual(
            CLIOptionBounds.ftsSegmentCount(
                meetings: 100_000,
                segmentsPerMeeting: 10),
            CLIOptionBounds.maximumFTSSegments)
        XCTAssertNil(CLIOptionBounds.ftsSegmentCount(
            meetings: 100_000,
            segmentsPerMeeting: 11))
        XCTAssertNil(CLIOptionBounds.ftsSegmentCount(
            meetings: Int.max,
            segmentsPerMeeting: 2))
    }
}
