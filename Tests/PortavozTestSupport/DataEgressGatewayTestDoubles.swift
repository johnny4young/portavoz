import Foundation
import PortavozCore

struct TestDataEgressGateway: DataEgressGateway {
    func perform(
        _ networkRequest: URLRequest,
        metadata: DataEgressRequest
    ) async throws -> DataEgressResponse {
        DataEgressResponse(
            data: Data(#"{"choices":[{"message":{"content":"ok"}}]}"#.utf8),
            statusCode: 200)
    }
}

actor CapturingDataEgressGateway: DataEgressGateway {
    struct Capture: Sendable {
        let request: URLRequest
        let metadata: DataEgressRequest
    }

    private let responseData: Data
    private let statusCode: Int
    private var capture: Capture?

    init(
        responseData: Data = Data(
            #"{"choices":[{"message":{"content":"Use let by default."}}]}"#.utf8),
        statusCode: Int = 200
    ) {
        self.responseData = responseData
        self.statusCode = statusCode
    }

    func perform(
        _ networkRequest: URLRequest,
        metadata: DataEgressRequest
    ) async throws -> DataEgressResponse {
        capture = Capture(request: networkRequest, metadata: metadata)
        return DataEgressResponse(
            data: responseData,
            statusCode: statusCode)
    }

    func snapshot() -> Capture? { capture }
}
