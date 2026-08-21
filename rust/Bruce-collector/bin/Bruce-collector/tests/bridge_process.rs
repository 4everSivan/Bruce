use std::io::Write;
use std::process::{Command, Stdio};

const REQUEST: &[u8] = br#"{"schemaVersion":1,"runId":"12345678-1234-4234-9234-123456789abc","module":"agent-usage","timeouts":{"localScanSeconds":30,"externalRequestSeconds":10,"moduleSeconds":90},"context":{"capabilities":["localSessions"]},"credentials":{}}"#;

#[test]
fn process_emits_one_json_envelope_without_stderr_logs() {
    let mut child = Command::new(env!("CARGO_BIN_EXE_Bruce-collector"))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(REQUEST).unwrap();
    let output = child.wait_with_output().unwrap();
    assert!(output.status.success());
    assert_eq!(
        output.stdout.iter().filter(|byte| **byte == b'\n').count(),
        1
    );
    assert!(
        output.stderr.is_empty(),
        "unexpected stderr: {:?}",
        output.stderr
    );
    let response: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(response["runId"], "12345678-1234-4234-9234-123456789abc");
}

#[test]
fn process_can_be_terminated_while_waiting_for_input() {
    let mut child = Command::new(env!("CARGO_BIN_EXE_Bruce-collector"))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child.kill().unwrap();
    let _ = child.wait().unwrap();
}
