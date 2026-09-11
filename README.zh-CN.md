<div align="center">
  <img src="docs/images/arco-app-icon.png" alt="Arco" width="112">

  <h1>Arco</h1>

  <p><strong>让会议成为你 Mac 上本地 Agent 的实时上下文。</strong></p>

  <p>
    Arco 是一款面向 macOS 的本地优先、AI Native 会议助手。它把带说话人标签的实时转写
    放在 Codex 或 Claude 旁边，让你在会议仍在进行时提问、挑战观点或找回关键决定。
  </p>

  <p><strong>macOS 14+</strong> · 本地优先 · 开源 · MIT</p>

  <p><a href="./README.md">English</a> · <strong>简体中文</strong></p>

  <p>
    <a href="https://github.com/xilanhua12138/Arco/releases"><strong>下载 macOS 应用</strong></a>
    · <a href="#开发">从源码构建</a>
  </p>
</div>

## 为什么做 Arco

大多数会议工具先录制，再让你会后回顾。Arco 面向的是会议中的即时需求：*对方刚才真正要的是什么？还有什么没解决？哪个假设值得挑战？*

它不是另一个托管聊天机器人，而是你 Mac 上原本就在使用的 Codex 或 Claude。它默认以实时转写为依据，只在你主动附加时读取所选项目工作区。

只要本地 CLI 已登录你的 Codex 或 Claude 订阅，Arco 就直接使用你已有的订阅额度。Agent 功能不需要额外订阅 Arco AI，也不需要配置 OpenAI 或 Anthropic API Key。

## 下载 macOS 应用

