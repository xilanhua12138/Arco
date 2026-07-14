# Transcription provider contract

Arco supports online, in-person, and hybrid meetings without pretending that an audio channel is a person. Cloud and on-device engines are peers behind one capture contract.

## Provider boundary

The frontend persists one validated `TranscriptionConfig`:

```ts
type TranscriptionConfig = {
  provider: 'deepgram' | 'elevenlabs' | 'local'
  model:
    | 'nova-3'
    | 'scribe-v2-realtime'
    | 'nemotron-speech-3.5-streaming'
    | 'whisper-tiny' | 'whisper-base' | 'whisper-small'
    | 'whisper-medium' | 'whisper-large'
  language: 'auto' | 'zh-CN' | 'en-US'
  diarization:
    | 'provider'
    | 'sortformer-streaming'
    | 'lseend-ami-streaming'
    | 'lseend-dihard3-streaming'
    | 'none'
}
```

Rust validates the combination and resolves it through a `TranscriberCatalog`. Each definition owns its executable, fixed arguments, credential requirement, and readiness timeout. The capture manager does not know inference APIs: it starts the chosen definition in an owned process group, supplies the shared PCM stream, and waits for the one-use ready-file.

The local sidecar has a second, deliberately smaller abstraction: `LocalTranscriptionProvider`. Nemotron and Whisper implement that protocol; the selected FluidAudio diarizer is composed alongside either engine. Model status, download, removal, and inference are separate commands, so capture never silently downloads models or mutates its model set.

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

## On-device ASR

The bundled Swift sidecar provides:

| Model | Runtime | Intended use |
|---|---|---|
| Nemotron Speech 3.5 Streaming | FluidAudio + Core ML/Apple Neural Engine | Lowest-latency multilingual local path |
| Whisper Tiny | SwiftWhisper/whisper.cpp | Smallest and fastest Whisper option |
| Whisper Base | SwiftWhisper/whisper.cpp | Lightweight general use |
| Whisper Small | SwiftWhisper/whisper.cpp | Balanced accuracy and speed |
| Whisper Medium | SwiftWhisper/whisper.cpp | Higher accuracy with greater memory/latency |
| Whisper Large v3 | SwiftWhisper/whisper.cpp | Highest-quality, heaviest Whisper option |

Each stereo channel has independent 200 ms pre-roll, 500 ms minimum speech, and 600 ms trailing-silence endpointing. The sidecar incrementally consumes the live stream, finalizes an utterance at the endpoint, transcribes it, and writes the shared Markdown adapter with audio-relative start/end metadata. Nemotron uses its token timing envelope; Whisper preserves its returned segment timings. Arco currently persists finalized local segments rather than exposing unstable interim text.

Models live under `~/Library/Application Support/Arco/models/`. Whisper downloads are staged, checked against their exact expected byte size, and atomically moved into place. Nemotron, Sortformer, and LS-EEND use FluidAudio's model manifests/caches plus separate Arco installation markers. A local ready signal is emitted only after the selected ASR and optional diarizer are loaded.

The implementation depends directly on Apache-2.0 FluidAudio and MIT SwiftWhisper. FluidVoice informed the product/model matrix, but its GPL-3.0 source is not copied into Arco.

## On-device streaming speaker separation

Local speaker separation offers three explicit FluidAudio backends:

| Model | Intended use | Speaker slots per source |
|---|---|---:|
| Streaming Sortformer | Stable identities for typical meetings | 4 |
| LS-EEND Meeting (AMI) | Meetings with overlap or quiet speech | 4 |
| LS-EEND General (DIHARD3) | Complex rooms and larger groups | 10 |

Sortformer uses the palettized `fastV2_1` model on CPU + Neural Engine. LS-EEND uses the 100 ms streaming variants on CPU. Arco creates one diarizer timeline per active source channel while sharing the loaded model weights.

Each backend returns finalized history plus a revisable tentative edge. Arco appends only new finalized intervals and replaces the tentative edge on every update, avoiding stale-hypothesis double counting. It finalizes each channel's diarizer before flushing the last utterance. Each finalized ASR segment is assigned to the speaker slot with the greatest temporal overlap.

