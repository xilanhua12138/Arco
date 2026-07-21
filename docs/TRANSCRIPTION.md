# Transcription provider contract

Arco supports online, in-person, and hybrid meetings without pretending that an audio channel is a person. Cloud and on-device engines are peers behind one capture contract.

## Provider boundary

The SwiftUI settings store persists one validated config with independent ASR and diarization providers:

```swift
struct TranscriptionConfiguration: Codable {
    var asr: ASRConfiguration
    var diarization: DiarizationConfiguration
}
```

The concrete enums preserve the existing provider/model values: Deepgram `nova-3`, Doubao `bigmodel`, ElevenLabs `scribe-v2-realtime`, local Nemotron/Whisper variants, Deepgram or Doubao diarization, the four local diarizers, and `none`. Language remains `auto`, `zh-CN`, or `en-US`.

Rust validates each provider/model pair independently and resolves a pipeline through a `TranscriberCatalog`. Each worker definition owns its executable, fixed arguments, credential requirement, and readiness timeout. The capture manager does not know inference APIs: it starts the resolved workers in owned process groups, supplies the live PCM stream, and waits for every one-use ready-file.

The local worker has two deliberately smaller boundaries: `LocalTranscriptionProvider` for Nemotron/Whisper and a standalone streaming diarization runner for FluidAudio. If both selections are local, Arco fuses them in one worker process and loads their models once. In a mixed pipeline, the ASR side reads the shared streaming speaker timeline while the diarization side updates it. Model status, download, removal, and inference are separate commands, so capture never silently downloads models or mutates its model set.

## Process and memory isolation

Swift statically links `libarco_core.a` and calls it through Arco's C ABI. That library contains the control plane and shared Rust provider support code, but provider streaming executes in owned helpers and the heavy local speech frameworks are absent from both `Arco` and `libarco_core.a`.

| Process | Contains | Failure boundary |
|---|---|---|
| `Arco` | SwiftUI/AppKit UI + in-process Rust control plane | Product state, windows, storage, and orchestration |
| `recorder` | ScreenCaptureKit + AVAudioEngine | Audio capture callbacks and PCM production |
| Rust cloud helpers | Deepgram, Doubao, or ElevenLabs streaming client | Provider stream, reconnect, and bounded audio queue |
| `arco-local-transcriber` | FluidAudio, SwiftWhisper/whisper.cpp, Nemotron, VAD, and local diarizers | Model loading, inference, native crashes, and model-memory pressure |
| `codex` / `claude` | User-installed external CLI | Agent request and provider-native session |

The Rust control plane starts helpers in exact owned process groups and retains their PIDs. Recording becomes visible only after every selected worker emits its ready signal. Stop, startup timeout, provider failure, app shutdown, or a worker crash targets that process tree; exiting `arco-local-transcriber` lets macOS reclaim its complete address space and loaded model memory. A local-engine crash or out-of-memory kill therefore fails the active capture contract without directly crashing the SwiftUI process. Arco does not keep a hidden persistent model host after capture ends.

FluidVoice is not an executable or library dependency and is not statically linked into `Arco`. It informed the product/model matrix only. Arco directly depends on Apache-2.0 FluidAudio and MIT SwiftWhisper inside `arco-local-transcriber`, never inside the main app or `libarco_core.a`.

## Capture layout

The Swift recorder emits standard interleaved 16-bit little-endian PCM at 16 kHz:

```text
frame 0: system[0], mic[0]
frame 1: system[1], mic[1]
…
```

- Channel 0 is system output, typically remote participants.
- Channel 1 is the selected room microphone, which may contain one or many local participants.
- Both FIFOs advance on the same 100 ms clock. A missing side is zero-filled and the wire format never switches to mono midstream.
- Each Swift source FIFO has a hard three-second ceiling. If a device callback outruns the mixer for that long, Arco keeps the freshest frames and drops the oldest rather than allowing unbounded memory growth.

For `system` mode the mic channel is silent. For `mic` mode the system channel is silent. The product presents these as Online, In-person, and Hybrid meeting scenarios. The scenario and transcription config remain fixed until the meeting stops.

The provider composition is explicit:

| ASR | Diarization | Runtime layout |
|---|---|---|
| Deepgram | Deepgram | One fused Deepgram stream |
| Doubao | Doubao | One fused Doubao stream with automatic speaker separation |
| Local | Local | One fused local process |
| Any provider | Off | One ASR worker |
| Different providers | Deepgram, Doubao, or local | Two workers; bounded PCM fan-out plus one shared streaming speaker timeline |

Mixed local/remote use works in both directions. For example, ElevenLabs ASR can use local Sortformer or Doubao speaker separation, and local Whisper can use Deepgram diarization. A remote provider selected for either role receives meeting audio and may incur its normal usage cost, even when the other role stays on-device.

## On-device ASR

The bundled Swift local-transcriber worker provides:

