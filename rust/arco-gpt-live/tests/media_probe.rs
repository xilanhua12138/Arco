use std::time::Duration;

use arco_gpt_live::{
    GPT_LIVE_INPUT_FRAME_SAMPLES_PER_CHANNEL, GptLiveWebRtcPeer, InboundOpusAction,
    InboundOpusPacket, InboundOpusReorderBuffer, OPUS_FRAME_SAMPLES_PER_CHANNEL, OpusDuplex,
    RecorderPcmFramer, RemotePlaybackPrebuffer, SpeechEnergyGate, TranscriptMarkerGate,
    create_audio_offer,
};

fn inbound_packet(sequence_number: u16, marker: u8) -> InboundOpusPacket {
    InboundOpusPacket::new(0x4152_434f, sequence_number, vec![marker])
}

#[test]
fn inbound_opus_packets_are_decoded_in_rtp_sequence_order() {
    let mut reorder = InboundOpusReorderBuffer::gpt_live();

    assert_eq!(
        reorder.push(inbound_packet(10, 10)).unwrap(),
        vec![InboundOpusAction::Decode(vec![10])]
    );
    assert!(reorder.push(inbound_packet(12, 12)).unwrap().is_empty());
    assert_eq!(
        reorder.push(inbound_packet(11, 11)).unwrap(),
        vec![
            InboundOpusAction::Decode(vec![11]),
            InboundOpusAction::Decode(vec![12]),
        ]
    );
}

#[test]
fn inbound_opus_packet_loss_uses_concealment_before_the_next_packet() {
    let mut reorder = InboundOpusReorderBuffer::gpt_live();

    reorder.push(inbound_packet(100, 100)).unwrap();
    assert!(reorder.push(inbound_packet(102, 102)).unwrap().is_empty());
    assert_eq!(
        reorder.flush_timeout(),
        vec![
            InboundOpusAction::Conceal20ms,
            InboundOpusAction::Decode(vec![102]),
        ]
    );
}

#[test]
fn inbound_opus_reordering_survives_rtp_sequence_wraparound() {
    let mut reorder = InboundOpusReorderBuffer::gpt_live();

    reorder.push(inbound_packet(u16::MAX, 1)).unwrap();
    assert!(reorder.push(inbound_packet(1, 3)).unwrap().is_empty());
    assert_eq!(
        reorder.push(inbound_packet(0, 2)).unwrap(),
        vec![
            InboundOpusAction::Decode(vec![2]),
            InboundOpusAction::Decode(vec![3]),
        ]
    );
}

#[test]
fn inbound_opus_rejects_an_unexpected_audio_source_change() {
    let mut reorder = InboundOpusReorderBuffer::gpt_live();

    reorder.push(inbound_packet(1, 1)).unwrap();
    let error = reorder
        .push(InboundOpusPacket::new(0xDEAD_BEEF, 2, vec![2]))
        .unwrap_err();

    assert_eq!(error, "GPT-Live WebRTC audio source changed unexpectedly");
}

#[test]
fn remote_playback_waits_for_three_frames_at_each_queue_restart() {
    let mut prebuffer = RemotePlaybackPrebuffer::gpt_live();
    let frame = vec![7_i16; OPUS_FRAME_SAMPLES_PER_CHANNEL * 2];

    assert!(prebuffer.push(&frame).is_none());
    assert!(prebuffer.push(&frame).is_none());
    assert_eq!(
        prebuffer.push(&frame).unwrap().len(),
        OPUS_FRAME_SAMPLES_PER_CHANNEL * 2 * 3
    );

    prebuffer.reset();
    assert!(prebuffer.push(&frame).is_none());
}

#[test]
fn transcript_marker_gate_accepts_a_marker_split_across_events() {
    let mut gate = TranscriptMarkerGate::new("Arco GPT Live transport test OK").unwrap();

    assert!(!gate.observe("Arco GPT "));
    assert!(gate.observe("Live transport test OK."));
}

