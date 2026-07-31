# 发布人工验收清单

| 项目 | 定义 |
|---|---|
| 文档版本 | 1.0 |
| 文档路径 | `docs/development/05-release-acceptance.md` |
| 适用平台 | macOS 26 及以上, 完整 Xcode + Developer ID 签名环境 |

本文记录不能由默认离线测试替代的发布门禁。只有获得用户明确授权、使用预期发布签名和真实个人账号完成现场验收后, 才能在 OpenSpec 中勾选 12.5、12.6 和 12.8。

## 前置条件

- 安装并选择完整 Xcode, 确认发布 Team、bundle identifier 和版本号。
- 使用隔离的验收账号或用户明确指定的个人账号。
- 明确本轮允许访问的 Agent Provider。
- 验收前记录 `~/Library/Application Support/mddd/` 和 Keychain service `com.mddd.dashboard.credentials` 的初始状态。
- 不在录屏、截图、终端历史或缺陷文档中记录 PAT、OAuth code、Cookie、邮箱、仓库私有名称或完整用户路径。

## 构建、签名和安装

- [ ] 使用 Xcode Archive 生成 Release 构建。
- [ ] 核对 entitlements、Hardened Runtime、网络和 Keychain 能力均为最小范围。
- [ ] 验证签名链、notarization 和 Gatekeeper。
- [ ] 从干净目录安装 `.app`, 首次启动菜单栏出现品牌图标, 无多余进程。
- [ ] 点击菜单栏标签弹出面板, 关闭设置窗口后再次打开不创建第二个 Scheduler。
- [ ] 退出时运行中的 Collector 在宽限期内取消, 无残留 Python 子进程。

## 真实登录与撤销

### Agent Provider

- [ ] 每个获准 Provider 使用官方登录窗口、设备授权或官方 CLI。
- [ ] 登录成功、用户取消、授权失效和撤销不会修改第三方应用数据库。
- [ ] 未授权 `externalQuotas` 时不发起额度网络请求。
- [ ] 账号信息功能若参考 CC Switch, 仍只读取已声明的只读数据, 不复制其凭证。

## 长时运行与恢复

- [ ] 已授权模块默认每 30 分钟刷新一次, 关闭自动刷新后只保留手动刷新。
- [ ] 同模块重复点击最多合并为一次后续重跑, 不出现并发 Collector。
- [ ] 不同模块在并发上限内独立运行, 单模块失败不取消其他模块。
- [ ] 跨越至少两个刷新周期的系统睡眠只触发一次唤醒补偿。
- [ ] 离线、rate limit 和临时错误有限退避; 永久认证错误停在 `authRequired`。
- [ ] 刷新失败保留最后成功快照, current 损坏时可回退 previous。
- [ ] 令牌续期、撤销和退出路径没有重复请求或残留子进程。

## 可访问性与视觉

- [ ] VoiceOver 可读出菜单栏标签摘要、面板卡片、模块状态、刷新、设置和诊断操作。
- [ ] 仅使用键盘可完成刷新 (`⌘R`)、设置操作和诊断预览/关闭。
- [ ] refreshing、partial、stale、offline、authRequired、error 和 notConfigured 同时具有文字、图标和可访问性语义。
- [ ] 增加对比度、减少动态效果、浅色和深色模式下保持现有视觉语言, 无不可读状态。
- [ ] Agent 的基线布局、字体层级和卡片表达没有非预期变化。

## 敏感信息复核

- [ ] Activity Monitor 或 `ps` 中的进程参数不包含测试凭证。
- [ ] Collector 子进程环境只有固定白名单, 不继承 Provider key 或带凭证的 proxy 环境。
- [ ] Console、应用错误、Bridge stdout/stderr 摘要不包含凭证、邮箱或完整路径。
- [ ] Application Support 快照不包含凭证字段; 权限保持目录 `0700`、文件 `0600`。
- [ ] 诊断预览和解压后的 ZIP 只有状态元数据, 不含 Artifact、账号、仓库、host、邮箱和完整路径。
- [ ] Widget DOM 和 Web Inspector 中不存在凭证或原生能力通道。

## 清理与回滚

- [ ] 在设置页撤销全部授权并分别断开应用持有凭证的模块。
- [ ] 退出应用后删除验收用 Application Support 数据。
- [ ] 在“钥匙串访问”中确认验收用 `com.mddd.dashboard.credentials` 项已删除。
- [ ] 在仓库平台和 Provider 官方页面撤销验收期间创建的远端授权。
- [ ] 回滚到上一兼容 Bridge v1 / Artifact v1 构建后, previous 快照仍可读。

## 验收记录

记录日期、macOS/Xcode 版本、应用版本、签名 Team、被验收的能力范围和结果。只记录错误类别和脱敏复现步骤, 不记录真实账号标识或数据内容。