| Model | Runtime | Intended use |
|---|---|---|
| Nemotron Speech 3.5 Streaming | FluidAudio + Core ML/Apple Neural Engine | Lowest-latency multilingual local path |
| Whisper Tiny | SwiftWhisper/whisper.cpp | Smallest and fastest Whisper option |
| Whisper Base | SwiftWhisper/whisper.cpp | Lightweight general use |
| Whisper Small | SwiftWhisper/whisper.cpp | Balanced accuracy and speed |
| Whisper Medium | SwiftWhisper/whisper.cpp | Higher accuracy with greater memory/latency |
| Whisper Large v3 | SwiftWhisper/whisper.cpp | Highest-quality, heaviest Whisper option |

Each stereo channel has an independent stateful Silero VAD stream through FluidAudio's Core ML `VadManager`. The meeting profile keeps 200 ms speech padding, requires 500 ms before an utterance is persisted, finalizes after 600 ms of model-confirmed silence, and force-splits continuous speech at 30 seconds so noise or a long monologue cannot grow the ASR buffer without bound. The worker incrementally consumes the live stream, transcribes finalized utterances, and writes the shared Markdown adapter with audio-relative start/end metadata. Nemotron uses its token timing envelope; Whisper preserves its returned segment timings. Arco currently persists finalized local segments rather than exposing unstable interim text.

Models live under `~/Library/Application Support/Arco/models/`. Every local ASR model has the shared Silero VAD Core ML bundle as a required dependency; `prepare` installs it through the same visible model-progress flow, while `stream` loads it in offline mode and fails clearly if the bundle is missing or corrupt. Capture never downloads VAD implicitly. Whisper downloads are staged, checked against their exact expected byte size, and atomically moved into place. Nemotron, Silero VAD, Sortformer, Pyannote + WeSpeaker, and LS-EEND use FluidAudio's model manifests/caches plus Arco-owned installation checks or markers. Each local worker emits its ready signal only after its selected models are loaded.

The local worker depends directly on Apache-2.0 FluidAudio and MIT SwiftWhisper. FluidVoice informed the product/model matrix, but its GPL-3.0 source is not copied into Arco and no FluidVoice artifact is linked into the main program.

## On-device streaming speaker separation

Local speaker separation offers four explicit FluidAudio backends:

| Model | Intended use | Speaker slots per source |
|---|---|---:|
| Streaming Sortformer | Stable identities for typical meetings | 4 |
| Pyannote + WeSpeaker (experimental) | Familiar segmentation + embedding pipeline with rolling speaker memory | Dynamic |
| LS-EEND Meeting (AMI) | Meetings with overlap or quiet speech | 4 |
| LS-EEND General (DIHARD3) | Complex rooms and larger groups | 10 |

Sortformer uses the palettized `fastV2_1` model on CPU + Neural Engine. Pyannote + WeSpeaker runs a five-second Core ML window every two seconds: the oldest two seconds are finalized and the overlapping three-second edge remains revisable. LS-EEND uses the 100 ms streaming variants on CPU. Arco creates one diarizer timeline per active source channel while sharing the loaded model weights.

Each backend returns finalized history plus a revisable tentative edge. Arco appends only new finalized intervals and replaces the tentative edge on every update, avoiding stale-hypothesis double counting. The standalone diarizer atomically publishes a versioned timeline for both channels as the meeting continues. A separate ASR worker waits up to 1.5 seconds for timeline coverage for each finalized segment, then chooses the speaker slot with the greatest temporal overlap. It never waits until capture stops to rewrite the transcript.

Local workers have a five-minute readiness ceiling and the capture remains visibly `Starting` until every selected worker is ready. Once ready, diarization consumes the live stream incrementally. A future persistent local-model service could keep the diarizer warm across meetings and amortize that per-process load, but it must remain an independently terminable process with explicit memory and crash isolation.

The identity key remains `(channel, speaker)`:

```text
(channel 0, speaker 0) → Remote 1
(channel 0, speaker 1) → Remote 2
(channel 1, speaker 0) → In room 1
(channel 1, speaker 1) → In room 2
```

A slot is not a durable human identity, and the same human heard through both sources can receive two labels. A segment containing a rapid speaker switch is currently assigned to its dominant speaker; word-level local speaker splitting is a later refinement.

## Deepgram streaming request

Deepgram remains the migration-safe default. When selected for both roles, it uses one request with word-level diarization:

```text
wss://api.deepgram.com/v1/listen
  ?model=nova-3
  &language=zh-Hans
  &encoding=linear16
  &sample_rate=16000
  &channels=2
  &multichannel=true
  &diarize_model=latest
  &punctuate=true
  &smart_format=true
  &endpointing=300
```

When Deepgram is ASR-only, Arco omits `diarize_model` and attributes finalized segments from the selected external timeline. When Deepgram is diarization-only, it keeps word-level diarization enabled, publishes those intervals to the timeline, and does not write a second transcript. Therefore local ASR plus Deepgram diarization does send audio to Deepgram.

Arco maps the UI's automatic-language choice to Deepgram's streaming multilingual value, `language=multi`; it never sends the unsupported literal `language=auto`.

Use `diarize_model=latest`; do not combine it with the deprecated `diarize=true` parameter.

Primary references:

