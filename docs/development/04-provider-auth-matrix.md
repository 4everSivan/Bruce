# Provider 登录与授权矩阵

| 项目 | 定义 |
|---|---|
| 文档版本 | 2.0 |
| 文档路径 | `docs/development/04-provider-auth-matrix.md` |
| 事实源优先级 | 本表与代码不一致时以 `ProviderRegistry.swift`、`CollectorRunInput.swift` 和 Rust `collector-bridge/src/lib.rs` 的 `ALLOWED_CREDENTIAL_FIELDS` 为准 |
| 适用平台 | Bruce 支持的 Agent 数据源与订阅额度 Provider |

本矩阵区分「读取既有本机会话」和「应用持有可访问外部服务的凭证」。不得复制第三方 OAuth client secret, 不得模拟账号密码登录, 也不得截获其他 CLI 的回调。订阅凭证统一保存在 macOS Keychain service `com.bruce.dashboard.credentials`, 运行时经 Bridge stdin 单次请求注入, 不进入命令行参数、Artifact 或日志。

## 会话数据源 (只读扫描)

| 数据源 | 方式 | 凭证需求 |
|---|---|---|
| Kimi Work / Kimi Code、Claude Code、Codex、Grok、OpenCode、Orca、Pi、ZCode、CodeBuddy | Collector 只读本机既有会话记录 | 无 (不读密码, 不写会话) |
| CC Switch SQLite 与 Antigravity 会话库 | SQLite URI `mode=ro` 一次性只读导入/探测 | 无 |

## 订阅额度 Provider 矩阵

App 模式下每个 Provider 由 `ProviderRegistry` 登记: 凭证账号键 → 注入 kind → 配置判定规则。

| Provider | 用户配置凭证 | Keychain 账号键 | Bridge 注入字段 | 配置判定 | 外部端点 | 自动续期 |
|---|---|---|---|---|---|---|
| Kimi | Kimi For Coding API Key | `kimi:api-key` | `kimiQuotaAccounts` (`api_key`) | 所有凭证账号非空 | Kimi API | 不适用 (静态 key) |
| DeepSeek | API Key | `deepseek:api-key` | `deepseekQuotaAccounts` (`api_key`) | 所有凭证账号非空 | DeepSeek 官方用量接口 | 不适用 (静态 key) |
| 火山引擎 Coding Plan | Access Key + Secret Key | `volcengine:ak` / `volcengine:sk` | `volcengineQuotaAccounts` (`accessKeyId`/`secretAccessKey`) | 所有凭证账号非空 | 火山引擎官方接口 | 不适用 (静态 AK/SK) |
| 智谱 GLM Coding Plan | API Key (+ 可选 base URL) | `zhipu:api-key` / `zhipu:base-url` | `zhipuQuotaAccounts` (`api_key`/`base_url`) | 所有凭证账号非空 | 智谱 BigModel 接口 | 不适用 (静态 key) |
| Codex OAuth | 无手工输入; 从 CC Switch `codex_oauth_auth.json` 或 Codex CLI `~/.codex/auth.json` 一次性只读导入账号索引 | `codex:accounts` (v2 分账号索引) + 分账号记录 | `codexQuotaAccounts` (`access_token`), 附 `context.codexQuotaAccountOrder` | 存在已配置分账号记录 | OpenAI (ChatGPT 后端) | 运行时经 token manager 决议短期 access token; 刷新由官方链路维护 |
| Antigravity | OAuth JSON (官方客户端登录产物) | `antigravity:oauth` | `antigravityOAuth` / `antigravityQuotaAccounts` | 所有凭证账号非空 | **当前无额度查询实现**: 纯 Rust collector 的 provider 适配器表中没有 Antigravity, 注入字段暂无消费方 (见 `docs/development/07-dead-flow-and-migration-leftover-audit.md`) | 由官方客户端维护; Collector 端「文件优先, 登录 Keychain 回退」只读 |
| Claude | 无需手工配置 (可选导入 OAuth 快照) | `claude:oauth` | `providerMeta.claude.enabled` + 可选 `claudeQuotaAccounts` (`oauth`) | 应用内有效凭证或本机 CLI 登录态探测命中 | `api.anthropic.com/api/oauth/usage` | 只读本机 CLI 登录态: Keychain `Claude Code-credentials` 优先, `~/.claude/.credentials.json` 兜底; 不刷新, 不回写 |
| Grok | 无需手工配置 (可选导入 OAuth 快照) | `grok:oauth` | `providerMeta.grok.enabled` + 可选 `grokQuotaAccounts` (`oauth`) | 应用内有效凭证或本机 CLI 登录态探测命中 | grok.com gRPC-web 账单接口 | 只读 `~/.grok/auth.json` (OIDC scope 优先, legacy `/sign-in` 兜底); protobuf 解析失败抛可诊断错误, 不伪造用量 |
| OpenCode Go | 浏览器登录 opencode.ai 后复制 auth cookie (`Fe26.2**...`) 与 workspace URL 中的 `wrk_` ID, 粘贴 JSON | `opencode-go:oauth` | `opencodeGoQuotaAccounts` | 所有凭证账号非空 | `opencode.ai/_server` 服务端计量, 跨机器汇总 | 无自动续期; 会话失效时返回「请重新登录」错误, 由用户重新粘贴 |

CLI 直跑模式下云端额度条目仍可由 CC Switch providers 行驱动; App 模式完全由上述 Keychain 注入驱动, 不要求 CC Switch 数据库存在。App 模式运行时不读 `~/.codex/auth.json`, Codex 活跃账号由分账号注入承载。

## 实施规则

- 应用内登录窗口只是 Bruce 的原生进度和状态窗口; 实际账号密码只在 provider 官方浏览器页、设备授权页或官方 CLI 中输入。
- 当前仓库未使用 `ASWebAuthenticationSession` 接收 OAuth 回调; Codex 设备码流由 Bruce 轮询 OpenAI 官方设备授权端点完成, 不复用第三方 client secret。
- 凭证轮换经 `credentialUpdates` 只写回应用 Keychain, 不回写 CC Switch、第三方认证文件或其他应用的登录 Keychain。
- Antigravity 额度查询的 OAuth client 凭证 (`AGY_CLIENT_ID` / `AGY_CLIENT_SECRET`) 若未来补齐查询链路, 由运行环境注入, 缺省为空时刷新链路安全降级; 不得硬编码入库。
- 未配置任何 Provider 时订阅卡片不渲染; 已启用但凭证损坏按缺失处理 (fail-closed, 不授予 externalQuotas)。
- Bridge 对 credentials 字段做白名单校验 (`ALLOWED_CREDENTIAL_FIELDS`), 未登记字段直接拒绝请求。

## 待外部配置

- 最终发布 bundle identifier 与 OAuth callback scheme。
- 火山引擎和企业的最小权限账号策略。

这些配置未确认时必须使用表中降级路径, 不得自行发明 OAuth client 或复制第三方 client secret。
