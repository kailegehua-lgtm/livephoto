# CODEX.md

本文件用于指导 Codex / AI 编程助手理解并维护当前 `livephoto` iOS 项目。  
本项目不是硬件检测 App，而是一个围绕“抓拍主图 + 生成动态片段”的 **Live Photo 风格拍摄应用**。

---

## 1. 项目定位

项目当前的核心目标：

1. 使用相机实时预览完成拍摄。
2. 抓取一张主图作为封面。
3. 生成与主图对应的短视频片段。
4. 将素材落盘并在列表中可回看。
5. 让失败、处理中、完成三类状态都可见且可诊断。

当前代码可以概括为两条链路：

- 稳定模式：拍主图后继续保留约 1 秒 post-roll 视频片段。
- 实验模式：利用 rolling buffer 回溯约 3 秒 pre-roll，再补 1 秒 post-roll 合成片段。

项目最重要的要求是：

1. 拍摄链路不能卡死。
2. AVFoundation 回调异常时必须有兜底。
3. UI 不能长时间停留在无反馈状态。
4. 主线程不能被采集、编码、文件操作阻塞。
5. 已保存的 `MomentAsset` 状态必须可追踪、可恢复、可落盘。

---

## 2. 当前架构认知

修改代码前，先按当前职责边界理解项目：

- `livephoto/ViewModels/CaptureViewModel.swift`
  负责拍摄页状态绑定、用户动作转发、错误文案展示。
- `livephoto/Camera/CameraSessionManager.swift`
  负责相机权限申请、`AVCaptureSession` 配置、输入输出管理、sample buffer 分发。
- `livephoto/Camera/MomentCaptureCoordinator.swift`
  负责一次完整拍摄流程的编排，包括拍照、录制、超时、后台处理、导出状态落库。
- `livephoto/Services/MomentStore.swift`
  负责 `MomentAsset` 持久化、目录结构、封面图和视频文件写入。
- `livephoto/Models/MomentAsset.swift`
  负责拍摄模式、资源状态和存储模型定义。

除非明确要求，否则不要打破这些职责边界。

---

## 3. Codex 工作原则

### 3.1 不允许盲目大范围重构

除非用户明确要求，否则不要：

- 重写整条拍摄链路
- 随意改动 UI 层级
- 将 ViewModel、Coordinator、Store 的职责揉在一起
- 为了“更优雅”改掉现有状态流转
- 删除已有失败兜底、超时或临时状态

优先做最小、可验证、可回归的修改。

### 3.2 先分析，再修改

遇到 bug 或行为异常时，至少先说明：

1. 问题现象是什么。
2. 影响的是哪条链路：稳定模式、实验模式、落盘、列表展示还是预览。
3. 最可能卡在哪个异步节点。
4. 是否涉及权限、AVFoundation 回调、后台导出或文件写入。
5. 修复策略是什么。

不要跳过原因分析直接改代码。

### 3.3 每次修改后必须输出

每次完成修改后，必须说明：

- 修改了哪些文件
- 每个文件改了什么
- 为什么这样改
- 如何验证
- 是否存在风险
- 是否需要真机验证

---

## 4. 核心状态约束

当前项目虽然不是硬件检测，但同样不允许中间状态无止境悬挂。

### 4.1 `MomentStatus` 必须单向收敛

当前资源状态：

```swift
enum MomentStatus: String, Codable {
    case captured
    case processing
    case ready
    case failed
}
```

必须遵守以下原则：

1. 新建 moment 后先进入 `captured`。
2. 后台处理开始后进入 `processing`。
3. 导出成功后进入 `ready`。
4. 任一中间步骤失败后进入 `failed`。
5. 不允许长期停留在 `captured` 或 `processing` 无后续结果。

### 4.2 UI 状态也必须能退出

例如：

- `isCapturing`
- `isBackgroundProcessing`
- `errorMessage`
- `authorizationState`

出现异常时必须回收状态，不能让按钮、提示文案或 loading 一直挂住。

### 4.3 异步流程必须有 watchdog / timeout 思维

当前项目中以下节点都属于高风险异步点：

