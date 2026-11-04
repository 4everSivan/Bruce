use super::tests_cache::{temp_root, window};
use super::{scan_dsh_cached, scan_dsh_uncached};
use collector_domain::CollectionWindow;
use collector_runtime::{CancellationToken, RuntimeError};
use serde_json::{json, Value};
use std::fs;
use std::io::Write;
use std::path::Path;
use std::time::{Duration, SystemTime};

/// 窗口内的基准时刻: 2026-07-28T12:00:00+08:00 (`tests_cache::window` 的今天)。
const BASE: i64 = 1_785_211_200_000;

/// 构造一个单帧 zstd 流: 帧内容即 `payload` 原文 (未压缩 Raw 块)。
///
/// dsh 每次追加写一个独立帧, 因此「多行夹具」= 多个本函数结果串接; 这样测试无需 zstd
/// 编码器即可覆盖多帧串接解码, 真实压缩码流的解码由 `REAL_MULTI_FRAME_HEX` 覆盖。
fn zstd_raw_frame(payload: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(payload.len() + 16);
    // Magic_Number
    out.extend_from_slice(&[0x28, 0xb5, 0x2f, 0xfd]);
    // Frame_Header_Descriptor: Frame_Content_Size_flag=2 (4 字节), Single_Segment=1。
    out.push(0b1010_0000);
    out.extend_from_slice(&(payload.len() as u32).to_le_bytes());
    for (index, block) in payload.chunks(64 * 1024).enumerate() {
        let last = (index + 1) * 64 * 1024 >= payload.len();
        let header = u32::from(last) | ((block.len() as u32) << 3);
        out.extend_from_slice(&header.to_le_bytes()[..3]);
        out.extend_from_slice(block);
    }
    if payload.is_empty() {
        // 空帧: 一个空的 last block。
        out.extend_from_slice(&[0x01, 0x00, 0x00]);
    }
    out
}

/// 每个事件写一帧 (与 dsh 追加写形状一致)。
fn session_bytes(lines: &[Value]) -> Vec<u8> {
    let mut out = Vec::new();
    for line in lines {
        out.extend_from_slice(&zstd_raw_frame(format!("{line}\n").as_bytes()));
    }
    out
}

fn write_compressed(root: &Path, relative: &str, lines: &[Value]) {
    let path = root.join(relative);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(&path, session_bytes(lines)).unwrap();
}

fn write_plain(root: &Path, relative: &str, lines: &[Value]) {
    let path = root.join(relative);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    let content = lines
        .iter()
        .map(|line| format!("{line}\n"))
        .collect::<String>();
    fs::write(&path, content).unwrap();
}

fn session_header(cwd: &str) -> Value {
    json!({"type": "session", "version": 4, "id": "fixture-session", "cwd": cwd})
}

#[allow(clippy::too_many_arguments)]
fn assistant_message(
    time: i64,
    id: Option<&str>,
    model: Option<&str>,
    input: u64,
    output: u64,
    cache_read: u64,
    cache_write: u64,
    total: u64,
) -> Value {
    let mut message = json!({ "role": "assistant" });
    if let Some(id) = id {
        message["id"] = json!(id);
    }
    if let Some(model) = model {
        message["source"] = json!({"provider": "deepseek-account", "model": model});
    }
    json!({
        "type": "assistant/message",
        "time": time,
        "data": {
            "message": message,
            "usage": {
                "inputTokens": input,
                "outputTokens": output,
                "cacheReadTokens": cache_read,
                "cacheWriteTokens": cache_write,
                "totalTokens": total,
            }
        }
    })
}

fn event(type_name: &str, time: i64) -> Value {
    json!({"type": type_name, "seq": 0, "time": time, "data": {"text": "ignored"}})
}

fn today(scan: &super::SourceScan) -> &collector_domain::TokenBucket {
    scan.contribution
        .by_day
        .get("2026-07-28")
        .expect("今日桶应存在")
}

