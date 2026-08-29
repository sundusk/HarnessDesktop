import Foundation

/// 宽容递归 JSON 值模型：用于 `args` / `request` 这类异构载荷的按需取值。
///
/// 解码原则（规格 19）：Parse what we need, ignore what we do not need。
enum HarnessJSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([HarnessJSONValue])
    case object([String: HarnessJSONValue])

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var arrayValue: [HarnessJSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var objectValue: [String: HarnessJSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// 按对象键取子值（非对象返回 nil）。
    subscript(key: String) -> HarnessJSONValue? {
        objectValue?[key]
    }
}

extension HarnessJSONValue: Decodable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Bool 必须先于 Double 尝试：避免数值分支吞掉布尔。
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([HarnessJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: HarnessJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "harness protocol: unsupported JSON value"
            )
        }
    }
}

/// `$events` 下行事件帧（上游 `RemoteEventDownlinkFrame`，宽容模型：只取需要的字段）。
///
/// - `ready`：绑定了本次事件流世代的 `clientId`，后续 waterfall 应答必须携带；
/// - `emit`：广播事件（如 `api-session/*`）；
/// - `waterfall`：待决请求（如 `approval/request`），**每个收到交付的客户端都必须
///   经 `$events/result` 应答**，全部应答 `next` 后事件才继续向 Host 链下游传递；
/// - `cancel`：某个已交付的 waterfall 已终结（被认领 / 全员放行 / 撤销）。
enum HarnessRemoteEventFrame: Equatable, Sendable {
    case ready(clientId: String, hostHome: String?)
    case emit(event: String, args: [HarnessJSONValue])
    case waterfall(event: String, eventId: String, agentId: String?, request: HarnessJSONValue?)
    case cancelled(eventId: String)
}

extension HarnessRemoteEventFrame: Decodable {
    private enum Keys: String, CodingKey {
        case type, clientId, host, event, args, eventId, agentId, request
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "ready":
            let clientId = try container.decode(String.self, forKey: .clientId)
            let hostInfo = try? container.decodeIfPresent(HostInfo.self, forKey: .host)
            self = .ready(clientId: clientId, hostHome: hostInfo?.home)
        case "emit":
            let event = try container.decode(String.self, forKey: .event)
            let args = try? container.decodeIfPresent([HarnessJSONValue].self, forKey: .args)
            self = .emit(event: event, args: args ?? [])
        case "waterfall":
            self = .waterfall(
                event: try container.decode(String.self, forKey: .event),
                eventId: try container.decode(String.self, forKey: .eventId),
                agentId: try? container.decodeIfPresent(String.self, forKey: .agentId),
                request: try? container.decodeIfPresent(HarnessJSONValue.self, forKey: .request)
            )
        case "cancel":
            self = .cancelled(eventId: try container.decode(String.self, forKey: .eventId))
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "harness protocol: unknown downlink frame type \(other)"
            )
        }
    }

    /// ready 帧携带的 Host 稳定信息。
    struct HostInfo: Decodable, Sendable {
        let home: String?
    }
}

/// `/api/remote.mux` 服务端消息（上游 `RemoteStreamServerMessage`，宽容模型）。
///
/// - `{"type":"item","streamId","value":<下行帧>}`：逻辑流数据项；
/// - `{"type":"end","streamId"}`：服务端正常关闭；
/// - `{"type":"error","streamId","error":{"code","message","details"}}`：流失败。
///
/// 未知 `value` 帧类型宽容置 nil（消息本身存活，由上层跳过），绝不拖垮整个流。
struct HarnessRemoteStreamMessage: Decodable, Sendable {
    let type: String
    let streamId: String?
    /// `item` 消息携带的下行帧；未知类型为 nil。
    let frame: HarnessRemoteEventFrame?
    /// `error` 消息的可读信息。
    let failureMessage: String?

    private enum Keys: String, CodingKey {
        case type, streamId, value, error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        type = try container.decode(String.self, forKey: .type)
        streamId = try container.decodeIfPresent(String.self, forKey: .streamId)
        frame = (try? container.decodeIfPresent(HarnessRemoteEventFrame.self, forKey: .value)) ?? nil
        let failure = try? container.decodeIfPresent(Failure.self, forKey: .error)
        failureMessage = failure?.message
    }

    /// `error` 消息的失败字段。
    struct Failure: Decodable, Sendable {
        let code: String?
        let message: String?
    }
}

/// 客户端 open 消息（上游 `RemoteStreamClientMessage`）。
///
/// 打开 Gateway 内部 `$events` 事件流；payload 必须恰为 `{"args":{}}`。
struct HarnessRemoteStreamOpenMessage: Encodable, Sendable {
    let type: String
    let streamId: String
    let endpoint: String
    let payload: Payload

    init(endpoint: String) {
        self.type = "open"
        self.streamId = UUID().uuidString.lowercased()
        self.endpoint = endpoint
        self.payload = Payload()
    }

    struct Payload: Encodable, Sendable {
        let args: Args = Args()
    }

    struct Args: Encodable, Sendable {}
}
