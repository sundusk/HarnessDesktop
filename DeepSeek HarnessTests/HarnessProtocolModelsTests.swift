import XCTest
@testable import DeepSeek_Harness

/// 协议模型宽松解码测试（规格 19：Parse what we need, ignore what we do not need）。
final class HarnessProtocolModelsTests: XCTestCase {

    // MARK: - RPC 信封（session/list 形态）

    private func decodeSessionList(_ json: String) throws -> HarnessRPCEnvelope.Response<HarnessSessionListValue> {
        try JSONDecoder().decode(HarnessRPCEnvelope.Response<HarnessSessionListValue>.self, from: Data(json.utf8))
    }

    func testDecodeSessionListResponse() throws {
        let envelope = try decodeSessionList("""
        {
          "type": "server-response",
          "rpcId": "abc",
          "result": {
            "ok": true,
            "value": {
              "items": [
                { "sessionId": "s1", "updatedAt": 1730000000, "running": true, "blank": false },
                { "sessionId": "s2", "updatedAt": 1730000001, "running": false, "blank": true,
                  "parentSessionId": "s1", "origin": "subagent", "cwd": "/tmp" }
              ]
            }
          }
        }
        """)
        XCTAssertEqual(envelope.rpcId, "abc")
        XCTAssertTrue(envelope.result.ok)
        XCTAssertEqual(envelope.result.value?.items.count, 2)
        XCTAssertEqual(envelope.result.value?.items[0].sessionId, "s1")
        XCTAssertEqual(envelope.result.value?.items[0].running, true)
        XCTAssertEqual(envelope.result.value?.items[1].running, false)
    }

    /// 上游新增未知字段仍必须正常解析。
    func testDecodeIgnoresUnknownFields() throws {
        let envelope = try decodeSessionList("""
        {
          "type": "server-response",
          "rpcId": "abc",
          "result": {
            "ok": true,
            "value": {
              "items": [
                { "sessionId": "s1", "running": true, "blank": false,
                  "brandNewField": { "nested": true } }
              ],
              "nextPage": { "cursor": "c1" }
            }
          }
        }
        """)
        XCTAssertTrue(envelope.result.ok)
        XCTAssertEqual(envelope.result.value?.items.first?.sessionId, "s1")
    }

    /// 失败分支：result.ok=false，无 value。
    func testDecodeRPCFailure() throws {
        let envelope = try decodeSessionList("""
        {
          "type": "server-response",
          "rpcId": "abc",
          "result": {
            "ok": false,
            "error": { "code": "internal", "message": "boom" }
          }
        }
        """)
        XCTAssertFalse(envelope.result.ok)
        XCTAssertNil(envelope.result.value)
        XCTAssertEqual(envelope.result.error?.message, "boom")
    }

    /// `$events/result` 的响应 value 缺省（上游返回 undefined）仍可解析。
    func testDecodeEmptyValueResponse() throws {
        let envelope = try JSONDecoder().decode(
            HarnessRPCEnvelope.Response<HarnessRPCEmptyValue>.self,
            from: Data("""
            { "type": "server-response", "rpcId": "abc", "result": { "ok": true } }
            """.utf8)
        )
        XCTAssertTrue(envelope.result.ok)
        XCTAssertNil(envelope.result.value)
    }

    func testMalformedPayloadThrows() {
        func decode(_ json: String) throws -> HarnessRPCEnvelope.Response<HarnessSessionListValue> {
            try JSONDecoder().decode(HarnessRPCEnvelope.Response<HarnessSessionListValue>.self, from: Data(json.utf8))
        }
        XCTAssertThrowsError(try decode("not json at all"))
        XCTAssertThrowsError(try decode("{\"type\": \"server-response\"}"))
    }

    // MARK: - RPC 请求编码

    /// `session/list` 的 args 键必须是 `_request`（按上游参数名绑定）。
    func testSessionListRequestBodyEncoding() throws {
        let request = HarnessRPCRequest(method: HarnessProtocolPath.sessionListEndpoint, args: HarnessRPCSessionListArgs())
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as! [String: Any]
        XCTAssertEqual(json["type"] as? String, "client-request")
        XCTAssertEqual(json["method"] as? String, "session/list")
        let payload = json["payload"] as! [String: Any]
        let args = payload["args"] as! [String: Any]
        XCTAssertEqual(args.count, 1)
        XCTAssertNotNil(args["_request"])
        XCTAssertEqual((args["_request"] as! [String: Any]).count, 0)
    }

    /// waterfall 应答 args：固定 `{clientId, eventId, outcome:{kind:"next"}}`。
    func testEventResultArgsEncoding() throws {
        let request = HarnessRPCRequest(
            method: HarnessProtocolPath.remoteEventResultEndpoint,
            args: HarnessRPCEventResultArgs(clientId: "c1", eventId: "e1")
        )
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as! [String: Any]
        XCTAssertEqual(json["method"] as? String, "$events/result")
        let args = (json["payload"] as! [String: Any])["args"] as! [String: Any]
        XCTAssertEqual(args["clientId"] as? String, "c1")
        XCTAssertEqual(args["eventId"] as? String, "e1")
        XCTAssertEqual((args["outcome"] as! [String: Any])["kind"] as? String, "next")
    }

    // MARK: - HarnessJSONValue

    func testJSONValueTypedExtraction() throws {
        let value = try JSONDecoder().decode(HarnessJSONValue.self, from: Data("""
        { "sessionId": "s1", "running": true, "count": 3, "tags": ["a"], "nested": { "k": "v" } }
        """.utf8))
        XCTAssertEqual(value["sessionId"]?.stringValue, "s1")
        XCTAssertEqual(value["running"]?.boolValue, true)
        XCTAssertEqual(value["count"]?.stringValue, nil)
        XCTAssertEqual(value["tags"]?.arrayValue?.first?.stringValue, "a")
        XCTAssertEqual(value["nested"]?["k"]?.stringValue, "v")
        XCTAssertNil(value["missing"])
    }
}
