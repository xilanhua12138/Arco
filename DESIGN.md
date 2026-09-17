# Arco design system

## Creative north star: The Living Page

Arco should feel like one personal thinking workspace that stays open while a conversation happens. The live transcript is the central working surface. Ask Arco is explicitly opened from the meeting header; it starts collapsed and retains the user’s choice for the current app session. Collapsing never ends an Agent request or discards a draft.

The Agent is a restrained continuous document rather than a wall of chat bubbles or AI cards. Questions, answers, source receipts, and the composer form one calm vertical flow; the transcript remains independently scrollable.

Physical scene: a knowledge worker is participating in a hybrid meeting, glancing at Arco for two or three seconds at a time in either a bright office or a dim call. The interface therefore uses one stable light appearance, keeps transcript reading width bounded and opens Agent only when requested.

## Reference blend

- **Typeless is the primary visual reference:** near-black type, generous white space, large direct headings, thick but controlled radii, sparse color, list-like history, and a substantial settings sheet.
- **Liquid Glass supplies the Mac material layer:** window chrome, navigation/control islands, drawers, and sheets may refract the desktop behind them.
- **Dayflow contributes personal-tool calm:** the interface should feel owned by one person rather than operated by a team.
- **OpenLess contributes direct action:** important jobs should be reachable by a visible button, not hidden behind command syntax.

Implementation follows two deliberate passes. The first pass independently reproduces Typeless's visible shell grammar—rail geometry, page gutters, typography, navigation states, grouped rows, and settings proportions. The second pass preserves that baseline while replacing its dictation-dashboard information architecture with Arco's meeting workflow. No proprietary Typeless code or assets are reused.

## Register

- Surface: desktop productivity product.
- User state: listening, speaking, and scanning quickly.
- Voice: calm, direct, private, evidence-conscious.
- Density: sparse navigation; compact conversation and list contents. Leave space between functional regions rather than inflating every paragraph.

## Visual hierarchy

1. The live transcript and speaker identity.
2. The current Agent question and answer.
3. The global recording state and Stop control while capture is active.
4. Audio location and meeting scenario.
5. History navigation and technical status.

The UI uses whitespace, type scale, row rhythm, and one-pixel dividers before adding containers. Shadows are reserved for transient floating layers such as settings and errors.

## Material hierarchy

1. **Native window glass:** the outer window may use macOS Liquid Glass on macOS 26+ and Vibrancy on older supported systems.
2. **Glass controls:** AppKit owns native windows and panels; SwiftUI applies the Liquid Glass substrate on macOS 26+ and native material fallbacks on older supported systems. Controls use restrained transparent fills and never draw a second simulated glass layer. The main window uses opaque white and neutral grey surfaces; floating windows may retain native material.
3. **Reading surface:** transcript and Agent prose use a stable, high-opacity surface. Long-form text never sits directly on a changing glass background.
4. **Content rows:** use dividers and spacing by default. Add a card only when the content is a genuinely bounded object.

Glass must remain visibly subordinate to the transcript. Blur is not hierarchy by itself, and translucency must not reduce contrast.

## Tokens

- Color system: one Typeless-derived light neutral and alpha palette in `macos/ArcoNativeUI/Sources/ArcoNativeUI/Views/Theme.swift`; Arco does not follow the operating system's dark appearance.
- Main stage: plain white. No ambient washes, dot grid, or outer panel strokes. Agent uses #F6F6F6 and a 16pt radius; its background separates it from the transcript without a vertical divider.
- Brand: retain the actual Arco icon. Cobalt #245CF5 marks primary actions and links; recording uses #C62D41. Text is #191919 and supporting text #666666.
- Recording red: state only, never brand decoration.
- Neutrals: opaque white paper, #F6F6F6 sidebar and assistant, #E8E8E8 selected navigation.
- Geometry baseline: 210px rail, 8px outer inset, 16–24px page gutter, an optional Agent capped at 400pt with a 20pt gap on Current, 1080px maximum width for History, and a 32px native title-bar clearance.
- Radii: 8px navigation and field controls, 10px grouped content, 12px settings sheet, 14px recording HUD, and 16–20px window/sidebar material. Pills only for status and compact global actions.
- Motion: 110ms press feedback, 160ms hover/popover response, 220ms state transitions, and 260ms sheets using one quint-like ease-out. No bounce, elastic easing, or continuously drifting background animation.
- Shadows: stable reading surfaces use no outer shadow. Native HUD and Agent windows defer their material edge and outer shadow entirely to macOS; SwiftUI content sheets use the restrained sheet token.
- Primary type: macOS system font (SF with system Chinese fallback), including AppKit text editors. Meeting titles are 28pt semibold; landing titles 32pt (28pt compact), history titles 30pt. Transcript is 14pt, navigation 14pt. Main Agent uses heading 14pt semibold, question 13pt semibold, answer 13pt regular with 3pt extra line spacing and 8pt paragraph gaps. Floating Agent uses heading 13pt, question 12.5pt, answer/input 12pt, with 2.5pt extra line spacing and 6pt paragraph gaps. Dense Agent typography stays scoped to the Agent surface. Main and floating composers use the same 36pt editor and 100pt default white input area; context chips sit beside the plus button below the input.
- Shared metadata, small and tiny tokens are 12pt with sufficient contrast. Specialized legacy utility labels retain their existing sizes.

