# Local credential storage

Arco stores provider credentials at `~/.arco/credentials.json`. The directory is
0700 and files are 0600. It is a plaintext local file restricted to the current
OS user, not an encrypted vault. Do not include it in diagnostics or transcripts.

The version-1 document contains a `providers` object: `deepgram` and `elevenLabs`
store `apiKey`; `doubao` stores `appId` (or the new API key) and `accessToken`;
`gptLive` stores the existing versioned OAuth object, including refresh token.
Settings continue to show only connection status. Verification still precedes
saving an API key. GPT Live refresh and disconnect update only their own entry.

All readers and writers share a process-safe lock. Writes replace a synced,
private temporary file atomically. Malformed files, future versions, symlinks
and hard-linked files are rejected without overwriting existing data. Updating
one provider preserves other entries. The app has no Keychain fallback, so
removing an entry cannot resurrect an old credential.

Existing installations can re-enter credentials or, after quitting Arco, run:

```sh
uv run --no-project python native/migrate-credentials.py
```

This explicit migration is the only credential code that accesses Keychain.
It preserves existing JSON entries and imports available legacy credentials.
Its output contains provider names and migration status only. Old Keychain
items remain untouched for rollback and are never accessed by the new app.
App-signing certificates remain managed by the existing build signing script;
they are unrelated to the app's provider credential store.