- `AVCapturePhotoOutput.capturePhoto`
- `AVCaptureMovieFileOutput.startRecording / stopRecording`
- 实验模式导出合成
- 文件写入和视频复制

任何新增异步节点，如果系统 API 存在不回调、慢回调或失败后状态不一致的可能，必须补 timeout 或失败兜底。

---

## 5. 相机与采集链路要求

### 5.1 权限处理必须完整

涉及相机和麦克风时，至少要考虑：

- `notDetermined`
- `denied`
- `restricted`
- `authorized`
- `simulator unsupported`

不能只处理“允许 / 拒绝”两种结果。

### 5.2 `AVCaptureSession` 相关操作不要阻塞主线程

以下工作应继续留在专用队列或后台任务：

- session 配置
- session 启停
- sample buffer 处理
- 视频导出
- 文件复制和删除

不要把这些逻辑迁回主线程。

### 5.3 预览和采集链路必须可释放

页面退出或流程中断时，要确保：

- session 可以停止
- 临时录制文件不会无限堆积
- sample buffer 累积不会无限增长
- continuation 不会因为异常路径永久悬空

---

## 6. 两种拍摄模式的专项要求

### 6.1 稳定模式

稳定模式的目标是：

- 主图优先成功
- 后续 1 秒视频后台补齐
- 即使视频失败，也尽量保留主图和失败状态

修改这条链路时，必须保证：

1. 主图成功后应尽快创建 `MomentAsset`。
2. 后台处理失败不能把已保存的主图一起丢掉。
3. `stopRecording()` 没有返回时要有 timeout。
4. 状态流转仍然是 `captured -> processing -> ready/failed`。

### 6.2 实验模式

实验模式依赖 `RollingMediaBuffer` 和后续导出合成，风险更高。

修改这条链路时，必须重点检查：

1. pre-roll 样本数量不足时是否明确失败。
2. post-roll 收集开始和结束是否成对。
3. sample buffer 深拷贝是否必要且开销可控。
4. 导出超时后是否能正确标记 `failed`。
5. 失败时是否清理临时输出。

不要为了“实验效果”牺牲稳定模式的可靠性。

---

## 7. 存储与数据一致性要求

### 7.1 `MomentStore` 修改必须保持索引和文件一致

当前存储结构是：

```text
Documents/Moments/
  index.json
  <UUID>/
    cover.jpg
    motion.mov
```

修改持久化逻辑时，必须保证：

1. `index.json` 可反序列化。
2. `MomentAsset` 字段兼容已有数据。
3. `cover.jpg` 和 `motion.mov` 的写入顺序清晰。
4. 视频拷贝失败不会造成模型状态假成功。

### 7.2 模型变更必须考虑兼容性

如果修改 `MomentAsset` 或 `CaptureMode`：

- 必须考虑旧 `index.json` 的解码兼容
- 新增字段优先提供默认值或兼容分支
- 不要随意改已有 raw value

---

## 8. 错误处理要求

### 8.1 不允许只抛出模糊错误

错误需要尽量区分来源，例如：

- 权限未授权
- 相机不可用
- 主图数据为空
- 视频录制失败
- 导出超时
- 文件写入失败
- 实验模式样本不足

### 8.2 用户可见错误与内部错误要分层

对用户展示的文案要简洁明确。  
内部实现需要保留足够上下文，方便后续加日志或诊断。

不要把底层系统错误原样直接堆给 UI，也不要把所有错误都压成同一句“拍摄失败”。

---

## 9. 并发与线程规则

### 9.1 主线程只处理 UI 与主状态

适合放在主线程 / `@MainActor` 的内容：

- `@Published` UI 状态更新
- 列表展示数据同步
- 用户触发后的状态提示

不适合放在主线程的内容：

- `AVCaptureSession` 配置
- 录制等待
- sample buffer 累积
- 视频合成导出
- 大文件读写

### 9.2 continuation 和 task 必须成对收口

如果修改以下实现，必须检查异常路径是否也能 resume / cancel：

- `photoContinuation`
- `recordingContinuation`
- `backgroundHintTask`
- processing watchdog

