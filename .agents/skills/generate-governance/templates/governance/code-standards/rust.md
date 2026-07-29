<!-- source: template/code-standards/rust -->
### 格式与工具链

- **[强制] 格式与 lint**: 通过 `cargo fmt` 和项目既有 `cargo clippy` 规则.
- **[默认] crate 可见性**: 公共 API 用 `pub` 显式导出; 内部实现用 `pub(crate)` 限制, 不默认全公开.
- **[默认] 特性门控**: 新增 feature flag 时说明默认行为, 组合关系和兼容性影响.

### 错误处理

- **[强制] 错误类型清晰**: 公共边界使用明确错误类型; 不在库代码中 `unwrap` / `expect`, 除非能证明不可达并说明原因.
- **[强制] 错误用 ? 传播**: 可恢复错误用 `?` 向上传播, 不用 `match` 吞掉或转 panic.
- **[默认] 类型转换用 From/TryFrom**: 类型间转换实现 `From` / `TryFrom`, 不在业务逻辑里手写转换.

### 并发与资源

- **[强制] 所有权优先**: 优先用所有权和借用表达生命周期; 避免不必要的 clone 和全局可变状态.
- **[强制] 并发安全**: 跨线程共享状态必须通过类型系统表达同步语义, 不绕过 `Send` / `Sync` 约束.
- **[默认] Arc/Mutex vs channel**: 状态共享用 `Arc<Mutex<T>>` / `Arc<RwLock<T>>`; 消息传递优先用 channel, 不在能避免时引入共享锁.
- **[默认] tokio 取消安全**: async 函数标注是否 cancel-safe; 持有跨 `.await` 的锁或借用需评估取消时的状态一致性.

### 安全与边界

- **[强制] unsafe 审计**: `unsafe` 块必须说明安全性不变量与维护责任, 集中标注便于审计, 不散落业务代码.
- **[默认] #[must_use] 标注**: 返回值不可忽略的公共函数标注 `#[must_use]`, 防止 Result / Option 静默丢弃.

### 测试与组织

- **[强制] 测试覆盖错误路径**: 单元测试覆盖 `Result::Err` 与边界分支, 不只测 happy path.
- **[默认] 属性测试**: 不变量优先用属性测试 (proptest / quickcheck), 不只枚举固定样例.
<!-- /source: template/code-standards/rust -->