## Product surfaces

- **First value:** onboarding owns the whole first-run window; the main Arco workspace is not mounted behind it. A sparse landing page communicates one promise and one Continue action. Continue enters a five-step setup workspace—Agent, Transcription, Audio check, Shortcut, First meeting—with a stable left progress rail and exactly one task in the reading surface. Provider setup uses opaque reading surfaces and flat controls with explicit selected fills; it does not layer Liquid Glass across the sheet, rail, or segmented choices. The rail can revisit completed steps, later steps stay locked, real provider/audio checks gate progress, and a quiet Set up later action preserves a complete transcript-only path. This follows Dayflow's public root-switch and standalone setup pattern without copying its brand assets or product-specific questions.
- **Idle Current:** whenever capture is off, Current is a left-aligned 30–36pt heading, a neutral launch area with one Start CTA and audio-source control, a separate compact shortcut area, and a quiet local-history summary. The Agent workspace appears only after capture begins and there is live meeting context to discuss. Stopping does not automatically display history inside Current; it opens the finalized meeting in History review, and Current remains the deliberate route back to starting another meeting.
- **Current conversation:** only an active capture owns Current's persistent two-column workspace. The transcript is primary, capped at 720pt while Ask Arco is collapsed. An explicit header button opens a 400pt maximum Agent at the right. Below 740pt of usable workspace, the two independently scrolling regions stack without rebuilding the Agent view.
- **Recording HUD:** a fixed 368×56 native utility window at the active display's bottom center. It contains a red state dot, `Recording`, elapsed time, `Stop`, and `Ask Arco`—nothing else. It never steals focus when it appears.
- **Agent utility window:** one reusable 720×560 always-on-top workspace at the active display's top-right. `Ask Arco` remains primary on the left while a compact live Transcript stays visible as evidence on the right. Hiding Transcript contracts the native window to 432×560 without destroying the meeting thread, draft, or scroll state.
- **Navigation/control layer:** at most one lightweight rail or floating island. A permanent rail is acceptable at wide sizes only when it remains navigation—not analytics or a second workspace.
- **History:** search plus date-grouped rows with title, evidence preview, time, and line count. Opening a row—or successfully stopping the active meeting after its final transcript read—keeps History selected while showing the meeting review workspace. Meetings without a generated or imported title use one restrained `Untitled meeting` display placeholder; the placeholder is never persisted as data. Storage policy belongs in Settings; History must not become a statistics or policy overview.
- **Speaker map:** a compact disclosure that separates system audio (`Remote N`) from the room microphone (`In room N`). These are location + diarization labels, never presumed identities; a single microphone can contain multiple people.
- **Agent workspace:** an optional, state-preserving primary landmark with first-question command rows, prose answers, compact `Context used · N` disclosures, and one full-width bottom composer dock aligned to the answer body. Source receipts stay collapsed beneath each answer until the user opens them; at 340px Agent width and below, answer density tightens and Copy becomes an icon-only secondary action without losing its accessible name. Primary/Secondary routing is configured outside the conversation, and replies preserve provider and context truth without exposing full UUIDs. Answers persist with the meeting. Copy is the reply action; there is no separate Notes destination or save/unsave toggle.
- **Meeting review:** when available, the generated summary reads as the opening section of the transcript document, separated by whitespace and one divider rather than a nested AI card. No empty summary shell is shown while generation is pending or after a non-fatal failure.
- **Settings sheet:** a large, calm sheet with six stable sections—Shortcuts, Audio & speakers, Meeting output, Agent runtime, GPT Live Beta, Data & privacy. Shortcuts exposes one global Start/Stop binding and an explicit Off state. Meeting output begins with two linear status rows; prompt text and switches appear only after choosing Automatic title or End-of-meeting summary. Audio exposes only the current/next meeting type at first glance. The linear `Recognition` disclosure owns the cloud/on-device choice, local model lifecycle, language, speaker separation, and source lanes; those controls lock together for the duration of a meeting.
- **Notices:** actionable system states with concrete language.

## Interaction rules

