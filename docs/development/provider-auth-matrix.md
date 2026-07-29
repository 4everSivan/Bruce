# Provider 登录与授权矩阵

本矩阵区分“读取既有本机会话”和“应用持有可访问外部服务的凭证”. 首版不得复制第三方 OAuth client secret, 不得模拟账号密码登录, 也不得在未注册桌面 OAuth 应用时截获其他 CLI 的回调.

| Provider / 数据源 | 当前仓库证据 | 官方可用方式 | mddd MVP 策略 | 自动续期 |
|---|---|---|---|---|
| Kimi Work | 只读本机会话记录 | 使用 Kimi 官方应用登录 | 扫描既有会话; 应用提供“打开官方登录”入口, 不读取密码 | 由官方应用维护 |
| Kimi Code | 本机会话和现有 OAuth token | `kimi login` 使用 OAuth device-code; API key 可手动配置 | 优先从应用启动 `kimi login` 并展示进度窗口; API key 作为 Keychain 回退 | 官方 CLI 或 mddd Keychain adapter |
| Claude Code | 只读本机会话; 服务额度来自 CC Switch provider | 既有 Claude Code/CC Switch 登录或 API key | 首版不复制 Claude 登录态; 扫描会话, 额度凭证按 provider 单独配置 | 取决于对应 provider |
| Codex CLI / Orca | 只读会话及既有 Codex 登录缓存 | `codex login` 浏览器登录、`codex login --device-auth`、API key stdin | 从应用启动官方 CLI 登录并检查 `codex login status`; 不复用仓库内硬编码 OAuth client | Codex 官方登录自动刷新; API key 无刷新令牌 |
| GitHub | `gh api graphql` 使用本机 `gh` 登录态 | `gh auth login --web`; PAT 可通过 stdin | 首选从应用启动 `gh auth login --web`; 应用内只显示状态和官方页面进度 | 由 `gh` 凭证存储维护 |
| 私有 GitLab | 当前从本机明文文件读取 PAT | OAuth authorization code + PKCE、GitLab 17.1+ device flow、PAT、`glab auth` | 实例注册 OAuth app 时使用 PKCE; 否则使用 `glab` web flow 或 Keychain PAT | OAuth refresh token; PAT 到期后重新配置 |
| DeepSeek | CC Switch provider env | API key | 应用安全输入后写入 Keychain; 不提供账号密码窗口 | 不适用 |
| 火山引擎 Coding Plan | CC Switch provider env/meta | Access Key / Secret Key 或对应官方授权能力 | 首版使用 Keychain 手动配置; 不把 AK/SK 写入 Artifact | 不适用 |
| Antigravity / Google Cloud Code | 读取 Antigravity OAuth token 与只读会话库 | 由官方 Antigravity/Google 客户端完成 OAuth | 扫描既有登录态; 首版启动官方登录入口, 不复用第三方 client secret | 由官方客户端维护 |

## 实施规则

- 应用内“登录窗口”是 mddd 的原生进度和状态窗口; 实际账号密码只在 provider 官方浏览器页、设备授权页或官方 CLI 中输入.
- 只有 mddd 自己注册并配置了 OAuth client 的 provider, 才能由 `ASWebAuthenticationSession` 接收回调.
- 支持 OAuth 的私有 GitLab 优先使用 authorization code + PKCE 和最小 `read_user` / `read_api` scope.
- GitHub 首版复用 `gh` 的系统凭证存储, 不调用 `gh auth token --show-token`, 不把 token 导入 mddd.
- Codex 首版复用官方 `codex login`; mddd 不直接刷新或覆盖 `~/.codex/auth.json`.
- Kimi Code 首版复用官方 device-code 登录; mddd 不直接覆盖 Kimi token 文件.
- PAT、API key、AK/SK 只允许写入 macOS Keychain, 传给 Collector 时使用 stdin, 不放入命令行参数.
- 私有 GitLab 必须支持配置内部 CA; 禁止以关闭 TLS hostname 或证书校验作为产品默认值.

## 官方依据

- [GitHub CLI `gh auth login`](https://cli.github.com/manual/gh_auth_login)
- [GitLab OAuth provider](https://docs.gitlab.com/integration/oauth_provider/)
- [GitLab OAuth 2 API 与 PKCE/device flow](https://docs.gitlab.com/api/oauth2/)
- [GitLab PAT](https://docs.gitlab.com/user/profile/personal_access_tokens/)
- [Kimi Code `kimi login`](https://www.kimi.com/code/docs/en/kimi-code-cli/reference/kimi-command.html)
- [Kimi Code provider 与 API key](https://www.kimi.com/code/docs/en/kimi-code-cli/configuration/providers.html)
- [Codex authentication](https://learn.chatgpt.com/docs/auth)

## 待外部配置

- 私有 GitLab 是否允许创建用户级或实例级 OAuth application.
- 最终发布 bundle identifier 与 OAuth callback scheme.
- 火山引擎、DeepSeek 和企业 CC Switch provider 的最小权限账号策略.

这些配置未确认时必须使用表中降级路径, 不得自行发明 OAuth client 或复制第三方 client secret.
