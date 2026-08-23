# 桌面宠物设计、实现与进度

> AI 快速入口：当任务涉及桌面宠物、小雨、心情球、状态气泡、悬浮窗、点击穿透、拖拽、精灵图或动画时，先读本文，再读对应源码。
> 本文面向 Codex、DeepSeek Harness 和人工维护者。最后核验日期：**2026-08-23**。

## 1. 当前结论

- 桌面宠物已实现，默认皮肤为 **小雨**，可在设置中切回完整保留的 **心情球**。
- 状态只来自 `AppCoordinator.activityState`，不读取 WebView DOM，也不直接消费 wire 事件。
- 小雨支持 7 种 Harness 呈现状态、空闲双击挥手、双击展开主 App 以及左右拖拽奔跑。
- 小雨使用原始角色颜色；心情状态色只用于角色背后的光晕和气泡描边。
- 所有动作、气泡显示与隐藏均保持同一个宠物视口、角色尺度规则和屏幕底部锚点。
- 目前没有自动行走、屏幕边缘巡逻、碰撞逻辑或鼠标视线跟随。
- `HarnessActivityState`、事件协议、`ActivityReducer` 优先级和完成事件 2.5 秒 transient 行为没有因宠物功能而改变。

截至最后核验：当前源码完整测试 **259/259 通过**，Universal Release 构建已验证 `arm64 + x86_64` 和签名；拖拽奔跑视觉 QA **97/100，通过**。双击展开主 App 属于尚未发布的源码改动，当前 `/Applications/DeepSeek Harness.app` 仍是已发布的 v0.2.10，不包含本次改动。后续发布或安装后必须同步更新这里，不能把日期快照当作永久现状。

## 2. 架构与数据流

```text
Harness native events
        ↓
ActivityReducer / AppCoordinator.activityState
        ↓
MoodBallModel
  - 活动状态 → mood
  - mood → 文案、状态色
  - completion → done 2.5s transient
        ↓
MoodBallView
  ├─ FloatingPetSkin.moodBall → 原心情球渲染
  └─ FloatingPetSkin.xiaoyu   → XiaoyuSpriteView
        ↓
MoodBallCoordinator + MoodBallPanel
  - NSPanel 生命周期、尺寸、显隐、屏幕位置、点击穿透
  - SwiftUI 手势负责拖拽和双击
```

职责边界：

| 文件 | 责任 |
| --- | --- |
| `DeepSeek Harness/App/AppCoordinator.swift` | 持有 `petSettings` / `petModel`；任务完成时调用 `noteTaskCompletion()` |
| `DeepSeek Harness/App/AppDelegate.swift` | 创建并启动 `MoodBallCoordinator`；提供双击恢复主窗口的统一入口 |
| `DeepSeek Harness/Desktop/Pet/MoodBallSettings.swift` | 皮肤、大小、颜色、气泡、穿透、位置等 UserDefaults 持久化 |
| `DeepSeek Harness/Desktop/Pet/MoodBallModel.swift` | `HarnessActivityState` 到呈现 mood 的唯一映射；气泡文案和颜色 |
| `DeepSeek Harness/Desktop/Pet/MoodBallCoordinator.swift` | 悬浮面板生命周期、尺寸、显隐、悬停穿透、屏幕变化兜底 |
| `DeepSeek Harness/Desktop/Pet/MoodBallPanel.swift` | 透明非激活 `NSPanel`、拖拽状态和位置持久化 |
| `DeepSeek Harness/Desktop/Pet/MoodBallView.swift` | 皮肤切换、固定布局、气泡、拖拽、双击；保留心情球画面 |
| `DeepSeek Harness/Desktop/Pet/XiaoyuSpriteView.swift` | 小雨图集解码缓存、状态动画、逐帧时长、拖拽奔跑和最近邻渲染 |
| `DeepSeek Harness/Desktop/Settings/SettingsView.swift` | “设置 → 桌面宠物”即时设置 UI |
| `DeepSeek Harness/Desktop/MenuBar/MenuBarCoordinator.swift` | “显示/隐藏桌面宠物”菜单项 |

