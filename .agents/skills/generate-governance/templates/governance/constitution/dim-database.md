<!-- source: template/dim-database -->
### 数据库安全红线

- **[红线] 禁止无备份 DDL**: 未确认有效备份和回滚路径前, 不得执行不可逆 DDL (DROP, TRUNCATE, ALTER 删列等).
- **[红线] 禁止破坏复制与恢复资产**: 禁止随意删除 WAL, 归档, 备份集, replication slot 或恢复所需元数据.
- **[红线] 禁止用处置掩盖根因**: 禁止以扩连接数, 扩磁盘, 清 WAL 等方式掩盖根因.
- **[强制] 变更前确认角色**: 未确认 host, port, cluster, database, primary/standby 状态前, 不得建议或执行写操作.
- **[强制] 默认只读诊断**: 诊断优先使用只读视图和日志, 写操作需显式授权.

{{USER_REDLINES_DATABASE}}
<!-- /source: template/dim-database -->
