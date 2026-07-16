use crate::models::{MeetingDetail, MeetingSummary, TranscriptLine};
use crate::storage::MeetingRoot;
use chrono::{DateTime, Local, LocalResult, NaiveDateTime, NaiveTime, TimeZone};
use regex::Regex;
use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Arc, RwLock};

const MAX_TRANSCRIPT_BYTES: u64 = 8 * 1024 * 1024;

#[derive(Clone, Debug)]
pub struct MeetingStore {
    roots: Arc<RwLock<Vec<MeetingRoot>>>,
    legacy_dir: PathBuf,
}

impl MeetingStore {
    pub fn new(local_dir: PathBuf, legacy_dir: PathBuf) -> Self {
        Self {
            roots: Arc::new(RwLock::new(vec![MeetingRoot {
                source: "local".into(),
                path: local_dir,
            }])),
            legacy_dir,
        }
    }

    pub fn set_roots(&self, roots: Vec<MeetingRoot>) -> Result<(), String> {
        if roots.is_empty() || roots.iter().all(|root| root.source != "local") {
            return Err("meeting storage roots must include the default folder".into());
        }
        let mut current = self
            .roots
            .write()
            .map_err(|_| "meeting storage roots are unavailable".to_string())?;
        *current = roots;
        Ok(())
    }

    pub fn local_dir(&self) -> PathBuf {
        self.roots
            .read()
            .unwrap_or_else(|lock| lock.into_inner())
            .iter()
            .find(|root| root.source == "local")
            .map(|root| root.path.clone())
            .unwrap_or_default()
    }

    pub fn list(
        &self,
        query: Option<&str>,
        active_path: Option<&Path>,
    ) -> Result<Vec<MeetingSummary>, String> {
        let normalized_query = query
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(str::to_lowercase);
        let mut results = Vec::new();
        let mut seen_paths = HashSet::new();

        let mut roots = self
            .roots
            .read()
            .map_err(|_| "meeting storage roots are unavailable".to_string())?
            .clone();
        roots.push(MeetingRoot {
            source: "legacy".into(),
            path: self.legacy_dir.clone(),
        });
        for root in roots {
            let source = root.source.as_str();
            let dir = root.path;
            if !dir.exists() {
                continue;
            }
            let entries = fs::read_dir(&dir)
                .map_err(|error| format!("could not read {}: {error}", dir.display()))?;
            for entry in entries {
                let entry = match entry {
                    Ok(entry) => entry,
                    Err(_) => continue,
                };
                let path = entry.path();
                if !is_transcript_file(&path) {
                    continue;
                }
                let canonical = path.canonicalize().unwrap_or_else(|_| path.clone());
                if !seen_paths.insert(canonical) {
                    continue;
                }
                let detail = match parse_meeting(&path, source, active_path) {
                    Ok(detail) => detail,
                    // One damaged historical file should never hide every other meeting.
                    Err(_) => continue,
                };
                // Failed/abandoned test captures otherwise dominate history.
                // Keep the active session even before its first final result.
                if detail.lines.is_empty() && !detail.summary.is_live {
                    continue;
                }
                if let Some(query) = normalized_query.as_deref() {
                    let searchable = format!(
                        "{}\n{}\n{}",
                        detail.summary.title.as_deref().unwrap_or_default(),
                        detail.summary.preview,
                        detail.raw_markdown
                    )
                    .to_lowercase();
                    if !searchable.contains(query) {
                        continue;
                    }
                }
                results.push(detail.summary);
            }
        }

        results.sort_by(|left, right| {
            right
                .started_at
                .cmp(&left.started_at)
                .then_with(|| right.id.cmp(&left.id))
        });
        Ok(results)
    }

    pub fn read(&self, id: &str, active_path: Option<&Path>) -> Result<MeetingDetail, String> {
        let (source, file_name) = id
            .split_once(':')
            .ok_or_else(|| "invalid meeting id".to_string())?;
        let dir = if source == "legacy" {
            self.legacy_dir.clone()
        } else {
            self.roots
                .read()
                .map_err(|_| "meeting storage roots are unavailable".to_string())?
                .iter()
                .find(|root| root.source == source)
                .map(|root| root.path.clone())
                .ok_or_else(|| "invalid meeting source".to_string())?
        };

        // IDs are lookup keys, never paths. This check prevents traversal even
        // before the directory scan below performs an exact filename match.
        if file_name.is_empty()
            || file_name.contains('/')
            || file_name.contains('\\')
            || file_name == "."
            || file_name == ".."
        {
            return Err("invalid meeting id".into());
        }

        let entries = fs::read_dir(&dir).map_err(|error| {
            if error.kind() == std::io::ErrorKind::NotFound {
                format!("meeting not found: {id}")
            } else {
                format!("could not read {}: {error}", dir.display())
            }
        })?;
        for entry in entries.flatten() {
            let path = entry.path();
            if is_transcript_file(&path)
                && path.file_name().and_then(|name| name.to_str()) == Some(file_name)
            {
                return parse_meeting(&path, source, active_path);
            }
        }
        Err(format!("meeting not found: {id}"))
    }
}

