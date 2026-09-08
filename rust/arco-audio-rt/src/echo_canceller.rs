//! AEC runs on the recorder's ordinary processing queue, never in an audio callback.
//! Stereo input is fixed at 16 kHz: system playback on the left, microphone on the right.

pub const FRAME_SAMPLES: usize = 160;
pub const MAX_STEREO_FRAMES: usize = 1_600;

use webrtc_audio_processing::{config::EchoCanceller as Algorithm, Config, Processor};

pub struct EchoCanceller {
    processor: Processor,
    render: [f32; FRAME_SAMPLES],
    capture: [f32; FRAME_SAMPLES],
    output: [i16; MAX_STEREO_FRAMES * 2],
}

impl EchoCanceller {
    pub fn new() -> Result<Self, &'static str> {
        let processor = Processor::new(16_000).map_err(|_| "could not create WebRTC AEC3")?;
        processor.set_config(Config {
            echo_canceller: Some(Algorithm::Full {
                stream_delay_ms: None,
            }),
            ..Default::default()
        });
        Ok(Self {
            processor,
            render: [0.; FRAME_SAMPLES],
            capture: [0.; FRAME_SAMPLES],
            output: [0; MAX_STEREO_FRAMES * 2],
        })
    }

    pub fn reset(&mut self) -> Result<(), &'static str> {
        *self = Self::new()?;
        Ok(())
    }

    /// Full calls contain multiples of 10 ms. Only the final shutdown tail may
    /// contain fewer samples; it is padded internally without extending output.
    /// Any error leaves the caller's audio untouched so capture can fall back.
    pub fn process_stereo(&mut self, samples: &mut [i16]) -> Result<(), &'static str> {
        if samples.len() % 2 != 0 || samples.len() > self.output.len() {
            return Err("invalid stereo frame length");
        }
        self.output[..samples.len()].copy_from_slice(samples);
        for frame in self.output[..samples.len()].chunks_mut(FRAME_SAMPLES * 2) {
            self.render.fill(0.);
            self.capture.fill(0.);
            for (i, pair) in frame.chunks_exact(2).enumerate() {
                self.render[i] = f32::from(pair[0]) / 32768.;
                self.capture[i] = f32::from(pair[1]) / 32768.;
            }
            self.processor
                .process_render_frame([&mut self.render[..]])
                .map_err(|_| "WebRTC render processing failed")?;
            self.processor
                .process_capture_frame([&mut self.capture[..]])
                .map_err(|_| "WebRTC microphone processing failed")?;
            for (i, pair) in frame.chunks_exact_mut(2).enumerate() {
                pair[1] = (self.capture[i] * 32768.).round().clamp(-32768., 32767.) as i16;
            }
        }
        samples.copy_from_slice(&self.output[..samples.len()]);
        Ok(())
    }
}

/// # Safety
/// `output` must point to writable pointer storage; destroy the result once.
#[no_mangle]
pub unsafe extern "C" fn arco_aec_create(output: *mut *mut EchoCanceller) -> i32 {
    if output.is_null() {
        return crate::STATUS_INVALID_ARGUMENT;
    }
    unsafe {
        *output = std::ptr::null_mut();
    }
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        match EchoCanceller::new() {
            Ok(aec) => {
                unsafe {
                    *output = Box::into_raw(Box::new(aec));
                }
                crate::STATUS_OK
            }
            Err(_) => crate::STATUS_INTERNAL_ERROR,
        }
    }))
    .unwrap_or(crate::STATUS_PANIC)
}

/// # Safety
/// `aec` must be live and exclusively held; `samples` must cover `frames * 2`
/// writable interleaved i16 values. Calls belong on the normal worker queue.
#[no_mangle]
pub unsafe extern "C" fn arco_aec_process(
    aec: *mut EchoCanceller,
    samples: *mut i16,
    frames: u32,
) -> i32 {
    if aec.is_null() || frames as usize > MAX_STEREO_FRAMES || (frames > 0 && samples.is_null()) {
        return crate::STATUS_INVALID_ARGUMENT;
    }
    if frames == 0 {
        return crate::STATUS_OK;
    }
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let samples = unsafe { std::slice::from_raw_parts_mut(samples, frames as usize * 2) };
        match unsafe { &mut *aec }.process_stereo(samples) {
            Ok(()) => crate::STATUS_OK,
            Err(_) => crate::STATUS_INTERNAL_ERROR,
        }
    }))
    .unwrap_or(crate::STATUS_PANIC)
}

/// # Safety
/// `aec` must be live and exclusively held by the processing queue.
#[no_mangle]
pub unsafe extern "C" fn arco_aec_reset(aec: *mut EchoCanceller) -> i32 {
    if aec.is_null() {
        return crate::STATUS_INVALID_ARGUMENT;
    }
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        match unsafe { &mut *aec }.reset() {
            Ok(()) => crate::STATUS_OK,
            Err(_) => crate::STATUS_INTERNAL_ERROR,
        }
    }))
    .unwrap_or(crate::STATUS_PANIC)
}