- [Multichannel vs diarization](https://developers.deepgram.com/docs/multichannel-vs-diarization)
- [Multichannel streaming response](https://developers.deepgram.com/docs/multichannel)
- [Speaker diarization](https://developers.deepgram.com/docs/diarization)
- [Live Audio API](https://developers.deepgram.com/reference/speech-to-text/listen-streaming)

Deepgram sends a separate streaming `Results` object for each channel. Speaker numbers are channel-local, and one alternative can contain a speaker change, so Arco groups consecutive words with the same `(channel, speaker)` instead of assigning the whole alternative from its first word.

Deepgram may restart numbering after a reconnect. Arco namespaces identities by connection and allocates new session-wide display numbers. This can split the same human into two anonymous labels after a network interruption, but avoids the more damaging false claim that two different humans are one person.

## Doubao streaming transcription

Doubao uses the bidirectional speech-recognition WebSocket at
`wss://openspeech.bytedance.com/api/v3/sauc/bigmodel` with resource ID
`volc.bigasr.sauc.duration`. Arco splits its stereo capture into one mono stream
per active source and sends the required gzip-compressed full request followed
by sequenced audio frames.

- With Doubao selected for both roles, one `doubao-combined` worker requests
  `enable_speaker_info` and writes finalized utterances with their returned
  speaker slots.
- With Doubao as ASR-only, finalized text can consume an external shared
  speaker timeline. With Doubao as diarization-only, it publishes speaker
  intervals without writing a duplicate transcript.
- Credentials support a Doubao Speech APP Key or the legacy App ID + Access
  Token pair and are stored in a dedicated macOS Keychain service. Arco never
  falls back to the generic Ark/LLM `DOUBAO_API_KEY`.
- The worker is ready only after every active channel receives a server
  response. Provider handshake errors remain terminal. A transient disconnect
  receives at most three recovery attempts; only a new finalized utterance
  resets that budget. Recovery retains audio that has not yet been sent, closes
  the disconnected channel's stale tentative edge, and advances past already
  sent frames instead of replaying them into every replacement connection.

Primary references:

- [Doubao Speech Recognition product capabilities](https://www.volcengine.com/docs/6561/1354871?lang=zh)
- [Volcengine's official streaming ASR client](https://github.com/volcengine/ai-app-lab/blob/main/arkitect/core/component/asr/asr_client.py)

## ElevenLabs realtime transcription

ElevenLabs uses Scribe v2 Realtime only. Its realtime API is mono and does not currently expose speaker diarization or dual-channel transcription, so it is registered as an ASR provider, not a diarization provider.

- The ElevenLabs helper opens one realtime WebSocket for each active source. `system` sends only channel 0, `mic` sends only channel 1, and `both` sends each channel through its own connection.
- With diarization off, realtime commits receive one source label per channel: `Remote 1` or `In room 1`. These are location labels, not detected speaker identities.
- With Deepgram or a local streaming diarizer selected, each finalized ElevenLabs segment reads the shared timeline and receives the dominant overlapping speaker label.
- Audio is streamed only while the meeting is active. Arco does not buffer meeting audio for a later ElevenLabs batch pass and does not replace the transcript after capture stops.
- Speaker attribution remains incremental; Arco does not run a stop-time batch pass or replace the transcript after capture stops.

The API key is verified against ElevenLabs' user endpoint, stored in macOS Keychain, and injected only into the owned helper environment.

Primary references:

- [Scribe v2 Realtime API](https://elevenlabs.io/docs/api-reference/speech-to-text/v-1-speech-to-text-realtime)
- [ElevenLabs API authentication](https://elevenlabs.io/docs/api-reference/authentication)

## Ordering, readiness, and backpressure

- Only finalized results become durable transcript events.
- Events from both channels are ordered by audio start time when the provider can emit them concurrently.
- Exact repeated speech is preserved; text equality is not a deduplication key.
- The mic channel is never assumed to be `You`. That name requires a future explicit mapping, personal-mic mode, or voice enrollment.

The Rust cloud adapters drain recorder stdout into bounded in-memory queues: 60 seconds by default, configurable with `ARCO_AUDIO_BUFFER_SECONDS` and hard-clamped to 1–300 seconds. When that ceiling is reached, pipe backpressure pauses capture rather than growing memory without bound. A completed WebSocket `send()` is not a server acknowledgement; all cloud providers remain streaming-only.

Rust reports `recording` only after every resolved worker is ready. Deepgram signals after its WebSocket is accepted; Doubao after every active source returns its first server response; ElevenLabs after every active source connection is accepted. HTTP 4xx handshakes and provider error messages are terminal configuration failures. The cloud adapters retry transient network failures with bounded backoff while stdin continues draining. Doubao additionally limits a stream to three consecutive recovery attempts and resets that budget only after finalized transcript progress. Each local worker signals after model load; a missing or incomplete model is a terminal setup error. If any selected worker exits, the owned capture pipeline fails as one unit rather than silently continuing with a different contract.

## Echo caveat

Hybrid setups can leak room speech back through conferencing output or acoustic echo. Identity mapping cannot fix duplicated audio. Capture should prefer OS echo cancellation and may later deduplicate only when channel, timing, and text strongly agree—not by global text equality.
