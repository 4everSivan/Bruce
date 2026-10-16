#![deny(unsafe_code)]

use collector_bridge::{read_request, run_bytes_panic_safe};
use std::io::{self, Write};

fn main() -> io::Result<()> {
    let input = read_request(io::stdin().lock())?;
    // C043: 采集链路内任何未预期 panic 都必须仍产出 JSON envelope,
    // 调用方 (macOS/Windows 宿主) 才能把失败原因呈现给用户。
    let response = run_bytes_panic_safe(&input);
    let stdout = io::stdout();
    let mut handle = stdout.lock();
    serde_json::to_writer(&mut handle, &response)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
    handle.write_all(b"\n")?;
    handle.flush()
}
