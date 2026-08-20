# AGENTS.md

> 项目：DeepSeek Harness（macOS 原生客户端 / 宿主）
> 详细开发规格见 `1.0开发文档.md` 与 `2.0开发文档.md`。

## 开发约定（必须遵守）

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
