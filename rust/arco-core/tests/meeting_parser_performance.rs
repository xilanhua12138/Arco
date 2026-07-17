#[test]
fn meeting_parser_reuses_compiled_regular_expressions() {
    let source = include_str!("../src/meetings.rs");
    let cached_regex_count = source.matches("OnceLock<Regex>").count();
    let cached_initialization_count = source.matches("get_or_init").count();

    assert!(
        cached_regex_count >= 2,
        "transcript-line and Started-at regexes must each be cached in a OnceLock"
    );
    assert!(
        cached_initialization_count >= 2,
        "meeting parsing must retrieve both compiled regexes through OnceLock::get_or_init"
    );
}
