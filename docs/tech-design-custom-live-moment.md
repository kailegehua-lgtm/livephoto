# Screen Flicker Capture 技术方案

## 1. 目标

实现一套面向产线闪屏抓拍场景的 iOS 采集与导出方案，满足以下目标：

1. 在真机上提供稳定实时预览。
2. 在 `稳定模式` 下，保证主图和触发后 1 秒动态片段可靠落盘。
3. 在 `实验模式` 下，支持前 3 秒回溯、后 1 秒补录，并导出约 4 秒视频。
4. 动态效果允许后台处理完成后再开放查看。
5. 在整个过程中，预览主链路不能被视频拼接与导出拖垮。

默认运行参数：

- 设备目标：`iPhone 15 Pro`
- 分辨率：`1280x720`
- 帧率：`30fps`
- 实验模式回溯：`3秒`
- 实验模式补录：`1秒`

## 2. 总体架构

系统按双模式设计：

### 2.1 稳定模式

特点：

1. 预览优先。
2. 使用 `AVCapturePhotoOutput` 生成主图。
3. 使用 `AVCaptureMovieFileOutput` 录制触发后 1 秒动态片段。
4. 不在预览期间常驻运行原始帧 ring buffer。

用途：

1. 产线可用性验证。
2. 稳定兜底模式。
3. 作为实验模式迭代时的回退路径。

### 2.2 实验模式

特点：

1. 切换模式后才启用 `AVCaptureVideoDataOutput`。
2. 使用低帧率轻量 ring buffer 缓存前 3 秒视频帧。
3. 触发时冻结历史帧，再补录后 1 秒帧。
4. 使用 `AVAssetWriter` 将前后片段合成为本地 mp4/mov。

用途：

1. 验证“前 3 秒 + 后 1 秒”是否具备业务价值。
2. 为后续正式的 ring buffer 抓拍方案积累实现路径。

## 3. 核心设计原则

### 3.1 预览优先

这是最高优先级约束：

1. `AVCaptureVideoPreviewLayer` 必须保持流畅。
2. 所有重活都不能挂在主线程。
3. 实验模式的 ring buffer 采样必须与稳定模式隔离。
4. 导出和落盘只能在后台串行队列中进行。

### 3.2 处理延迟可接受

允许：

1. 点击拍摄后先生成主图和列表记录。
2. 后台完成动态视频导出。
3. 导出完成后再开放播放。

这与系统原生 Live Photo 的体验一致，即：

1. 拍摄反馈立即出现。
2. 动态效果不是瞬时可用。

### 3.3 双轨架构不能互相污染

要求：

1. 稳定模式代码路径尽量固定。
2. 实验模式引入的新采集管线不能常驻。
3. 切回稳定模式后必须移除实验模式的额外 output 和缓存状态。

## 4. 模块拆分

### 4.1 `CameraSessionManager`

职责：

1. 配置 `AVCaptureSession`
2. 管理 camera input / audio input
3. 管理 `AVCapturePhotoOutput`
4. 管理 `AVCaptureMovieFileOutput`
5. 按模式动态挂载/卸载 `AVCaptureVideoDataOutput`
6. 提供预览层所需 session
7. 管理 FPS、曝光等设备级参数

要求：

1. session 配置与切换放在独立 `sessionQueue`
2. 模式切换时只做必要的 output 变更
3. 不能因为实验模式逻辑影响稳定模式默认预览

### 4.2 `RingBufferController`

职责：

1. 维护最近 3 秒视频帧
2. 控制最大缓存数量
3. 提供拍摄时刻的只读快照
4. 提供 reset / purge

要求：

1. 默认只缓存视频，不缓存音频
2. 使用 YUV420 `CMSampleBuffer`
3. 低帧率采样，例如 6fps 或按配置控制
4. 以时间戳为依据淘汰旧帧
5. 必须有固定容量和内存上限

### 4.3 `MomentCaptureCoordinator`

职责：

