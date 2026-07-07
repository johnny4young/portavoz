import Foundation

/// One tool exposed over MCP. The handler receives the raw `arguments`
/// JSON and returns the text content of the result — tools decode their
/// own arguments with small Codable structs, keeping this layer free of
/// any storage knowledge (the CLI/app assemble the toolbox).
public struct MCPTool: Sendable {
    public let name: String
    public let description: String
    /// JSON Schema for the arguments, as a raw JSON string.
    public let inputSchema: String
    public let handler: @Sendable (Data) async throws -> String

    public init(
        name: String,
        description: String,
        inputSchema: String,
        handler: @escaping @Sendable (Data) async throws -> String
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.handler = handler
    }
}

/// Minimal MCP server over newline-delimited JSON-RPC 2.0 (the stdio
/// transport): `initialize`, `ping`, `tools/list`, `tools/call`. Local by
/// construction — it only ever talks through the pipes of the process
/// that spawned it (M8; the ARCHITECTURE "localhost + token" story maps
/// to stdio process trust).
public struct MCPServer: Sendable {
    public static let protocolVersion = "2024-11-05"

    private let serverName: String
    private let serverVersion: String
    private let tools: [MCPTool]

    public init(serverName: String = "portavoz", serverVersion: String = "0.1.0", tools: [MCPTool]) {
        self.serverName = serverName
        self.serverVersion = serverVersion
        self.tools = tools
    }

    /// Handles one incoming line. Returns the response JSON line, or nil
    /// for notifications (and empty lines), which get no response.
    public func handleLine(_ line: String) async -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        guard
            let data = trimmed.data(using: .utf8),
            let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return encode(error: -32700, message: "parse error", id: NSNull())
        }

        let id = message["id"]
        guard let method = message["method"] as? String else {
            return encode(error: -32600, message: "invalid request", id: id ?? NSNull())
        }
        // Notifications (no id) never get a response.
        guard let id else { return nil }

        switch method {
        case "initialize":
            return encode(result: [
                "protocolVersion": Self.protocolVersion,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": serverName, "version": serverVersion],
            ], id: id)

        case "ping":
            return encode(result: [String: Any](), id: id)

        case "tools/list":
            let list = tools.map { tool -> [String: Any] in
                let schema =
                    (try? JSONSerialization.jsonObject(with: Data(tool.inputSchema.utf8)))
                    as? [String: Any] ?? ["type": "object"]
                return [
                    "name": tool.name,
                    "description": tool.description,
                    "inputSchema": schema,
                ]
            }
            return encode(result: ["tools": list], id: id)

        case "tools/call":
            let params = message["params"] as? [String: Any] ?? [:]
            guard
                let name = params["name"] as? String,
                let tool = tools.first(where: { $0.name == name })
            else {
                return encode(error: -32602, message: "unknown tool", id: id)
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let argumentsData =
                (try? JSONSerialization.data(withJSONObject: arguments)) ?? Data("{}".utf8)
            do {
                let text = try await tool.handler(argumentsData)
                return encode(result: [
                    "content": [["type": "text", "text": text]],
                    "isError": false,
                ], id: id)
            } catch {
                return encode(result: [
                    "content": [["type": "text", "text": "error: \(error.localizedDescription)"]],
                    "isError": true,
                ], id: id)
            }

        default:
            return encode(error: -32601, message: "method not found: \(method)", id: id)
        }
    }

    // MARK: - JSON-RPC envelopes

    private func encode(result: [String: Any], id: Any) -> String {
        encodeEnvelope(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func encode(error code: Int, message: String, id: Any) -> String {
        encodeEnvelope(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private func encodeEnvelope(_ envelope: [String: Any]) -> String {
        guard
            let data = try? JSONSerialization.data(withJSONObject: envelope),
            let text = String(data: data, encoding: .utf8)
        else {
            return #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"internal error"}}"#
        }
        return text
    }
}