/// 多帧压缩会话: token 映射 (totalTokens 是派生值不得计入输入)、非用量事件预筛、
/// 项目名取会话头 cwd 末段、缺 id 的消息照常计数。
#[test]
fn dsh_maps_camel_case_tokens_from_multi_frame_sessions() {
    let root = temp_root("dsh-multiframe");
    write_compressed(
        &root,
        "workspace-dir/session-a/session.v4.jsonl.zstd",
        &[
            session_header("/Users/example/work/demo-project"),
            // 派生 totalTokens 远大于分量之和: 只能由分量求和, 不得采信。
            assistant_message(
                BASE,
                Some("msg-1"),
                Some("deepseek-flash"),
                100,
                20,
                30,
                5,
                999,
            ),
            event("tool/call", BASE + 1_000),
            event("step/end", BASE + 2_000),
            assistant_message(
                BASE + 3_000,
                Some("msg-2"),
                Some("cline-pass/deepseek-v4.1-flash-1017"),
                7,
                3,
                0,
                0,
                10,
            ),
            // 无 message id: 照常计数, 不参与跨文件去重。
            assistant_message(BASE + 4_000, None, Some("deepseek-flash"), 1, 1, 0, 0, 2),
        ],
    );

    let scan = scan_dsh_uncached(&root, &window());

    assert!(scan.diagnostic.is_none());
    assert!(scan.found, "识别到会话文件");
    assert_eq!(scan.stats.files_scanned, 1);
    assert_eq!(scan.stats.files_scanned, scan.stats.files_visited);
    assert_eq!(
        scan.stats.lines_seen, 6,
        "多帧串接解码不得丢帧: 6 行全部读出"
    );
    let bucket = today(&scan);
    assert_eq!(bucket.input, 108, "inputTokens 直取, totalTokens 不计入");
    assert_eq!(bucket.output, 24);
    assert_eq!(bucket.cache_read, 30);
    assert_eq!(bucket.cache_creation, 5);
    assert_eq!(bucket.total, 167, "总量由四类分量求和");
    assert_eq!(scan.stats.usage_records, 3, "三条 assistant/message 用量");
    assert_eq!(
        scan.contribution.projects_today[0].name, "demo-project",
        "项目名取会话头 cwd 末段"
    );
    assert_eq!(scan.contribution.projects_today[0].total, 167);
    // 预筛: 不含 "usage" / "cwd" 的事件行不建 JSON DOM。
    assert_eq!(scan.stats.ignored_lines, 3, "两条非用量事件 + 会话头");
    assert_eq!(
        scan.stats.json_lines_parsed, 4,
        "只解析预筛命中的行: 3 条用量行 + 会话头"
    );
    fs::remove_dir_all(root).ok();
}

/// 真实压缩码流 (5 个 zstd 帧串接, `zstd -19` 生成) 的解码与口径核对。
#[test]
fn dsh_decodes_real_zstd_multi_frame_fixture() {
    let root = temp_root("dsh-real-zstd");
    let path = root.join("workspace-dir/session-real/session.v4.jsonl.zstd");
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(&path, hex_bytes(REAL_MULTI_FRAME_HEX)).unwrap();

    let scan = scan_dsh_uncached(&root, &window());

    assert!(scan.diagnostic.is_none());
    assert_eq!(scan.stats.files_scanned, 1);
    assert_eq!(
        scan.stats.lines_seen, 5,
        "5 个真实 zstd 帧的行必须全部读出 (帧边界在行尾)"
    );
    assert_eq!(scan.stats.json_lines_parsed, 3, "会话头 + 两条用量行");
    assert_eq!(scan.stats.usage_records, 2);
    let bucket = today(&scan);
    assert_eq!(bucket.input, 107);
    assert_eq!(bucket.output, 23);
    assert_eq!(bucket.cache_read, 30);
    assert_eq!(bucket.cache_creation, 2);
    assert_eq!(bucket.total, 162);
    assert_eq!(
        scan.contribution.projects_today[0].name, "demo-project",
        "项目名取会话头 cwd 末段"
    );
    let mut models = scan
        .contribution
        .models_today
        .iter()
        .map(|delta| delta.model.as_str())
        .collect::<Vec<_>>();
    models.sort_unstable();
    assert_eq!(
        models,
        vec!["cline-pass/deepseek-v4.1-flash-1017", "deepseek-flash"],
        "模型串原样保留 (去重表按键序产出)"
    );
    fs::remove_dir_all(root).ok();
}

