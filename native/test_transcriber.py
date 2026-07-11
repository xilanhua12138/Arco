import asyncio
import importlib.util
import os
import pathlib
import sys
import tempfile
import unittest
from urllib.parse import parse_qs, urlparse


MODULE_PATH = pathlib.Path(__file__).with_name("transcriber.py")
SPEC = importlib.util.spec_from_file_location("arco_transcriber", MODULE_PATH)
transcriber = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = transcriber
SPEC.loader.exec_module(transcriber)


def result(channel, words, transcript="", start=0.0, duration=1.0, final=True):
    return {
        "type": "Results",
        "is_final": final,
        "channel_index": [channel, 2],
        "start": start,
        "duration": duration,
        "channel": {
            "alternatives": [{"transcript": transcript, "words": words}]
        },
    }


def word(text, speaker, start, end):
    return {
        "punctuated_word": text,
        "word": text.rstrip(".,!?"),
        "speaker": speaker,
        "start": start,
        "end": end,
    }


class MultichannelDiarizationTests(unittest.TestCase):
    def test_remote_channel_splits_every_consecutive_word_speaker_boundary(self):
        payload = result(
            0,
            [
                word("Hello", 0, 0.0, 0.2),
                word("there.", 0, 0.2, 0.5),
                word("Different", 1, 0.6, 0.9),
                word("voice.", 1, 0.9, 1.1),
                word("Back.", 0, 1.2, 1.5),
            ],
            "Hello there. Different voice. Back.",
        )

        segments = transcriber.segments_from_result(payload)

        self.assertEqual([segment.label for segment in segments], [
            "Remote 1",
            "Remote 2",
            "Remote 1",
        ])
        self.assertEqual([segment.text for segment in segments], [
            "Hello there.",
            "Different voice.",
            "Back.",
        ])
        self.assertEqual(
            [(segment.channel, segment.speaker) for segment in segments],
            [(0, 0), (0, 1), (0, 0)],
        )

    def test_in_room_channel_is_also_diarized_and_never_assumed_to_be_you(self):
        payload = result(
            1,
            [
                word("First", 0, 3.0, 3.2),
                word("person.", 0, 3.2, 3.5),
                word("Second", 2, 3.6, 3.8),
                word("person.", 2, 3.8, 4.1),
            ],
            "First person. Second person.",
            start=3.0,
        )

        segments = transcriber.segments_from_result(payload)

        self.assertEqual([segment.label for segment in segments], [
            "In room 1",
            "In room 3",
        ])
        self.assertNotIn("You", [segment.label for segment in segments])
        self.assertEqual(
            [(segment.channel, segment.speaker) for segment in segments],
            [(1, 0), (1, 2)],
        )

    def test_non_final_results_are_never_persisted(self):
        payload = result(0, [word("draft", 0, 0, 0.2)], "draft", final=False)
        self.assertEqual(transcriber.segments_from_result(payload), [])

    def test_identical_real_utterances_are_preserved_at_distinct_times(self):
        first = transcriber.segments_from_result(
            result(1, [word("Yes.", 0, 1.0, 1.2)], "Yes.", start=1.0)
        )[0]
        second = transcriber.segments_from_result(
            result(1, [word("Yes.", 0, 5.0, 5.2)], "Yes.", start=5.0)
        )[0]
        self.assertEqual(first.text, second.text)
        self.assertNotEqual((first.start, first.end), (second.start, second.end))

        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "transcript-test.md")
            pathlib.Path(path).write_text("# Meeting Transcript\n\n", encoding="utf-8")
            transcript = transcriber.Transcript(path)
            transcript.append(first, 1_700_000_000)
            transcript.append(second, 1_700_000_000)
            contents = pathlib.Path(path).read_text(encoding="utf-8")
        self.assertEqual(contents.count("In room 1:** Yes."), 2)
        self.assertIn("start=1.000 end=1.200", contents)
        self.assertIn("start=5.000 end=5.200", contents)

    def test_deepgram_contract_is_stereo_multichannel_with_latest_diarization(self):
        query = parse_qs(urlparse(transcriber.deepgram_url()).query)
        self.assertEqual(query["channels"], ["2"])
        self.assertEqual(query["multichannel"], ["true"])
        self.assertEqual(query["diarize_model"], ["latest"])
        self.assertEqual(query["endpointing"], ["300"])
        self.assertEqual(query["smart_format"], ["true"])
        self.assertNotIn("interim_results", query)
        self.assertNotIn("diarize", query)