命名说明：现有 `MoodBall*` 类型和 `moodball.*` UserDefaults 键是历史兼容边界。即使 UI 已统一称为“桌面宠物”，也不要为了整洁做无关重命名或迁移。

## 3. 状态契约

### 3.1 Harness 状态到呈现状态

| `HarnessActivityState` / 事件 | 呈现 mood | 默认色 | 气泡文字 | 小雨动作 |
| --- | --- | --- | --- | --- |
| `.disconnected` | `disconnected` | `#9CA3AF` 灰 | 不显示 | 闭眼静止，整体 65% 透明度 |
| `.idle` | `idle` | `#60A5FA` 蓝 | 不显示 | 平静站立、自然眨眼 |
| `.running` | `waiting` | `#34D399` 绿 | 正在思考中 | 思考、处理中；不是字面奔跑 |
| `.waitingForApproval` | `authorizing` | `#FACC15` 黄 | 等待你的授权 | 注视用户、等待许可 |
| `.waitingForInput` | `questioning` | `#EC4899` 粉 | 做出你的抉择 | 倾听并伸手询问 |
| completion transient | `done` | `#22D3EE` 青 | 搞定啦 | 蹲起、跳跃、举手庆祝 |
| `.error` | `failed` | `#F87171` 红 | 出错了 | 低头、蹲坐、沮丧 |

关键约束：

- `done` 来自 `ActivityReducer.drainCompletions()`，由 `MoodBallModel.noteTaskCompletion()` 保持 2.5 秒，再回到真实状态。
- `MoodBallModel.transientMood` 的呈现优先于当前 `activityState`，但不要借此修改 reducer 的领域优先级。
- `disconnected` 必须读取可自定义的 `settings.disconnectedColor`，不能退回硬编码灰色。
- `idle` 和 `disconnected` 不显示气泡；其余 mood 在 `showStatusBubble == true` 时显示。
- 颜色可以在设置中自定义；上表只是默认契约。

### 3.2 小雨动画配置

应用专用状态图集中的行顺序如下：

| App 图集 row | 动画 | 有效帧 | 逐帧时长 | 播放策略 | 整行显示倍率 | 来源 |
| ---: | --- | ---: | --- | --- | ---: | --- |
| 0 | `disconnected` | 1 | 1.00s | 静帧循环 | 1.00 | 原图 row 0 闭眼帧 |
| 1 | `idle` | 7 | `0.88, 0.88, 0.12, 0.88, 0.88, 0.12, 0.96` | 循环 | 1.00 | 原图 row 0 |
| 2 | `waiting` | 6 | 0.20s/帧 | 循环 | 0.97 | 原图 row 7，任务处理中 |
| 3 | `authorizing` | 6 | 0.24s/帧 | 循环 | 0.95 | 原图 row 6，等待用户 |
| 4 | `questioning` | 6 | 0.20s/帧 | 循环 | 1.00 | 按原角色身份新生成 |
| 5 | `done` | 5 | 0.12s/帧 | 循环 | 1.10 | 原图 row 4 |
| 6 | `failed` | 8 | 0.16s/帧 | 播放一次后停在末帧 | 1.02 | 原图 row 5 |
| 7 | `wave` | 4 | 0.14s/帧 | 两轮后恢复 idle | 0.96 | 原图 row 3 |

实现约束：

- `TimelineView` 以 `1/60s` 最小刷新间隔驱动，但真正换帧由上表逐帧时长决定。
- mood 变化时从对应动画首帧重新开始。
- 双击由 `MoodBallModel.handleDoubleClick(...)` 同时触发动作时间和主窗口回调；小雨只有在 `idle` 时允许 `wave` 覆盖状态，心情球继续使用原有衰减晃动。
- 提问动作语义固定为“正面关注 → 轻微歪头 → 手离开口袋 → 胸前开放手掌询问 → 保持倾听 → 回到关注姿势”。禁止问号、文字、光效或新道具。

### 3.3 左右拖拽奔跑

