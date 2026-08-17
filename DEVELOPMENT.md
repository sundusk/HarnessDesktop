# HarnessDesktop — DEVELOPMENT

开发流程与阶段状态。

## 开发原则

1. **Attach First** — 只连接用户已运行的 Harness。
2. **Zero Mutation** — 不修改 `~/.dsh` 等任何 Harness 数据，不执行 npm / pnpm / dsh plugin 命令。
3. **Web Core + Native Enhancement** — `WKWebView` 是兼容核心；Native API 失败只允许降级。

## 构建与测试

```bash
# 构建
xcodebuild -project HarnessDesktop.xcodeproj -scheme HarnessDesktop \
  -destination 'platform=macOS' build

# 测试
xcodebuild -project HarnessDesktop.xcodeproj -scheme HarnessDesktop \
  -destination 'platform=macOS' test
```

每次有意义的修改后必须：构建 → 跑测试 → 修复 warning → 检查 Zero Mutation → 更新本文档完成状态。

## 阶段状态

### Phase 0 — 项目骨架 ✅

- [x] macOS App target（SwiftUI App lifecycle）
- [x] App Sandbox + `com.apple.security.network.client` entitlement
- [x] 基础 `AppCoordinator`
- [x] `README.md` / `ARCHITECTURE.md` / `AGENTS.md` / `DEVELOPMENT.md`
- [x] Unit Test target
- [x] `xcodebuild build` 通过
- [x] `xcodebuild test` 通过

### Phase 1 — Attach + WKWebView ✅

- [x] `HarnessEndpoint`（loopback-only 校验）
- [x] `LocalHarnessDiscovery`（短超时 HTTP，2xx/3xx 即存在；不扫进程 / 不读 shell / 不读 `~/.dsh`）
- [x] Harness 未运行页（复制命令 + 重新检测，不自动运行命令）
- [x] `WKWebView` 直接加载 `http://127.0.0.1:3080/`（持久化数据存储，不注入 JS / 不改 DOM）
- [x] 外部链接策略（同 origin 留在 WebView，其余交给默认浏览器）
- [x] Reload（⌘R）与 Open in Browser
- [x] 连接期间低频健康检查（每 5s），Harness 中途关闭显示错误状态，恢复后可重新连接
- [x] Unit Tests（Endpoint 校验 / Discovery mock / 导航策略）
- [x] Build 通过
- [x] Test 通过

### Phase 2 — 原生窗口体验 ⬜ 未开始

- [ ] AppKit WindowCoordinator / 窗口位置恢复
- [ ] Menu Bar（NSStatusItem）
- [ ] 基础 Settings

### Phase 3 — Native Handshake ⬜ 未开始

- [ ] `host.describe`（最小 Native API）
- [ ] `HarnessHTTPTransport` / `HarnessProtocolAdapter` / `HarnessCompatibilityResolver`
- [ ] 失败进入 Degraded Mode，不阻止 Web UI

### Phase 4 — WebSocket Event Layer ⬜ 未开始

- [ ] `/api/events.host`、`/api/events.mux`（必须先核对上游 wire contract）
- [ ] reconnect / decode / unknown frame handling / Domain Event mapping

### Phase 5 — ActivityReducer ⬜ 未开始

- [ ] `SessionRuntimeState` / 多 Session / 全局活动状态 / transient completion event

### Phase 6 — Notifications ⬜ 未开始

- [ ] approval / question / completion / error；dedupe / debounce

### Phase 7 — Floating Pet ⬜ 未开始

- [ ] `NSPanel` 悬浮状态球；拖拽；位置保存；状态动画

### Phase 8 — 稳定性与发布准备 ⬜ 未开始

- [ ] diagnostics / crash-safe state restore / app icon / signing / notarization

## Zero Mutation 手工验收

开发机有真实 Harness 时执行：

1. 记录 `~/.dsh` 当前状态（checksum / git-like diff）。
2. 启动 Harness（`npx @deepseek-ai/dsh web`）。
3. 启动 HarnessDesktop，使用主窗口。
4. 退出 HarnessDesktop。
5. 再次用 Terminal 启动 Harness，验证所有插件和皮肤仍正常。
6. 验证 HarnessDesktop 没有修改任何 Harness 文件。

## 安全验收清单

- [ ] 没有代码写入 `~/.dsh`
- [ ] 没有代码读取 Profile 以驱动运行逻辑
- [ ] 没有 npm / pnpm / Node / dsh plugin / @latest
- [ ] 没有 kill Harness / 自动启动 Harness
- [ ] 没有 DOM status parsing / WebSocket monkey patch
- [ ] 没有公网 Harness
