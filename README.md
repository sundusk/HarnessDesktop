# DeepSeek Harness

> This is an **unofficial** macOS client for [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness).

DeepSeek Harness 是一个 macOS 原生客户端 / 宿主，为已经安装并运行 DeepSeek Harness 的用户提供桌面体验。

## 声明

- **非官方**：本应用与 DeepSeek 官方无关。
- **不包含 DeepSeek Harness**：应用不内置、不捆绑、不 fork Harness Runtime。
- **不管理 Harness**：不安装 / 更新 / 卸载 Harness，不管理插件与 Profile。
- **需要用户自己运行 Harness**：请在终端运行 `npx @deepseek-ai/dsh web`。
- **默认连接 `127.0.0.1:3080`**（仅 loopback）。
- **不修改 `~/.dsh`**：应用从权限模型上（App Sandbox）就没有理由写入 Harness 数据。
- **自动检查版本，但不自动更新**，不执行任何 npm / pnpm / dsh plugin 命令；
  External Harness（终端启动的）永远不会被本应用停止。

## 架构原则

1. **Attach First** — 只连接用户已经运行的 Harness，不负责启动 / 安装 / 管理。
2. **Zero Configuration Mutation** — 不直接修改用户的任何 Harness 配置资产（`~/.dsh` / Profile / 插件 / Shell / PATH）。
3. **Web Core + Native Enhancement** — 官方 Web UI 是核心；原生能力是增强，失败时优雅降级。

详见 [ARCHITECTURE.md](ARCHITECTURE.md)。

## 系统要求

- macOS 14.0+
- Apple Silicon + Intel

## 构建

```bash
# 构建
xcodebuild -project 'DeepSeek Harness.xcodeproj' -scheme 'DeepSeek Harness' \
  -destination 'platform=macOS' build

# 测试
xcodebuild -project 'DeepSeek Harness.xcodeproj' -scheme 'DeepSeek Harness' \
  -destination 'platform=macOS' test
```

## 使用

1. 在终端启动 Harness：

   ```bash
   npx @deepseek-ai/dsh web
   ```

2. 启动 DeepSeek Harness。
3. 应用自动检测 `http://127.0.0.1:3080`：
   - 检测到 → 在 `WKWebView` 中加载官方 Harness Web UI；菜单栏显示当前版本；
   - 未检测到 → 显示「DeepSeek Harness 未运行」页，可复制启动命令或重新检测（**不会自动运行命令**）。
4. **版本检查（2.0 Phase 8）**：
   - 启动时静默检查 npm registry 上 `@deepseek-ai/dsh` 的最新版本（6 小时内不重复检查）；
   - 菜单栏显示「当前 / 最新 / ⬆ 有更新可用」；
   - 菜单栏「检查 Harness 更新…」手动强制检查；
   - 仅提示，**不自动更新**；网络不可用不影响任何功能。
5. 桌面右下角出现**心情球**悬浮灯：随 Harness 状态实时呼吸变色
   （蓝=空闲 / 绿=工作中 / 黄=等待批准 / 粉=等待输入 / 红=出错 / 灰=未连接），
   任务完成时短暂「搞定啦」庆祝。按住可拖到任意位置（位置会记住），双击会兴奋晃动。
   - 菜单栏（鲸鱼图标）只有「显示悬浮球」开关（显示/隐藏心情球）；
   - 其余悬浮球设置都在「设置… → 悬浮球」标签里（球大小 / 呼吸速度 / 眼睛 / 气泡文字 /
     发光 / 点击穿透 / 锁定位置 / 状态颜色，即时生效）；
   - 设置窗口为左右标签页：**常规**（Harness 连接）与**悬浮球**。

## 开发状态

| Phase | 内容 | 状态 |
|-------|------|------|
| 0 | 项目骨架（App target / Sandbox / 测试 target / 文档） | ✅ |
| 1 | Attach + WKWebView（发现 / 未运行页 / 导航策略 / Reload / Open in Browser） | ✅ |
| 2 | 原生窗口体验（窗口恢复 / Menu Bar / Settings） | ✅ |
| 3 | Native Handshake（`host.describe` / Transport / Adapter / Compatibility Resolver，降级不阻断 Web UI） | ✅ |
| 4 | WebSocket Event Layer（`events.mux` / `events.host`，退避重连 / 宽松解码 / Domain Event 映射） | ✅ |
| 5 | ActivityReducer（多 Session / 全局活动状态优先级 / transient completion） | ✅ |
| 6 | Notifications（approval/question 立即、完成/错误通知、debounce/dedupe） | ✅ |
| 7 | 心情球悬浮球（内置 MoodBall，状态来自 Native 活动状态；菜单栏开关 + 设置页悬浮球设置） | ✅ |
| 8（V1） | 稳定性与发布准备（App 图标已完成；signing/notarization 移交 2.0 Phase 13/14） | ⬜ 进行中 |
| 2.0-8 | Runtime Domain & Environment Doctor（所有权模型 / 版本服务 / npm registry 查询 / semver 比较 / 启动静默检查 / 菜单栏检查更新 / 当前与最新版本 UI） | ✅ |
| 2.0-9 | Runtime Helper Skeleton（内嵌 XPC Service target / 强类型能力 API / 调用方身份校验 / 所有权验证 / health check；无任意命令） | ✅ |
| 2.0-10 | App-owned Node Runtime（目录与根限制 / 私有 npm cache / 隔离 DSH_HOME / 一键准备状态机与 UI / Release 打包脚本；Node 二进制由脚本获取） | ✅ |
| 2.0-11 | Managed Start/Stop（posix_spawn 进程组 / generation 所有权 / endpoint 碰撞保护 / 优雅停止 SIGINT→SIGTERM→SIGKILL / 意外退出处理 / 自动启动与退出策略 / External 保护） | ✅ |
| 2.0-12 … 14 | Update-Rollback / UX / Release | ⬜ 未开始 |

详情见 [DEVELOPMENT.md](DEVELOPMENT.md)。

## 开发约束

对后续所有 AI Coding Agent 的永久约束见 [AGENTS.md](AGENTS.md)。

## 安全验收

安装 / 使用 / 退出 / 删除 DeepSeek Harness 前后，Terminal 中的 Harness 均不受影响。

---

*Harness is the server. DeepSeek Harness is a native macOS client.*
