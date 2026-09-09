# Bruce 运行时 CPU 占用优化设计

- 日期: 2026-09-09
- 状态: 已确认设计, 待实施
- 方案: A - 分层渐进优化
- 适用版本: Bruce 当前 HEAD 及后续 1.x
- 关联文档: [Rust Collector 性能设计](2026-08-21-rust-collector-performance-design.md), [Collector 性能架构设计](../../openspec/changes/rust-collector-performance/next-architecture-design.md)

## 1. 决策摘要

本方案针对两类不同的 CPU 问题分别处理:

1. 空闲或界面可见期间的持续 CPU: Widget 像素场和菜单栏刷新动画必须具有明确的可见性边界, 不在隐藏或无交互状态持续循环.
2. Collector 刷新期间的 CPU/IO 峰值: 未缓存的 JSONL source 改为版本化文件级增量缓存, SQLite source 采用只读、可验证的增量读取, 超时能够中断扫描.

方案按以下阶段实施:

```text
性能基线与 source 指标
        -> UI 动画和渲染降载
        -> JSONL 增量缓存
        -> SQLite 增量读取、取消与 Codex 正确性修复
        -> cold/warm/append/rewrite/delete 验收与 Instruments 复核
```

本方案不改变 artifact 主要字段、数据语义、凭证所有权、RefreshScheduler 的 30 分钟刷新周期或第三方 SQLite 的只读边界. 本次设计和后续验证默认使用隔离 HOME、fixture 和 fake HTTP, 不默认运行真实账号采集.

## 2. 范围、目标与非目标

### 2.1 范围

- 为 Collector 增加不携带原始会话内容的 source-level 性能指标.
- 限制 `agent-usage/widget/index.html` 的持续 Canvas 动画.
- 拆分 `MenuBarStatusItemController` 的摘要渲染和刷新 glyph 动画.
- 将现有文件级缓存能力扩展到 Kimi Work、Claude、CodeBuddy、Grok 和 Pi 等 JSONL source.
- 为 OpenCode、ZCode 等第三方 SQLite source 增加可验证的数据库级增量策略.
- 将 cancellation token 传入本地文件和 SQLite 扫描边界.
- 修复 Codex warm-cache 命中后的 `found`/status 回归.
- 增加 cold/warm/append/rewrite/delete、损坏缓存、取消和结果一致性测试.

### 2.2 目标与验收标准

目标采用行为和相对指标, 不预设跨机器的绝对 CPU 百分比:

| 场景 | 验收标准 |
|---|---|
| Widget 隐藏、不可见或 reduced-motion | 不存在持续 rAF/Timer 动画循环 |
| Widget 可见 | 保留动态效果, 动画刷新频率不超过 8 fps |
| 菜单栏刷新 | 动画 tick 不调用完整 `ImageRenderer` |
| warm unchanged Collector run | 未变化 JSONL source 不重新解析正文 |
| warm/cold 对照 | artifact 按稳定字段逐字段一致 |
| append/rewrite/delete | 只处理必要增量, 结果与完整重建一致 |
| 取消/超时 | 停止后不发布部分结果, 保留上一次成功 artifact |
| SQLite | 不执行 DDL; 未知 schema 或解析失败保留诊断状态 |

### 2.3 非目标

- 不把 RefreshScheduler 的 1800 秒周期作为首要修复点.
- 不移除所有视觉效果, 只限制其运行条件和频率.
- 不新增常驻 daemon、跨进程共享内存或自定义 RPC.
- 不修改 CC Switch、OpenCode、ZCode 或其他第三方数据库.
- 不把新的性能指标加入稳定的用户 artifact 契约.
- 不在本次工作中重写 Provider、OAuth 或凭证写回流程.
- 不为了证明性能而默认读取真实会话、Keychain 或外部账号.

## 3. 现状证据与设计边界

本节来自当前代码静态审查和隔离测试, 尚未经过 Instruments 或真实账号运行时 profile; 因此是高概率热点和待验证假设, 不是现场 CPU 根因结论.

| 类型 | 现状 | 影响 |
|---|---|---|
| 持续 CPU | Widget 在 `driftSpeed > 0` 时持续 `requestAnimationFrame`, 每帧遍历并绘制全部 marks | 可能造成 Widget 宿主持续 CPU |
| 持续 CPU | 菜单栏刷新期间每秒 12 次重新执行完整 `ImageRenderer` | 可能造成 App 主线程持续 CPU |
| 刷新峰值 | Kimi Work、Claude、CodeBuddy、Grok、Pi 的 JSONL 每轮递归并逐行解析 | 文件多或 transcript 大时产生 CPU/IO 峰值 |
| 刷新峰值 | Codex cache hit 仍需目录遍历、metadata、canonicalize 和 fingerprint | 降低了正文解析成本, 但没有消除扫描成本 |
| 正确性 | Codex cache hit 传递 `stats.files_scanned > 0` 作为 `found` | warm run 可能被错误标记为 `not_found` |
| 可中断性 | 未缓存 JSONL 扫描没有逐目录、逐文件、逐行检查 cancellation | deadline 后仍可能继续消耗 CPU |

