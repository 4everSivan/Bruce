<!-- source: template/base -->
# mddd 项目事实

本文件是 `constitution.md` 的项目实施层, 是所有 AI 工具的共享基线. 维护项目事实, 路径, 脚本, 数据模型, 服务拓扑和已确认环境能力策略.

边界:

- 红线, 证据分级和工作模式定义 -> `constitution.md`
- 项目事实, 路径, 脚本, 数据模型, 服务拓扑和已确认环境能力策略 -> 本文件
- 输出格式, 模板和自审清单 -> `templates/*` 或对应 skill 内置模板

---

## 1. 项目目标

`mddd` 用于制作一个运行在 macOS 菜单栏场景中的研发活动看板. 核心能力是分析本机 AI Agent 的 token 用量, 成本和额度. 项目采用本机 Collector 采集数据, 输出 JSON artifact; macOS App 以原生 SwiftUI 液态玻璃看板渲染 (macOS 26), 仓库根 `*/widget/` 单文件 Widget 继续服务 Daimon/Kimi Work Blueprint 场景.

项目是本地优先工具, 但会读取真实会话记录和认证信息, 并调用外部服务. 任何实现都必须优先保护凭证, 个人活动数据和其他应用维护的本机数据库.
<!-- source: user-input -->
<!-- source: scan/README, confidence: HIGH -->

---

## 2. 沟通与输出规范

- **[强制]** 面向用户的说明, 文档和解释统一中文; 中文内容默认英文半角标点.
- **[例外]** 第三方工具输出, 日志, 错误信息, 协议字段和标准 API 名称保留原始英文.
- **[强制]** 先给结论再给依据; 优先可执行建议; 复杂问题说明设计意图, 风险点, 验证方式和回滚边界.

---

## 3. 规则层级与单一事实源映射

优先级从高到低: 平台/System/Developer/工具强制安全指令 > `constitution.md` > 本文件 `AGENTS.md` > 工具入口 > generated subagent body > 设计说明 > 单次偏好.

冲突裁决: 项目路径, 脚本和数据入口以本文件为准; 用户授权不能覆盖 `constitution.md` 红线.

| 概念 | 唯一归属 |
|------|---------|
| 红线, 证据分级, 工作模式 | `constitution.md` |
| 项目事实, 路径, 脚本, 拓扑 | `AGENTS.md` |
| 输出格式, 模板, 自审清单 | `templates/*` 或对应 skill 内置模板 |

---

## 4. 事实来源优先级

1. 用户提供的真实现象, 报错, 日志, 输出, 截图和业务时间线.
2. 项目 Collector 的实际输出和可重复测试结果.
3. 已归档的历史数据和问题记录.
4. `README.md`, `docs/` 和项目内设计文档.
5. 官方文档和对应版本源码.

有现场数据时先读现场数据, 再用源码或文档解释机制. 源码和文档只证明机制边界, 不单独证明真实账号或当前运行结果. 版本差异必须说明适用范围.

---

## 5. 目录与路径约定

### 5.1 源码与入口

| 目录 | 用途 |
|------|------|
| `agent-usage/collector/` | 扫描本机 Agent 会话, 聚合 token, 估算成本并查询服务额度 |
| `agent-usage/widget/` | 渲染 Agent token, 成本, 额度和趋势的单文件 Widget |
| `macos/MdddApp/` | SwiftPM 包 (macOS 26): `MdddApp` (SwiftUI 菜单栏应用, 原生液态玻璃看板, `Sources/MdddApp/Views/` 卡片组件), `MdddAppCore` (AppModel, 调度, PanelViewModel 映射), `MdddOnboardingCore` (扫描, 授权, Gate, 订阅凭证纯逻辑), 多个 Harness 边界测试 |
| `data/` | 本机运行产物; 可能包含个人活动和使用量数据, 不得提交 |
| `docs/` | 项目设计, 决策和说明文档 |
| `scripts/` | 本地验证脚本 (`verify-local.sh`) 与测试版 App 打包脚本 (`build-test-app.sh`) |

### 5.2 参考资料

- `README.md`: 项目目标, 模块说明, 本机数据源和运行命令.
- `constitution.md`: 安全红线, 证据要求和工作模式.
- `docs/development/01-mddd-design.md`: 产品需求, UI 规范, 数据契约和验收标准.
<!-- source: scan/code-structure, confidence: HIGH -->

