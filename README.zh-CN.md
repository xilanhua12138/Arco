# Arco

[English](./README.md) | **中文**

![Arco — 会议即实时上下文](./assets/banner.png)

一个 [agent skill](https://agentskills.io)：监听会议，并在本地磁盘上持续维护一份
**带说话人标注的实时转写**——这样你就能让你的 AI 助手总结要点、提取待办事项、
或回答刚才会上聊到的问题，而且全部基于真实的原话。它适用于任何支持本地 shell
访问的 skill 运行环境（Claude Code，或任何遵循 Agent Skills 标准的 agent）。

它会同时采集**系统音频**（电话/会议另一端的人）和你的**麦克风**，混音后送入
[Deepgram](https://deepgram.com) 的实时语音转文字（开启说话人分离 diarization）。
每一行都会被打上 `Speaker 1 / Speaker 2 / Speaker 3…` 标签，写入一个 Claude Code
可以直接读取的 Markdown 文件。

仅支持 macOS——采集端基于 ScreenCaptureKit 构建，所以**不需要**安装 BlackHole
之类的虚拟音频设备。

## 为什么做这个

我经常在通话过程中想问 Claude「等等，他们刚才说想要什么来着？」，但从会议笔记
App 里复制粘贴太笨拙了。Arco 直接把转写放在 Claude 本来就能访问的文件里。不用切
App，也不用往通话里拉一个会议机器人。

## 工作原理

```
recorder (Swift)                                         listen.py
ScreenCaptureKit 系统音频 + AVAudioEngine 麦克风
混音/重采样 → 16k 单声道 PCM ──stdout│stdin──────────► Deepgram 实时 ASR
                                                           (diarize=true)
                                                                │
                                          实时追加 ◄────────────┘
                           ~/.claude/meeting-transcripts/current.md
```

- `recorder.swift` 通过 ScreenCaptureKit 抓取系统输出、通过 AVAudioEngine 抓取
  麦克风，把两路混音/重采样成 16 kHz 单声道 PCM，并把裸字节写到 stdout。
- `listen.py` 把这路音频通过 WebSocket 送进 Deepgram，并把每一句最终结果追加到
  转写文件里。
- 你的 AI 助手在你提问时随时读取 `current.md`。

## 安装

clone 到你的 skills 目录（Claude Code 是 `~/.claude/skills/`）：

```bash
git clone https://github.com/xilanhua12138/Arco.git ~/.claude/skills/arco
```

你需要：

- macOS（版本要新到支持 ScreenCaptureKit 麦克风采集）
- Swift 工具链（`swiftc`——随 Xcode / Command Line Tools 一起提供）
- [`uv`](https://docs.astral.sh/uv/)（它会按需拉取 `websockets`，不用手动 `pip install`）
- 一个 Deepgram API key——**注册账号即送 $200 免费额度**，足够用很久（见下方「成本估算」）

初始化 checkout：

```bash
cd ~/.claude/skills/arco
bash bin/init.sh
# 如果 init.sh 创建了 .env 或提示缺少 key，编辑 .env 填入你的 DEEPGRAM_API_KEY
bash bin/init.sh
```

`init.sh` 会检查本地工具链、在需要时创建 `.env`、把 `ARCO_MIC_DEVICE_ID` /
`ARCO_MIC_DEVICE_NAME` 刷新为当前 macOS 默认麦克风、预装 Python 的 `websockets`
依赖，并编译/签名 recorder。初始化之后第一次执行 `start.sh` 时，macOS 会请求
**屏幕录制**和**麦克风**权限——两个都要授予。命令行的 `recorder` 二进制有时需要
你手动在 *系统设置 → 隐私与安全性 → 屏幕录制* 里勾选；勾一次，然后重新启动即可。

## 使用

```bash
bash bin/start.sh both     # 系统音频 + 麦克风（默认）
bash bin/start.sh system   # 只录通话另一端
bash bin/start.sh mic      # 线下面对面会议，只录麦克风

bash bin/mic-id.sh --write-env  # 把当前默认麦克风 ID 刷新进 .env
bash bin/status.sh         # 查看是否在运行 + 最近几行转写
bash bin/stop.sh           # 停止
```

运行期间，转写文件位于 `~/.claude/meeting-transcripts/current.md`，逐行更新。你可
以直接问你的 AI 助手「总结一下目前为止的会议内容」或「他们让我后续跟进什么？」，
它会去读这个文件。

当你告诉 Claude 会议结束（或要求一份最终总结）时，skill 会自动停止监听——不会在
后台继续录音。每次会话都保存为 `meeting-<时间戳>.md`；`current.md` 始终指向最新
的一份。

## 配置

`.env`（参见 `.env.example`）：

| 变量 | 默认值 | 说明 |
|----------|---------|-------|
| `DEEPGRAM_API_KEY` | — | 必填 |
| `DEEPGRAM_MODEL` | `nova-3` | Deepgram 模型 |
| `DEEPGRAM_LANG` | `zh-Hans` | 简体中文；英文会议用 `en` |

关于模型：在我的测试里，`nova-3` 配 `zh-Hans` 的中文效果远远最干净。`nova-2`/`zh`
会出现乱码字符，`nova-3`/`multi` 则完全解码错了中文。英文会议请设置
`DEEPGRAM_LANG=en`。

## 成本估算：$200 免费额度能用多久？

Deepgram 注册账号就送 **$200 免费额度**，之后才转为按量付费（pay-as-you-go）。

Arco 会把系统音频和麦克风混成**单独一路** 16k 单声道音频流送给 Deepgram，所以是
**按一条流计费**，不是两条。按 Nova-3 实时流式（streaming）的按量价格估算：

| 模式 | 单价 | 每天 4 小时（240 分钟）成本 | $200 能用 |
|------|------|------------------------------|-----------|
| **Nova-3 单语言**（默认 `zh-Hans` 或 `en`） | $0.0048/分钟 | 240 × $0.0048 = **$1.152/天** | **约 173 天（≈ 5.7 个月）** |
| Nova-3 多语言（`multi`） | $0.0058/分钟 | 240 × $0.0058 = $1.392/天 | 约 143 天（≈ 4.8 个月） |

换句话说，按默认配置**每天开 4 小时会议/交流，$200 大约能撑半年左右**才需要充值。
单价数据来自 [Deepgram 官方定价页](https://deepgram.com/pricing)，价格可能随官方调整
而变化，请以官网为准。

## 一些值得知道的点

- **别把系统输出静音。** Arco 抓的是输出流，所以如果你这边把通话静音了，就没东西
  可采集。
- **说话人分离需要一点时间稳定。** 一次会话最开始的一两个字可能会被标错，因为
  Deepgram 的 diarizer 还在「热身」。
- **构建产物不入库。** `recorder` 是本地编译的（`bin/build.sh`），所以被 gitignore
  了。改完 `recorder.swift` 后要重新编译。
- **用 Deepgram，不用豆包。** 豆包的说话人分离只存在于它的离线文件识别 API 里，
  流式接口没有，所以它没法实时区分说话人。Deepgram 在一条 WebSocket 里就搞定了。

## 许可证

MIT——见 [LICENSE](./LICENSE)。
