# livephoto 实验模式滚动编码缓存方案

## 1. 目标

为 `experimentalPreRoll` 模式提供一套基于滚动编码缓存的实现方案，替代原来的“原始像素帧深拷贝 + 后台统一导出” pre-roll 机制。

目标约束：

1. 设备目标：`iPhone 15 Pro`
2. 采集目标：`720p @ 30fps`
3. 时间窗口：`3s pre-roll + 1s post-roll`
4. 输出格式：`H.264 .mov`
5. 优先保证真实采样帧率接近 `30fps`
6. 不影响现有稳定模式

非目标：

1. 当前阶段不生成系统标准 Live Photo 配对资源
2. 当前阶段不支持音频
3. 当前阶段不处理多码率和多分辨率自适配

## 2. 现状问题

原实验模式使用 `RollingMediaBuffer` 缓存原始像素帧，问题在于：

1. 相机实际输出接近 `30fps`
2. pre-roll buffer 需要逐帧深拷贝 `CVPixelBuffer`
3. 性能瓶颈落在 CPU / 内存带宽 / RAM，而不是相机本身
4. 真机诊断已出现 `cam≈30`、`buf<30`

结论：

1. 当前瓶颈在“缓存原始帧”链路
2. 继续优化分配和池化只能提高上限，不能从架构上消除逐帧像素拷贝成本
3. 要稳定逼近真实 `30fps`，应把压力从“长期持有原始帧”转为“实时硬件编码”

## 3. 核心思路

实验模式改为：

1. 相机预览仍然使用 `AVCaptureSession`
2. 实验模式挂载 `AVCaptureVideoDataOutput`
3. 每帧到来后不再存原始 `CVPixelBuffer` 数组
4. 每帧尽快送入一条持续运行的 `AVAssetWriter` 编码链路
5. 编码结果写入滚动视频分片
6. 点击拍摄时，记录主图时刻，并基于分片时间轴裁出：
   - 前 `3s` pre-roll
   - 后 `1s` post-roll
7. 将裁出的片段拼成最终 `motion.mov`

一句话概括：

1. 旧方案：`先缓存原始帧，再统一导出`
2. 新方案：`先实时编码成滚动短视频，再按时间裁片段`

## 4. 当前落地架构

当前实现已经落地为以下模块：

1. `CameraSessionManager`
2. `RollingEncodedRecorder`
3. `RollingSegmentStore`
4. `ExperimentalClipAssembler`
5. `MomentCaptureCoordinator`
6. `MomentStore`

### 4.1 `CameraSessionManager`

职责：

1. 维持现有 session 配置
2. 实验模式下继续提供 `AVCaptureVideoDataOutput`
3. 将 sample buffer 转发给 `RollingEncodedRecorder`
4. 保留诊断统计：
   - camera callback fps
   - recorder accepted fps

当前注意点：

1. 视频输出回调不做像素级深拷贝
2. UI 上的 `availablePreRollSeconds` 目前代表观察窗口，不等于 finalized segment 总时长
3. 当前 `buf=` 统计仍是“样本送进 recorder 的频率”，不是最终编码写入 fps

### 4.2 `RollingEncodedRecorder`

这是实验模式的核心模块。

职责：

1. 持有一条实时编码链路
2. 接收视频 sample buffer
3. 将 sample buffer 直接写入当前活跃 segment
4. 按时间窗口维护滚动 segment 集合
5. 对外暴露：
   - 当前可用 pre-roll 秒数
   - 当前 segment 元数据
   - 拍摄时刻对应的时间锚点

当前关键设计：

1. 每个 segment 为一个独立 `.mov`
2. segment 建议时长：`1s`
3. 当前常驻保留窗口约 `4.5s`
4. 超出窗口后删除最旧 segment
5. 每个 segment 完成后立即可用于后续裁剪
6. 只有 `writer.status == .completed` 的 segment 才会注册进 store
7. 只有 `writer.status == .writing` 时才允许 finalize

为什么建议 `1s` 分片：

