# Antigravity 本机用量接入设计方案

<!-- @topic: AntigravityUsage -->
> **created**: 2026-11-19 ｜ **last-change**: 2026-11-19 ｜ **status**: baseline
> **文档ID**: DESIGN-ANTIGRAVITY ｜ **状态**: 现行基线（2026-11-19 维护者确认开工）
> **最后更新**: 2026-11-19 ｜ **所属总体**: [00-系统总体设计.md](00-系统总体设计.md) ｜ **对应 Topic**: `AntigravityUsage`
> 📌 **关联设计**: [01-数据采集与多模型计费引擎.md](01-数据采集与多模型计费引擎.md)（`TokenUsage`）｜ [14-Agent请求日志.md](14-Agent请求日志.md)（`RequestLog`）

---

## 1. 简介

Antigravity 是 Google 的 Agent 开发产品，包含 **CLI（`agy`）** 与 **IDE** 两种形态。两者都会把会话写入本机 `~/.gemini` 下的 `brain` 目录，布局相同：每个会话一个目录，正文在 `.system_generated/logs/transcript_full.jsonl`，索引在 `conversation_summaries.db`，原生元数据在 `conversations/<id>.db`。

Bruce 在此批之前支持 10 个本机 Agent，没有 Antigravity。2026-11-19 维护者要求增加支持，参考 cc-switch 的 `agy` 实现，先落地设计，再讨论前端；本批开工后作为第 11 个源接入。

**历史背景**：Bruce 曾在 `df6921d`（2026-09-10）移除过 Antigravity 的凭证导入、设置页与 SQLite 探测链路，原因是当时没有 Rust 额度消费者。本次先做**本机用量**，不复活凭证/额度链路；额度另立 P3。

**当前状态**：2026-11-19 维护者确认「开工」，本文转为现行基线；实现由 T34 承接，代码交付与验收证据以任务卡为准。

---

## 2. 索引

- 文档 ID：`DESIGN-ANTIGRAVITY`
- 所属总体：[00-系统总体设计.md](00-系统总体设计.md)
- 对应主题：`AntigravityUsage`
- 关联设计：
  - [01-数据采集与多模型计费引擎.md](01-数据采集与多模型计费引擎.md)：本机源注册、增量缓存、`AGENT_SPECS` 与价卡；
  - [14-Agent请求日志.md](14-Agent请求日志.md)：请求粒度旁路输出。
