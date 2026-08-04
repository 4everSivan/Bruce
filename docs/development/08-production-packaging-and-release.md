# mddd 正式版打包与发布流程

> 版本: 1.0  
> 日期: 2026-08-04  
> 适用范围: macOS 菜单栏 App 的预览版和正式版构建、签名、公证、验收与回滚  
> 实施状态: 流程规范已落地为脚本与 CI. `scripts/build-release-app.sh` 已实现 (08 §3 五阶段, 版本来源 Git tag, Developer ID + Hardened Runtime + notarization, 产物含 SHA256SUMS/release-notes); `scripts/entitlements-release.plist` 最小 entitlement; `.github/workflows/ci.yml` 增加 protected `release-sign` job (仅 tag v* 触发, 凭证从 Secret 读取, PR 永不接触). `scripts/build-test-app.sh` 修复阶段 D 拆分后 collector 子模块未打包的回归 (6 个 .py 模块全部复制). 前置条件 (Developer ID 证书/公证 API Key/正式 bundle ID) 仍未配置, 未配置时脚本在对应阶段清晰失败, 不生成半成品.

## 1. 发布渠道定义

| 渠道 | 用途 | 签名/公证 | 允许内容 |
|---|---|---|---|
| Preview | 本地开发和内部测试 | 当前 ad-hoc 签名即可 | 可包含诊断开关, 不作为公开分发 |
| Release | 面向用户的正式下载包 | Developer ID + Hardened Runtime + Apple notarization | 只包含生产资源和最小权限 |

当前 `scripts/build-test-app.sh` 只生成 `dist/mddd-test.app` 和压缩包, 使用固定测试 bundle ID/version、ad-hoc 签名且未执行公证. 它继续作为 Preview 流程, 不得被称为正式版.

