# 16 · 代码审查发现记录 (2026-09)

- 审查范围: `6d70ce5..HEAD` 共 7 个提交 (Codex 模型归属 `dde76ee`, CodeBuddy 解析增强 `6a1b6c4`, AtomicJSONStore 抽取 `7c82b33`, 设置页重构 `eec3324`/`e736712`, Clippy 修复 `8eb4528`/`4ab2e78`), 约 +3900 行。
- 审查方式: 静态阅读 diff + 本机真实数据 (CodeBuddy JSONL, ZCode SQLite) 交叉验证。
- 状态标记: 修复项已回填提交号 (2026-09-06 修复批次, verify-local 全绿); 未修复的问题持续留档。

---

## 结论摘要

整体工程质量良好: 机械性重构忠实原语义, 凭证无日志泄漏, 设置页各 provider 状态独立无串扰, 两个 Clippy 修复语义中性。审查发现 1 个 P1 双计数缺陷、2 个 P2 与 5 个 P3; 除 2 项非缺陷/已知取舍与 1 项待验证外, 其余已全部修复 (2026-09-06 批次)。

---

## P1 · CodeBuddy thinking tokens 双计数 (已实锤) — 已修复 `51fa239`

- 位置: `rust/Bruce-collector/crates/collector-local/src/sources.rs:873` (`codebuddy_usage_fields` 返回值)
- 现状: `output.unwrap_or(0).saturating_add(reasoning.unwrap_or(0))` 把 thinking 加法计入 output。
- 本机证据 (CodeBuddy 2.143.0, `~/.codebuddy/projects/`):
  - 同一条记录 `rawUsage = {prompt_tokens: 24575, completion_tokens: 109, completion_thinking_tokens: 64}`, 归一化 `total_tokens = 24684 = 24575 + 109`。
  - 即 `completion_tokens` **已包含** thinking (OpenAI 兼容语义), 正确 output 是 109, 当前代码算出 173, 单记录 output 虚增 59%。
  - zhipu 原生命名 (`completion_thinking_tokens`) 与 OpenAI 命名 (`completion_tokens_details.reasoning_tokens`) 两个解析分支均受影响。
- 影响面: 本机 15689 条记录中 2735 条 (17.4%) 带 thinking, 全部虚增; output 为最高单价档, 成本估算同步偏高。
- 口径冲突: 此前用户确认口径为 "output 用归一化 output_tokens, thinking 不拆"; `6a1b6c4` 的 rawUsage 优先 + 加法实际推翻了该决定, 且加法行为已写入测试断言 (`codebuddy_reads_raw_usage_from_function_call` 断言 50+20=70), 修复须连测试一起改。
- 修复方向: completion 已含 reasoning 时不再加算; 修 `codebuddy_reads_raw_usage_from_function_call` 与 `codebuddy_reads_camel_case_cache_breakdown` 两个测试的期望值。
- 修复记录: `51fa239` 删除 reasoning 加法并在函数注释固化口径依据, 两个测试期望改为 50/30。

## P2 · rawUsage 优先导致 cache_read 丢失 — 已修复 `72f7ab8`

- 位置: `sources.rs` `codebuddy_usage` 的候选链 `find_map` (rawUsage → providerData.usage → message.usage → usage)。
- 现状: rawUsage 解析成功后不再回退归一化 usage。
- 本机证据: 样本记录 rawUsage 只有 `completion_tokens_details` (无 `prompt_tokens_details`), 缓存信息仅在归一化 `cache_read_input_tokens: 384` 中 → 采到 cache_read=0, 384 缓存 token 全额计入纯输入。
- 影响: 总 token 不变, 但缓存折扣丢失, 成本估算偏高。
- 修复方向: rawUsage 无缓存字段时合并归一化 usage 的 cache_read / cache_creation。
- 修复记录: `72f7ab8` 候选链改为全量解析后按序合并, 首选候选缺缓存明细时从后续候选补齐并同步扣减 input (`input_cache_inclusive` 标记防止病态形态重复扣减); 新增本机真实形态回归测试 `codebuddy_merges_normalized_cache_when_raw_usage_lacks_breakdown` (24191/109/384, 总量守恒 24684)。

## P2 · AtomicJSONStore 备份 "写一次永不刷新" — 已修复 `88dff9d`

- 位置: `macos/BruceApp/Sources/BruceOnboardingCore/AtomicJSONStore.swift:227` (`backup()` 已存在即跳过); 全仓库无 `removeBackup` 调用方。
- 影响点: `ArtifactStore.swift:161`, `DeepSeekUsageLedger.swift:334`, `OnboardingConfiguration.swift:309` 均 `backupPrevious: true`。
- 后果: `.backup.json` 永远停留在功能上线后第一次写入时的状态; 回滚安全网会还原数月前陈旧数据。
- 修复方向: 成功写入后 `removeBackup` (滚动深度 1), 或 `backupPrevious` 改为覆盖式备份。
- 修复记录: `88dff9d` 采用覆盖式备份 — 每次 `backupPrevious` 写入都把备份刷成「本次写入前」状态 (滚动深度 1); 新增 Harness 用例 `atomicStoreBackupRefreshesOnEachWrite` (v1/v2/v3 → 备份持 v2 → 回滚还原 v2), OnboardingCore Harness 163 项全绿。
- 备注: 重构前 ArtifactStore 只有 schema-v0 迁移备份 (同为 write-once, 属迁移语义), per-write 备份是本次新加, 非回归。

