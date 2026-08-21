## ADDED Requirements

### Requirement: Artifact 与运行元数据分离

系统必须 (MUST) 将可展示业务数据放入 `artifact`, 将凭证候选更新放入 `credentialUpdates`, 将运行诊断放入 `diagnostics`. 任何凭证或认证响应不得进入 Widget 可见的 Artifact.

#### Scenario: 处理 Bridge 响应

- **WHEN** Swift 运行时收到有效 Bridge 响应
- **THEN** 系统分别校验并路由三个数据区, 只将 `artifact` 提供给缓存和 Widget

#### Scenario: Artifact 疑似包含凭证

- **WHEN** Artifact 在敏感字段检查中匹配访问令牌、刷新令牌、私钥或 Cookie 字段
- **THEN** 系统拒绝发布和持久化该 Artifact, 并生成脱敏协议错误

### Requirement: 发布前 schema 校验

系统必须 (MUST) 为 Agent、GitHub 和 GitLab Artifact 定义可版本化的 schema, 并在替换当前快照前校验必需字段、字段类型、时间值和模块标识.

#### Scenario: 新快照通过校验

- **WHEN** Collector 返回与模块和受支持 schema 版本匹配的 Artifact
- **THEN** 系统将其标记为候选成功快照并进入原子持久化流程

#### Scenario: 新快照校验失败

- **WHEN** Collector 返回缺字段、错误类型、无效日期或模块不匹配的 Artifact
- **THEN** 系统拒绝替换当前快照, 保留校验错误和最后成功数据

### Requirement: 原子本机快照

系统必须 (MUST) 将应用快照存储在 `~/Library/Application Support/Bruce/` 下的应用专用目录, 先写入临时文件并完成同步与校验后原子替换目标文件. 系统必须始终保留最近一次成功快照.

#### Scenario: 成功写入快照

- **WHEN** 候选 Artifact 校验通过且磁盘写入成功
- **THEN** 系统原子替换对应模块当前快照, 并更新成功时间元数据

#### Scenario: 写入过程中应用中断

- **WHEN** 应用在临时文件写入或替换前中断
- **THEN** 下次启动仍能读取替换前的完整成功快照, 且忽略或清理不完整临时文件

### Requirement: 过期状态与降级展示

系统必须 (MUST) 在刷新失败时继续提供最近一次成功快照, 并把快照年龄、最近尝试时间和失败类别作为独立状态提供给 UI. 系统不得把旧数据伪装为刚刚成功获取的数据.

#### Scenario: 刷新失败但存在缓存

- **WHEN** 某模块刷新失败且存在最近成功快照
- **THEN** 系统继续展示该快照, 明确标注数据更新时间和当前失败状态

#### Scenario: 刷新失败且没有缓存

- **WHEN** 某模块首次刷新失败且没有成功快照
- **THEN** 系统显示可操作的错误或配置状态, 不构造零值热力图或虚假用量

### Requirement: schema 兼容与迁移边界

系统必须 (MUST) 根据 `schemaVersion` 选择明确的读取器. 对受支持的旧版本可以执行纯本机、可回滚迁移; 对未知新版本必须安全拒绝, 不得猜测字段含义.

#### Scenario: 读取受支持旧版本

- **WHEN** 应用启动时发现可迁移的旧版本快照
- **THEN** 系统保留原文件或备份, 迁移副本并重新校验后再发布

#### Scenario: 读取未知新版本

- **WHEN** 应用发现高于当前支持范围的 schema 版本
- **THEN** 系统不渲染该数据, 保留原文件, 并提示需要升级应用或重新采集

### Requirement: 本机数据保护与仓库隔离

系统必须 (MUST) 使用当前用户专属权限创建缓存和诊断目录, 并确保运行产物不会默认写入仓库的 `data/` 或其他版本控制路径. 用户主动导出诊断时必须先脱敏.

#### Scenario: 创建应用数据目录

- **WHEN** 应用首次需要持久化快照
- **THEN** 系统在 Application Support 中创建仅当前用户可访问的目录和文件

#### Scenario: 用户导出诊断

- **WHEN** 用户选择导出用于排查的诊断包
- **THEN** 系统排除 Keychain 数据和原始凭证, 对账号及路径执行脱敏, 并在导出前展示内容范围