已确认的非主要方向:

- `RefreshScheduler` 使用单次 1800 秒 Timer、coalescing 和容量限制, 不是 busy loop.
- `UsageHeroCard` 之前导致隐藏面板 CPU 的 `TimelineView` 动画已经移除, 当前装饰动画已有 `panelVisible`/reduced-motion 边界.
- quota worker pool 有界, 未发现无界 provider task 或明显 retry loop.

## 4. 目标架构

### 4.1 运行时数据流

```text
RefreshScheduler
    -> CollectorRunner
        -> Rust Collector request
            ├─ local JSONL adapters
            │    └─ versioned incremental cache
            ├─ SQLite adapters
            │    └─ read-only cursor cache
            ├─ bounded aggregation
            └─ source-level diagnostics
        -> artifact / diagnostics / credentialUpdates
    -> AppModel / PanelViewModel
```

性能优化只发生在现有 Collector、UI 渲染和诊断边界内部. `CollectorRunner` 仍负责进程生命周期、超时和结果接收; App 仍负责 Keychain 写回; Widget 仍只消费 artifact.

### 4.2 性能指标边界

新增内部 `PerformanceMetrics`，由一次 Collector run 持有，并按 source 记录:

- wall time 和阶段耗时;
- `files_visited`、`files_scanned`、`bytes_read`、`json_lines_parsed`;
- cache hit、append、rebuild、delete 和 invalidation;
- SQLite rows read;
- cancellation/deadline reason.

指标默认不进入用户 artifact. 只有显式诊断或 benchmark 模式输出经过脱敏的指标，不输出原始路径、token、authorization、cookie、会话内容或完整 JSON response.

## 5. UI 运行时设计

### 5.1 Widget 像素场状态机

Widget 使用三个状态:

| 状态 | 进入条件 | 行为 |
|---|---|---|
| `static` | 隐藏、不可见、reduced motion 或动态效果未启用 | 只绘制静态 Canvas, 不创建动画循环 |
| `interactive` | 指针 hover 或指针位置改变 | 启动短暂动态效果, 最后一次指针事件后 400ms 回到 `static` |
| `visible-animation` | 文档可见、元素与 viewport 相交且动态效果已启用 | 保留 drift 效果, 频率限制为 4-8 fps |

`visibilitychange`、`IntersectionObserver` 和组件销毁都必须停止动画调度. 若宿主不提供可靠的相交状态, `document.visibilityState` 仍是最低限度的停止条件.

绘制层面缓存 `DOMRect`、颜色、字体和 mark 几何数据. 静态 marks 可预渲染到静态层, 动态层只在 `interactive` 或 `visible-animation` 状态更新. 不在每个绘制 tick 中重复执行布局查询和样式解析.

### 5.2 菜单栏状态图标

菜单栏拆为两个更新通道:

1. 摘要通道: 只有摘要文本、token、成本或状态变化时才重新创建 `ImageRenderer`.
2. 动画通道: 只更新小型 refresh glyph, 使用 AppKit 图层或小图标帧; 动画频率限制为 4-8 fps.

`objectWillChange` 通过单个 pending render task 合并同一 run loop 内的多次变化. 没有刷新任务时停止动画 Timer. 如果 glyph 动画在系统版本上不稳定, 保留静态图标作为降级路径.

辅助功能标签由摘要通道更新, 不依赖动画 tick, 并且必须与当前显示摘要一致.

## 6. Collector 增量扫描设计

### 6.1 JSONL cache contract

在现有文件缓存实现上抽象统一的文件级增量接口, source adapter 只提供 source identity、解析器和聚合器. 每个缓存条目包含:

- 哈希化的 source/file identity;
- device、inode、size、mtime 等文件签名;
- parser version、aggregation version、window policy version;
- 当前文件的聚合 contribution;
- append 安全所需的边界和校验信息;
- 该条目的扫描统计.

缓存不保存原始 JSONL 行. contribution 只包含当前 artifact 所需的聚合字段; 需要支持滚动窗口时，保存可重新按天/窗口裁剪的聚合信息，而不是只保存不可裁剪的总数.

### 6.2 文件状态处理

- **unchanged**: 签名和版本一致时直接复用 contribution, 不读取 JSONL 正文.
- **append**: 文件只增长且边界校验通过时只解析新增字节.
- **rewrite/truncate**: 签名不满足 append 条件时完整重建该文件.
- **delete**: 从 source aggregate 移除已删除文件的 contribution.
- **invalid**: cache JSON 损坏、版本不兼容或 identity 不确定时删除对应条目并安全重建.

Claude、CodeBuddy、Codex 等存在 message ID 去重的 source 仍必须经过统一 dedupe 边界, 不能在 cache hit 后简单按文件 token 相加. 现有 bounded queue 和 worker 上限保持不变, 不因为 cache 改造而无界并行读取文件.