1. 实现简单
2. pre-roll 3 秒时最多只需拼接 3 到 4 个 segment
3. 删除旧数据成本低
4. 比单个超长滚动文件更容易做边界管理和失败恢复

### 4.3 `RollingSegmentStore`

职责：

1. 管理 segment 文件路径
2. 维护 segment 元数据索引
3. 负责 segment 生命周期清理

当前元数据结构：

1. `id`
2. `url`
3. `startWallClockTime`
4. `endWallClockTime`
5. `frameCount`
6. `nominalFrameRate`
7. `isFinalized`

当前约束：

1. 只有 finalized segment 才允许参与导出
2. 删除策略始终按时间顺序清理最旧 segment
3. 目录应放在 `tmp/rolling-cache/<session-id>/`

### 4.4 `ExperimentalClipAssembler`

职责：

1. 根据拍摄时刻选择涉及的 segment
2. 从各 segment 中裁出目标时间范围
3. 合并为最终 `motion.mov`

当前实现：

1. 使用 `AVMutableComposition`
2. 对每个命中的 segment 插入对应时间段
3. 最后统一 export 为单个 `.mov`
4. 如果 composition 为空，显式报 `emptyComposition`

裁剪范围：

1. `captureWallClockTime - 3s` 到 `captureWallClockTime`
2. `captureWallClockTime` 到 `captureWallClockTime + 1s`

导出结果要求：

1. 最终文件保持竖屏 transform
2. 时长允许略有浮动，但目标接近 `4s`
3. 若 pre-roll 不足 3 秒，则继续沿用当前“不足则拒拍”策略

### 4.5 `MomentCaptureCoordinator`

当前职责调整：

1. 不再向 `RollingMediaBuffer` 请求 pre-roll 原始帧
2. 改为向 `RollingEncodedRecorder` 查询当前可用 pre-roll 时长
3. 拍摄时记录 `captureWallClockTime`
4. 抓主图后等待约 `1s` post-roll
5. 通知 assembler 按时间裁片
6. 更新 `MomentStatus`

状态流保持不变：

1. `captured`
2. `processing`
3. `ready`
4. `failed`

## 5. 关键时序

### 5.1 空闲录制阶段

1. 进入实验模式
2. `RollingEncodedRecorder` 启动第一个 segment writer
3. 相机帧持续写入 segment
4. 每到 `1s` 边界，关闭当前 segment，开启下一个
5. 最旧 segment 超过保留窗口后删除

### 5.2 用户拍摄阶段

1. 用户点击拍摄
2. 记录 `captureWallClockTime`
3. 同步抓主图
4. 检查当前 pre-roll 是否已达到阈值
5. 等待 `1s` post-roll
6. 结束当前 segment 或等待其 finalized
7. 使用 assembler 裁出：
   - `captureTime - 3s`
   - `captureTime + 1s`
8. 拼成 `motion.mov`
9. 更新记录状态

### 5.3 失败兜底

任一节点失败时：

1. 标记 `MomentAsset` 为 `failed`
2. 保留主图
3. 删除本次最终导出临时文件
4. 滚动编码链路自动恢复到持续录制状态

## 6. 编码策略

建议初版参数：

1. codec：`H.264`
2. resolution：`1280 x 720`
3. fps：`30`
4. color format：沿用 camera sample buffer 输出
5. bitrate：先从中等码率开始，不追求极致压缩

原因：

1. `H.264` 兼容性最好
2. `iPhone 15 Pro` 对 `720p@30` 的硬件编码压力较小
3. 初版先证明“真实 fps 稳定”比压缩率更重要

## 7. 文件与目录建议

建议新增临时目录结构：

```text
tmp/
  rolling-cache/
    <session-id>/
      segment-0001.mov
      segment-0002.mov
      segment-0003.mov
      ...
```

规则：

1. 进入实验模式时创建 session 目录
2. 退出实验模式或页面销毁时清理目录
3. 若 App 异常中断，下次启动时清理过期目录

## 8. 验证结论

当前真机调试结论：

