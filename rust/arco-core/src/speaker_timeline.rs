use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs::{self, File};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::Duration;

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SpeakerInterval {
    pub speaker: i64,
    pub start: f64,
    pub end: f64,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ChannelTimeline {
    pub processed_until: f64,
    pub finalized: Vec<SpeakerInterval>,
    pub tentative: Vec<SpeakerInterval>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SpeakerTimeline {
    pub version: u8,
    pub channels: [ChannelTimeline; 2],
}

impl Default for SpeakerTimeline {
    fn default() -> Self {
        Self {
            version: 1,
            channels: [ChannelTimeline::default(), ChannelTimeline::default()],
        }
    }
}

impl SpeakerTimeline {
    pub fn update(
        &mut self,
        channel: usize,
        processed_until: f64,
        finalized: Vec<SpeakerInterval>,
        tentative: Vec<SpeakerInterval>,
    ) {
        let Some(target) = self.channels.get_mut(channel) else {
            return;
        };
        if processed_until.is_finite() {
            target.processed_until = target.processed_until.max(processed_until.max(0.0));
        }
        for interval in finalized.into_iter().filter(valid_interval) {
            if !target.finalized.contains(&interval) {
                target.finalized.push(interval);
            }
        }
        target.finalized.sort_by(interval_order);
        target.finalized = compact(std::mem::take(&mut target.finalized));
        let mut next_tentative: Vec<_> = tentative.into_iter().filter(valid_interval).collect();
        next_tentative.sort_by(interval_order);
        target.tentative = compact(next_tentative);
    }

    pub fn dominant_speaker(&self, channel: usize, start: f64, end: f64) -> Option<i64> {
        if !start.is_finite() || !end.is_finite() || end <= start {
            return None;
        }
        let timeline = self.channels.get(channel)?;
        let mut overlaps = HashMap::<i64, f64>::new();
        for interval in timeline.finalized.iter().chain(&timeline.tentative) {
            let overlap = (end.min(interval.end) - start.max(interval.start)).max(0.0);
            if overlap > 0.0 {
                *overlaps.entry(interval.speaker).or_default() += overlap;
            }
        }
        overlaps
            .into_iter()
            .max_by(
                |(left_speaker, left_overlap), (right_speaker, right_overlap)| {
                    left_overlap
                        .total_cmp(right_overlap)
                        .then_with(|| right_speaker.cmp(left_speaker))
                },
            )
            .map(|(speaker, _)| speaker)
    }
}

fn valid_interval(interval: &SpeakerInterval) -> bool {
    interval.start.is_finite()
        && interval.end.is_finite()
        && interval.start >= 0.0
        && interval.end > interval.start
}

fn interval_order(left: &SpeakerInterval, right: &SpeakerInterval) -> std::cmp::Ordering {
    left.start
        .total_cmp(&right.start)
        .then_with(|| left.end.total_cmp(&right.end))
        .then_with(|| left.speaker.cmp(&right.speaker))
}

fn compact(intervals: Vec<SpeakerInterval>) -> Vec<SpeakerInterval> {
    let mut result: Vec<SpeakerInterval> = Vec::with_capacity(intervals.len());
    for interval in intervals {
        if let Some(previous) = result.last_mut() {
            if previous.speaker == interval.speaker && interval.start <= previous.end + 0.02 {
                previous.end = previous.end.max(interval.end);
                continue;
            }
        }
        result.push(interval);
    }
    result
}

pub struct SpeakerTimelineStore {
    path: PathBuf,
    timeline: SpeakerTimeline,
}

impl SpeakerTimelineStore {
    pub fn new(path: PathBuf) -> Self {
        Self {
            path,
            timeline: SpeakerTimeline::default(),
        }
    }

    pub fn update(
        &mut self,
        channel: usize,
        processed_until: f64,
        finalized: Vec<SpeakerInterval>,
        tentative: Vec<SpeakerInterval>,
    ) -> Result<(), String> {
        self.timeline
            .update(channel, processed_until, finalized, tentative);
        self.flush()
    }

    fn flush(&self) -> Result<(), String> {
        let parent = self
            .path
            .parent()
            .ok_or_else(|| "speaker timeline path has no parent".to_string())?;
        fs::create_dir_all(parent)
            .map_err(|error| format!("could not create speaker timeline directory: {error}"))?;
        let temporary = self
            .path
            .with_extension(format!("{}.tmp", std::process::id()));
        let result = (|| {
            let payload = serde_json::to_vec(&self.timeline)
                .map_err(|error| format!("could not encode speaker timeline: {error}"))?;
            let mut file = File::create(&temporary)
                .map_err(|error| format!("could not create speaker timeline snapshot: {error}"))?;
            file.write_all(&payload)
                .and_then(|_| file.sync_all())
                .map_err(|error| format!("could not persist speaker timeline snapshot: {error}"))?;
            fs::rename(&temporary, &self.path)
                .map_err(|error| format!("could not publish speaker timeline snapshot: {error}"))
        })();
        if result.is_err() {
            let _ = fs::remove_file(&temporary);
        }
        result
    }
}

pub fn read_timeline(path: &Path) -> Result<SpeakerTimeline, String> {
    let payload = fs::read(path).map_err(|error| {
        format!(
            "could not read speaker timeline {}: {error}",
            path.display()
        )
    })?;
    let timeline: SpeakerTimeline = serde_json::from_slice(&payload)
        .map_err(|error| format!("invalid speaker timeline {}: {error}", path.display()))?;
    if timeline.version != 1 {
        return Err(format!(
            "unsupported speaker timeline version: {}",
            timeline.version
        ));
    }
    Ok(timeline)
}

pub async fn wait_for_speaker(
    path: &Path,
    channel: usize,
    start: f64,
    end: f64,
    max_wait: Duration,
) -> Option<i64> {
    let deadline = tokio::time::Instant::now() + max_wait;
    loop {
        if let Ok(timeline) = read_timeline(path) {
            let covered = timeline
                .channels
                .get(channel)
                .map(|timeline| timeline.processed_until + 0.001 >= end)
                .unwrap_or(false);
            if covered || tokio::time::Instant::now() >= deadline {
                return timeline.dominant_speaker(channel, start, end);
            }
        } else if tokio::time::Instant::now() >= deadline {
            return None;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn interval(speaker: i64, start: f64, end: f64) -> SpeakerInterval {
        SpeakerInterval {
            speaker,
            start,
            end,
        }
    }

    #[test]
    fn streaming_updates_append_final_history_and_replace_the_tentative_edge() {
        let mut timeline = SpeakerTimeline::default();
        timeline.update(0, 1.0, vec![], vec![interval(0, 0.0, 1.0)]);
        timeline.update(
            0,
            2.0,
            vec![interval(0, 0.0, 0.8)],
            vec![interval(1, 0.8, 2.0)],
        );

        assert_eq!(timeline.channels[0].processed_until, 2.0);
        assert_eq!(timeline.channels[0].finalized, vec![interval(0, 0.0, 0.8)]);
        assert_eq!(timeline.channels[0].tentative, vec![interval(1, 0.8, 2.0)]);
        assert!(timeline.channels[1].finalized.is_empty());
    }

    #[test]
    fn dominant_speaker_uses_temporal_overlap_and_keeps_channels_isolated() {
        let mut timeline = SpeakerTimeline::default();
        timeline.update(
            1,
            4.0,
            vec![interval(2, 0.0, 1.0), interval(4, 1.0, 4.0)],
            vec![],
        );

        assert_eq!(timeline.dominant_speaker(1, 0.5, 2.0), Some(4));
        assert_eq!(timeline.dominant_speaker(0, 0.5, 2.0), None);
        assert_eq!(timeline.dominant_speaker(1, 2.0, 2.0), None);
    }

    #[tokio::test]
    async fn snapshots_are_atomic_and_waiting_times_out_without_coverage() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("speaker-timeline.json");
        let mut store = SpeakerTimelineStore::new(path.clone());
        store
            .update(0, 1.0, vec![interval(3, 0.0, 1.0)], vec![])
            .unwrap();

        assert_eq!(
            read_timeline(&path).unwrap().dominant_speaker(0, 0.1, 0.9),
            Some(3)
        );
        assert_eq!(
            wait_for_speaker(&path, 0, 1.2, 1.5, Duration::from_millis(30)).await,
            None
        );
        assert!(root.path().read_dir().unwrap().all(|entry| {
            !entry
                .unwrap()
                .file_name()
                .to_string_lossy()
                .contains(".tmp")
        }));
    }

    #[test]
    fn malformed_or_wrong_version_snapshots_are_rejected() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("speaker-timeline.json");
        let wrong_version = SpeakerTimeline {
            version: 2,
            ..SpeakerTimeline::default()
        };
        std::fs::write(&path, serde_json::to_vec(&wrong_version).unwrap()).unwrap();
        assert!(read_timeline(&path).unwrap_err().contains("version"));

        std::fs::write(&path, b"not json").unwrap();
        assert!(read_timeline(&path).is_err());
    }
}