/// fork / seed 会话继承历史消息: 同一 message id 跨文件只计一次, 取值按总量最大者。
#[test]
fn dsh_dedupes_message_ids_across_files() {
    let root = temp_root("dsh-dedupe");
    write_compressed(
        &root,
        "workspace-dir/session-origin/session.v4.jsonl.zstd",
        &[
            session_header("/Users/example/work/demo-project"),
            assistant_message(
                BASE,
                Some("shared-1"),
                Some("deepseek-flash"),
                100,
                10,
                5,
                0,
                115,
            ),
            assistant_message(
                BASE + 1_000,
                Some("origin-only"),
                Some("deepseek-flash"),
                10,
                1,
                0,
                0,
                11,
            ),
            assistant_message(BASE + 2_000, None, Some("deepseek-flash"), 3, 1, 0, 0, 4),
        ],
    );
    // fork: 继承 shared-1 (历史快照更小) 与 origin-only, 并追加自己的消息。
    write_compressed(
        &root,
        "workspace-dir/session-fork/session.v4.jsonl.zstd",
        &[
            session_header("/Users/example/work/demo-project"),
            assistant_message(
                BASE,
                Some("shared-1"),
                Some("deepseek-flash"),
                40,
                4,
                0,
                0,
                44,
            ),
            assistant_message(
                BASE + 1_000,
                Some("origin-only"),
                Some("deepseek-flash"),
                10,
                1,
                0,
                0,
                11,
            ),
            assistant_message(
                BASE + 3_000,
                Some("fork-only"),
                Some("deepseek-flash"),
                20,
                2,
                0,
                0,
                22,
            ),
            assistant_message(BASE + 4_000, None, Some("deepseek-flash"), 6, 1, 0, 0, 7),
        ],
    );

    let scan = scan_dsh_uncached(&root, &window());

    assert_eq!(scan.stats.files_scanned, 2);
    assert_eq!(scan.stats.usage_records, 7, "两个文件的事件都按用量解析");
    let bucket = today(&scan);
    // shared-1 取总量最大的一次 (115), origin-only 计一次 (11), fork-only (22),
    // 两条无 id 观测各自计数 (4 + 7)。
    assert_eq!(bucket.input, 100 + 10 + 20 + 3 + 6);
    assert_eq!(bucket.output, 10 + 1 + 2 + 1 + 1);
    assert_eq!(bucket.cache_read, 5);
    assert_eq!(bucket.total, 115 + 11 + 22 + 4 + 7);
    fs::remove_dir_all(root).ok();
}

/// 多模型 / 缺模型: 模型缺失回落到 unknown, 模型串不改写; 未压缩 `.jsonl` 同样可读。
#[test]
fn dsh_keeps_model_strings_and_accepts_plain_jsonl() {
    let root = temp_root("dsh-models");
    write_compressed(
        &root,
        "workspace-dir/session-a/session.v4.jsonl.zstd",
        &[
            session_header("/Users/example/work/press-model"),
            assistant_message(BASE, Some("m-1"), Some("deepseek-flash"), 10, 2, 0, 0, 12),
            assistant_message(BASE + 1_000, Some("m-2"), None, 4, 1, 0, 0, 5),
        ],
    );
    write_plain(
        &root,
        "workspace-dir/session-b/session.v4.jsonl",
        &[
            session_header(r"C:\Users\example\work\windows-project"),
            assistant_message(
                BASE + 2_000,
                Some("m-3"),
                Some("cline-pass/deepseek-v4.1-flash-1017"),
                6,
                2,
                1,
                0,
                9,
            ),
        ],
    );

    let scan = scan_dsh_uncached(&root, &window());

    assert_eq!(scan.stats.files_scanned, 2);
    let models = scan
        .contribution
        .models_today
        .iter()
        .map(|delta| (delta.model.as_str(), delta.bucket.total))
        .collect::<Vec<_>>();
    let mut models = models;
    models.sort_unstable();
    assert_eq!(
        models,
        vec![
            ("cline-pass/deepseek-v4.1-flash-1017", 9),
            ("deepseek-flash", 12),
            ("unknown", 5),
        ],
        "缺模型回落 unknown, 其余模型串原样保留"
    );
    let mut projects = scan
        .contribution
        .projects_today
        .iter()
        .map(|project| project.name.as_str())
        .collect::<Vec<_>>();
    projects.sort_unstable();
    assert_eq!(
        projects,
        vec!["press-model", "windows-project"],
        "兼容 / 与 \\ 两种会话路径分隔符"
    );
    fs::remove_dir_all(root).ok();
}

