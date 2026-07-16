use crate::agent::AgentRunner;
use crate::meeting_state::MeetingStateStore;
use crate::meetings::MeetingStore;
use crate::models::{GeneratedMeetingArtifact, MeetingDetail, MeetingSummary};
use std::path::Path;
use std::sync::Mutex;

const OUTPUT_CONTEXT_SCOPE: &str = "meeting-output";
const MAX_PROMPT_CHARS: usize = 8_000;
const MAX_TITLE_CHARS: usize = 80;

#[allow(clippy::too_many_arguments)]
pub fn generate_meeting_output_once(
    output_run_lock: &Mutex<()>,
    runner: &AgentRunner,
    meetings: &MeetingStore,
    meeting_state: &MeetingStateStore,
    provider: &str,
    meeting_id: &str,
    kind: &str,
    prompt: &str,
    active_path: Option<&Path>,
) -> Result<GeneratedMeetingArtifact, String> {
    validate_provider(provider)?;
    validate_kind(kind)?;
    let prompt = prompt.trim();
    if prompt.is_empty() {
        return Err("meeting output prompt cannot be empty".into());
    }
    if prompt.chars().count() > MAX_PROMPT_CHARS {
        return Err(format!(
            "meeting output prompt is too long (maximum {MAX_PROMPT_CHARS} characters)"
        ));
    }

    let _guard = output_run_lock
        .lock()
        .map_err(|_| "meeting output coordinator is unavailable".to_string())?;
    let meeting = meetings.read(meeting_id, active_path)?;
    let artifacts = meeting_state.meeting_artifacts(meeting_id)?;
    if let Some(existing) = match kind {
        "title" => artifacts.title,
        "summary" => artifacts.summary,
        _ => unreachable!("kind was validated before acquiring the output lock"),
    } {
        return Ok(existing);
    }

    let canonical_cwd = runner.working_directory(OUTPUT_CONTEXT_SCOPE, None)?;
    let binding = meeting_state.session_binding(
        meeting_id,
        provider,
        OUTPUT_CONTEXT_SCOPE,
        &canonical_cwd,
    )?;
    let expected_session_id = binding.as_ref().map(|binding| binding.session_id.as_str());
    let output = match runner.run_session(
        provider,
        prompt,
        &meeting,
        OUTPUT_CONTEXT_SCOPE,
        None,
        expected_session_id,
    ) {
        Ok(output) => output,
        Err(error) => {
            return meeting_state.commit_failed_meeting_artifact(meeting_id, kind, provider, &error)
        }
    };
    let value = match sanitize_output(kind, &output.reply.answer) {
        Ok(value) => value,
        Err(error) => {
            return meeting_state.commit_failed_meeting_artifact_with_output(
                meeting_id,
                kind,
                OUTPUT_CONTEXT_SCOPE,
                &canonical_cwd,
                &output,
                &error,
                expected_session_id,
            )
        }
    };
    meeting_state.commit_meeting_artifact(
        meeting_id,
        kind,
        OUTPUT_CONTEXT_SCOPE,
        &canonical_cwd,
        &output,
        &value,
        expected_session_id,
    )
}

pub fn read_meeting_with_artifacts(
    meetings: &MeetingStore,
    meeting_state: &MeetingStateStore,
    meeting_id: &str,
    active_path: Option<&Path>,
) -> Result<MeetingDetail, String> {
    let mut detail = meetings.read(meeting_id, active_path)?;
    meeting_state.hydrate_meeting_summary(&mut detail.summary)?;
    Ok(detail)
}

