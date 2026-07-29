<!-- source: template/dim-database -->
### 数据库

- 驱动/ORM: {{DB_DRIVERS}}
- 迁移工具: {{MIGRATION_TOOL}}
- 数据库类型: {{DB_TYPE}}

数据库操作原则:
- 默认只读诊断; 写操作需显式确认目标环境与回滚路径.
- 变更前确认 host, port, database, primary/standby 状态.
- 不直接用 superuser 解决日常问题.
<!-- /source: template/dim-database -->
