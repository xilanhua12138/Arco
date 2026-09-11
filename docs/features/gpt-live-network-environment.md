# GPT Live follows the user’s login shell and native macOS networking

## Verified distinction from Dayflow

On 2026-09-11, reproducing Dayflow’s login-shell launch with the installed Codex
0.153.4 and no inherited proxy variables returned OK in 22.7 seconds. Launching
the installed Arco v0.3.23 GPT Live worker under the same shell still timed out
connecting to ChatGPT after 30.8 seconds. Its login credential was unexpired.

Dayflow uses the configured login shell with `-l -i -c`:
[LoginShellRunner](https://github.com/JerryZLiu/Dayflow/blob/09b9c7eb8c738bbbaa504a6d285ef3d9c76d0af8/Dayflow/Dayflow/Core/AI/LoginShellRunner.swift),
[ChatCLIProcessRunner](https://github.com/JerryZLiu/Dayflow/blob/09b9c7eb8c738bbbaa504a6d285ef3d9c76d0af8/Dayflow/Dayflow/Core/AI/ChatCLIProcessRunner.swift).
The installed Codex binary also imports CFNetwork’s native proxy APIs; its
[HTTP client](https://github.com/openai/codex/blob/main/codex-rs/http-client/README.md)
owns system/PAC/environment routing. Arco’s old ureq transport only inspected
environment variables. Shell startup alone therefore did not close that gap.

## Implementation

GPT Live now starts through the user’s configured login/interactive shell,
using positional arguments and exec to preserve PID, pipes and cancellation.
No command/path is evaluated as shell text. Local auth-status and logout avoid
shell startup. The live probe uses the same bootstrap as the installed worker.

The transport resolves the complete destination URL using proxy/bypass environment
variables when explicitly supplied, otherwise native `CFNetworkCopySystemProxySettings`
and `CFNetworkCopyProxiesForURL`. WebSocket URLs are mapped to HTTPS for system
routing while retaining their path/query. CFNetwork chooses the direct or proxy
route, including system exceptions. An explicit empty proxy or matching NO_PROXY
keeps a direct route. WSS_PROXY can override the WebSocket route independently.

OAuth login/refresh, call creation and the sideband use this shared resolver.
No GPT Live scutil parser, proxy-environment injection, hardcoded proxy address,
shell-profile edits or global network-setting changes are involved. The pre-existing
Agent CLI system-proxy bridge is outside this change.

The scope is login-shell startup plus native per-URL direct/manual proxy selection,
not a copy of all Codex networking features. PAC evaluation is not implemented and
returns a clear error rather than silently bypassing the configured route. The
existing sideband transport supports HTTP CONNECT, not SOCKS-only or HTTPS-proxy
connections. WebRTC media connectivity is verified separately from HTTP/sideband.

## Validation

Tests cover shell argument preservation/injection resistance, environment priority,
explicit direct routes, bypass domains, per-URL WebSocket mapping, WSS overrides,
and native CFNetwork direct/HTTP proxy dictionaries. Existing OAuth, call and media
transport tests remain in place. Real connection checks use synthetic audio rather
than the microphone or a private meeting transcript.

Final local validation on 2026-09-11: 186 core tests and 29 GPT Live tests passed;
both crates passed Clippy with warnings denied. The signed native app build passed
its boundary checks. With all proxy environment variables removed, the live probe
received model speech and the expected assistant transcript. After installation,
the bundled worker reported connecting → connected → disconnecting and exited 0
in 7.65 seconds using a synthetic-silence recorder and an empty diagnostic document.
All 105 existing transcript files retained identical hashes. Arco reopened and
loaded the user's historical meeting. No microphone capture was used in validation.
