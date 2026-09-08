# Codex CLI follows the macOS manual proxy

A Finder-launched Arco process does not inherit proxy exports from the shell. The CLI can discover its executable and ChatGPT login while its network requests bypass the system proxy and time out.

Before launching an Agent CLI process, Arco now reads the macOS manual proxy configuration using `/usr/sbin/scutil --proxy` and translates enabled HTTP, HTTPS and SOCKS entries into child-process environment variables. This applies to both connection tests and streaming conversations. Existing explicit proxy environment variables, including empty values, take precedence. Existing `NO_PROXY` values are preserved; supported system exception entries are translated when absent. No global environment, Codex user configuration, sandbox, or timeout setting is changed. PAC scripts require per-URL evaluation and are not translated by this manual-proxy fallback.

Validation on 2026-09-08: the original installed app had no proxy variables and displayed a 90-second timeout while Codex repeatedly reported request timeouts. The configured system HTTP/HTTPS proxy was `127.0.0.1:7890`. A direct connection to the Codex endpoint timed out; using that proxy reached the endpoint. With the same Codex binary, login, arguments and filesystem sandbox, the authenticated probe succeeded. The patched `AgentRunner::test_provider` then succeeded in about 14 seconds with all proxy variables removed from its parent environment.

Regression coverage: captured system settings, disabled/malformed entries, port bounds, IPv6, explicit environment precedence, exception preservation, and environment delivery to a real subprocess. Existing Agent and backend tests cover connection failure, timeout, cancellation and workspace isolation.

## Dayflow comparison

Reviewed upstream commit `5d14c1ef35bd8bd7b7a3dee259e58ffb668dd0bd` on 2026-09-08:

- [LoginShellRunner.swift](https://github.com/JerryZLiu/Dayflow/blob/5d14c1ef35bd8bd7b7a3dee259e58ffb668dd0bd/Dayflow/Dayflow/Core/AI/LoginShellRunner.swift#L58-L73) invokes the user's login shell with `-l -i -c`.
- [ChatCLIProcessRunner.swift](https://github.com/JerryZLiu/Dayflow/blob/5d14c1ef35bd8bd7b7a3dee259e58ffb668dd0bd/Dayflow/Dayflow/Core/AI/ChatCLIProcessRunner.swift#L206-L220) uses the same shell for actual CLI execution and merges explicit environment overrides. This inherits shell-configured networking rather than selecting a proxy. The runner's default timeout is 300 seconds.
- With inherited proxy variables removed, running that shell pattern on the affected Mac produced no proxy variables. Copying the shell launch alone would therefore not supply this Mac's enabled system proxy. Arco retains direct executable invocation and bridges the already enabled manual system settings only when explicit proxy variables are absent.

No proxy host or port is hardcoded in production logic. Disabled system proxies leave the child environment unchanged; a real subprocess regression verifies this. Interface-scoped and supplemental settings are excluded from global proxy selection; a regression first reproduced the incorrect promotion of a scoped proxy, then passed after restricting parsing to the top-level dictionary. PAC evaluation and interface/domain-specific routing are not implemented by this fallback.
