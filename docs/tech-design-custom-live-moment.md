# livephoto 技术方案

## 1. 目标

实现一套 App 内动态照片方案，支持：

1. 稳定模式：主图 + 后 1 秒动态片段
2. 实验模式：前 3 秒滚动编码回溯 + 后 1 秒补录
3. 列表浏览、详情播放、批量删除、批量保存到系统相册

默认目标环境：

- 设备：`iPhone 15 Pro`
- 分辨率：`720p`
- 预览目标帧率：`30fps`

## 2. 总体架构

当前架构分为两条拍摄链路：

### 2.1 稳定模式

使用：

1. `AVCapturePhotoOutput`
2. `AVCaptureMovieFileOutput`

特点：

1. 不常驻原始帧缓存
2. 主图优先
3. 后 1 秒动态视频后台补齐
4. 预览最稳

### 2.2 实验模式

使用：

1. `AVCapturePhotoOutput`
2. `AVCaptureVideoDataOutput`
3. `RollingEncodedRecorder`
4. `RollingSegmentStore`
5. `ExperimentalClipAssembler`

特点：

1. 只在实验模式挂载 `AVCaptureVideoDataOutput`
2. 目标是真实 `30fps` 采样与编码
3. 使用滚动 `.mov` 分片覆盖 `3s pre-roll + 1s post-roll`
4. 拍摄后在后台裁片并合成最终视频

## 3. 核心模块

### 3.1 `CameraSessionManager`

职责：

1. 管理 `AVCaptureSession`
2. 配置 camera / audio input
3. 配置 `PhotoOutput / MovieFileOutput / VideoDataOutput`
4. 管理模式切换
5. 对外暴露：
   - `authorizationState`
   - `onVideoSampleBuffer`
   - `onRollingBufferUpdated`

关键设计：

1. `sessionQueue` 负责 session 配置和启停
2. 只有实验模式才挂载 `AVCaptureVideoDataOutput`
3. 视频像素格式固定为 `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`
4. 相机 active format 显式选到 `1280x720 @ 30fps`

### 3.2 `RollingEncodedRecorder`

职责：

1. 接收实验模式视频 sample buffer
2. 维护实时编码链路
3. 将 sample buffer 写入当前活跃 segment
4. 暴露当前可用 pre-roll 秒数
5. 根据拍摄墙钟时间生成 `RollingClipPlan`

当前实现关键点：

1. segment 时长当前约 `1s`
2. 缓存窗口当前约 `4.5s`
3. 首帧会先 `startWriting()` / `startSession()`，再判断 input ready 状态
4. 只有 `writer.status == .writing` 时才允许 `markAsFinished()`
5. 只有 `writer.status == .completed` 的 segment 才会注册进 store

### 3.3 `RollingSegmentStore`

职责：

1. 管理实验模式滚动 segment 文件
2. 维护 segment 元数据索引
3. 清理超过保留窗口的旧文件

关键设计：

1. segment 目录位于 `tmp/rolling-cache/<session-id>/`
2. 只保留 finalized segment 参与后续导出
3. 当前清理窗口约 `4.5s`

### 3.4 `ExperimentalClipAssembler`

职责：

1. 根据 `RollingClipPlan` 选取目标 segments
2. 用 `AVMutableComposition` 裁出目标时间片段
3. 导出单个最终 `motion.mov`

当前实现关键点：

1. 以拍摄墙钟时间映射 segment 局部时间
2. 沿用 segment 原始视频轨和 transform
3. 如果 composition 最终没有任何可插入内容，明确报 `emptyComposition`
4. 只导出视频，不导出音频

### 3.5 `MomentCaptureCoordinator`

职责：

1. 接收拍摄命令
2. 编排稳定模式与实验模式的完整流程
3. 管理 `MomentStatus`
4. 管理 timeout / watchdog / `processingPhase`

实验模式关键流程：

1. 查询 `RollingEncodedRecorder.availableDuration`
2. 判断 pre-roll 是否满足阈值
3. 抓主图
4. 记录入库为 `captured`
5. 继续收集约 1 秒 post-roll
6. 生成 `RollingClipPlan`
7. 调用 `ExperimentalClipAssembler` 导出
8. 更新为 `ready` 或 `failed`

当前诊断补充：

1. `processingPhase` 会标记 `experimental:failed:segments / empty / session / timeout / other`
2. 用于区分“无有效 segment”和“导出 session 失败”等问题

### 3.6 `MomentStore`

