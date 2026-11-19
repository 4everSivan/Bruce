# Agent 请求日志设计方案

<!-- @topic: RequestLog -->
> **created**: 2026-11-19 ｜ **last-change**: 2026-11-19 ｜ **status**: baseline
> **文档ID**: DESIGN-REQUESTLOG ｜ **状态**: 现行基线（2026-11-19 维护者确认开工）
> **最后更新**: 2026-11-19 ｜ **所属总体**: [00-系统总体设计.md](00-系统总体设计.md) ｜ **对应 Topic**: `RequestLog`
> 📌 **关联设计**: [01-数据采集与多模型计费引擎.md](01-数据采集与多模型计费引擎.md)（观测、去重键与增量缓存）｜ [06-Agent用量分析与Token统计工作台.md](06-Agent用量分析与Token统计工作台.md)（工作台承载）｜ [15-Antigravity接入.md](15-Antigravity接入.md)（本机来源与 Token 口径）

---

## 1. 简介

Bruce 现有用量链路只产出**聚合桶**（日 / 月 / 周 / 模型 / 小时 / 工程），回答「某天某模型用了多少 Token」，无法回答「具体哪一次请求、什么时间、用了哪个模型、花了多少、是否成功」。cc-switch 的「请求日志」把这个问题做成了请求粒度的用量台账：一行对应一次模型响应，保存 Token、费用、耗时与状态，不保存对话正文。

本方案为 Bruce 定义同类能力，但**不复刻 cc-switch 的本地代理**。Bruce 是只读监控工具，数据全部来自本机 Agent 已经落盘的会话记录；请求日志是聚合历史的**下钻视图**，不是替代品。

**当前状态**：2026-11-19 维护者确认前端骨架并下达「开工」，本文转为现行基线；实现由 T34–T38 承接，代码交付与验收证据以任务卡为准。

---

## 2. 索引

- 文档 ID：`DESIGN-REQUESTLOG`
- 所属总体：[00-系统总体设计.md](00-系统总体设计.md)
- 对应主题：`RequestLog`
- 关联设计：
  - [01-数据采集与多模型计费引擎.md](01-数据采集与多模型计费引擎.md)（`TokenUsage`）：观测值、去重键、三套增量缓存与价卡；
  - [06-Agent用量分析与Token统计工作台.md](06-Agent用量分析与Token统计工作台.md)（`AgentAnalytics`）：设置中心工作台的前端承载；
  - [15-Antigravity接入.md](15-Antigravity接入.md)（`AntigravityUsage`）：新增本机来源与 Token 口径。
