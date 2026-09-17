use crate::models::{TimedWord, TranscriptTiming};
use serde_json::{json, Value};
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

pub fn words(value: Option<&Value>, milliseconds: bool) -> Vec<TimedWord> {
    let scale = if milliseconds { 1.0 } else { 1000.0 };
    value
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|w| {
            let text = w
                .get("punctuated_word")
                .or_else(|| w.get("word"))
                .or_else(|| w.get("text"))?
                .as_str()?;
            let number = |key: &str| {
                w.get(key)
                    .and_then(|v| v.as_f64().or_else(|| v.as_str()?.parse().ok()))
            };
            let start = number(if milliseconds { "start_time" } else { "start" })? * scale;
            let end = number(if milliseconds { "end_time" } else { "end" })? * scale;
            if text.trim().is_empty()
                || !start.is_finite()
                || !end.is_finite()
                || start < 0.0
                || end < start
            {
                return None;
            }
            Some(TimedWord {
                text: text.to_owned(),
                start_ms: start.round() as i64,
                end_ms: end.round() as i64,
            })
        })
        .collect()
}

pub fn shift(words: &mut [TimedWord], seconds: f64) {
    let offset = (seconds * 1000.0).round() as i64;
    for w in words {
        w.start_ms += offset;
        w.end_ms += offset;
    }
}

pub fn comment(start: f64, end: f64, words: &[TimedWord], origin: f64) -> String {
    let timing = TranscriptTiming {
        start_ms: (start * 1000.0).round() as i64,
        end_ms: (end * 1000.0).round() as i64,
        words: words.to_vec(),
        origin_ms: Some((origin * 1000.0).round() as i64),
    };
    // Prevent recognized text from terminating the invisible Markdown metadata.
    let json = serde_json::to_string(&timing)
        .unwrap_or_default()
        .replace('<', "\\u003c")
        .replace('>', "\\u003e");
    format!("<!-- arco-timing {json} -->\n")
}

pub fn sidecar_path(path: &Path) -> PathBuf {
    PathBuf::from(format!("{}.timing.json", path.display()))
}

pub fn sidecar_line(
    line_index: usize,
    start: f64,
    end: f64,
    words: &[TimedWord],
    origin: f64,
) -> String {
    let timing = TranscriptTiming {
        start_ms: (start * 1000.0).round() as i64,
        end_ms: (end * 1000.0).round() as i64,
        words: words.to_vec(),
        origin_ms: Some((origin * 1000.0).round() as i64),
    };
    let record = json!({"line": line_index, "timing": timing});
    format!("{}\n", serde_json::to_string(&record).unwrap_or_default())
}

pub fn append_line(
    path: &Path,
    line_index: usize,
    start: f64,
    end: f64,
    words: &[TimedWord],
    origin: f64,
) -> io::Result<()> {
    use std::io::Write;

    let line = sidecar_line(line_index, start, end, words, origin);
    let mut file = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)?;
    file.write_all(line.as_bytes())?;
    file.flush()
}

pub fn read_sidecar(path: &Path) -> Vec<Option<TranscriptTiming>> {
    let Ok(raw) = fs::read_to_string(path) else {
        return Vec::new();
    };
    let mut records = Vec::new();
    for line in raw.lines() {
        let Ok(record) = serde_json::from_str::<Value>(line) else {
            records.push(None);
            continue;
        };
        let index = record["line"].as_u64().unwrap_or_default() as usize;
        if usize::try_from(index + 1).is_err() {
            continue;
        }
        let timing = serde_json::from_value::<TranscriptTiming>(record["timing"].clone()).ok();
        if index >= records.len() {
            records.resize(index + 1, None);
        }
        records[index] = timing;
    }
    records
}

pub fn valid(timing: &TranscriptTiming) -> Option<TranscriptTiming> {
    if timing.start_ms < 0 || timing.end_ms < timing.start_ms {
        return None;
    }
    let mut timing = timing.clone();
    timing.words.retain(|word| {
        !word.text.trim().is_empty()
            && word.start_ms >= timing.start_ms
            && word.end_ms >= timing.start_ms
            && word.end_ms <= timing.end_ms
    });
    Some(timing)
}

