<!-- source: template/code-standards/go -->
### 格式与工具链

- **[强制] 格式化**: Go 代码必须通过 `gofmt` 或项目既有格式化命令.
- **[强制] 静态检查**: 提交前通过 `go vet` 与项目既有 `staticcheck` / `golangci-lint` 规则.
- **[默认] 包命名与组织**: 包名简短小写, 避免通用名 (util, common, helpers); 按职责而非类型分层组织包.

### 错误处理

- **[强制] 错误处理显式**: 不吞掉 `error`; 包装错误时保留上下文, 需要上层判断时使用 `errors.Is` / `errors.As` 兼容的方式.
- **[强制] 错误不降级**: 不把 error 静默转为 nil 或默认值继续执行; 业务关键路径必须显式处理或向上传播.

### 并发与资源

- **[强制] Context 传递**: I/O, RPC, 数据库和长耗时操作应接收并传递 `context.Context`, 不在库层自行创建不可取消的后台上下文.
- **[强制] goroutine 可退出**: goroutine 必须有明确退出路径; 跨 goroutine 协调用 `errgroup` 或显式取消信号, 避免泄漏.
- **[默认] channel 关闭责任清晰**: 由单一发送方负责关闭 channel; 多发送方用 `sync.WaitGroup` + 关闭协调, 不重复关闭.
- **[默认] defer 顺序**: 资源获取后立即 `defer` 释放; 注意 `defer` 在循环与热路径的开销.

### 安全与边界

- **[默认] 接口克制**: 只在调用方需要抽象时定义接口; 避免为了单一实现提前抽象.
- **[默认] init 副作用**: `init()` 只做确定性注册, 不执行网络, 文件写入或依赖环境的初始化.

### 测试与组织

- **[强制] 表驱动测试**: 多输入场景优先用表驱动测试 (table-driven test) 组织, 覆盖正常, 边界与错误路径.
- **[默认] 测试包边界**: 外部测试包 (`package foo_test`) 验证公开 API; 内部测试 (`package foo`) 仅用于不可从外部访问的边界.
<!-- /source: template/code-standards/go -->