1. `iPhone 15 Pro` 上相机回调已经稳定在 `cam≈30`
2. 切换到滚动编码缓存后，实验模式链路已达到 `buf≈30`
3. 当前版本已验证可以正常保存并查看实验模式结果
4. 调试过程中曾出现的关键问题包括：
   - `markAsFinished` 在 `writer.status == .unknown` 时调用导致崩溃
   - `startWriting()` 放在 `isReadyForMoreMediaData` 判断之后导致没有任何有效 segment
   - failed segment 被注册进 store 导致后续导出失败

这些问题已在当前实现中修正。

## 9. 硬件消耗与瓶颈判断

### 8.1 相比原始像素帧缓存

滚动编码缓存：

1. 明显降低 RAM 占用
2. 明显降低内存带宽搬运压力
3. 更依赖硬件编码器与临时文件写入

### 8.2 新瓶颈

新方案的主要风险不再是 raw frame copy，而是：

1. writer 切 segment 的时序正确性
2. segment finalize 时的短暂空窗
3. 裁片与拼接边界误差
4. 临时文件 I/O

结论：

1. 对 `iPhone 15 Pro`，这条路的性能前景优于当前原始像素帧缓存
2. 主要复杂度在工程实现，而不是硬件算力不足

## 10. 风险点

### 9.1 Segment 边界抖动

问题：

1. 若拍摄时刻刚好落在 segment 切换点附近
2. 可能出现边界少帧或时间段对不上

当前处理：

1. segment 保留轻微重叠容忍
2. 裁片统一按 wall clock 映射到 asset time
3. 对 capture 时刻前后各增加少量容差，再在 composition 里精裁

### 9.2 Finalize 延迟

问题：

1. 点击拍摄后，最后一个 post-roll segment 可能尚未 finalize

当前处理：

1. `MomentCaptureCoordinator` 等待 post-roll segment finalize 完成
2. 继续保留 export timeout / watchdog

### 9.3 临时文件积累

方案：

1. 目录按 session 隔离
2. 页面退出清理
3. 启动时清理过期缓存目录

## 11. 当前限制

1. 当前只导出视频，不导出音频
2. 当前仍未生成标准 Live Photo 配对资源
3. `buf=` 诊断尚未改成真实编码写入 fps
4. 仍有若干 `Sendable` warning 未收敛

## 12. 实施状态

当前文档对应的核心步骤均已完成：

1. `RollingEncodedRecorder` 已实现并接入实验模式
2. `RollingSegmentStore` 已实现
3. `ExperimentalClipAssembler` 已实现
4. `MomentCaptureCoordinator` 已切到基于 clip plan 的实验模式闭环
5. 稳定模式保持独立，不受实验模式改动影响

## 13. 后续步骤

建议按以下顺序继续收尾：

1. 将 `buf=` 调试项改成真实编码写入 fps
2. 收紧 `availablePreRollSeconds` 的含义或文案，减少和 finalized segment 的认知偏差
3. 收敛 `Sendable` warning
4. 视需要补充导出后 nominal fps 自检
7. 真机验证完成后，再删除旧实验链路

## 11. 验证方案

真机验证至少覆盖：

1. 连续停留实验模式 30 秒以上，观察是否稳定生成 segment
2. 多次拍摄，确认最终输出 fps 接近 `30`
3. 连拍场景下确认不会卡死
4. 进入后台再回来，确认 recorder 状态可恢复或重建
5. 异常中断后重启，确认临时目录可清理

关键验收指标：

1. `camera fps ≈ 30`
2. `recorder accepted fps ≈ 30`
3. 导出文件 `nominalFrameRate ≈ 30`
4. pre-roll 可稳定达到 `3s`
5. 无明显预览卡死和持续内存上涨

## 12. 与现有方案的关系

这份文档只针对实验模式的新实现。

保持不变的部分：

1. 稳定模式继续使用 `AVCaptureMovieFileOutput`
2. `MomentStore` 状态流不变
3. 列表、详情、相册保存逻辑不要求同步重写

需要替换的部分：

1. 实验模式的 `RollingMediaBuffer` raw frame 缓存职责
2. `MomentVideoComposer` 的 pixel-buffer 级导出职责

