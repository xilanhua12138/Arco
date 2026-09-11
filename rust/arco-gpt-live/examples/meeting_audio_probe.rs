//! Device integration probe: generated tones only, no microphone or meeting recording.
use arco_gpt_live::{
    meeting_audio::{MeetingAudioBridge, send_microphone},
    meeting_route::{MeetingRoute, physical_microphone_uid, recover_stale},
};
use rodio::{
    buffer::SamplesBuffer,
    cpal::{
        self,
        traits::{DeviceTrait, HostTrait, StreamTrait},
    },
    nz,
};
use std::sync::{Arc, Mutex};
use std::time::Duration;
fn default_name() -> String {
    cpal::default_host()
        .default_input_device()
        .unwrap()
        .description()
        .unwrap()
        .name()
        .to_owned()
}
fn main() -> Result<(), Box<dyn std::error::Error>> {
    if std::env::args().any(|s| s == "--crash-child") {
        let _route = MeetingRoute::connect()?;
        println!("ROUTE_CONNECTED");
        loop {
            std::thread::sleep(Duration::from_secs(1));
        }
    }
    recover_stale()?;
    let original = default_name();
    println!(
        "Original input: {original}; UID: {}",
        physical_microphone_uid()?
    );
    let bridge = MeetingAudioBridge::open(true)?;
    assert!(bridge.assistant.is_some(), "virtual output must exist");
    let route = MeetingRoute::connect()?;
    assert_eq!(default_name(), "BlackHole 2ch");
    assert!(route.connected());
    assert!(
        MeetingRoute::connect().is_err(),
        "concurrent owners rejected"
    );
    let input = cpal::default_host().default_input_device().unwrap();
    let config = input.default_input_config()?;
    assert_eq!(config.sample_format(), cpal::SampleFormat::F32);
    let rate = config.sample_rate() as usize;
    let channels = config.channels() as usize;
    let captured = Arc::new(Mutex::new(Vec::<f32>::new()));
    let samples = Arc::clone(&captured);
    let stream = input.build_input_stream(
        &config.config(),
        move |data: &[f32], _| samples.lock().unwrap().extend(data),
        |e| eprintln!("capture: {e}"),
        None,
    )?;
    stream.play()?;
    std::thread::sleep(Duration::from_millis(150));
    let mut mic = Vec::new();
    for n in 0..16_000 {
        mic.push((7000.0 * (n as f32 * 1650.0 * std::f32::consts::TAU / 16000.0).sin()) as i16);
        mic.push((7000.0 * (n as f32 * 320.0 * std::f32::consts::TAU / 16000.0).sin()) as i16);
    }
    send_microphone(bridge.microphone.as_ref().unwrap(), &mic)?;
    let ai = (0..48_000)
        .map(|n| 0.21 * (n as f32 * 880.0 * std::f32::consts::TAU / 48000.0).sin())
        .collect::<Vec<_>>();
    bridge
        .assistant
        .as_ref()
        .unwrap()
        .append(SamplesBuffer::new(nz!(1), nz!(48_000), ai));
    std::thread::sleep(Duration::from_millis(1400));
    drop(stream);
    let captured = captured.lock().unwrap();
    let mono: Vec<f32> = captured.chunks_exact(channels).map(|f| f[0]).collect();
    let amplitude = |freq: f64| -> f64 {
        let (sin, cos) = mono.iter().enumerate().fold((0.0, 0.0), |(s, c), (i, x)| {
            let a = i as f64 * freq * std::f64::consts::TAU / rate as f64;
            (s + *x as f64 * a.sin(), c + *x as f64 * a.cos())
        });
        2.0 * (sin * sin + cos * cos).sqrt() / mono.len() as f64
    };
    println!(
        "frames={} rate={} channels={} peak={} rms={}",
        mono.len(),
        rate,
        channels,
        mono.iter().fold(0.0f32, |a, x| a.max(x.abs())),
        (mono.iter().map(|x| x * x).sum::<f32>() / mono.len() as f32).sqrt()
    );
    let mic = amplitude(320.0);
    let ai = amplitude(880.0);
    let remote = amplitude(1650.0);
    println!("Measured virtual microphone: mic={mic:.5}, AI={ai:.5}, excluded system={remote:.5}");
    drop(route);
    assert_eq!(default_name(), original);
    println!("PASS: default microphone restored");
    assert!(
        mic > 0.015 && ai > 0.015 && remote < 0.003,
        "both send sources, no system loopback"
    );
    println!("PASS: real BlackHole input carries microphone + assistant; system audio excluded");
    use std::io::{BufRead, BufReader};
    let mut child = std::process::Command::new(std::env::current_exe()?)
        .arg("--crash-child")
        .stdout(std::process::Stdio::piped())
        .spawn()?;
    let mut line = String::new();
    BufReader::new(child.stdout.take().unwrap()).read_line(&mut line)?;
    assert!(line.contains("ROUTE_CONNECTED"));
    child.kill()?;
    child.wait()?;
    assert_eq!(default_name(), "BlackHole 2ch");
    recover_stale()?;
    assert_eq!(default_name(), original);
    println!("PASS: killed worker recovered using persisted original microphone");
    Ok(())
}
