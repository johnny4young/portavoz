import PortavozCore
import XCTest

final class SemanticEmbeddingProfileTests: XCTestCase {
    func testFingerprintIsStableAndCoversEveryCompatibilityBoundary() {
        let baseline = semanticTestProfile()

        XCTAssertEqual(baseline.fingerprint, semanticTestProfile().fingerprint)
        XCTAssertNotEqual(
            baseline.fingerprint,
            semanticTestProfile(modelRevision: 2).fingerprint)
        XCTAssertNotEqual(
            baseline.fingerprint,
            semanticTestProfile(dimension: 3).fingerprint)
        XCTAssertNotEqual(
            baseline.fingerprint,
            semanticTestProfile(pipelineRevision: 2).fingerprint)
        XCTAssertNotEqual(
            baseline.fingerprint,
            semanticTestProfile(vectorSchemaVersion: 2).fingerprint)
    }

    func testInvalidProfilesCannotDescribePersistedVectors() {
        XCTAssertFalse(SemanticEmbeddingProfile(
            modelIdentifier: " ",
            modelRevision: 1,
            vectorDimension: 2,
            pipelineIdentifier: "test",
            pipelineRevision: 1,
            vectorSchemaVersion: 1).isValid)
        XCTAssertFalse(SemanticEmbeddingProfile(
            modelIdentifier: "test",
            modelRevision: 1,
            vectorDimension: 0,
            pipelineIdentifier: "test",
            pipelineRevision: 1,
            vectorSchemaVersion: 1).isValid)
    }
}
