# HarnessDesktop

> This is an **unofficial** macOS client for [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness).

HarnessDesktop 是一个 macOS 原生客户端 / 宿主，为已经安装并运行 DeepSeek Harness 的用户提供桌面体验。

## 声明

- **非官方**：本应用与 DeepSeek 官方无关。
- **不包含 DeepSeek Harness**：应用不内置、不捆绑、不 fork Harness Runtime。
- **不管理 Harness**：不安装 / 更新 / 卸载 Harness，不管理插件与 Profile。
- **需要用户自己运行 Harness**：请在终端运行 `npx @deepseek-ai/dsh web`。
- **默认连接 `127.0.0.1:3080`**（仅 loopback）。
- **不修改 `~/.dsh`**：应用从权限模型上（App Sandbox）就没有理由写入 Harness 数据。
- **不自动更新 Harness**，不执行任何 npm / pnpm / dsh plugin 命令。

## 架构原则

1. **Attach First** — 只连接用户已经运行的 Harness，不负责启动 / 安装 / 管理。
2. **Zero Mutation** — 不修改用户的任何 Harness 环境数据。
3. **Web Core + Native Enhancement** — 官方 Web UI 是核心；原生能力是增强，失败时优雅降级。

详见 [ARCHITECTURE.md](ARCHITECTURE.md)。

## 系统要求

- macOS 14.0+
- Apple Silicon + Intel

## 构建

```bash
# 构建
xcodebuild -project HarnessDesktop.xcodeproj -scheme HarnessDesktop \
  -destination 'platform=macOS' build

# 测试
xcodebuild -project HarnessDesktop.xcodeproj -scheme HarnessDesktop \
  -destination 'platform=macOS' test
```

## 使用

1. 在终端启动 Harness：

   ```bash
   npx @deepseek-ai/dsh web
   ```

2. 启动 HarnessDesktop。
3. 应用自动检测 `http://127.0.0.1:3080`：
   - 检测到 → 在 `WKWebView` 中加载官方 Harness Web UI；
   - 未检测到 → 显示「DeepSeek Harness 未运行」页，可复制启动命令或重新检测（**不会自动运行命令**）。

## 开发状态

| Phase | 内容 | 状态 |
|-------|------|------|
| 0 | 项目骨架（App target / Sandbox / 测试 target / 文档） | ✅ |
| 1 | Attach + WKWebView（发现 / 未运行页 / 导航策略 / Reload / Open in Browser） | ✅ |
| 2 | 原生窗口体验（窗口恢复 / Menu Bar / Settings） | ✅ |
| 3 | Native Handshake（`host.describe` / Transport / Adapter / Compatibility Resolver，降级不阻断 Web UI） | ✅ |
| 4 | WebSocket Event Layer（`events.mux` / `events.host`，退避重连 / 宽松解码 / Domain Event 映射） | ✅ |
| 5+ | ActivityReducer / 通知 / Pet / 发布准备 | ⬜ 未开始 |

详情见 [DEVELOPMENT.md](DEVELOPMENT.md)。

## 开发约束

对后续所有 AI Coding Agent 的永久约束见 [AGENTS.md](AGENTS.md)。

## 安全验收

安装 / 使用 / 退出 / 删除 HarnessDesktop 前后，Terminal 中的 Harness 均不受影响。

---

*Harness is the server. HarnessDesktop is a native macOS client.*
