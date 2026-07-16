# Arco desktop architecture

## Decision

The desktop app uses a **SwiftUI + AppKit native macOS frontend** and an **in-process Rust static library**. Swift calls the Rust control plane through a narrow C ABI; commands and events cross that boundary as versioned JSON values. There is no browser runtime in the application.

The process boundary is intentionally different for code that loads speech models or owns long-lived network/audio streams. The ScreenCaptureKit/AVAudioEngine recorder, each cloud transcription helper, and the FluidAudio/SwiftWhisper/Nemotron local transcriber run as app-managed worker executables. Codex and Claude run as the external CLIs already installed and authenticated by the user. This keeps high-memory inference and crash-prone native model code outside the UI process while preserving one Rust authority for lifecycle and storage.

This split preserves the existing product contract:

- SwiftUI owns presentation, Liquid Glass materials and controls, and view-local interaction state; AppKit owns only windows/panels, global shortcuts, and native pickers.
- Rust owns meeting truth, capture policy, credentials, provider routing, Agent session bindings, and exact child-process lifecycle.
- Workers own audio capture, provider streams, or local inference. They do not become independent product authorities.
- Markdown and atomic JSON sidecars remain the portable durable format.

## Runtime boundaries

```text
SwiftUI views + observable AppStore
  │ async JSON commands/events
  ▼
C ABI (`arco_runtime_*`)
  ▼
`libarco_core.a` inside the Arco process
  ├─ MeetingStore ── reads new App Support files + legacy Markdown (read-only)
  ├─ MeetingStateStore ── native-session bindings + UI cache + saved-note sidecars
  ├─ CaptureManager ── ASR/diarization registries + exact child PIDs + PCM fan-out
  ├─ LocalTranscriptionRuntime ── model status/download/remove lifecycle
  └─ AgentRunner ── resolves Codex/Claude and passes prompt via stdin/argv
          │
          ├─ codex exec --json … / codex exec resume <thread_id> …
          └─ claude -p --output-format json … --resume <session_id> …

AppKit WindowCoordinator
  ├─ main NSWindow (SwiftUI content)
  ├─ recording HUD NSPanel (reused, hidden when inactive)
  └─ Agent NSPanel (reused, hidden when closed)

Owned worker process groups
  ├─ Swift recorder stdout (16kHz Int16LE stereo PCM)
  │   ├─ channel 0: system output
  │   └─ channel 1: local microphone
  └─ resolved provider pipeline
      ├─ ASR worker ── Deepgram | Doubao | ElevenLabs | local Nemotron/Whisper
      ├─ optional streaming diarization worker ── Deepgram | Doubao | local Sortformer/Pyannote/LS-EEND
      └─ shared versioned speaker timeline
             └─ finalized ASR segments → overlap attribution → Markdown adapter
```

The desktop app does not invoke the legacy global `start.sh` / `stop.sh`, touch a shared `.stop` flag, or use `pkill -f`.

`CaptureManager` independently resolves the validated ASR and diarization selections, then starts the recorder and resolved workers in separate owned process groups. Matching Deepgram, Doubao, or local selections are fused. Cross-provider selections receive identical PCM through a bounded fan-out and exchange an atomic streaming speaker timeline. A provider-specific ready-file handshake gates the visible recording state: Deepgram signals after its WebSocket is accepted; Doubao after every active source returns its first server response; ElevenLabs after every active source connection is accepted; each local worker after its model is loaded. Stop/error/drop targets only those exact process trees, and an app shutdown finalizes an active Markdown transcript as `interrupted`.

Provider discovery, capture routing, model management, and inference are separate boundaries. The in-process Rust library owns policy and lifecycle; worker executables own recorder, cloud-streaming, and local-inference work. Only the ASR worker writes the transcript; a separate diarization worker publishes channel-local intervals. Adding another engine therefore means registering either provider role and implementing its streaming worker contract rather than branching through the UI, meeting store, and process lifecycle.

FluidAudio, SwiftWhisper, Nemotron, and local diarization models are not linked into `Arco` or `libarco_core.a`. They are loaded only by `arco-local-transcriber`. Stopping or failing that owned worker releases its entire address space, including model memory. A worker crash or out-of-memory termination fails the active capture pipeline and produces an actionable state, but it does not directly terminate the SwiftUI application. The ready-file handshake, startup timeout, exact process-group cleanup, and parent-death behavior are therefore part of the reliability contract rather than packaging details.

## Native overlay contract

AppKit creates each `NSPanel` lazily on first use, then retains and reuses it for the rest of the process lifetime:

- The recording HUD hosts SwiftUI content at 368×56. A successful capture start positions it at the current monitor work area's bottom center and shows it without taking focus.
- The Agent panel hosts SwiftUI content at 720×560 with a 3:2 Agent/Transcript split. Collapsing the evidence pane resizes the same native panel to 432×560. `Ask Arco` keeps it inside the current monitor work area, shows the existing panel, and focuses its composer.

Both windows are transparent, always-on-top, visible on all workspaces, and render their visible material in SwiftUI with `GlassEffectContainer` and `.glassEffect(.regular…)`. As in the source UI, they do not request a protected compositor surface because that conflicts with Liquid Glass rendering. AppKit's `NSPanel` is only the lifecycle and placement container; no `NSGlassEffectView`/`NSVisualEffectView` material layer remains. On macOS 26 the interactive HUD and Agent controls use SwiftUI's interactive Liquid Glass; older systems use the SwiftUI `Material` fallback. The panels add `CanJoinAllSpaces | FullScreenAuxiliary`; the HUD uses one window level above the Agent so Stop remains reachable. The HUD is hidden after every stop attempt. Closing the Agent only hides it.

