# 历史录音与转录稿联动

历史会议的转录稿上方显示录音播放器。支持播放/暂停、拖动真实采样波形、1/1.5/2 倍速、句子时间与词语点击跳转、当前位置高亮和转录稿跟随。手动滚动会暂停跟随，点击跟随按钮或主动跳转可恢复。

播放器参考 Mizzen Responses 实际使用的 `src/app/presentation/[slug]/components/VideoPlayer.tsx` 音频分支：60px 高浅灰容器、40px 灰色播放按钮、灰阶波形、蓝色游标、右侧时间与倍速。Arco 使用本地录音采样波形，并在末尾提供转录稿跟随按钮。

## 时间戳来源

| 当前供应商/模型 | 接入方式 | 精度边界 |
| --- | --- | --- |
| Deepgram Nova-3 | `alternatives[].words[].start/end`，秒转毫秒；保留说话人分组 | 供应商词级时间 |
| 豆包大模型流式识别 | `show_utterances=true`，读取 `utterances[].words[].start_time/end_time` | 按响应的字词单元保存；没有词时使用句级时间 |
| ElevenLabs Scribe v2 Realtime | `include_timestamps=true`，读取 committed timestamp 消息的 `words` | 供应商字词时间 |
| Nemotron Speech 3.5 本地模型 | FluidAudio 0.15.5 `finishWithTokenTimings()` | token 发射帧时间，约 80ms；子词不等于完整汉字/单词，也不是精确声学边界 |
| Whisper Tiny/Base/Small/Medium/Large v3 本地模型 | SwiftWhisper/whisper.cpp `token_timestamps`、`max_len=1`、`split_on_word` | 模型估计时间；正文重新合并，保留字词分段用于跳转 |

所有时间统一到会议起始点。云端重连、续录、本地 VAD 分段均加回音频偏移。新的隐藏 `arco-timing` JSON 注释保存时间与词语，保留旧 `arco` 注释兼容原有消费方。历史文件已有的句级时间仍可跳转；没有保存的词时间不会凭空补齐。

## 归档与播放器

`meeting_recording` 后端命令按会议 ID/转录路径查找归档，返回本地分片路径与会议相对起点。设置曾使用的归档根目录会保留索引。查找时忽略符号链接和不属于会议的归档。

播放器用 AVFoundation composition 串联编号 M4A 分片，按实际时间放置，裁掉相邻分片的编码尾部。分片被容量限制清理或文件损坏时，保留原时间轴并跳过缺口。切换会议或关闭面板会停止旧播放器和取消加载。

主应用允许链接 AVFoundation 来播放历史音频；捕获仍在独立 helper。边界检查继续禁止主应用使用 AVCaptureSession、AVAudioEngine、SCStream 等捕获入口。

## 验证

- Rust core：原有 190 项单测及新增的 Agent 上下文元数据过滤测试通过，覆盖时间单位、重连偏移、续录、旧注释解析、元数据转义、历史目录和清理过的分片。
- 本地 ASR：12 项 contract tests 通过；真实音频跑 Whisper Tiny 和 Nemotron，分别返回 22 和 37 个有时间戳的单元。其余 Whisper 大小共用适配路径，未逐个加载模型实测。
- AVFoundation contract：真实静音播放推进、暂停、倍速、边界/缺口跳转、波形采样、旧数据解码与生命周期通过。
- 录音归档 contract：AAC 编解码、分片时长、淘汰、符号链接和无效 PCM 检查通过。
- 云端供应商在本次通过解析测试与 helper 构建，未逐家发起真实云端识别会话。

构建产物位于 `build/Arco.app`，本机安装位于 `/Applications/Arco.app`；发布时分别验证版本与签名。界面自动化能读取测试窗口的按钮与词语链接，系统截屏/点击工具报 ScreenCaptureKit 错误，尚无成功的视觉验收截图。