pub fn list_meetings_with_artifacts(
    meetings: &MeetingStore,
    meeting_state: &MeetingStateStore,
    query: Option<&str>,
    active_path: Option<&Path>,
) -> Result<Vec<MeetingSummary>, String> {
    let normalized_query = query
        .map(str::trim)
        .filter(|query| !query.is_empty())
        .map(str::to_lowercase);
    let mut summaries = meetings.list(None, active_path)?;
    for summary in &mut summaries {
        if let Err(error) = meeting_state.hydrate_meeting_summary(summary) {
            log::warn!(
                "Arco could not read generated output for {}; preserving the transcript with idle output state: {error}",
                summary.id
            );
            summary.generated_summary = None;
            summary.title_generation_status = "idle".into();
            summary.summary_generation_status = "idle".into();
        }
    }
    if let Some(query) = normalized_query.as_deref() {
        summaries.retain(|summary| {
            let generated = format!(
                "{}\n{}\n{}",
                summary.title.as_deref().unwrap_or_default(),
                summary.generated_summary.as_deref().unwrap_or_default(),
                summary.preview
            )
            .to_lowercase();
            if generated.contains(query) {
                return true;
            }
            meetings
                .read(&summary.id, active_path)
                .map(|detail| detail.raw_markdown.to_lowercase().contains(query))
                .unwrap_or(false)
        });
    }
    Ok(summaries)
}

fn sanitize_output(kind: &str, answer: &str) -> Result<String, String> {
    match kind {
        "title" => sanitize_title(answer),
        "summary" => {
            let summary = answer.trim();
            if summary.is_empty() {
                Err("generated meeting summary was empty".into())
            } else {
                Ok(summary.to_string())
            }
        }
        _ => Err(format!(
            "unsupported meeting output kind: {kind}; expected title or summary"
        )),
    }
}

fn sanitize_title(answer: &str) -> Result<String, String> {
    let first_line = answer
        .lines()
        .map(str::trim)
        .find(|line| !line.is_empty() && !line.starts_with("```"))
        .unwrap_or_default();
    let without_heading = first_line.trim_start_matches(|character: char| {
        character.is_whitespace() || matches!(character, '#' | '>' | '-' | '+')
    });
    let without_decoration = without_heading
        .trim_matches(|character: char| matches!(character, '*' | '_' | '`'))
        .trim();
    let without_quotes = without_decoration
        .trim_matches(|character: char| matches!(character, '"' | '\'' | '“' | '”' | '‘' | '’'))
        .trim_matches(|character: char| matches!(character, '*' | '_' | '`'))
        .trim();
    let collapsed = without_quotes
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");
    if collapsed.is_empty() {
        return Err("generated meeting title was empty after cleaning".into());
    }
    Ok(collapsed.chars().take(MAX_TITLE_CHARS).collect())
}

fn validate_kind(kind: &str) -> Result<(), String> {
    if matches!(kind, "title" | "summary") {
        Ok(())
    } else {
        Err(format!(
            "unsupported meeting output kind: {kind}; expected title or summary"
        ))
    }
}

fn validate_provider(provider: &str) -> Result<(), String> {
    if matches!(provider, "codex" | "claude") {
        Ok(())
    } else {
        Err(format!(
            "unsupported agent provider: {provider}; expected codex or claude"
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::{sanitize_output, MAX_TITLE_CHARS};

    #[test]
    fn title_cleaning_is_single_line_unquoted_and_bounded() {
        let cleaned = sanitize_output(
            "title",
            "\n### **\"Roadmap review\"**\nThis line must not enter the title",
        )
        .unwrap();
        assert_eq!(cleaned, "Roadmap review");

        let long = sanitize_output("title", &"界".repeat(MAX_TITLE_CHARS + 20)).unwrap();
        assert_eq!(long.chars().count(), MAX_TITLE_CHARS);
    }

    #[test]
    fn empty_cleaned_title_and_summary_are_rejected_precisely() {
        assert_eq!(
            sanitize_output("title", "### **\"\"**").unwrap_err(),
            "generated meeting title was empty after cleaning"
        );
        assert_eq!(
            sanitize_output("summary", " \n\t ").unwrap_err(),
            "generated meeting summary was empty"
        );
    }
}
