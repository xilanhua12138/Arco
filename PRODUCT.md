# Arco product brief

## One sentence

Arco is an Agent-first meeting workspace: it lets the user think with their own Codex or Claude CLI while a live transcript remains visible beside every answer as inspectable evidence.

## User and job

Arco is for knowledge workers who are actively participating in meetings. Their attention belongs to the conversation, so the interface must be scannable in seconds and useful without prompt engineering.

The core job is not “produce meeting notes.” It is:

> Help me understand, answer, challenge, and follow through on this conversation while it is still happening, using context I already trust.

## Three layers

1. **Evidence** — a timestamped, speaker-labelled transcript. This remains inspectable even if AI is disabled.
2. **Interpretation** — optional Agent answers, generated meeting titles and end-of-meeting summaries from Codex or Claude native conversations with explicit context boundaries.
3. **Outcomes** — only user-confirmed notes, decisions, open questions, and actions.

Agent output never silently becomes a fact or task.

The first implemented outcome is deliberately small: the user can save an Agent answer as a meeting note. Structured decision/action candidates remain a later step and will still require confirmation.

## Session invariants

- Arco owns at most one active capture session.
- The active meeting and the meeting currently being reviewed are separate state.
- Capture status and polling always follow the active meeting ID.
- Opening History may show another meeting without changing capture.
- `Current` always returns to the active meeting while capture is running.
- When capture is idle, `Current` always shows the start-listening surface; a selected or recent History meeting never fills it implicitly. A successful stop is an explicit transition into the just-completed meeting's History review, not implicit History content inside `Current`.
- A meeting opened from History remains a History review, including its navigation state, until the user explicitly returns to `Current`.
- The Start action appears exactly once: in the main Current surface while Current is idle, or in the sidebar while the user is elsewhere. Stop remains a global sidebar safety control during capture.
- A History selection becomes visible only after that meeting has loaded successfully; old evidence is never shown under a new title.
- Stop completes transcript finalization and a final read before the session becomes a review.
- Recording success reveals one global HUD on the active display. Idle capture has no HUD.
- Ask Arco shows or focuses one reusable Agent window; it never creates a second conversation window or a second provider session.
- A meeting starts without a semantic title. Once enough final transcript evidence exists, Arco may ask the configured CLI to name it; a timestamp is never presented as an inferred title.
- Automatic title and summary generation share one dedicated native CLI session per meeting and provider. That session is separate from the meeting's Ask Arco conversation, so background prompts never appear as user questions.
- The HUD, Agent window, and main window treat native capture state and meeting sidecars as the source of truth. Cross-window events invalidate local caches and trigger a read.

## MVP flows

### Reach first value

- First launch is a standalone product state, not a sheet over an already-running workspace. A single-purpose landing page leads into a stable setup workspace with five visible stages: choose and test a Primary with an optional Secondary CLI, choose and prepare transcription, verify the audio lanes required by the meeting type, confirm the global shortcut, then start the first meeting or enter Arco.
- Skipping Agent setup enters a complete transcript-only product; it never traps the user behind an account-style gate.
- Whenever capture is idle, Current keeps one focused `Start listening` surface without mounting the Agent workspace. Starting capture opens the transcript and Arco Agent together; if no CLI is connected, the Agent side offers setup without hiding the live transcript.
- The default global shortcut is `⌘ + ⇧ + Space`. It uses the macOS registered global-shortcut layer, starts or stops the single capture session while Arco is running, can be changed or disabled in Settings, and becomes an in-place test instead of starting an invisible recording during onboarding.
- Existing users with a valid provider configuration are migrated past onboarding automatically.

### Start and follow a meeting