- `XiaoyuDragSprites.png` row 0：向屏幕右侧奔跑，8 帧，来自原图 row 1。
- `XiaoyuDragSprites.png` row 1：向屏幕左侧奔跑，8 帧，来自原图 row 2。
- 帧间隔为 0.08 秒；水平累计位移达到 2 px 后选择方向，避免鼠标微抖频繁换向。
- 屏幕横坐标增加是 `.right`，减少是 `.left`；拖动中反向会立即切换行并从该方向首帧开始。
- 拖拽动画临时覆盖当前小雨状态；松手后清除方向并从当前 Harness 状态动画首帧恢复。
- 拖拽图集显示倍率固定为 1.0，沿用最近邻插值和底部锚点。
- `lockPosition == true` 时不移动、不播放奔跑；`clickThroughMode == .always` 时窗口始终穿透，因此不能拖拽。
- 不要通过镜像 SwiftUI 视图、倒放帧序或运行时变换伪造另一方向；当前左右行均来自原图的对应动作。

## 4. 资源契约

### 4.1 应用实际打包的资源

| 文件 | 格式 | 尺寸 | 网格 | 非空格分布 |
| --- | --- | ---: | --- | --- |
| `DeepSeek Harness/Resources/Pet/Xiaoyu/XiaoyuSprites.png` | RGBA PNG | `1536×1664` | `8×8`，每格 `192×208` | `[1, 7, 6, 6, 6, 5, 8, 4]` |
| `DeepSeek Harness/Resources/Pet/Xiaoyu/XiaoyuDragSprites.png` | RGBA PNG | `1536×416` | `2×8`，每格 `192×208` | `[8, 8]` |

两张 PNG 必须作为 Xcode target resources 进入 App Bundle。`XiaoyuSpriteAtlas` 和 `XiaoyuDragSpriteAtlas` 各解码一次并缓存裁切后的 `CGImage`，不能在每一帧重复解码或裁图。

### 4.2 原始 Codex Pet 图集与 App 图集不是同一协议

原始身份参考位于开发机 `/Users/sundusk/Desktop/spritesheet.webp`，尺寸为 `1536×2288`，即 `8×11`、每格 `192×208` 的 Codex Pet v2 图集。它保持不变，也不是运行时依赖。

必须区分：

- 原始 Codex Pet 的 rows 0–10 是 `idle / running-right / running-left / waving / jumping / failed / waiting / running-task / review / look-A / look-B`。
- App 的 `XiaoyuSprites.png` 是按 Harness mood 重排后的 **8×8 专用状态图集**；row 语义不同。
- App 的 `XiaoyuDragSprites.png` 是从原图 row 1/2 确定性无损裁出的 **2×8 专用拖拽图集**。
- 不要让 App 在运行时读取桌面路径，不要覆盖原始 WebP，也不要把 App 专用 PNG 当作可安装的 Codex Pet v2 包。

如果以后替换资源：先锁定脸型、眼睛、发型、夹克结构、裤子、鞋子、头身比例、像素质感和相机距离；优先确定性裁切/装配，只有源动作确实缺失时才生成。修复应以“最小完整动作行”为单位，不要混入身份或尺度不一致的单帧补丁。

## 5. 尺寸、基线与气泡不位移约束

这是已经修过的高风险区域，后续改动必须保持：

1. `settings.ballSize` 范围 60–200，默认 120。对小雨而言，它表示固定角色视口内的显示高度基准。
2. 每个源格固定 `192×208`；显示宽度按 `size × 192 / 208`，显示高度为 `size`。
3. 每个动画只允许一个共享 `displayScale`，并使用 `.scaleEffect(..., anchor: .bottom)`。
4. 禁止按单帧非透明包围盒分别放大到满格。蹲坐、低头、跳跃的姿势高度可以变化，头脸、身体、手脚和服装的解剖尺度不能跳变。
5. 使用 `.interpolation(.none)`，保持像素边缘，不要改为平滑插值。
6. 宠物画面始终占 `2d × 2d` 固定视口；气泡不参与宠物画面的尺寸计算。
7. 气泡总高度固定为 44。显示气泡时，面板只向上增加 44，宠物画面向下偏移 44，从而保持宠物在屏幕上的底部位置不变。
8. `MoodBallCoordinator.panelFrame(...)` 必须同时保持水平中心和“宠物中心距窗口底边为 d”的锚点。不要只改 SwiftUI 的 offset 而不改 NSPanel frame 计算，反之亦然。
9. 气泡层 `.allowsHitTesting(false)`；悬停穿透只检测宠物画面，不让气泡抢走鼠标事件。

