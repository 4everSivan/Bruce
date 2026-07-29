<!-- source: template/code-standards/typescript -->
### 格式与工具链

- **[强制] 严格 tsconfig**: 项目应启用 `strict` 与项目既有严格选项; 不为绕过类型检查而放宽 `tsconfig`.
- **[默认] 工具链一致**: 遵循项目既有 TypeScript, ESLint, Prettier, Vitest/Jest/Playwright 配置.
- **[默认] 依赖锁文件**: 依赖变更必须更新 `package-lock.json` / `pnpm-lock.yaml` / `yarn.lock`, 不提交与 `package.json` 不一致的锁文件.

### 错误处理

- **[强制] 异步错误处理**: Promise, async 操作和外部调用必须有错误处理路径; 不留下未处理的 floating promise.
- **[强制] 流错误处理**: Node.js stream 必须监听 `error` 事件或用 pipeline 组合, 不让未捕获错误导致进程崩溃.

### 并发与资源

- **[强制] 异步取消与超时**: 长耗时异步操作应支持取消与超时 (AbortSignal / 超时包装), 不无限期阻塞.
- **[默认] 资源释放**: 事件监听器, 定时器, 订阅和文件句柄在不需时显式移除或关闭, 避免内存泄漏.

### 安全与边界

- **[强制] 运行时校验**: 来自网络, 用户输入, 环境变量和持久化存储的数据必须在信任边界做运行时校验 (zod / valibot / 项目既有方案).
- **[强制] unknown 优于 any**: 不新增无约束的 `any`; 必须用时收敛到局部并说明边界, 优先用 `unknown` + 类型收窄.
- **[默认] as 断言克制**: 不用 `as` 绕过类型检查; 必须断言时优先类型守卫 (type guard) 或运行时校验.

### 测试与组织

- **[默认] 模块导出克制**: 公共导出保持稳定; 非公共实现避免从 barrel 文件暴露.
- **[默认] 判别联合**: 多状态数据用 discriminated union (`type` 字段判别) 建模, 不用多个可选字段叠加.
- **[默认] 依赖审计**: 引入新依赖前评估体积, 维护状态与安全公告, 优先用标准或既有依赖.
<!-- /source: template/code-standards/typescript -->