- Auto-follow only while the user remains near the live edge.
- Enter sends Agent questions; Shift+Enter adds a line.
- `⌘K` focuses meeting search.
- `⌘ + ⇧ + Space` starts or stops listening by default while Arco is running. Default and user-defined Command/Control/Option/Shift combinations use the registered application shortcut layer. During the Shortcut onboarding stage, a press confirms the binding inline and never starts a hidden capture session.
- The 210pt navigation rail remains stable, including at 1024pt. The settings sheet uses its own 202pt rail. During capture, Current offers an optional Agent alongside the transcript; while idle, the focused start surface uses the full workspace. Below 740pt usable workspace width, the two reading surfaces stack. Drafts, request errors and context scope are held per meeting; collapse and width changes retain the same editor instance.
- Escape or `⌘W` hides the Agent utility window without destroying its meeting thread; the persistent Current workspace remains open. Escape closes settings layers.
- Settings and errors must be keyboard-dismissible.
- Disabled controls explain the missing prerequisite nearby.
- User context is never described as “magic memory”; show the selected scope and provider.
- Provider configuration establishes one Primary and an optional Secondary. The settled provider stays out of normal conversation chrome; show a notice only when the configured Primary is unavailable and the Secondary is actually in use.
- Session identity is a backend continuity invariant, not persistent interface copy. Provider UUIDs and repeated “native session” labels stay out of the everyday conversation.
- Direct Agent actions use a single divided command list, not a grid of AI suggestion cards.
- Active capture and reviewed meeting are separate. When the user reviews History during capture, show one calm `Return to live` state bar; `Current` must always reopen the active meeting.
- Capture controls have one owner per state: idle Current owns the large Start CTA and the sidebar becomes status-only; idle History/review owns no central Start, so the sidebar exposes it; recording always keeps the global Stop in the sidebar.
- The transcript chip is always visible in the Agent composer. A selected workspace appears as a second attachment chip, is chosen with the native folder picker, and can be removed without exposing a broad Home-folder option.

## Anti-references

- chat bubbles for every answer;
- purple/pink gradients, neon AI glow, or simulated glass distortion;
- glass on every surface, especially underneath transcript body copy;
- dashboard card grids around every sentence;
- KPI tiles, usage charts, and admin-style overview pages;
- rainbow speaker rails;
- oversized marketing headings inside the product;
- hidden capture or invisible context expansion;
- modal stacks for routine settings;
- animations that compete with a live conversation.

## Impeccable workflow

The project keeps product and design context in durable Markdown. For material UI changes:

1. read `PRODUCT.md` and this file;
2. shape the interaction before styling;
3. run the Swift state, preferences, and localization contract executables;
4. build the Rust static library and the Swift package, then build `build/Arco.app` with `native/build-native-app.sh`;
5. inspect the real native app at 1240×820 and 1080×750, then simulate a dark operating-system appearance at 1024px to verify Arco remains light before checking the packaged native app separately;
6. refresh this document when actual tokens or components change.

## 2026-09-05 design artifacts

Editable Pencil design: `designs/arco-typeless/arco.pen`. Independent review: `designs/arco-typeless/REVIEW.md`. Typeless 2.5.0 bundle typography audit: `designs/arco-typeless/TYPELESS-TYPOGRAPHY.md`. All design meeting text is a layout fixture. Native ImageRenderer artifacts are rendering checks, not desktop interaction or recording E2E evidence.

Main Agent content uses 24pt side insets. Its 100pt default composer places context chips in the bottom control row; additional references scroll horizontally without pushing the send button offscreen. Transcript timestamps occupy a 64pt left column, followed by a 12pt gap and speech content. The native 18pt SpeakerAvatar and 12pt speaker label sit above 14pt prose, with a thin divider after each utterance.

## Settings and floating surfaces — September refinement

- HUD remains 368×56. Arco’s own mark identifies Ask; Stop uses recording red on a pale red background. Only active recording displays the recording dot; saved state has a check.
- Floating Agent retains 720×560 with transcript and 432×560 without it. Both column headings are 14pt semibold; reading backgrounds are opaque. The outer native material is retained.
- Settings retain all six destinations and the 202pt rail. Page heading22, navigation14, field labels13, supporting copy12, menus13. A28% scrim and one light shadow separate the sheet. Control rows grow for wrapped descriptions and stack when their two columns do not fit.
- Pencil uses Noto Sans SC and Roboto Mono as editable substitutes. CoreText verified the native Chinese fallback as PingFang UI SC. Native rendered fixtures are the typography reference; design PNGs are not pixel-identical native font proofs.

Floating Agent reading areas are opaque white. Only the composer uses the subtle gray background; the main-window Agent retains its gray reading panel.

## Settings navigation (2026-09-06)

Four primary sections: General, Listening & recording, Talk with Arco, Data & privacy. Recognition and generation rules belong to Listening. Text connection and voice connection belong to Talk with Arco. Detail pages keep the parent highlighted and return inside the same sheet. Text provider validation uses a pinned save footer; save stays disabled until its test passes. Headings are 20pt, group titles14pt, body13pt and help12pt. Prompt drafts survive back/section navigation; explicit Cancel clears only that rule's draft. Brainstorming happens around the current meeting and needs no settings switch.
