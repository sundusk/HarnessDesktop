# DeepSeek Harness — Architecture

> Harness is the server. DeepSeek Harness is a native macOS client.
>
> Attach First. Zero Configuration Mutation. Explicit Runtime Management. Web Core, Native Enhancement.

## 总体架构（2.0：新增 Runtime Manager 层）

```text
┌────────────────────────────────────────────┐
│              DeepSeek Harness                │
│                                            │
│ ┌────────────────────────────────────────┐ │
│ │ Presentation                           │ │
│ │  MainWindowView / MenuBar / Settings   │ │
│ │  Notifications / Pet                   │ │
│ └──────────────────┬─────────────────────┘ │
│                    │                       │
│ ┌──────────────────▼─────────────────────┐ │
│ │ Domain                                 │ │
│ │  Endpoint / ConnectionState /          │ │
│ │  Activity / Ownership                  │ │
│ └──────────────────┬─────────────────────┘ │
│                    │                       │
│ ┌──────────────────▼─────────────────────┐ │
│ │ Harness Integration                    │ │
│ │  Discovery / WebSurface / Transport /  │ │
│ │  Compatibility                         │ │
│ └──────────────────┬─────────────────────┘ │
│                    │                       │
│ ┌──────────────────▼─────────────────────┐ │
│ │ Harness Runtime（2.0）                  │ │
│ │  EnvironmentDoctor / VersionService /  │ │
│ │  RuntimeController / ManagerClient     │ │
│ └──────────────┬──────────────┬──────────┘ │
│                │              │            │
│              HTTP/WS       XPC/IPC         │
│                │              │            │
│                ▼              ▼            │
│        ┌─────────────────┐  ┌───────────┐  │
│        │  Harness        │  │Runtime    │  │
│        │  http://        │  │Helper     │  │
│        │  127.0.0.1:3080 │  │(Phase 9+) │  │
│        └─────────────────┘  └───────────┘  │
│                                        │   │
│                            App-owned Node │
│                            + exact dsh    │
└────────────────────────────────────────────┘
                     ~/.dsh   ← Desktop 不直接写入
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

### ADR-004 — Attach First remains authoritative（2.0）

**背景**：2.0 增加 Runtime Manager（一键准备 / 启动 / 更新），可能诱使 App 主动启动 Harness。

**决策**：任何时候都优先发现并连接已经运行的 Harness；已发现 `127.0.0.1:<port>` 有有效 Harness 时禁止再启动 Managed Harness、禁止因版本不同替换用户运行中的 Harness、禁止因更新可用而停止外部 Harness。App 启动流程保持：探测 loopback → 已存在则 Attach；不存在才进入 Managed Runtime 检查。

**理由**：Desktop 是客户端不是服务器管理工具；用户终端里的 Harness 及其 Profile / 插件 / 皮肤是用户资产，任何主动接管都是架构退化。

### ADR-005 — External vs Managed ownership（2.0）

**背景**：Runtime Manager 需要决定哪些操作（Start / Stop / Update / Rollback）被允许。

**决策**：引入 `HarnessOwnership`（external / managed）。external = 非本次 Runtime Supervisor 创建的进程（Terminal / 其他 App / LaunchAgent），只允许 Attach / 读取版本 / 检查更新，**禁止 Stop / Restart / Update / Rollback**；managed = 由 Desktop 创建且进程身份与 generation token 被记录的进程，允许完整生命周期管理。Stop 必须同时验证 generationID + pid + helper-owned 引用，防止 PID reuse 误杀。

**理由**：Never kill what you do not own——安全边界是所有权，不是端口或版本。

### ADR-006 — Zero Configuration Mutation（2.0，升级 ADR-002）

**背景**：2.0 允许 App 启动 Harness，与 ADR-002 的「零变更」需要调和。

**决策**：重新定义为 **Desktop 不直接修改 Harness 的配置资产**：永远禁止编辑 / 删除 / 重建 `~/.dsh`、settings.yaml、Profile manifest、插件、皮肤、用户 Shell 配置、系统 PATH、`brew install node`、`npm install -g ...`、执行任意用户提供的 shell command。允许：读取 Harness 公开 API、在 App 自己的 Application Support 目录保存状态、管理 App 私有 Node Runtime / npm cache、启动官方 `@deepseek-ai/dsh`、停止 App 自己启动的 Harness、查询 npm registry 版本元数据。

**理由**：自动检查可以静默，自动修改不可以；写操作只允许作用于 App-owned 数据。

### ADR-007 — Runtime Helper boundary（2.0，Phase 9 已实现）

**背景**：主 App 处于 App Sandbox；若由 Sandbox App 直接创建 Node / Harness 子进程，子进程会继承极窄 Sandbox，导致 Harness 核心能力（访问用户工作目录 / 工具链 / 文件系统）被错误限制。

**决策**：不在 SwiftUI 主进程里直接 `Process()` 启动 Harness。使用独立的、签名的、用户级 Runtime Helper（优先 `SMAppService` 用户级 Agent + XPC / 强类型 IPC）。Helper API 必须是强类型能力白名单（`inspectRuntime` / `prepareRuntime` / `startHarness(version:port:dataMode:)` / `stopHarness(identity:)` / `status(identity:)`），**禁止** `runCommand(_:)` / `runShell(_:)` / `execute(arguments:)` 等任意命令接口。若签名 / IPC 成本不可接受，允许 V1 采用 Developer ID 站外分发、主 App 非 Sandbox 的简化方案，但必须保留命令白名单限制，且不得因取消 Sandbox 增加任意 shell 能力。

**实施状态（Phase 9）**：已实现内嵌 XPC Service target（`RuntimeHelper.xpc`，launchd 按需拉起，无需 SMAppService 注册）——强类型 @objc 协议 + NSSecureCoding DTO、调用方 Team ID 校验（`SecCodeCopyGuestWithAttributes`）、generation+pid 所有权验证、无任意命令。**签名约束**：XPC 要求 App 与 Helper 同一 team 签名；本工程为可移植性使用 ad-hoc 签名（无 team），开发构建下连接被拒 → `helperUnavailable` 优雅降级，正式分发（同一 Developer ID）时正常。若未来发现该成本不可接受，可按上文简化方案执行并更新本 ADR。

**理由**：进程边界即安全边界；Helper 是能力提供者，不是通用终端。

### ADR-008 — App-owned Node Runtime（2.0，Phase 10 起）

**背景**：普通用户可能没有 Node / npx / Homebrew。

**决策**：Managed Mode 使用 App-owned Node Runtime（Release 包内携带，arm64 / x86_64 分架构），npm cache 定向 App-owned 目录（`npm_config_cache=<AppSupport>/Runtime/npm-cache`），Managed Harness 使用隔离数据目录（`DSH_HOME=<AppSupport>/ManagedHarnessHome`）。不修改系统 Node、不依赖 `.zshrc` / PATH、不写 `/usr/local`、`/opt/homebrew`、`~/.npm` 等系统路径。Node Runtime 属于 Desktop 自己的基础设施；Harness 本体不随 App 固定打包。

**理由**：开箱即用与零系统变更不可兼得时，选择「隔离 + App-owned」，把变更限制在自己的目录内。

### ADR-009 — Managed exact Harness version（2.0，Phase 11 起）

**背景**：直接 `npx @deepseek-ai/dsh@latest` 每次启动都拉最新，行为不可复现且违反 Zero Configuration Mutation 的显式原则。

**决策**：Managed Harness 禁止使用 `@latest`。第一次 Prepare 时确认 registry `dist-tags.latest` 并固定 `managedVersion`（exact version），以后始终启动 exact version；`managedVersion` / `previousManagedVersion` 保存在 HarnessDesktop 自己的设置中，禁止写进 Harness Profile。

**理由**：显式版本 = 可复现、可回退、可审计。

### ADR-010 — Update is explicit and transactional（2.0，Phase 12 起）

**背景**：更新失败若直接覆盖当前版本，用户会失去可运行版本。

**决策**：更新必须显式（用户确认界面）且事务化：`PrepareCandidate(latest)` → `StopCurrent` → `LaunchCandidate` → health check（host.describe 验证）→ `Commit managedVersion`。在新版本成功启动并通过验证之前不删除 previous version / cache；candidate 启动失败则尝试恢复 previous working version。

**理由**：不允许「先覆盖再下载、失败后无版本可用」的破坏性更新。

### ADR-011 — DeepSeek Harness version sources are independent

**背景**：DeepSeek Harness 的 GitHub prerelease 可能早于 npm `dist-tags.latest` 发布。把 npm 同时当成“官方最新”和“可安装最新”会漏报 Release；反过来直接安装 GitHub 版本会在 npm 尚未同步时失败。

**决策**：版本系统固定为三个概念：`runningVersion` 只来自当前连接实例的 Compatibility Handshake（`host.describe.version`）；`latestReleaseVersion` 来自 GitHub `releases?per_page=20`，决定是否存在官方新版本；`latestInstallableVersion` 来自 npm Registry，决定 Managed Runtime 能否准备、启动或更新到该 exact 版本。两个网络源拥有独立的 6 小时缓存、节流和 single-flight。无法获取 `runningVersion` 时必须显示未知，绝不以 npm、npx、本地安装目录或 Managed Runtime 版本替代。

**安全边界**：所有 Managed Runtime 候选版本只允许经过 `latestManagedCandidateVersion()`，该入口仅消费 npm installable。GitHub-only Release 可以展示，但更新按钮必须禁用。App 自身的 `AppUpdateChecker` / `GitHubLatestReleaseProvider` 是另一套更新体系，不参与 Harness 版本判断。

**降级规则**：任一网络源失败只回退自己的缓存；GitHub 不可用时不能声称“已是最新”，npm 不可用时不能声称“可以更新”。版本查询失败不得影响 Attach、WebView、Native Adapter、Session、Pet 或已运行的 Managed Harness。

**npx 约束**：`npx @deepseek-ai/dsh --version` 仅表达 npx 当前可解析的包版本，可用于诊断，绝不代表当前连接的 Harness。External Harness 无论由 npm/npx 还是源码启动，均只允许 Discover、Attach 和只读协议访问。

## 模块职责

| 模块 | 职责 | 禁止 |
|------|------|------|
| `Harness/Discovery` | 探测 loopback 端点（短超时 HTTP，2xx/3xx 即存在） | 扫进程、读 shell、读 `~/.dsh`、执行命令 |
| `Harness/Web` | 承载官方 Web UI；导航策略；Reload；Open in Browser | 注入 JS、改 DOM/CSS、hook fetch/WebSocket、按 DOM 推断状态 |
| `Harness/Compatibility` | `host.describe` 握手 / 事件帧解析 / `HarnessVersion`（统一 Version Model） | 把上游 wire model 泄漏到上层 |
| `Harness/Runtime`（2.0） | Environment Doctor / 双源 Version Service / Runtime State / Update Status / RuntimeManagerClient | 混淆 GitHub release 与 npm installable；写非 App-owned 路径 |
| `RuntimeHelper`（2.0） | XPC Service target：强类型能力接口 / 调用方身份校验 / 所有权验证 | 任意命令 / 任意 shell / 访问用户数据 |
| `Domain` | 连接状态 / 端点 / 活动 / 所有权模型 | 不包含 Presentation 逻辑 |
| `Desktop` | SwiftUI / AppKit 视图、菜单栏、Pet | 自行推断网络 / 版本状态 |
| `Infrastructure` | 设置持久化（UserDefaults）、日志（os.Logger） | 记录凭据 / Prompt / 会话内容 / 完整环境变量 |

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
│   ├── Domain/         # 端点 / 连接状态 / 活动 / 所有权（HarnessOwnership）
│   ├── Harness/
│   │   ├── Discovery/  # 端点探测
│   │   ├── Web/        # WKWebView
│   │   ├── Transport/  # HTTP / WebSocket
│   │   ├── Compatibility/  # 握手 / 事件帧 / HarnessVersion
│   │   └── Runtime/    # (2.0) Doctor / VersionService / RuntimeState / UpdateStatus / Report / ManagerClient
│   ├── RuntimeHelper/  # (2.0) XPC Service target：契约 / 身份校验 / Service / main
│   ├── Desktop/        # SwiftUI / AppKit 视图（Window / MenuBar / Settings / Notifications / Pet）
│   ├── Infrastructure/ # Settings / Logging
│   └── Resources/      # Assets / Info.plist / Entitlements
├── DeepSeek HarnessTests/
├── README.md
├── ARCHITECTURE.md
├── AGENTS.md
└── DEVELOPMENT.md
```