### 6.3 Cache migration

新实现使用新的 cache version 或 namespace. 旧格式不做复杂在线迁移; 首次运行自动重建. 任何 source 的 cache 异常只影响该 source, 不阻止其他 source 输出, 但必须保留诊断状态.

## 7. SQLite 增量读取设计

每个第三方数据库使用独立、版本化的 cursor entry, 保存哈希化数据库 identity、文件/WAL 状态、schema/parser version、可靠的 rowid 或时间游标和聚合 contribution.

- 数据库签名未变化时复用 contribution.
- 仅追加且存在可靠 cursor 时读取新增 rows.
- 数据库重写、压缩、schema 变化或签名不确定时完整重建.
- 没有可靠增量条件时使用有界 fallback, 不伪造空结果.

OpenCode 优先使用可利用时间或 rowid 的 schema-aware 查询, 仅在 schema 无法识别时保留当前兼容性 fallback. `LIKE '%tokens%'` 和最多 10,000 行候选查询必须继续有上限并输出诊断. ZCode 同样优先使用 `started_at`/rowid 增量, 不假设所有表都可写或存在固定 schema.

所有 SQLite 连接继续使用只读模式. 禁止 `CREATE INDEX`、`VACUUM`、迁移、checkpoint 写操作和任何数据修复.

## 8. 取消、超时和正确性

将 cancellation token 传入 JSONL 和 SQLite 读取器, 在以下边界检查:

- 进入目录前;
- 每个文件 metadata/open 前;
- JSONL 每行读取前后;
- SQLite 每批 rows 读取前后;
- contribution 合并和 cache 写入前.

取消或 deadline 后不发布部分聚合结果, 由 App 保留上一次成功 artifact. `cancelled`、`deadline`、`parse_error`、`schema_error` 和真实空结果使用不同状态.

Codex cache hit 必须使用“选择到有效文件”作为 `found` 判定, 不能使用只在 cache miss 时增加的 `files_scanned`. 新增测试必须验证:

- cold run 得到正常 Codex status;
- warm run 复用 contribution 后仍是正常 status;
- warm run 的 token、daily、model、cost 等稳定字段与 cold run 一致.

## 9. 测试和验证

### 9.1 自动化测试

- Rust: 为每个 JSONL source 覆盖 cold、warm、append、rewrite、delete、损坏 cache 和版本失效.
- Rust: warm unchanged 断言 `json_lines_parsed=0` 或 source-specific 等价指标为零.
- Rust: Codex warm-cache final artifact status 回归测试.
- Rust: cancellation 在目录、文件、行和 SQLite row 边界停止, 不产生部分发布结果.
- Swift: Widget 状态转换和菜单栏 render coalescing 使用纯逻辑/可注入 renderer 测试.
- Swift: 保留现有 PanelViewModel、RefreshScheduler 和 onboarding harness.

### 9.2 隔离运行验证

性能 fixture 使用隔离 HOME、固定时间窗口、合成凭证和 fake HTTP, 覆盖 14/182 天、cold/warm/append/rewrite/delete 以及多账号矩阵. 不把 fixture 通过静态检查冒充真实账号性能结论.

### 9.3 运行时 profile

使用 Instruments Time Profiler 和 Activity Monitor 分别记录:

1. Bruce 空闲、面板关闭;
2. Bruce 面板打开;
3. Collector 刷新期间;
4. Widget 宿主进程.

每个场景至少比较优化前后平均 CPU、CPU time、刷新 wall time、Collector 读取字节数、解析行数和峰值 RSS. 真实数据 profile 只有在明确授权后执行.

## 10. 分阶段交付与回滚

### Phase 0: 指标基线

只增加内部 metrics 和 fixture 输出, 不改变业务行为. 通过现有 Rust/Swift gates 后记录基线.

### Phase 1: UI 降载

先上线 Widget 状态机和菜单栏双通道渲染. 保留静态降级路径. 通过 UI harness 和 Instruments 验证隐藏状态无持续循环.

### Phase 2: JSONL cache

按 source 分组接入增量缓存, 每组独立测试和提交. 使用新 cache version/namespace; 出现异常时可删除新缓存并回退完整扫描.

### Phase 3: SQLite、取消和 Codex 修复

先修复 Codex `found` 回归, 再接入 SQLite cursor 和扫描取消. 任何不确定 schema 或取消错误都回退到已有安全路径并保留诊断.

### Phase 4: 完整验收

运行 Rust workspace tests、Clippy、Swift build 和 harness, 完成隔离 fixture 矩阵, 再进行 Instruments 对照. 未达到数据一致性或安全边界时，不宣称性能修复完成.

每个阶段保持独立提交和可回滚边界. UI 可回退静态渲染; Collector cache 可通过版本失效回退完整扫描; SQLite 增量失败可按 source 禁用而不影响其他 source.