如果出现“气泡一出现宠物下沉”“某个蹲姿忽然变大”“皮肤切换跳位”，优先检查：

- `MoodBallView` 的顶部对齐、固定视口和 `bubbleHeight` offset；
- `MoodBallCoordinator.panelFrame(...)` 的底部锚点数学；
- `XiaoyuAnimation.displayScale` 是否被误改为逐帧缩放；
- 图集源行本身是否已经发生身份/尺度漂移。

## 6. 悬浮窗与交互

- `MoodBallPanel` 是透明、无边框、非激活的 `NSPanel`，level 为 `.floating`，可加入所有 Space 和全屏辅助空间。
- 初始位置优先恢复保存值，否则放在鼠标所在屏幕可视区右下角，边距 16。
- 显示器变化后，如果窗口中心不在任何屏幕可视区，自动收回右下角。
- 拖拽使用 `NSEvent.mouseLocation` 和抓取点偏移，不依赖 SwiftUI `translation`，避免移动窗口后坐标系反馈导致拖拽缩水。
- 位移小于 4 px 视为点击；0.35 秒内两次点击视为双击。
- 双击任一皮肤时保留原有动作反馈，并调用 `AppDelegate.showMainWindow()`：取消 App 隐藏、激活 App、恢复最小化窗口并将主窗口置前；窗口已关闭时重新显示，窗口已可见时只前置。
- 点击穿透模式：
  - `.hover`：默认穿透，鼠标进入宠物有效区域后恢复响应；
  - `.always`：始终穿透，不可拖拽；
  - `.never`：始终响应。
- 拖拽中 `panel.isDragging` 会阻止悬停逻辑重新打开穿透。
- 位置记忆受 `rememberPosition` 控制；设置页可锁定位置或重置到右下角。

## 7. 设置和持久化

`FloatingPetSkin` 只有 `.moodBall` 和 `.xiaoyu`；未保存或无效值默认 `.xiaoyu`。

两种皮肤共用：显隐、大小、气泡、光晕、7 种状态色、点击穿透、位置记忆、锁定位置和重置位置。呼吸速度、眼睛显隐和眼睛颜色只在心情球皮肤下显示。

现有 UserDefaults 键：

```text
moodball.skin
moodball.ballSize
moodball.breathingSpeed
moodball.showEyes
moodball.eyeColor
moodball.showStatusBubble
moodball.glowEnabled
moodball.lockPosition
moodball.clickThrough
moodball.rememberPosition
moodball.isBallVisible
moodball.ballPositionX
moodball.ballPositionY
moodball.moodColor.<mood>
```

颜色以 6 位十六进制字符串保存。不要把 `UInt32` 直接写入后再按十六进制字符串读取，否则会破坏持久化颜色。

## 8. 已完成进度

| 项目 | 状态 |
| --- | --- |
| 心情球原功能保留 | ✅ |
| 小雨成为默认皮肤，设置中可切换 | ✅ |
| 7 种状态及颜色契约 | ✅ |
| 小雨专用 8×8 状态图集 | ✅ |
| 缺失的 6 帧提问动作 | ✅ |
| 60 Hz 时间线和逐帧时长 | ✅ |
| 失败一次播放后停末帧 | ✅ |
| 空闲双击挥手两轮 | ✅ |
| 双击宠物恢复并前置主 App | ✅ |
| 气泡出现不挤动宠物 | ✅ |
| 所有姿势使用整行动画尺度校准 | ✅ |
| 左右拖拽 2×8 奔跑图集和运行时切换 | ✅ |
| 资源、状态、时序、持久化、底部锚点单测 | ✅ |
| 深浅背景、60/120/200 px、动作联系表视觉检查 | ✅ |
| 当前源码 Universal Release、签名和双架构验证 | ✅（2026-08-23） |
| 双击展开主 App 的发布与正式安装 | ⬜ 尚未进行；当前正式安装仍为 v0.2.10 |