SwiftUI view state is never the cross-window authority. Capture state, the active meeting ID, provider-native session bindings, and persisted Agent turns remain in Rust/on disk. Backend events mean “this cache changed”; each surface re-reads the authoritative state. A focus refresh covers events missed while a hidden panel was not active.

## Data contract

Swift transcript lines use:

```swift
struct TranscriptLine: Codable, Identifiable {
    let id: String
    let sequence: Int
    let timestamp: String
    let speaker: String
    let text: String
}
```

Speaker identity is always the composite `(channel, speaker)`: channel 0 becomes `Remote 1/2/3`; channel 1 becomes `In room 1/2/3`. Deepgram can supply live word-level speaker changes; Doubao supplies finalized utterance speaker slots; local Sortformer, Pyannote + WeSpeaker, and LS-EEND supply incremental per-channel intervals. In a mixed pipeline, the diarization worker atomically updates the shared timeline and the ASR worker assigns each finalized segment to the greatest temporal overlap, waiting only briefly for streaming coverage. ElevenLabs itself supplies no identity, but its ASR can consume any separately selected diarization provider. With diarization off, Arco uses one location label per active source and never promotes it as diarization. All output slots are anonymous and source-local. The mic channel is never assumed to be the user because one room microphone can hear several local participants. A later explicit personal-mic mode, manual rename, or voice enrollment may map one composite identity to `You`. The next storage revision will add `sessionId`, audio-relative start/end offsets, `source` (`mic` or `system`), confidence, and `isFinal`, then persist to SQLite while continuing to export the Markdown adapter.

The Swift store keeps `activeMeetingId` and the reviewed meeting ID separate. Capture polling always reads the active ID; History selection changes the reviewed snapshot only after its transcript loads successfully. A stop forces one final transcript read after the native pipeline has drained.

The UI maps capture modes to user-facing meeting scenarios:

- `both` → Hybrid meeting;
- `system` → Online meeting;
- `mic` → In-person meeting.

The selected mode is remembered locally and cannot change during active capture.

## Context contract

Reusing CLI authentication does not mean choosing an unrelated Codex or Claude conversation. Arco constructs context explicitly:

- current transcript (always);
- selected historical meetings (future);
- selected workspace path as an explicit read scope;
- one explicitly selected workspace, attached visibly in the Agent composer; broad Home-folder access is not exposed by the product UI.

Conversation identity belongs to the provider. Arco lets Codex or Claude generate the native UUID, records an exact binding for `(meeting, provider, context scope, canonical workspace)`, and resumes only that ID. Codex `--last` and Claude `--continue` are forbidden because they are recency-based and can select an unrelated conversation. Switching provider selects another independent lane; switching scope or workspace selects another isolated native session.

The provider's persisted conversation is the continuity source. Arco's sidecar is deliberately derivative: it maps the meeting to the native ID, caches answer cards for fast UI rendering, and stores saved-note state. Old pre-session turns remain readable with a null native ID and are never assigned a fabricated one.

Prompts go through process stdin or direct argv arrays, never an interpolated shell command. The default provider profile is advisory/read-only. Mutation requires a separate, visible future permission mode.

For Codex, `transcript` and `workspace` scopes add a macOS Seatbelt profile around Codex's own read-only sandbox. Their native state lives in a per-binding Codex home, so the CLI can resume the selected conversation without granting the model read access to unrelated `~/.codex` sessions. The backend can still read legacy `personal` bindings created by earlier builds, but the desktop product no longer creates that scope. Claude transcript scope runs in safe mode with no tools; workspace scope exposes only `Read`, `Glob`, and `Grep`. Agent prompts, structured output, and every descendant process share one timeout and owned process group. A binding is serialized so two processes cannot concurrently resume and interleave writes to the same native session.

## Storage

- New data: `~/Library/Application Support/Arco/transcripts/`.
- On-device ASR and diarization models: `~/Library/Application Support/Arco/models/`, installed and removed through the local runtime rather than the capture process.
- Native Agent session bindings, cached answer cards, and saved-note flags: `~/Library/Application Support/Arco/meeting-state/`, one JSON sidecar per meeting ID.
- Isolated Codex native state for transcript/workspace bindings: under Arco Application Support, one provider-managed home per binding. The native Codex thread ID remains authoritative.
- Legacy import: `~/.claude/meeting-transcripts/{meeting,transcript}-*.md`.
- Legacy files are never renamed, rewritten, or deleted.
- Empty/malformed history is handled as data-quality input, not an app crash.
- Meeting-state writes use a temporary file, file sync, and atomic rename. A damaged sidecar produces an actionable error without hiding or rewriting the transcript.

## Hardening path

1. Keychain storage and first-run permission/key onboarding.
2. SQLite/WAL session index, transcript FTS, incremental commits, and crash recovery.
3. Stream provider deltas into the UI, add cancellation, and replace context receipts with real evidence citations where the provider exposes stable evidence references. Native provider-session resume is already the continuity base.
4. Universal helper builds, Developer ID signing/notarization, DMG, and updater. The current preview build embeds the host-architecture SwiftUI app, recorder, Rust cloud helpers, and local-transcriber worker under one stable local development identity. It is not a notarized distribution signature.
5. Auto-detection of supported meeting apps without joining or recording invisibly.
