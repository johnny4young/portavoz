import CSQLiteVecResearch
import XCTest

final class SQLiteVecResearchTests: XCTestCase {
    func testPinnedStaticEngineRunsOneIsolatedExactQuery() {
        XCTAssertEqual(portavoz_sqlite_vec_run_exact_query_smoke(), 0)
    }
}
