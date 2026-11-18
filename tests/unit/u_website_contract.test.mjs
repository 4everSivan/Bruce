// @module: official_website
// @type: unit_test
import test from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(here, "..", "..");
const siteRoot = join(repoRoot, "website");

const context = { window: {} };
vm.createContext(context);
vm.runInContext(readFileSync(join(siteRoot, "js", "data.js"), "utf8"), context);
const data = context.window.BRUCE_DATA;

test("UT-website-001: 官网 10 类本地会话与 10 家云端订阅数据源及图标完整", () => {
  assert.ok(data, "BRUCE_DATA 应挂载到 window");
  assert.equal(data.sources.agents.length, 10, "应覆盖 10 类本机会话源");
  assert.equal(data.sources.providers.length, 10, "应覆盖 10 家云端订阅源");

  for (const row of [...data.sources.agents, ...data.sources.providers]) {
    assert.ok(row.name && row.tag, `${row.name} 应同时声明名称与路径/窗口说明标签`);
    if (row.icon) {
      assert.ok(
        existsSync(join(siteRoot, "assets", "provider-icons", `${row.icon}.svg`)),
        `缺少 provider 图标: ${row.icon}.svg`
      );
    }
    if (row.image) {
      assert.ok(
        existsSync(join(siteRoot, "assets", "agent-icons", `${row.image}.png`)),
        `缺少 agent 位图: ${row.image}.png`
      );
    }
    if (row.logo) {
      assert.ok(
        existsSync(join(siteRoot, "assets", "agent-icons", `${row.logo}.svg`)),
        `缺少 agent 矢量图标: ${row.logo}.svg`
      );
    }
  }
});

test("UT-website-002: 官网 HTML 保留构建占位符、菜单栏状态项与双源目录且无自指套话", () => {
  const html = readFileSync(join(siteRoot, "index.html"), "utf8");
  for (const token of ["{{VERSION}}", "{{DMG_SIZE}}", "{{EXE_SIZE}}"]) {
    assert.ok(html.includes(token), `index.html 应保留构建占位符 ${token}`);
  }
  for (const id of [
    'id="hero-menubar"',
    'id="anatomy-menubar"',
    'id="source-agents-list"',
    'id="source-providers-list"',
    'id="deck-switcher"',
  ]) {
    assert.ok(html.includes(id), `index.html 缺少关键锚点 ${id}`);
  }
  for (const stalePhrase of ["纸色 #f1efe9", "还没有发生的日子", "桌面上标题在左"]) {
    assert.ok(!html.includes(stalePhrase), `index.html 不应残留套话或元说明: ${stalePhrase}`);
  }
});

test("UT-website-003: 面板热力图图例与分析工作台保持原生克制，无硬编码色块或装饰 Emoji", () => {
  const panelJs = readFileSync(join(siteRoot, "js", "panel.js"), "utf8");
  const analysisJs = readFileSync(join(siteRoot, "js", "analysis.js"), "utf8");
  const egressJs = readFileSync(join(siteRoot, "js", "egress.js"), "utf8");

  assert.ok(!panelJs.includes("levelColor("), "panel.js 热力图图例应交由 CSS 主题变量控制，不应行内写死绿色");
  assert.ok(panelJs.includes("orbitGaugeSvg"), "panel.js 应提供按源码常数绘制的 22pt 配额环渲染");

  for (const noisyEmoji of ["🔥", "📍", "📁", "💡", "🗑"]) {
    assert.ok(!analysisJs.includes(noisyEmoji), `analysis.js 不应包含装饰性 Emoji ${noisyEmoji}`);
    assert.ok(!egressJs.includes(noisyEmoji), `egress.js 不应包含装饰性 Emoji ${noisyEmoji}`);
  }
});

test("UT-website-004: 看板、出口保护与分析工作台使用连续过渡与持久骨架，并响应 reduced-motion", () => {
  const baseCss = readFileSync(join(siteRoot, "css", "base.css"), "utf8");
  const siteCss = readFileSync(join(siteRoot, "css", "site.css"), "utf8");
  const panelCss = readFileSync(join(siteRoot, "css", "panel.css"), "utf8");
  const panelJs = readFileSync(join(siteRoot, "js", "panel.js"), "utf8");
  const egressJs = readFileSync(join(siteRoot, "js", "egress.js"), "utf8");
  const analysisJs = readFileSync(join(siteRoot, "js", "analysis.js"), "utf8");

  assert.ok(baseCss.includes("--ease-silk") && baseCss.includes("--ease-morph"), "base.css 应声明连续过渡缓动曲线");
  assert.ok(baseCss.includes("prefers-reduced-motion: reduce"), "base.css 应提供 reduced-motion 降级");
  assert.ok(panelCss.includes("prefers-reduced-motion: reduce"), "panel.css 应关闭微观动画响应 reduced-motion");

  assert.ok(panelJs.includes("slotOrder") && panelJs.includes("anatomy__glider"), "panel.js 应使用物理槽位发牌与滑块指示器");
  assert.ok(panelCss.includes(".anatomy__panel-layer"), "panel.css 应包含看板双向层叠过渡层");
  assert.ok(siteCss.includes(".deck-switcher__glider") && siteCss.includes(".anatomy__glider"), "site.css 应包含滑块指示器样式");

  assert.ok(egressJs.includes("ensureSpecimenMounted") && egressJs.includes("ensureSettingsMounted"), "egress.js 应持久化 DOM 骨架避免整块重建");
  assert.ok(siteCss.includes(".eg-issue-wrap.is-open") && siteCss.includes(".eg-sheet-backdrop.is-open"), "site.css 应包含连续折叠与弹层过渡");

  assert.ok(analysisJs.includes("ensureWorkbenchMounted") && analysisJs.includes("syncTimelineHover"), "analysis.js 应原地更新十字准星与图表而不重绘整棵树");
  assert.ok(siteCss.includes(".wb-seg__glider") && siteCss.includes(".wb-drawer.is-open"), "site.css 应包含分段滑块与抽屉连续展开样式");
});