---

## 6. 标准脚本与验证命令

| 命令 | 用途 |
|------|------|
| `python3 agent-usage/collector/collect_usage.py --out data/agent-usage.json` | 实时采集 Agent 用量和额度; 可能刷新并写回 OAuth, 必须先获得明确授权 |
| `python3 -c 'import ast,pathlib; [ast.parse(p.read_text()) for p in pathlib.Path(".").glob("*/collector/*.py")]'` | 无外部调用的 Python 语法验证 |
| `node --check -` | 对从 Widget 提取的 JavaScript 执行语法验证 |
| `zsh scripts/verify-local.sh` | 标准本地验证: Python 语法 + pytest + swift build + 全部 10 个 Harness |
| `python3 -m pytest tests/` | Python 单元与契约测试 (bridge, collector, widget 安全); 154 项 |
| `swift build --package-path macos/MdddApp` | macOS App 与 MdddOnboardingCore 构建验证 |
| `swift run --package-path macos/MdddApp MdddOnboardingCoreHarness` | Onboarding Core 边界测试 (进程, SQLite, Keychain, Gate, 订阅凭证, 设备码登录, 令牌轮换合并, Codex v2 迁移, DeepSeek 追踪 ID 与保存事务, 统一过期判定器, Claude/Grok 导入器); 161 项 |
| `swift run --package-path macos/MdddApp PanelViewModelHarness` | 面板 view model 映射边界测试 (措辞, 分组, 条件渲染, Codex 账号上次成功时间, DeepSeek 月度映射); 32 项 |
| `swift run --package-path macos/MdddApp DeepSeekUsageLedgerHarness` | DeepSeek 月度账本边界测试 (领域差分, 时区跨日, 持久化权限, 损坏恢复, 敏感字段); 17 项 |
| `zsh scripts/build-test-app.sh` | 生成 `dist/mddd.app` 本地构建 App (Release 构建 + 打包 + 签名校验) |
| GitHub Actions `.github/workflows/ci.yml` | push/PR 触发: verify-local.sh + Python 3.9 兼容 + 测试包构建; tag `v*` 触发草稿 Release |

执行第一个实时命令前必须应用 `constitution.md` 的 Production Operation Mode. 静态分析或普通代码审查不得把实时采集作为默认验证步骤.
<!-- source: scan/config, confidence: HIGH -->

---

## 7. 服务与拓扑

```text
macOS 本机会话与认证文件
  ├─ Kimi Work / Kimi Code / Claude / Codex / Orca 会话
  ├─ CC Switch SQLite 与 OAuth 账号库 (App 模式仅一次性只读导入)
  ├─ App Keychain (订阅凭证: Kimi/DeepSeek/火山/Codex/Antigravity)
  └─ Kimi 与 Antigravity OAuth
                  │
                  ▼
Python Collectors ──出站请求──> Kimi, DeepSeek,
                  │             火山引擎, OpenAI, Google Cloud Code,
                  │             Anthropic (Claude), Grok
                  ▼
           {"artifact": ...} JSON
                  │
        ┌─────────┴─────────┐
        ▼                   ▼
DaimonWidget.data.main   AppModel + PanelViewModelMapper
        │                   │
        ▼                   ▼
Daimon 单文件 Widgets   macOS 菜单栏原生液态玻璃看板
```