#[test]
fn recorder_pcm_framer_preserves_fragmented_twenty_millisecond_frames() {
    let samples = (0..GPT_LIVE_INPUT_FRAME_SAMPLES_PER_CHANNEL * 2)
        .map(|value| value as i16 - 320)
        .collect::<Vec<_>>();
    let bytes = samples
        .iter()
        .flat_map(|sample| sample.to_le_bytes())
        .collect::<Vec<_>>();
    let mut framer = RecorderPcmFramer::new();

    assert!(framer.push(&bytes[..77]).unwrap().is_empty());
    let frames = framer.push(&bytes[77..]).unwrap();
    assert_eq!(frames, vec![samples]);
    assert!(framer.finish().is_ok());

    let mut malformed = RecorderPcmFramer::new();
    assert!(malformed.push(&[1]).unwrap().is_empty());
    assert_eq!(
        malformed.finish().unwrap_err(),
        "GPT-Live recorder ended with an incomplete PCM frame"
    );
}

#[test]
fn transcript_marker_gate_rejects_unrelated_lifecycle_events() {
    let mut gate = TranscriptMarkerGate::new("Arco GPT Live transport test OK").unwrap();

    assert!(!gate.observe("session.usage.updated"));
    assert!(!gate.observe("The session is ready."));
}

#[test]
fn speech_energy_gate_rejects_silence_and_comfort_noise() {
    let mut gate = SpeechEnergyGate::gpt_live_smoke();
    let silence = vec![0_i16; OPUS_FRAME_SAMPLES_PER_CHANNEL * 2];
    let comfort_noise = vec![100_i16; OPUS_FRAME_SAMPLES_PER_CHANNEL * 2];

    for _ in 0..10 {
        assert!(!gate.observe_stereo(&silence).unwrap());
        assert!(!gate.observe_stereo(&comfort_noise).unwrap());
    }
}

#[test]
fn speech_energy_gate_requires_one_hundred_milliseconds_above_minus_fifty_dbfs() {
    let mut gate = SpeechEnergyGate::gpt_live_smoke();
    let speech = vec![1_000_i16; OPUS_FRAME_SAMPLES_PER_CHANNEL * 2];

    for _ in 0..4 {
        assert!(!gate.observe_stereo(&speech).unwrap());
    }
    assert!(gate.observe_stereo(&speech).unwrap());
}

#[test]
fn speech_energy_gate_rejects_malformed_stereo_pcm() {
    let mut gate = SpeechEnergyGate::gpt_live_smoke();

    assert_eq!(
        gate.observe_stereo(&[1_i16]).unwrap_err(),
        "GPT-Live speech probe requires complete stereo PCM frames"
    );
}

#[test]
fn opus_library_encodes_and_decodes_a_twenty_millisecond_stereo_frame() {
    let mut codec = OpusDuplex::new().unwrap();
    let mut input = vec![0_i16; OPUS_FRAME_SAMPLES_PER_CHANNEL * 2];
    input[100] = 10_000;
    input[101] = -10_000;

    let packet = codec.encode_20ms_stereo(&input).unwrap();
    let decoded = codec.decode_stereo(&packet).unwrap();

    assert!(!packet.is_empty());
    assert!(packet.len() <= 1_275);
    assert_eq!(decoded.len(), OPUS_FRAME_SAMPLES_PER_CHANNEL * 2);
    assert!(decoded.iter().any(|sample| *sample != 0));
}

#[test]
fn opus_library_rejects_frames_with_the_wrong_duration() {
    let mut codec = OpusDuplex::new().unwrap();
    assert_eq!(
        codec.encode_20ms_stereo(&[0; 100]).unwrap_err(),
        "GPT-Live Opus input must contain exactly 20 ms of 48 kHz stereo PCM"
    );
}

#[tokio::test]
async fn webrtc_peer_accepts_the_recorders_native_sixteen_kilohertz_frames() {
    let caller = GptLiveWebRtcPeer::new().await.unwrap();
    let callee = GptLiveWebRtcPeer::new().await.unwrap();
    let offer = caller.create_offer(Duration::from_secs(5)).await.unwrap();
    let answer = callee
        .answer_offer(&offer, Duration::from_secs(5))
        .await
        .unwrap();
    caller.apply_answer(&answer).await.unwrap();
    caller
        .wait_connected(Duration::from_secs(10))
        .await
        .unwrap();
    callee
        .wait_connected(Duration::from_secs(10))
        .await
        .unwrap();

    let mut input = vec![0_i16; GPT_LIVE_INPUT_FRAME_SAMPLES_PER_CHANNEL * 2];
    for (index, stereo_sample) in input.chunks_exact_mut(2).enumerate() {
        let sample = (((index % 32) as i16) - 16) * 800;
        stereo_sample[0] = sample;
        stereo_sample[1] = -sample;
    }
    caller.send_20ms_recorder_stereo(&input).await.unwrap();
    let decoded = callee
        .receive_decoded_stereo(Duration::from_secs(5))
        .await
        .unwrap();

    assert_eq!(decoded.len(), OPUS_FRAME_SAMPLES_PER_CHANNEL * 2);
    assert!(decoded.iter().any(|sample| sample.unsigned_abs() > 100));
    assert_eq!(
        caller
            .send_20ms_recorder_stereo(&input[..input.len() - 1])
            .await
            .unwrap_err(),
        "GPT-Live recorder input must contain exactly 20 ms of 16 kHz stereo PCM"
    );
    caller.close().await.unwrap();
    callee.close().await.unwrap();
}

