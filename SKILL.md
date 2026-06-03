---
name: arco
description: Listen to a meeting and produce a real-time transcript with multi-speaker diarization. Captures system audio (the remote side of an online call) plus the microphone (you), mixes them, and runs Deepgram real-time ASR with diarization to label every line as Speaker 1/2/3..., writing it live to transcript.md that Claude can read at any time to summarize, extract action items, or answer questions grounded in the meeting. Use this when the user says things like "listen to the meeting", "take meeting notes", "start meeting transcription", "record this meeting", "听会", "监听会议", or "记录这次会议". Always STOP the listener (bin/stop.sh) as soon as the user signals the meeting is over ("stop listening", "会议结束", "结束监听", "好了用完了", "停止记录") or asks for a final summary — do not leave it running.
---

# Arco — Meeting Listener (multi-speaker diarization)

Turns a live meeting into a timestamped, speaker-labeled transcript you can read and analyze at any moment.

## Architecture

```
recorder (Swift)                                      listen.py
ScreenCaptureKit system audio + AVAudioEngine mic
mixed/resampled → 16k PCM ──stdout|stdin────────────► Deepgram realtime ASR
                                                        (diarize=true, multi-speaker)
                                                             │
                             appended live ◄─────────────────┘
                  ~/.claude/meeting-transcripts/current.md
```

## Usage

### 0. First-time initialization

Before the first start in a fresh checkout, run:

```bash
bash ~/.claude/skills/arco/bin/init.sh
```

This checks the macOS toolchain, creates `~/.claude/meeting-transcripts`,
creates `.env` from `.env.example` if needed, preloads `websockets`, and
builds/signs the `recorder` binary. If it reports a missing
`DEEPGRAM_API_KEY`, fill `~/.claude/skills/arco/.env` and rerun `init.sh`.

On restricted networks, export proxy env vars in the same shell before
`init.sh` and `start.sh`; see [Network / proxy](#network--proxy).

### 1. Start listening

```bash
bash ~/.claude/skills/arco/bin/start.sh both
```

`both` (default — system audio + mic mixed, Deepgram separates all speakers) · `system` (remote only) · `mic` (mic only, in-person meeting).

First start after initialization, macOS asks for **Screen Recording** and
**Microphone** permission. The command-line `recorder` binary may need to be
ticked manually under *System Settings → Privacy & Security → Screen
Recording*, then re-run once. **Do not mute system output**, or system audio
can't be captured.

> **Before starting, check whether Deepgram needs a proxy on your network** — see [Network / proxy](#network--proxy). If you're on a restricted network (e.g. mainland China), export the proxy env vars in the same shell *before* `start.sh`, otherwise the transcript stays empty or shows only stray single words.

### 2. Read the transcript (read it incrementally — don't re-read the whole file)

The transcript grows continuously, so **don't `Read` the whole file every turn** —
it re-floods your context with lines you've already seen. Instead, remember how far
you've read and pull only what's new:

- **First read:** `wc -l ~/.claude/meeting-transcripts/current.md` to get the
  current line count `N` (read the file itself if you need the backlog).
- **Each later read:** `tail -n +$((N+1)) ~/.claude/meeting-transcripts/current.md`
  to get only the lines appended since last time, then update `N` to the new total.

A new session truncates the file, so reset `N` to 0 whenever the listener is
restarted.

Format: `**[HH:MM:SS] Speaker N:** spoken text`, updated live. While the meeting runs you can ask things like "how is the X we just discussed implemented in the code?", "summarize the key points so far", or "list the action items".

### 3. Status / Stop

```bash
bash ~/.claude/skills/arco/bin/status.sh   # running state + recent lines
bash ~/.claude/skills/arco/bin/stop.sh     # stop listening (kills recorder + listen.py)
```

**Auto-stop (important):** the listener keeps running in the
background until it is explicitly stopped — it will not end on its own. As soon
as the user indicates the meeting is finished (e.g. "会议结束了", "结束监听",
"好了用完了", "stop listening", "停止记录") or asks for a final wrap-up/summary,
run `bin/stop.sh` automatically before doing anything else, then read the final
transcript and answer. Never leave the recorder running after the user is done.
The stopped session is preserved at `transcript-<timestamp>.md` for later reference.

## Config (BYOK)

`~/.claude/skills/arco/.env`:
- `DEEPGRAM_API_KEY` (required — get a free key at https://deepgram.com, $200 credit)
- optional `DEEPGRAM_MODEL` (default `nova-3`), `DEEPGRAM_LANG` (default `zh-Hans` — nova-3 Mandarin Simplified; use `en` for English meetings)

Requires `uv` (it auto-pulls `websockets` via `--with`, no manual install).

## Network / proxy

Deepgram's ASR runs on its own servers, reached over the public internet
(`api.deepgram.com`). **From networks that can't reach it directly (e.g. mainland
China), check whether you need a proxy before starting** — the symptom is a
transcript that stays empty or shows only stray single words even though the mic
and audio are fine. (Diagnostically, the offline REST API returns
`SLOW_UPLOAD: Request upload timeout`, and the realtime WebSocket silently drops
most audio packets, so only fragments get transcribed.) The bottleneck is the
network to Deepgram, not the audio capture.

If Deepgram is **not** directly reachable, export proxy env vars in the *same
shell that launches the listener*, then start it — `listen.py` uses `websockets`
(≥14), which picks up `HTTPS_PROXY` automatically:

```bash
export HTTPS_PROXY=http://<your-local-proxy-host>:<port>
export HTTP_PROXY=http://<your-local-proxy-host>:<port>
bash ~/.claude/skills/arco/bin/start.sh both
```

Use your own local proxy address/port — don't hardcode one. If Deepgram is
directly reachable on your network, skip this entirely; no proxy is needed.

## Notes

- **Multi-speaker diarization** is done by Deepgram (`diarize=true`), labeling lines as `Speaker 1/2/3...`, kept consistent over time.
- Why Deepgram and not Doubao: Doubao's speaker diarization only exists in its **file (offline) recognition** API (`additions.speaker`), not the streaming endpoint — so it can't do real-time multi-speaker labeling. Deepgram does it live in one WebSocket.
- Transcripts are saved at `~/.claude/meeting-transcripts/transcript-<timestamp>.md`; `current.md` always points to the latest session.