## P3 · 低危问题清单

1. **DeepSeekLedger 回滚路径跳过 schemaVersion 校验** — 已修复 `d12732a`: 回滚还原结果与直读执行同一版本校验, 高版本备份保守拒绝; `OnboardingConfiguration` 存在同类缺陷, 一并修复。
2. **`AtomicJSONStore.read` 把 IO 错误归为 `.corrupt`** — 已修复 `6099785`: 新增 `.unreadable` 分离「字节读取失败 (权限/IO, 内容未知)」与「解码/校验失败」, 两个调用方对 `.unreadable` 保守不回滚。
3. **`codebuddy_first_positive_number` 零值陷阱** — 已修复 `9a41656`: 无正值时返回 `None` 让 `.or_else` 嵌套回退生效, 最终默认仍由 `unwrap_or(0)` 承担; 新增回归测试 `codebuddy_nested_cache_detail_survives_flat_zero_field`。
4. **行为变化 (非缺陷, 不修)**: Codex 老会话无模型信息时占位从 `"codex"` 变为 `"unknown"` (builder 统一兜底, `collector-domain/src/lib.rs` `record`), 模型用量卡会显示 unknown 行。
5. **Codex 累计总量跨模型切换归属为近似**: 整段 delta 归到切换后的新模型 (commit `dde76ee` 已声明); 属已知取舍, 不修。

## 待验证 · zcode `output + reasoning` 同类双计数风险

- 位置: `sources.rs:1458` (`scan_zcode`)。
- 现状: 本机 8814 行 `model_usage` 中 `reasoning_tokens` 全为 0, 且写入端 `raw_usage_json` 自洽 (`totalTokens = inputTokens + outputTokens`), 双计数未在本机触发。
- 结论: 风险存在但未证实; 待出现 reasoning > 0 的真实会话后, 用 `computed_total_tokens`/`provider_total_tokens` 与五桶加法对比再定。

---

## 审查通过项

- `8eb4528` / `4ab2e78`: Clippy 修复语义中性 (`while let` 改写, `io::Error::other`)。
- `StoredCredentialParser`, `reverify` 统一入口, 按 provider 归因错误字典: 实现正确。
- 配置弹窗各 provider 独立 `@State` (kimiValues/deepseekValues/...), 无跨 provider 串数据。
- CodeBuddy 会话级快照去重 (替代字段级 max): 方向正确, 修复跨会话 messageId 撞号。
- 凭证处理: SecureField 输入, 无 print/NSLog/Logger 泄漏路径。

---

## 附录 · Codex 采集失效排查记录 (2026-09-05)

用户反馈「采集不到 chatgpt 的 token 消耗」, 要求重新对齐 CC (Claude Code) 采集流程。排查结论: **数据链路三层验证全部健康, 数据层无法复现失效**。

### 验证证据

1. **采集器直跑** (dist 二进制, 与 App 同款请求, days=182): codex status=ok, 当日 20.4M tokens 且持续增长, 模型归属 gpt-6-astra / gpt-5.6-luna / gpt-5.6-sol / codex-auto-review; 全窗口扫描仅 11 秒, 远低于 App 的 30 秒 localScan 超时。
2. **运行中 App 的落盘快照** (`~/Library/Application Support/Bruce/snapshots/agent-usage.json`, 当日 12:19 更新): codex 当日 12.5M tokens, 每日数据齐全; 两个 Codex 账号额度 fresh (5 小时窗口 100%, 周窗口 16%)。
3. **真实文件审计** (75 个 rollout, 全窗口约 6.25 亿 tokens, `/tmp` 一次性脚本): dde76ee 状态机的采集结果与 CC 式直接累加 `last_token_usage` **逐日完全一致 (差值 +0)**; 状态机去重的 1236 个事件全部是零增量重放快照, 直接累加也不会多算。

### 结论与建议

- 数据层不成立, 剩余可能: (a) 面板 UI 渲染层 (本次排查无法观察 UI: 截屏权限未授予, 面板关闭时无可读 AX 树); (b) 观察时点恰逢一次刷新失败 (diagnostics 含 `COLLECTOR_PARTIAL_RESULT`); (c) 观察来自旧版本构建。
- **简化机会 (等价重构, 待确认后实施)**: 审计证明 dde76ee 的签名/每源去重表/高水位机制在本机全部真实数据上等价于 CC 式直接累加, 属于死重。可将 `scan_codex` 简化为: 保留 turn_context 模型归属 + 直接累加 `last_token_usage` (零增量事件已被全零检查自然过滤)。行为不变, 代码复杂度显著下降。
