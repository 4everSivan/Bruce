# `pricing_presentation` 模块单元测试规格 (`u_pricing_presentation_cases`)

> **module**: pricing_presentation ｜ **type**: unit_cases ｜ **updated_at**: 2026-11-02 ｜ **status**: active

## 1. 单元测试用例总表

| 用例 ID | 用例标题 | 关联功能点 | 场景类型 (`normal`/`boundary`/`exception`) | 目标源码符号 | 绑定测试函数 | 状态 |
|---|---|---|---|---|---|---|
| `UT-pricing_presentation-001` | 静态文案与双端对拍一致 | `FP-pricing_presentation-01` | `normal` | `pricing-presentation.js :: copy` | `test_ut_pricing_presentation_001_copy_parity` | `active` |
| `UT-pricing_presentation-002` | 当前目录副标题 | `FP-pricing_presentation-02` | `boundary` | `pricing-presentation.js :: currentCatalogSubtitle` | `test_ut_pricing_presentation_002_current_catalog_subtitle` | `active` |
| `UT-pricing_presentation-003` | 同步时间格式化 | `FP-pricing_presentation-03` | `normal` | `pricing-presentation.js :: timestamp` | `test_ut_pricing_presentation_003_sync_time_format` | `active` |
| `UT-pricing_presentation-004` | 同步状态机矩阵 | `FP-pricing_presentation-04` | `normal` | `pricing-presentation.js :: stageDisplay` | `test_ut_pricing_presentation_004_stage_display_matrix` | `active` |
| `UT-pricing_presentation-005` | 按钮可用性 | `FP-pricing_presentation-05` | `boundary` | `pricing-presentation.js :: isSyncButtonEnabled/isRestoreButtonEnabled` | `test_ut_pricing_presentation_005_button_enablement` | `active` |

## 2. 用例规格详情

### UT-pricing_presentation-001: 静态文案与双端对拍一致

- **关联功能点**：`FP-pricing_presentation-01`（静态文案对拍）
- **目标符号**：`apps/win/src/pricing-presentation.js :: copy`
- **场景类型**：`normal`
- **前置条件与夹具**：`tests/fixtures/pricing-sync-parity/cases.json` 的 `rows`
- **输入参数（Given / When）**：导出对象 `PP.copy`
- **预期结果与断言（Then）**：
  1. `caption`、`autoSyncTitle`、`autoSyncSubtitle` 与 fixture 相等
  2. `currentCatalogTitle`、`syncCatalogTitle`、`syncButton`、`restoreButton` 与 fixture 相等

### UT-pricing_presentation-002: 当前目录副标题

- **关联功能点**：`FP-pricing_presentation-02`（当前目录副标题）
- **目标符号**：`pricing-presentation.js :: currentCatalogSubtitle(source, modelCount)`
- **场景类型**：`boundary`
- **前置条件与夹具**：`pricing-sync-parity.cases.json` 的 `currentCatalog`；补充 `modelCount = 0` 与 `"abc"`
- **输入参数（Given / When）**：`("builtin", 95)`、`("github", 95)`、`("builtin", 0)`、`("github", "abc")`
- **预期结果与断言（Then）**：
  1. builtin 返回 `内置基线 · 95 款模型`
  2. 其他来源返回 `GitHub 已同步 · 95 款模型`
  3. 非法数量按 0 处理
  4. 非法来源不抛异常且走同步分支

### UT-pricing_presentation-003: 同步时间格式化

- **关联功能点**：`FP-pricing_presentation-03`（同步时间展示）
- **目标符号**：`pricing-presentation.js :: timestamp(iso, now)`
- **场景类型**：`normal`
- **前置条件与夹具**：`pricing-sync-parity.cases.json` 的 `lastSync`
- **输入参数（Given / When）**：同日、跨天、空值、非法 ISO 四组输入
- **预期结果与断言（Then）**：
  1. 同日输出 `今天 HH:mm`
  2. 跨天输出 `M月d日 HH:mm`
  3. 空值经 `lastSyncSubtitle` 输出 `上次同步 —`
  4. 非法 ISO 返回空字符串

### UT-pricing_presentation-004: 同步状态机矩阵

- **关联功能点**：`FP-pricing_presentation-04`（同步状态机）
- **目标符号**：`pricing-presentation.js :: stageDisplay(stage)`
- **场景类型**：`normal`
- **前置条件与夹具**：`pricing-sync-parity.cases.json` 的 13 条 `stages`
- **输入参数（Given / When）**：逐条传入 fixture 的 `stage`
- **预期结果与断言（Then）**：
  1. 每条输出的 `kind`/`text`/`detail`/`statusLine` 与 fixture 期望一致
  2. `failed` 的五种 reason 映射到对应中文提示
  3. 未知 kind 降级为 `{kind:"hidden", text:null}`

### UT-pricing_presentation-005: 按钮可用性

- **关联功能点**：`FP-pricing_presentation-05`（按钮可用性）
- **目标符号**：`pricing-presentation.js :: isSyncButtonEnabled/isRestoreButtonEnabled`
- **场景类型**：`boundary`
- **前置条件与夹具**：`pricing-sync-parity.cases.json` 的 `stages`
- **输入参数（Given / When）**：`{kind:"syncing"}`、`{kind:"idle"}`、`null`
- **预期结果与断言（Then）**：
  1. `syncing` 时两个按钮均返回 `false`
  2. 非 `syncing` 状态均返回 `true`
  3. `null` 输入不抛异常并返回 `true`