最终预期：

1. 实验模式的核心从“内存帧缓存”切为“滚动编码缓存”
2. 性能瓶颈从 CPU / 内存带宽迁移到硬件编码与片段管理
3. 在 `iPhone 15 Pro` 上更有机会稳定达到真实 `30fps`

## 13. 面向当前工程的落地映射

本节只描述“当前工程里具体改哪些文件、加哪些文件”，用于直接指导实现。

### 13.1 保持不动的文件

初版尽量不动或少动：

1. [MomentStore.swift](/Users/ahs/Documents/codex_project/livephoto/livephoto/Services/MomentStore.swift)
2. [MomentListView.swift](/Users/ahs/Documents/codex_project/livephoto/livephoto/Views/MomentListView.swift)
3. [MomentDetailView.swift](/Users/ahs/Documents/codex_project/livephoto/livephoto/Views/MomentDetailView.swift)

原因：

1. 这些文件不决定实验模式的实时采样能力
2. 初版可以沿用最终 `motion.mov` 结果写入逻辑
3. 避免把技术改造扩散到列表与存储表现层

### 13.2 需要新增的文件

建议新增以下文件：

1. `livephoto/Camera/RollingEncodedRecorder.swift`
2. `livephoto/Camera/RollingSegmentStore.swift`
3. `livephoto/Camera/ExperimentalClipAssembler.swift`
4. `livephoto/Camera/RollingSegment.swift`

职责建议：

1. `RollingEncodedRecorder.swift`
   负责 segment writer 生命周期、sample buffer 写入、segment 切换
2. `RollingSegmentStore.swift`
   负责 segment 元数据集合、窗口裁剪、目录清理
3. `ExperimentalClipAssembler.swift`
   负责按拍摄时刻裁段与合并导出
4. `RollingSegment.swift`
   负责 segment 元数据结构定义

### 13.3 需要重写或大改的现有文件

1. [CameraSessionManager.swift](/Users/ahs/Documents/codex_project/livephoto/livephoto/Camera/CameraSessionManager.swift)
2. [MomentCaptureCoordinator.swift](/Users/ahs/Documents/codex_project/livephoto/livephoto/Camera/MomentCaptureCoordinator.swift)

改动方向：

1. `CameraSessionManager`
   - 实验模式下把 `CMSampleBuffer` 转发给 `RollingEncodedRecorder`
   - 不再依赖 `RollingMediaBuffer` 作为实验模式主缓存
2. `MomentCaptureCoordinator`
   - 不再读取 `BufferedMediaSnapshot`
   - 改为记录拍摄 wall clock 时间
   - post-roll 等待结束后请求 assembler 导出最终片段

### 13.4 需要降级或待废弃的文件

1. [RollingMediaBuffer.swift](/Users/ahs/Documents/codex_project/livephoto/livephoto/Camera/RollingMediaBuffer.swift)
2. [MomentVideoComposer.swift](/Users/ahs/Documents/codex_project/livephoto/livephoto/Camera/MomentVideoComposer.swift)
3. [VideoExportManager.swift](/Users/ahs/Documents/codex_project/livephoto/livephoto/Camera/VideoExportManager.swift)

建议策略：

1. 第一阶段先保留文件，避免一次性删改过大
2. `experimentalPreRoll` 切到新链路后，这三个文件只保留稳定模式兼容或作为旧实现 fallback
3. 验证完成后再决定是否删除旧实验路径

## 14. 实施分阶段计划

建议拆成五个可回归阶段，每个阶段都应可真机验证。

### 阶段 1：录制器骨架

目标：

1. 能在实验模式下持续写出 `1s` segment
2. 不接入拍摄按钮逻辑
3. 先证明 segment 本身能稳定 `30fps`

涉及文件：

1. 新增 `RollingEncodedRecorder.swift`
2. 新增 `RollingSegment.swift`
3. 修改 [CameraSessionManager.swift](/Users/ahs/Documents/codex_project/livephoto/livephoto/Camera/CameraSessionManager.swift)

