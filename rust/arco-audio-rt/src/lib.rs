//! Real-time audio data plane for the native Arco recorder.
//!
//! Capture callbacks only validate/downmix raw PCM and publish it into a
//! preallocated `rtrb` queue. Sample-rate conversion is performed when the
//! ordinary recorder worker drains the matching consumer. No model or product
//! state lives in this library; the containing recorder executable remains the
//! crash-isolation boundary.

use rtrb::{Consumer, Producer, RingBuffer};
use rubato::{FftFixedIn, Resampler};
use std::ffi::c_void;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr;
use std::slice;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;

const STATUS_OK: i32 = 0;
const STATUS_INVALID_ARGUMENT: i32 = 1;
const STATUS_UNSUPPORTED_FORMAT: i32 = 2;
const STATUS_INTERNAL_ERROR: i32 = 3;
const STATUS_PANIC: i32 = 4;
const STATUS_FINISHED: i32 = 5;

const LINEAR_PCM_FORMAT_ID: u32 = u32::from_be_bytes(*b"lpcm");
const FORMAT_FLAG_IS_FLOAT: u32 = 1 << 0;
const FORMAT_FLAG_IS_BIG_ENDIAN: u32 = 1 << 1;
const FORMAT_FLAG_IS_SIGNED_INTEGER: u32 = 1 << 2;
const FORMAT_FLAG_IS_PACKED: u32 = 1 << 3;
const FORMAT_FLAG_IS_ALIGNED_HIGH: u32 = 1 << 4;
const FORMAT_FLAG_IS_NON_INTERLEAVED: u32 = 1 << 5;
const MAX_CHANNELS: usize = 64;
const MAX_FLUSH_ROUNDS: usize = 4;
const MAX_SAMPLE_RATE: usize = 768_000;
const MAX_RING_CAPACITY_FRAMES: usize = 2_000_000;

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct AudioStreamBasicDescription {
    pub sample_rate: f64,
    pub format_id: u32,
    pub format_flags: u32,
    pub bytes_per_packet: u32,
    pub frames_per_packet: u32,
    pub bytes_per_frame: u32,
    pub channels_per_frame: u32,
    pub bits_per_channel: u32,
    pub reserved: u32,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct AudioBuffer {
    pub number_channels: u32,
    pub data_byte_size: u32,
    pub data: *const c_void,
}

#[repr(C)]
pub struct AudioBufferList {
    pub number_buffers: u32,
    pub buffers: [AudioBuffer; 1],
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum SampleKind {
    Float32,
    Signed16,
}

#[derive(Clone, Copy, Debug)]
struct FormatSpec {
    source_rate: usize,
    target_rate: usize,
    channels: usize,
    bytes_per_frame: usize,
    sample_kind: SampleKind,
    non_interleaved: bool,
}

impl FormatSpec {
    fn parse(format: &AudioStreamBasicDescription, target_rate: f64) -> Result<Self, i32> {
        if !format.sample_rate.is_finite()
            || !target_rate.is_finite()
            || format.sample_rate <= 0.0
            || target_rate <= 0.0
            || format.channels_per_frame == 0
            || format.channels_per_frame as usize > MAX_CHANNELS
        {
            return Err(STATUS_INVALID_ARGUMENT);
        }
        let source_rate = format.sample_rate.round() as usize;
        let target_rate_value = target_rate;
        let target_rate = target_rate_value.round() as usize;
        if (format.sample_rate - source_rate as f64).abs() > 0.01
            || (target_rate_value - target_rate as f64).abs() > 0.01
            || source_rate == 0
            || target_rate == 0
            || source_rate > MAX_SAMPLE_RATE
            || target_rate > MAX_SAMPLE_RATE
        {
            return Err(STATUS_UNSUPPORTED_FORMAT);
        }
        if format.format_id != LINEAR_PCM_FORMAT_ID
            || format.frames_per_packet != 1
            || format.format_flags & FORMAT_FLAG_IS_BIG_ENDIAN != 0
            || format.format_flags & FORMAT_FLAG_IS_ALIGNED_HIGH != 0
            || format.format_flags & FORMAT_FLAG_IS_PACKED == 0
        {
            return Err(STATUS_UNSUPPORTED_FORMAT);
        }

        let is_float = format.format_flags & FORMAT_FLAG_IS_FLOAT != 0;
        let is_signed = format.format_flags & FORMAT_FLAG_IS_SIGNED_INTEGER != 0;
        let sample_kind = match (is_float, is_signed, format.bits_per_channel) {
            (true, false, 32) => SampleKind::Float32,
            (false, true, 16) => SampleKind::Signed16,
            _ => return Err(STATUS_UNSUPPORTED_FORMAT),
        };
        let sample_bytes = match sample_kind {
            SampleKind::Float32 => 4,
            SampleKind::Signed16 => 2,
        };
        let non_interleaved = format.format_flags & FORMAT_FLAG_IS_NON_INTERLEAVED != 0;
        let expected_bytes_per_frame = if non_interleaved {
            sample_bytes
        } else {
            sample_bytes * format.channels_per_frame as usize
        };
        if format.bytes_per_frame as usize != expected_bytes_per_frame
            || format.bytes_per_packet as usize != expected_bytes_per_frame
        {
            return Err(STATUS_UNSUPPORTED_FORMAT);
        }

        let unit = source_rate / gcd(source_rate, target_rate);
        let desired = source_rate.div_ceil(50);
        let chunk_size = desired
            .div_ceil(unit)
            .checked_mul(unit)
            .ok_or(STATUS_UNSUPPORTED_FORMAT)?;
        let chunk_duration = chunk_size
            .checked_mul(1000)
            .ok_or(STATUS_UNSUPPORTED_FORMAT)?;
        if chunk_duration > source_rate * 40 {
            return Err(STATUS_UNSUPPORTED_FORMAT);
        }

        Ok(Self {
            source_rate,
            target_rate,
            channels: format.channels_per_frame as usize,
            bytes_per_frame: expected_bytes_per_frame,
            sample_kind,
            non_interleaved,
        })
    }

    fn chunk_size(self) -> usize {
        let unit = self.source_rate / gcd(self.source_rate, self.target_rate);
        self.source_rate.div_ceil(50).div_ceil(unit) * unit
    }
}

fn gcd(mut left: usize, mut right: usize) -> usize {
    while right != 0 {
        let remainder = left % right;
        left = right;
        right = remainder;
    }
    left.max(1)
}

struct SharedState {
    overflow_epoch: AtomicU64,
    acknowledged_epoch: AtomicU64,
    dropped_frames: AtomicU64,
    finished: AtomicBool,
}

impl SharedState {
    fn new() -> Self {
        Self {
            overflow_epoch: AtomicU64::new(0),
            acknowledged_epoch: AtomicU64::new(0),
            dropped_frames: AtomicU64::new(0),
            finished: AtomicBool::new(false),
        }
    }
}

#[repr(C)]
pub struct ArcoAudioRtProducer {
    ring: Producer<f32>,
    format: FormatSpec,
    shared: Arc<SharedState>,
}

#[repr(C)]
pub struct ArcoAudioRtConsumer {
    ring: Consumer<f32>,
    shared: Arc<SharedState>,
    format: FormatSpec,
    resampler: FftFixedIn<f32>,
    input: Vec<Vec<f32>>,
    output: Vec<Vec<f32>>,
    input_len: usize,
    output_delay_remaining: usize,
    segment_real_input_frames: u64,
    segment_output_frames: u64,
    observed_epoch: u64,
    flush_rounds: usize,
    done: bool,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct ArcoAudioRtPushResult {
    pub status: i32,
    pub accepted_frames: u32,
    pub dropped_frames: u32,
    pub overflow_epoch: u64,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct ArcoAudioRtDrainResult {
    pub status: i32,
    pub frame_count: u32,
    pub dropped_input_frames: u64,
    pub discontinuity: u8,
    pub finished: u8,
    pub reserved: [u8; 6],
}

impl ArcoAudioRtProducer {
    fn dropped_result(&self, frames: usize, start_new_epoch: bool) -> ArcoAudioRtPushResult {
        self.shared
            .dropped_frames
            .fetch_add(frames as u64, Ordering::Relaxed);
        let epoch = if start_new_epoch {
            self.shared.overflow_epoch.fetch_add(1, Ordering::Release) + 1
        } else {
            self.shared.overflow_epoch.load(Ordering::Acquire)
        };
        ArcoAudioRtPushResult {
            status: STATUS_OK,
            accepted_frames: 0,
            dropped_frames: frames.min(u32::MAX as usize) as u32,
            overflow_epoch: epoch,
        }
    }

    fn write_mono<F>(&mut self, frames: usize, mut sample_at: F) -> ArcoAudioRtPushResult
    where
        F: FnMut(usize) -> f32,
    {
        if self.shared.finished.load(Ordering::Acquire) {
            return ArcoAudioRtPushResult {
                status: STATUS_FINISHED,
                ..Default::default()
            };
        }
        if frames == 0 {
            return ArcoAudioRtPushResult {
                status: STATUS_OK,
                overflow_epoch: self.shared.overflow_epoch.load(Ordering::Acquire),
                ..Default::default()
            };
        }

        let epoch = self.shared.overflow_epoch.load(Ordering::Acquire);
        if self.shared.acknowledged_epoch.load(Ordering::Acquire) < epoch {
            return self.dropped_result(frames, false);
        }
        let mut chunk = match self.ring.write_chunk_uninit(frames) {
            Ok(chunk) => chunk,
            Err(_) => return self.dropped_result(frames, true),
        };
        let (first, second) = chunk.as_mut_slices();
        for (index, slot) in first.iter_mut().chain(second.iter_mut()).enumerate() {
            let sample = sample_at(index);
            slot.write(if sample.is_finite() { sample } else { 0.0 });
        }
        // SAFETY: every slot returned by the chunk was initialized above.
        unsafe { chunk.commit_all() };
        ArcoAudioRtPushResult {
            status: STATUS_OK,
            accepted_frames: frames.min(u32::MAX as usize) as u32,
            dropped_frames: 0,
            overflow_epoch: epoch,
        }
    }

    unsafe fn push_planar(
        &mut self,
        channels: *const *const f32,
        channel_count: usize,
        frame_count: usize,
    ) -> ArcoAudioRtPushResult {
        if channels.is_null()
            || channel_count == 0
            || channel_count > MAX_CHANNELS
            || channel_count != self.format.channels
        {
            return ArcoAudioRtPushResult {
                status: STATUS_INVALID_ARGUMENT,
                ..Default::default()
            };
        }
        // SAFETY: the caller promises a channel pointer table for this callback.
        let channel_ptrs = unsafe { slice::from_raw_parts(channels, channel_count) };
        if channel_ptrs.iter().any(|pointer| pointer.is_null()) {
            return ArcoAudioRtPushResult {
                status: STATUS_INVALID_ARGUMENT,
                ..Default::default()
            };
        }
        self.write_mono(frame_count, |frame| {
            let mut sum = 0.0f32;
            for pointer in channel_ptrs {
                // SAFETY: each channel contains at least frame_count samples.
                sum += unsafe { *pointer.add(frame) };
            }
            sum / channel_count as f32
        })
    }

    unsafe fn push_buffer_list(&mut self, input: *const AudioBufferList) -> ArcoAudioRtPushResult {
        if input.is_null() {
            return ArcoAudioRtPushResult {
                status: STATUS_INVALID_ARGUMENT,
                ..Default::default()
            };
        }
        // SAFETY: Core Audio supplies a valid variable-length AudioBufferList.
        let buffer_count = unsafe { (*input).number_buffers as usize };
        if buffer_count == 0 || buffer_count > MAX_CHANNELS {
            return ArcoAudioRtPushResult {
                status: STATUS_INVALID_ARGUMENT,
                ..Default::default()
            };
        }
        // SAFETY: `buffers` is the first element of the C flexible array.
        let buffers = unsafe { slice::from_raw_parts((*input).buffers.as_ptr(), buffer_count) };
        let sample_bytes = match self.format.sample_kind {
            SampleKind::Float32 => 4,
            SampleKind::Signed16 => 2,
        };

        let frames = if self.format.non_interleaved {
            if buffer_count != self.format.channels
                || buffers
                    .iter()
                    .any(|buffer| buffer.number_channels != 1 || buffer.data.is_null())
            {
                return ArcoAudioRtPushResult {
                    status: STATUS_UNSUPPORTED_FORMAT,
                    ..Default::default()
                };
            }
            let first_size = buffers[0].data_byte_size as usize;
            if first_size % self.format.bytes_per_frame != 0
                || buffers
                    .iter()
                    .any(|buffer| buffer.data_byte_size as usize != first_size)
            {
                return ArcoAudioRtPushResult {
                    status: STATUS_UNSUPPORTED_FORMAT,
                    ..Default::default()
                };
            }
            first_size / self.format.bytes_per_frame
        } else {
            let buffer = &buffers[0];
            if buffer_count != 1
                || buffer.number_channels as usize != self.format.channels
                || buffer.data.is_null()
                || buffer.data_byte_size as usize % self.format.bytes_per_frame != 0
            {
                return ArcoAudioRtPushResult {
                    status: STATUS_UNSUPPORTED_FORMAT,
                    ..Default::default()
                };
            }
            buffer.data_byte_size as usize / self.format.bytes_per_frame
        };

        let sample_kind = self.format.sample_kind;
        let non_interleaved = self.format.non_interleaved;
        let bytes_per_frame = self.format.bytes_per_frame;
        let channels = self.format.channels;
        let read_sample = |buffer: &AudioBuffer, byte_offset: usize| -> f32 {
            // SAFETY: layout and byte bounds were validated from the ASBD and ABL.
            let pointer = unsafe { (buffer.data as *const u8).add(byte_offset) };
            match sample_kind {
                SampleKind::Float32 => unsafe { ptr::read_unaligned(pointer.cast::<f32>()) },
                SampleKind::Signed16 => {
                    (unsafe { ptr::read_unaligned(pointer.cast::<i16>()) }) as f32 / 32_768.0
                }
            }
        };
        self.write_mono(frames, |frame| {
            let mut sum = 0.0f32;
            if non_interleaved {
                for buffer in buffers {
                    sum += read_sample(buffer, frame * bytes_per_frame);
                }
            } else {
                let buffer = &buffers[0];
                let frame_base = frame * bytes_per_frame;
                for channel in 0..channels {
                    sum += read_sample(buffer, frame_base + channel * sample_bytes);
                }
            }
            sum / channels as f32
        })
    }
}

impl ArcoAudioRtConsumer {
    fn reset_after_overflow(&mut self, epoch: u64) -> u64 {
        let available = self.ring.slots();
        let purged_frames = available.saturating_add(self.input_len) as u64;
        if available > 0 {
            if let Ok(chunk) = self.ring.read_chunk(available) {
                chunk.commit_all();
            }
        }
        self.resampler.reset();
        self.input[0].fill(0.0);
        self.output[0].fill(0.0);
        self.input_len = 0;
        self.output_delay_remaining = self.resampler.output_delay();
        self.segment_real_input_frames = 0;
        self.segment_output_frames = 0;
        self.flush_rounds = 0;
        self.done = false;
        self.observed_epoch = epoch;
        self.shared
            .acknowledged_epoch
            .store(epoch, Ordering::Release);
        purged_frames
    }

    fn target_output_frames(&self) -> u64 {
        let numerator = self.segment_real_input_frames as u128 * self.format.target_rate as u128;
        ((numerator + (self.format.source_rate as u128 / 2)) / self.format.source_rate as u128)
            as u64
    }

    fn process_chunk(&mut self, destination: &mut [i16], finishing: bool) -> Result<usize, i32> {
        let (_, produced) = self
            .resampler
            .process_into_buffer(&self.input, &mut self.output, None)
            .map_err(|_| STATUS_INTERNAL_ERROR)?;
        self.input[0].fill(0.0);
        self.input_len = 0;

        let skip = self.output_delay_remaining.min(produced);
        self.output_delay_remaining -= skip;
        let mut available = produced - skip;
        if finishing {
            available = available.min(
                self.target_output_frames()
                    .saturating_sub(self.segment_output_frames) as usize,
            );
        }
        available = available.min(destination.len());
        for (output, sample) in destination
            .iter_mut()
            .zip(self.output[0][skip..skip + available].iter().copied())
        {
            let scaled = (sample.clamp(-1.0, 1.0) * 32_767.0).round();
            *output = scaled as i16;
        }
        self.segment_output_frames += available as u64;
        Ok(available)
    }

    fn drain(&mut self, destination: &mut [i16]) -> ArcoAudioRtDrainResult {
        let dropped = self.shared.dropped_frames.swap(0, Ordering::AcqRel);
        if self.done {
            return ArcoAudioRtDrainResult {
                status: STATUS_OK,
                dropped_input_frames: dropped,
                finished: 1,
                ..Default::default()
            };
        }

        let epoch = self.shared.overflow_epoch.load(Ordering::Acquire);
        if epoch != self.observed_epoch {
            let purged = self.reset_after_overflow(epoch);
            return ArcoAudioRtDrainResult {
                status: STATUS_OK,
                dropped_input_frames: dropped.saturating_add(purged),
                discontinuity: 1,
                ..Default::default()
            };
        }
        if destination.len() < self.resampler.output_frames_max() {
            return ArcoAudioRtDrainResult {
                status: STATUS_INVALID_ARGUMENT,
                dropped_input_frames: dropped,
                ..Default::default()
            };
        }

        let mut written = 0usize;
        loop {
            let current_epoch = self.shared.overflow_epoch.load(Ordering::Acquire);
            if current_epoch != self.observed_epoch {
                let purged = self.reset_after_overflow(current_epoch);
                return ArcoAudioRtDrainResult {
                    status: STATUS_OK,
                    dropped_input_frames: dropped.saturating_add(purged),
                    discontinuity: 1,
                    ..Default::default()
                };
            }

            let chunk_size = self.format.chunk_size();
            if self.input_len < chunk_size {
                let (popped, _) = self
                    .ring
                    .pop_partial_slice(&mut self.input[0][self.input_len..chunk_size]);
                self.input_len += popped.len();
                self.segment_real_input_frames += popped.len() as u64;
            }

            let producer_finished = self.shared.finished.load(Ordering::Acquire);
            let raw_empty = self.ring.is_empty();
            let has_full_chunk = self.input_len == chunk_size;
            let finishing = producer_finished && raw_empty;

            if !has_full_chunk && !finishing {
                break;
            }
            if finishing && self.input_len == 0 {
                if self.segment_output_frames >= self.target_output_frames() {
                    self.done = true;
                    break;
                }
                if self.flush_rounds >= MAX_FLUSH_ROUNDS {
                    return ArcoAudioRtDrainResult {
                        status: STATUS_INTERNAL_ERROR,
                        frame_count: written as u32,
                        dropped_input_frames: dropped,
                        ..Default::default()
                    };
                }
                self.input[0].fill(0.0);
                self.input_len = chunk_size;
                self.flush_rounds += 1;
            } else if finishing && self.input_len < chunk_size {
                self.input[0][self.input_len..chunk_size].fill(0.0);
                self.input_len = chunk_size;
                self.flush_rounds += 1;
            }

            let output_max = self.resampler.output_frames_max();
            if destination.len() - written < output_max {
                break;
            }
            match self.process_chunk(&mut destination[written..], finishing) {
                Ok(count) => written += count,
                Err(status) => {
                    return ArcoAudioRtDrainResult {
                        status,
                        frame_count: written as u32,
                        dropped_input_frames: dropped,
                        ..Default::default()
                    }
                }
            }
            if finishing && self.segment_output_frames >= self.target_output_frames() {
                self.done = true;
                break;
            }
        }

        ArcoAudioRtDrainResult {
            status: STATUS_OK,
            frame_count: written.min(u32::MAX as usize) as u32,
            dropped_input_frames: dropped,
            discontinuity: 0,
            finished: u8::from(self.done),
            reserved: [0; 6],
        }
    }
}

fn create_source(
    format: &AudioStreamBasicDescription,
    target_rate: f64,
    capacity_frames: usize,
) -> Result<(Box<ArcoAudioRtProducer>, Box<ArcoAudioRtConsumer>), i32> {
    if capacity_frames == 0 || capacity_frames > MAX_RING_CAPACITY_FRAMES {
        return Err(STATUS_INVALID_ARGUMENT);
    }
    let format = FormatSpec::parse(format, target_rate)?;
    let chunk_size = format.chunk_size();
    let resampler =
        FftFixedIn::<f32>::new(format.source_rate, format.target_rate, chunk_size, 1, 1)
            .map_err(|_| STATUS_UNSUPPORTED_FORMAT)?;
    let input = resampler.input_buffer_allocate(true);
    let output = resampler.output_buffer_allocate(true);
    let output_delay = resampler.output_delay();
    let shared = Arc::new(SharedState::new());
    let (producer, consumer) = RingBuffer::new(capacity_frames);
    Ok((
        Box::new(ArcoAudioRtProducer {
            ring: producer,
            format,
            shared: Arc::clone(&shared),
        }),
        Box::new(ArcoAudioRtConsumer {
            ring: consumer,
            shared,
            format,
            resampler,
            input,
            output,
            input_len: 0,
            output_delay_remaining: output_delay,
            segment_real_input_frames: 0,
            segment_output_frames: 0,
            observed_epoch: 0,
            flush_rounds: 0,
            done: false,
        }),
    ))
}

#[no_mangle]
/// Creates the paired producer and consumer handles for one audio source.
///
/// # Safety
/// `format`, `out_producer`, and `out_consumer` must point to live, writable C
/// objects for the duration of this call. The returned handles must each be
/// destroyed exactly once with their matching destroy function.
pub unsafe extern "C" fn arco_audio_rt_source_create(
    format: *const AudioStreamBasicDescription,
    target_rate: f64,
    capacity_frames: u32,
    out_producer: *mut *mut ArcoAudioRtProducer,
    out_consumer: *mut *mut ArcoAudioRtConsumer,
) -> i32 {
    if format.is_null()
        || out_producer.is_null()
        || out_consumer.is_null()
        || out_producer.cast::<u8>() == out_consumer.cast::<u8>()
    {
        return STATUS_INVALID_ARGUMENT;
    }
    // SAFETY: validated non-null output pointers belong to the caller.
    unsafe {
        *out_producer = ptr::null_mut();
        *out_consumer = ptr::null_mut();
    }
    match catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: the caller supplies a live ASBD for this call.
        create_source(unsafe { &*format }, target_rate, capacity_frames as usize)
    })) {
        Ok(Ok((producer, consumer))) => {
            // SAFETY: ownership is transferred to the opaque C handles.
            unsafe {
                *out_producer = Box::into_raw(producer);
                *out_consumer = Box::into_raw(consumer);
            }
            STATUS_OK
        }
        Ok(Err(status)) => status,
        Err(_) => STATUS_PANIC,
    }
}

#[no_mangle]
/// Pushes one planar floating-point callback into the real-time queue.
///
/// # Safety
/// `producer` must be a live producer handle and must not be used concurrently.
/// `channels` must contain `channel_count` readable pointers, each with at least
/// `frame_count` samples.
pub unsafe extern "C" fn arco_audio_rt_push_planar_f32(
    producer: *mut ArcoAudioRtProducer,
    channels: *const *const f32,
    channel_count: u32,
    frame_count: u32,
) -> ArcoAudioRtPushResult {
    if producer.is_null() {
        return ArcoAudioRtPushResult {
            status: STATUS_INVALID_ARGUMENT,
            ..Default::default()
        };
    }
    match catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: opaque producer ownership remains with the caller.
        unsafe {
            (&mut *producer).push_planar(channels, channel_count as usize, frame_count as usize)
        }
    })) {
        Ok(result) => result,
        Err(_) => ArcoAudioRtPushResult {
            status: STATUS_PANIC,
            ..Default::default()
        },
    }
}

