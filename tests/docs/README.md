# Bruce 测试文档中心 (tests/docs/)

> **module**: global ｜ **type**: index ｜ **updated_at**: 2026-11-02 ｜ **status**: active

## 1. 测试体系概览与快速入口

- **受管技能版本**：`test-anything v0.1.0`
- **技术栈与运行器**：`javascript (Node.js 25, ESM)` + `node:test` / `node:perf_hooks`
- **标准执行命令**：
  - 查看帮助：`$test-anything help`（或 `--help` / `-h`）
  - 生成/更新用例：`$test-anything create`（或裸调 `$test-anything`）
  - 全量测试：`$test-anything run`
  - 单元测试：`$test-anything run unittest`
  - 基准测试：`$test-anything run benchmark`

> 本套件覆盖跨端契约与 Windows 纯函数层；Rust Collector 与 Swift Harness 仍以 `zsh scripts/verify-local.sh` 为准。既有共享 fixture 已按原路径保留在 `tests/fixtures/`，Rust `include_str!`、Swift Harness 与 `scripts/check-collector-fixtures.sh` 无需改路径。

## 2. 模块测试资产矩阵

| 模块 (`module`) | 功能点草稿 (`drafts/`) | 测试计划 (`plans/`) | 单测规格 (`cases/u_*`) | 基准规格 (`cases/b_*`) | 单测数 / 基准数 | 最新运行状态 |
|---|---|---|---|---|---|---|
| `pricing_catalog` | [pricing_catalog_draft.md](drafts/pricing_catalog_draft.md) | [pricing_catalog_plan.md](plans/pricing_catalog_plan.md) | [u_pricing_catalog_cases.md](cases/u_pricing_catalog_cases.md) | [b_pricing_catalog_cases.md](cases/b_pricing_catalog_cases.md) | 4 / 1 | not_run |
| `pricing_presentation` | [pricing_presentation_draft.md](drafts/pricing_presentation_draft.md) | [pricing_presentation_plan.md](plans/pricing_presentation_plan.md) | [u_pricing_presentation_cases.md](cases/u_pricing_presentation_cases.md) | [b_pricing_presentation_cases.md](cases/b_pricing_presentation_cases.md) | 5 / 2 | not_run |
| `artifact_contract` | [artifact_contract_draft.md](drafts/artifact_contract_draft.md) | [artifact_contract_plan.md](plans/artifact_contract_plan.md) | [u_artifact_contract_cases.md](cases/u_artifact_contract_cases.md) | [b_artifact_contract_cases.md](cases/b_artifact_contract_cases.md) | 5 / 1 | not_run |
| `quota_policy_contract` | [quota_policy_contract_draft.md](drafts/quota_policy_contract_draft.md) | [quota_policy_contract_plan.md](plans/quota_policy_contract_plan.md) | [u_quota_policy_contract_cases.md](cases/u_quota_policy_contract_cases.md) | [b_quota_policy_contract_cases.md](cases/b_quota_policy_contract_cases.md) | 4 / 1 | not_run |
| `provider_brand` | [provider_brand_draft.md](drafts/provider_brand_draft.md) | [provider_brand_plan.md](plans/provider_brand_plan.md) | [u_provider_brand_cases.md](cases/u_provider_brand_cases.md) | [b_provider_brand_cases.md](cases/b_provider_brand_cases.md) | 4 / 1 | not_run |

## 3. 全局计划与最新报告导航

- **全局测试总计划**：[plans/test_plan.md](plans/test_plan.md)
- **最新全量汇总报告**：[reports/all_report_latest.md](reports/all_report_latest.md)
- **最新单元测试报告**：[reports/u_report_latest.md](reports/u_report_latest.md)
- **最新基准测试报告**：[reports/b_report_latest.md](reports/b_report_latest.md)

## 4. 存量测试接管说明

- 原 `tests/`（44 个文件：36 个共享 fixture、4 个基准基线、4 个视觉资源）已原子迁移至 `_test_anything_backup/original_tests/tests/`，备份只读。
- 共享 fixture 与视觉资源已按原相对路径回填到新 `tests/fixtures/`、`tests/visual/`；4 个基准基线落在 `tests/fixtures/legacy_benchmark_baselines/`。
- 既有 Rust/Swift/Windows 原生测试代码未迁移，仍由各自 runner 执行。
