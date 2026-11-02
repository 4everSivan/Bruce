# `provider_brand` 模块单元测试规格 (`u_provider_brand_cases`)

> **module**: provider_brand ｜ **type**: unit_cases ｜ **updated_at**: 2026-11-02 ｜ **status**: active

## 1. 单元测试用例总表

| 用例 ID | 用例标题 | 关联功能点 | 场景类型 (`normal`/`boundary`/`exception`) | 目标源码符号 | 绑定测试函数 | 状态 |
|---|---|---|---|---|---|---|
| `UT-provider_brand-001` | Agent glyph 覆盖 | `FP-provider_brand-01` | `normal` | `provider-brand.js :: window.BRUCE_PROVIDER_GLYPHS` | `test_ut_provider_brand_001_agent_glyph_coverage` | `active` |
| `UT-provider_brand-002` | 模型 glyph 覆盖 | `FP-provider_brand-02` | `normal` | 同上 | `test_ut_provider_brand_002_model_glyph_coverage` | `active` |
| `UT-provider_brand-003` | 几何结构合法 | `FP-provider_brand-03` | `boundary` | 同上 :: `{vb, shapes}` | `test_ut_provider_brand_003_glyph_geometry_integrity` | `active` |
| `UT-provider_brand-004` | 未知身份不回退到假图标 | `FP-provider_brand-04` | `exception` | 同上 :: `unknownAgents/unknownModels` | `test_ut_provider_brand_004_unknown_identity_absent` | `active` |

## 2. 用例规格详情

### UT-provider_brand-001: Agent glyph 覆盖

- **关联功能点**：`FP-provider_brand-01`（Agent 身份覆盖）
- **目标符号**：`apps/win/src/provider-brand.js :: window.BRUCE_PROVIDER_GLYPHS`
- **场景类型**：`normal`
- **前置条件与夹具**：`agent-brand-parity/cases.json` 的 `agents`；用 `node:vm` 加载生成文件
- **输入参数（Given / When）**：9 个 agent 的 `glyph`
- **预期结果与断言（Then）**：
  1. 每个非空 `glyph` 都是 glyph 表的键
  2. 表内条目数为 11
  3. 缺键时断言失败并带出 agent id

### UT-provider_brand-002: 模型 glyph 覆盖

- **关联功能点**：`FP-provider_brand-02`（模型身份覆盖）
- **目标符号**：同上
- **场景类型**：`normal`
- **前置条件与夹具**：`agent-brand-parity/cases.json` 的 `models`
- **输入参数（Given / When）**：10 个模型的 `glyph`
- **预期结果与断言（Then）**：
  1. 每个非空 `glyph` 都是 glyph 表的键
  2. 模型映射与 agent 映射使用同一张表

### UT-provider_brand-003: 几何结构合法

- **关联功能点**：`FP-provider_brand-03`（几何结构合法）
- **目标符号**：`provider-brand.js :: {vb, shapes}`
- **场景类型**：`boundary`
- **前置条件与夹具**：`provider_brand_fixtures.json` 的期望键集合
- **输入参数（Given / When）**：遍历全部 glyph 条目
- **预期结果与断言（Then）**：
  1. `vb` 为非空字符串
  2. `shapes` 为非空数组
  3. 每个 shape 为 `[string, number]`，path 非空

### UT-provider_brand-004: 未知身份不回退到假图标

- **关联功能点**：`FP-provider_brand-04`（未知身份回退）
- **目标符号**：`unknownAgents/unknownModels`
- **场景类型**：`exception`
- **前置条件与夹具**：`agent-brand-parity/cases.json`
- **输入参数（Given / When）**：`unknown-agent`、`cursor`、`gemini-3-pro`、`qwen3-coder`
- **预期结果与断言（Then）**：
  1. 这些标识不得作为 glyph 表的键
  2. 查表返回 `undefined`，由调用方保留原色点
