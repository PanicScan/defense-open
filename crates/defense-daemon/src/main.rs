use std::env;
use std::path::PathBuf;

use anyhow::Result;
use defense_daemon::ipc_types::DaemonCommand;
use defense_daemon::service::DaemonService;

fn main() -> Result<()> {
    let event_log_path = env::var_os("DEFENSE_DAEMON_EVENT_LOG")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("target/defense-daemon/events.jsonl"));
    let service = DaemonService::new(event_log_path);
    let response = service.handle(DaemonCommand::Status)?;

    println!("{}", serde_json::to_string_pretty(&response)?);
    Ok(())
}
