# Rust Collector 验证记录

记录日期: 2026-08-21.

## 已完成的本地证据

| 范围 | 命令/检查 | 结果 |
|------|-----------|------|
| Python 契约 | `python3 -m pytest -q` | 261 passed |
| Rust workspace | `cargo fmt --check`, `cargo test --workspace`, `cargo clippy --workspace --all-targets -- -D warnings` | 全部通过 |
| Swift App | `swift build --package-path macos/BruceApp` | 通过 |
| Swift Harness | `zsh scripts/verify-local.sh` | 全部通过, 含 Onboarding 177, Panel 43, RefreshScheduler 81, CollectorRunner 28 |
| 差分契约 | `python3 scripts/differential-collector.py --request tests/fixtures/bridge/agent-usage/request-valid.json --rust rust/Bruce-collector/target/debug/Bruce-collector` | `PARITY OK` |
| Fixture 安全 | `scripts/check-collector-fixtures.py` | 15 个 fixture, `secretFindings=[]` |
| Preview 打包 | `zsh scripts/build-test-app.sh` | `dist/Bruce.app` 与 `dist/Bruce.zip` 生成 |
| Collector runtime smoke | `zsh scripts/collector-release-smoke.sh dist/Bruce.app --local-preview` | Bridge 单 envelope、artifact、旧 cache rebuild、install/upgrade/rollback 全部通过 |
| 逻辑/物理 I/O 指标 | `python3 scripts/benchmark-collector-matrix.py --rust rust/Bruce-collector/target/release/matrix-fixture --runs 5 --strict` | `logical_source_bytes` 门禁和 macOS `physical_disk_read_bytes` 可选计数均覆盖 Python/Rust; warm unchanged Rust 逻辑读取为 `0` 且目标通过 |
| Release 包扫描 | `Bruce_validate_release_bundle` | release Swift executable + universal Rust release-shaped preflight 通过; Python fallback marker、错架构和 data 目录均被拒绝 |

## 性能对比

基于隔离 HOME, 无网络、无真实凭证、5 次运行, `small/medium/large` 三档 JSONL fixture.

| 场景 | Python parent wall P50 | Rust parent wall P50 | Python RSS P50 | Rust RSS P50 |
|------|-------------------------:|----------------------:|---------------:|-------------:|
| small | 130.067 ms | 22.218 ms | 24.76 MB | 8.40 MB |
| medium | 179.153 ms | 24.925 ms | 25.44 MB | 8.59 MB |
| large | 311.076 ms | 25.335 ms | 25.25 MB | 8.62 MB |

该表为早期单窗口摘要; 当前以完整双窗口矩阵结果为准. 完整矩阵覆盖本地 cold/warm、append、rewrite/truncate 和规模增长, 外部 quota 使用注入 HTTP fixture, 不访问真实网络.

## 2026-08-21 完整矩阵补充

`benchmark-collector-matrix.py --runs 5 --strict` 已覆盖开发文档 014 要求的两个窗口、三档本地历史、四种刷新变化、1/10/64 账号、Provider success/failure 和 credential expiry. 结果为 artifact parity `0`, fixture invariant failures `0`, target failures `0`; 跨窗口/规模 cold wall P50 `0.5636x`, cold wall P95 `0.5692x`, warm unchanged wall P50 `0.0876x`, cold CPU P50 `0.2667x`, cold RSS P50 `0.3757x`, warm logical source bytes P50 `0.0000x`. `disk_read_bytes` 的门禁口径是 `logical_source_bytes`; 两端另提供 macOS `physical_disk_read_bytes` 可选计数, 当前矩阵无 measurement gap. 详细原始结果和限制见 [benchmark-evidence.md](./benchmark-evidence.md).

## 仍需发布环境证据

以下项目仍依赖 Developer ID 和 notarization 环境, 不能由当前本地 unsigned 环境伪造为已完成:

- universal Rust binary 已在本机生成, `lipo` 显示 `x86_64 arm64`, 并通过双架构 local Preview smoke.
- Developer ID 签名、`notarytool` 公证、staple 和 `spctl` 验证.
- signed Release artifact 上的安装、升级和回滚演练; 本地 Preview 隔离目录 smoke 已通过.
- 具备多账号 HTTP fixture 的 account-scale benchmark 已由注入 HTTP fixture 覆盖; 真实网络不作为本地门禁.

Release 脚本已经默认要求 `arm64 x86_64` 并在缺少签名或公证条件时 fail closed; 这些发布证据完成前, 不将 cutover 标记为 ready.

## 本轮补充: Swift 生产接入与当前迁移状态

本轮已把 Rust 可执行文件接入 Swift 的生产路径, 并把 Python 适配器收敛为 Debug/Preview 能力:

- Release 构建只选择 Bundle 内的 `Bruce-collector`; Rust 不存在或不可执行时返回明确的 `RUST_COLLECTOR_UNAVAILABLE`, 不再回退到 Python.
- Debug/Preview 仍允许使用 `PythonPreviewAdapter`, 方便 UI 预览和迁移期间的对照验证; Preview 与 Release 使用同一 Rust binary 构建来源.
- `CollectorExecutable` 与 `CollectorRuntimeControlling` 保留了 Swift Runner 的 timeout、cancel、run scope、`runId` 和凭证更新处理接缝.
- Release 编译产物已通过字符串扫描, 不含 `PythonPreviewAdapter`、`run_bridge.py`、`pythonURL` 或 `bridgeURL` fallback 标记; `Bruce_validate_release_bundle` 已将该扫描固化为发布门禁.
- `Bruce_validate_release_bundle` 已验证合法 Rust bundle 可通过, 错架构 binary、`data` 目录以及 Python/source runtime 会被拒绝.
- `zsh scripts/build-test-app.sh` 已成功生成 `dist/Bruce.app` 和 `dist/Bruce.zip`; `CI=true zsh scripts/verify-local.sh` 全部通过.
- `BRUCE_RUST_TARGET_ARCHS="arm64 x86_64" zsh scripts/build-test-app.sh` 已生成带 universal Rust runtime 的 Preview bundle; `lipo` 和双架构 local smoke 均通过. smoke 还验证 Bridge 单 stdout envelope、artifact schema、旧 `parserVersion` cache rebuild 以及隔离临时目录的 install/upgrade/rollback; strict 模式对当前 Preview bundle 因包含 Python runtime 而 fail closed.
- Release-shaped universal preflight 已修复 Rust 静态 header 字符串造成的 `Bearer` 扫描误报; 合法 bundle 通过, 注入 synthetic bearer secret 仍被拒绝.

OpenSpec 当前进度为 41 项中的 39 项完成. 未完成的 2 项是发布环境相关证据, 不是本地 Rust/Swift 契约失败:

1. 7.3: universal binary、Developer ID、notarization/staple/spctl、安装升级、旧 cache 重建和 rollback.
2. 8.5: final parity、performance、security、Swift integration 和 Release cutover gates.

因此下一步架构讨论应以“Rust 已成为 Release 的唯一采集实现”为前提, 重点解决 Rust 内部的应用编排深度、Provider/credential 的接入 locality 以及刷新路径的可观测和资源控制, 不再设计 Python/Rust 双生产实现.
