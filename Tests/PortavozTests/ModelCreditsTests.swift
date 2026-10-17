import ModelStoreKit
import XCTest

final class ModelCreditsTests: XCTestCase {
    func testEveryDownloadableModelIsCreditedFromItsPinnedSource() async {
        let credits = ModelCatalog.credits
        XCTAssertEqual(Set(credits.map(\.id)).count, credits.count)
        for descriptor in [ModelCatalog.parakeetTdtV3, ModelCatalog.speakerDiarization] {
            XCTAssertEqual(descriptor.license, "CC-BY-4.0")
            XCTAssertTrue(credits.contains { $0.id == descriptor.id }, "CC-BY requires attribution: \(descriptor.id)")
        }
        let parakeet = credits.first { $0.id == ModelCatalog.parakeetTdtV3.id }
        XCTAssertEqual(parakeet?.creator, "NVIDIA")
        XCTAssertEqual(parakeet?.source.absoluteString,
                       "https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml")
        for credit in credits {
            XCTAssertFalse(credit.source.absoluteString.contains("/resolve/"), "link the repository, not a file")
        }
    }
}
