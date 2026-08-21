#![deny(unsafe_code)]

use collector_bridge::{read_request, run_bytes};
use std::io::{self, Write};

fn main() -> io::Result<()> {
    let input = read_request(io::stdin().lock())?;
    let response = run_bytes(&input);
    let stdout = io::stdout();
    let mut handle = stdout.lock();
    serde_json::to_writer(&mut handle, &response)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
    handle.write_all(b"\n")?;
    handle.flush()
}