/// 损坏的压缩文件只计入 io_errors, 不中断整源扫描, 也不污染其它会话的用量。
#[test]
fn dsh_skips_corrupt_compressed_files() {
    let root = temp_root("dsh-corrupt");
    write_compressed(
        &root,
        "workspace-dir/session-good/session.v4.jsonl.zstd",
        &[
            session_header("/Users/example/work/good-project"),
            assistant_message(BASE, Some("good-1"), Some("deepseek-flash"), 8, 2, 0, 0, 10),
        ],
    );
    // 非 zstd 内容 (魔数非法)。
    let garbage = root.join("workspace-dir/session-garbage/session.v4.jsonl.zstd");
    fs::create_dir_all(garbage.parent().unwrap()).unwrap();
    fs::write(&garbage, b"this is not a zstd session").unwrap();
    // 帧被截断: 魔数与帧头合法, 块内容不足。
    let truncated = zstd_raw_frame(b"{\"type\":\"assistant/message\",\"time\":1785211200000}\n");
    let truncated_path = root.join("workspace-dir/session-truncated/session.v4.jsonl.zstd");
    fs::create_dir_all(truncated_path.parent().unwrap()).unwrap();
    fs::write(&truncated_path, &truncated[..truncated.len() - 4]).unwrap();
    // 后缀匹配但没有帧的纯文本文件。
    let plain_garbage = root.join("workspace-dir/session-garbage/data.jsonl.zstd");
    fs::write(&plain_garbage, b"this is not a zstd session").unwrap();
    // 帧头声明了病态大的内容长度: 在解压前即拒绝, 不占内存。
    let oversized = root.join("workspace-dir/session-oversized/session.v4.jsonl.zstd");
    fs::create_dir_all(oversized.parent().unwrap()).unwrap();
    fs::write(&oversized, zstd_frame_declaring(64 * 1024 * 1024)).unwrap();

    let scan = scan_dsh_uncached(&root, &window());

    assert!(scan.diagnostic.is_none());
    assert!(scan.found);
    assert_eq!(scan.stats.files_scanned, 5);
    assert_eq!(
        scan.stats.io_errors, 4,
        "损坏 / 截断 / 非帧 / 超大帧各计一次"
    );
    assert_eq!(scan.stats.usage_records, 1, "只有完好文件产出用量");
    assert_eq!(today(&scan).total, 10);
    // C201: 整文件读取失败与 Codex / JSONL 同口径附信息级说明。
    assert_eq!(
        scan.notice.as_deref(),
        Some("会话文件读取失败 4 个, 本轮沿用上次结果或暂未计入, 下次刷新重试")
    );
    fs::remove_dir_all(root).ok();
}

/// mtime 早于采集窗口的会话整体跳过 (按文件签名过滤, 不解压)。
#[test]
fn dsh_skips_files_older_than_the_window() {
    let root = temp_root("dsh-window");
    write_compressed(
        &root,
        "workspace-dir/session-old/session.v4.jsonl.zstd",
        &[
            session_header("/Users/example/work/demo-project"),
            assistant_message(BASE, Some("old-1"), Some("deepseek-flash"), 5, 1, 0, 0, 6),
        ],
    );
    let path = root.join("workspace-dir/session-old/session.v4.jsonl.zstd");
    let file = fs::OpenOptions::new().write(true).open(&path).unwrap();
    file.set_modified(SystemTime::now() - Duration::from_secs(30 * 86_400))
        .unwrap();
    drop(file);
    // 以真实当前时间为窗口基准, 保证 30 天前的 mtime 落在窗口之外。
    let window = CollectionWindow::from_context(
        &serde_json::from_value(json!({"timezone": "Asia/Shanghai", "days": 3})).unwrap(),
    )
    .unwrap();

    let scan = scan_dsh_uncached(&root, &window);

    assert!(!scan.found, "窗口外的会话不算发现会话");
    assert_eq!(scan.stats.files_visited, 1);
    assert_eq!(scan.stats.files_skipped, 1);
    assert_eq!(scan.stats.files_scanned, 0);
    assert_eq!(scan.stats.lines_seen, 0, "跳过文件不解压");
    assert!(scan.contribution.by_day.is_empty());
    fs::remove_dir_all(root).ok();
}