## 9. 仍需人工补验

以下项目在 `DEVELOPMENT.md` 中仍明确保留为人工检查，不应被后续 AI 误报为已经完全验证：

- 连接真实 Harness 后逐一触发非空闲状态，确认状态、气泡和动作匹配。
- 实际左右拖动，确认方向、反向切换、松手恢复和 60/120/200 px 手感。
- 菜单栏“显示/隐藏桌面宠物”。
- 沙盒环境下全局鼠标监视器与 `.hover` 点击穿透恢复。
- 空闲状态双击挥手；非空闲状态不应被挥手覆盖；两种皮肤都应展开主 App。
- 分别从 App 隐藏、主窗口最小化、主窗口关闭和其他 App 前台四种状态双击宠物，确认主窗口恢复并获得焦点。
- 多显示器增删、缩放或分辨率变化后的可见区回收。

## 10. 测试与视觉证据

宠物相关单元测试：

- `DeepSeek HarnessTests/MoodBallSettingsTests.swift`
  - 默认皮肤、持久化、范围钳制、颜色重置、位置和穿透文案。
- `DeepSeek HarnessTests/MoodBallModelTests.swift`
  - 状态映射、气泡、完成 transient、断连自定义颜色、双击动作与主窗口回调、显隐、气泡底部锚点。
- `DeepSeek HarnessTests/XiaoyuSpriteTests.swift`
  - mood 到图集 row、逐帧时长、播放策略、整行显示倍率、空闲挥手覆盖、拖拽方向阈值、奔跑循环、两张 Bundle 图集的尺寸/透明度/占用。

常用验证命令：

```sh
xcodebuild \
  -project "DeepSeek Harness.xcodeproj" \
  -scheme "DeepSeek Harness" \
  -destination "platform=macOS" \
  test
```

视觉证据位于 `docs/xiaoyu-pet/`：

- `XiaoyuContactSheet.png`：8 种状态联系表。
- `disconnected.gif`、`idle.gif`、`waiting.gif`、`authorizing.gif`、`questioning.gif`、`done.gif`、`failed.gif`、`wave.gif`：状态预览。
- `XiaoyuDragContactSheet.png`：左右奔跑联系表。
- `XiaoyuDragRight.gif`、`XiaoyuDragLeft.gif`：拖拽奔跑预览。

图像或动画每次有实质修改时，应重新执行独立视觉 QA。至少检查身份一致性、方向、帧序、头脸/衣服/鞋子、角色尺度、脚底基线、透明边缘、裁切、循环连贯性以及正常 App 尺寸下的观感。确定性尺寸/alpha 检查不能替代视觉检查。

## 11. 后续修改操作指南

### 修复状态或气泡 BUG

1. 先确认问题属于领域状态、`MoodBallModel` 映射、SwiftUI 布局还是 `NSPanel` frame。
2. 不要从 DOM 推断状态，也不要在视图内重建 reducer 逻辑。
3. 先补或更新 `MoodBallModelTests` / `panelFrame` 回归测试。
4. 同时检查气泡显示和隐藏两种情况下的屏幕底部锚点。

### 调整动画速度或循环

1. 只修改 `XiaoyuAnimation.frameDurations`、`playback` 或 `XiaoyuDragDirection.frameDuration`。
2. 保持 `renderInterval = 1/60`，不要用低频 Timeline 直接充当精灵 FPS。
3. 更新 `XiaoyuSpriteTests` 的精确时间边界测试。
4. 重新播放 GIF 或 App 动画检查离散帧节奏。

### 增加新的 Harness 状态动作

1. 先判断是否真的需要增加 `HarnessActivityState`；多数情况下只需新增呈现 mood，不应修改事件协议。
2. 定义 mood、颜色/气泡语义、动画 row、帧数、时序、播放策略和状态优先级。
3. 生成或提取完整动作行，保持身份锁和整行统一尺度。
4. 更新图集、Xcode resource、`XiaoyuAnimation`、映射测试、资源占用测试、README、`DEVELOPMENT.md` 和本文。
5. 做联系表、动画预览和独立视觉 QA，再构建安装。