The local provider has a five-minute readiness ceiling and remains visibly `Starting` until the selected ASR and diarizer are loaded. Once ready, diarization consumes the live stream incrementally. A future persistent local-model service should keep the diarizer warm across meetings and amortize that per-process load.

The identity key remains `(channel, speaker)`:

```text
(channel 0, speaker 0) → Remote 1
(channel 0, speaker 1) → Remote 2
(channel 1, speaker 0) → In room 1
(channel 1, speaker 1) → In room 2
```

A slot is not a durable human identity, and the same human heard through both sources can receive two labels. A segment containing a rapid speaker switch is currently assigned to its dominant speaker; word-level local speaker splitting is a later refinement.

## Deepgram streaming request

Deepgram remains the migration-safe default and uses its own word-level diarization:

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

The Deepgram branch never prepares or loads a local diarization model. Conversely, local ASR never sends audio to Deepgram.

Use `diarize_model=latest`; do not combine it with the deprecated `diarize=true` parameter.

Primary references:

- [Multichannel vs diarization](https://developers.deepgram.com/docs/multichannel-vs-diarization)
- [Multichannel streaming response](https://developers.deepgram.com/docs/multichannel)
- [Speaker diarization](https://developers.deepgram.com/docs/diarization)
- [Live Audio API](https://developers.deepgram.com/reference/speech-to-text/listen-streaming)

Deepgram sends a separate streaming `Results` object for each channel. Speaker numbers are channel-local, and one alternative can contain a speaker change, so Arco groups consecutive words with the same `(channel, speaker)` instead of assigning the whole alternative from its first word.

Deepgram may restart numbering after a reconnect. Arco namespaces identities by connection and allocates new session-wide display numbers. This can split the same human into two anonymous labels after a network interruption, but avoids the more damaging false claim that two different humans are one person.

## ElevenLabs realtime transcription

ElevenLabs uses Scribe v2 Realtime only. Its realtime API is mono and does not currently expose speaker diarization or dual-channel transcription, so Arco does not claim that this provider separates speakers.

- Arco opens one realtime WebSocket for each active source. `system` sends only channel 0, `mic` sends only channel 1, and `both` sends each channel through its own connection.
- Realtime commits receive one source label per channel: `Remote 1` or `In room 1`. These are location labels, not detected speaker identities.
- Audio is streamed only while the meeting is active. Arco does not buffer meeting audio for a later ElevenLabs batch pass and does not replace the transcript after capture stops.
- Choose Deepgram or an on-device diarization model when realtime multi-speaker separation is required.

The API key is verified against ElevenLabs' user endpoint, stored in macOS Keychain, and injected only into the owned sidecar environment.

Primary references:

- [Scribe v2 Realtime API](https://elevenlabs.io/docs/api-reference/speech-to-text/v-1-speech-to-text-realtime)
- [ElevenLabs API authentication](https://elevenlabs.io/docs/api-reference/authentication)

## Ordering, readiness, and backpressure

- Only finalized results become durable transcript events.
- Events from both channels are ordered by audio start time when the provider can emit them concurrently.
- Exact repeated speech is preserved; text equality is not a deduplication key.
- The mic channel is never assumed to be `You`. That name requires a future explicit mapping, personal-mic mode, or voice enrollment.

The Rust cloud adapters drain recorder stdout into bounded in-memory queues: 60 seconds by default, configurable with `ARCO_AUDIO_BUFFER_SECONDS` and hard-clamped to 1–300 seconds. When that ceiling is reached, pipe backpressure pauses capture rather than growing memory without bound. A completed WebSocket `send()` is not a server acknowledgement; both cloud providers remain streaming-only.

Rust reports `recording` only after provider readiness. Deepgram signals after its WebSocket is accepted; ElevenLabs signals after every active source connection is accepted. HTTP 4xx handshakes and provider error messages are terminal configuration failures; network and 5xx failures retry with bounded backoff while stdin continues draining. The local sidecar signals after model load; a missing or incomplete model is a terminal setup error.

## Echo caveat

Hybrid setups can leak room speech back through conferencing output or acoustic echo. Identity mapping cannot fix duplicated audio. Capture should prefer OS echo cancellation and may later deduplicate only when channel, timing, and text strongly agree—not by global text equality.
