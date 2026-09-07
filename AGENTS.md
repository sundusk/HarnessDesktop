# AGENTS.md

> 项目：DeepSeek Harness（macOS 原生客户端 / 宿主）
> 详细开发规格见 `1.0开发文档.md` 与 `2.0开发文档.md`。

## 开发约定（必须遵守）

### 每次开发前检查 DeepSeek Harness 官方上游进展

官方仓库：<https://github.com/deepseek-ai/deepseek-harness>

每次开始开发、排查兼容性问题或升级客户端前，必须先查看该官方仓库的最新进展，包括相关提交、Release、Issue 和 Discussion，并重点确认当前问题是否已经有官方修复、行为变化或兼容性要求。需要联网检索时，以官方 GitHub 内容为准，并在开发结论中说明检查到的相关版本或变更。

官方 Harness 仓库是只读上游，禁止直接修改、提交或推送其中的代码。所有适配、兼容和产品侧修复必须落在本客户端项目内；如需引用官方实现，应记录对应的官方链接或版本，避免基于过时源码判断问题。

### 每次开发完成后，删除所有构建产物

**规则**：每次开发完成（功能实现 → 编译 → 测试通过 → 提交代码）后，必须清理本机所有构建产物，防止 macOS 搜索（Spotlight）和应用列表中堆积大量同名的 DeepSeek Harness 拷贝。

**必须删除**：

- 项目内所有构建目录：`build/`、`DerivedData/`、`release-build/`、`.build-tmp/` 等，以及任何 `xcodebuild -derivedDataPath ...` 指定生成的目录；
- 构建产物里的 `.app`（例如 `build/Debug/DeepSeek Harness.app`、`build/ReleaseDerivedData/Build/Products/Release/DeepSeek Harness.app`）；
- 本项目的 Xcode 默认 DerivedData 产物：`~/Library/Developer/Xcode/DerivedData/` 下与本项目相关的目录（旧名 `HarnessDesktop-*` 与现名 `DeepSeek Harness-*`）；
- 开发期间产生的本地安装拷贝（如 `~/Applications/`、`/Applications/` 下的开发版 App）；
- 临时构建目录（如 `/tmp/*-build`、`/tmp/*-derived`）。

**保留**：用户明确要求保留的正式安装版本（例如 `/Applications/DeepSeek Harness.app`）不删除。

**验证方式**：清理后执行

```sh
mdfind "kMDItemCFBundleIdentifier == 'dev.deepseekharness.DeepSeekHarness'"
mdfind "kMDItemCFBundleIdentifier == 'dev.harnessdesktop.HarnessDesktop'"
```

应只剩用户保留的正式安装（或没有任何结果）。

### Harness 运行版本永久约束

- 当前连接的 Harness 运行版本只能来自该实例的 `host.describe.version`。
- npm Registry 版本只表示可安装版本；GitHub Release 版本只表示官方发布版本。
- `npx @deepseek-ai/dsh --version` 仅用于诊断，绝不能作为运行版本或其回退。
- 无法读取运行版本时必须降级为未知，禁止以 npm、npx、Managed Runtime 或路径推断替代。
- npm/npx 与源码启动的 External Harness 适用同一所有权保护：只允许 Attach 与只读访问。
