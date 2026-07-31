# Provider 登录与授权矩阵

| 项目 | 定义 |
|---|---|
| 文档版本 | 1.0 |
| 文档路径 | `docs/development/04-provider-auth-matrix.md` |
| 适用平台 | mddd 支持的 Agent Provider (Kimi / Codex / DeepSeek / 火山引擎 / Antigravity) |

本矩阵区分“读取既有本机会话”和“应用持有可访问外部服务的凭证”. 首版不得复制第三方 OAuth client secret, 不得模拟账号密码登录, 也不得在未注册桌面 OAuth 应用时截获其他 CLI 的回调.

| Provider / 数据源 | 当前仓库证据 | 官方可用方式 | mddd MVP 策略 | 自动续期 |
|---|---|---|---|---|
| Kimi Work | 只读本机会话记录 | 使用 Kimi 官方应用登录 | 扫描既有会话; 应用提供“打开官方登录”入口, 不读取密码 | 由官方应用维护 |
| Kimi Code | 本机会话和现有 OAuth token | `kimi login` 使用 OAuth device-code; API key 可手动配置 | 优先从应用启动 `kimi login` 并展示进度窗口; API key 作为 Keychain 回退 | 官方 CLI 或 mddd Keychain adapter |
| Claude Code | 只读本机会话; 服务额度来自 CC Switch provider | 既有 Claude Code/CC Switch 登录或 API key | 首版不复制 Claude 登录态; 扫描会话, 额度凭证按 provider 单独配置 | 取决于对应 provider |
| Codex CLI / Orca | 只读会话及既有 Codex 登录缓存 | `codex login` 浏览器登录、`codex login --device-auth`、API key stdin | 从应用启动官方 CLI 登录并检查 `codex login status`; 不复用仓库内硬编码 OAuth client | Codex 官方登录自动刷新; API key 无刷新令牌 |
| DeepSeek | CC Switch provider env | API key | 应用安全输入后写入 Keychain; 不提供账号密码窗口 | 不适用 |
| 火山引擎 Coding Plan | CC Switch provider env/meta | Access Key / Secret Key 或对应官方授权能力 | 首版使用 Keychain 手动配置; 不把 AK/SK 写入 Artifact | 不适用 |
| Antigravity / Google Cloud Code | 读取 Antigravity OAuth token 与只读会话库 | 由官方 Antigravity/Google 客户端完成 OAuth | 扫描既有登录态; 首版启动官方登录入口, 不复用第三方 client secret | 由官方客户端维护 |

## 实施规则

- 应用内“登录窗口”是 mddd 的原生进度和状态窗口; 实际账号密码只在 provider 官方浏览器页、设备授权页或官方 CLI 中输入.
- 只有 mddd 自己注册并配置了 OAuth client 的 provider, 才能由 `ASWebAuthenticationSession` 接收回调.
- Codex 首版复用官方 `codex login`; mddd 不直接刷新或覆盖 `~/.codex/auth.json`.
- Kimi Code 首版复用官方 device-code 登录; mddd 不直接覆盖 Kimi token 文件.
- PAT、API key、AK/SK 只允许写入 macOS Keychain, 传给 Collector 时使用 stdin, 不放入命令行参数.

## 官方依据

- [Kimi Code `kimi login`](https://www.kimi.com/code/docs/en/kimi-code-cli/reference/kimi-command.html)
- [Kimi Code provider 与 API key](https://www.kimi.com/code/docs/en/kimi-code-cli/configuration/providers.html)
- [Codex authentication](https://learn.chatgpt.com/docs/auth)

## 待外部配置

- 最终发布 bundle identifier 与 OAuth callback scheme.
- 火山引擎、DeepSeek 和企业 CC Switch provider 的最小权限账号策略.

这些配置未确认时必须使用表中降级路径, 不得自行发明 OAuth client 或复制第三方 client secret.
