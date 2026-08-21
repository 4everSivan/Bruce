# Bruce CI/CD 设计

| 项目 | 定义 |
|---|---|
| 文档版本 | 1.0 |
| 文档路径 | `docs/development/02-ci-cd.md` |

## 1. 目标与当前阶段

Bruce 的 CI/CD 目标是: 每次代码变更都经过与本地完全一致的验证套件, 并能一键产出可测试的 `.app` 包; 发布流程只做「打草稿」, 不做自动发布。

当前阶段 (Development Preview):

- 签名、公证和可下载的正式 `.app` 发布包尚未完成 (需要完整 Xcode、开发者账号和 notarization 凭证)。
- 真实账号登录验收、菜单栏生命周期验收属于发布人工门禁, CI 不替代。
- CI 只做可重复的离线验证和测试包构建, 不接触真实凭证、Keychain 或外部服务。

## 2. 运行器与工具链

- 运行器: `macos-26` (macOS 26, 与项目最低系统版本一致; 仓库公开后也可选用 arm64 变体).
- 工具链: 运行器自带 Xcode 工具链, `swift --version` 与本地 Apple Swift 6.2.1 同族; Python 默认 3.9+.
- Python 最低版本验证: 单独 job 用 `actions/setup-python` 固定 3.9 运行, 保证 Collector 的 3.9 兼容声明不被破坏.
- 运行环境准备: macos-26 镜像默认 `python3` 为 3.14 且不含 pytest, `setup-python` 后 `python3` 别名仍指向系统解释器, 因此 Python 相关 job 统一用 `python` 命令并显式安装 pytest; 镜像不含 `rg`, 测试包构建 job 先用 `brew install ripgrep` 准备 `build-test-app.sh` 的前置依赖.
- 与本地一致性: CI 的核心 job 直接调用仓库内 `scripts/verify-local.sh` 和 `scripts/build-test-app.sh`, 不复制脚本逻辑, 保证 CI 与本地验证同源.

## 3. 工作流与触发策略

工作流文件: `.github/workflows/ci.yml`.

触发:

- push 到 `main`: 全部验证 + 构建测试包。
- pull_request: 全部验证 + 构建测试包 (合并前门禁)。
- tag `v*`: 验证通过后创建草稿 Release。

## 4. Job 职责

| Job | 运行器 | 内容 | 失败影响 |
|---|---|---|---|
| `verify` | macos-26 | 打印工具链版本, 运行 `scripts/verify-local.sh` (Python 语法 + pytest + swift build + 脚本列出的全部 Harness) | 阻塞合并与发布 |
| `python-min-version` | macos-26 | Python 3.9 下 py_compile + pytest | 阻塞合并与发布 |
| `build-release-app` | macos-26 | 运行 `scripts/build-test-app.sh`, 上传 `dist/` 为 Actions artifact (`Bruce-app`) | 阻塞合并与发布 |
| `release` | macos-26 | 仅 tag 触发, 依赖前三个 job; 重建测试包并创建**草稿** GitHub Release, 附 `Bruce.zip` | 不阻塞 PR |

各 job 均设置 timeout, 防止运行器卡死。

## 5. 发布流程

发布入口是 tag (例如 `v0.1.0`):

1. 推 tag 后 CI 先跑完验证与构建。
2. `release` job 用 `gh release create --draft` 创建草稿 Release, 附测试 zip。
3. 维护者在 GitHub 上人工复核草稿, 补充发布说明后手动发布。

签名、公证和 Gatekeeper 通过 (完整 Xcode + Developer ID 凭证) 之前, 草稿 Release 不自动转正式。未来启用正式发布时, 用仓库 secrets 注入 Developer ID Application 证书、notarization Apple ID 和 app-specific password, 并在 `release` job 中增加 `codesign --deep`、`ditto -c -k` 和 `xcrun notarytool` 步骤, 全部产物先上传草稿, 由人工确认后发布。

## 6. 安全边界

- workflow 顶层 `permissions: contents: read` (最小权限); 只有 `release` job 局部放宽为 `contents: write`, 且仅在 tag 触发时执行。
- 不使用任何自定义 secrets; 凭证 (OAuth、PAT、API key) 永不进入 CI。
- CI 的测试包构建与本地 `build-test-app.sh` 相同, 不含仓库绝对路径和敏感信息 (脚本内已内置扫描检查)。
- 本地优先原则不变: CI 只做可重复验证, 不替代真实环境验收。

## 7. 验证与维护

- 新增 Harness 或测试时, 只需更新 `scripts/verify-local.sh` 和对应文档计数, workflow 无需改动。
- 修改构建打包逻辑时改 `scripts/build-test-app.sh`, CI 自动跟随。
- Actions 版本升级 (checkout / setup-python / upload-artifact) 应跟随官方 major 版本, 升级后跑一次 `main` push 验证。

## 8. 未来扩展

- 完整 Xcode archive、签名、公证与 Gatekeeper 验证 (需要开发者账号凭证)。
- 正式 Release 发布门禁 (人工确认草稿)。
- 自动更新通道 (如 Sparkle) 的密钥与 appcast 生成, 超出当前 Development Preview 范围。
