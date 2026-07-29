<!-- source: template/code-standards/java -->
### 格式与工具链

- **[默认] 格式与 lint**: 遵循项目既有 checkstyle / spotless / spotbugs 配置.
- **[默认] 统一日志**: 日志统一通过项目既有日志框架 (SLF4J / Log4j / 项目封装), 不用 `System.out` / `printStackTrace`.

### 错误处理

- **[强制] 异常分层**: 区分业务异常, 参数错误和系统异常; 不捕获后仅打印日志继续执行.
- **[强制] try-with-resources**: 实现 `AutoCloseable` 的资源用 try-with-resources 管理, 不依赖手动 close.
- **[强制] 不吞异常**: catch 块必须处理, 重新抛出或转换为语义化异常, 不空 catch 或仅忽略.

### 并发与资源

- **[强制] 事务边界清晰**: 数据库写操作必须明确事务边界, 避免在事务中执行不可控外部 I/O.
- **[默认] 并发集合选择**: 跨线程共享集合用 `ConcurrentHashMap` / `CopyOnWriteArrayList` 或显式锁, 不用 `Collections.synchronizedXxx` 包装后自行细粒度锁.
- **[默认] Optional 语义**: 用 `Optional` 表达可能缺失的返回值, 不用 `Optional` 作字段或参数.

### 安全与边界

- **[强制] 空值边界明确**: 公共 API 明确 nullable 语义 (注解 / Optional / 文档); 不用 `null` 表达多种业务状态.
- **[默认] 不可变集合**: 返回多元素结果优先用不可变集合 (`List.of` / `Map.copyOf` / `Collections.unmodifiableXxx`), 防止调用方意外修改.
- **[默认] equals/hashCode 契约**: 值对象或作为集合元素的类必须正确实现 `equals` 与 `hashCode`, 或用 record.

### 测试与组织

- **[强制] 依赖注入**: 服务依赖通过项目既有 DI 框架或构造函数注入, 避免隐藏全局状态.
- **[强制] 测试贴近边界**: 核心业务逻辑使用单元测试覆盖; 持久化和集成路径使用项目既有集成测试模式.
- **[默认] Stream 无副作用**: Stream 操作不修改外部状态; 终端操作前保持无副作用, 复杂中间逻辑抽方法.
<!-- /source: template/code-standards/java -->