- Collector 是唯一数据采集边界, Widget 不直接读取凭证.
- `run(ctx)` 返回 `{"artifact": ...}`; Daimon host 将 artifact 映射为 Widget 的 `data.main`.
- `data/*.json` 是可选本机落盘产物, 不是源代码或测试 fixture.
- `agent-usage` 实时采集可能轮换本机 OAuth; 该副作用必须被显式识别和授权.
- `agent-usage` 云端额度条目在 CLI 模式由 CC Switch providers 行驱动; App 模式改由注入凭证 (`kimi_web_tokens` / `provider_env.deepseek` / `provider_meta.volcengine` / `codex_oauth_auth` + `codex_auth` / `antigravity_oauth`) 驱动合成, 不再要求 CC Switch 数据库存在; App 模式不读 `~/.codex/auth.json`, Codex 活跃账号由 `codex_auth` 注入承载.
- agy (Antigravity CLI) >= 1.1.8 把 OAuth 令牌存进登录 Keychain (go-keyring, service `gemini` / account `antigravity`, 值带 `go-keyring-base64:` 前缀), 不再写 `~/.gemini/antigravity-cli/antigravity-oauth-token`; collector CLI 模式与 App 导入链路均按「文件优先, Keychain 回退」读取, Keychain 来源只读不回写.
- Antigravity 额度查询的 OAuth client 凭证 (`AGY_CLIENT_ID` / `AGY_CLIENT_SECRET`) 由运行环境注入, 不硬编码入库; 缺省为空时刷新链路安全降级, 不得伪造非空凭证.
- Claude / Grok 订阅额度 (`quota_official.py`) 实时只读本机 CLI 登录态, 不刷新, 不回写, 不做一次性导入: Claude 按「Keychain `Claude Code-credentials` (无 account) 优先, `~/.claude/.credentials.json` 兜底」读取, 调用 `api.anthropic.com/api/oauth/usage`; Grok 读取 `~/.grok/auth.json` (OIDC scope 优先, legacy `/sign-in` 兜底), 调用 `grok.com` gRPC-web 账单接口, protobuf 启发式解析失败必须抛可诊断错误, 不得伪造用量. App 模式由 `provider_meta.claude/grok.enabled` 标记驱动 (无凭证注入), CLI 模式自动探测本机凭证; Swift 侧以本机检测结果作为 configured 语义 (fail-closed).
- App 订阅凭证存 Keychain (`com.mddd.dashboard.credentials`), 在设置「订阅额度」分区配置或从本机/CC Switch 一次性只读导入; 令牌轮换经 `credentialUpdates` 只写回 Keychain, 不回写 CC Switch.
- 外部 API 和 CC Switch 数据库 schema 未在仓库内锁定, 解析失败必须保留可诊断证据.
<!-- source: scan/security, confidence: HIGH -->
<!-- source: infer, confidence: MEDIUM -->

---

## 8. 治理维度事实

### 代码结构

- 语言: Python 3 为主, 原生 JavaScript/HTML/CSS 为展示层.
- 框架: 无应用框架; Python 使用标准库, Widget 使用 DaimonWidget host contract.
- 构建系统: 无; Collector 直接执行, Widget 无构建步骤.
- 入口文件: `agent-usage/collector/collect_usage.py`, `agent-usage/widget/index.html`.
- 架构模式: 模块化 Collector-Artifact-Widget 管道, 业务模块相互独立 (confidence: HIGH).

### 编码规范

- 新增公共函数, 外部服务边界和复杂 artifact 结构应提供类型标注或明确 schema.
- 可执行脚本必须使用 `if __name__ == "__main__":` 隔离副作用入口.
- 不在 import 阶段执行网络, 文件写入, 当前日期固化或重型初始化.
- 捕获具体异常; 关键错误不得静默退化为"无数据".
- 文件, SQLite 连接和其他资源使用上下文管理器.
- SQL 动态值使用参数化绑定.
- 外部服务, 文件系统, 时间和时区必须能够在测试中替换.
- Collector 与 Widget 共享的字段属于兼容性契约.
<!-- source: template/code-standards/python -->
<!-- source: scan/code-structure, confidence: HIGH -->

### 数据库

- 驱动/ORM: Python 标准库 `sqlite3`.
- 迁移工具: 无.
- 数据库类型: SQLite; 读取 CC Switch provider/pricing 和 Antigravity conversation summaries.

数据库操作原则:

- 连接外部应用数据库时使用 SQLite URI `mode=ro`.
- 本项目不得为 CC Switch 或 Antigravity 数据库执行迁移, DDL 或数据修复.
- schema 不兼容必须产生可诊断状态, 不得静默伪装成空结果.
- 若未来新增项目自有数据库, 必须先补充 schema, 迁移, 备份和回滚约束.
<!-- source: template/dim-database -->
<!-- source: scan/dependencies, confidence: MEDIUM -->

### 未启用维度

- API: 未检测到服务端路由, 控制器, API 契约或认证入口. 当前只有出站 API 客户端, confidence: LOW, 不启用 API 治理维度.
- Deploy: 未检测到 Docker, K8s, Terraform 或 CI/CD 配置, confidence: HIGH.
- Maintenance: 未检测到项目级监控, 告警或结构化日志配置, confidence: HIGH.
<!-- source: scan/api, confidence: LOW -->
<!-- source: scan/config, confidence: HIGH -->