/// 根目录不存在: 空结果而不是故障 (未安装 dsh 的机器)。
#[test]
fn dsh_missing_root_is_an_empty_scan() {
    let root = temp_root("dsh-missing");
    let scan = scan_dsh_uncached(&root.join("does-not-exist"), &window());
    assert!(!scan.found);
    assert_eq!(scan.stats, Default::default());
    assert!(scan.contribution.by_day.is_empty());
    fs::remove_dir_all(root).ok();
}

/// 取消: 返回类型化 Runtime 错误, 且不留下半成品缓存。
#[test]
fn dsh_cancellation_returns_typed_runtime_error() {
    let root = temp_root("dsh-cancel");
    write_compressed(
        &root,
        "sessions/workspace-dir/session-a/session.v4.jsonl.zstd",
        &[
            session_header("/Users/example/work/demo-project"),
            assistant_message(BASE, Some("m-1"), Some("deepseek-flash"), 5, 1, 0, 0, 6),
        ],
    );
    let cache_root = root.join("cache");
    let cancellation = CancellationToken::new();
    cancellation.cancel();

    let result = scan_dsh_cached(
        &root.join("sessions"),
        &window(),
        &cache_root,
        &cancellation,
    );

    assert!(matches!(
        result,
        Err(super::SourceScanError::Runtime(RuntimeError::Cancelled))
    ));
    assert!(
        !cache_root.join("dsh-sessions-v1.json").exists(),
        "取消的扫描不得落盘部分缓存"
    );
    fs::remove_dir_all(root).ok();
}

/// 按文件签名缓存: 未变化文件命中缓存且不解压, 追加写 (每次一个 zstd 帧) 只重建该文件。
#[test]
fn dsh_cache_hits_unchanged_files_and_rebuilds_appended_frames() {
    let root = temp_root("dsh-cache");
    let cache_root = root.join("cache");
    write_compressed(
        &root,
        "workspace-dir/session-a/session.v4.jsonl.zstd",
        &[
            session_header("/Users/example/work/demo-project"),
            assistant_message(BASE, Some("m-1"), Some("deepseek-flash"), 10, 2, 0, 0, 12),
        ],
    );
    write_plain(
        &root,
        "workspace-dir/session-b/session.v4.jsonl",
        &[
            session_header("/Users/example/work/demo-project"),
            assistant_message(
                BASE + 1_000,
                Some("m-2"),
                Some("deepseek-flash"),
                4,
                1,
                0,
                0,
                5,
            ),
        ],
    );
    let expected = scan_dsh_uncached(&root, &window());

    let cold = scan_dsh_cached(&root, &window(), &cache_root, &CancellationToken::new()).unwrap();
    assert_eq!(cold.contribution, expected.contribution);
    assert_eq!(cold.stats.cache_rebuilds, 2);
    assert_eq!(cold.stats.cache_hits, 0);
    assert!(cold.stats.json_lines_parsed > 0);
    super::tests_cache::assert_cache_files_private_without_temporaries(&cache_root);

    let warm = scan_dsh_cached(&root, &window(), &cache_root, &CancellationToken::new()).unwrap();
    assert_eq!(warm.contribution, cold.contribution);
    assert_eq!(warm.stats.cache_hits, 2, "两个文件都命中");
    assert_eq!(warm.stats.cache_rebuilds, 0);
    assert_eq!(warm.stats.json_lines_parsed, 0, "命中缓存不解析 JSON");
    assert_eq!(warm.stats.lines_seen, 0, "命中缓存不解压");

    // dsh 每次追加写一个独立帧: 文件签名变化即该文件整文件重建。
    let compressed = root.join("workspace-dir/session-a/session.v4.jsonl.zstd");
    let mut file = fs::OpenOptions::new()
        .append(true)
        .open(&compressed)
        .unwrap();
    file.write_all(&zstd_raw_frame(
        format!(
            "{}\n",
            assistant_message(
                BASE + 2_000,
                Some("m-3"),
                Some("deepseek-flash"),
                20,
                4,
                0,
                0,
                24
            )
        )
        .as_bytes(),
    ))
    .unwrap();
    drop(file);
    let expected = scan_dsh_uncached(&root, &window());
    let appended =
        scan_dsh_cached(&root, &window(), &cache_root, &CancellationToken::new()).unwrap();
    assert_eq!(appended.contribution, expected.contribution);
    assert_eq!(appended.stats.cache_rebuilds, 1, "只有追加的文件重建");
    assert_eq!(appended.stats.cache_hits, 1);
    assert_eq!(today(&appended).total, 12 + 5 + 24);

    // 缓存条目损坏: 计入 cache_corruptions 并整体重建, 结果不变。
    fs::write(cache_root.join("dsh-sessions-v1.json"), b"not-json").unwrap();
    let repaired =
        scan_dsh_cached(&root, &window(), &cache_root, &CancellationToken::new()).unwrap();
    assert_eq!(repaired.contribution, expected.contribution);
    assert_eq!(repaired.stats.cache_corruptions, 1);
    assert_eq!(repaired.stats.cache_rebuilds, 2);

    // 源文件删除: 对应缓存条目被清理, 其余会话结果不变。
    fs::remove_file(root.join("workspace-dir/session-b/session.v4.jsonl")).unwrap();
    let after_delete =
        scan_dsh_cached(&root, &window(), &cache_root, &CancellationToken::new()).unwrap();
    assert!(after_delete.found);
    assert_eq!(after_delete.stats.cache_hits, 1);
    assert_eq!(after_delete.stats.cache_deletions, 1);
    assert_eq!(
        after_delete
            .contribution
            .projects_today
            .first()
            .map(|project| project.total),
        Some(12 + 24)
    );
    fs::remove_dir_all(root).ok();
}

