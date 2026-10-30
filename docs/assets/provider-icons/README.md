# 订阅 Provider 品牌图形源文件 (C026)

本目录存放订阅用量卡片徽章使用的品牌图形**源文件**，由
`scripts/gen-provider-glyphs.mjs` 归一化为绝对 `M/L/C/Z` 路径数据，
生成双端消费的数据文件：

- macOS: `apps/macos/Sources/BruceAppCore/ProviderBrandGlyphData.swift`
- Windows: `apps/win/src/app.js`（`PROVIDER_GLYPHS` 生成块）与 `provider-brand.js`（设置窗口挂载副本）

**请勿手改生成产物**：修改图形请替换本目录源文件后重新运行生成器；
`scripts/verify-local.sh` 会以 `--check` 模式校验生成产物与源文件一致。

## 来源与许可证

逐图标登记见 [SOURCES.json](SOURCES.json)。汇总：

| Provider | 来源 | 许可证 |
|---|---|---|
| kimi / deepseek / claude / cline / opencodeGo | Simple Icons | CC0-1.0 |
| volcengine / stepfun | theSVG（Iconify `thesvg` 集） | MIT |
| codex（ChatGPT）/ grok | SVG Logos（Iconify `logos` 集） | CC0-1.0 |
| zhipu（Z.ai） | z.ai 官方站点 `logo.svg`，取 Z 字形图层 | 品牌官方资源 |

## Agent / 模型身份图形 (C161)

Agent 与模型厂商的品牌徽章复用同一套图形数据，另加三份官方 App 位图：

- 源文件：`agent-icons/agent-zcode.png`、`agent-icons/agent-codex.png`、`agent-icons/agent-codebuddy.png`
  （分别取自本机 ZCode.app、ChatGPT.app、@tencent-ai/codebuddy-code 的内置图标）；
- 生成期由 `scripts/gen-provider-glyphs.mjs` 原样投放到
  `apps/macos/Assets/AgentIcons/` 与 `apps/win/src/assets/agent-icons/`，
  `--check` 逐字节比对，请勿直接改投放副本；
- 品牌底色/图形色与尺寸分档规则见 [design/04 规则 11](../../devel/design/04-设置中心与价格校准交互.md)；
- 无官方图形的 Agent（如 Pi）使用字标，**不**从图标库借用近似图形。

## 使用边界

- 图形仅用于**指示性识别**（徽章旁恒有服务名文字，不改色变形误导）；
- 各品牌商标权归其权利人所有，CC0/MIT 仅覆盖图形文件本身的著作权；
- zhipu 未使用图标库（库内仅有「智谱」点阵 mark，与现显示名 Z.ai 不符），
  改用官方 Z 字形以保证品牌一致性；
- jev 全部图标库无覆盖，界面保留首字母兜底（fail-closed）。
