import XCTest
@testable import DeepSeek_Harness

/// 协议模型宽松解码测试（规格 19：Parse what we need, ignore what we do not need）。
final class HarnessProtocolModelsTests: XCTestCase {

    private func decode(_ json: String) throws -> HarnessRPCEnvelope.Response {
        try JSONDecoder().decode(HarnessRPCEnvelope.Response.self, from: Data(json.utf8))
    }

    func testDecodeFullResponse() throws {
        let envelope = try decode("""
        {
          "type": "server-response",
          "rpcId": "abc",
          "result": {
            "ok": true,
            "value": {
              "version": "0.0.1",
              "cwd": "/Users/x",
              "provider": "deepseek-official",
              "model": "deepseek-v4-flash",
              "attachedSessions": 6,
              "canOpenPath": true
            }
          }
        }
        """)
        XCTAssertEqual(envelope.rpcId, "abc")
        XCTAssertTrue(envelope.result.ok)
        XCTAssertEqual(envelope.result.value?.version, "0.0.1")
        XCTAssertEqual(envelope.result.value?.attachedSessions, 6)
        XCTAssertEqual(envelope.result.value?.canOpenPath, true)
        XCTAssertEqual(envelope.result.value?.provider, "deepseek-official")
    }

    /// 上游新增未知字段仍必须正常解析。
    func testDecodeIgnoresUnknownFields() throws {
        let envelope = try decode("""
        {
          "type": "server-response",
          "rpcId": "abc",
          "result": {
            "ok": true,
            "value": {
              "version": "0.0.1",
              "cwd": "/tmp",
              "attachedSessions": 1,
              "canOpenPath": false,
              "brandNewField": { "nested": true }
            }
          }
        }
        """)
        XCTAssertTrue(envelope.result.ok)
        XCTAssertEqual(envelope.result.value?.version, "0.0.1")
    }

    /// provider/model 为可选字段：缺失仍可解析。
    func testDecodeOptionalFieldsMissing() throws {
        let envelope = try decode("""
        {
          "type": "server-response",
          "rpcId": "abc",
          "result": {
            "ok": true,
            "value": {
              "version": "0.0.1",
              "cwd": "/tmp",
              "attachedSessions": 0,
              "canOpenPath": false
            }
          }
        }
        """)
        XCTAssertNil(envelope.result.value?.provider)
        XCTAssertNil(envelope.result.value?.model)
    }

    /// 失败分支：result.ok=false，无 value。
    func testDecodeRPCFailure() throws {
        let envelope = try decode("""
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

    /// 未知事件 / 畸形 payload 被安全忽略或记录，不 crash（规格 19）。
    func testMalformedPayloadThrows() {
        XCTAssertThrowsError(try decode("not json at all"))
        XCTAssertThrowsError(try decode("{\"type\": \"server-response\"}"))
    }
}