#[no_mangle]
/// Pushes a Core Audio buffer list into the real-time queue.
///
/// # Safety
/// `producer` must be a live, uniquely accessed producer handle. `input` must
/// point to a complete `AudioBufferList` whose buffers match the ASBD supplied
/// when the source was created.
pub unsafe extern "C" fn arco_audio_rt_push_audio_buffer_list(
    producer: *mut ArcoAudioRtProducer,
    input: *const AudioBufferList,
) -> ArcoAudioRtPushResult {
    if producer.is_null() {
        return ArcoAudioRtPushResult {
            status: STATUS_INVALID_ARGUMENT,
            ..Default::default()
        };
    }
    match catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: opaque producer ownership remains with the caller.
        unsafe { (&mut *producer).push_buffer_list(input) }
    })) {
        Ok(result) => result,
        Err(_) => ArcoAudioRtPushResult {
            status: STATUS_PANIC,
            ..Default::default()
        },
    }
}

#[no_mangle]
/// Drains converted 16 kHz mono PCM into the caller's output buffer.
///
/// # Safety
/// `consumer` must be a live, uniquely accessed consumer handle. `output` must
/// point to at least `capacity_frames` writable `i16` samples.
pub unsafe extern "C" fn arco_audio_rt_consumer_drain_i16(
    consumer: *mut ArcoAudioRtConsumer,
    output: *mut i16,
    capacity_frames: u32,
) -> ArcoAudioRtDrainResult {
    if consumer.is_null() || output.is_null() {
        return ArcoAudioRtDrainResult {
            status: STATUS_INVALID_ARGUMENT,
            ..Default::default()
        };
    }
    match catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: caller owns an output allocation of capacity_frames samples.
        let destination = unsafe { slice::from_raw_parts_mut(output, capacity_frames as usize) };
        // SAFETY: opaque consumer ownership remains with the caller.
        unsafe { (&mut *consumer).drain(destination) }
    })) {
        Ok(result) => result,
        Err(_) => ArcoAudioRtDrainResult {
            status: STATUS_PANIC,
            ..Default::default()
        },
    }
}

