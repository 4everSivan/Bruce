#![deny(unsafe_code)]

use collector_bridge::{read_request, run_bytes_panic_safe};
use std::io::{self, Read, Write};

fn main() -> io::Result<()> {
    // T14: `Bruce-collector policy` 为额度策略入口 (policy-request-v1 → policy-response-v1),
    // 只做纯计算, 不扫描、不出站、不接收凭据; 无参数时为采集 Bridge (request-v1)。
    if std::env::args_os()
        .nth(1)
        .is_some_and(|arg| arg == "policy")
    {
        let mut input = Vec::new();
        io::stdin()
            .lock()
            .take((collector_policy::MAX_POLICY_REQUEST_BYTES + 1) as u64)
            .read_to_end(&mut input)?;
        return write_json(&collector_policy::handle_request(&input));
    }
    let input = read_request(io::stdin().lock())?;
    // C043: 采集链路内任何未预期 panic 都必须仍产出 JSON envelope,
    // 调用方 (macOS/Windows 宿主) 才能把失败原因呈现给用户。
    write_json(&run_bytes_panic_safe(&input))
}

fn write_json<T: serde::Serialize>(value: &T) -> io::Result<()> {
    let stdout = io::stdout();
    let mut handle = stdout.lock();
    serde_json::to_writer(&mut handle, value)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
    handle.write_all(b"\n")?;
    handle.flush()
}