职责：

1. 持久化 `MomentAsset`
2. 保存主图和视频文件
3. 更新 `index.json`
4. 删除记录和本地目录

关键设计：

1. `MomentStore` 负责主线程状态发布
2. `MomentFileWorker` actor 负责文件 IO
3. 文件写入、视频复制、删除不阻塞主线程

### 3.7 `MomentListView`

职责：

1. 展示历史记录
2. 支持普通浏览模式
3. 支持选择模式
4. 批量删除和保存到系统相册

当前保存策略：

1. 保存封面图
2. 若记录为 `ready`，同时保存视频
3. 不生成系统标准 Live Photo 资源对

## 4. 状态机

### 4.1 记录状态

`MomentAsset.status`：

1. `captured`
2. `processing`
3. `ready`
4. `failed`

约束：

1. 新建记录先进入 `captured`
2. 后台处理开始后进入 `processing`
3. 成功进入 `ready`
4. 任一失败进入 `failed`

### 4.2 拍摄页状态

拍摄页通过 `CaptureViewModel` 绑定：

1. 拍摄中状态
2. 后台处理中提示
3. 实验模式当前已缓存秒数
4. 导出阶段号
5. 错误文案

## 5. 时间轴策略

### 5.1 旧问题

此前实验模式存在三个关键问题：

1. 用 sample buffer 的时间戳判断 pre-roll 时长，预缓存会卡在约 2 秒
2. 直接持有原始 `CVPixelBuffer`，导致 buffer pool 被占满
3. 真实相机输出接近 `30fps`，但 raw-frame buffer 链路只能拿到约 `18~23fps`

### 5.2 当前方案

当前统一使用墙钟时间：

1. 衡量实验模式当前已观察到的 pre-roll 窗口
2. 计算当前可用 pre-roll 秒数
3. 生成拍摄时刻对应的 clip 目标区间
4. 将目标区间映射到各 segment 的局部时间并裁片

## 6. 导出策略

### 6.1 稳定模式

1. 使用 `AVCaptureMovieFileOutput`
2. 录制后 1 秒动态视频
3. 视频落盘后更新记录为 `ready`

### 6.2 实验模式

1. 使用滚动 `AVAssetWriter` 生成短 segment
2. 拍摄后使用 `AVMutableComposition` 拼接目标时间片段
3. 输出 H.264 `.mov`
4. 若失败，清理临时文件并把记录标成 `failed`

### 6.3 导出方向

当前已处理视频方向问题：

1. sample buffers 以传感器横屏坐标输出
2. segment 保持 writer 输入 transform
3. 合成时沿用首个有效 track 的 `preferredTransform`
4. 详情页和系统相册播放方向正确

## 7. 权限

当前涉及权限：

1. `NSCameraUsageDescription`
2. `NSMicrophoneUsageDescription`
3. `NSPhotoLibraryAddUsageDescription`

权限状态：

1. `unknown`
2. `authorized`
3. `denied`
4. `restricted`
5. `unsupported`
6. `unavailable`

## 8. 异步与容错

关键高风险点：

1. `capturePhoto`
2. `stopRecording`
3. 实验模式 segment finalize
4. 实验模式 clip plan / composition 导出
5. 文件落盘

当前机制：

1. photo timeout
2. recording timeout
3. export timeout
4. processing watchdog
5. 失败时状态落到 `failed`
6. 空 segment 和非 completed segment 不进入后续导出链路

## 9. 相册保存能力

列表页支持多选后：

1. 删除本地记录
2. 保存到系统相册

当前实现说明：

1. 保存到系统相册时是“照片 + 视频”
2. 不是系统标准 Live Photo 配对资源
3. `ready` 状态才会导出视频到系统相册

## 10. 当前限制

1. 实验模式当前只导出视频，不导出音频
2. 当前不生成标准 Live Photo
3. 相册保存是照片与视频分开资源
4. UI 显示的 `availablePreRollSeconds` 代表观察窗口，不等价于“已经 finalized 的 segment 总时长”
5. 仍有若干 `Sendable` warning 与部分 AVFoundation 弃用 warning 未收敛，但不影响当前运行

## 11. 后续可选方向

1. 将底部 `buf=` 从“送进 recorder 的回调 fps”改成“真实编码写入 fps”
2. 删除前确认
3. `全选 / 取消全选` 交互优化
4. 真正的标准 Live Photo 资源生成
5. 实验模式支持可配置的 pre-roll / post-roll 时长
