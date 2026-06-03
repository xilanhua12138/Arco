#!/usr/bin/env python3
"""Arco meeting listener (Deepgram).

Reads 16kHz / 16-bit / mono PCM from stdin, streams it to Deepgram real-time ASR
with diarize=true (multi-speaker), and appends "[time] Speaker N: text" lines to
transcript.md in real time.

Upstream (stdin) is `recorder` (ScreenCaptureKit system audio + microphone).
Usage: recorder both | listen.py <transcript_path>
Requires DEEPGRAM_API_KEY (free key at https://deepgram.com).
"""
from __future__ import annotations

import asyncio
import fcntl
import os
import json
import select
import sys
import time
from datetime import datetime

import websockets

KEY = os.environ.get("DEEPGRAM_API_KEY", "")
# nova-3 + zh-Hans gives the cleanest Mandarin transcription (nova-2/zh garbles
# characters, nova-3/multi mis-decodes Chinese). Override via .env if needed.
LANG = os.environ.get("DEEPGRAM_LANG", "zh-Hans")
MODEL = os.environ.get("DEEPGRAM_MODEL", "nova-3")
URL = (
    f"wss://api.deepgram.com/v1/listen?model={MODEL}&language={LANG}"
    "&encoding=linear16&sample_rate=16000&channels=1"
    "&punctuate=true&diarize=true&interim_results=false&endpointing=800"
)


def label(spk) -> str:
    try:
        return f"Speaker {int(spk) + 1}"
    except (ValueError, TypeError):
        return "Speaker"


class Transcript:
    def __init__(self, path: str):
        self.path = path
        self._seen: set[str] = set()
        os.makedirs(os.path.dirname(path), exist_ok=True)
        if not os.path.exists(path):
            with open(path, "w", encoding="utf-8") as f:
                f.write(f"# Meeting Transcript\n\n> Started: {datetime.now():%Y-%m-%d %H:%M:%S} (live)\n\n")

    def add(self, text: str, spk) -> None:
        text = text.strip()
        if not text or text in self._seen:
            return
        self._seen.add(text)
        ts = time.strftime("%H:%M:%S", time.localtime())
        line = f"**[{ts}] {label(spk)}:** {text}\n\n"
        with open(self.path, "a", encoding="utf-8") as f:
            fcntl.flock(f, fcntl.LOCK_EX)  # single transcript, lock on append
            f.write(line)
            fcntl.flock(f, fcntl.LOCK_UN)
        print(f"[transcript] {label(spk)}: {text}", flush=True)


async def run(path: str) -> None:
    if not KEY:
        print("Missing DEEPGRAM_API_KEY (get a free key at https://deepgram.com, put it in .env)", file=sys.stderr)
        sys.exit(1)
    tr = Transcript(path)
    async with websockets.connect(URL, additional_headers={"Authorization": f"Token {KEY}"}) as ws:
        loop = asyncio.get_event_loop()

        async def reader() -> None:
            fd = sys.stdin.buffer.fileno()
            os.set_blocking(fd, False)
            silence = b"\0" * 3200
            while True:
                ready, _, _ = await loop.run_in_executor(None, select.select, [fd], [], [], 1.0)
                if not ready:
                    await ws.send(silence)
                    continue
                try:
                    chunk = os.read(fd, 3200)
                except BlockingIOError:
                    await ws.send(silence)
                    continue
                if chunk == b"":
                    await ws.send(json.dumps({"type": "CloseStream"}))
                    return
                await ws.send(chunk)

        async def receiver() -> None:
            async for msg in ws:
                try:
                    obj = json.loads(msg)
                except Exception:
                    continue
                if obj.get("type") != "Results" or not obj.get("is_final"):
                    continue
                alt = (obj.get("channel", {}).get("alternatives") or [{}])[0]
                text = (alt.get("transcript") or "").strip()
                if not text:
                    continue
                # `transcript` is the clean utterance text. With diarize=true the
                # `words` array sometimes contains duplicated tokens, so never rebuild
                # the text from words -- only read the speaker label from them.
                # Deepgram emits a separate final at each utterance/speaker boundary,
                # so one message maps to one speaker in practice.
                words = alt.get("words") or []
                spk = words[0].get("speaker") if words else None
                tr.add(text, spk)

        await asyncio.gather(reader(), receiver())


if __name__ == "__main__":
    p = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/.claude/meeting-transcripts/current.md")
    try:
        asyncio.run(run(p))
    except KeyboardInterrupt:
        pass
