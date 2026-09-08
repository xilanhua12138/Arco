//! Replay raw 16 kHz stereo i16 PCM through the same AEC used by the recorder.
//! Usage: cargo run --release --example aec_replay < input.pcm > output.pcm
use arco_audio_rt::echo_canceller::{EchoCanceller, MAX_STEREO_FRAMES};
use std::io::{self, Read, Write};
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut aec = EchoCanceller::new()?;
    let mut input = io::stdin().lock();
    let mut output = io::BufWriter::new(io::stdout().lock());
    let mut bytes = [0u8; MAX_STEREO_FRAMES * 4];
    loop {
        let mut count = 0;
        while count < bytes.len() {
            let n = input.read(&mut bytes[count..])?;
            if n == 0 {
                break;
            }
            count += n;
        }
        if count == 0 {
            break;
        }
        if count % 4 != 0 {
            return Err("input ends in an incomplete stereo frame".into());
        }
        let mut samples: Vec<i16> = bytes[..count]
            .chunks_exact(2)
            .map(|x| i16::from_le_bytes([x[0], x[1]]))
            .collect();
        aec.process_stereo(&mut samples)?;
        for sample in samples {
            output.write_all(&sample.to_le_bytes())?;
        }
    }
    output.flush()?;
    Ok(())
}
