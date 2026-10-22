# 变更与核验卡池 (change/)

> **created**: 2026-09-23 ｜ **last-change**: 2026-10-20 ｜ **status**: active

## 1. 简介

C 卡承载缺陷修复、功能回调、参数或契约调整及重构，记录原因、前后差异、影响范围和验证证据。阶段能力建设按 [T 任务轨](../task/README.md) 执行。

日常直接使用本项目的模板和工具。共同路径、授权、校验结果与修复边界见 [文档中心](../../README.md)。

## 2. 索引

| 入口 | 用途 | 维护时机 |
|---|---|---|
| [变更卡模板](../../standards/change-template.json) | 复制生成真实 C 卡 | 建卡时替换示例字段 |
| [index.json](index.json) | `cards` 保存卡片路由，`topics` 关联设计主题 | 建卡、转状态、闭环和归档时 |
| [设计中心](../design/README.md) | 定位具体设计正文与主题 | 建卡前及规则回写时 |
| [待办池](../todo/README.md) | 接收尚未入轨事项 | 建卡登记后移出对应行 |
| [归档库](../../archive/README.md) | 本批次发布封箱 | 卡片 `closed` 且满足发布条件后 |

## 3. 建卡与状态规则

卡号从总账已有最大编号继续递增，如 `C001`；包含历史归档登记，跨版本不重置。最大号 +1 不是原子预占，并行合入须结合 `ID_DUPLICATE` 和 Git 冲突检查；撞号先修正卡号及引用，不得覆盖另一事项。

| 字段组 | 建卡时写什么 | 收口时补什么 |
|---|---|---|
| 身份与上下文 | `id`、`title`、真实发布批次 `version`、执行分支 `branch` | 与总账保持一致 |
| `target` / `design` | 模块、组件、具体设计正文及匹配主题，是否改变设计规则 | 必要时回写正文及 `rule_diff` |
| `why` / `changes` | 现象、原因、前后差异和影响 | 以实际修复校正描述 |
| `precheck` / `callback` | 实际适用的预检与前后回调命令 | 保存预检结果，按授权执行回调 |
| `verification` | 预定义各项 `true_if` / `false_if`，结果先留 `null` | 真实 `evidence`、`run_id`、结果、人工原话及 `signoff` |
| `sync` / `gate` | 保留模板默认值 | 真实提交、回写情况及工具记录的门禁结果 |

`target.design_doc` 和 `design.doc` 使用项目根目录相对路径，指向具体设计正文，不能指向 README；主题与正文的 `<!-- @topic: TopicName -->` 一致。命令使用必要路径不违反源码影响范围脱钩规则。

| 状态 | 含义 |
|---|---|
| `draft` / `pending` | 正在定义或等待执行 |
| `in_progress` | 正在修复与取证 |
| `rejected` | 人工明确驳回，保留审计并同卡返工 |
| `verified` | 业务核验与人工确认完成，目标状态预检通过 |
| `closed` | 合入、必要设计回写及 CHANGELOG 记账完成，关闭预检通过 |

## 4. 执行与收口

1. **建卡登记**：复制模板，填写目标和验收契约，在 `index.json.cards` 登记路径及同一状态；来自 todo 的事项同时删除原行。
2. **预检与修复**：在授权范围内运行 `precheck.command`。若已修复，保存证据并跳过重复编码，仍执行后续核验；否则运行适用回调、修复并补针对性回归。
3. **实测与确认**：逐项比对验收条件，记录命令、实际输出及 `local-YYYYMMDD-HH` 或纯数字 `run_id`。所有业务验收项满足后运行 `scripts/adflow-verify --card <卡号> --receipt`，以节点回执汇报并请求确认；人工明确确认后摘录真实 `user_quote` 与 `signoff`，不得用测试输出代替确认。
4. **预检 `verified`**：保持当前卡片及索引状态，执行下列命令；Exit 0 后再同步两处状态为 `verified`，以节点回执复核。

以下以 `C001` 为例，执行时使用当前真实卡号；命令均在项目根目录运行：

```bash
scripts/adflow-verify --card C001 --to verified --record
```

5. **合入与回写**：在合入已获授权的前提下完成合入，填写真实 `sync.commit` 并核对其为当前 HEAD 祖先。设计规则变化时回写正文，更新根目录 CHANGELOG 的 `[Unreleased]` 条目及总账主题关联；如实更新 `sync.design_pinned`、`sync.changelog`。
6. **预检 `closed`**：完成上述前提后执行下列命令；Exit 0 后同步卡片及索引为 `closed`，再以节点回执复核。尚未实际打 Tag 时不虚填 `sync.tag`。

```bash
scripts/adflow-verify --card C001 --to closed --record
```

每次预检 Exit 0 后，同步状态再运行下列命令复核，并把输出的节点回执按 [AGENTS.md](../../../AGENTS.md) 二.3 的格式转交人类（只填「未覆盖」「需要你」两行）。`--record` 只回写本卡真实 `gate`，不会变更卡片或索引状态；结构通过仍需人工核对业务证据。失败处理沿用 [共同校验规则](../../README.md#4-校验与收口)，不手改 gate 消除失败。

```bash
scripts/adflow-verify --card C001 --receipt
```

**驳回**：人工明确驳回后，同步卡片与索引为 `rejected`，在 `rejections` 追加日期、`reason` 和返工动作，并以节点回执确认驳回已登记；继续同卡修复、重新取证与确认，不占新号或退回 todo。

**Hotfix**：S1/P0 故障可在明确授权范围内先修后补，补卡标记 `is_hotfix: true`；故障恢复后 24 小时内补齐卡片、核验、必要设计回写与 CHANGELOG。紧急性不扩大部署、推送或代签权限。

---

## 附：项目既有约定（升级保留）

> 本节为 Bruce 项目在 ad-flow 早期版本下积累的项目级约定，规范升级时逐字保留；其余受管章节已同步至 v1.5.0。

### 3.1 `topics[].changes` 语义（TD-011 定稿，2026-10-16）

`index.json` 的每个 topic 是**一篇现行设计文档的变更总账**：

- **下限（机器可校验，强制）**：该数组**必须包含所有以该设计文档为 `design.doc`（即卡片 `topic` 字段所指）的卡**。此不变式由 `scripts/check-change-ledger.mjs` 在每次 `verify-local.sh` 中校验，违反即门禁失败。
- **上限（人工维护，可选）**：允许把**非主卡归属、但确实改过该设计文档**的卡一并登记，使该文档的总账完整可读（跨文档多归属）。判定依据以 git 历史或卡内证据为准，不做机器强校验。
- **卡片自身只有一个 `topic` 字段**：它表示主卡归属，因此「数组 ⊋ 主卡归属集合」是合法且预期的（例如 C055 主卡归属为 `TokenUsage`，同时因改写了 design/04 而登记在 `PricingEngine`）。
- **历史缺口**：该语义此前未写明，导致 C039/C040/C041 声明了 `topic` 却未登记进数组，且 design/04 回链的 `PricingEngine` topic 在总账中根本不存在（均已于 C055 修复）。
