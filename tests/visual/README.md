# Widget 视觉基线

基线统一使用 782 × 356 px、浅色主题和 `valid.json` 脱敏 fixture:

- `baselines/agent-usage-valid.jpg`

本地查看:

```bash
python3 -m http.server 8765 --bind 127.0.0.1
```

然后打开:

```text
http://127.0.0.1:8765/tests/visual/widget_harness.html?module=agent-usage
```

状态和 fixture 可通过查询参数组合:

```text
?module=agent-usage&variant=partial&state=partial&deterministic=1
?module=agent-usage&variant=valid&state=offline&deterministic=1
?module=agent-usage&variant=valid&state=authRequired&deterministic=1
```

支持的状态矩阵为 `fresh`、`refreshing`、`stale`、`offline`、`authRequired`、`partial`、`error` 和 `notConfigured`. 状态层使用 `tests/visual/host-bootstrap.js` (Daimon 宿主导入, 原 App Bundle 内嵌资源已随 WKWebView 链路拆除), 因而可在无真实账号时复核文字、图标外状态线索和减少动态效果。

## 确定性截图模式

URL 追加 `&deterministic=1` 时, harness 在注入 widget 前冻结时钟 (`Date` 固定为 2026-07-28T12:00:00Z), 模拟 `prefers-reduced-motion: reduce` 并禁用所有 CSS 动画/过渡. 这使 agent-usage 的 countUp 数字直出终值, pixel 背景 canvas 静止, 渲染结果可逐像素复现 (同机两次截图差异为 0). 不加该参数时行为不变, 人工预览不受影响.

重新生成基线 (从项目根启动上述 http.server 后执行, 依赖 Chrome headless 和 Pillow):

```bash
for m in agent-usage; do
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless --disable-gpu \
    --hide-scrollbars --window-size=782,356 --screenshot=/tmp/Bruce-$m.png \
    "http://127.0.0.1:8765/tests/visual/widget_harness.html?module=$m&deterministic=1"
done
python3 -c "
from PIL import Image
for m in ['agent-usage']:
    Image.open(f'/tmp/Bruce-{m}.png').convert('RGB').save(f'tests/visual/baselines/{m}-valid.jpg','JPEG',quality=90)
"
```

PNG 截图与 JPG 基线对比存在压缩噪声 (实测差异像素 <3%, RMSE <6); 判定「视觉一致」的参考阈值为差异像素 <5% 且 RMSE <10, 超过则按实质差异处理.

2026-07-28 基线重建原因: widget 当日演进为全宽流式布局 (经确认为预期变更), 旧基线对应约 350px 窄列布局, 已不可比对.

视觉变更必须同时检查:

- 颜色、字体层级、卡片是否保持现有风格.
- 动态数据是否来自脱敏 fixture.
- 截图是否仍为固定尺寸.
- 预期差异是否已经在对应 OpenSpec 任务或评审记录中说明.

## 2026-07-30 状态验收记录

使用 `deterministic=1` 和脱敏 fixture 在 782 × 356 px 下生成并目视检查:

| 状态 | 模块 / fixture | 结果 |
|---|---|---|
| `fresh` | Agent / valid | 主内容完整, 无冗余状态覆盖层 |
| `partial` | Agent / partial | 保留可用内容, 显示部分数据源暂不可用 |

状态均保持原有配色、字体层级和卡片布局; 状态信息使用文字和 `aria-live` 语义, 不只依赖颜色。临时截图不进入仓库。
