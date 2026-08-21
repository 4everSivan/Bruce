## ADDED Requirements

### Requirement: 保留现有视觉语言

系统必须 (MUST) 复用现有三个 `widget/index.html` 的布局、配色、字体层级、热力图表达和动效基线. 产品化不得以默认 SwiftUI 列表或重新设计的通用图表替换现有核心视觉.

#### Scenario: 渲染 Agent 用量

- **WHEN** Agent Artifact 被加载到应用
- **THEN** 页面沿用现有 Agent Widget 的信息层级、颜色语义、卡片结构和趋势表达

#### Scenario: 渲染仓库热力图

- **WHEN** GitHub 或 GitLab Artifact 被加载到应用
- **THEN** 页面沿用对应现有 Widget 的热力格、日期布局、强度分级和交互风格

### Requirement: WKWebView 数据适配

系统必须 (MUST) 使用受控 WKWebView 承载 Widget, 并将已验证 Artifact 映射为现有 host contract 的 `DaimonWidget.data.main`. 数据注入必须发生在受信任本机页面上下文中.

#### Scenario: 加载有效 Artifact

- **WHEN** WidgetHost 收到某模块的已验证 Artifact
- **THEN** 系统将其注入 `DaimonWidget.data.main`, 触发现有渲染入口, 并显示与独立 Widget 等价的内容

#### Scenario: 页面早于数据完成加载

- **WHEN** WKWebView 已完成页面初始化但 Artifact 尚未可用
- **THEN** 系统显示视觉一致的加载或未配置状态, 并在数据到达后只更新内容层

### Requirement: Widget 与凭证及网络隔离

系统必须 (MUST) 阻止 Widget 读取 Keychain、原始认证信息或 Collector 进程通道. Widget 不得直接调用 GitHub、GitLab 或 Agent 服务 API, 所有外部数据必须先经过 Collector 和 Artifact 校验.

#### Scenario: Widget 请求外部资源

- **WHEN** Widget 脚本尝试访问未列入本机静态资源白名单的网络地址
- **THEN** WidgetHost 拒绝请求并生成脱敏诊断, 不向请求附加任何凭证

#### Scenario: Widget 向原生层发送消息

- **WHEN** Widget 通过脚本消息处理器请求操作
- **THEN** 原生层仅接受显式白名单消息和结构化参数, 不提供通用文件、进程或 Keychain 访问能力

### Requirement: 安全的动态内容渲染

系统必须 (MUST) 对用户名、仓库名、服务错误和其他外部字符串使用文本节点或等价转义方式渲染. 不得将未经处理的动态值拼接到 `innerHTML`、脚本源码或 URL.

#### Scenario: 仓库名包含 HTML 字符

- **WHEN** Artifact 中的仓库名包含 `<`、`>`、引号或脚本样式文本
- **THEN** Widget 将其作为普通文本显示, 不执行脚本或改变页面结构

### Requirement: 加载、过期与错误状态一致性

系统必须 (MUST) 在不移除最近成功可视化的前提下展示刷新中、数据过期、认证失效和临时错误状态. 状态组件必须延续现有视觉语言并提供可执行入口.

#### Scenario: 后台刷新进行中

- **WHEN** 当前模块正在刷新且已有成功快照
- **THEN** Widget 继续显示快照, 并以非阻塞方式显示刷新中状态

#### Scenario: 认证失效

- **WHEN** 当前模块因认证失效而暂停
- **THEN** Widget 保留旧快照并显示数据已过期及重新登录入口, 不将旧数据清空

### Requirement: 可访问性与动效降级

系统必须 (MUST) 支持键盘导航、可读的辅助功能标签、足够的非颜色状态线索和 macOS 减少动态效果偏好, 同时尽量保持现有视觉风格.

#### Scenario: 用户启用减少动态效果

- **WHEN** macOS 的减少动态效果设置已启用
- **THEN** Widget 关闭或缩短非必要动画, 保留数据变化的静态视觉反馈

#### Scenario: 用户使用键盘导航

- **WHEN** 用户不使用鼠标在模块和主要操作之间移动
- **THEN** 系统提供可见焦点、合理顺序和可触发的刷新及设置操作
