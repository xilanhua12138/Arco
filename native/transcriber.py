#!/usr/bin/env python3
"""Arco's app-owned Deepgram multichannel streaming transcriber.

Input is standard interleaved stereo PCM: 16 kHz, signed Int16LE,
channel 0 = system/remote audio, channel 1 = microphone/in-room audio.
Both channels are diarized. Within one WebSocket, a speaker identity is the
composite (channel, Deepgram speaker id). Reconnects receive a new identity
namespace so a reset Deepgram speaker number cannot falsely merge two people.
"""

from __future__ import annotations

import asyncio
import collections
import fcntl
import json
import os
import re
import sys
import threading
import time
from dataclasses import dataclass
from urllib.parse import urlencode


SAMPLE_RATE = 16_000
CHANNELS = 2
BYTES_PER_SAMPLE = 2
FRAME_BYTES = CHANNELS * BYTES_PER_SAMPLE
READ_CHUNK_BYTES = 6_400  # 100 ms of stereo Int16LE PCM.
DEFAULT_BUFFER_SECONDS = 60
MAX_BUFFER_SECONDS = 300


@dataclass(frozen=True)
class Segment:
    channel: int
    speaker: int | None
    label: str
    text: str
    start: float
    end: float
    connection_id: int | None = None


@dataclass(frozen=True)
class AudioChunk:
    data: bytes
    start_frame: int

    @property
    def end_frame(self) -> int:
        return self.start_frame + len(self.data) // FRAME_BYTES


