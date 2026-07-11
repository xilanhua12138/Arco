# Arco design system

## Creative north star: The Living Page

Arco should feel like one personal thinking workspace that stays open while a conversation happens. The live transcript is the central working surface; the Agent is a persistent thinking tool at its right, always available without displacing the conversation itself.

The Agent is a restrained continuous document rather than a wall of chat bubbles or AI cards. Questions, answers, source receipts, and the composer form one calm vertical flow; the transcript remains independently scrollable.

Physical scene: a knowledge worker is participating in a hybrid meeting, glancing at Arco for two or three seconds at a time in either a bright office or a dim call. The interface therefore uses one stable light appearance, gives the transcript the wider central column, and keeps the Agent visible as a narrower right-side thinking surface.

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
- Density: sparse navigation, generous reading rhythm.

## Visual hierarchy

1. The live transcript and speaker identity.
2. The current Agent question and answer.
3. The global recording state and Stop control while capture is active.
4. Audio location and meeting scenario.
5. History navigation and technical status.

The UI uses whitespace, type scale, row rhythm, and one-pixel dividers before adding containers. Shadows are reserved for transient floating layers such as settings and errors.

## Material hierarchy

1. **Native window glass:** the outer window may use macOS Liquid Glass on macOS 26+ and Vibrancy on older supported systems.
2. **Glass controls:** navigation, the capture control island, and transient drawers/sheets may use a tinted translucent material with a thin inner highlight.
3. **Reading surface:** transcript and Agent prose use a stable, high-opacity surface. Long-form text never sits directly on a changing glass background.
4. **Content rows:** use dividers and spacing by default. Add a card only when the content is a genuinely bounded object.

Glass must remain visibly subordinate to the transcript. Blur is not hierarchy by itself, and translucency must not reduce contrast.

## Tokens

- Color system: one Typeless-derived light neutral and alpha palette in `src/index.css`; Arco does not follow the operating system's dark appearance.
- Ambient depth: the main page stage uses Arco's light ambient wash plus a locally masked 8px dot field. The texture may show around reading surfaces, never through transcript or Agent prose.
- Brand: near-black for primary controls; cobalt is a sparse semantic color for evidence links and selected context.
- Recording red: state only, never brand decoration.
- Neutrals: slightly blue paper and near-black ink tones in one stable light appearance.
- Geometry baseline: 210px rail, 8px outer inset, 16–24px page gutter, a 3:2 Transcript/Agent split on Current, 1080px maximum width for History, and a 32px native title-bar clearance.
- Radii: 8px navigation and field controls, 10px grouped content, 12px settings sheet, 14px recording HUD, and 16–20px window/sidebar material. Pills only for status and compact global actions.
- Motion: 180–260ms, opacity and transform, ease-out. No bounce or decorative streaming animation.
- Shadows: stable reading surfaces use no outer shadow. Native HUD and Agent windows keep only a one-pixel inner highlight and defer the outer shadow to macOS; browser sheets use the restrained sheet token.
- Primary type: Avenir Next with explicit PingFang SC and system fallbacks; SF Mono is reserved for timestamps, paths, and runtime identifiers. Page titles are 36/40 at weight 600; transcript copy is 14/22; navigation is 14/16.
- Metadata: 10–12px with sufficient contrast for operational state; monospace is reserved for paths and runtime identifiers.

## Product surfaces

- **First value:** onboarding is a focused five-step sheet—Welcome, providers, connection test, shortcut, Ready—with a quiet Skip action. It teaches the product through the next real action, not a carousel of features.
- **Idle Current:** whenever capture is off, Current becomes a quiet launch surface centered on the waveform, `Start listening` heading, and one large CTA. It deliberately omits explanatory product copy. The next meeting's audio mode and one local-storage receipt remain compact beneath the action; source-backed local totals and the complete shortcut reference sit in one restrained footer row without cards. Empty Transcript and Agent columns are not rendered.
- **Current conversation:** only an active capture owns Current's persistent two-column workspace. The independently scrolling transcript occupies the wider central column; Agent conversation and composer occupy the narrower right column under the shared meeting title.
- **Recording HUD:** a fixed 368×56 native utility window at the active display's bottom center. It contains a red state dot, `Recording`, elapsed time, `Stop`, and `Ask Arco`—nothing else. It never steals focus when it appears.
- **Agent utility window:** one reusable 720×560 always-on-top workspace at the active display's top-right. `Ask Arco` remains primary on the left while a compact live Transcript stays visible as evidence on the right. Hiding Transcript contracts the native window to 432×560 without destroying the meeting thread, draft, or scroll state.
- **Navigation/control layer:** at most one lightweight rail or floating island. A permanent rail is acceptable at wide sizes only when it remains navigation—not analytics or a second workspace.
- **History:** search plus date-grouped rows with title, evidence preview, time, and line count. Opening a row keeps History selected while showing the meeting review workspace. Meetings without a generated or imported title use one restrained `Untitled meeting` display placeholder; the placeholder is never persisted as data. Storage policy belongs in Settings; History must not become a statistics or policy overview.
- **Speaker map:** a compact disclosure that separates system audio (`Remote N`) from the room microphone (`In room N`). These are location + diarization labels, never presumed identities; a single microphone can contain multiple people.
- **Agent workspace:** a persistent primary landmark with first-question command rows, prose answers, honest `Context used` receipts, and one compact composer. Primary/Secondary routing is configured outside the conversation; replies preserve provider and context truth without exposing full UUIDs. Saving a note is a real durable action.
- **Meeting review:** when available, the generated summary reads as the opening section of the transcript document, separated by whitespace and one divider rather than a nested AI card. No empty summary shell is shown while generation is pending or after a non-fatal failure.
- **Settings sheet:** a large, calm sheet with five stable sections—Audio & speakers, Shortcuts, Meeting output, Agent runtime, Data & privacy. Shortcuts exposes one global Start/Stop binding and an explicit Off state. Meeting output begins with two linear status rows; prompt text and switches appear only after choosing Automatic title or End-of-meeting summary. Audio exposes only the current/next meeting type at first glance. The linear `Recognition` disclosure owns the cloud/on-device choice, local model lifecycle, language, speaker separation, and source lanes; those controls lock together for the duration of a meeting.
- **Notices:** actionable system states with concrete language.

## Interaction rules

- Auto-follow only while the user remains near the live edge.
- Enter sends Agent questions; Shift+Enter adds a line.
- `⌘K` focuses meeting search.
- `Fn + M` starts or stops listening by default while Arco is running. It uses a macOS-native Fn-state listener because Carbon-style global shortcut registration does not support Fn. User-defined Command/Control/Option/Shift combinations continue through the registered application shortcut layer.
- The 210px navigation rail remains stable at normal desktop widths and narrows to 202px at 1024px. During capture, Current renders Transcript in the central column and Agent at its right; while idle, it renders only the start surface. Below compact desktop width, the live reading panes and the idle overview both stack in reading order instead of becoming competing overlays.
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
3. run component and E2E tests;
4. run `npx impeccable detect src`;
5. inspect the rendered app at 1240×820 and 1080×750, then simulate a dark operating-system appearance at 1024px to verify Arco remains light before checking the packaged native app separately;
6. refresh this document when actual tokens or components change.