/// 活写撕裂 (C189 / C192): 正在写入的会话被抓到「新追加的帧只落了一半」—— 之前的帧照常计入,
/// 数字不下降; 撕裂末帧计一次 io_errors, 不算坏帧 (不产生说明)。部分解析照常缓存, 签名不变时
/// 直接命中 (不再每轮重解压); 写完后签名变化, 重建为真实值。
#[test]
fn dsh_torn_tail_keeps_complete_frames_and_recovers() {
    let root = temp_root("dsh-torn-write");
    let cache_root = root.join("cache");
    let session = root.join("workspace-dir/session-a/session.v4.jsonl.zstd");
    let header = session_header("/Users/example/work/demo-project");
    let first = assistant_message(BASE, Some("m-1"), Some("deepseek-flash"), 10, 2, 0, 0, 12);
    let second = assistant_message(
        BASE + 1_000,
        Some("m-2"),
        Some("deepseek-flash"),
        20,
        4,
        0,
        0,
        24,
    );
    write_compressed(
        &root,
        "workspace-dir/session-a/session.v4.jsonl.zstd",
        &[header, first, second],
    );
    let scan =
        || scan_dsh_cached(&root, &window(), &cache_root, &CancellationToken::new()).unwrap();
    let warm = scan();
    assert_eq!(today(&warm).total, 36);
    let complete = fs::read(&session).unwrap();
    let third_line = assistant_message(
        BASE + 2_000,
        Some("m-3"),
        Some("deepseek-flash"),
        50,
        10,
        0,
        0,
        60,
    );
    let third = zstd_raw_frame(format!("{third_line}\n").as_bytes());

    // 第三帧只落了一半。
    let mut torn_bytes = complete.clone();
    torn_bytes.extend_from_slice(&third[..third.len() / 2]);
    fs::write(&session, &torn_bytes).unwrap();
    let torn = scan();
    assert_eq!(
        torn.contribution, warm.contribution,
        "撕裂末帧之前的帧照常计入"
    );
    assert!(torn.found);
    assert_eq!(torn.stats.io_errors, 1);
    assert_eq!(torn.stats.cache_rebuilds, 1, "部分解析照常缓存");
    assert!(torn.notice.is_none(), "撕裂末帧不是坏帧, 不产生说明");
    let torn_again = scan();
    assert_eq!(
        torn_again.stats.cache_hits, 1,
        "签名不变直接命中, 不再每轮重解压"
    );
    assert_eq!(torn_again.contribution, warm.contribution);

    let mut completed = complete;
    completed.extend_from_slice(&third);
    fs::write(&session, completed).unwrap();
    let recovered = scan();
    assert_eq!(recovered.stats.cache_rebuilds, 1);
    assert_eq!(recovered.stats.io_errors, 0);
    assert_eq!(today(&recovered).total, 36 + 60, "写完后恢复为真实值");
    fs::remove_dir_all(root).ok();
}

