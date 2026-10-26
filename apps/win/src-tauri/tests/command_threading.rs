//! C109: 含出站 HTTP 的 Tauri command 不得以同步 `fn` 声明。
//!
//! Tauri 2 的同步 command 在主线程执行, 期间托盘、看板与设置窗口全部失去响应;
//! 网络调用必须在 `async fn` command 内经 `off_main_thread` 放到阻塞线程池。
//! 本用例逐个解析 `src/lib.rs` 中的 `#[tauri::command]` 函数体, 同步 command 一旦
//! 直接调用下列网络入口即失败 (能在回退为同步 fn 时变红)。

const LIB: &str = include_str!("../src/lib.rs");

/// 会发起阻塞 HTTP 的入口 (credentials 设备码 / 订阅试查 / 采集链路) 与 ureq 直用。
const NETWORK_ENTRY_POINTS: &[&str] = &[
    "credentials::codex_device_start",
    "codex_device_poll_once",
    "codex_device_exchange",
    "codex_device_poll_blocking",
    "verify_subscription_following_local",
    "credentials::verify_subscription(",
    "collect_with_recovery",
    "run_configured_collection",
    "run_scoped_collection",
    "ureq::",
];

/// 从 `start` 处的 `{` 起按括号配对截取函数体; 跳过字符串字面量与行注释中的括号。
fn function_body(source: &str, start: usize) -> &str {
    let bytes = source.as_bytes();
    let mut depth = 0usize;
    let mut index = start;
    let mut in_string = false;
    while index < bytes.len() {
        let byte = bytes[index];
        if in_string {
            match byte {
                b'\\' => index += 1,
                b'"' => in_string = false,
                _ => {}
            }
        } else if byte == b'/' && bytes.get(index + 1) == Some(&b'/') {
            while index < bytes.len() && bytes[index] != b'\n' {
                index += 1;
            }
        } else {
            match byte {
                b'"' => in_string = true,
                b'{' => depth += 1,
                b'}' => {
                    depth -= 1;
                    if depth == 0 {
                        return &source[start..=index];
                    }
                }
                _ => {}
            }
        }
        index += 1;
    }
    &source[start..]
}

struct Command<'a> {
    name: &'a str,
    is_async: bool,
    body: &'a str,
}

fn commands() -> Vec<Command<'static>> {
    let mut found = Vec::new();
    let mut cursor = 0;
    while let Some(offset) = LIB[cursor..].find("#[tauri::command]") {
        let attribute_end = cursor + offset + "#[tauri::command]".len();
        let signature_start =
            attribute_end + LIB[attribute_end..].find("fn ").expect("command 后应有 fn");
        let prefix = LIB[attribute_end..signature_start].trim();
        let is_async = prefix.ends_with("async");
        let name_start = signature_start + 3;
        let name_end = name_start
            + LIB[name_start..]
                .find(['(', '<'])
                .expect("函数名后应有参数表");
        let body_start = name_end + LIB[name_end..].find('{').expect("函数体");
        found.push(Command {
            name: &LIB[name_start..name_end],
            is_async,
            body: function_body(LIB, body_start),
        });
        cursor = body_start;
    }
    found
}

#[test]
fn network_commands_are_never_synchronous() {
    let commands = commands();
    assert!(
        commands.len() > 30,
        "应解析出全部 command (实际 {})",
        commands.len()
    );
    let mut offenders = Vec::new();
    for command in &commands {
        if command.is_async {
            continue;
        }
        for entry in NETWORK_ENTRY_POINTS {
            if command.body.contains(entry) {
                offenders.push(format!("{} -> {}", command.name, entry));
            }
        }
    }
    assert!(
        offenders.is_empty(),
        "同步 command 在主线程发起网络请求 (须改为 async + off_main_thread): {offenders:?}"
    );
}

#[test]
fn known_network_commands_are_async() {
    let commands = commands();
    for name in [
        "codex_device_start",
        "codex_device_poll",
        "verify_subscription",
    ] {
        let command = commands
            .iter()
            .find(|command| command.name == name)
            .unwrap_or_else(|| panic!("缺少 command {name}"));
        assert!(command.is_async, "{name} 必须是 async command");
        assert!(
            command.body.contains("off_main_thread"),
            "{name} 的阻塞网络调用必须经 off_main_thread"
        );
    }
}
