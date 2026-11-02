# `provider_brand` 模块功能点与测试草稿

> **module**: provider_brand ｜ **type**: draft ｜ **updated_at**: 2026-11-02 ｜ **status**: active

## 1. 来源与模块边界

- **源文档路径**：`docs/devel/design/06-Agent用量分析与Token统计工作台.md`、`docs/assets/provider-icons/SOURCES.json`
- **目标源码路径**：`apps/win/src/provider-brand.js`（`window.BRUCE_PROVIDER_GLYPHS`，由 `scripts/gen-provider-glyphs.mjs` 生成）与 `tests/fixtures/agent-brand-parity/cases.json`
- **存量测试备份**：`_test_anything_backup/original_tests/tests/fixtures/agent-brand-parity/`（已回填至新 `tests/fixtures/`）
- **模块职责边界**：Windows 设置页订阅行的品牌徽章几何表，以及双端 Agent/模型身份表对拍。覆盖 glyph 键存在性、几何结构、未知身份回退；不覆盖 Swift `AgentBrandPalette` 的渲染。

## 2. 功能点拆解清单 (Functional Points)

| 功能点 ID | 功能名称 | 触发与输入约束 | 预期行为与输出 | 边界与异常规则 | 来源定位 |
|---|---|---|---|---|---|
| `FP-provider_brand-01` | Agent 身份覆盖 | `agent-brand-parity.agents[].glyph` | 每个已登记 glyph ID 都存在于 `BRUCE_PROVIDER_GLYPHS` | 缺失即两端徽章漂移 | `apps/win/src/provider-brand.js`；design/06 |
| `FP-provider_brand-02` | 模型身份覆盖 | `agent-brand-parity.models[].glyph` | 同上，模型映射的 glyph ID 也必须在表内 | 未知 glyph 不生成假图标 | 同上 |
| `FP-provider_brand-03` | 几何结构合法 | 遍历 glyph 表 | 每项含非空 `vb` 字符串与 `shapes` 数组；每 shape 为 `[path, opacity]` 且 opacity 为数字 | 空 shapes 或非字符串 path 视为生成损坏 | `provider-brand.js` 生成契约 |
| `FP-provider_brand-04` | 未知身份回退 | `unknownAgents` / `unknownModels` | 未登记身份不得出现在 glyph 表中 | 出现即为误映射 | `agent-brand-parity.cases.json` |

## 3. 候选测试点分流

### 3.1 单元测试候选 (`u_`)

| 候选编号 | 关联功能点 | 场景维度 (`normal`/`boundary`/`exception`) | 候选测试描述 | 来源类型 |
|---|---|---|---|---|
| `CAND-U-01` | `FP-provider_brand-01` | `normal` | 9 个 Agent 的 glyph ID 均存在 | `legacy_tests` |
| `CAND-U-02` | `FP-provider_brand-02` | `normal` | 10 个模型映射的 glyph ID 均存在 | `legacy_tests` |
| `CAND-U-03` | `FP-provider_brand-03` | `boundary` | 所有 glyph 的 `vb` 与 `shapes` 结构合法 | `docs` |
| `CAND-U-04` | `FP-provider_brand-04` | `exception` | `unknown-agent`/`cursor`/`gemini-3-pro` 等未登记身份不在表中 | `legacy_tests` |

### 3.2 性能基准候选 (`b_`)

| 候选编号 | 关联功能点 | 性能热点原因 | 计划负载规模 | 关注指标 |
|---|---|---|---|---|
| `CAND-B-01` | `FP-provider_brand-01` | 工作台逐行渲染时按 Agent/模型键查表 | 19 个键 × 20,000 轮 | `ops/sec`, `ns/op` |

## 4. 待确认与实现差异 (Gaps)

| 差异编号 | 涉及功能点 | 差异类型 (`unimplemented`/`conflict`/`missing_data`) | 详细说明与处置方式 |
|---|---|---|---|
| `GAP-provider_brand-01` | `FP-provider_brand-01` | `missing_data` | 生成器 `scripts/gen-provider-glyphs.mjs` 的输出与 `docs/assets/provider-icons/SOURCES.json` 的许可证台账需人工复核；本模块只校验结构一致性与身份覆盖 |
