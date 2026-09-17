# Software echo cancellation for mixed capture

Mixed capture enables WebRTC AEC3 by default. The original C++ WebRTC AudioProcessing implementation is statically linked via `webrtc-audio-processing = 2.1.0` (bundled). The recorder feeds 16 kHz system playback as render reference and microphone audio as capture, in 10 ms frames. Delay estimation is automatic, not hardcoded to this Mac's measured acoustic delay. Noise suppression and automatic gain control are not enabled.

Only the microphone sent to transcription changes. System-channel PCM is retained sample-for-sample, and no AVAudioEngine Voice Processing or macOS ducking API is called. The audio archive receives both original captured channels before AEC. This preserves input for later replay or speaker correction. Existing microphone-only and system-only modes are unchanged. `ARCO_MIC_ECHO_CANCELLATION=off` remains an explicit opt-out; absent, empty or unknown values use the mixed-mode default.

Processing happens on the recorder's ordinary serial worker queue, outside the real-time audio callbacks. AEC state resets after dropped/discontinuous input. The final partial frame is zero-padded internally without extending the emitted transcript audio. Initialization or processing failure is logged and falls back to unprocessed audio; processing errors leave the caller's entire buffer unchanged.

## Building

The WebRTC library is statically included; installed users do not need Homebrew or extra downloads. Developers need `brew install meson ninja pkgconf` and `rustup component add llvm-tools-preview` for the bundled build. `native/build-recorder.sh` links the system C++ runtime. License notices are packaged in `Resources/native/licenses/WebRTC-AEC3.txt`.

## Validation on 2026-09-08

- Before implementation, the delayed-echo regression measured 0 dB reduction and failed its 15 dB minimum; invalid-buffer rejection also failed.
- After implementation, all 16 audio-runtime tests passed, covering echo reduction, preservation of near-end audio without playback, unchanged system samples, silence, reset, partial tails, invalid sizes, FFI pointers and existing resampling/overflow behavior. The signed native recorder self-test passed.
- Offline replay of a newly captured, uncompressed loudspeaker test reduced microphone energy by about 30 dB over two measured windows (2–6 and 6–10 seconds), and about 48 dB over 10–13 seconds. System samples were unchanged.
- The first 300 seconds of the user's AAC meeting archive were replayed locally. Sampled local-speech windows (22–26, 44–50 and 65–70 seconds) changed by approximately 0 dB; sampled echo/mixed windows improved by about 1.6–7.2 dB. This is not proof that all repeated speech or all speaker labels are corrected.
- A real recorder A/B run confirmed default AEC3 activation, normal mono microphone input, clean shutdown and unchanged playback energy (less than 0.001 dB difference). Whole-microphone energy fell only about 4 dB in that run, so the 30 dB offline result must not be generalized to all rooms or every live segment; the live microphone also contains unrelated local sound.

Sources: [WebRTC Rust binding and bundled-build documentation](https://github.com/tonarino/webrtc-audio-processing), [Apple's separate voice-processing ducking setting](https://developer.apple.com/documentation/avfaudio/avaudioinputnode/voiceprocessingotheraudioduckingconfiguration).

Full archived meeting replay also completed: 1,346.668 seconds of audio processed in 16.736 seconds, preserving all 21,546,688 system-channel samples and the exact frame count. This validates full-session processing, not a two-speaker diarization result.
