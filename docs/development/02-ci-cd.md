# Bruce CI/CD 设计

| 项目 | 定义 |
|---|---|
| 文档版本 | 2.0 |
| 文档路径 | `docs/development/02-ci-cd.md` |

## 1. 目标与当前阶段

Bruce 的 CI/CD 目标是: 每次代码变更都经过与本地完全一致的验证套件, 并能一键产出可测试的 `.app` 包; 发布流程只做「打草稿」, 不做自动发布。

当前阶段 (Development Preview):

- 测试包 (未签名) 由 CI 自动构建; 正式版签名、公证和 Gatekeeper 校验暂不纳入当前 CI/CD 规划。
- 真实账号登录验收、菜单栏生命周期验收属于发布人工门禁, CI 不替代。
- CI 只做可重复的离线验证和打包构建, 不接触真实凭证、Keychain 或外部服务。

## 2. 运行器与工具链

- 运行器: 全部 job 使用 `macos-26` 公共托管镜像。
- 工具链: 运行器自带 Xcode 工具链与 Rust/Cargo, `swift --version`、`rustc --version` 和本地工具链同族.
- 运行环境准备: 镜像不含 `rg`, 打包相关 job 先用 `brew install ripgrep` 准备打包脚本的前置依赖.
- 与本地一致性: CI 直接调用仓库内 `scripts/verify-local.sh`、`scripts/build-test-app.sh` 和 `scripts/release-notes.sh`, 不复制脚本逻辑, 保证 CI 与本地验证同源.

## 3. 工作流与触发策略

工作流文件: `.github/workflows/ci.yml`.

触发:

- push 到 `main`: 全部验证 + 构建测试包。
- pull_request: 全部验证 + 构建测试包 (合并前门禁)。
- push tag `v*`: 验证通过后, 执行测试包草稿 Release (`release`)。

## 4. Job 职责

| Job | 条件 | 内容 | 失败影响 |
|---|---|---|---|
| `verify` | push / PR / tag | 打印 Rust/Swift 工具链版本, 运行 `scripts/verify-local.sh` (Rust fmt/test/Clippy + fixture scan + swift build + 全部 Harness) | 阻塞合并与全部发布 |
| `build-release-app` | push / PR / tag | 安装 ripgrep 后运行 `scripts/build-test-app.sh`, 上传 `dist/` 为 Actions artifact `Bruce-test-app` | 阻塞合并与测试包发布 |
| `release` | 仅 tag `refs/tags/`, needs verify + build-release-app | 重建测试包, 在 `dist/` 内生成 `SHA256SUMS`, 用 `scripts/release-notes.sh` 从 CHANGELOG 提取说明, `gh release create --draft` 上传 `Bruce.zip` + 校验和 + 说明 | 不阻塞 PR |

各 job 均设置 timeout (20-30 分钟), 防止运行器卡死。CI 只产出未签名 Preview 草稿 Release, 由维护者人工复核后发布。

## 5. 发布流程

发布入口是 tag (例如 `v0.4.0`):

1. 推 tag 后 `verify` 先行; 通过后 `release` 执行测试包构建和草稿 Release 创建。
2. `release` 产出未签名 Preview 草稿 Release, 附带 `Bruce.zip`、校验和和发布说明。
3. 维护者在 GitHub 上人工复核草稿, 补充发布说明后手动发布。正式版签名、公证和 Gatekeeper 校验不属于当前 CI/CD 流程。

## 6. 安全边界

- workflow 顶层 `permissions: contents: read` (最小权限); 只有 `release` job 局部放宽为 `contents: write`, 且仅在 tag 触发时执行。
- 当前 workflow 不注入 Developer ID、notary API Key 或正式 bundle ID, 不执行正式签名、公证和 Gatekeeper 校验。
- OAuth、PAT、API key 等业务凭证永不进入 CI。
- 打包产物经脚本内置扫描检查 (不含仓库绝对路径、fixture、会话数据、私钥形态)。
- 本地优先原则不变: CI 只做可重复验证, 不替代真实环境验收。

## 7. 验证与维护

- 新增 Harness 或测试时, 只需更新 `scripts/verify-local.sh` 和对应文档计数, workflow 无需改动。
- 修改 Preview 打包逻辑时改 `scripts/build-test-app.sh`, CI 自动跟随。`scripts/build-release-app.sh` 为 CI 外的正式版手工预留脚本, 当前不属于自动门禁。
- Actions 版本升级 (checkout / upload-artifact) 应跟随官方 major 版本, 升级后跑一次 `main` push 验证。

## 8. 未来扩展

- 自动更新通道 (如 Sparkle) 的密钥与 appcast 生成, 超出当前 Development Preview 范围。