不允许保留永远不结束的 continuation。

### 9.3 避免引入高风险阻塞写法

避免在关键线程使用：

```swift
DispatchQueue.main.sync { }
Thread.sleep(forTimeInterval:)
DispatchSemaphore.wait()
while true { }
```

如果必须在串行队列上 `sync`，要先解释不会死锁的前提。

---

## 10. 日志与诊断建议

当前项目里日志体系还不重，但后续修改应按可诊断方向推进。

至少应能定位这些节点：

- 权限状态
- session 是否启动
- 拍照是否回调
- 录制是否开始
- 录制是否停止
- 导出是否开始
- 导出是否成功或超时
- `MomentStatus` 如何变化
- 文件是否落盘成功

如果新增日志，优先记录：

- moment id
- capture mode
- 当前步骤
- 耗时
- 错误原因

不要只打一行没有上下文的 `print("failed")`。

---

## 11. 测试与验证要求

当前项目偏重真机链路，很多问题无法只靠模拟器发现。

### 11.1 修改后至少给出验证步骤

例如：

1. 打开拍摄页并授权相机、麦克风。
2. 在稳定模式下拍摄，确认列表出现新条目。
3. 检查新条目是否从 `captured/processing` 收敛到 `ready` 或 `failed`。
4. 切到实验模式，确认不足样本、导出失败、正常成功三类行为是否符合预期。
5. 退出页面再进入，确认 session 可恢复。

### 11.2 能补单元测试时优先补

适合抽象和测试的部分：

- 状态流转
- `MomentStore` 持久化
- 模型兼容解码
- timeout / watchdog 收敛逻辑

纯 AVFoundation 真机行为如果不易覆盖，至少补手动验证路径。

---

## 12. Bug 修复流程

当用户提供 bug 时，Codex 应按以下流程处理：

```text
1. 阅读问题现象
2. 确认影响范围：预览、拍照、录制、导出、落盘、列表展示
3. 找出最可能卡住的异步节点
4. 检查是否缺 timeout / watchdog
5. 检查状态是否没有收口
6. 检查主线程是否被阻塞
7. 检查文件和索引是否不一致
8. 给出修复方案
9. 修改代码
10. 给出验证步骤
```

---

## 13. 给 Codex 的问题模板

当需要修 bug 时，用户应尽量提供以下信息：

```markdown
## 问题现象

例如：点击拍摄后，列表里一直显示处理中，没有变成可播放。

## 复现步骤

1. 打开 App
2. 进入拍摄页
3. 选择稳定模式 / 实验模式
4. 点击拍摄
5. 观察预览页和列表页状态

## 设备环境

- Device:
- iOS Version:
- App Version:
- Build:
- 是否真机:

## 相关日志或报错

粘贴 Xcode 控制台输出、导出错误、文件写入错误或状态异常信息。

## 期望结果

例如：拍摄后应在有限时间内进入 ready，失败时应明确显示 failed 和原因。

## 修复要求

- 不要大范围重构
- 先定位根因
- 优先保证状态能收敛
- 必要时补 timeout / watchdog
- 给出验证步骤
```

---

## 14. 代码风格要求

优先使用清晰、稳定、方便诊断的代码。

要求：

- 命名清晰
- 状态流转明确
- 错误原因可读
- 避免魔法数字
- timeout 时间使用常量
- UI 和采集逻辑分离
- 文件写入与模型更新顺序清楚
- 对现有兼容逻辑保持谨慎

---

## 15. 输出格式要求

Codex 每次完成任务后，必须输出：

```markdown
## 根因分析

说明导致问题的原因。

## 修改内容

- 文件 A：修改了什么
- 文件 B：修改了什么

## 验证方式

1. 如何手动验证
2. 是否能运行自动化测试
3. 是否需要真机验证

## 风险说明

说明是否影响稳定模式、实验模式、持久化或列表展示。
```

---

## 16. 特别注意

本项目的目标不是“偶尔拍成功”，而是：

> 成功、处理中、失败、权限拒绝、导出超时、样本不足，都必须有明确结果。

任何一次拍摄都不允许让用户长期停在无反馈状态。