/// 结构合法但压缩块内容损坏的帧 (单段, 声明 16 字节, 一个 8 字节的压缩块)。
fn zstd_corrupt_compressed_frame() -> Vec<u8> {
    let mut out = vec![0x28, 0xb5, 0x2f, 0xfd, 0b0010_0000, 16];
    let header = (8u32 << 3) | (2 << 1) | 1;
    out.extend_from_slice(&header.to_le_bytes()[..3]);
    out.extend_from_slice(&[0xff; 8]);
    out
}

/// 不声明内容长度、窗口 1 MiB 的帧, 由 65 个 128 KiB 的 RLE 块组成: 压缩后约 260 字节,
/// 解出 8.125 MiB —— 只能在解码过程中发现超限。
fn zstd_rle_bomb_frame() -> Vec<u8> {
    let mut out = vec![0x28, 0xb5, 0x2f, 0xfd, 0b0000_0000, 10 << 3];
    for index in 0..65u32 {
        let last = u32::from(index == 64);
        let header = ((128 * 1024) << 3) | (1 << 1) | last;
        out.extend_from_slice(&header.to_le_bytes()[..3]);
        out.push(b'x');
    }
    out
}

/// C192: 帧彼此独立 —— 中间一帧解码失败、帧间混入无法识别的字节 (按魔数重新同步)、
/// 或一帧在解码中超过上限, 都只跳过该帧并计数; 其余帧用量完整, 坏帧数随缓存持久化,
/// 经信息级说明可见。旧实现任一帧失败即整个会话本轮为 0。
#[test]
fn dsh_damaged_frames_are_isolated_and_counted() {
    let message = |id: &str, offset: i64, input: u64| {
        let line = assistant_message(
            BASE + offset,
            Some(id),
            Some("deepseek-flash"),
            input,
            1,
            0,
            0,
            input + 1,
        );
        zstd_raw_frame(format!("{line}\n").as_bytes())
    };
    let header_line = session_header("/Users/example/work/demo-project");
    let header = zstd_raw_frame(format!("{header_line}\n").as_bytes());
    let cases: [(&str, Vec<u8>); 3] = [
        ("corrupt-block", zstd_corrupt_compressed_frame()),
        (
            "garbage-between-frames",
            b"not a zstd frame at all".to_vec(),
        ),
        ("rle-bomb", zstd_rle_bomb_frame()),
    ];
    for (label, damaged) in cases {
        let root = temp_root(&format!("dsh-damaged-{label}"));
        let cache_root = root.join("cache");
        let session = root.join("workspace-dir/session-a/session.v4.jsonl.zstd");
        fs::create_dir_all(session.parent().unwrap()).unwrap();
        let mut bytes = header.clone();
        bytes.extend_from_slice(&message("m-1", 0, 10));
        bytes.extend_from_slice(&damaged);
        bytes.extend_from_slice(&message("m-2", 1_000, 20));
        fs::write(&session, bytes).unwrap();

        let scan =
            || scan_dsh_cached(&root, &window(), &cache_root, &CancellationToken::new()).unwrap();
        let cold = scan();
        assert_eq!(today(&cold).total, 11 + 21, "{label}: 坏帧前后的帧都计入");
        assert_eq!(cold.stats.io_errors, 0, "{label}: 不再整文件失败");
        assert_eq!(
            cold.notice.as_deref(),
            Some("1 个 dsh 压缩帧损坏或超过 8 MiB 上限, 已跳过这些帧"),
            "{label}"
        );
        let warm = scan();
        assert_eq!(warm.stats.cache_hits, 1, "{label}: 部分成功的解析照常缓存");
        assert_eq!(warm.notice, cold.notice, "{label}: 坏帧数随缓存持久化");
        fs::remove_dir_all(root).ok();
    }
}

