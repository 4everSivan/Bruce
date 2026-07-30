# Widget 视觉基线

基线统一使用 782 × 356 px、浅色主题和 `valid.json` 脱敏 fixture:

- `baselines/agent-usage-valid.jpg`
- `baselines/github-valid.jpg`
- `baselines/gitlab-valid.jpg`

本地查看:

```bash
python3 -m http.server 8765 --bind 127.0.0.1
```

然后打开:

```text
http://127.0.0.1:8765/tests/visual/widget_harness.html?module=agent-usage
http://127.0.0.1:8765/tests/visual/widget_harness.html?module=github
http://127.0.0.1:8765/tests/visual/widget_harness.html?module=gitlab
```

状态和 fixture 可通过查询参数组合:

```text
?module=github&variant=valid&state=offline&deterministic=1
?module=gitlab&variant=valid&state=stale&deterministic=1
?module=agent-usage&variant=partial&state=partial&deterministic=1
?module=github&variant=valid&state=authRequired&deterministic=1
```

支持的状态矩阵为 `fresh`、`refreshing`、`stale`、`offline`、`authRequired`、`partial`、`error` 和 `notConfigured`. 状态层使用与 App Bundle 相同的 `host-bootstrap.js`, 因而可在无真实账号时复核文字、图标外状态线索和减少动态效果。

## 确定性截图模式

URL 追加 `&deterministic=1` 时, harness 在注入 widget 前冻结时钟 (`Date` 固定为 2026-07-28T12:00:00Z), 模拟 `prefers-reduced-motion: reduce` 并禁用所有 CSS 动画/过渡. 这使 agent-usage 的 countUp 数字直出终值, pixel 背景 canvas 静止, 渲染结果可逐像素复现 (同机两次截图差异为 0). 不加该参数时行为不变, 人工预览不受影响.

重新生成基线 (从项目根启动上述 http.server 后执行, 依赖 Chrome headless 和 Pillow):

```bash
for m in agent-usage github gitlab; do
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless --disable-gpu \
    --hide-scrollbars --window-size=782,356 --screenshot=/tmp/mddd-$m.png \
    "http://127.0.0.1:8765/tests/visual/widget_harness.html?module=$m&deterministic=1"
done
python3 -c "
from PIL import Image
for m in ['agent-usage','github','gitlab']:
    Image.open(f'/tmp/mddd-{m}.png').convert('RGB').save(f'tests/visual/baselines/{m}-valid.jpg','JPEG',quality=90)
"
```

PNG 截图与 JPG 基线对比存在压缩噪声 (实测差异像素 <3%, RMSE <6, 集中在热力格边缘); 判定「视觉一致」的参考阈值为差异像素 <5% 且 RMSE <10, 超过则按实质差异处理.

2026-07-28 基线重建原因: 三个 widget 当日演进为全宽流式布局 (经确认为预期变更), 旧基线对应约 350px 窄列布局, 已不可比对.

视觉变更必须同时检查:

- 颜色、字体层级、卡片和热力格是否保持现有风格.
- 动态数据是否来自脱敏 fixture.
- 截图是否仍为固定尺寸.
- 预期差异是否已经在对应 OpenSpec 任务或评审记录中说明.

## 2026-07-30 状态验收记录

使用 `deterministic=1` 和脱敏 fixture 在 782 × 356 px 下生成并目视检查:

| 状态 | 模块 / fixture | 结果 |
|---|---|---|
| `fresh` | GitHub / valid | 主内容完整, 无冗余状态覆盖层 |
| `offline` | GitHub / valid | 保留热力图, 右下角显示网络不可用文字 |
| `stale` | GitLab / valid | 保留热力图, 右下角显示数据可能已过期 |
| `authRequired` | GitHub / valid | 保留热力图, 显示前往设置重新登录 |
| `partial` | Agent / partial | 保留可用内容, 显示部分数据源暂不可用 |

五种状态均保持原有配色、字体层级、卡片和热力图布局; 状态信息使用文字和 `aria-live` 语义, 不只依赖颜色。临时截图不进入仓库。
