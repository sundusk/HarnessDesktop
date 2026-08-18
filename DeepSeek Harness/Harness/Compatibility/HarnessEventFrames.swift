import Foundation

/// 事件流帧模型（wire contract 已对照上游 `events.d.ts` / `readSse` 实现确认）。
///
/// 传输形态：`POST /api/events.<mux|host>` 的 streaming fetch（SSE 风格），
/// `data: ` 行按 `\n\n` 分帧，每帧是 `server-request` 信封，`payload` 为事件帧判别联合。
///
/// 解码原则（规格 19）：Parse what we need, ignore what we do not need。
/// 未知字段 / 未知帧类型一律忽略并记录，不得关闭流。
struct HarnessServerRequestFrame: Sendable {
    let rpcId: String
    let method: String
    /// 帧 payload 的原始 JSON（由 Adapter 按帧类型宽松解码）。
    let payload: Data
}

/// 事件帧宽松模型：只声明需要映射的字段，其余字段自动忽略。
///
/// `type` 为判别字段；`sessionId` 等按帧类型存在，缺失时为空值。
struct HarnessEventFrame: Decodable, Sendable {
    let type: String
    let sessionId: String?
    let running: Bool?
    let message: String?
    let approvalId: String?
    let questionRpcId: String?
    let outcome: String?
}
