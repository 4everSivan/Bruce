# Widget 设计

Widget 是 Daimon / Kimi Work Blueprint 场景下的单文件展示组件。宿主通过 `window.DaimonWidget` 提供数据、状态和主题事件，Widget 负责用量与额度的浏览器渲染；它不属于原生 App 的打包资源。

## 宿主接口与数据边界

页面注册 `onDataChange(render)`，从回调参数的 `data.main` 读取 `agents`、`services`、`generatedAt` 和 `totalCostUsd`。`onStatusChange` 回调读取宿主当前 `status`，只有 `running` 显示“刷新中”；其他状态显示“LIVE”。主题回调让已有像素场重绘。

组件内没有采集调度器或 Provider 网络请求。宿主接口缺失时不注册数据回调；`main` 或 `agents` 缺失时只把总量占位符设为“—”并返回，其他旧卡片仍然保留。原生打包清单收拢图标与字体，并复制 Collector 二进制，没有复制 Widget 或将原生快照推送到 Daimon 的步骤。宿主如何生产这份数据由外部集成负责。

依据：[`apps/widget/index.html`](../../apps/widget/index.html) 的 `render()`、`renderStatus()` 与末尾宿主回调注册；[`scripts/runtime-manifest.zsh`](../../scripts/runtime-manifest.zsh) 的 `BRUCE_BUNDLE_FILES`、`Bruce_copy_rust_collector()`。

## 用量与额度的展示口径

用量按 `status === "ok"` 的 Agent 汇总今日 Token，输入栏包含普通输入、缓存读取和缓存创建，输出栏单列输出。Agent 行按状态、今日总量排序。组合柱图按传入 `daily` 的各日下标对齐，前四个 Agent 单独分色，其余合并；它依赖宿主提供一致的日期数组，不在页面内补齐缺失日期。逐小时折线只在数组恰有 24 项且存在正数时显示。

额度同时接收 `services` 与 Agent 自带的 `quota.windows`。窗口 `usedPercent` 用于显示剩余比例，60% 和 85% 为警示分界；Codex 多账号组显示有效成员中“最大窗口已用比例”的平均值。该均值是页面汇总指标，不是服务端共同余额。余额型项目显示余额与币种，不转换为窗口百分比。

底部关于 CC Switch 与“每 30 分钟”的文字是固定文案，不能据此推断宿主的真实定价来源或调度周期。原生调度行为见[刷新生命周期](刷新生命周期设计.md)。

依据：[`apps/widget/index.html`](../../apps/widget/index.html) 的 `render()`、`renderCombo()`、`detailView()`、`renderQuota()`、`groupBlock()`。

## 动画的可见性与释放

`KimiPixelField.mount(container, options)` 创建 Canvas，并返回 `render`、`setVisible`、`setInteractive`、`destroy`。像素场同时考虑文档可见性和 `IntersectionObserver` 的相交状态。可见、非交互且允许运动时，每 125 ms 安排一次绘制；指针交互请求单帧，400 ms 无新交互后回到常规节拍。隐藏时取消帧与定时器，`destroy()` 还会解除观察器、事件监听并移除 Canvas。

`compact` 档位或系统“减少动态效果”会禁止持续漂移；总量数字的滚动动画也检查“减少动态效果”。每次数据更新先销毁旧像素场再挂载新实例，避免重复保留旧调度器。性能 Harness 使用伪 Canvas 和伪调度器表达隐藏、8 fps 上限、交互与销毁的预期，不覆盖 Daimon 宿主集成。

依据：[`apps/widget/index.html`](../../apps/widget/index.html) 的 `mount()`、`motionAllowed()`、`setVisible()`、`updateField()`；[`scripts/widget-performance-harness.mjs`](../../scripts/widget-performance-harness.mjs)。

## 相关文档

- [系统设计](Bruce设计文档.md)：原生应用、Collector 与独立 Widget 的关系。
- [Collector 设计](采集引擎与本地用量设计.md)：上游用量与 Artifact 的含义。

最后更新：2026-10-18