- 执行记录：[变更总账 (AntigravityUsage)](../change/index.json#AntigravityUsage)、[任务总账](../task/index.json)
- 外部参考：cc-switch 4.0.35 `docs/agy-integration-zh.md`、`session_manager/providers/agy.rs`、`services/session_usage_agy.rs`、`services/session_usage_agy/native_models.rs`。
- 本机参考：`/Users/sivan/.local/bin/agy --help` 确认 `--print` / `--output-format json` 可用（2026-11-19）；未执行任何联网额度查询。

---

## 3. 规范

### 3.1 定位与边界

1. **第 11 个本机用量源**：一个 Agent（`agent_id = "antigravity"`）统一覆盖 CLI 与 IDE，避免同一会话跨端双算。
2. **只读**：只读 `brain`、`conversation_summaries.db`、`conversations/*.db`；不写任何 Antigravity 文件，不读取或修改登录凭据。
3. **先用量、后请求日志、再额度**：P1 只做 Token 聚合；P2 把同一解析器的输出接入请求日志；P3 才讨论订阅额度。
4. **不接管配置**：不做模型切换、供应商切换、MCP/Skills 管理、会话删除或 `--gemini_dir` 私有目录。
5. **不读正文入库**：transcript 只在内存中解析；缓存与产物只保留派生数值、模型名、时间与工程名。

### 3.2 目标

| 编号 | 目标 |
|---|---|
| G1 | 本机存在 Antigravity CLI 或 IDE 会话时，产出该 Agent 的日/月/模型/小时/工程聚合 |
| G2 | 正确处理 transcript 的 step 重写与流式追加，不重复计数 |
| G3 | Token 口径与 Bruce 归一化桶一致：input 不含缓存、output 含思考 |
| G4 | 可从 `Model Selection` 事件还原每次响应使用的模型；无法确定时记 `unknown` |
| G5 | 缓存命中时不重复解析；文件变更时只重读变更文件 |
| G6 | 同一会话同时存在于 CLI 与 IDE 根时按 step 合并，只计一次 |
| G7 | 请求日志可复用同一解析结果，产出逐响应明细 |

### 3.3 非目标

1. **订阅额度**：不在 P1/P2 内。P3 另立卡，优先尝试 `agy --print /usage --output-format json`，不硬编码 OAuth client secret。
2. **原生库完整解析**：P1 不解析 `conversations/*.db` 的 protobuf；Orchestrator 模式的实际模型、精确耗时放 P2 增强。
3. **会话管理**：不做会话列表、预览、恢复、删除。
4. **配置管理**：不做供应商/模型切换、Key 注入、终端启动。
5. **旧版备份目录**：不扫描 `~/.gemini/antigravity-backup`、`antigravity-ide` 等历史目录，避免重复与噪声。
6. **失败请求**：transcript 只含已完成响应；不推断 4xx/5xx。

### 3.4 功能需求

| 编号 | 需求 | 说明 |
|---|---|---|
| R1 | 路径发现 | 同时发现 CLI 与 IDE 两个 `brain` 根；缺失的根忽略 |
| R2 | 会话发现 | 只接受合法 session id；transcript 路径必须位于根内 |
| R3 | 解析 | 只统计 `PLANNER_RESPONSE` + `DONE` + 任一 Token > 0 |
| R4 | 模型 | `Model Selection` 继承；显示名归一化；未知记 `unknown` |
| R5 | 去重 | 同 session 跨根按 step 合并；同 step 后写覆盖 |
| R6 | 缓存 | 按文件 mtime/size 失效；缓存只存派生数值 |
| R7 | 工程 | 可选从 `conversation_summaries.db.workspace_uris` 取 basename |
| R8 | 状态 | 根存在但无 Token 时给可见说明，不报 `error` |
| R9 | 请求日志 | 每个计入的响应产出一条 `RequestObservation` |
| R10 | 双端 | macOS 与 Windows collector 共用解析；路径解析跨平台 |

### 3.5 非功能约束

1. **只读与安全**：SQLite 以只读方式打开；transcript 逐行读取；路径规范化后必须仍位于根内，防止 symlink 越界。
2. **性能**：本机 121 个 transcript、约 6 万行；文件变更时整文件重读，未变更时命中缓存。冷扫描应在现有本机源并行预算内完成。
3. **内存**：单文件解析使用 `BTreeMap<step_index, row>`，只保留最后一条同 step 记录；不持有文件全文。
4. **隐私**：不缓存 `content` / `thinking` / `tool_calls` / `title` / `preview`；缓存只保留 step、时间、Token、模型、工程名。
5. **稳定性**：单文件损坏只跳过该文件并计数；不中止整个源；不把解析失败写成 0 用量。

### 3.6 输入输出与失败条件

**输入**：

- `~/.gemini/antigravity-cli/brain/**/.system_generated/logs/transcript_full.jsonl`
- `~/.gemini/antigravity/brain/**/.system_generated/logs/transcript_full.jsonl`
- 可选：同级 `conversation_summaries.db`（只读，仅 `workspace_uris`）

**输出**：

- `AgentUsage` 行：`id="antigravity"`、`name="Antigravity"`、`status`、`note`、日/月/模型/小时/工程桶；
- `RequestObservation`：请求键、时间、模型、归一化 Token、工程。

**失败条件**：

| 条件 | 行为 |
|---|---|
| 两个根都不存在 | `found=false`，`status=not_found`，沿用 history 语义 |
| 根存在但无 transcript | `found=true`，用量 0，note 说明 |
| transcript 有行但无 Token（旧版 CLI） | 跳过该行；note 说明「CLI 旧版会话未记录 Token」 |
| 单文件读取/解析失败 | 跳过并计数；`LOCAL_SOURCE_NOTICE` 说明；不中止整源 |
| summaries DB 锁定/缺列 | 忽略工程归属；不影响用量 |
| session id 非法或路径越界 | 跳过该会话，计数 |

---

## 4. 设计详情

### 4.1 架构与行为

```text
~/.gemini/antigravity-cli/brain ─┐
                                 ├─► 会话发现（session id 去重）
~/.gemini/antigravity/brain ─────┘
                                 │
                                 ▼
                 Antigravity transcript 解析器
                 ├─ BTreeMap<step_index, row>（后写覆盖）
                 ├─ Model Selection 继承
                 ├─ Token 归一化
                 └─ RequestObservation（可选）
                                 │
                                 ▼
                 UsageContributionBuilder → 现有聚合/历史/artifact
```

**行为顺序**：

1. 解析两个根，枚举合法 session；
2. 同 session 跨根合并 step；
3. 每个文件读取缓存条目；mtime/size 未变则复用；
4. 变更文件整文件重读，构建 step 表；
5. 按 step 顺序解析模型切换与完成响应；
6. 产出 `UsageSample`；同时产出 `RequestObservation`（P2）；
7. 进入现有 `SourceScan` / `LocalAgentResult` 流程。

### 4.2 核心业务规则

<!-- @topic: AntigravityUsage -->

#### 4.2.1 数据源与路径

```text
<root>/<session-id>/.system_generated/logs/transcript_full.jsonl
<root>/conversation_summaries.db
<root>/conversations/<session-id>.db
```

其中 `<root>` 为：

- `~/.gemini/antigravity-cli`（CLI）
- `~/.gemini/antigravity`（IDE）

规则：

- `session-id` 必须非空且只含 `[A-Za-z0-9-]`；
- transcript 必须真实存在且规范化后仍位于 `<root>/brain` 内；
- 不扫描 `antigravity-backup`、`antigravity-ide`；
- Windows 使用同一 `home/.gemini/...` 结构；路径解析集中在 `collector-application/src/paths.rs`。

#### 4.2.2 会话发现与跨根合并

1. 对每个根列出 `brain/<session-id>/`；
2. 同一 session id 出现在两个根时，不二选一，而是**按 step 合并**：
   - 同 step 取 `created_at` 较晚者；相同则取文件 mtime 较晚者；
   - 合并后的 step 集合去重后计数；
3. 若两个根内容完全一致，结果等价于只读一个根；
4. 合并冲突计入 `ScanStats.conflict_session_groups`，并在 note 中说明（沿用 Codex 副本口径）。

#### 4.2.3 transcript 解析

每行是 JSON，关键字段：

| 字段 | 用途 |
|---|---|
| `step_index` | 同 step 覆盖排序 |
| `type` | 只取 `USER_INPUT` / `PLANNER_RESPONSE` |
| `status` | 只取 `PLANNER_RESPONSE` 的 `DONE` |
| `created_at` | ISO8601 UTC，转 epoch millis |
| `content` | 仅用于解析 `Model Selection`，不落盘 |
| `input_tokens` / `output_tokens` / `cache_read_tokens` | Token 计数；缺失或全 0 跳过 |
| `cache_write_tokens` / `reasoning_tokens` | 可选；当前真实样本未见 |
| `model` | 部分版本有；优先于继承值 |

解析规则：

- 先按 `step_index` 构建 `BTreeMap`，同 step 后写覆盖前写（流式完成时会重写）；
- 文件读取失败不缓存为空；下一轮重试（沿用 C197 口径）；
- 尾行截断：只处理可解析的完整 JSON 行，残行下一轮重试。

#### 4.2.4 Token 口径

cc-switch 用本地模拟 SSE 验证过，Bruce 直接采用：

| 归一化字段 | Antigravity 字段 | 说明 |
|---|---|---|
| `input` | `input_tokens` | **已排除缓存**的新鲜输入，不再减 cache |
| `cache_read` | `cache_read_tokens` | 单列 |
| `output` | `output_tokens` | **已包含思考**，不再加 reasoning |
| `cache_creation` | `cache_write_tokens`（缺省 0） | 当前真实样本未见 |
| `cache_creation_1h` | 0 | Antigravity 无 TTL 区分 |

导入门槛：四个归一化桶任一 > 0。`status != DONE` 或类型不是 `PLANNER_RESPONSE` 的行不导入。

#### 4.2.5 模型归属

transcript 的响应行通常没有 `model`，模型切换写在用户输入里：

```text
Model Selection` from None to Gemini 3.6 Flash (High).
```

规则：

1. 按 step 顺序扫描；遇到 `USER_INPUT` 且 content 含 `Model Selection`，解析 ` to ` 后的显示名，直到 `. ` / 换行 / 反引号；
2. 后续 `PLANNER_RESPONSE` 继承最近一次选择；
3. 若响应行自身有非空 `model` 字段，优先使用；
4. 显示名 → 基础模型 ID：
   - `Gemini 3.6 Flash (High)` → `gemini-3.6-flash`
   - `Gemini 4 Pro (Low)` → `gemini-4-pro`
   - 无空格的值视为已经是 ID；
5. 档位后缀 `-high/-medium/-low/-trial/-n/-tiered` 不进入聚合 `model`，只保留在 `raw_model`；
6. `Orchestrator Carbon/Argon` 是模式，不是具体模型：
   - P1：`model = unknown`，不猜测；
   - P2：从 `conversations/<id>.db` 的 `gen_metadata` 解析真实模型（protobuf 字段 20/3、1/19/21）；
7. `gemini-api` 是入口标签，不是模型，忽略；
8. 未知模型计入 `unknown`，参与 Token 总量，不参与计价。

#### 4.2.6 工程归属

- 可选读取 `conversation_summaries.db` 的 `conversation_id` 与 `workspace_uris`；
- `workspace_uris` 是 JSON 数组，取第一个 `file://` URI 转为路径，再取 basename；
- 只存 basename，不存完整路径；
- summaries DB 缺失/锁定/缺列时，`project = None`，不影响用量；
- 不读 `title` / `preview` / 正文。

#### 4.2.7 缓存

新增 Antigravity 按文件缓存 `antigravity-cache-v1`（具体文件名由实现定）：

```json
{
  "version": 1,
  "mtime_ns": 0,
  "size": 0,
  "steps": [
    {
      "step": 12,
      "timestamp": 1760000000000,
      "model": "gemini-3.6-flash",
      "input": 2239,
      "output": 723,
      "cache_read": 15474,
      "cache_creation": 0,
      "request_key": "a1b2..."
    }
  ]
}
```

规则：

- 文件 mtime/size 未变：直接复用；
- 变更：整文件重读并重建条目（不维护字节偏移，因为 transcript 会重写 step）；
- 读取失败：不写空条目，沿用旧条目，下一轮重试；
- 缓存只存派生数值与模型名，不存 content / thinking / tool_calls；
- 缓存写入 `0600`，与现有缓存同级。

#### 4.2.8 状态与 note

| 场景 | `status` | `note` |
|---|---|---|
| 两个根都不存在 | `not_found` | 沿用「未发现会话记录」 |
| 根存在、有完成响应、有 Token | `ok` | 「Antigravity CLI/IDE 本机会话聚合」 |
| 根存在、只有旧版 CLI 无 Token 行 | `ok` | 「CLI 旧版会话未记录 Token，仅统计可计量的 IDE/新版本会话」 |
| 根存在、没有完成响应 | `ok` | 「未发现可计量的完成响应」 |
| 解析故障 | `error` | 沿用 `LOCAL_SOURCE_SCHEMA_INCOMPATIBLE` |
| 部分文件失败/重复会话 | `ok` | `LOCAL_SOURCE_NOTICE` 说明，不改变状态 |

#### 4.2.9 注册与双端改动清单

| 位置 | 改动 |
|---|---|
| `core/collector/crates/collector-application/src/lib.rs` | `AGENT_SPECS` 追加 `("antigravity", "Antigravity", ...)`，保持既有顺序 |
| `core/collector/crates/collector-application/src/lib.rs` | `local_source_jobs` 追加 `scan_antigravity_cached` |
| `core/collector/crates/collector-application/src/paths.rs` | 新增 `resolve_antigravity_brain_roots(home)` |
| `core/collector/crates/collector-local/src/lib.rs` | 导出扫描函数；`source_derivation_version("antigravity") = 1` |
| `core/collector/crates/collector-local/src/sources/antigravity.rs` | 新增解析器、缓存与测试 |
| `apps/macos/Sources/BruceAppCore/PanelModels.swift` | 固定品牌色与 Nothing 档位 |
| `apps/macos/Sources/BruceAppCore/AgentBrandPalette.swift`、`apps/win/src/agent-brand.js` | 新增 Antigravity 品牌图标（官方 App 图标，指示性识别）、tile/mark/monogram 与系列色环 |
| `docs/assets/provider-icons/agent-icons/agent-antigravity.png`、`SOURCES.json` | 登记官方 App 图标来源、许可证与指示性使用边界 |
| `apps/macos/Sources/BruceOnboardingCore/LocalDependencyScanner.swift` | 欢迎向导探测 Antigravity 会话根 |
| `apps/win/viewmodel/src/color.rs` | Windows 颜色与档位 |
| `apps/win/src-tauri/src/paths.rs` | Windows 路径探测 |
| `docs/devel/design/01`、`06`、`10`、`README` | 10 → 11 个 Agent；补 `@topic: AntigravityUsage` 路由 |
| `config/pricing-catalog.json` | Gemini 3.x / 4.x 价卡条目 |

#### 4.2.10 价卡

- 聚合 `model` 使用基础 ID（如 `gemini-3.6-flash`），价卡按基础 ID 匹配；
- 价卡没有对应条目时 `cost_usd = NULL`，UI 显示「未计价」，**不得估算**；
- 补价卡时使用官方公开价格；无法确认的价格不写入；
- 远端价卡同步（design/09）优先于内置表；内置表至少覆盖当前常用 Gemini 3.x/4.x。

#### 4.2.11 请求日志联动

- 每个计入的完成响应产出 `RequestObservation`；
- `request_key = sha256("antigravity", session_id + ":" + step_index)` 截断 128 位；
- `model` 用归一化基础 ID，`raw_model` 用显示名；
- 请求日志的 Token 口径与本设计的聚合口径完全相同；
- 详见 [14-Agent请求日志.md](14-Agent请求日志.md)。

#### 4.2.12 订阅额度（P3，暂不实施）

- 优先方案：`agy --print /usage --output-format json`，移除 `GEMINI_API_KEY` / `GOOGLE_GEMINI_BASE_URL`，超时与 `kill_on_drop`；
- 返回结构：`status`、`command.data.groups[].buckets[]`，桶 id 为 `gemini-5h`、`gemini-weekly`、`gemini-argon-wtu-weekly`、`3p-5h`、`3p-weekly`；`remaining_fraction` 转 `used% = 1 - remaining`；
- 不在 Bruce 内硬编码 OAuth client secret，不写 Keychain；
- 未登录、未安装、输出结构变化均降级为「暂不可用」，不伪造额度；
- P3 需要单独评审与授权，不阻塞 P1/P2。

### 4.3 验证与实现情况

**实现状态**：未实现，未建卡。

**本机只读抽查（2026-11-19）**：

| 来源 | PLANNER_RESPONSE | 带 Token |
|---|---:|---:|
| IDE `~/.gemini/antigravity/brain` | 17,543 | 17,297 |
| CLI `~/.gemini/antigravity-cli/brain` | 11,276 | 0 |

结论：IDE 与新版本 transcript 可计量；旧版 CLI 无 Token 字段，必须在 note 中说明，不能宣称全量可统计。

**计划测试**：

| 编号 | 场景 | 期望 |
|---|---|---|
| V1 | 合成 transcript：input 100、cache 20、output 5、thinking 7 | 归一化 input=100、cache=20、output=5；不重复减/加 |
| V2 | 同 step 多行 | 只取最后一行 |
| V3 | Model Selection 前后切换 | 每条响应归属正确模型 |
| V4 | 显示名 `Gemini 3.6 Flash (High)` | `model=gemini-3.6-flash`，`raw_model` 保留显示名 |
| V5 | 两个根同 session | step 合并，只计一次 |
| V6 | CLI 旧版无 Token | 跳过，note 可见，不报 error |
| V7 | 文件重写/尾部截断 | 不出现重复计数或崩溃 |
| V8 | 缓存冷/热对拍 | 结果一致 |
| V9 | 时区跨日 | 与 `CollectionWindow` 一致 |
| V10 | 非法 session id / symlink 越界 | 跳过，计数 |
| V11 | 请求行 Token 合计 vs 聚合 | 同窗口一致 |

**验收要点**：

1. Antigravity 出现在 artifact 的 `agents` 中，id/name/status/note 正确；
2. 有 IDE 会话时 Token 与模型构成可见；
3. CLI 旧版会话不产生假 0，说明可见；
4. 冷/热扫描结果一致；
5. macOS / Windows 对同一 fixture 产出相同 artifact；
6. 不读取或写入任何凭据。

### 4.4 规则演进

| 编号 | 类型 | 简介 | 规则演进 |
|---|---|---|---|
| 本设计 | Baseline | 第 11 个本机源：CLI + IDE 双根、step 合并、Token 口径、模型继承、请求日志联动 | 2026-11-19 维护者确认开工，转现行基线；由 T34 实施 |
| `df6921d` | Refactor | 移除 Antigravity 凭证导入/设置/探测链路（当时无 Rust 额度消费者） | 历史事实；本设计不复用额度链路，仅恢复本机只读用量 |

### 4.5 参考资料

1. cc-switch 4.0.35：
   - `docs/agy-integration-zh.md`：接入范围、Token 语义、会话与模型说明；
   - `src-tauri/src/session_manager/providers/agy.rs`：双根发现、transcript 读取、summaries DB；
   - `src-tauri/src/services/session_usage_agy.rs`：Token 导入、模型继承、去重；
   - `src-tauri/src/services/session_usage_agy/native_models.rs`：原生模型/耗时 protobuf；
   - `src-tauri/src/services/subscription_agy.rs`：`agy --print /usage` 额度查询（P3 参考）。
2. Bruce：
   - `core/collector/crates/collector-local/src/sources/`：现有 JSONL / SQLite 适配器与缓存；
   - `core/collector/crates/collector-application/src/lib.rs`：`AGENT_SPECS`、`local_source_jobs`；
   - `core/collector/crates/collector-application/src/paths.rs`：本机路径解析；
   - `docs/devel/design/01-数据采集与多模型计费引擎.md`：Token 口径与历史台账。
3. 本机实测：2026-11-19 只读扫描 121 个 transcript、60,576 行；IDE/CLI Token 覆盖如上表；`agy --help` 确认 `--print` 与 `--output-format json` 存在，未执行联网额度查询。