class BoundedAudioBuffer:
    """Thread-safe PCM queue that never blocks the recorder pipe.

    The oldest queued audio is discarded when the configured byte ceiling is
    reached. A chunk currently being sent is counted toward the ceiling but is
    never discarded; it is returned to the head of the queue if send fails.
    """

    def __init__(self, max_bytes: int):
        aligned = max(FRAME_BYTES, int(max_bytes) // FRAME_BYTES * FRAME_BYTES)
        self.max_bytes = aligned
        self._condition = threading.Condition()
        self._queued: collections.deque[AudioChunk] = collections.deque()
        self._queued_bytes = 0
        self._inflight: AudioChunk | None = None
        self._closed = False
        self.dropped_bytes = 0

    @property
    def buffered_bytes(self) -> int:
        with self._condition:
            return self._queued_bytes + (
                len(self._inflight.data) if self._inflight is not None else 0
            )

    @property
    def finished(self) -> bool:
        with self._condition:
            return self._closed and not self._queued and self._inflight is None

    def push(self, chunk: AudioChunk) -> None:
        data = chunk.data[: len(chunk.data) // FRAME_BYTES * FRAME_BYTES]
        if not data:
            return
        start_frame = chunk.start_frame
        initial_trim = 0
        if len(data) > self.max_bytes:
            initial_trim = len(data) - self.max_bytes
            initial_trim = (
                (initial_trim + FRAME_BYTES - 1) // FRAME_BYTES * FRAME_BYTES
            )
            data = data[initial_trim:]
            start_frame += initial_trim // FRAME_BYTES

        with self._condition:
            self.dropped_bytes += initial_trim
            inflight_bytes = len(self._inflight.data) if self._inflight else 0
            while (
                self._queued
                and inflight_bytes + self._queued_bytes + len(data) > self.max_bytes
            ):
                removed = self._queued.popleft()
                self._queued_bytes -= len(removed.data)
                self.dropped_bytes += len(removed.data)

            available = self.max_bytes - inflight_bytes - self._queued_bytes
            if len(data) > available:
                trim = len(data) - max(0, available)
                trim = (trim + FRAME_BYTES - 1) // FRAME_BYTES * FRAME_BYTES
                trim = min(trim, len(data))
                self.dropped_bytes += trim
                data = data[trim:]
                start_frame += trim // FRAME_BYTES
            if data:
                queued = AudioChunk(data=data, start_frame=start_frame)
                self._queued.append(queued)
                self._queued_bytes += len(data)
                self._condition.notify_all()

    def acquire(self, timeout: float | None = None) -> AudioChunk | None:
        deadline = None if timeout is None else time.monotonic() + timeout
        with self._condition:
            if self._inflight is not None:
                raise RuntimeError("only one audio sender may acquire a chunk")
            while not self._queued and not self._closed:
                remaining = None if deadline is None else deadline - time.monotonic()
                if remaining is not None and remaining <= 0:
                    return None
                self._condition.wait(remaining)
            if not self._queued:
                return None
            chunk = self._queued.popleft()
            self._queued_bytes -= len(chunk.data)
            self._inflight = chunk
            return chunk

    def ack(self, chunk: AudioChunk) -> None:
        with self._condition:
            if self._inflight != chunk:
                raise RuntimeError("cannot acknowledge an unowned audio chunk")
            self._inflight = None
            self._condition.notify_all()

    def nack(self, chunk: AudioChunk) -> None:
        with self._condition:
            if self._inflight != chunk:
                raise RuntimeError("cannot retry an unowned audio chunk")
            self._inflight = None
            self._queued.appendleft(chunk)
            self._queued_bytes += len(chunk.data)
            self._condition.notify_all()

    def close(self) -> None:
        with self._condition:
            self._closed = True
            self._condition.notify_all()


class StdinAudioPump:
    """Continuously drains recorder stdout into a bounded in-memory queue."""

    def __init__(
        self,
        input_fd: int,
        audio_buffer: BoundedAudioBuffer,
        read_size: int = READ_CHUNK_BYTES,
    ):
        self.input_fd = input_fd
        self.audio_buffer = audio_buffer
        self.read_size = max(FRAME_BYTES, read_size)
        self._thread = threading.Thread(
            target=self._run,
            name="arco-stdin-audio-pump",
            daemon=True,
        )

    def start(self) -> None:
        self._thread.start()

    def join(self, timeout: float | None = None) -> None:
        self._thread.join(timeout)

    def _run(self) -> None:
        next_frame = 0
        carry = b""
        try:
            while True:
                data = os.read(self.input_fd, self.read_size)
                if data == b"":
                    break
                data = carry + data
                aligned_size = len(data) // FRAME_BYTES * FRAME_BYTES
                carry = data[aligned_size:]
                aligned = data[:aligned_size]
                if aligned:
                    self.audio_buffer.push(AudioChunk(aligned, next_frame))
                    next_frame += len(aligned) // FRAME_BYTES
        except OSError as error:
            print(f"audio input stopped: {error}", file=sys.stderr, flush=True)
        finally:
            self.audio_buffer.close()


def participant_label(channel: int, speaker: object) -> str:
    prefix = "Remote" if channel == 0 else "In room"
    try:
        return f"{prefix} {int(speaker) + 1}"
    except (TypeError, ValueError):
        return prefix


def response_channel(payload: dict) -> int:
    value = payload.get("channel_index", 0)
    if isinstance(value, (list, tuple)):
        value = value[0] if value else 0
    try:
        return int(value)
    except (TypeError, ValueError):
        return 0


def _number(value: object, fallback: float) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return fallback


def _word_text(word: dict) -> str:
    return str(word.get("punctuated_word") or word.get("word") or "").strip()


def _is_cjk(value: str) -> bool:
    return bool(re.search(r"[\u3400-\u9fff\u3040-\u30ff\uac00-\ud7af]", value))


def join_words(tokens: list[str]) -> str:
    """Join Deepgram words without corrupting CJK or punctuation."""
    result = ""
    for token in (token for token in tokens if token):
        if not result:
            result = token
        elif _is_cjk(result[-1:]) or _is_cjk(token[:1]):
            result += token
        elif re.match(r"^[,.;:!?%\)\]\}，。！？、；：）】]", token):
            result += token
        elif result.endswith(("(", "[", "{", "（", "【")):
            result += token
        else:
            result += " " + token
    return result.strip()


def segments_from_result(payload: dict) -> list[Segment]:
    """Convert one final Deepgram result into speaker-boundary segments.

    This is deliberately stateless: two identical final utterances at different
    times remain two real segments. Both channels split whenever word.speaker
    changes, so a single alternative may produce multiple participants.
    """
    if payload.get("type") != "Results" or not payload.get("is_final"):
        return []
    alternatives = payload.get("channel", {}).get("alternatives") or [{}]
    alternative = alternatives[0]
    channel = response_channel(payload)
    words = alternative.get("words") or []
    payload_start = _number(payload.get("start"), 0.0)
    payload_end = payload_start + _number(payload.get("duration"), 0.0)

    segments: list[Segment] = []
    current_speaker: int | None = None
    current_words: list[str] = []
    current_start = payload_start
    current_end = payload_end
    has_group = False

    def flush() -> None:
        nonlocal current_words, has_group
        text = join_words(current_words)
        if text:
            segments.append(
                Segment(
                    channel=channel,
                    speaker=current_speaker,
                    label=participant_label(channel, current_speaker),
                    text=text,
                    start=current_start,
                    end=max(current_start, current_end),
                )
            )
        current_words = []
        has_group = False

    for word in words:
        raw_speaker = word.get("speaker")
        try:
            speaker = int(raw_speaker) if raw_speaker is not None else None
        except (TypeError, ValueError):
            speaker = None
        token = _word_text(word)
        word_start = _number(word.get("start"), payload_start)
        word_end = _number(word.get("end"), word_start)
        if has_group and speaker != current_speaker:
            flush()
        if not has_group:
            current_speaker = speaker
            current_start = word_start
            current_end = word_end
            has_group = True
        else:
            current_end = max(current_end, word_end)
        if token:
            current_words.append(token)
    flush()

    if segments:
        return segments
    text = str(alternative.get("transcript") or "").strip()
    if not text:
        return []
    return [
        Segment(
            channel=channel,
            speaker=None,
            label=participant_label(channel, None),
            text=text,
            start=payload_start,
            end=max(payload_start, payload_end),
        )
    ]


def offset_segments(segments: list[Segment], seconds: float) -> list[Segment]:
    """Move connection-local Deepgram offsets onto the session timeline."""
    return [
        Segment(
            channel=segment.channel,
            speaker=segment.speaker,
            label=segment.label,
            text=segment.text,
            start=segment.start + seconds,
            end=segment.end + seconds,
            connection_id=segment.connection_id,
        )
        for segment in segments
    ]


class SpeakerRegistry:
    """Namespace Deepgram speaker ids by WebSocket connection.

    Deepgram can restart speaker numbering after reconnect. Treating speaker 0
    before and after a reconnect as one person would be a false identity merge,
    so each connection-local identity receives a new session-wide anonymous
    label. This may split one person across a network interruption, but never
    silently claims that two people are the same.
    """

    def __init__(self):
        self._labels: dict[tuple[int, int, int | None], int] = {}
        self._next = {0: 1, 1: 1}

    def relabel(self, segments: list[Segment], connection_id: int) -> list[Segment]:
        result: list[Segment] = []
        for segment in segments:
            key = (connection_id, segment.channel, segment.speaker)
            number = self._labels.get(key)
            if number is None:
                number = self._next.setdefault(segment.channel, 1)
                self._next[segment.channel] = number + 1
                self._labels[key] = number
            prefix = "Remote" if segment.channel == 0 else "In room"
            result.append(
                Segment(
                    channel=segment.channel,
                    speaker=segment.speaker,
                    label=f"{prefix} {number}",
                    text=segment.text,
                    start=segment.start,
                    end=segment.end,
                    connection_id=connection_id,
                )
            )
        return result


class Transcript:
    def __init__(self, path: str):
        self.path = path
        os.makedirs(os.path.dirname(path), exist_ok=True)
        if not os.path.exists(path):
            raise FileNotFoundError(
                "The desktop host must initialize the transcript before transcription"
            )

    def append(self, segment: Segment, stream_started_at: float) -> None:
        # Deepgram's segment offset is converted to a wall-clock timestamp so
        # the markdown stays compatible with existing Arco history files.
        timestamp = time.strftime(
            "%H:%M:%S", time.localtime(stream_started_at + segment.start)
        )
        # Do not deduplicate by text. Participants often repeat themselves, and
        # distinct finals with distinct timing are distinct meeting evidence.
        line = f"**[{timestamp}] {segment.label}:** {segment.text}\n\n"
        metadata = (
            f"<!-- arco channel={segment.channel} "
            f"speaker={segment.speaker if segment.speaker is not None else 'unknown'} "
            f"stream={segment.connection_id if segment.connection_id is not None else 'unknown'} "
            f"start={segment.start:.3f} end={segment.end:.3f} -->\n\n"
        )
        with open(self.path, "a", encoding="utf-8") as transcript:
            fcntl.flock(transcript, fcntl.LOCK_EX)
            transcript.write(line)
            transcript.write(metadata)
            transcript.flush()
            fcntl.flock(transcript, fcntl.LOCK_UN)
        print(f"[transcript] {segment.label}: {segment.text}", flush=True)


class OrderedTranscriptWriter:
    """Small reorder window for finals arriving independently per channel."""

    def __init__(
        self,
        transcript: Transcript,
        stream_started_at: float,
        reorder_seconds: float = 2.0,
    ):
        self.transcript = transcript
        self.stream_started_at = stream_started_at
        self.reorder_seconds = reorder_seconds
        self.pending: list[tuple[int, Segment]] = []
        self.sequence = 0
        self.latest_end = 0.0

    def add(self, segments: list[Segment]) -> None:
        for segment in segments:
            self.pending.append((self.sequence, segment))
            self.sequence += 1
            self.latest_end = max(self.latest_end, segment.end)
        self._flush(self.latest_end - self.reorder_seconds)

    def finish(self) -> None:
        self._flush(float("inf"))

    def _flush(self, cutoff: float) -> None:
        ready = [item for item in self.pending if item[1].end <= cutoff]
        self.pending = [item for item in self.pending if item[1].end > cutoff]
        ready.sort(key=lambda item: (item[1].start, item[1].channel, item[0]))
        for _, segment in ready:
            self.transcript.append(segment, self.stream_started_at)


def deepgram_url() -> str:
    params = {
        "model": os.environ.get("DEEPGRAM_MODEL", "nova-3"),
        "language": os.environ.get("DEEPGRAM_LANG", "zh-Hans"),
        "encoding": "linear16",
        "sample_rate": "16000",
        "channels": "2",
        "multichannel": "true",
        "diarize_model": "latest",
        "punctuate": "true",
        "smart_format": "true",
        "endpointing": "300",
    }
    return f"wss://api.deepgram.com/v1/listen?{urlencode(params)}"


def configured_buffer_seconds() -> int:
    try:
        value = int(os.environ.get("ARCO_AUDIO_BUFFER_SECONDS", ""))
    except ValueError:
        value = DEFAULT_BUFFER_SECONDS
    return max(1, min(value or DEFAULT_BUFFER_SECONDS, MAX_BUFFER_SECONDS))


def signal_ready() -> None:
    """Atomically tell the desktop host that Deepgram accepted the socket."""
    ready_path = os.environ.get("ARCO_READY_FILE", "").strip()
    if not ready_path:
        return
    ready_path = os.path.abspath(os.path.expanduser(ready_path))
    os.makedirs(os.path.dirname(ready_path), exist_ok=True)
    temporary = f"{ready_path}.{os.getpid()}.tmp"
    with open(temporary, "w", encoding="utf-8") as ready_file:
        ready_file.write("deepgram-ready\n")
        ready_file.flush()
        os.fsync(ready_file.fileno())
    os.replace(temporary, ready_path)


def websocket_status_code(error: BaseException) -> int | None:
    for candidate in (error, getattr(error, "response", None)):
        if candidate is None:
            continue
        for attribute in ("status_code", "status"):
            value = getattr(candidate, attribute, None)
            try:
                return int(value)
            except (TypeError, ValueError):
                continue
    return None


def is_non_retryable_websocket_error(error: BaseException) -> bool:
    status = websocket_status_code(error)
    return status is not None and 400 <= status < 500


class AudioDiscontinuity(ConnectionError):
    pass


class DeepgramTerminalError(RuntimeError):
    pass


def deepgram_payload_error(payload: dict) -> str | None:
    payload_type = str(payload.get("type") or "").lower()
    status = str(payload.get("status") or "").lower()
    raw_error = payload.get("error")
    is_error = payload_type == "error" or raw_error not in (None, "", False)
    is_error = is_error or (
        payload_type == "metadata" and status in {"error", "failed", "invalid"}
    )
    if not is_error:
        return None
    if isinstance(raw_error, dict):
        raw_error = raw_error.get("message") or raw_error.get("description")
    message = (
        raw_error
        or payload.get("message")
        or payload.get("description")
        or payload.get("code")
        or "Deepgram returned an unknown streaming error"
    )
    return str(message).strip()


async def stream_connection(
    socket: object,
    audio_buffer: BoundedAudioBuffer,
    writer: OrderedTranscriptWriter,
    speakers: SpeakerRegistry,
    connection_id: int,
) -> None:
    """Send one continuous audio range and receive its final results."""
    anchor_ready = asyncio.Event()
    connection_audio_origin: float | None = None

    async def send_audio() -> None:
        nonlocal connection_audio_origin
        expected_frame: int | None = None
        current: AudioChunk | None = None
        last_keepalive = time.monotonic()
        try:
            while True:
                current = audio_buffer.acquire(0)
                if current is None:
                    if audio_buffer.finished:
                        await socket.send(json.dumps({"type": "CloseStream"}))
                        return
                    if time.monotonic() - last_keepalive >= 5:
                        await socket.send(json.dumps({"type": "KeepAlive"}))
                        last_keepalive = time.monotonic()
                    await asyncio.sleep(0.02)
                    continue
                if expected_frame is not None and current.start_frame != expected_frame:
                    audio_buffer.nack(current)
                    gap_start = expected_frame
                    gap_end = current.start_frame
                    current = None
                    raise AudioDiscontinuity(
                        f"buffer dropped audio frames {gap_start}..{gap_end}; "
                        "opening a new timestamped stream"
                    )
                if connection_audio_origin is None:
                    connection_audio_origin = current.start_frame / SAMPLE_RATE
                    anchor_ready.set()
                try:
                    await socket.send(current.data)
                except BaseException:
                    audio_buffer.nack(current)
                    current = None
                    raise
                audio_buffer.ack(current)
                expected_frame = current.end_frame
                current = None
        finally:
            if current is not None:
                audio_buffer.nack(current)

    async def receive_results() -> None:
        async for message in socket:
            try:
                payload = json.loads(message)
            except (TypeError, json.JSONDecodeError):
                continue
            terminal_error = deepgram_payload_error(payload)
            if terminal_error:
                raise DeepgramTerminalError(terminal_error)
            segments = segments_from_result(payload)
            if not segments:
                continue
            await anchor_ready.wait()
            assert connection_audio_origin is not None
            session_segments = offset_segments(segments, connection_audio_origin)
            writer.add(speakers.relabel(session_segments, connection_id))

    sender = asyncio.create_task(send_audio())
    receiver = asyncio.create_task(receive_results())
    try:
        await asyncio.gather(sender, receiver)
    finally:
        sender.cancel()
        receiver.cancel()
        await asyncio.gather(sender, receiver, return_exceptions=True)


def session_started_at() -> float:
    try:
        return float(os.environ.get("ARCO_SESSION_STARTED_AT_UNIX", ""))
    except ValueError:
        return time.time()


async def transcribe(path: str) -> None:

    api_key = os.environ.get("DEEPGRAM_API_KEY", "").strip()
    if not api_key:
        raise RuntimeError("Missing DEEPGRAM_API_KEY")

    transcript = Transcript(path)
    input_fd = sys.stdin.buffer.fileno()
    buffer_seconds = configured_buffer_seconds()
    audio_buffer = BoundedAudioBuffer(SAMPLE_RATE * FRAME_BYTES * buffer_seconds)
    pump = StdinAudioPump(input_fd, audio_buffer)
    pump.start()

    # Import only after the pump starts so dependency import and every network
    # state still continuously drain recorder stdout.
    import websockets

    writer = OrderedTranscriptWriter(transcript, session_started_at())
    speakers = SpeakerRegistry()
    reconnect_delay = 1.0
    connection_id = 0

    try:
        while not audio_buffer.finished:
            try:
                async with websockets.connect(
                    deepgram_url(),
                    additional_headers={"Authorization": f"Token {api_key}"},
                    open_timeout=10,
                ) as socket:
                    connection_id += 1
                    signal_ready()
                    reconnect_delay = 1.0
                    await stream_connection(
                        socket,
                        audio_buffer,
                        writer,
                        speakers,
                        connection_id,
                    )
                    if not audio_buffer.finished:
                        raise ConnectionError(
                            "Deepgram closed before the recorder stream ended"
                        )
            except Exception as error:
                if isinstance(error, DeepgramTerminalError):
                    raise RuntimeError(
                        f"Deepgram rejected the streaming configuration: {error}"
                    ) from error
                if is_non_retryable_websocket_error(error):
                    status = websocket_status_code(error)
                    raise RuntimeError(
                        f"Deepgram rejected the streaming request (HTTP {status}); "
                        "check the API key and request settings"
                    ) from error
                if audio_buffer.finished:
                    break
                dropped_seconds = audio_buffer.dropped_bytes / (
                    SAMPLE_RATE * FRAME_BYTES
                )
                print(
                    f"[reconnect] Deepgram stream dropped "
                    f"({type(error).__name__}: {error}); retrying in "
                    f"{reconnect_delay:.0f}s; buffered="
                    f"{audio_buffer.buffered_bytes}B/{audio_buffer.max_bytes}B "
                    f"dropped={dropped_seconds:.1f}s",
                    file=sys.stderr,
                    flush=True,
                )
                await asyncio.sleep(reconnect_delay)
                reconnect_delay = min(reconnect_delay * 2, 15.0)
    finally:
        writer.finish()


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: transcriber.py <transcript-path>", file=sys.stderr)
        return 2
    try:
        asyncio.run(transcribe(os.path.abspath(os.path.expanduser(sys.argv[1]))))
        return 0
    except KeyboardInterrupt:
        return 130
    except Exception as error:
        print(f"transcriber failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
