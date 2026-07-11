use arco_lib::agent::AgentRunner;

fn main() {
    let result = AgentRunner::default().test_provider("codex");
    println!("{}", result.message);
    if !result.ok {
        std::process::exit(1);
    }
}