#[tokio::test]
async fn webrtc_library_generates_an_audio_only_sendrecv_opus_offer() {
    let offer = create_audio_offer().await.unwrap();

    assert!(offer.contains("m=audio"));
    assert!(offer.contains("a=rtpmap:111 opus/48000/2"));
    assert!(offer.contains("a=sendrecv"));
    assert!(!offer.contains("m=video"));
    assert!(offer.len() < 256 * 1024);
}

#[tokio::test]
async fn two_library_peers_exchange_and_decode_an_opus_audio_frame() {
    let caller = GptLiveWebRtcPeer::new().await.unwrap();
    let callee = GptLiveWebRtcPeer::new().await.unwrap();
    let offer = caller.create_offer(Duration::from_secs(5)).await.unwrap();
    let answer = callee
        .answer_offer(&offer, Duration::from_secs(5))
        .await
        .unwrap();
    caller.apply_answer(&answer).await.unwrap();

    caller
        .wait_connected(Duration::from_secs(10))
        .await
        .unwrap();
    callee
        .wait_connected(Duration::from_secs(10))
        .await
        .unwrap();

    let mut input = vec![0_i16; OPUS_FRAME_SAMPLES_PER_CHANNEL * 2];
    for (index, stereo_sample) in input.chunks_exact_mut(2).enumerate() {
        let sample = (((index % 64) as i16) - 32) * 500;
        stereo_sample[0] = sample;
        stereo_sample[1] = -sample;
    }
    caller.send_20ms_stereo(&input).await.unwrap();
    let decoded = callee
        .receive_decoded_stereo(Duration::from_secs(5))
        .await
        .unwrap();

    assert_eq!(decoded.len(), OPUS_FRAME_SAMPLES_PER_CHANNEL * 2);
    assert!(decoded.iter().any(|sample| sample.unsigned_abs() > 100));
    caller.close().await.unwrap();
    callee.close().await.unwrap();
}

#[tokio::test]
async fn receiver_works_when_the_answer_omits_ssrc_declarations() {
    let caller = GptLiveWebRtcPeer::new().await.unwrap();
    let callee = GptLiveWebRtcPeer::new().await.unwrap();
    let offer = caller.create_offer(Duration::from_secs(5)).await.unwrap();
    let answer = callee
        .answer_offer(&offer, Duration::from_secs(5))
        .await
        .unwrap();
    assert!(answer.lines().any(|line| line.starts_with("a=ssrc:")));
    let answer_without_ssrc = answer
        .lines()
        .filter(|line| !line.starts_with("a=ssrc:"))
        .collect::<Vec<_>>()
        .join("\r\n")
        + "\r\n";
    caller.apply_answer(&answer_without_ssrc).await.unwrap();

    caller
        .wait_connected(Duration::from_secs(10))
        .await
        .unwrap();
    callee
        .wait_connected(Duration::from_secs(10))
        .await
        .unwrap();

    let frame = vec![2_000_i16; OPUS_FRAME_SAMPLES_PER_CHANNEL * 2];
    callee.send_20ms_stereo(&frame).await.unwrap();
    let decoded = caller
        .receive_decoded_stereo(Duration::from_secs(5))
        .await
        .unwrap();

    assert_eq!(decoded.len(), OPUS_FRAME_SAMPLES_PER_CHANNEL * 2);
    assert!(decoded.iter().any(|sample| sample.unsigned_abs() > 100));
    caller.close().await.unwrap();
    callee.close().await.unwrap();
}
