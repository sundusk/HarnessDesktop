# DeepSeek Harness — Architecture

> Harness is the server. DeepSeek Harness is a native macOS client.
>
> Attach First. Zero Mutation. Web Core, Native Enhancement.

## 总体架构

```text
┌────────────────────────────────────────────┐
│              DeepSeek Harness                │
│                                            │
│ ┌────────────────────────────────────────┐ │
│ │ Presentation                           │ │
│ │  MainWindowView / NotRunningView       │ │
│ │  (MenuBar / Notifications / Pet: 后期)  │ │
│ └──────────────────┬─────────────────────┘ │
│                    │                       │
│ ┌──────────────────▼─────────────────────┐ │
│ │ Domain                                 │ │
│ │  HarnessEndpoint / HarnessConnectionState│ │
│ └──────────────────┬─────────────────────┘ │
│                    │                       │
│ ┌──────────────────▼─────────────────────┐ │
│ │ Harness Integration                    │ │
│ │  HarnessDiscovery / HarnessWebSurface  │ │
│ └──────────────┬──────────────┬──────────┘ │
│                │              │            │
│              HTTP           WKWebView      │
└────────────────┼──────────────┼────────────┘
                 │              │
                 ▼              ▼
        ┌───────────────────────────────┐
        │       DeepSeek Harness        │
        │   http://127.0.0.1:3080       │
        └───────────────┬───────────────┘
                        │
                        ▼
                     ~/.dsh   ← DeepSeek Harness 不得写入此处
```

## 故障模型（Graceful Degradation）

- 原生 Harness API 不兼容 → Menu Bar / 通知 / Pet 不可用，但 `WKWebView` 官方 Harness UI 必须仍然可用。
- 禁止单点耦合：Native API 连接失败 → 进入 Degraded Mode → 继续显示官方 Web UI。
- WebView 与 Native Transport 生命周期互相独立。

## 决策记录

### ADR-001 — Attach First

**背景**：用户已经通过 `npx @deepseek-ai/dsh web` 在终端运行 Harness。

**决策**：应用只做连接（attach），不负责启动、安装或管理 Harness 进程。V1 不提供 Process Supervisor、不提供 Managed Runtime。

**理由**：
- 避免与 Harness 版本 / Node 运行时 / Profile / 插件体系耦合；
- 保持「Harness 是服务端，Desktop 是客户端」的单向依赖；
- 任何「Desktop 启动 Harness」的需求都意味着 Desktop 需要理解 Harness 的安装环境，违反 Zero Mutation。

### ADR-002 — Zero Mutation

**背景**：`~/.dsh` / `$DSH_HOME` 保存用户的 Profile、插件、patch 与运行时数据。

**决策**：应用不得写入、删除、迁移、修复或重建任何 Harness 数据；不得执行 `npm install` / `pnpm install` / `dsh plugin ...` 等命令；V1 启用 App Sandbox 且只申请 `com.apple.security.network.client`。

**理由**：
- 从权限模型上就没有修改 Harness 的能力；
- 用户资产（Profile / 插件 / 皮肤）不应被第三方客户端破坏；
- 验收标准：安装前 / 安装后 / 使用中 / 退出后 / 删除后，Terminal 中的 Harness 行为完全不变。

### ADR-003 — Web Core + Native Enhancement

**背景**：Harness 官方 Web UI 是最完整的兼容层，会随上游持续演进。

**决策**：`WKWebView` 直接加载 `http://127.0.0.1:3080/`，作为核心功能与兼容层；macOS 原生能力（Menu Bar / 通知 / Pet）属于增强层。Native API 失败只能造成降级，不能造成应用失败。

**理由**：
- 同源加载保证与 `/api` 的一致性，最大限度兼容官方皮肤与第三方插件；
- 官方 Web UI 升级后无需同步重写前端；
- Native 协议（`/api/events.host`、`/api/events.mux` 等）属于易变上游契约，只允许存在于 Compatibility / Transport 层，且其失败不能影响 Web 核心。

## 模块职责

| 模块 | 职责 | 禁止 |
|------|------|------|
| `Harness/Discovery` | 探测 loopback 端点（短超时 HTTP，2xx/3xx 即存在） | 扫进程、读 shell、读 `~/.dsh`、执行命令 |
| `Harness/Web` | 承载官方 Web UI；导航策略；Reload；Open in Browser | 注入 JS、改 DOM/CSS、hook fetch/WebSocket、按 DOM 推断状态 |
| `Domain` | 连接状态 / 端点模型 | 不包含 Presentation 逻辑 |
| `Desktop` | SwiftUI 视图 | 自行推断网络状态 |
| `Infrastructure` | 设置持久化（UserDefaults）、日志（os.Logger） | 记录凭据 / Prompt / 会话内容 |

## 安全边界

- 只允许 loopback host：`127.0.0.1` / `localhost` / `::1`；禁止公网与局域网地址。
- 外部链接一律交给 `NSWorkspace.shared.open`，避免应用变成通用浏览器。
- ATS：仅配置 `NSAllowsLocalNetworking`，不使用 `NSAllowsArbitraryLoads`。

## 目录

```text
DeepSeek Harness/
├── DeepSeek Harness.xcodeproj
├── DeepSeek Harness/
│   ├── App/            # 入口 + AppCoordinator
│   ├── Domain/         # 端点 / 连接状态（后续: 活动状态 / Reducer）
│   ├── Harness/        # Discovery / Web / (后续: Transport / Compatibility)
│   ├── Desktop/        # SwiftUI 视图
│   ├── Infrastructure/ # Settings / Logging / (后续: Diagnostics)
│   └── Resources/      # Assets / Info.plist / Entitlements
├── DeepSeek HarnessTests/
├── README.md
├── ARCHITECTURE.md
├── AGENTS.md
└── DEVELOPMENT.md
```