1. 接收拍摄命令
2. 按模式分发不同拍摄策略
3. 协调主图、历史帧冻结、后续帧收集和导出
4. 更新记录状态

要求：

1. 稳定模式与实验模式完全分开实现
2. 同一时刻只允许一个 capture 任务
3. 拍摄失败时至少保留主图

### 4.4 `VideoExportManager`

职责：

1. 接收历史帧和 post-roll 帧
2. 用 `AVAssetWriter` 输出视频文件
3. 统一做时间轴重映射
4. 处理导出状态和错误回调

要求：

1. 独立串行 `exportQueue`
2. 不阻塞预览和采集队列
3. 输出 H.264 或 HEVC
4. 支持失败回收临时文件

### 4.5 `MomentStore`

职责：

1. 保存主图
2. 保存动态视频
3. 保存元数据
4. 持久化记录状态
5. 加载列表数据

### 4.6 `PlaybackCoordinator`

职责：

1. 判断记录是否可播放
2. 驱动详情页长按播放
3. 在视频缺失时降级

## 5. 采集链路设计

## 5.1 Session 默认配置

默认配置：

1. `AVCaptureSession`
2. `sessionPreset = .hd1280x720`
3. 视频输入：后置广角摄像头
4. 音频输入：默认麦克风
5. 视频帧率：目标 `30fps`
6. 视频像素格式：`kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`

说明：

1. 禁止使用 BGRA 作为长期缓存输入格式。
2. `iPhone 15 Pro` 硬件能力足以支持 720p/30fps。
3. 是否开启音频参与导出可后续配置，第一版实验模式可以先只做视频。

## 5.2 设备参数控制

需要开放：

1. `activeVideoMinFrameDuration`
2. `activeVideoMaxFrameDuration`
3. 曝光时间锁定
4. ISO 锁定

原因：

1. 抓闪屏时，需要尽量减少摄像头自动曝光带来的抹平效应。
2. 需要为产线后续调试不同屏幕刷新率预留空间。

## 6. 稳定模式技术路径

## 6.1 目标

目标是让预览和拍摄闭环尽可能稳定。

## 6.2 处理流程

1. 进入拍摄页。
2. `CameraSessionManager` 启动 session。
3. 只挂载 `PhotoOutput + MovieFileOutput`。
4. 用户点击拍摄。
5. 立即抓主图。
6. 同时录制后 1 秒视频。
7. 主图优先写入记录。
8. 视频文件完成后关联到记录。
9. 导出完成后记录变为 `ready`。

## 6.3 优势

1. 预览最稳。
2. 导出链路简单。
3. 适合先跑通数据闭环。

## 6.4 局限

1. 没有 pre-roll。
2. 不满足最终业务目标。

## 7. 实验模式技术路径

## 7.1 目标

实现前 3 秒回溯、后 1 秒补录。

## 7.2 启用方式

只有当用户切到实验模式时：

1. `CameraSessionManager` 才挂载 `AVCaptureVideoDataOutput`
2. `RingBufferController` 才开始缓存视频帧

切回稳定模式时：

1. 移除 `VideoDataOutput`
2. 清空 ring buffer

## 7.3 Ring Buffer 策略

第一版策略：

1. 目标采样帧率低于预览帧率，例如 6fps
2. 缓存窗口为 3 秒
3. 最大帧数约 18 帧
4. 只保留视频

原因：

1. 先验证回溯行为
2. 控制内存与预览影响
3. 降低 `CMSampleBuffer` 深拷贝成本

## 7.4 触发流程

1. 用户点击拍摄。
2. 读取 ring buffer 快照。
3. 立即抓主图。
4. 开始收集后 1 秒 video sample buffer。
5. 结束后得到：
   - pre-roll snapshot
   - post-roll snapshot
   - still photo
6. 将 pre-roll 和 post-roll 交给 `VideoExportManager`
7. 后台输出约 4 秒视频
8. 导出完成后记录状态变为 `ready`

## 7.5 时间轴处理

导出时必须：

