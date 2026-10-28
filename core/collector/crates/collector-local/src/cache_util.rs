//! Shared primitives for the rebuildable file caches.
//!
//! JSONL 与 SQLite 缓存共用同一套条目读取 / 原子写入与指纹语义; 集中在这里是为了让
//! 失败路径 (NotFound → Missing, 其余 IO 或解析错误 → Corrupt, 写盘时临时文件 + rename)
//! 只有一处实现, 避免两个缓存引擎各自演化出不同的持久化纪律。

use super::sources::SourceScanError;
use collector_runtime::CancellationToken;
use serde::de::DeserializeOwned;
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

/// 缓存条目的读取结果: 缺失与损坏必须区分 —— 两者计入不同的统计
/// (`cache_corruptions` 只统计后者), 并共同触发重建。
pub(crate) enum CacheLoad<T> {
    Missing,
    Corrupt,
    Entry(Box<T>),
}

/// 读取一个 JSON 缓存条目: NotFound → `Missing`, 其余 IO 错误与解析失败 →
/// `Corrupt`, 成功 → `Entry(Box::new(value))`。
pub(crate) fn load_json_cache<T: DeserializeOwned>(path: &Path) -> CacheLoad<T> {
    let data = match fs::read(path) {
        Ok(data) => data,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return CacheLoad::Missing,
        Err(_) => return CacheLoad::Corrupt,
    };
    match serde_json::from_slice(&data) {
        Ok(entry) => CacheLoad::Entry(Box::new(entry)),
        Err(_) => CacheLoad::Corrupt,
    }
}

/// 原子写入一个 JSON 缓存条目。
///
/// 临时文件以 `create_new` 创建并显式收紧到 0600, 写入后用 `rename` 原子替换目标,
/// 失败时清理临时文件 —— 读取方要么看到旧的完整条目, 要么看到新的完整条目, 不会
/// 读到半截 JSON。缓存可再生, 调用方按自身策略处理返回的错误。
pub(crate) fn write_json_atomic<T: Serialize>(
    path: &Path,
    value: &T,
    cancellation: &CancellationToken,
) -> Result<(), SourceScanError> {
    cancellation.check()?;
    let parent = path
        .parent()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "cache path has no parent"))?;
    fs::create_dir_all(parent)?;
    let temporary = parent.join(format!(
        ".{}.tmp-{}-{}",
        path.file_name()
            .and_then(|value| value.to_str())
            .unwrap_or("cache"),
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos()
    ));
    let result = (|| -> Result<(), SourceScanError> {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temporary)
            .map_err(SourceScanError::Io)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            file.set_permissions(fs::Permissions::from_mode(0o600))
                .map_err(SourceScanError::Io)?;
        }
        // C110: 先序列化到内存再一次写入 —— 直接 to_writer 到未缓冲的 File 会把每个
        // JSON 记号变成一次 write 系统调用 (Claude 冷扫约 0.6 s 内核态)。
        let mut bytes = serde_json::to_vec(value).map_err(|error| {
            SourceScanError::Io(io::Error::new(io::ErrorKind::InvalidData, error))
        })?;
        bytes.push(b'\n');
        file.write_all(&bytes).map_err(SourceScanError::Io)?;
        // 落盘后再 rename: 避免掉电/崩溃后留下已替换但内容未持久化的条目。
        file.sync_all().map_err(SourceScanError::Io)?;
        drop(file);
        cancellation.check()?;
        fs::rename(&temporary, path).map_err(SourceScanError::Io)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

/// 指定字节区间的 SHA-256 (十六进制)。区间短于 `length` 时返回 `UnexpectedEof`,
/// 防止把被截断的文件当成完整指纹。
pub(crate) fn fingerprint_range(
    path: &Path,
    start: u64,
    length: u64,
    cancellation: &CancellationToken,
) -> Result<String, SourceScanError> {
    cancellation.check()?;
    let mut file = File::open(path)?;
    file.seek(SeekFrom::Start(start))?;
    let mut hasher = Sha256::new();
    let mut remaining = length;
    let mut buffer = [0u8; 8192];
    while remaining > 0 {
        cancellation.check()?;
        let requested = remaining.min(buffer.len() as u64) as usize;
        let read = file.read(&mut buffer[..requested])?;
        if read == 0 {
            return Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "fingerprint range exceeds file size",
            )
            .into());
        }
        hasher.update(&buffer[..read]);
        remaining -= read as u64;
    }
    Ok(format!("{:x}", hasher.finalize()))
}

/// 文件是否以换行结尾 (空文件视为是), 用于判定追加解析的安全偏移。
pub(crate) fn ends_with_newline(
    path: &Path,
    size: u64,
    cancellation: &CancellationToken,
) -> Result<bool, SourceScanError> {
    if size == 0 {
        return Ok(true);
    }
    cancellation.check()?;
    let mut file = File::open(path)?;
    file.seek(SeekFrom::Start(size - 1))?;
    let mut byte = [0u8; 1];
    file.read_exact(&mut byte)?;
    Ok(byte[0] == b'\n')
}

/// 头尾指纹: size 的 LE 字节 + 首 `chunk_bytes` + (size 超过一块时) 末 `chunk_bytes`
/// 的 SHA-256, 十六进制输出。代替全文件哈希做副本判等 —— GB 级 rollout 每轮刷新全量
/// 重读会让采集卡在分钟级; 指纹只读固定量字节。同头同尾同长但中段不同的极端构造会被
/// 误判为相同副本 (可接受: 仍只计一次用量, 不会重复计数)。
pub(crate) fn fingerprint_head_tail(
    path: &Path,
    size: u64,
    chunk_bytes: u64,
    cancellation: &CancellationToken,
) -> Result<String, SourceScanError> {
    cancellation.check()?;
    let mut file = File::open(path)?;
    let mut hasher = Sha256::new();
    hasher.update(size.to_le_bytes());
    let mut buffer = vec![0u8; chunk_bytes as usize];
    // 头部块 (整文件不足一块时即全部内容).
    let head_len = io::Read::by_ref(&mut file)
        .take(chunk_bytes)
        .read(&mut buffer)?;
    hasher.update(&buffer[..head_len]);
    // 中段存在时直接 seek 到末块前读取, 不重读中段.
    if size > chunk_bytes {
        cancellation.check()?;
        file.seek(SeekFrom::Start(size - chunk_bytes))?;
        let mut tail = Vec::with_capacity(chunk_bytes as usize);
        io::Read::by_ref(&mut file)
            .take(chunk_bytes)
            .read_to_end(&mut tail)?;
        hasher.update(&tail);
    }
    cancellation.check()?;
    Ok(format!("{:x}", hasher.finalize()))
}
