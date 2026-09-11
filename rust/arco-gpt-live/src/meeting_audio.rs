//! Local monitoring and a dedicated meeting send bus. Never route received
//! system audio back into the meeting microphone.
use rodio::cpal::traits::{DeviceTrait, HostTrait};
use rodio::{DeviceSinkBuilder, MixerDeviceSink, Player, Source, buffer::SamplesBuffer, nz};
use std::sync::{
    Arc,
    atomic::{AtomicU32, Ordering},
};
use std::time::Duration;

pub const MEETING_DEVICE: &str = "BlackHole 2ch";

pub struct MeetingAudioBridge {
    _sink: Option<MixerDeviceSink>,
    pub microphone: Option<Arc<Player>>,
    pub assistant: Option<Arc<Player>>,
}

impl MeetingAudioBridge {
    pub fn open(include_microphone: bool) -> Result<Self, String> {
        let host = rodio::cpal::default_host();
        let name = |device: rodio::cpal::Device| {
            device
                .description()
                .map(|value| value.name().to_owned())
                .unwrap_or_default()
        };
        // A loopback must only be selected inside the meeting application.
        if host.default_output_device().map(&name).as_deref() == Some(MEETING_DEVICE) {
            return Err("Keep the Mac's speakers on a physical device.".into());
        }
        let device = if include_microphone {
            host.output_devices()
                .map_err(|error| format!("Could not inspect meeting audio devices: {error}"))?
                .find(|device| {
                    device
                        .description()
                        .map(|value| value.name() == MEETING_DEVICE)
                        .unwrap_or(false)
                })
        } else {
            None
        };
        let Some(device) = device else {
            return Ok(Self {
                _sink: None,
                microphone: None,
                assistant: None,
            });
        };
        // No fallback to another device: that could unexpectedly broadcast audio.
        let mut sink = DeviceSinkBuilder::from_device(device)
            .and_then(|builder| builder.open_stream())
            .map_err(|error| format!("Could not open the meeting microphone: {error}"))?;
        sink.log_on_drop(false);
        let microphone = Arc::new(Player::connect_new(sink.mixer()));
        let assistant = Arc::new(Player::connect_new(sink.mixer()));
        // Two full-scale sources may overlap. Reserve headroom for their sum.
        microphone.set_volume(0.5);
        assistant.set_volume(0.5);
        Ok(Self {
            _sink: Some(sink),
            microphone: Some(microphone),
            assistant: Some(assistant),
        })
    }
}

pub fn microphone_samples(stereo: &[i16]) -> Vec<f32> {
    // Recorder channel 0 is received system audio, channel 1 is room/microphone.
    stereo
        .chunks_exact(2)
        .map(|frame| f32::from(frame[1]) / 32768.0)
        .collect()
}

pub fn send_microphone(player: &Player, stereo: &[i16]) -> Result<(), String> {
    if player.len() >= 10 {
        // Capture callbacks can arrive in bursts when the Mac is busy. Keep the
        // send bus live and bounded instead of disconnecting the meeting over a
        // transient 200ms backlog. clear() pauses, so resume before appending.
        player.clear();
        player.play();
    }
    player.append(SamplesBuffer::new(
        nz!(1),
        nz!(16_000),
        microphone_samples(stereo),
    ));
    Ok(())
}

/// Measures samples as the player consumes them, rather than when a network
/// packet arrives. The audio callback only updates an atomic; UI publication
/// runs on a separate, rate-limited task.
pub struct MeteredSource<S> {
    source: S,
    meter: Arc<AtomicU32>,
    sum: f32,
    count: usize,
}

impl<S: Source> MeteredSource<S> {
    pub fn new(source: S, meter: Arc<AtomicU32>) -> Self {
        Self {
            source,
            meter,
            sum: 0.0,
            count: 0,
        }
    }
}
impl<S: Source> Iterator for MeteredSource<S> {
    type Item = f32;
    fn next(&mut self) -> Option<f32> {
        let sample = self.source.next()?;
        self.sum += sample * sample;
        self.count += 1;
        if self.count >= 480 {
            let level = (self.sum / self.count as f32).sqrt();
            self.meter.fetch_max(level.to_bits(), Ordering::Relaxed);
            self.sum = 0.0;
            self.count = 0;
        }
        Some(sample)
    }
}
impl<S: Source> Source for MeteredSource<S> {
    fn current_span_len(&self) -> Option<usize> {
        self.source.current_span_len()
    }
    fn channels(&self) -> rodio::ChannelCount {
        self.source.channels()
    }
    fn sample_rate(&self) -> rodio::SampleRate {
        self.source.sample_rate()
    }
    fn total_duration(&self) -> Option<Duration> {
        self.source.total_duration()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn meeting_send_never_contains_received_system_audio() {
        assert_eq!(microphone_samples(&[32767, 0, -32768, 0]), vec![0.0, 0.0]);
        assert_eq!(
            microphone_samples(&[0, 16384, 32767, -16384]),
            vec![0.5, -0.5]
        );
    }
    #[test]
    fn visual_meter_only_advances_when_playback_consumes_samples() {
        let meter = Arc::new(AtomicU32::new(0));
        let source = SamplesBuffer::new(nz!(2), nz!(48_000), vec![0.25; 960]);
        let mut measured = MeteredSource::new(source, Arc::clone(&meter));
        assert_eq!(meter.load(Ordering::Relaxed), 0);
        for _ in 0..480 {
            assert_eq!(measured.next(), Some(0.25));
        }
        assert_eq!(f32::from_bits(meter.load(Ordering::Relaxed)), 0.25);
    }
}
