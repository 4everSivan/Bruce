# Rust Collector requirement acceptance evidence

记录日期: 2026-08-21.

本文件汇总当前可复现的本地证据. “通过”只表示对应本地或 fixture 门禁已通过; 需要 Developer ID、notarization 或真实安装介质的项目不会被本地结果替代.

## Requirement matrix

| Requirement | 当前状态 | 证据 | 备注 |
|---|---|---|---|
| Python/Rust differential fixtures strict | 通过 | `python3 scripts/differential-collector.py --request tests/fixtures/bridge/agent-usage/request-valid.json --rust rust/Bruce-collector/target/debug/Bruce-collector`; `zsh scripts/verify-local.sh` | artifact/status/diagnostic、credential update/challenge 和 secret scan 已覆盖, parity failures=`0`. |
| Cold/warm/account-scale performance matrix | 通过 | `python3 scripts/benchmark-collector-matrix.py --rust rust/Bruce-collector/target/release/matrix-fixture --runs 5 --strict`; [benchmark-evidence.md](./benchmark-evidence.md) | 30 个场景、5 次/场景; parity/invariant/target failures 均为 `0`; `disk_read_bytes` 以两端一致的 `logical_source_bytes` 口径测得, warm unchanged Rust 为 `0`. |
| Rebuildable incremental cache | 通过 | Rust local tests; benchmark cold/warm/append/rewrite stats; `zsh scripts/collector-release-smoke.sh dist/Bruce.app --local-preview` | warm unchanged 不解析 JSONL; append 只读追加; rewrite/truncate 失效并重建; smoke 还验证旧 `parserVersion` entry 会 rebuild; cache 使用临时文件 + atomic rename. |
| External SQLite read-only and bounded | 通过 | `cargo test --workspace`; `zsh scripts/verify-local.sh` | schema capability、只读 URI、参数化查询和 bounded rows 的现有测试通过. |
| Explicit refresh resource budgets | 通过 | Rust runtime/application tests; full workspace clippy/test | local/network/account queue 有界; account-scale HTTP 请求严格为 `1/10/64`, credential refresh=`0`. |
| Resource metrics without sensitive data | 通过 | `scripts/check-collector-fixtures.py`; matrix JSON | fixture scan `secretFindings=[]`; metrics 只包含计数、时长、大小和 reason, 不含 token/raw session. |
| Rust Bridge v1 process seam | 通过 | Rust Bridge tests; `CollectorRunnerHarness`; `PanelViewModelHarness` | 单 stdout envelope、runId、超时/取消和错误边界通过. |
| Release runtime does not fallback to Python | 本地通过 | `Bruce_validate_release_bundle`; release Swift executable + universal Rust preflight; strict `collector-release-smoke.sh` fail-closed check; `zsh scripts/build-test-app.sh` | release-shaped bundle scan 通过, Python fallback marker 和 synthetic bearer secret 均被拒绝; 当前 Preview bundle 含 Python runtime 时 strict smoke 明确拒绝; 尚未等价于签名 Release 验收. |
| Artifact/failure semantics compatible | 通过 | differential runner; provider success/failure/credential-expired matrix | provider failure 保留 `partial`; credential expiry 不发 HTTP, 诊断可见. |
| Swift remains App credential owner | 通过 | `zsh scripts/verify-local.sh`; Onboarding/CollectorRunner harnesses | Rust 只返回 validated updates/challenges, Swift 负责 Keychain 写回. |
| Signed universal binary and notarization | 部分通过, 签名/公证阻塞 | `BRUCE_RUST_TARGET_ARCHS="arm64 x86_64" zsh scripts/build-test-app.sh`; `lipo -info`; strict smoke | universal Rust binary 已实际生成并通过双架构 smoke; `xcrun notarytool` 可用但当前没有 Developer ID identity、notary credentials/API key 和可通过 Gatekeeper 的签名. |
| Installation, upgrade, old-cache rebuild, rollback | 本地 Preview 通过, Release 待发布环境 | `collector-release-smoke.sh` | 隔离临时 Applications 目录已验证 install/upgrade/rollback 和 old-cache rebuild; 仍需在 signed/notarized Release artifact 上完成真实安装介质演练. |

## Local gate summary

```text
Python pytest: 261 passed
Rust workspace tests: passed
Rust clippy (-D warnings): passed
Swift build and harnesses: passed
differential parity: PARITY OK
fixture security scan: 15 fixtures, secretFindings=[]
benchmark matrix: 30 cases x 5 runs, parity=0, invariants=0, targets=0
collector release smoke: Preview install/upgrade/rollback/cache rebuild passed
```

## Release cutover decision

当前结论: **Release cutover not ready**.

本地 Rust/Swift 契约和性能门禁已通过, 7.5 已完成“逐条证据 + readiness 决策”, 决策结果为 not ready. 7.3 的 Developer ID、notarization/staple/spctl 和 signed artifact 安装证据仍缺失, 因此 7.3、8.5 保持未完成, 直到具备发布凭证和真实安装环境后再重新判定.