#[no_mangle]
/// Marks a producer complete so the consumer can flush its delayed output.
///
/// # Safety
/// `producer` must be a live producer handle that has not been destroyed.
pub unsafe extern "C" fn arco_audio_rt_producer_finish(producer: *mut ArcoAudioRtProducer) -> i32 {
    if producer.is_null() {
        return STATUS_INVALID_ARGUMENT;
    }
    match catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: opaque producer ownership remains with the caller.
        unsafe { (&*producer).shared.finished.store(true, Ordering::Release) };
    })) {
        Ok(()) => STATUS_OK,
        Err(_) => STATUS_PANIC,
    }
}

#[no_mangle]
/// Destroys a producer handle.
///
/// # Safety
/// `producer` must be null or a live handle returned by `source_create`, and a
/// non-null handle must be passed here at most once.
pub unsafe extern "C" fn arco_audio_rt_producer_destroy(producer: *mut ArcoAudioRtProducer) {
    if producer.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: this function consumes the unique opaque handle exactly once.
        drop(unsafe { Box::from_raw(producer) });
    }));
}

#[no_mangle]
/// Destroys a consumer handle.
///
/// # Safety
/// `consumer` must be null or a live handle returned by `source_create`, and a
/// non-null handle must be passed here at most once.
pub unsafe extern "C" fn arco_audio_rt_consumer_destroy(consumer: *mut ArcoAudioRtConsumer) {
    if consumer.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: this function consumes the unique opaque handle exactly once.
        drop(unsafe { Box::from_raw(consumer) });
    }));
}