- 执行记录：[变更总账 (RequestLog)](../change/index.json#RequestLog)、[任务总账](../task/index.json)
- 外部参考：cc-switch 4.0.35（MIT）`src-tauri/src/database/schema.rs`、`services/session_usage.rs`、`services/usage_stats.rs`、`database/dao/usage_rollup.rs`；仅借鉴数据模型与处理策略，不复制代码。

---

## 3. 规范

### 3.1 定位与边界

1. **请求粒度用量台账**：一行 = 一次已落盘的模型响应；字段是派生数值与标识，不是原始请求报文。
2. **只读本机会话**：不启动本地代理、不拦截 Agent 网络请求、不修改任何 Agent 配置或凭据。
3. **不保存内容**：不保存 prompt、response、工具调用内容、文件路径、session id 或凭据；工程字段只保留目录名。
4. **独立存储**：请求日志写入独立 SQLite，不混入 `usage-history-v1.sqlite`。历史台账是不可再生资产，请求日志是可再生资产，两者的保留策略、故障降级与语义不同。
5. **下钻而非替代**：聚合 KPI、趋势、模型构成仍以现有 artifact 为唯一事实源；请求日志只提供逐条明细。

### 3.2 目标

| 编号 | 目标 |
|---|---|
| G1 | 为支持的 Agent 产出逐请求明细：时间、模型、输入/输出/缓存 Token、费用、工程、状态 |
| G2 | 复用现有增量缓存与去重键，不新增第二次会话解析、不新增独立游标体系 |
| G3 | 请求日志可幂等重放：同一轮重复扫描不产生重复行，删除请求库后可从热缓存重建 |
| G4 | 明细保留 30 天，支持按时间、Agent、模型、状态筛选与分页查询 |
| G5 | 查询失败或请求库不可用时，不影响菜单栏刷新与聚合 artifact 发布 |
| G6 | 与聚合口径一致：同一窗口内请求行 Token 合计应等于该 Agent 的聚合 Token |

### 3.3 非目标

1. **不做代理记账**：不实现 cc-switch 的本地路由、转发、故障转移或 `proxy_request_logs` 的 `proxy` 数据源。
2. **不记录失败请求**：会话日志通常只保存成功响应；未落盘的 4xx/5xx、超时与流中断不在本能力范围内，UI 必须明示「不包含未落盘的失败请求」。
3. **不一次性覆盖全部 Agent**：首批只做请求键可靠的三源（Claude Code、Codex、Antigravity）；SQLite 源与无稳定 ID 的源放二期。
4. **不做请求内容检索**：没有全文搜索、没有 prompt 回放、没有对话预览。
5. **不替代额度查询**：请求日志不参与订阅额度、预警或出口校验。
6. **不在首版做 Windows UI**：collector 与查询协议跨平台；Windows 前端另卡对齐。

### 3.4 功能需求

| 编号 | 需求 | 说明 |
|---|---|---|
| R1 | 逐请求采集 | 每个可计量的已落盘响应产出一行；Token 全零的行跳过 |
| R2 | 去重与幂等 | 同一请求重复扫描只保留一行；流式写入的同一 message 以最终值为准 |
| R3 | 费用 | 复用聚合链路的价卡与分档规则；未定价记 NULL，不伪造 0 |
| R4 | 保留 | 30 天明细；过期行直接删除，不做二次汇总（聚合历史已存在） |
| R5 | 查询 | 时间范围、Agent、模型、状态筛选；分页；按时间倒序 |
| R6 | 详情 | request id 可复制、原始模型、计价模型、Token 语义、工程、数据来源、保真度 |
| R7 | 降级 | 请求库打开/写入/查询失败只产生信息级诊断或内联错误，不改变 envelope |
| R8 | 重建 | 请求库可删除重建；JSONL / Codex / Antigravity 来源在缓存命中时仍可重放 |

### 3.5 非功能约束

1. **性能**：热刷新从缓存重放请求行，30 天量级（本机约数万行）应在 100 ms 量级完成写入；超过 200 ms 时再引入「只写变更文件 + 定期全量校准」，不在首版过度设计。
2. **存储**：请求库独立，WAL，`busy_timeout` 3 秒；目录 `0700`、文件 `0600`；30 天自然日截止。
3. **内存**：每个来源在扫描期间最多保留 50,000 条请求行；超出时按时间倒序截断并附信息级说明，避免冷扫描峰值失控。
4. **隐私**：请求键是 hash；工程只存 basename；不存 session id；不读会话正文进入任何持久化文件。
5. **一致性**：请求行使用与 `UsageSample` 相同的归一化 Token 口径；不允许另写一套「input 减 cache / output 加 reasoning」。
6. **可观测**：写入数量、截断数量、清理数量、失败原因进入信息级诊断；不进入菜单栏故障态。

### 3.6 输入输出与失败条件

**存储路径**：

- macOS：`~/Library/Application Support/Bruce/request-log-v1.sqlite`
- Windows：`%LOCALAPPDATA%\Bruce\request-log-v1.sqlite`

**写入输入**：现有本机扫描轮产出的 `RequestObservation` 集合 + `PricingTable` + 当前时间。

**查询输入**：Bridge `module=request-log` 的只读请求，包含 `home`、时间范围、Agent 列表、模型、状态、分页。

**查询输出**：`total / page / pageSize / entries[] / generatedAt`。

**失败条件**：

| 条件 | 行为 |
|---|---|
| 请求库不存在 | 写入轮创建；查询返回空页并附 notice |
| 请求库 schema 版本未知或损坏 | 不删除、不截断；信息级诊断；查询返回错误，UI 保留上次结果 |
| 写入超时 / busy | 跳过本轮写入，保留已有数据，下一轮重试 |
| 单条请求字段异常 | 跳过该条并计数，不影响整轮 |
| 查询参数非法 | Bridge 返回协议错误，不执行 SQL |

---

## 4. 设计详情

### 4.1 架构与行为

```text
Agent 会话文件
   │
   ▼
collector-local 适配器（现有解析 / 去重 / 增量缓存，不变）
   │
   ├── UsageContribution ──────────────► usage-history-v1.sqlite ─► artifact ─► 现有 KPI/趋势
   │
   └── RequestObservation（新增，复用 dedupe key + 归一化 Token）
              │
              ▼
       request-log-v1.sqlite（独立库，30 天，WAL）
              ▲ 只读查询
              │
App 工作台「请求日志」──► Bruce-collector(module=request-log) ──► 单页 JSON
```

**行为顺序**：

1. 正常本机扫描轮启动，按现有 `local_source_jobs` 并行扫描；
2. 适配器在产生 `UsageSample` 的同一处判断是否有稳定请求键；有则同时产出 `RequestObservation`；
3. 扫描结果进入 `assemble`；`resolve_pricing_table` 完成后统一写请求库；
4. 请求库按 30 天截止清理过期行；
5. 前端按需调用查询模块；查询不扫描会话、不写库。

**关键设计**：请求行不是第二次解析的产物，而是现有观测流的**旁路输出**。这保证请求日志与聚合共用同一套消息去重、流式合并、Codex 增量计费与 Antigravity step 覆盖规则，避免两套口径漂移。

### 4.2 核心业务规则

<!-- @topic: RequestLog -->

#### 4.2.1 数据模型

`request-log-v1.sqlite`，`PRAGMA user_version = 1`：

```sql
CREATE TABLE request_log (
    agent_id            TEXT NOT NULL,
    request_key         TEXT NOT NULL,    -- 32 位十六进制，观测 dedupe key 的 128bit hash
    occurred_at         INTEGER NOT NULL, -- epoch millis
    model               TEXT,             -- 归一化模型；计价与聚合使用
    raw_model           TEXT,             -- 原始显示名，如 Gemini 3.6 Flash (High)
    project             TEXT,             -- 仅工程名，不存完整路径
    input               INTEGER NOT NULL DEFAULT 0,
    output              INTEGER NOT NULL DEFAULT 0,
    cache_read          INTEGER NOT NULL DEFAULT 0,
    cache_creation      INTEGER NOT NULL DEFAULT 0,
    cache_creation_1h   INTEGER NOT NULL DEFAULT 0,
    cost_usd            REAL,             -- NULL = 未定价
    pricing_model       TEXT,             -- 写入时实际命中的价卡键
    status_code         INTEGER NOT NULL DEFAULT 200,
    fidelity            TEXT NOT NULL DEFAULT 'exact', -- exact / estimated
    latency_ms          INTEGER,          -- NULL = 无计时
    first_token_ms      INTEGER,          -- NULL = 无计时
    PRIMARY KEY (agent_id, request_key)
);

CREATE INDEX idx_request_log_time        ON request_log(occurred_at DESC);
CREATE INDEX idx_request_log_agent_time  ON request_log(agent_id, occurred_at DESC);
CREATE INDEX idx_request_log_model_time  ON request_log(model, occurred_at DESC);
CREATE INDEX idx_request_log_status_time ON request_log(status_code, occurred_at DESC);
```

字段口径：

- `input / output / cache_read / cache_creation` 与 `UsageSample` 相同，是**归一化后**的四象限，不是厂商原始字段；
- `cache_creation_1h` 只对 Anthropic 1 小时 TTL 缓存有意义，其余来源为 0；
- `cost_usd` 在写入时计算，价格变更不回改历史行；
- `fidelity`：`exact` 表示来源给出精确 Token 计数；`estimated` 留给 Grok 等估算源；
- `model` 与 `raw_model` 分离，既支持模型归并/计价，也保留原始显示名。

#### 4.2.2 请求键与来源覆盖

请求键复用现有观测去重键，不新增缓存字段：

| Agent | 请求键来源 | 首版 | 说明 |
|---|---|---|---|
| Claude Code | `DedupeKey` = hash(`claude-message`, `message.id`) 的 128bit | ✓ | 同一 message 多行流式写入，取最终值 |
| Codex | `r:<response_id>`；旧版无 response_id 时用 `t:<timestamp>:<usage>` 签名 | ✓ | 与现有 Codex 副本合并共用同一键 |
| Antigravity | hash(`antigravity`, `session_id:step_index`) | ✓ | transcript 同 step 后写覆盖 |
| ZCode | `model_usage` 行身份（session + started_at + model + tokens） | 二期 | SQLite 缓存当前只存聚合，需要单独补观测 |
| OpenCode | `message` 表 id / time + model | 二期 | 同上 |
| CodeBuddy | `DedupeKey` = hash(codebuddy 需跨文件键) | 二期 | JSONL 观测已具备 |
| DSH | 现有消息 id / 去重键 | 二期 | 需确认 dsh 观测是否带稳定键 |
| Kimi Code / Kimi Work / Pi | 当前 `dedupe_key = None` | 二期 | 需合成启发式键，或明确不支持 |
| Grok | 时间戳 + 估算用量 | 二期 | `fidelity = estimated`，UI 标注估算 |

首版只承诺三源。其余来源在 UI 显示「该 Agent 暂无逐请求明细」，不伪造空行。

#### 4.2.3 采集与写入

1. **旁路产出**：`UsageContributionBuilder` 增加 `record_request(sample, request_meta)`；适配器在调用 `record` 的同一处调用。没有稳定键的适配器不调用。
2. **缓存命中也要重放**：JSONL 聚合器在 `absorb` / `finish` 时从缓存观测重新产出 `RequestObservation`；Codex 从 `CachedUsageObservation` 产出；Antigravity 从独立缓存产出。这样删除请求库后，热缓存仍能重建明细。
3. **来源结果携带**：`SourceScan` / `LocalAgentResult` 增加 `requests: Vec<RequestObservation>`；`assemble` 在价卡就绪后统一落库。
4. **截断**：每个来源保留最近 30 天、最多 50,000 条；按 `occurred_at` 倒序保留，超出计数进入信息级说明。
5. **单事务**：一轮扫描的全部来源在一个事务内写入；失败整轮回滚，不留下半轮数据。
6. **失败隔离**：请求库失败只产生 `LOCAL_REQUEST_LOG_UNAVAILABLE` 信息级诊断；artifact 仍发布。

#### 4.2.4 幂等与更新规则

使用 `INSERT ... ON CONFLICT(agent_id, request_key) DO UPDATE`，只在以下条件更新：

1. 新 Token 总量大于旧值（流式响应继续增长）；
2. 旧 `cost_usd IS NULL` 且新值可计价；
3. 旧 `status_code` 非终态且新值为 200（首版均为 200，预留给二期错误状态）。

其余情况保持旧行。**禁止**把已落库的 Token 改小；Antigravity step 覆盖若出现修正值，按 `max` 合并，不向下覆盖。

不需要 cc-switch 式的 `session_usage_dedup` 墓碑表：写入前按 30 天截止过滤，旧行即使被重放也不会重新插入；主键本身保证幂等。

#### 4.2.5 保留与清理

- 保留窗口：当前本地自然日向前 30 天（含今日），与查询上限一致；
- 每轮写入后执行 `DELETE FROM request_log WHERE occurred_at < cutoff`；走时间索引；
- 不做二次 rollup：30 天前的聚合数据已在 `usage-history-v1.sqlite`；
- 每周一次 `PRAGMA incremental_vacuum`（或等价维护），避免频繁 `VACUUM`；
- 请求库可删除：删除后下一轮从热缓存重建；缓存也已清空时，只能从仍存在的会话文件重建。

#### 4.2.6 费用

- 复用 `PricingTable::calculate_cost` 与 `pricing::rate_class_for`，不另写计价；
- 每条请求构造单样本 `TokenBucket`（含 `cache_creation_1h` 与 `rate_splits`），按同一分档规则计费；
- 价卡命中键写入 `pricing_model`；未命中或模型为 `unknown` 时 `cost_usd = NULL`；
- UI 对 NULL 显示「未计价」，不显示 `$0.00`；
- 请求行费用合计允许与 artifact 费用存在舍入差，但同一窗口、同一价卡下应基本一致；验收时以「差额 < 0.01 USD 或因未计价而少计」为口径。

#### 4.2.7 查询协议

Bridge 增加 `module = "request-log"`，与 `agent-usage` 并列；`context` 只允许查询字段，不携带凭据。

请求：

```json
{
  "schemaVersion": 1,
  "runId": "uuid",
  "module": "request-log",
  "timeouts": { "externalRequestSeconds": 0, "moduleSeconds": 10 },
  "context": {
    "home": "/Users/example",
    "operation": "query",
    "start": 1760000000000,
    "end": 1762500000000,
    "agentIds": ["claude-code", "codex", "antigravity"],
    "model": "claude-opus-5-5",
    "status": 200,
    "page": 0,
    "pageSize": 50
  },
  "credentials": {}
}
```

响应：

```json
{
  "schemaVersion": 1,
  "module": "request-log",
  "generatedAt": "2026-11-19T12:00:00Z",
  "total": 1234,
  "page": 0,
  "pageSize": 50,
  "entries": [
    {
      "requestId": "a1b2c3d4e5f60718293a4b5c6d7e8f90",
      "agentId": "claude-code",
      "model": "claude-opus-5-5",
      "rawModel": "claude-opus-5-5",
      "occurredAt": 1760000000000,
      "input": 2,
      "output": 381,
      "cacheRead": 9947,
      "cacheCreation": 19932,
      "costUsd": 0.12,
      "statusCode": 200,
      "project": "Bruce",
      "fidelity": "exact"
    }
  ]
}
```

校验规则：

- `page` 0–1000，`pageSize` 1–200；
- `start` / `end` 必须是毫秒时间戳，范围不超过 31 天；
- `agentIds` 只接受已知 Agent；`model` 最长 128 字符；`status` 100–599；
- 查询只读打开，不使用请求中的任意路径；库路径由 `home` 固定解析；
- SQL 全部参数化。

#### 4.2.8 前端信息架构（2026-11-19 已定骨架）

2026-11-19 评审确定三条骨架：

1. **入口：侧栏一级分类**。设置侧栏在「模型用量」与「模型计费」之间新增「请求日志」，不占用模型用量页签。
2. **详情：居中 Sheet**。表格保持全宽，点击行打开居中详情 Sheet；不采用右侧 Inspector，避免 823pt 面板下表格被压到约 560pt。
3. **密度：摘要条 + 表格**。表格上方只放一条轻量摘要，不做与概览页重复的大 KPI 磁贴。

> **2026-11-19 维护者确认**：前端骨架与 Agent 徽章尺寸按 demo 定稿 —— 表格 18px、筛选菜单 16px、详情 Sheet 18px；设计随「开工」转入现行基线。

页面结构：

- **侧栏分类**：新增 `SettingsCategory.requestLog`，标题「请求日志」，图标 `list.bullet.rectangle`（或等价）。
- **页面**：标题「请求日志」→ 筛选条 → 摘要条 → 表格 → 分页。
- **筛选条**：今日 / 近 7 天 / 近 30 天分段；Agent 多选；模型下拉；刷新按钮；列设置（首版可后置）。
- **摘要条**：请求数、Token 合计、已计价费用、平均每请求 Token；标注「仅本机会话记录」。
- **表格列**：时间、Agent（品牌徽章，不使用色点）、模型、新鲜输入、输出、缓存读、费用、速度、工程；缓存写 / 耗时 / 状态默认隐藏（首版会话行均为 200，状态列无信息量）。速度 = output tokens ÷ 生成耗时（总耗时减首字），无原生计时显示「—」。
- **Agent 徽章**：沿用 `AgentBrandBadge` 口径（品牌底/位图 + 系列色环），筛选菜单、表格、详情 Sheet 三处一致；Antigravity 使用官方 App 图标（指示性识别），缺素材时回退字标。
- **详情 Sheet**：request id（可复制）、原始模型、计价模型、四象限 Token、费用、工程、时间、数据来源、保真度、速度 / 总耗时 / 首字。
- **空态**：区分「还没有请求」「筛选无结果」「该 Agent 暂不支持逐请求明细」「请求库不可用」。
- **刷新**：进入分类查询一次；artifact 更新后 250 ms 防抖重查；页面可见期间每 30 s 兜底查询；手动刷新执行「同步后查询」；保留当前筛选与页码，总量收缩时回退一页；详情 Sheet 打开时不强行跳页。
- **深链**：概览页后续可从模型 / Agent 行跳到已筛选的请求日志分类（二期）。
- **文案边界**：「基于本机会话日志，不包含未落盘的失败请求」必须常驻或出现在页脚。

首版范围：不做列设置与导出；Windows UI 后续批次对齐；状态列等二期错误状态出现后再显示。

**高保真 demo 先行**：已产出 `local/designs/request-log-demo/index.html`（`local/` 未跟踪，不进入仓库），支持 `?theme=dark`、`?state=empty|loading|error`、`?sheet=1`、`?agent=antigravity`、`?menu=agent` 直接预览各状态；Agent 列已按 `AgentBrandBadge` 口径接入 Claude / Codex / Antigravity / ZCode / OpenCode 图标。页面已由 T35–T38 实施；C248 按实机验收补齐速度列、筛选图标与自动刷新。

#### 4.2.9 隐私与安全

1. 请求库不存 prompt、response、工具调用、文件路径、session id、凭据；
2. `request_key` 是 SHA-256 截断 128 位；`project` 只存 basename；
3. 目录 `0700`、文件 `0600`；WAL 与 SHM 文件同权限；
4. 查询模块不联网、不读 Keychain、不写 Agent 目录；
5. 导出/复制只允许单条 `request_id` 与派生数值，不提供整库导出（后续如需导出另评审）。

#### 4.2.10 失败降级

| 故障 | artifact | 请求日志 UI | 诊断 |
|---|---|---|---|
| 请求库创建/打开失败 | 正常发布 | 显示「请求日志不可用」 | `LOCAL_REQUEST_LOG_UNAVAILABLE`（信息级） |
| 写入 busy/超时 | 正常发布 | 保留上次结果 | 同上，附原因 |
| 查询模块超时 | 不受影响 | 内联错误 + 重试按钮 | 查询错误，不改 artifact |
| 某来源解析失败 | 该源既有降级逻辑不变 | 该 Agent 无新行 | 沿用 `LOCAL_SOURCE_SCHEMA_INCOMPATIBLE` / `LOCAL_SOURCE_NOTICE` |
| schema 版本未知 | 不删除库 | 错误提示 | 信息级；不自动重建 |

### 4.3 验证与实现情况

**实现状态**：未实现，未建卡。本文只定义目标规则；代码、测试与人工验收在 T 卡落地后补证。

**计划测试**：

| 编号 | 场景 | 期望 |
|---|---|---|
| V1 | 同一 fixture 连续扫描两轮 | 行数、费用、Token 不变 |
| V2 | 删除请求库、热缓存存在，再扫描 | 三源明细重建，Token 合计与删除前一致 |
| V3 | 冷缓存 + 删除请求库 | 从会话文件重建，结果与热缓存一致 |
| V4 | Claude 流式 message 多行 | 只留一行，取最终 Token |
| V5 | Codex 旧版无 response_id | 用时间戳 + 用量签名去重 |
| V6 | Antigravity 同 step 重写 | 只留一行，取最后一次 |
| V7 | 请求行 Token 合计 vs artifact | 同窗口一致（允许未计价差异单独说明） |
| V8 | 查询分页/筛选/排序 | total、页边界、倒序正确 |
| V9 | 非法分页/模型/时间范围 | 协议错误，不执行 SQL |
| V10 | 请求库损坏/权限不足 | artifact 正常，信息级诊断，UI 内联错误 |
| V11 | 50,000 条截断 | 保留最近行，有截断说明 |

**验收要点**：

1. 菜单栏刷新耗时相对现状无明显回退（热扫描增量 < 100 ms 量级）；
2. 三源请求行可在 UI 查询，且聚合 KPI 不变；
3. 删除请求库不影响 `usage-history-v1.sqlite`；
4. 不出现会话正文、路径或凭据落库；
5. Mac/Windows collector 对同一 fixture 产出相同请求行。

### 4.4 规则演进

| 编号 | 类型 | 简介 | 规则演进 |
|---|---|---|---|
| 本设计 | Baseline | 请求日志独立库、复用观测去重键、三源首批、30 天明细、查询模块；前端为侧栏分类 + 摘要条 + 表格 + 居中 Sheet | 2026-11-19 维护者确认开工，转现行基线；由 T35–T38 实施 |

### 4.5 参考资料

1. cc-switch 4.0.35（MIT）：
   - `src-tauri/src/database/schema.rs`：`proxy_request_logs` 表；
   - `src-tauri/src/services/session_usage.rs`：会话导入、去重、30 天明细；
   - `src-tauri/src/services/usage_stats.rs`：`get_request_logs` 筛选与分页；
   - `src-tauri/src/database/dao/usage_rollup.rs`：30 天汇总/清理；
   - `src-tauri/src/lib.rs`：启动同步 + 10 分钟兜底。
2. Bruce 现有实现：
   - `core/collector/crates/collector-local/src/jsonl_cache.rs`：JSONL 观测与去重键；
   - `core/collector/crates/collector-local/src/sources/jsonl_adapters.rs`：Claude / CodeBuddy 观测聚合；
   - `core/collector/crates/collector-local/src/sources/codex.rs`：Codex 单次响应去重；
   - `core/collector/crates/collector-application/src/lib.rs`：`AGENT_SPECS`、`local_source_jobs`、`assemble`；
   - `core/collector/crates/collector-bridge/src/lib.rs`：module 白名单与 envelope；
   - `core/collector/crates/collector-history/src/lib.rs`：历史台账边界；
   - `apps/macos/Sources/BruceApp/Settings/AgentUsageWorkbenchView.swift`：工作台承载。
3. 本机只读抽查（2026-11-19，仅结构，不落内容）：Claude 会话含 `message.id`、`requestId`、`usage`、`timestamp`；Codex 含 `token_count`；Antigravity IDE transcript 含 `input_tokens` / `cache_read_tokens` / `output_tokens`。