正式版采用 Developer ID 分发路径. Apple 对于 App Store 外分发的软件要求使用 Developer ID 签名, 开启 Hardened Runtime, 并通过 `notarytool` 提交公证; 公证后使用 `stapler` 将票据附加到 App. 参考 [Apple notarization documentation](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

## 2. 正式版前置条件

### 2.1 本机和 CI 凭证

- Apple Developer Program 团队和有效 Developer ID Application 证书.
- 用于公证的 App Store Connect API Key (`key ID`、`issuer ID`、私钥文件).
- CI 受保护变量或密钥存储, 不得提交到仓库.
- `xcodebuild`、`codesign`、`notarytool`、`stapler`、`spctl` 可用.
- 构建机器使用项目要求的 macOS/Swift 工具链.

### 2.2 版本来源

正式版必须只有一个版本来源, 建议使用 Git tag:

```text
tag v<major>.<minor>.<patch>
CFBundleShortVersionString = <major>.<minor>.<patch>
CFBundleVersion = CI 递增构建号
```

脚本启动时校验 tag、bundle ID、短版本号和构建号, 不一致直接失败. 禁止沿用测试脚本中的固定 `0.1.0/1`.

### 2.3 资源与敏感信息门禁

构建输入不得包含:

- OAuth access/refresh token、Keychain 导出、私钥、API Key.
- `data/*.json`、本机会话数据库或个人路径.
- 未批准的调试日志和临时文件.

构建前后都要执行敏感字段扫描, 并检查 `dist/` 只包含本次构建生成的文件.

## 3. 建议的正式版脚本

新增 `scripts/build-release-app.sh`, 与 Preview 脚本分开, 按以下阶段执行. 本文只定义流程, 不在本次文档更新中执行.

### 阶段 1: 清理和验证

1. 检查工作树干净, 或仅允许 CI 生成目录.
2. 从 tag 解析版本号和构建号.
3. 执行 `zsh scripts/verify-local.sh`.
4. 执行 Python/Swift/Widget 的静态敏感信息扫描.
5. 创建唯一临时 staging 目录, 不复用旧 `dist/` 内容.

### 阶段 2: Release 构建

1. `swift build --configuration release --package-path macos/MdddApp`.
2. 使用 Release 产物组装 `Mddd.app`.
3. 写入正式 bundle ID、版本号、构建号和最小 Info.plist.
4. 复制运行时需要的 Collector、Widget 和资源, 排除测试 Harness、fixture、源码缓存和本机数据.
5. 对嵌套二进制、Helper 和 App 进行签名前结构检查.

### 阶段 3: Hardened Runtime 与签名

1. 为 App 建立显式 entitlements 文件, 只声明当前功能需要的权限.
2. 使用 Developer ID Application 证书按由内到外的顺序签名嵌套内容和 App.
3. 执行 `codesign --verify --deep --strict --verbose=2`.
4. 执行 `codesign -dvv` 和 entitlements 检查, 确认没有 ad-hoc 签名、临时证书或调试 entitlement.

### 阶段 4: 公证与装订票据

1. 将签名后的 App 打成稳定命名的 zip.
2. 使用 `xcrun notarytool submit ... --wait` 提交公证.
3. 公证失败时保存 request ID、脱敏日志和失败原因, 不发布任何包.
4. 公证成功后执行 `xcrun stapler staple Mddd.app`.
5. 执行 `xcrun stapler validate Mddd.app`.

### 阶段 5: Gatekeeper 验证与产物生成

1. 执行 `spctl --assess --type execute --verbose=4 Mddd.app`.
2. 在干净用户环境中首次启动, 检查菜单栏、设置页、授权、刷新和退出.
3. 重新压缩装订后的 App.
4. 生成 `SHA256SUMS`.
5. 生成脱敏 release notes, 列出版本、变更、已知限制和回滚版本.

## 4. CI 正式发布 Job

在 `.github/workflows/ci.yml` 增加独立的 protected release job, 不要把正式凭证放进普通 PR job:

```text
tag v*                         # 触发
  -> verify                    # 完整离线验证
  -> build-release             # Release 构建与敏感信息门禁
  -> sign                      # protected runner + Developer ID
  -> notarize                  # notarytool --wait
  -> staple-and-verify         # stapler + spctl + clean-user smoke
  -> checksum-and-draft        # 生成校验和并创建草稿 Release
  -> manual approval           # 发布前人工确认
  -> publish                   # 上传 App zip、校验和、说明
```

CI 规则:

- Pull Request 只能运行 Preview/验证任务, 不接触签名和公证凭证.
- 正式发布只接受保护分支和符合格式的 tag.
- 每次 release 保存构建日志、notary request ID、校验和和版本元数据.
- 任何签名、公证、Gatekeeper 或敏感信息门禁失败都不得上传可下载资产.

## 5. 正式版验收矩阵

### 5.1 构建和安全

- [ ] 版本号来自 tag, bundle ID 为正式值.
- [ ] 所有嵌套代码使用 Developer ID 签名.
- [ ] Hardened Runtime 生效, entitlement 最小化.
- [ ] `notarytool` 成功, ticket 已 staple.
- [ ] `codesign`、`stapler`、`spctl` 全部通过.
- [ ] 包内无 token、私钥、`data/`、测试 fixture 和调试产物.

### 5.2 功能和数据

- [ ] 菜单栏图标可启动, 面板可打开和关闭.
- [ ] 设置页可完成授权、撤销和重新授权.
- [ ] 自动刷新、手动刷新、失败诊断和下次排程正常.
- [ ] Codex 多账号状态、过期恢复、重新授权提示和旧 artifact 读取正常.
- [ ] CLI/Collector 不会被 App 模式意外读取的本机认证文件污染.
- [ ] 离线或服务失败时保留可解释的旧成功状态, 不把失败显示为成功.

### 5.3 安装和升级

- [ ] 干净 macOS 用户首次安装通过 Gatekeeper.
- [ ] 从上一正式版升级后 Keychain、设置和本地缓存可读.
- [ ] 降级到上一版本时不会破坏旧 artifact 或凭证索引.
- [ ] 卸载/移除 App 后不自动删除用户明确保存的数据.

## 6. 发布产物

每个正式版本至少包含:

```text
mddd-<version>-macos.zip
SHA256SUMS
release-notes-<version>.md
```

内部归档还应保存:

- 未公开的构建元数据和 CI run URL.
- notary request ID 与脱敏状态.
- 签名证书标识和 entitlements 摘要.
- 完整验证命令及结果.

不把 Developer ID 私钥、公证 API 私钥或用户认证数据放入发布资产.

## 7. 回滚流程

触发条件包括 Gatekeeper 失败、首次启动崩溃、Keychain 迁移失败、刷新链路产生错误写回或严重 artifact 不兼容.

回滚步骤:

1. 暂停当前版本下载链接和自动更新引用.
2. 保留已发布 zip、校验和与诊断信息, 不覆盖证据.
3. 将下载入口切换到上一通过验收的正式版本.
4. 发布回滚说明, 明确受影响版本和用户操作.
5. 使用上一版本验证旧 artifact、Keychain 和授权状态.
6. 修复后重新走完整 tag、签名、公证和人工验收流程.

## 8. 当前阻塞与完成标准

当前仓库尚未配置 Developer ID 证书、公证 API Key、正式 bundle ID 和 release entitlements. 在这些前置条件完成前, 只能生成 Preview 测试包, 不能把现有 `mddd-test.app` 称为正式版.

正式发布流程完成的判定标准:

- `scripts/build-release-app.sh` 可在干净环境重复生成同版本结构一致的 App.
- CI 保护 Job 能完成签名、公证、装订和 Gatekeeper 验证.
- 正式版验收矩阵全部勾选, 产物带校验和和脱敏说明.
- 回滚版本已准备并通过旧数据/凭证兼容验证.
