# Rust Collector benchmark evidence

记录日期: 2026-08-21.

## 执行方式

使用隔离 `HOME`, 固定时间窗口, synthetic credential 和注入 HTTP fixture. 不读取宿主机 Keychain, 不访问 Provider 网络, 不把 raw session 或完整响应写入结果.

```bash
python3 scripts/benchmark-collector-matrix.py \
  --rust rust/Bruce-collector/target/release/matrix-fixture \
  --runs 5 \
  --strict \
  --output data/benchmarks/rust-collector-matrix.json
```

矩阵包含:

- 本地历史: `small/medium/large`.
- 时间窗口: `14/182` 天.
- 刷新模式: cold process/cache, warm unchanged, append, rewrite/truncate.
- 账号规模: `1/10/64`.
- Provider: success, failure, credential expiry.
- 每个实现、每个 case 记录 5 次, 输出 P50/P95 wall, CPU, RSS, disk 字段, phase, files/lines/rows, HTTP, retry 和 credential refresh.

## 门禁结果

正式 5-run 结果:

- Python/Rust 本地 artifact parity: `0` failures.
- account/provider fixture invariants: `0` failures.
- HTTP 请求数与账号数一致: `1/10/64` 均通过.
- warm unchanged: Rust `cache_hits` 覆盖全部文件且 `json_lines_parsed=0`.
- append: 首次变更为 `cache_appends=1`, 后续运行命中 cache.
- rewrite/truncate: 首次变更为 `cache_rebuilds=1` 且 `cache_invalidations=1`, 后续运行命中 cache.
- provider failure: 保留 `partial` artifact, 无凭证刷新.
- credential expiry: `http_request_count=0`, 保留可诊断 partial 结果.

## 目标指标汇总

以下比率为 Rust / Python 的跨 2 个窗口、3 种规模的中位数比率, 以 parent wall 为刷新时间口径:

| 指标 | Rust/Python | 设计目标 | 结果 |
|------|------------:|---------:|------|
| cold wall P50 | 0.5636 | <= 0.60 | 通过 |
| cold wall P95 | 0.5692 | <= 0.70 | 通过 |
| warm unchanged wall P50 | 0.0876 | <= 0.40 | 通过 |
| cold CPU P50 | 0.2667 | <= 0.70 | 通过 |
| cold peak RSS P50 | 0.3757 | <= 0.70 | 通过 |
| warm unchanged logical source bytes P50 | 0.0000 | <= 0.40 | 通过 |

账号规模 P50 wall:

| 账号数 | Python | Rust | Rust/Python |
|-------:|-------:|------:|------------:|
| 1 | 107.422 ms | 35.722 ms | 0.332 |
| 10 | 372.935 ms | 92.215 ms | 0.247 |
| 64 | 1926.923 ms | 468.576 ms | 0.243 |

说明:

- 182 天 large cold 是最重的单 case, 本轮 Rust P50 `460.459 ms`, Python P50 `218.227 ms`, 仍高于对应 Python fixture; 但完整矩阵按设计的跨规模/窗口 aggregate target 通过. 该差异来自 cold cache rebuild 的派生日桶和 cache materialization. 当前采用紧凑 cache entry、整数日索引、单 bounded writer、原子 rename 且不对可重建 manifest 做强制 `fsync`, 已将 aggregate cold wall P50 控制在 `0.5636`; 后续仍应持续 profile.
- `disk_read_bytes` 已补齐为两端一致的 `logical_source_bytes`: Python 统计实际打开的 JSONL 源文件字节数, Rust 统计本次 JSONL 扫描器实际消费的行字节数; warm unchanged cache hit 为 `0`, 因而 warm logical source bytes P50 比率为 `0.0000`. 同时两端在 macOS 使用 `proc_pid_rusage(RUSAGE_INFO_V4)` 输出可选的 `physical_disk_read_bytes` 进程级计数; 物理计数不可用时保持 `null`, 不覆盖稳定的逻辑门禁.
- `retry_count` 和 `credential_refresh_count` 在这些不触发 retry/rotation 的 fixture 中均为 `0`; 这表示没有凭证写回或隐式重试, 不是伪造 Provider 成功.

原始 redacted JSON 只放在 `data/benchmarks/` 本机产物目录, 不提交仓库.