pub fn meeting_id(source: &str, path: &Path) -> Result<String, String> {
    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| format!("invalid transcript filename: {}", path.display()))?;
    Ok(format!("{source}:{file_name}"))
}

pub fn parse_meeting(
    path: &Path,
    source: &str,
    active_path: Option<&Path>,
) -> Result<MeetingDetail, String> {
    let raw_markdown = read_transcript(path)?;
    let lines = parse_transcript_lines(&raw_markdown);
    let started = parse_started_at(&raw_markdown)
        .or_else(|| parse_started_from_filename(path))
        .or_else(|| modified_at(path))
        .unwrap_or_else(Local::now);
    let started_at = started.to_rfc3339();
    let title = parse_title(&raw_markdown);
    let preview = transcript_preview(&raw_markdown, &lines);
    let active = active_path
        .map(|active| paths_refer_to_same_file(active, path))
        .unwrap_or(false);
    let summary = MeetingSummary {
        id: meeting_id(source, path)?,
        title,
        generated_summary: None,
        title_generation_status: "idle".into(),
        summary_generation_status: "idle".into(),
        started_at,
        duration_label: duration_label(&lines),
        preview,
        path: path.to_string_lossy().into_owned(),
        utterance_count: lines.len(),
        is_live: active,
        source: if source == "legacy" { "legacy" } else { "arco" }.to_string(),
    };
    Ok(MeetingDetail {
        summary,
        lines,
        raw_markdown,
    })
}

pub fn parse_transcript_lines(markdown: &str) -> Vec<TranscriptLine> {
    let pattern = Regex::new(
        r"^\s*\*\*\[(?P<timestamp>\d{2}:\d{2}:\d{2})\]\s*(?P<speaker>[^:*]+?):\*\*\s*(?P<text>.*)\s*$",
    )
    .expect("transcript regex is valid");
    markdown
        .lines()
        .filter_map(|line| pattern.captures(line))
        .enumerate()
        .map(|(sequence, captures)| TranscriptLine {
            id: format!("line-{}", sequence + 1),
            timestamp: captures["timestamp"].to_string(),
            speaker: captures["speaker"].trim().to_string(),
            text: captures["text"].trim().to_string(),
            sequence,
        })
        .collect()
}

fn is_transcript_file(path: &Path) -> bool {
    if path.extension().and_then(|value| value.to_str()) != Some("md") {
        return false;
    }
    let Some(name) = path.file_name().and_then(|value| value.to_str()) else {
        return false;
    };
    name.starts_with("transcript-") || name.starts_with("meeting-")
}

fn read_transcript(path: &Path) -> Result<String, String> {
    let metadata = fs::metadata(path)
        .map_err(|error| format!("could not inspect {}: {error}", path.display()))?;
    if metadata.len() > MAX_TRANSCRIPT_BYTES {
        return Err(format!(
            "transcript is too large ({} bytes, maximum {})",
            metadata.len(),
            MAX_TRANSCRIPT_BYTES
        ));
    }
    let bytes =
        fs::read(path).map_err(|error| format!("could not read {}: {error}", path.display()))?;
    Ok(String::from_utf8_lossy(&bytes).into_owned())
}

fn parse_title(markdown: &str) -> Option<String> {
    markdown.lines().find_map(|line| {
        let value = line.trim().strip_prefix("# ")?.trim();
        if value.is_empty() || value.eq_ignore_ascii_case("meeting transcript") {
            None
        } else {
            Some(value.to_string())
        }
    })
}

fn parse_started_at(markdown: &str) -> Option<DateTime<Local>> {
    let regex =
        Regex::new(r"(?m)^>\s*Started:\s*(?P<date>\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2})").ok()?;
    let raw = regex.captures(markdown)?.name("date")?.as_str();
    let naive = NaiveDateTime::parse_from_str(raw, "%Y-%m-%d %H:%M:%S").ok()?;
    localize(naive)
}