---

## 9. 已确认环境能力

用户于 2026-07-28 确认以下能力写入项目治理:

| ID | kind | detected | confirmed | detection_basis | template_condition |
|----|------|----------|-----------|-----------------|--------------------|
| `semble` | `mcp` | true | true | MCP 语义搜索调用成功 | `has_mcp_semble` |
| `headroom` | `mcp` | true | true | 当前环境提供压缩, retrieve 和统计工具 | `has_mcp_headroom` |
| `context7` | `mcp` | true | true | 当前环境提供 library resolve 与文档查询工具 | `has_mcp_context7` |
| `fetch` | `mcp` | true | true | 当前环境提供 URL fetch 工具 | `has_mcp_fetch` |
| `improve-codebase-architecture` | `skill` | true | true | 当前环境注册架构改进 skill | `has_skill_architecture` |

<!-- source: capability-detect, confirmed: true -->

### Semble 代码搜索

- **[强制] 代码探索先用 Semble**: 需要理解代码结构, 定位实现或查找调用关系时, 先使用 Semble 语义搜索, 再按返回路径读取文件.
- **[强制] 避免重复搜索**: Semble 已返回明确文件和行号时, 不对同一语义问题重复使用 grep 或 rg.
- **[默认] Grep/rg 边界**: 仅用于精确字符串, 全仓库字面匹配, 确认符号残留, 或 Semble 结果上下文不足时.
- **[默认] 相关实现发现**: 已定位关键实现后, 优先使用 Semble find-related 查相似实现, 调用方或测试.
<!-- source: capability-detect/mcp-semble, confirmed: true -->

### Headroom 上下文管理

- **[强制] 大内容先压缩**: 大型日志, 搜索结果, 长文件内容或大 diff 进入推理前, 优先使用 Headroom 压缩.
- **[强制] 压缩摘要保真**: 摘要必须保留用户最新目标, 已确认约束, 已改文件, 未完成事项, 验证结果, 关键决策和阻塞点.
- **[强制] 可追溯**: 压缩结果带 hash 时, 后续需要细节必须 retrieve 原文; 不得凭摘要补造细节.
<!-- source: capability-detect/mcp-headroom, confirmed: true -->

### Context7 文档查询

- **[强制] 第三方 API 先查文档**: 涉及库, 框架, SDK, CLI, 云服务, 版本迁移和配置语法时, 优先使用 Context7.
- **[强制] 先 resolve 再 query**: 除非用户提供 `/org/project` 形式的 library ID, 否则必须先解析 library ID.
- **[强制] 标注版本边界**: 文档结论涉及版本差异时, 必须说明适用版本和证据来源.
- **[默认] 不滥用**: 业务逻辑, 代码审查, 重构建议和通用编程概念不需要 Context7.
<!-- source: capability-detect/mcp-context7, confirmed: true -->

### Fetch 外部资料

- **[默认] 官方来源优先**: 外部资料优先官方文档, 规范, 仓库 README 和 release notes.
- **[强制] 外部资料不替代现场证据**: 网页只能证明机制和文档描述, 不能证明当前项目或真实账号状态.
- **[强制] 禁止请求敏感 URL**: 不请求包含 token, 私钥, 内部凭据或敏感查询参数的 URL.
<!-- source: capability-detect/mcp-fetch, confirmed: true -->

### 架构改进 Skill

- **[默认] 架构问题使用专用 skill**: 用户请求架构改进, 解耦, 降低复杂度或提升可测试性时, 使用架构改进 skill 辅助分析.
- **[强制] 不扩大范围**: 普通 bugfix 或小修改不得自动扩大为架构改造.
<!-- source: capability-detect/skill-architecture, confirmed: true -->

---

## 10. 已确认工作流策略

- OpenSpec 1.5.0 已初始化并作为项目工作流使用. 文档实体统一存放在 `docs/openspec/`, 仓库根 `openspec` 符号链接仅用于保持 CLI 从项目根运行时的路径兼容.
- Superpowers suite 未检测为完整套件, 不生成强制规则.
- `grill-me`, 制品类 skills 和 `pua` 未被确认为本项目强制能力.
- TokenSave 未检测到.
<!-- source: capability-detect, confirmed: true -->
<!-- /source: template/base -->