/// 缓存版本升级 (解析 / 聚合规则变化) 时旧条目整体失效重建, 不计为损坏。
#[test]
fn dsh_cache_version_mismatch_invalidates_instead_of_corrupting() {
    let root = temp_root("dsh-cache-version");
    let cache_root = root.join("cache");
    write_compressed(
        &root,
        "workspace-dir/session-a/session.v4.jsonl.zstd",
        &[
            session_header("/Users/example/work/demo-project"),
            assistant_message(BASE, Some("m-1"), Some("deepseek-flash"), 10, 2, 0, 0, 12),
        ],
    );
    let cold = scan_dsh_cached(&root, &window(), &cache_root, &CancellationToken::new()).unwrap();
    let cache_path = cache_root.join("dsh-sessions-v1.json");
    let content = fs::read_to_string(&cache_path).unwrap();
    fs::write(
        &cache_path,
        content.replace("\"parser_version\":1", "\"parser_version\":0"),
    )
    .unwrap();

    let stale = scan_dsh_cached(&root, &window(), &cache_root, &CancellationToken::new()).unwrap();

    assert_eq!(stale.contribution, cold.contribution);
    assert_eq!(stale.stats.cache_invalidations, 1);
    assert_eq!(stale.stats.cache_corruptions, 0);
    assert_eq!(stale.stats.cache_rebuilds, 1);
    fs::remove_dir_all(root).ok();
}

/// 只写帧头 (声明 `content_len` 字节) 与一个空 last block 的帧, 用于超大帧护栏用例。
fn zstd_frame_declaring(content_len: u32) -> Vec<u8> {
    let mut out = vec![0x28, 0xb5, 0x2f, 0xfd, 0b1010_0000];
    out.extend_from_slice(&content_len.to_le_bytes());
    out.extend_from_slice(&[0x01, 0x00, 0x00]);
    out
}

fn hex_bytes(hex: &str) -> Vec<u8> {
    let mut out = Vec::with_capacity(hex.len() / 2);
    for pair in hex.as_bytes().chunks(2) {
        assert_eq!(pair.len(), 2, "十六进制串长度必须为偶数");
        out.push(u8::from_str_radix(std::str::from_utf8(pair).unwrap(), 16).unwrap());
    }
    out
}

/// 真实 zstd 码流 (5 个独立帧串接), 由 `zstd -19 -c` 逐行压缩生成:
/// 会话头 + step/start + 两条 assistant/message + 一条 tool/call,
/// 项目 `/Users/fixture/workspace/demo-project`。
const REAL_MULTI_FRAME_HEX: &str = concat!(
    "28b52ffd0468750200e2441011907d9cee848bd120b6d8fdbfbd1b4bce12603b45cfa08c02ba4fe3d189b34978c798f2",
    "a7195e3c5d245e568a97f2e269792045bef5e00fae397f7af18f99ba0e030042e5dfa85dda96267900486228b52ffd04",
    "681d020052040e11a0ed3cb85c92f50780a8f46ee218d462c0a0d6e587e53728fb948f1aa5874176493966f98aad7e58",
    "fe53f1e10d5147e154c7f3959b7d1a0200bc92d000e801cd6ac3bf28b52ffd0468750500f2cb231960770ea38ea1d2c7",
    "316a66d51d6e98c2d3a38c095404290111c0b66daf8064d7dea695424cb9c83a8b5ceeded056bd7b0fc6b3b44f4dda9a",
    "24eb6edbeeb0841868678deede9255974506cf2e4fbbf3f1d54e7ad56a5a2aabf2dd61d070146c65354699c74f7a2d5e",
    "8b972de7dd7b0fbe01c2a1380c18bf11edbb219e5abefb36927923a125d94c99e5e377cafa5a0a005128148090932820",
    "2c4ef2d91846e2c2cf27bf846a2ec8579901c5021c6928b52ffd0468ed02008206151770adc690dbf0c39844087c7fff",
    "ff9be4820cf94a3ff758c0343dfd68fcb91f32574ae6f849bb699d5042c9b3ab15bac63b97dc5b1759adb5da6a8cb5a1",
    "20981bcaa5ae04b703e9ea18f70822c3d4ddb089ea5201000c0205059fc95b4828b52ffd0468bd0500a24c261950770e",
    "23a6d7ccc4a7db58b037332f10159df6c14755d96008c0f77d839ce8b5ee21c1d766cd50292f1c39d4392cae661d26f3",
    "5db1643157bb2aedf0fb9ec841c6a8e9f44419185b9498fb62aec2c4d5a20edf4dafc8959d9ccf675ced666597936956",
    "1f9e8850539133ed72f6f97cb5f7e6bd797a693d1c10424ae2501239cf94bd87c63cc67d7886683753c2ade86ddb4d3f",
    "cf5777ef050a003309c749146476935034c63ee32287f37242dd2c15d10b0050a1633636",
);
