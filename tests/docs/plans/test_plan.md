# 全局测试总计划 (Test Plan)

> **module**: global ｜ **type**: test_plan ｜ **updated_at**: 2026-11-02 ｜ **status**: active

## 1. 目标技术栈与执行环境

- **主语言与框架**：`javascript (Node.js 25, ESM)` + 内置 `node:test` / `node:assert/strict` / `node:perf_hooks`
- **单元测试运行命令**：`TMPDIR=tests/tmp node --test tests/unit/`
- **基准测试运行命令**：`TMPDIR=tests/tmp node tests/benchmark/b_run_all.bench.mjs`
- **运行期临时目录**：`tests/tmp/`（所有临时文件、基准原始 JSON 与缓存强制落盘于此）

本套件是 **跨端契约与 Windows 纯函数层** 的独立测试资产，不替代项目原生测试：

| 原生测试体系 | 命令 | 本套件关系 |
|---|---|---|
| Rust Collector 单测 | `cargo test --manifest-path core/collector/Cargo.toml --workspace` | 不被替代；共享 fixture 已按原路径回填 |
| Swift Harness | `zsh scripts/verify-local.sh` | 不被替代；`tests/fixtures/` 路径保持不变 |
| Windows 前端测试 | `node --test apps/win/tests/` | 互补：本套件从仓库根统一驱动契约与纯函数 |

## 2. 模块测试覆盖总表

| 模块 (`module`) | 模块计划 | 单测规格 (`u_`) | 基准规格 (`b_`) | 单测代码 (`unit/`) | 基准代码 (`benchmark/`) | 公共夹具 (`fixtures/`) |
|---|---|---|---|---|---|---|
| `pricing_catalog` | [pricing_catalog_plan.md](pricing_catalog_plan.md) | [u_pricing_catalog_cases.md](../cases/u_pricing_catalog_cases.md) | [b_pricing_catalog_cases.md](../cases/b_pricing_catalog_cases.md) | `tests/unit/u_pricing_catalog.test.mjs` | `tests/benchmark/b_pricing_catalog.bench.mjs` | `tests/fixtures/pricing_catalog_fixtures.json` |
| `pricing_presentation` | [pricing_presentation_plan.md](pricing_presentation_plan.md) | [u_pricing_presentation_cases.md](../cases/u_pricing_presentation_cases.md) | [b_pricing_presentation_cases.md](../cases/b_pricing_presentation_cases.md) | `tests/unit/u_pricing_presentation.test.mjs` | `tests/benchmark/b_pricing_presentation.bench.mjs` | `tests/fixtures/pricing_presentation_fixtures.json` |
| `artifact_contract` | [artifact_contract_plan.md](artifact_contract_plan.md) | [u_artifact_contract_cases.md](../cases/u_artifact_contract_cases.md) | [b_artifact_contract_cases.md](../cases/b_artifact_contract_cases.md) | `tests/unit/u_artifact_contract.test.mjs` | `tests/benchmark/b_artifact_contract.bench.mjs` | `tests/fixtures/artifact_contract_fixtures.json` |
| `quota_policy_contract` | [quota_policy_contract_plan.md](quota_policy_contract_plan.md) | [u_quota_policy_contract_cases.md](../cases/u_quota_policy_contract_cases.md) | [b_quota_policy_contract_cases.md](../cases/b_quota_policy_contract_cases.md) | `tests/unit/u_quota_policy_contract.test.mjs` | `tests/benchmark/b_quota_policy_contract.bench.mjs` | `tests/fixtures/quota_policy_contract_fixtures.json` |
| `provider_brand` | [provider_brand_plan.md](provider_brand_plan.md) | [u_provider_brand_cases.md](../cases/u_provider_brand_cases.md) | [b_provider_brand_cases.md](../cases/b_provider_brand_cases.md) | `tests/unit/u_provider_brand.test.mjs` | `tests/benchmark/b_provider_brand.bench.mjs` | `tests/fixtures/provider_brand_fixtures.json` |

## 3. 全局夹具与隔离策略

- 外部网络、第三方服务与非受控 I/O 一律通过 `tests/fixtures/` 隔离；本套件不发起任何网络请求。
- 既有共享 fixture（`tests/fixtures/{pricing-sync-parity,artifacts,bridge,quota-*-parity,refresh-policy-parity,agent-brand-parity}/`）保持原路径，供 Rust `include_str!`、Swift Harness 与 `scripts/check-collector-fixtures.sh` 继续消费。
- 运行期产生的所有临时文件与基准原始数据统一输出至 `tests/tmp/`（已加入 `.gitignore`）。
- 基准使用固定迭代数与预热轮次，只做同一机器上的相对比较；不宣称跨机器绝对性能。