从 [GitHub Releases](https://github.com/xilanhua12138/Arco/releases) 下载最新 Apple Silicon `.dmg`，打开后把 `Arco.app` 拖到“应用程序”文件夹。Arco 需要 macOS 14 或更高版本。

当前预览版使用本地开发签名，尚未经过 Apple 公证。第一次启动时，请按住 Control 点击 `Arco.app`，选择**打开**并确认一次。凭证保存在受本机文件权限保护的本地文件中，正常使用不再请求钥匙串授权。安装包已经包含录音器、云转写 helper 和本地转写 worker；Whisper、Nemotron 和说话人分离模型只会在你进入**设置 → 聆听与记录 → 识别**并主动选择后下载。

## 邀请 Arco 入会

> **v0.3.25 已提供。** 以下为应用真实截图：使用合成语音进行演示会议，展示实时转写、实际生成的回答和已连接的参会悬浮窗。

邀请 Arco 和你一起听会，支持线上、线下和混合会议。系统音频接收远端发言，物理麦克风拾取现场声音。Arco 默认安静，每轮被点名后再用语音回应；涉及会议内容的问题，会交给能读取当前转写的 Codex 或 Claude Agent。

<p align="center">
  <img src="docs/images/arco-invite-meeting.jpg" alt="演示会议的实时转写、Arco 生成的发布安排总结，以及邀请入会入口" width="1000">
  <br>
  <sub>演示讨论被实时转写，Arco 根据发言整理发布安排，并指出尚未安排负责人的权限测试。</sub>
</p>

点击邀请后，Arco 出现在独立置顶的参会卡片中。Aura 动效采用 [LiveKit Agents UI 官方着色器](https://github.com/livekit/components-js/blob/main/packages/shadcn/components/agents-ui/agent-audio-visualizer-aura.tsx)，移植到原生 Metal，呈现聆听、思考和语音播放状态。

<p align="center">
  <img src="docs/images/arco-voice-participant.png" alt="Arco 已连接并正在聆听，独立 Aura 悬浮窗与会议转写、问答面板同屏显示" width="1000">
  <br>
  <sub>演示会议中的实际应用窗口：Arco 语音参会时，仍可同时查看转写和问答。</sub>
</p>

| 操作 | 结果 |
| --- | --- |
| 开始聆听 | 开始转写，不自动邀请 Arco。 |
| 邀请 Arco 入会 | 弹出参会窗并连接语音；尚未录音时，开启新的当前会议。 |
| 点击「Arco 已入会」 | 找回同一个悬浮窗，不重复连接，也不会误触离会。 |
| 收起悬浮窗 | Arco 继续参会，可从会议页面重新打开。 |
| 请 Arco 离会 | 自动关窗、停止语音、恢复麦克风，转写继续。 |
| 停止聆听或退出 Arco | 结束录音与语音参会，恢复麦克风。 |

只有卡片顶部标题区域可以拖动，位置会被记住。打开历史不会自动邀请 Arco，从历史页邀请也不会把新音频追加到旧记录。

**让远端参会者也听见 Arco。** 开发版通过 BlackHole 2ch 混合你的物理麦克风与 Arco 回复。首次引导时可提前配置音频组件，也可以跳过，之后在设置补齐。在飞书入会前或会议中的麦克风菜单选择一次**与系统一致**，之后 Arco 入会时会自动切换系统输入，离会时恢复。未配置时，回复在本机播放。邀请过程中不会突然要求安装驱动。

Arco 通过本机音频采集与路由参与会议，不会作为独立机器人出现在飞书参会名单里。发给会议的麦克风混音不包含远端系统声音，避免把对方的声音直接送回去。

## 实时上下文，而不是另一个会议仪表盘

Arco 把转写作为证据层，把 Agent 固定在右侧。系统音频与房间麦克风始终分离，因此混合会议可以区分 `远程 N` 和 `现场 N`，也不会把一整条音频通道误认为某一个人。

<p align="center">
  <img src="docs/images/arco-live-agent.png" alt="Arco 实时转写与 Agent 工作区" width="1000">
</p>

## 不离开当前对话，直接提问

你可以只参考本次转写，也可以通过 macOS 原生文件夹选择器附加一个项目工作区。Arco 会为后续问题复用该工作区，并通过这台 Mac 上已登录的 Codex CLI 或 Claude Code 发起请求。监听期间，录音控制与 Agent 会跨应用和 macOS Space 保持在最上层，让你无需离开当前对话就能提问、停止录制或回到转写证据。

<p align="center">
  <img src="docs/images/arco-in-meeting.png" alt="覆盖在当前桌面上的 Ask Arco 全局浮窗与录音控制" width="900">
</p>

## 真正有用的本地会议历史

会议可以先以未命名状态开始，随时手动改名，也可以由 Agent 在内容足够时生成标题，并在结束后自动生成总结。文字问答自动随会议保留。会议历史支持搜索并保存在本地。独立笔记功能已移除，已有笔记文件仍可从数据与隐私设置中打开。

<p align="center">
  <img src="docs/images/arco-history.png" alt="Arco 本地会议历史" width="1000">
</p>

## Arco 能做什么

| 功能 | 工作方式 | 价值 |
| --- | --- | --- |
| 混合会议采集 | 使用 ScreenCaptureKit 与 AVAudioEngine，分别采集系统音频和房间麦克风。 | 同一场会议里的线上和现场发言都清晰可辨。 |
| 流式转写 | 可选择 Deepgram、豆包、ElevenLabs，或本地 Nemotron / Whisper 模型。 | 自由权衡识别质量、延迟与隐私。 |
| 多说话人分离 | 独立选择 Deepgram、豆包，或本地 Streaming Sortformer、Pyannote + WeSpeaker、LS-EEND，在每条音频通道内增量分离匿名说话人。 | 一个麦克风可能听到多人，Arco 不会把整条麦克风通道标记为“你”。 |
| 本地原生 Agent | 调用 Mac 上已经安装并登录的 Codex CLI 或 Claude Code。 | 会议助手可以使用你已经信任的账号和项目理解。 |
| GPT Live 实时语音（Beta） | 在设置中主动开启语音 Beta，通过 OAuth 连接 ChatGPT，再从会议中启动语音会话。点击「邀请 Arco 入会」打开独立参会窗。 | 可以直接说出问题并听取简短回答；涉及会议进度的问题会交给读取当前转写的 Agent。 |
| 显式上下文 | 每次问题都包含会议转写；用户可以在输入框里明确附加一个工作区。 | 更广的上下文是可见且主动选择的，不会从无关目录里猜测。 |
| 原生会话连续性 | 每场会议、每个 Provider 和上下文边界都绑定准确的 Codex / Claude session。 | 后续问题保持连续，但不会通过 `--last` 误选其他对话。 |
| 自动会议产出 | 内容足够后生成标题，会议结束后生成总结；两类 Prompt 都可配置。 | 无需会前命名或手动记笔记，也能得到可复用的会议记录。 |
| 围绕会议讨论 | 随来源会议回看文字问答，也可复制回答到其他工具。 | 继续推敲想法，无需单独保存。 |
| 本地历史 | 以 Markdown 转写和本地 sidecar 存储，位置可自定义。 | 记录可迁移、可搜索，并始终由用户控制。 |

## 隐私

Arco 本地优先并完全开源。默认数据位置：

```text
~/Library/Application Support/Arco/
```

- 可随时自定义转写保存位置，旧位置仍会保留在历史记录中。
- 历史笔记文件会保留，可从数据与隐私设置打开原目录。
- 默认将会议音频压缩为 AAC/M4A，保存在 `~/Music/Arco/Recordings`，容量上限为 10 GB。可在**设置 → 数据与隐私 → 保存会议录音**中关闭，只保留转写。达到上限时清理最早的 Arco 音频片段，不删除转写和纪要。详见[录音存储说明](docs/features/recording-audio-storage.md)。
- 使用本地转写和说话人分离时，语音处理留在 Mac 上。
- 使用 Deepgram 时，音频会发送给 Deepgram 完成转写。
- 使用豆包进行转写或说话人分离时，音频会发送给豆包语音；两项都选择豆包时复用同一条流式识别与自动说话人分离链路。
- 使用 ElevenLabs 进行转写时，音频会发送给 ElevenLabs；可搭配其他流式说话人分离供应商。
- Deepgram、豆包语音和 ElevenLabs 凭证均由 Rust 后端验证，分别保存在 `~/.arco/credentials.json` 中（目录权限 `700`、文件权限 `600`），不会写入转写或日志。
- Agent 问题通过所选的本地 CLI 发送；输入框会始终显示当前使用的是“仅转写”还是“转写 + 工作区”。
- Codex 的转写与工作区模式会额外受到 macOS 只读沙箱保护。
- GPT Live 是默认关闭、需要主动开启的 Beta 功能。只有主动开启语音会话后，Arco 才会把当前会议音频发送给 OpenAI；结束语音会话或停止会议会断开连接。收起参会窗会保持语音连接，点击**离会**才会结束。
- GPT Live 的 ChatGPT OAuth 凭证单独保存在 `~/.arco/credentials.json` 中，不读取 Codex CLI 的登录信息。当前 Beta 依赖未公开的 ChatGPT 后端接口，部分账号可能不可用，上游改动也可能使它失效。

## 开发

### 从源码构建所需环境

- macOS 14 或更高版本
- 本地模型推荐 Apple Silicon
- Rust 与 Xcode/Swift 6 工具链
- Agent 功能需要 Codex CLI 或 Claude Code

### 从源码运行

```bash
git clone https://github.com/xilanhua12138/Arco.git
cd Arco
./native/build-recorder.sh
./native/build-deepgram-transcriber.sh
./native/build-elevenlabs-transcriber.sh
./native/build-doubao-transcriber.sh
./native/build-local-transcriber.sh
ARCO_BUILD_PROFILE=debug ARCO_SKIP_CODESIGN=1 ./native/build-native-app.sh
open build/Arco.app
```

生成与预览版 Release 相同的本地 ad-hoc 签名压缩包：

```bash
./native/package-local-app.sh
```

安装镜像与校验文件位于 `artifacts/Arco-macos-<arch>.dmg` 和 `artifacts/Arco-macos-<arch>.dmg.sha256`。未来面向普通用户的正式版本会补充 Developer ID 签名与 Apple 公证。

使用 Deepgram 时，只需进入**设置 → 聆听与记录 → 识别**，粘贴 Key 并点击**验证并保存**。Arco 会通过 Deepgram 的[官方认证接口](https://developers.deepgram.com/guides/fundamentals/authenticating)完成验证，再保存到 `~/.arco/credentials.json`。本地模型保存在 `~/Library/Application Support/Arco/models/`。

## 原来的 Agent Skill 仍然保留

Arco 最初是一个轻量 Agent Skill，现在已经成长为完整桌面应用。原来的 [`SKILL.md`](./SKILL.md)、命令行脚本与独立 listener 仍然保留在同一仓库中，偏好 Skill 工作流的用户可以继续使用。

```bash
git clone --depth 1 --filter=blob:none --no-checkout \
  https://github.com/xilanhua12138/Arco.git ~/.claude/skills/arco
cd ~/.claude/skills/arco
git sparse-checkout init --no-cone
git sparse-checkout set \
  /SKILL.md /.env.example /listen.py /recorder.swift /bin/
git checkout
bash bin/init.sh
```

这个 sparse checkout 只会下载 Agent Skill 实际使用的文件，不会拉取桌面应用源码。

具体命令和要求见 [`SKILL.md`](./SKILL.md)。桌面应用也会只读加载已有的 `~/.claude/meeting-transcripts/` 历史记录，不会覆盖原文件。

## 验证源码

```bash
cargo test --manifest-path rust/arco-core/Cargo.toml
cargo build --manifest-path rust/arco-core/Cargo.toml --lib
swift build --package-path macos/ArcoNativeUI
swift run --package-path macos/ArcoNativeUI ArcoNativeUIContractTests
swift run --package-path macos/ArcoNativeUI ArcoPreferencesContractTests
swift run --package-path macos/ArcoNativeUI ArcoLocalizationContractTests
ARCO_BUILD_PROFILE=debug ARCO_SKIP_CODESIGN=1 ./native/build-native-app.sh
./native/package-local-app.sh
```

## 技术架构

- **SwiftUI**：呈现主工作区、历史、设置、Onboarding、录音 HUD、全局 Agent 窗口以及全部 Liquid Glass 表面和控件。AppKit 只负责原生窗口/面板生命周期、全局快捷键和系统选择器。
- **Rust staticlib + C ABI**：在 Arco 主进程内负责存储、采集编排、凭证、Provider 路由、Agent 生命周期与原生 session 绑定。
- **受管 worker 进程**：录音器、云转写 helper、FluidAudio/SwiftWhisper/Nemotron 本地链路与主 UI 进程隔离，避免模型崩溃或内存峰值直接带崩界面。Codex 与 Claude 仍是外部 CLI 进程。
- **Markdown + 原子 JSON sidecar**：将转写证据与 Agent 回答分开存储。问答随会议保留；历史笔记文件仍可在设置中打开。

详细约束见 [PRODUCT.md](./PRODUCT.md)、[DESIGN.md](./DESIGN.md)、[docs/ARCHITECTURE.md](./docs/ARCHITECTURE.md) 与 [docs/TRANSCRIPTION.md](./docs/TRANSCRIPTION.md)。

## 致谢

特别感谢 [FluidVoice](https://github.com/altic-dev/FluidVoice) 展示了高速、隐私友好、完全在设备端运行的 macOS 语音体验，并为 Arco 的本地模型与 Provider 设计提供了重要启发。FluidVoice 仅是设计启发边界：Arco 没有复制或分发其 GPL-3.0 源码，主程序也没有链接 FluidVoice 库。Arco 直接依赖的 FluidAudio 与 SwiftWhisper 只存在于隔离的本地转写 worker 中；完整依赖与许可证边界详见 [docs/TRANSCRIPTION.md](./docs/TRANSCRIPTION.md)。

## 参与贡献

欢迎提交 Issue 和 Pull Request。较大的产品或架构改动，建议先开 Issue 对齐行为与隐私边界。

## License

Arco 使用 [MIT License](./LICENSE)。

第三方组件保留各自许可。Aura 着色器移植自 LiveKit Agents UI / Unicorn Studio，保留上游 Polyform Non-Resale 声明，详见[第三方声明](macos/ArcoNativeUI/Sources/ArcoNativeUI/Resources/Aura/NOTICE.md)。
