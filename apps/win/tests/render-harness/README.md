# Windows 前端「真实浏览器内核」渲染自检 harness

> 归属：`apps/win` 测试资产（与 `apps/win/tests/dom.mjs` 同一层）。
> 建立于 C029，用于补上「Windows 侧只能靠推理」的验证盲区 —— 维护者没有 Windows 机器。

## 为什么需要它

`apps/win/tests/dom.mjs` 是极简 DOM 桩，**没有 CSS 引擎**，布局 / 主题覆写 / 字体回退
全部验证不到。下面这类问题只有真渲染才能发现（C029 实测案例）：

- C027 把 hero 渐变写成内联 `background-image`，与 `.theme-nothing .hero-num` 的
  `background-size: 4px 4px` 叠加成 4px 平铺条纹 —— DOM 桩完全看不出来；
- C027 新增组件的圆角 / 半透明底在 Nothing 主题下与 mac 形态不一致；
- 满数据时的横向溢出（26 周热力图、14 日柱、订阅头部行）。

## 用法

```zsh
# 1. 在仓库根目录起静态服务 (harness 需 fetch 真实产物; file:// 不可用)
python3 -m http.server 8749 --bind 127.0.0.1

# 2. 浏览器打开 (ZCode 内置浏览器 / 任意 Chromium)
open http://127.0.0.1:8749/apps/win/tests/render-harness/dashboard-harness.html
open http://127.0.0.1:8749/apps/win/tests/render-harness/settings-harness.html
```

harness 载入的是**同字节**的 `apps/win/src/index.html` / `settings.html` 标记 +
`app.js` / `settings.js` / `styles.css`，唯一注入的是 `window.__TAURI__`
（生产环境由 WebView2 注入），因此渲染路径与 Windows 侧一致。

## 页面内可用钩子

| 钩子 | 作用 |
|---|---|
| `__ready` | app.js 加载完成 |
| `__setTheme("fluent"\|"nothing")` | 切主题（走真实 settings-updated 事件） |
| `__setPanel(panel)` | 换数据（走真实 dashboard-updated 事件），可注入 fixture 之外的合成面板 |
| `__setCategory("general"\|"agentUsage"\|"modelPricing"\|"subscription"\|"consent"\|"maintenance")` | 设置窗口切分类 |
| `__fixture` / `__settings` | 真实 parity fixture 与默认设置 |

窗口尺寸由 harness 的 `html,body` 固定为 440×760（面板）/ 1040×680（设置），
对应 `apps/win/src-tauri/tauri.conf.json`。

## 已知覆盖边界

- 不覆盖 WebView2 与 macOS Chromium 的字体度量差异：macOS 无 Segoe UI Variable /
  Cascadia Mono，Latin 走 `-apple-system` 回退，字宽略有差异（中文均走 PingFang SC /
  Microsoft YaHei UI，观感接近）。
- 不覆盖 Windows 原生窗口装饰（外框圆角/阴影由 Tauri 窗口决定，`#panel` 自身
  `border-radius: 0`），以及托盘图标、全局热键、Toast 通知等系统集成面。
- 不作为 CI 门禁：CI 无浏览器依赖，本 harness 供人工/Agent 按需驱动。
