import XCTest
@testable import DeepSeek_Harness

/// Phase 9：Helper 身份验证与所有权校验（规格 §32 / §35）。
final class RuntimeHelperIdentityTests: XCTestCase {

    // MARK: - Caller validator（Helper 只接受同 team 签名的主 App）

    func testAcceptsSameTeam() {
        XCTAssertTrue(RuntimeHelperCallerValidator.accepts(callerTeamID: "TEAM123", expectedTeamID: "TEAM123"))
    }

    func testRejectsDifferentTeam() {
        XCTAssertFalse(RuntimeHelperCallerValidator.accepts(callerTeamID: "TEAM123", expectedTeamID: "TEAM456"))
    }

    func testRejectsNilCallerTeam() {
        // ad-hoc / 无签名调用方 → 拒绝
        XCTAssertFalse(RuntimeHelperCallerValidator.accepts(callerTeamID: nil, expectedTeamID: "TEAM123"))
    }

    func testRejectsNilExpectedTeam() {
        // Helper 自己 ad-hoc（无 team）→ 拒绝一切连接（开发构建下 Helper 不可用，优雅降级）
        XCTAssertFalse(RuntimeHelperCallerValidator.accepts(callerTeamID: "TEAM123", expectedTeamID: nil))
        XCTAssertFalse(RuntimeHelperCallerValidator.accepts(callerTeamID: nil, expectedTeamID: nil))
    }

    // MARK: - Managed process ownership（文档 §17：generationID + pid 双验证，防 PID reuse）

    func testOwnedWhenGenerationAndPIDMatch() {
        let registration = ManagedProcessOwnership.Registration(generationID: UUID(), pid: 4242)
        XCTAssertTrue(ManagedProcessOwnership.isOwned(
            generationID: registration.generationID, pid: 4242, registered: registration
        ))
    }

    func testNotOwnedWhenPIDSameButGenerationMismatch() {
        // PID 复用场景：同 pid、不同 generation → 不是 owned，禁止 Stop
        let registration = ManagedProcessOwnership.Registration(generationID: UUID(), pid: 4242)
        XCTAssertFalse(ManagedProcessOwnership.isOwned(
            generationID: UUID(), pid: 4242, registered: registration
        ))
    }

    func testNotOwnedWhenGenerationSameButPIDDifferent() {
        let registration = ManagedProcessOwnership.Registration(generationID: UUID(), pid: 4242)
        XCTAssertFalse(ManagedProcessOwnership.isOwned(
            generationID: registration.generationID, pid: 9999, registered: registration
        ))
    }

    func testNotOwnedWhenNoRegistration() {
        XCTAssertFalse(ManagedProcessOwnership.isOwned(
            generationID: UUID(), pid: 4242, registered: nil
        ))
    }

    // MARK: - 契约：DTO 可安全编解码（NSSecureCoding）

    func testInspectionDTORoundTrip() throws {
        let dto = RuntimeInspectionDTO(nodeVersion: "v22.0.0", runtimeReady: true, managedHomeReady: true)
        let data = try NSKeyedArchiver.archivedData(withRootObject: dto, requiringSecureCoding: true)
        let decoded = try NSKeyedUnarchiver.unarchivedObject(ofClass: RuntimeInspectionDTO.self, from: data)
        XCTAssertEqual(decoded?.nodeVersion, "v22.0.0")
        XCTAssertTrue(decoded?.runtimeReady ?? false)
        XCTAssertTrue(decoded?.managedHomeReady ?? false)
    }

    func testIdentityDTORoundTrip() throws {
        let dto = ManagedHarnessIdentityDTO(
            generationID: "12345678-1234-1234-1234-123456789012",
            pid: 4242,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            version: "0.1.0-rc.7",
            port: 3080
        )
        let data = try NSKeyedArchiver.archivedData(withRootObject: dto, requiringSecureCoding: true)
        let decoded = try NSKeyedUnarchiver.unarchivedObject(ofClass: ManagedHarnessIdentityDTO.self, from: data)
        XCTAssertEqual(decoded?.generationID, "12345678-1234-1234-1234-123456789012")
        XCTAssertEqual(decoded?.pid, 4242)
        XCTAssertEqual(decoded?.startedAt, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(decoded?.version, "0.1.0-rc.7")
        XCTAssertEqual(decoded?.port, 3080)
    }

    // MARK: - 状态 wire code 映射

    func testStatusWireCodeMapping() {
        XCTAssertEqual(ManagedHarnessProcessStatus.fromWireCode("running", pid: 1), .running(pid: 1))
        XCTAssertEqual(ManagedHarnessProcessStatus.fromWireCode("stopped", pid: 1), .stopped)
        XCTAssertEqual(ManagedHarnessProcessStatus.fromWireCode("exited", pid: 7), .exited(code: 7))
        XCTAssertNil(ManagedHarnessProcessStatus.fromWireCode("unknown", pid: 1))
        XCTAssertEqual(ManagedHarnessProcessStatus.running(pid: 1).wireCode, "running")
    }

    // MARK: - XPC 错误映射（错误码 → HarnessRuntimeFailure，不携带敏感信息）

    func testRuntimeHelperErrorMapping() {
        XCTAssertEqual(
            runtimeHelperError(.callerNotAuthorized),
            NSError(domain: RuntimeHelperErrorDomain, code: RuntimeHelperErrorCode.callerNotAuthorized.rawValue)
        )
        XCTAssertEqual(runtimeHelperError(.runtimeMissing).domain, RuntimeHelperErrorDomain)
        XCTAssertEqual(runtimeHelperError(.runtimeMissing).code, 3)
    }
}