验收标准：

1. 真机实验模式停留 10 秒以上
2. 临时目录出现连续 segment 文件
3. segment 的 `nominalFrameRate` 接近 `30`

### 阶段 2：segment 存储与清理

目标：

1. 维护最近约 `5~6s` 的 segment 窗口
2. 自动删除最旧 segment
3. 暴露当前可用 pre-roll 秒数

涉及文件：

1. 新增 `RollingSegmentStore.swift`
2. 修改 `RollingEncodedRecorder.swift`
3. 修改 [CaptureViewModel.swift](/Users/ahs/Documents/codex_project/livephoto/livephoto/ViewModels/CaptureViewModel.swift)
4. 修改 [CaptureView.swift](/Users/ahs/Documents/codex_project/livephoto/livephoto/Views/CaptureView.swift)

验收标准：

1. pre-roll 秒数能稳定涨到 3 秒以上
2. 缓存目录不会无限增长
3. 不出现旧 segment 清理后 writer 失效

### 阶段 3：裁段与导出

目标：

1. 给定一个 `captureWallClockTime`
2. 能从多个 segment 中裁出 `3s pre + 1s post`
3. 合成为一个最终 `motion.mov`

涉及文件：

1. 新增 `ExperimentalClipAssembler.swift`
2. 可能保留或替代 [VideoExportManager.swift](/Users/ahs/Documents/codex_project/livephoto/livephoto/Camera/VideoExportManager.swift)

验收标准：

1. 导出文件总时长接近 4 秒
2. 播放方向正确
3. 导出文件实际 fps 接近 30

### 阶段 4：接入拍摄流程

目标：

1. 拍摄按钮真正切到新实验链路
2. 主图抓拍、post-roll 等待、导出、状态更新形成闭环

涉及文件：

1. 大改 [MomentCaptureCoordinator.swift](/Users/ahs/Documents/codex_project/livephoto/livephoto/Camera/MomentCaptureCoordinator.swift)
2. 修改 [CameraSessionManager.swift](/Users/ahs/Documents/codex_project/livephoto/livephoto/Camera/CameraSessionManager.swift)
3. 少量调整 [CaptureViewModel.swift](/Users/ahs/Documents/codex_project/livephoto/livephoto/ViewModels/CaptureViewModel.swift)

验收标准：

1. `captured -> processing -> ready/failed` 状态流不变
2. 主图仍能可靠保存
3. 导出失败时不会卡死拍摄页

### 阶段 5：清理旧链路

目标：

1. 判断旧 raw-frame 实验链路是否还保留 fallback
2. 收敛调试字段与临时兼容代码

涉及文件：

1. [RollingMediaBuffer.swift](/Users/ahs/Documents/codex_project/livephoto/livephoto/Camera/RollingMediaBuffer.swift)
2. [MomentVideoComposer.swift](/Users/ahs/Documents/codex_project/livephoto/livephoto/Camera/MomentVideoComposer.swift)
3. [CaptureDiagnostics.swift](/Users/ahs/Documents/codex_project/livephoto/livephoto/Camera/CaptureDiagnostics.swift)

验收标准：

1. 不再同时维护两套复杂实验链路
2. 调试信息保留必要部分
3. 最终代码职责边界清晰

## 15. 当前推荐开工顺序

如果按最小风险推进，推荐从以下顺序开始：

1. 先实现 `RollingSegment` + `RollingEncodedRecorder`
2. 先不碰 `MomentCaptureCoordinator` 的主流程
3. 先让实验模式仅在后台滚动生成 segment
4. 先验证 segment 文件的真实 fps 是否稳定接近 30
5. 再实现 `RollingSegmentStore`
6. 再实现 `ExperimentalClipAssembler`
7. 最后替换实验模式拍摄闭环

这样做的原因：

1. 先验证“硬件编码缓存是否真能稳住 30fps”
2. 把性能验证和拍摄流程改造拆开
3. 一旦性能验证失败，可以低成本回退，而不是重写完整拍摄流程后才发现方向错误