class BufferReliabilityTests(unittest.TestCase):
    def test_buffer_has_hard_ceiling_and_discards_oldest_queued_audio(self):
        audio = transcriber.BoundedAudioBuffer(max_bytes=8)
        audio.push(transcriber.AudioChunk(b"a" * 4, start_frame=0))
        audio.push(transcriber.AudioChunk(b"b" * 4, start_frame=1))
        audio.push(transcriber.AudioChunk(b"c" * 4, start_frame=2))

        self.assertEqual(audio.buffered_bytes, 8)
        self.assertEqual(audio.dropped_bytes, 4)
        first = audio.acquire(0)
        self.assertEqual(first, transcriber.AudioChunk(b"b" * 4, start_frame=1))
        audio.ack(first)
        second = audio.acquire(0)
        self.assertEqual(second, transcriber.AudioChunk(b"c" * 4, start_frame=2))
        audio.ack(second)

    def test_failed_send_chunk_is_retained_at_queue_head(self):
        audio = transcriber.BoundedAudioBuffer(max_bytes=16)
        expected = transcriber.AudioChunk(b"x" * 8, start_frame=42)
        audio.push(expected)

        acquired = audio.acquire(0)
        self.assertEqual(acquired, expected)
        audio.nack(acquired)

        self.assertEqual(audio.acquire(0), expected)

    def test_stdin_pump_drains_pipe_and_closes_on_eof(self):
        read_fd, write_fd = os.pipe()
        audio = transcriber.BoundedAudioBuffer(max_bytes=16)
        pump = transcriber.StdinAudioPump(read_fd, audio, read_size=5)
        pump.start()
        os.write(write_fd, b"0123456789ab")
        os.close(write_fd)
        pump.join(1)
        os.close(read_fd)

        chunks = []
        while True:
            chunk = audio.acquire(0)
            if chunk is None:
                break
            chunks.append(chunk)
            audio.ack(chunk)
        self.assertEqual(b"".join(chunk.data for chunk in chunks), b"0123456789ab")
        self.assertEqual([chunk.start_frame for chunk in chunks], [0, 1, 2])
        self.assertTrue(audio.finished)

    def test_reconnect_uses_session_offsets_and_new_speaker_namespace(self):
        base = transcriber.segments_from_result(
            result(0, [word("Hello.", 0, 0.5, 0.8)], start=0.5)
        )
        speakers = transcriber.SpeakerRegistry()
        first = speakers.relabel(transcriber.offset_segments(base, 10.0), 1)[0]
        second = speakers.relabel(transcriber.offset_segments(base, 25.0), 2)[0]

        self.assertEqual((first.start, first.end), (10.5, 10.8))
        self.assertEqual((second.start, second.end), (25.5, 25.8))
        self.assertEqual(first.label, "Remote 1")
        self.assertEqual(second.label, "Remote 2")
        self.assertEqual((first.connection_id, second.connection_id), (1, 2))

    def test_client_http_errors_are_terminal_but_server_errors_retry(self):
        class Response:
            def __init__(self, status_code):
                self.status_code = status_code

        class HandshakeError(Exception):
            def __init__(self, status_code):
                self.response = Response(status_code)

        self.assertTrue(
            transcriber.is_non_retryable_websocket_error(HandshakeError(401))
        )
        self.assertTrue(
            transcriber.is_non_retryable_websocket_error(HandshakeError(429))
        )
        self.assertFalse(
            transcriber.is_non_retryable_websocket_error(HandshakeError(503))
        )

    def test_deepgram_error_and_failed_metadata_payloads_are_terminal(self):
        self.assertEqual(
            transcriber.deepgram_payload_error(
                {
                    "type": "Error",
                    "code": "INVALID_QUERY_PARAMETER",
                    "message": "language is unsupported by this model",
                }
            ),
            "language is unsupported by this model",
        )
        self.assertEqual(
            transcriber.deepgram_payload_error(
                {
                    "type": "Metadata",
                    "status": "failed",
                    "error": {"message": "model nova-x does not exist"},
                }
            ),
            "model nova-x does not exist",
        )
        self.assertIsNone(
            transcriber.deepgram_payload_error(
                {"type": "Metadata", "request_id": "request-123"}
            )
        )

    def test_ready_signal_is_atomic_and_contains_no_secret(self):
        with tempfile.TemporaryDirectory() as directory:
            ready = pathlib.Path(directory, "deepgram.ready")
            original = os.environ.get("ARCO_READY_FILE")
            os.environ["ARCO_READY_FILE"] = str(ready)
            try:
                transcriber.signal_ready()
            finally:
                if original is None:
                    os.environ.pop("ARCO_READY_FILE", None)
                else:
                    os.environ["ARCO_READY_FILE"] = original

            self.assertEqual(ready.read_text(encoding="utf-8"), "deepgram-ready\n")
            self.assertEqual(list(pathlib.Path(directory).iterdir()), [ready])


class StreamFailureTests(unittest.IsolatedAsyncioTestCase):
    async def test_stream_send_failure_returns_exact_chunk_for_reconnect(self):
        class FailingSocket:
            def __aiter__(self):
                return self

            async def __anext__(self):
                await asyncio.Future()

            async def send(self, payload):
                if isinstance(payload, bytes):
                    raise ConnectionError("simulated network drop")

        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory, "transcript.md")
            path.write_text("# Meeting Transcript\n\n", encoding="utf-8")
            writer = transcriber.OrderedTranscriptWriter(
                transcriber.Transcript(str(path)),
                1_700_000_000,
            )
            audio = transcriber.BoundedAudioBuffer(max_bytes=16)
            expected = transcriber.AudioChunk(b"z" * 8, start_frame=80)
            audio.push(expected)

            with self.assertRaisesRegex(ConnectionError, "simulated network drop"):
                await transcriber.stream_connection(
                    FailingSocket(),
                    audio,
                    writer,
                    transcriber.SpeakerRegistry(),
                    connection_id=1,
                )

            self.assertEqual(audio.acquire(0), expected)


if __name__ == "__main__":
    unittest.main()
