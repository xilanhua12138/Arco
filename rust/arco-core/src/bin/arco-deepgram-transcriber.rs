use std::path::PathBuf;

#[tokio::main]
async fn main() {
    let Some(path) = std::env::args_os().nth(1).map(PathBuf::from) else {
        eprintln!("usage: arco-deepgram-transcriber <transcript-path>");
        std::process::exit(2);
    };
    if let Err(error) = arco_core::deepgram::run_transcriber(&path).await {
        eprintln!("transcriber failed: {error}");
        std::process::exit(1);
    }
}