/// Word alignment is for playback, not part of the meeting's spoken content.
pub fn without_word_metadata(markdown: &str) -> String {
    markdown
        .split_inclusive('\n')
        .filter(|line| !line.trim_start().starts_with("<!-- arco-timing "))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn model_context_preserves_text_and_legacy_metadata() {
        let text = "# Meeting\n[12:00:00] Remote 1: hello\n<!-- arco channel=0 start=1 end=2 -->\n<!-- arco-timing {\"words\":[]} -->\nLast line";
        assert_eq!(without_word_metadata(text), "# Meeting\n[12:00:00] Remote 1: hello\n<!-- arco channel=0 start=1 end=2 -->\nLast line");
    }

    #[test]
    fn provider_units_missing_values_and_reconnect_offsets() {
        let mut words = words(
            Some(&json!([
                {"word":"Hello", "start":0.125, "end":0.5},
                {"word":"bad", "start":2, "end":1},
                {"word":"untimed"}
            ])),
            false,
        );
        assert_eq!(words.len(), 1);
        shift(&mut words, 300.25);
        assert_eq!((words[0].start_ms, words[0].end_ms), (300375, 300750));
        let chinese = super::words(
            Some(&json!([{ "text":"你", "start_time":"125", "end_time":500 }])),
            true,
        );
        assert_eq!(chinese[0].start_ms, 125);
    }

    #[test]
    fn timing_roundtrips_without_injecting_markdown() {
        let word = TimedWord {
            text: "a --> <b>".into(),
            start_ms: 125,
            end_ms: 500,
        };
        let metadata = comment(0.125, 0.5, &[word.clone()], 1000.25);
        assert_eq!(metadata.matches("-->").count(), 1);
        let transcript = format!("**[12:00:00] Remote 1:** a --> <b>\n\n{metadata}");
        let lines = crate::meetings::parse_transcript_lines(&transcript);
        let timing = lines[0].timing.as_ref().unwrap();
        assert_eq!(timing.words, vec![word]);
        assert_eq!(timing.origin_ms, Some(1000250));
    }

    #[test]
    fn sidecar_timing_roundtrips_by_line_index() {
        let root = tempfile::tempdir().unwrap();
        let path = sidecar_path(&root.path().join("transcript.md"));
        append_line(&path, 0, 1.0, 2.0, &[], 1_000.25).unwrap();
        append_line(&path, 1, 3.0, 4.0, &[], 1_000.25).unwrap();
        let records = read_sidecar(&path);
        assert_eq!(records.len(), 2);
        assert_eq!(records[0].as_ref().unwrap().start_ms, 1000);
        assert_eq!(records[1].as_ref().unwrap().start_ms, 3000);
    }

    #[test]
    fn legacy_metadata_and_resumed_capture_use_meeting_clock() {
        let root = tempfile::tempdir().unwrap();
        let file = root.path().join("transcript-20260915-120000.md");
        let origin = chrono::DateTime::parse_from_rfc3339("2026-09-15T12:00:00+08:00")
            .unwrap()
            .timestamp() as f64;
        let start_local = chrono::DateTime::from_timestamp(origin as i64, 0)
            .unwrap()
            .with_timezone(&chrono::Local);
        let body = format!("# Meeting transcript\n\n> Started: {}\n\n**[{}] Remote 1:** legacy\n\n<!-- arco channel=0 start=1.125 end=2.250 -->\n\n**[{}] Remote 1:** resumed\n\n{}", start_local.format("%Y-%m-%d %H:%M:%S"), start_local.format("%H:%M:%S"), start_local.format("%H:%M:%S"), comment(2.0, 3.0, &[TimedWord {text:"resumed".into(),start_ms:2000,end_ms:3000}], origin+600.0));
        std::fs::write(&file, body).unwrap();
        let meeting = crate::meetings::parse_meeting(&file, "local", None).unwrap();
        assert_eq!(meeting.lines[0].timing.as_ref().unwrap().start_ms, 1125);
        assert_eq!(meeting.lines[1].timing.as_ref().unwrap().start_ms, 602000);
        assert_eq!(
            meeting.lines[1].timing.as_ref().unwrap().words[0].start_ms,
            602000
        );
    }
}
