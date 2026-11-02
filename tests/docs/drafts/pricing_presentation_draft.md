# `pricing_presentation` 模块功能点与测试草稿

> **module**: pricing_presentation ｜ **type**: draft ｜ **updated_at**: 2026-11-02 ｜ **status**: active

## 1. 来源与模块边界

- **源文档路径**：`docs/devel/design/09-模型价格表远端同步.md`、`docs/official/设置中心与价格校准设计.md`
- **目标源码路径**：`apps/win/src/pricing-presentation.js`（`window.BrucePricingPresentation` / CJS 导出）
- **存量测试备份**：`_test_anything_backup/original_tests/tests/fixtures/pricing-sync-parity/cases.json`（已回填至 `tests/fixtures/pricing-sync-parity/cases.json`）
- **模块职责边界**：价格表设置页的纯表现层：文案、副标题、时间格式、同步状态机与按钮可用性。无 DOM、无网络；macOS 对应实现为 `PricingCatalogSyncPresentation.swift`，双端以共享 fixture 对拍。

## 2. 功能点拆解清单 (Functional Points)

| 功能点 ID | 功能名称 | 触发与输入约束 | 预期行为与输出 | 边界与异常规则 | 来源定位 |
|---|---|---|---|---|---|
| `FP-pricing_presentation-01` | 静态文案对拍 | 读取 `copy` 常量 | 标题/说明/按钮文案与 `pricing-sync-parity` 的 `rows` 逐字段一致 | 文案漂移即失败 | pricing-presentation.js:10-20 |
| `FP-pricing_presentation-02` | 当前目录副标题 | `source` + `modelCount` | `builtin` → `内置基线 · N 款模型`；其他 → `GitHub 已同步 · N 款模型` | `modelCount` 非数字按 0 处理 | pricing-presentation.js:54-61 |
| `FP-pricing_presentation-03` | 同步时间展示 | `lastSyncAt`（RFC3339 带偏移）、`now` | 同日 `今天 HH:mm`，跨天 `M月d日 HH:mm`；空值返回 `上次同步 —` | 非法 ISO 返回空串 | pricing-presentation.js:21-65 |
| `FP-pricing_presentation-04` | 同步状态机 | `stage = {kind, ...}` | `idle/syncing/upToDate/updated/restored/failed` 映射到固定 `kind/text/detail/statusLine` | 未知 kind 降级为隐藏 | pricing-presentation.js:104-149 |
| `FP-pricing_presentation-05` | 按钮可用性 | `stage.kind` | 非 `syncing` 时同步/恢复按钮均可用 | `null` stage 视为可用 | pricing-presentation.js:151-157 |

## 3. 候选测试点分流

### 3.1 单元测试候选 (`u_`)

| 候选编号 | 关联功能点 | 场景维度 (`normal`/`boundary`/`exception`) | 候选测试描述 | 来源类型 |
|---|---|---|---|---|
| `CAND-U-01` | `FP-pricing_presentation-01` | `normal` | `copy` 与 `fixture.rows` 全字段相等 | `legacy_tests` |
| `CAND-U-02` | `FP-pricing_presentation-02` | `boundary` | builtin/同步来源、0 与非法 modelCount 的副标题 | `both` |
| `CAND-U-03` | `FP-pricing_presentation-03` | `normal`/`exception` | 同日、跨天、空值、非法 ISO 四种时间输入 | `both` |
| `CAND-U-04` | `FP-pricing_presentation-04` | `normal` | 13 条 `stages` fixture 逐条对拍，含失败原因映射 | `legacy_tests` |
| `CAND-U-05` | `FP-pricing_presentation-05` | `boundary` | `syncing` 时按钮禁用，其余状态可用 | `legacy_tests` |

### 3.2 性能基准候选 (`b_`)

| 候选编号 | 关联功能点 | 性能热点原因 | 计划负载规模 | 关注指标 |
|---|---|---|---|---|
| `CAND-B-01` | `FP-pricing_presentation-04` | 状态机在每次刷新与倒计时 tick 时高频调用 | 13 条 stage × 2,000 轮 | `ops/sec`, `ns/op` |
| `CAND-B-02` | `FP-pricing_presentation-03` | 时间格式化在状态栏与设置页高频渲染 | 10,000 次 | `ops/sec`, `ns/op` |

## 4. 待确认与实现差异 (Gaps)

| 差异编号 | 涉及功能点 | 差异类型 (`unimplemented`/`conflict`/`missing_data`) | 详细说明与处置方式 |
|---|---|---|---|
| `GAP-pricing_presentation-01` | `FP-pricing_presentation-04` | `missing_data` | macOS 侧 Swift 实现不在 Node 可执行范围内；双端一致性依赖共享 fixture 与各自原生测试，本模块只覆盖 Windows 纯函数 |