- One primary `Start listening` action.
- Choose the next meeting scenario before starting: Hybrid (`system + room`), Online (`system`), or In-person (`room`). The choice is locked during capture.
- Clear permission, audio source, recording, reconnecting, stopping, and error states.
- Continuous transcript; user scrolling disables auto-follow until `Jump to live`.
- Empty test sessions do not pollute the main history.
- Once recording is ready, expose only `Recording`, elapsed time, `Stop`, and `Ask Arco` in the global HUD. Audio engineering and provider metadata stay in Settings.
- Stop remains available above other apps and finalizes only Arco-owned recorder/transcriber processes.
- Stopping returns as soon as transcript finalization is complete. If the meeting contains evidence, the configured CLI creates the end-of-meeting summary in the background; generation latency or failure never turns a saved recording into a capture error.
- After stopping and successfully re-reading the finalized transcript, Arco opens the just-completed meeting as the latest History review. `Current` remains the explicit idle start surface when the user returns to it.
- Automatic title and summary prompts have safe Arco defaults and can be independently disabled or overridden in Settings. Arco always adds the transcript and fixed read-only safety envelope itself.

### Ask during a meeting

- Current opens directly into one persistent transcript workspace with the Agent docked at its right; asking and checking the evidence never require opening a drawer.
- The global `Ask Arco` action opens the same meeting thread in a focused always-on-top window. Hiding and reopening it preserves the native meeting/session binding and draft; it does not select a recent unrelated CLI conversation.
- Configure one Primary provider and an optional Secondary during setup. Every question uses the Primary unless that CLI runtime is unavailable before the request; normal request, authentication, or timeout errors never trigger a silent replay to the Secondary.
- Each meeting, provider, and explicit context envelope owns a CLI-generated native session ID. Follow-up questions resume that exact ID; Arco never uses Codex `--last` or Claude `--continue`.
- The transcript is always the visible evidence boundary. A user may explicitly attach one workspace through the native folder picker; a different canonical workspace uses a different native session so project context cannot leak into a later transcript-only answer. Arco never offers broad Home-folder access in the product UI.
- A user may attach reference documents (a resume, a JD, notes) to a meeting through the native file picker. Arco extracts the text itself and inlines it into the prompt as quoted reference material; the Agent never receives file-system access to the original file. Attachments appear as composer chips and in every answer's context receipts.
- Use a quick action or ask a custom question.
- Show the context actually sent with the answer. These receipts are context disclosure, not fabricated model citations.
- Treat the provider session as conversation truth. Arco keeps only the meeting binding, a display cache, and saved-note metadata. A failed request preserves the draft for retry and never silently replaces a missing native session.
- Let the user explicitly save or unsave an answer as a durable meeting note.

### Revisit history

- Import existing Arco Markdown without modifying it.
- Search titles and transcript text.
- Group results by Today, This week, and Earlier.
- Opening a result shows its transcript and Agent thread as a History review; it never changes the meaning or selection state of Current.
- Preserve native-session bindings, cached answer cards, and user-confirmed saved notes beside the meeting evidence without modifying legacy transcript files.
- Show a generated summary as a quiet review section when one exists. Pending or failed generation does not add empty cards or technical status noise to the transcript.

## Nudge policy

Arco should stay silent unless at least one high-value condition is present:

- the other person asked a clear question;
- claims or assumptions conflict;
- a meaningful decision lacks owner or timing;
- current discussion has a concrete connection to selected prior context;
- an important risk or open question is about to be lost.

No generic encouragement, constant summaries, invisible recording, or undisclosed context expansion.

## Explicit non-goals for MVP

- autonomous task execution or file modification;
- a terminal embedded in the UI;
- claiming that cloud-backed CLI inference is fully local;
- automatic selection of unrelated CLI conversation history;
- cross-platform audio parity before the macOS path is reliable;
- a meeting bot that joins calls as a participant.

## Success signals

- A first-time user can start a meeting in under 30 seconds after permissions and the selected transcription provider are ready; model download time is excluded from this measure.
- Live lines appear shortly after utterance finalization and survive an app refresh.
- Every Agent answer exposes its context boundary and the context receipts actually sent. Exact line-level model citations remain a later capability.
- Native Codex/Claude session bindings, cached answer cards, and saved-note state survive closing and reopening the app; a follow-up resumes the same provider ID.
- Generated titles and summaries survive closing and reopening the app in the meeting sidecar; generating a summary resumes the title-generation session when the provider is unchanged.
- The user can stop capture without leaving recorder/transcriber processes behind.
- The user can stop or open Ask Arco from any Space without returning to the main window; the HUD does not steal focus when it appears.
- Legacy history is visible without migration or overwrite.