/// # Safety
/// No concurrent call may use `aec`; destroy each non-null handle exactly once.
#[no_mangle]
pub unsafe extern "C" fn arco_aec_destroy(aec: *mut EchoCanceller) {
    if !aec.is_null() {
        drop(unsafe { Box::from_raw(aec) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn reference_signal(count: usize, seed: u32) -> Vec<i16> {
        let mut seed = seed;
        let mut filtered = 0.0;
        (0..count)
            .map(|_| {
                seed = seed.wrapping_mul(1664525).wrapping_add(1013904223);
                let sample = ((seed >> 16) as i16) as f64;
                filtered = 0.8 * filtered + 0.2 * sample;
                (filtered * 0.5) as i16
            })
            .collect()
    }

    #[test]
    fn default_canceller_removes_delayed_speaker_echo_without_changing_playback() {
        let reference = reference_signal(160_000, 42);
        let mut aec = EchoCanceller::new().unwrap();
        let mut before = 0f64;
        let mut after = 0f64;
        for start in (0..reference.len()).step_by(FRAME_SAMPLES) {
            let mut frame = vec![0i16; FRAME_SAMPLES * 2];
            for i in 0..FRAME_SAMPLES {
                let t = start + i;
                frame[i * 2] = reference[t];
                frame[i * 2 + 1] = if t >= 1120 {
                    reference[t - 1120] / 2
                } else {
                    0
                };
                if start > 64_000 {
                    before += f64::from(frame[i * 2 + 1]).powi(2);
                }
            }
            aec.process_stereo(&mut frame).unwrap();
            for i in 0..FRAME_SAMPLES {
                assert_eq!(frame[i * 2], reference[start + i], "playback changed");
                if start > 64_000 {
                    after += f64::from(frame[i * 2 + 1]).powi(2);
                }
            }
        }
        let reduction_db = 10.0 * (before / after.max(1.)).log10();
        assert!(
            reduction_db >= 15.0,
            "echo reduction {reduction_db:.2} dB is below 15 dB"
        );
    }

    #[test]
    fn silence_empty_tail_and_reset_preserve_frame_counts_and_playback() {
        let mut aec = EchoCanceller::new().unwrap();
        aec.process_stereo(&mut []).unwrap();
        let mut silence = [0i16; 320];
        aec.process_stereo(&mut silence).unwrap();
        assert_eq!(silence, [0; 320]);
        let mut tail = [123, 0, -456, 0, 789, 0];
        aec.process_stereo(&mut tail).unwrap();
        assert_eq!(
            tail.iter().step_by(2).copied().collect::<Vec<_>>(),
            [123, -456, 789]
        );
        aec.reset().unwrap();
        aec.process_stereo(&mut silence).unwrap();
        assert_eq!(silence, [0; 320]);
    }

    #[test]
    fn invalid_frame_sizes_are_rejected_without_modifying_audio() {
        let mut aec = EchoCanceller::new().unwrap();
        for mut invalid in [vec![1, 2, 3], vec![1; (MAX_STEREO_FRAMES + 1) * 2]] {
            let original = invalid.clone();
            assert_eq!(
                aec.process_stereo(&mut invalid),
                Err("invalid stereo frame length")
            );
            assert_eq!(invalid, original);
        }
    }

    #[test]
    fn microphone_speech_is_preserved_when_playback_is_silent() {
        let voice = reference_signal(32_000, 9876);
        let mut aec = EchoCanceller::new().unwrap();
        let mut output = Vec::new();
        for part in voice.chunks(FRAME_SAMPLES) {
            let mut stereo: Vec<_> = part.iter().flat_map(|&mic| [0, mic]).collect();
            aec.process_stereo(&mut stereo).unwrap();
            output.extend(stereo.into_iter().skip(1).step_by(2));
        }
        let original = &voice[8000..];
        let before: f64 = original.iter().map(|&x| f64::from(x).powi(2)).sum();
        let after: f64 = output[8000..].iter().map(|&x| f64::from(x).powi(2)).sum();
        let change_db = 10.0 * (after / before).log10();
        assert!(
            change_db.abs() < 1.0,
            "local speech changed by {change_db:.2} dB"
        );
        let correlation = (0..=160)
            .map(|lag| {
                let a = &voice[8000..voice.len() - 160];
                let b = &output[8000 + lag..output.len() - 160 + lag];
                let dot: f64 = a
                    .iter()
                    .zip(b)
                    .map(|(&x, &y)| f64::from(x) * f64::from(y))
                    .sum();
                let aa: f64 = a.iter().map(|&x| f64::from(x).powi(2)).sum();
                let bb: f64 = b.iter().map(|&x| f64::from(x).powi(2)).sum();
                dot / (aa * bb).sqrt()
            })
            .fold(-1.0_f64, f64::max);
        assert!(
            correlation > 0.95,
            "local speech waveform changed: correlation={correlation}"
        );
    }

    #[test]
    fn c_boundary_rejects_nulls_and_oversize_buffers_and_supports_reset() {
        unsafe {
            assert_eq!(
                arco_aec_create(std::ptr::null_mut()),
                crate::STATUS_INVALID_ARGUMENT
            );
            let mut handle = std::ptr::null_mut();
            assert_eq!(arco_aec_create(&mut handle), crate::STATUS_OK);
            assert!(!handle.is_null());
            assert_eq!(
                arco_aec_process(handle, std::ptr::null_mut(), 0),
                crate::STATUS_OK
            );
            assert_eq!(
                arco_aec_process(handle, std::ptr::null_mut(), 1),
                crate::STATUS_INVALID_ARGUMENT
            );
            let mut samples = [0; 320];
            assert_eq!(
                arco_aec_process(handle, samples.as_mut_ptr(), 1601),
                crate::STATUS_INVALID_ARGUMENT
            );
            assert_eq!(
                arco_aec_process(handle, samples.as_mut_ptr(), 160),
                crate::STATUS_OK
            );
            assert_eq!(samples, [0; 320]);
            assert_eq!(arco_aec_reset(handle), crate::STATUS_OK);
            assert_eq!(
                arco_aec_reset(std::ptr::null_mut()),
                crate::STATUS_INVALID_ARGUMENT
            );
            arco_aec_destroy(handle);
            arco_aec_destroy(std::ptr::null_mut());
        }
    }
}
