import Foundation
import PortavozCore
import XCTest

@testable import IntegrationsKit

final class MCPServerTests: XCTestCase {
    private func makeServer() -> MCPServer {
        MCPServer(tools: [
            MCPTool(
                name: "echo",
                description: "Echoes the input back.",
                inputSchema: #"{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}"#
            ) { data in
                struct Args: Decodable { var text: String }
                return "echo: \(try JSONDecoder().decode(Args.self, from: data).text)"
            },
            MCPTool(
                name: "boom",
                description: "Always fails.",
                inputSchema: #"{"type":"object"}"#
            ) { _ in
                throw NSError(
                    domain: "test", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "se rompió"])
            },
        ])
    }

    private func send(_ line: String) async -> [String: Any]? {
        guard let response = await makeServer().handleLine(line) else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any]
    }

    func testInitializeHandshake() async {
        let response = await send(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{}}}"#)
        let result = response?["result"] as? [String: Any]
        XCTAssertEqual(result?["protocolVersion"] as? String, MCPServer.protocolVersion)
        let info = result?["serverInfo"] as? [String: Any]
        XCTAssertEqual(info?["name"] as? String, "portavoz")
        XCTAssertNotNil((result?["capabilities"] as? [String: Any])?["tools"])
    }

    func testNotificationsGetNoResponse() async {
        let response = await makeServer().handleLine(
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        XCTAssertNil(response)
        let empty = await makeServer().handleLine("   ")
        XCTAssertNil(empty)
    }

    func testToolsListExposesSchemas() async {
        let response = await send(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        let tools = (response?["result"] as? [String: Any])?["tools"] as? [[String: Any]]
        XCTAssertEqual(tools?.count, 2)
        let echo = tools?.first { ($0["name"] as? String) == "echo" }
        let schema = echo?["inputSchema"] as? [String: Any]
        XCTAssertEqual(schema?["type"] as? String, "object")
        XCTAssertEqual((schema?["required"] as? [String])?.first, "text")
    }

    func testToolCallRoundTrip() async {
        let response = await send(
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"text":"hola"}}}"#)
        let result = response?["result"] as? [String: Any]
        let content = (result?["content"] as? [[String: Any]])?.first
        XCTAssertEqual(content?["text"] as? String, "echo: hola")
        XCTAssertEqual(result?["isError"] as? Bool, false)
    }

    func testToolErrorsSurfaceAsToolResults() async {
        let response = await send(
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"boom","arguments":{}}}"#)
        let result = response?["result"] as? [String: Any]
        XCTAssertEqual(result?["isError"] as? Bool, true)
        let text = ((result?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        XCTAssertTrue(text.contains("se rompió"))
    }

    func testProtocolErrors() async {
        let unknownMethod = await send(#"{"jsonrpc":"2.0","id":5,"method":"resources/list"}"#)
        XCTAssertEqual(
            ((unknownMethod?["error"] as? [String: Any])?["code"] as? Int), -32601)

        let unknownTool = await send(
            #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"nope"}}"#)
        XCTAssertEqual(((unknownTool?["error"] as? [String: Any])?["code"] as? Int), -32602)

        let garbage = await send("{not json")
        XCTAssertEqual(((garbage?["error"] as? [String: Any])?["code"] as? Int), -32700)
    }
}