fn parse_started_from_filename(path: &Path) -> Option<DateTime<Local>> {
    let stem = path.file_stem()?.to_str()?;
    let raw = stem
        .strip_prefix("transcript-")
        .or_else(|| stem.strip_prefix("meeting-"))?;
    for format in ["%Y%m%d-%H%M%S", "%Y-%m-%d-%H%M%S"] {
        if let Ok(naive) = NaiveDateTime::parse_from_str(raw, format) {
            return localize(naive);
        }
    }
    None
}

fn localize(naive: NaiveDateTime) -> Option<DateTime<Local>> {
    match Local.from_local_datetime(&naive) {
        LocalResult::Single(value) => Some(value),
        LocalResult::Ambiguous(first, _) => Some(first),
        LocalResult::None => None,
    }
}

fn modified_at(path: &Path) -> Option<DateTime<Local>> {
    fs::metadata(path)
        .ok()?
        .modified()
        .ok()
        .map(DateTime::<Local>::from)
}

fn transcript_preview(raw: &str, lines: &[TranscriptLine]) -> String {
    if !lines.is_empty() {
        let joined = lines
            .iter()
            .take(3)
            .map(|line| line.text.as_str())
            .collect::<Vec<_>>()
            .join(" ");
        return truncate_chars(joined.trim(), 180);
    }
    let fallback = raw.lines().find_map(|line| {
        let line = line.trim();
        if line.is_empty()
            || line.starts_with('#')
            || line.starts_with("> Started:")
            || line.starts_with("> Ended:")
        {
            None
        } else {
            Some(line.trim_matches('*').trim())
        }
    });
    fallback
        .map(|value| truncate_chars(value, 180))
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| "No transcript yet".into())
}

fn truncate_chars(value: &str, maximum: usize) -> String {
    if value.chars().count() <= maximum {
        return value.to_string();
    }
    let mut result = value
        .chars()
        .take(maximum.saturating_sub(1))
        .collect::<String>();
    result.push('…');
    result
}

fn duration_label(lines: &[TranscriptLine]) -> String {
    let Some(first) = lines.first().and_then(|line| parse_time(&line.timestamp)) else {
        return "0m".into();
    };
    let Some(last) = lines.last().and_then(|line| parse_time(&line.timestamp)) else {
        return "0m".into();
    };
    let start = first.num_seconds_from_midnight() as i64;
    let mut end = last.num_seconds_from_midnight() as i64;
    if end < start {
        end += 24 * 60 * 60;
    }
    let total_minutes = (end - start) / 60;
    if total_minutes < 60 {
        format!("{total_minutes}m")
    } else {
        format!("{}h {:02}m", total_minutes / 60, total_minutes % 60)
    }
}

fn parse_time(value: &str) -> Option<NaiveTime> {
    NaiveTime::parse_from_str(value, "%H:%M:%S").ok()
}

fn paths_refer_to_same_file(left: &Path, right: &Path) -> bool {
    let left = left.canonicalize().unwrap_or_else(|_| left.to_path_buf());
    let right = right.canonicalize().unwrap_or_else(|_| right.to_path_buf());
    left == right
}

use chrono::Timelike;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parser_preserves_identical_repeated_utterances() {
        let markdown = "**[10:00:00] Speaker 1:** exactly the same\n\n\
                        **[10:00:02] Speaker 1:** exactly the same\n";
        let lines = parse_transcript_lines(markdown);

        assert_eq!(lines.len(), 2);
        assert_eq!(lines[0].text, "exactly the same");
        assert_eq!(lines[1].text, "exactly the same");
        assert_eq!(lines[0].sequence, 0);
        assert_eq!(lines[1].sequence, 1);
        assert_ne!(lines[0].id, lines[1].id);
    }

    #[test]
    fn parser_ignores_malformed_lines_without_inventing_utterances() {
        let markdown = "# Meeting Transcript\n\n[broken Speaker 1] no delimiter\n\n\
                        **[25:99:99] Speaker 2:** syntactically shaped\n";
        let lines = parse_transcript_lines(markdown);

        // Timestamp validation is intentionally deferred to duration display;
        // the exact textual record remains visible instead of being discarded.
        assert_eq!(lines.len(), 1);
        assert_eq!(lines[0].timestamp, "25:99:99");
        assert_eq!(lines[0].speaker, "Speaker 2");
        assert_eq!(lines[0].text, "syntactically shaped");
    }

    #[test]
    fn duration_handles_midnight_rollover() {
        let lines = parse_transcript_lines(
            "**[23:59:30] Speaker 1:** before\n**[00:01:30] Speaker 2:** after",
        );
        assert_eq!(duration_label(&lines), "2m");
    }
}