1. 取 pre-roll 的最早时间作为导出起点
2. 将所有 sample buffer 的 `presentationTimeStamp` 平移到从 `0` 开始
3. 确保后续帧时间戳严格递增

否则 `AVAssetWriter` 很容易写失败。

## 8. 导出方案

## 8.1 输出格式

第一版建议：

1. 容器：`.mov` 或 `.mp4`
2. 编码：H.264
3. 分辨率：跟随 720p 采集

说明：

1. 工厂复判和 CV 处理优先考虑通用性。
2. H.264 兼容性更稳。

## 8.2 后台导出

导出要求：

1. 不能运行在主线程
2. 不能运行在视频采集队列
3. 只能运行在独立串行导出队列

建议流程：

1. 拍摄后立即创建记录，状态为 `captured`
2. 提交后台导出任务
3. 导出开始后记录更新为 `processing`
4. 导出成功更新为 `ready`
5. 导出失败更新为 `failed`

## 9. 数据模型

建议 `MomentAsset` 至少包含：

1. `id`
2. `createdAt`
3. `photoURL`
4. `videoURL`
5. `captureMode`
6. `status`
7. `preDuration`
8. `postDuration`
9. `coverTimestamp`
10. `duration`
11. `width`
12. `height`

状态建议：

1. `captured`
2. `processing`
3. `ready`
4. `failed`

## 10. 页面交互策略

## 10.1 拍摄页

要求：

1. 显示模式切换
2. 显示当前模式说明
3. 拍摄后立即反馈
4. 若处于实验模式，提示预览可能较慢

## 10.2 列表页

要求：

1. 显示封面图
2. 显示模式标签
3. 显示状态标签
4. 处理中记录也要可见

## 10.3 详情页

要求：

1. 默认显示主图
2. 只有 `ready` 状态才允许播放动态片段
3. `processing` 状态显示处理中提示
4. `failed` 状态显示失败提示

## 11. 内存与性能护栏

这是方案成败的关键。

### 11.1 必须遵守

1. YUV420 输入，禁止 BGRA
2. 所有高频帧处理包裹 `autoreleasepool`
3. Ring buffer 固定容量
4. 触发后立即冻结快照，不允许缓存无限增长
5. 导出完成或失败后清理临时文件

### 11.2 风险点

1. `CMSampleBuffer` 深拷贝过多
2. 预览期间常驻 `VideoDataOutput`
3. 导出与采集争抢 CPU
4. 大数组频繁 `removeFirst`

### 11.3 降级策略

若实验模式影响明显，可按顺序降级：

1. 降低实验模式缓存采样帧率
2. 缩短回溯时长
3. 缩短 post-roll
4. 临时关闭实验模式，回退稳定模式

## 12. 可借鉴的外部模块

GitHub 上没有现成成熟的“闪屏回溯抓拍”产线方案，但以下模块值得参考：

1. `NextLevel`
   参考相机会话组织、设备控制和输出管理
2. `HaishinKit`
   参考实时采集、编码队列和高频 buffer 管理
3. Apple AVFoundation 示例
   参考底层 `AVAssetWriter` 和时间轴处理

需要自研的部分：

1. Ring buffer
2. 触发冻结机制
3. 前后片段拼接
4. 状态机与后台导出
5. OOM 护栏

## 13. 当前实现状态

截至当前版本：

1. 稳定模式已验证可用：
   - 预览稳定
   - 记录可入列表
   - 详情可播放
2. 实验模式已接入第一版独立采集路径
3. 实验模式仍需继续验证：
   - 预览影响程度
   - 导出成功率
   - 回放时长是否符合预期

## 14. 下一步实施顺序

建议按以下顺序推进：

1. 给记录增加完整状态机
2. 真机验证实验模式：
   - 预览可接受性
   - 列表是否新增
   - 详情是否能回放约 4 秒
3. 根据实测结果优化：
   - ring buffer 采样率
   - 导出耗时
   - 内存峰值
4. 再决定是否升级到更重的压缩缓存方案
