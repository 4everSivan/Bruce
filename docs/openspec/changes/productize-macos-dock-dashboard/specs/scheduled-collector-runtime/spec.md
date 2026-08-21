## ADDED Requirements

### Requirement: 默认 30 分钟自动刷新

系统必须 (MUST) 为每个已启用且已授权的模块默认每 30 分钟安排一次刷新. 用户必须能够关闭自动刷新, 且手动刷新入口始终可用.

#### Scenario: 到达刷新周期

- **WHEN** 已启用模块距离最近一次成功或已完成尝试达到 30 分钟, 且当前没有同模块任务
- **THEN** 系统为该模块提交一次后台刷新并更新运行状态

#### Scenario: 自动刷新被关闭

- **WHEN** 用户关闭全局或模块级自动刷新
- **THEN** 系统不再为对应范围创建周期任务, 但仍允许用户手动刷新

### Requirement: 唤醒补偿与调度合并

系统必须 (MUST) 在 Mac 从睡眠恢复或应用重新获得运行机会时检查模块是否过期. 系统必须合并重复触发, 不得因错过多个周期而并发补跑多次.

#### Scenario: 睡眠后快照已过期

- **WHEN** Mac 唤醒且已启用模块距离上次成功刷新超过 30 分钟
- **THEN** 系统为该模块最多提交一次补偿刷新

#### Scenario: 多个触发同时到达

- **WHEN** 定时器、唤醒事件和手动刷新在同一模块任务开始前后到达
- **THEN** 系统合并自动触发, 并将用户手动请求标记为可见的当前任务或一次后续重跑, 不启动并发 Collector

### Requirement: 单模块互斥与跨模块隔离

系统必须 (MUST) 保证同一模块同一时间最多运行一个 Collector, 同时允许不同模块在资源限制内独立运行. 一个模块失败不得取消其他模块的任务.

#### Scenario: 重复刷新同一模块

- **WHEN** 某模块已有运行中的 Collector 且又收到刷新请求
- **THEN** 系统复用当前任务状态或合并为一次后续请求, 而不是启动第二个同模块进程

#### Scenario: 单个模块失败

- **WHEN** GitLab Collector 失败而 Agent 和 GitHub Collector 可正常工作
- **THEN** 系统仅将 GitLab 标记为失败或过期, 并允许其他模块继续完成和发布新快照

### Requirement: 版本化 Collector Bridge

系统必须 (MUST) 通过受控 Python 子进程调用现有 Collector, 使用版本化 JSON 请求和响应协议. Bridge 响应必须包含 `schemaVersion`、`runId`、`generatedAt`、`status`、`artifact`、`credentialUpdates` 和 `diagnostics`.

#### Scenario: Bridge 成功返回

- **WHEN** Collector 完成数据采集并输出受支持版本的有效响应
- **THEN** 系统校验运行标识和响应 schema, 分别处理 Artifact、凭证更新和脱敏诊断

#### Scenario: Bridge 输出被污染

- **WHEN** 子进程在标准输出中混入非 JSON 文本、返回未知 schema 版本或缺少必需字段
- **THEN** 系统拒绝发布该响应, 保留最后成功快照, 并记录不包含凭证的协议错误

### Requirement: 凭证仅通过受控输入传递

系统必须 (MUST) 在 App 模式下通过子进程标准输入或等价的私有进程通道传递最小必要凭证. Python Bridge 不得直接更新 Keychain、认证文件或第三方应用数据库, 只能在 `credentialUpdates` 中返回候选更新.

#### Scenario: Collector 获得临时凭证

- **WHEN** Swift 运行时启动需要认证的 Collector
- **THEN** 系统将仅本次任务所需凭证写入私有输入通道, 不放入命令行参数、普通日志或 Artifact

#### Scenario: 服务返回轮换令牌

- **WHEN** Collector 收到新的访问令牌或刷新令牌
- **THEN** Python Bridge 将其置于 `credentialUpdates`, 由 Swift 侧验证并原子写入 Keychain, Python 不直接写回原认证文件

### Requirement: 现有 Collector 接口兼容

系统必须 (MUST) 保留现有 Collector 的 `run(ctx)` 返回 `{"artifact": ...}` 契约和 `--out` 命令行模式. App Bridge 适配必须建立在可测试的采集函数之上, 不得迫使现有 Widget 或本机脚本立即迁移.

#### Scenario: 继续使用命令行采集

- **WHEN** 用户执行现有 `python3 <module>/collector/<script>.py --out <path>` 命令
- **THEN** Collector 继续产生与当前字段兼容的 `{"artifact": ...}` JSON 文件

#### Scenario: 应用调用相同采集逻辑

- **WHEN** App Bridge 执行某个 Collector
- **THEN** Bridge 复用与 CLI 相同的纯采集和聚合逻辑, 再包装版本化响应, 避免复制业务算法

### Requirement: 超时、取消与有限退避

系统必须 (MUST) 对本地扫描、单次外部请求和模块任务分别采用默认 30 秒、10 秒和 90 秒的超时边界. 临时失败必须使用有上限的退避, 用户退出或取消时必须终止相关子进程.

#### Scenario: 外部请求超时

- **WHEN** 单次外部服务请求在 10 秒内没有完成
- **THEN** Collector 中止该请求, 返回可诊断的临时错误, 并由调度器决定有限重试

#### Scenario: 模块执行超时

- **WHEN** 某模块 Collector 总执行时间超过 90 秒
- **THEN** 运行时终止该子进程, 保留最后成功快照, 并将本次运行标记为超时

#### Scenario: 用户退出期间存在任务

- **WHEN** 用户退出应用且存在运行中的 Collector
- **THEN** 系统先发出取消, 在短暂宽限期后终止未退出进程, 且不发布不完整输出

### Requirement: 脱敏诊断

系统必须 (MUST) 为每次运行保留足以定位模块、阶段、错误类型、耗时和重试次数的诊断信息, 并在写入日志或显示界面前移除令牌、授权码、Cookie、账号邮箱和敏感 URL 参数.

#### Scenario: Collector 返回认证错误

- **WHEN** 外部服务返回认证错误且响应中包含敏感字段
- **THEN** 系统记录服务、错误类别和可执行建议, 但不记录原始凭证或完整敏感响应