### 替换或修复精灵资源

1. 使用原始 `spritesheet.webp` 作为身份和动作来源，但保持它不变。
2. 优先无重采样裁切；不要用逐帧 bbox 最大化。
3. 如果生成新动作，锁定脸、眼睛、头发、夹克、裤子、鞋子、比例和像素质感；禁止无关道具、文字、问号和脱离身体的效果。
4. 保证 PNG 为 RGBA、固定网格、使用格非空、未使用格透明。
5. 使用最近邻渲染、整行统一 scale 和底部 anchor。
6. 保留最终联系表、GIF、验证结果和视觉 verdict。

### 增加新的拖拽交互

1. 不要破坏全局坐标拖拽和抓取点偏移。
2. 明确交互覆盖哪些 mood、何时开始、何时恢复、锁定位置和始终穿透时如何处理。
3. 交互动画不得改变宠物视口、解剖尺度或气泡锚点。
4. 对方向阈值、覆盖优先级、释放恢复和资源行添加测试。

## 12. AI 修改前后检查表

修改前：

- 阅读本文、相关 Swift 文件、对应测试和 `DEVELOPMENT.md` Phase 7。
- 执行 `git status --short`，保留用户已有和无关的未提交文件。
- 判断要改的是状态、呈现、资源、窗口、交互还是设置，不跨层做重复逻辑。
- 涉及图片时遵守 `codex-pet-production-rules`；实际生成/装配使用 `hatch-pet`；每次视觉迭代执行 `visual-verdict`。

修改后：

- 状态映射、逐帧时序、资源尺寸/占用、持久化和 panel anchor 测试通过。
- 在 60、120、200 px 检查所有受影响姿势；气泡开/关各检查一次。
- 检查深浅背景、光晕开/关、断连透明度和自定义颜色。
- 检查拖拽、反向、松手恢复、位置记忆、锁定和三种点击穿透模式。
- 检查双击动作，以及隐藏、最小化、关闭、其他 App 前台时的主窗口恢复。
- 确认 App Bundle 同时包含 `XiaoyuSprites.png` 和 `XiaoyuDragSprites.png`。
- 运行完整测试和 Debug/Release 构建；需要安装时再验证签名、架构和实际启动。
- 按仓库 `AGENTS.md` 清理项目构建目录、相关 DerivedData 和临时构建目录；用户明确保留的 `/Applications/DeepSeek Harness.app` 不删除。
- 清理后执行：

```sh
mdfind "kMDItemCFBundleIdentifier == 'dev.deepseekharness.DeepSeekHarness'"
mdfind "kMDItemCFBundleIdentifier == 'dev.harnessdesktop.HarnessDesktop'"
```

- 同步更新本文的“最后核验日期”“已完成进度”“仍需人工补验”和验证数字。

## 13. 明确禁止的回归

- 不把 `running` 任务状态理解成角色奔跑；字面奔跑只用于左右拖拽资源。
- 不启用自动走动、巡逻、碰撞或鼠标视线跟随，除非用户明确提出新需求。
- 不让气泡改变宠物的屏幕底部位置。
- 不让不同姿势、气泡显隐或皮肤切换改变角色解剖尺度。
- 不对像素图使用平滑插值。
- 不逐帧按 bbox 缩放，不用裁切或放大掩盖源素材问题。
- 不在运行时依赖 `/Users/sundusk/Desktop/spritesheet.webp`。
- 不改写原始 WebP，不把 App 专用图集冒充 Codex Pet v2 安装包。
- 不用硬编码灰色覆盖 `settings.disconnectedColor`。
- 不让非空闲小雨的双击挥手遮盖工作、授权、提问、完成、失败或断连状态。
- 不为了宠物功能修改 `HarnessActivityState`、事件协议、Reducer 优先级或 completion transient，除非新需求明确要求并有相应领域设计。
