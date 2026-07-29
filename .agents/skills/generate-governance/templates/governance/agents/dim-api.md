<!-- source: template/dim-api -->
### API

- API 框架: {{API_FRAMEWORKS}}
- 路由/控制器/Handler: {{API_ROUTE_PATHS}}
- 契约文件: {{API_SCHEMA_FILES}}
- 认证/授权入口: {{API_AUTH_ENTRYPOINTS}}
- API 测试路径: {{API_TEST_PATHS}}
- API 检测置信度: {{API_CONFIDENCE}}

API 事实边界:
- 上述路径来自项目扫描或用户确认; 未列出的入口不得推断为不存在.
- 若契约文件与实现不一致, 以用户确认的项目事实为准, 并在变更中同步修正.
- 若未检测到 API 测试, 不得编造测试命令; 应标注为待补齐验证项.
- 未检测到认证/授权入口表示状态未知, 不表示 API 是内部接口、无需认证或可以降低 API 安全优先级.
<!-- /source: template/dim-api -->