#[no_mangle]
/// Core Audio device callback that forwards the input buffer list to a producer.
///
/// # Safety
/// Core Audio must supply valid callback pointers. `in_client_data` must be null
/// or a live, uniquely callback-owned producer handle for the callback lifetime.
pub unsafe extern "C" fn arco_audio_rt_io_proc(
    _in_device: u32,
    _in_now: *const c_void,
    in_input_data: *const AudioBufferList,
    _in_input_time: *const c_void,
    _out_output_data: *mut AudioBufferList,
    _in_output_time: *const c_void,
    in_client_data: *mut c_void,
) -> i32 {
    if in_client_data.is_null() || in_input_data.is_null() {
        return 0;
    }
    let producer = in_client_data.cast::<ArcoAudioRtProducer>();
    let _ = catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: Core Audio invokes this with the stable producer clientData.
        unsafe { (&mut *producer).push_buffer_list(in_input_data) }
    }));
    0
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::f32::consts::TAU;
    use std::mem::{align_of, offset_of, size_of};

    fn float_format(
        rate: usize,
        channels: usize,
        non_interleaved: bool,
    ) -> AudioStreamBasicDescription {
        let flags = FORMAT_FLAG_IS_FLOAT
            | FORMAT_FLAG_IS_PACKED
            | if non_interleaved {
                FORMAT_FLAG_IS_NON_INTERLEAVED
            } else {
                0
            };
        let bytes = if non_interleaved { 4 } else { 4 * channels };
        AudioStreamBasicDescription {
            sample_rate: rate as f64,
            format_id: LINEAR_PCM_FORMAT_ID,
            format_flags: flags,
            bytes_per_packet: bytes as u32,
            frames_per_packet: 1,
            bytes_per_frame: bytes as u32,
            channels_per_frame: channels as u32,
            bits_per_channel: 32,
            reserved: 0,
        }
    }

    fn signed_16_format(
        rate: usize,
        channels: usize,
        non_interleaved: bool,
    ) -> AudioStreamBasicDescription {
        let flags = FORMAT_FLAG_IS_SIGNED_INTEGER
            | FORMAT_FLAG_IS_PACKED
            | if non_interleaved {
                FORMAT_FLAG_IS_NON_INTERLEAVED
            } else {
                0
            };
        let bytes = if non_interleaved { 2 } else { 2 * channels };
        AudioStreamBasicDescription {
            sample_rate: rate as f64,
            format_id: LINEAR_PCM_FORMAT_ID,
            format_flags: flags,
            bytes_per_packet: bytes as u32,
            frames_per_packet: 1,
            bytes_per_frame: bytes as u32,
            channels_per_frame: channels as u32,
            bits_per_channel: 16,
            reserved: 0,
        }
    }

    fn drain_all(
        producer: &mut ArcoAudioRtProducer,
        consumer: &mut ArcoAudioRtConsumer,
    ) -> Vec<i16> {
        producer.shared.finished.store(true, Ordering::Release);
        let mut result = Vec::new();
        for _ in 0..16 {
            let mut scratch = vec![0i16; 8192];
            let drained = consumer.drain(&mut scratch);
            assert_eq!(drained.status, STATUS_OK);
            result.extend_from_slice(&scratch[..drained.frame_count as usize]);
            if drained.finished != 0 {
                return result;
            }
        }
        panic!("consumer did not finish");
    }

    fn push_signal(
        producer: &mut ArcoAudioRtProducer,
        consumer: &mut ArcoAudioRtConsumer,
        signal: &[f32],
        callback_sizes: &[usize],
    ) -> Vec<i16> {
        let mut offset = 0usize;
        let mut drained = Vec::new();
        let mut callback_index = 0usize;
        while offset < signal.len() {
            let size =
                callback_sizes[callback_index % callback_sizes.len()].min(signal.len() - offset);
            let pointer = signal[offset..].as_ptr();
            let channels = [pointer];
            let pushed = unsafe { producer.push_planar(channels.as_ptr(), 1, size) };
            assert_eq!(pushed.status, STATUS_OK);
            assert_eq!(pushed.accepted_frames as usize, size);
            offset += size;
            callback_index += 1;

            let mut scratch = vec![0i16; 8192];
            let value = consumer.drain(&mut scratch);
            assert_eq!(value.status, STATUS_OK);
            drained.extend_from_slice(&scratch[..value.frame_count as usize]);
        }
        drained.extend(drain_all(producer, consumer));
        drained
    }

    #[test]
    fn rejects_invalid_and_unpacked_formats_without_creating_handles() {
        let mut format = float_format(48_000, 1, true);
        format.format_flags &= !FORMAT_FLAG_IS_PACKED;
        assert!(matches!(
            create_source(&format, 16_000.0, 48_000),
            Err(STATUS_UNSUPPORTED_FORMAT)
        ));

        let status = unsafe {
            arco_audio_rt_source_create(ptr::null(), 16_000.0, 1, ptr::null_mut(), ptr::null_mut())
        };
        assert_eq!(status, STATUS_INVALID_ARGUMENT);

        let huge_rate = float_format(MAX_SAMPLE_RATE + 1, 1, true);
        assert!(matches!(
            create_source(&huge_rate, 16_000.0, 48_000),
            Err(STATUS_UNSUPPORTED_FORMAT)
        ));
        let normal = float_format(48_000, 1, true);
        assert!(matches!(
            create_source(&normal, 16_000.0, MAX_RING_CAPACITY_FRAMES + 1),
            Err(STATUS_INVALID_ARGUMENT)
        ));

        let mut aliased_output: *mut ArcoAudioRtProducer = ptr::null_mut();
        let aliased_status = unsafe {
            arco_audio_rt_source_create(
                &normal,
                16_000.0,
                48_000,
                &mut aliased_output,
                (&mut aliased_output as *mut *mut ArcoAudioRtProducer)
                    .cast::<*mut ArcoAudioRtConsumer>(),
            )
        };
        assert_eq!(aliased_status, STATUS_INVALID_ARGUMENT);
        assert!(aliased_output.is_null());
    }

    #[test]
    fn core_audio_and_result_types_have_the_expected_64_bit_c_layout() {
        assert_eq!(size_of::<AudioStreamBasicDescription>(), 40);
        assert_eq!(align_of::<AudioStreamBasicDescription>(), 8);
        assert_eq!(offset_of!(AudioStreamBasicDescription, sample_rate), 0);
        assert_eq!(offset_of!(AudioStreamBasicDescription, format_id), 8);
        assert_eq!(offset_of!(AudioStreamBasicDescription, reserved), 36);

        assert_eq!(size_of::<AudioBuffer>(), 16);
        assert_eq!(align_of::<AudioBuffer>(), 8);
        assert_eq!(offset_of!(AudioBuffer, number_channels), 0);
        assert_eq!(offset_of!(AudioBuffer, data_byte_size), 4);
        assert_eq!(offset_of!(AudioBuffer, data), 8);
        assert_eq!(size_of::<AudioBufferList>(), 24);
        assert_eq!(offset_of!(AudioBufferList, buffers), 8);

        assert_eq!(size_of::<ArcoAudioRtPushResult>(), 24);
        assert_eq!(align_of::<ArcoAudioRtPushResult>(), 8);
        assert_eq!(offset_of!(ArcoAudioRtPushResult, overflow_epoch), 16);
        assert_eq!(size_of::<ArcoAudioRtDrainResult>(), 24);
        assert_eq!(align_of::<ArcoAudioRtDrainResult>(), 8);
        assert_eq!(offset_of!(ArcoAudioRtDrainResult, dropped_input_frames), 8);
        assert_eq!(offset_of!(ArcoAudioRtDrainResult, reserved), 18);
    }

    #[test]
    fn common_rates_finish_with_the_exact_expected_frame_count() {
        for rate in [44_100usize, 48_000, 96_000] {
            let format = float_format(rate, 1, true);
            let (mut producer, mut consumer) = create_source(&format, 16_000.0, rate * 2).unwrap();
            let signal: Vec<f32> = (0..rate)
                .map(|frame| (TAU * 1_000.0 * frame as f32 / rate as f32).sin())
                .collect();
            let output = push_signal(
                &mut producer,
                &mut consumer,
                &signal,
                &[997, 4_801, 127, 8_113],
            );
            assert_eq!(output.len(), 16_000, "wrong output length for {rate}");
        }
    }

    #[test]
    fn partial_chunks_finish_with_rounded_exact_frame_counts() {
        for rate in [44_100usize, 48_000, 96_000] {
            let format = float_format(rate, 1, true);
            let chunk = FormatSpec::parse(&format, 16_000.0).unwrap().chunk_size();
            for length in [0, 1, chunk - 1, chunk, chunk + 1, rate / 3 + 7] {
                let (mut producer, mut consumer) =
                    create_source(&format, 16_000.0, length.max(chunk) * 2).unwrap();
                let signal = vec![0.25f32; length];
                if !signal.is_empty() {
                    let channels = [signal.as_ptr()];
                    let pushed =
                        unsafe { producer.push_planar(channels.as_ptr(), 1, signal.len()) };
                    assert_eq!(pushed.status, STATUS_OK);
                    assert_eq!(pushed.accepted_frames as usize, signal.len());
                }
                let output = drain_all(&mut producer, &mut consumer);
                let expected =
                    ((length as u128 * 16_000 + rate as u128 / 2) / rate as u128) as usize;
                assert_eq!(
                    output.len(),
                    expected,
                    "wrong final frame count for rate={rate}, input={length}"
                );
            }
        }
    }

    #[test]
    fn irregular_callbacks_preserve_signal_continuity() {
        let rate = 48_000usize;
        let format = float_format(rate, 1, true);
        let (mut producer, mut consumer) = create_source(&format, 16_000.0, rate * 2).unwrap();
        let signal: Vec<f32> = (0..rate)
            .map(|frame| (TAU * 1_000.0 * frame as f32 / rate as f32).sin())
            .collect();
        let output = push_signal(
            &mut producer,
            &mut consumer,
            &signal,
            &[1, 997, 4_801, 127, 8_113, 31],
        );
        assert_eq!(output.len(), 16_000);
        let largest_step = output
            .windows(2)
            .skip(512)
            .map(|pair| (i32::from(pair[1]) - i32::from(pair[0])).unsigned_abs())
            .max()
            .unwrap_or_default();
        assert!(
            largest_step < 16_384,
            "callback boundaries introduced a discontinuity: {largest_step}"
        );
    }

    #[test]
    fn fft_resampler_rejects_aliases_and_preserves_the_voice_passband() {
        let rate = 48_000usize;
        let run = |frequency: f32| {
            let format = float_format(rate, 1, true);
            let (mut producer, mut consumer) = create_source(&format, 16_000.0, rate * 2).unwrap();
            let signal: Vec<f32> = (0..rate)
                .map(|frame| (TAU * frequency * frame as f32 / rate as f32).sin())
                .collect();
            let output = push_signal(
                &mut producer,
                &mut consumer,
                &signal,
                &[311, 2_003, 97, 4_799],
            );
            let body = &output[512.min(output.len())..];
            (body
                .iter()
                .map(|value| (*value as f64 / 32_768.0).powi(2))
                .sum::<f64>()
                / body.len().max(1) as f64)
                .sqrt()
        };
        let passband_rms = run(7_000.0);
        let alias_rms = run(12_000.0);
        assert!(
            passband_rms > 0.25,
            "7 kHz passband was attenuated: {passband_rms}"
        );
        assert!(alias_rms < 0.05, "12 kHz aliased into output: {alias_rms}");
    }

    #[test]
    fn overflow_discards_stale_audio_before_accepting_fresh_callbacks() {
        let format = float_format(48_000, 1, true);
        let (mut producer, mut consumer) = create_source(&format, 16_000.0, 960).unwrap();
        let old = vec![-0.75f32; 960];
        let old_ptrs = [old.as_ptr()];
        let first = unsafe { producer.push_planar(old_ptrs.as_ptr(), 1, old.len()) };
        assert_eq!(first.accepted_frames, 960);

        let overflow = unsafe { producer.push_planar(old_ptrs.as_ptr(), 1, old.len()) };
        assert_eq!(overflow.accepted_frames, 0);
        assert_eq!(overflow.dropped_frames, 960);
        let waiting_for_ack = unsafe { producer.push_planar(old_ptrs.as_ptr(), 1, old.len()) };
        assert_eq!(waiting_for_ack.accepted_frames, 0);
        assert_eq!(waiting_for_ack.overflow_epoch, overflow.overflow_epoch);
        let mut scratch = vec![0i16; 8192];
        let discontinuity = consumer.drain(&mut scratch);
        assert_eq!(discontinuity.discontinuity, 1);
        assert_eq!(discontinuity.dropped_input_frames, 2_880);

        let fresh = vec![0.75f32; 960];
        let fresh_ptrs = [fresh.as_ptr()];
        let accepted = unsafe { producer.push_planar(fresh_ptrs.as_ptr(), 1, fresh.len()) };
        assert_eq!(accepted.accepted_frames, 960);
        let output = drain_all(&mut producer, &mut consumer);
        assert!(!output.is_empty());
        assert!(
            output.iter().map(|value| *value as i64).sum::<i64>() > 0,
            "stale negative audio survived overflow reset"
        );
    }

    #[test]
    fn overflow_counts_and_discards_partial_resampler_input() {
        let format = float_format(48_000, 1, true);
        let (mut producer, mut consumer) = create_source(&format, 16_000.0, 960).unwrap();
        let stale_partial = vec![-0.75f32; 480];
        let stale_partial_ptrs = [stale_partial.as_ptr()];
        assert_eq!(
            unsafe { producer.push_planar(stale_partial_ptrs.as_ptr(), 1, stale_partial.len()) }
                .accepted_frames,
            480
        );
        let mut scratch = vec![0i16; 8192];
        let partial = consumer.drain(&mut scratch);
        assert_eq!(partial.frame_count, 0);
        assert_eq!(consumer.input_len, 480);

        let stale_ring = vec![-0.75f32; 960];
        let stale_ring_ptrs = [stale_ring.as_ptr()];
        assert_eq!(
            unsafe { producer.push_planar(stale_ring_ptrs.as_ptr(), 1, stale_ring.len()) }
                .accepted_frames,
            960
        );
        let overflow =
            unsafe { producer.push_planar(stale_ring_ptrs.as_ptr(), 1, stale_ring.len()) };
        assert_eq!(overflow.dropped_frames, 960);
        let discontinuity = consumer.drain(&mut scratch);
        assert_eq!(discontinuity.discontinuity, 1);
        assert_eq!(discontinuity.dropped_input_frames, 2_400);

        let fresh = vec![0.75f32; 960];
        let fresh_ptrs = [fresh.as_ptr()];
        assert_eq!(
            unsafe { producer.push_planar(fresh_ptrs.as_ptr(), 1, fresh.len()) }.accepted_frames,
            960
        );
        let output = drain_all(&mut producer, &mut consumer);
        assert!(output.iter().map(|value| i64::from(*value)).sum::<i64>() > 0);
    }

    #[test]
    fn audio_buffer_list_handles_interleaved_and_non_interleaved_float_pcm() {
        let interleaved_format = float_format(48_000, 2, false);
        let (mut producer, mut consumer) =
            create_source(&interleaved_format, 16_000.0, 4_800).unwrap();
        let mut samples = Vec::with_capacity(1_920);
        for _ in 0..960 {
            samples.push(0.25f32);
            samples.push(0.75f32);
        }
        let list = AudioBufferList {
            number_buffers: 1,
            buffers: [AudioBuffer {
                number_channels: 2,
                data_byte_size: (samples.len() * 4) as u32,
                data: samples.as_ptr().cast(),
            }],
        };
        let pushed = unsafe { producer.push_buffer_list(&list) };
        assert_eq!(pushed.accepted_frames, 960);
        let output = drain_all(&mut producer, &mut consumer);
        assert!(!output.is_empty());

        let planar_format = float_format(48_000, 1, true);
        let (mut producer, _) = create_source(&planar_format, 16_000.0, 4_800).unwrap();
        let plane = vec![0.5f32; 960];
        let planar_list = AudioBufferList {
            number_buffers: 1,
            buffers: [AudioBuffer {
                number_channels: 1,
                data_byte_size: (plane.len() * 4) as u32,
                data: plane.as_ptr().cast(),
            }],
        };
        assert_eq!(
            unsafe { producer.push_buffer_list(&planar_list) }.accepted_frames,
            960
        );
    }

    #[test]
    fn audio_buffer_list_handles_multichannel_planar_and_signed_pcm() {
        #[repr(C)]
        struct AudioBufferList2 {
            number_buffers: u32,
            buffers: [AudioBuffer; 2],
        }

        let planar_format = float_format(48_000, 2, true);
        let (mut producer, mut consumer) = create_source(&planar_format, 16_000.0, 4_800).unwrap();
        let left = vec![0.25f32; 960];
        let right = vec![0.75f32; 960];
        let list = AudioBufferList2 {
            number_buffers: 2,
            buffers: [
                AudioBuffer {
                    number_channels: 1,
                    data_byte_size: (left.len() * 4) as u32,
                    data: left.as_ptr().cast(),
                },
                AudioBuffer {
                    number_channels: 1,
                    data_byte_size: (right.len() * 4) as u32,
                    data: right.as_ptr().cast(),
                },
            ],
        };
        let pushed =
            unsafe { producer.push_buffer_list(ptr::addr_of!(list).cast::<AudioBufferList>()) };
        assert_eq!(pushed.accepted_frames, 960);
        let output = drain_all(&mut producer, &mut consumer);
        assert_eq!(output.len(), 320);
        let planar_mean = output
            .iter()
            .skip(64)
            .map(|sample| i64::from(*sample))
            .sum::<i64>()
            / (output.len() - 64) as i64;
        assert!((15_000..=18_000).contains(&planar_mean));

        let signed_format = signed_16_format(48_000, 2, false);
        let (mut producer, mut consumer) = create_source(&signed_format, 16_000.0, 4_800).unwrap();
        let signed: Vec<i16> = (0..960).flat_map(|_| [8_192, 24_576]).collect();
        let signed_list = AudioBufferList {
            number_buffers: 1,
            buffers: [AudioBuffer {
                number_channels: 2,
                data_byte_size: (signed.len() * 2) as u32,
                data: signed.as_ptr().cast(),
            }],
        };
        let pushed = unsafe { producer.push_buffer_list(&signed_list) };
        assert_eq!(pushed.accepted_frames, 960);
        let output = drain_all(&mut producer, &mut consumer);
        assert_eq!(output.len(), 320);
        let signed_mean = output
            .iter()
            .skip(64)
            .map(|sample| i64::from(*sample))
            .sum::<i64>()
            / (output.len() - 64) as i64;
        assert!((15_000..=18_000).contains(&signed_mean));
    }

    #[test]
    fn ffi_rejects_invalid_and_zero_capacity_null_pointers_without_ub() {
        let invalid_push =
            unsafe { arco_audio_rt_push_planar_f32(ptr::null_mut(), ptr::null(), 0, 0) };
        assert_eq!(invalid_push.status, STATUS_INVALID_ARGUMENT);
        let invalid_drain =
            unsafe { arco_audio_rt_consumer_drain_i16(ptr::null_mut(), ptr::null_mut(), 0) };
        assert_eq!(invalid_drain.status, STATUS_INVALID_ARGUMENT);

        let format = float_format(48_000, 1, true);
        let mut producer = ptr::null_mut();
        let mut consumer = ptr::null_mut();
        let status = unsafe {
            arco_audio_rt_source_create(&format, 16_000.0, 4_800, &mut producer, &mut consumer)
        };
        assert_eq!(status, STATUS_OK);
        assert!(!producer.is_null());
        assert!(!consumer.is_null());
        let zero_capacity =
            unsafe { arco_audio_rt_consumer_drain_i16(consumer, ptr::null_mut(), 0) };
        assert_eq!(zero_capacity.status, STATUS_INVALID_ARGUMENT);
        assert_eq!(
            unsafe { arco_audio_rt_producer_finish(producer) },
            STATUS_OK
        );
        unsafe {
            arco_audio_rt_producer_destroy(producer);
            arco_audio_rt_consumer_destroy(consumer);
        }
    }
}
