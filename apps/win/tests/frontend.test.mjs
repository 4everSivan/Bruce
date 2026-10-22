import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { analytics, boot, defaults, fixture, settle } from "./dom.mjs";

test("valid collector view model renders cards and keyboard-accessible collapse", async () => {
  const app = await boot();
  assert.equal(app.errors.length, 0);
  assert.ok(app.node("stack").children.length >= 2);
  const head = app.node("stack").querySelector(".card-head");
  await head.click();
  assert.equal(head.getAttribute("aria-expanded"), "false");
  await head.dispatch("keydown", { key: "Enter" });
  assert.equal(head.getAttribute("aria-expanded"), "true");
});

test("dashboard has no tabs and footer button invokes open_settings", async () => {
  const app = await boot();
  assert.equal(app.document.querySelector("#tabs"), null);
  assert.equal(app.document.querySelector("[data-view]"), null);
  assert.equal(app.document.querySelector("#settings-content"), null);
  assert.equal(app.document.querySelector("#credentials-content"), null);
  const start = app.calls.length;
  await app.node("foot-settings").click();
  assert.deepEqual(app.calls.slice(start).map(x => x.command), ["open_settings"]);
});

test("settings window navigation switches categories and persists configuration", async () => {
  const app = await boot({ html: "settings.html" });
  assert.equal(app.node("pane-general").classList.contains("hidden"), false);
  assert.equal(app.node("crumb").textContent, "设置 / 通用");
  await app.document.querySelector('[data-category="agentUsage"]').click();
  assert.equal(app.node("pane-agentUsage").classList.contains("hidden"), false);
  assert.equal(app.node("pane-general").classList.contains("hidden"), true);
  assert.equal(app.node("crumb").textContent, "设置 / Agent 用量");
  assert.ok(app.node("pane-agentUsage").textContent.includes("Rust Collector"));
  assert.ok(app.node("pane-agentUsage").textContent.includes("Claude Code"));
  assert.ok(app.node("pane-agentUsage").textContent.includes("未发现会话记录"));
  await app.document.querySelector('[data-category="modelPricing"]').click();
  assert.equal(app.node("pane-modelPricing").classList.contains("hidden"), false);
  await app.document.querySelector('[data-category="general"]').click();
  // 界面风格为 mac FluentSegmentedPicker 等价分段按钮, 隐藏 <select> 仍是值载体
  const themeChoices = () => [...app.node("pane-general").querySelectorAll(".fluent-seg")][0].querySelectorAll(".seg-opt");
  assert.deepEqual([...themeChoices()].map((n) => n.textContent), ["经典", "Nothing"]);
  assert.equal(themeChoices()[0].classList.contains("active"), true, "读取设置后同步选中项");
  await themeChoices()[1].click();
  assert.equal(app.node("setting-theme").value, "nothing");
  assert.equal(themeChoices()[1].getAttribute("aria-checked"), "true");
  // 设置即时生效 (C069): 分段点击即保存, 热键在 change (失焦/回车) 时保存
  assert.equal(app.state.settings.theme, "nothing");
  app.node("setting-hotkey").value = "Control+Shift+J";
  await app.node("setting-hotkey").dispatch("change");
  assert.equal(app.state.settings.hotkey, "Control+Shift+J");
  assert.equal(app.node("settings-save"), null, "无全局保存按钮");
  // mac SettingsView 恒用 SettingsDemoTokens Fluent 平面 token: 界面风格只作用于看板,
  // 设置窗口本身不得切到 Nothing (C067)
  assert.equal(app.document.body.classList.contains("theme-nothing"), false);
  assert.equal(app.document.body.classList.contains("theme-fluent"), true);
  await app.document.querySelector('[data-category="subscription"]').click();
  assert.equal(app.node("pane-subscription").classList.contains("hidden"), false);
});

test("agent usage workbench renders the Rust analytics snapshot verbatim, without estimates (C070)", async () => {
  const app = await boot({ html: "settings.html" });
  await app.document.querySelector('[data-category="agentUsage"]').click();
  await settle();
  const pane = app.node("pane-agentUsage");
  assert.equal(pane.classList.contains("hidden"), false);
  // mac 工作台默认「近 7 天」, 数值只来自 get_usage_analytics
  assert.ok(app.calls.some(call => call.command === "get_usage_analytics" && call.args.range === "7d"));
  const week = analytics["7d"];

  // 1. KPI 磁贴: 文案逐字取自快照, 不再有 ×15.2 / ×16.5 / 写死命中率
  const tiles = pane.querySelectorAll("#kpi-tiles .kpi-tile");
  assert.equal(tiles.length, 4);
  assert.deepEqual(tiles.map(tile => tile.querySelector(".kpi-value").textContent), [
    week.kpi.totalTokensText, week.kpi.costText, week.kpi.cacheHitRateText, `${week.kpi.activeAgentsCount} 个`,
  ]);
  assert.equal(tiles[1].querySelector(".wb-chip").textContent, week.kpi.costTagText);
  assert.equal(tiles[3].querySelector(".kpi-sub").textContent, week.kpi.topAgentText);
  assert.doesNotMatch(pane.textContent, /≈ ¥|折算费用|价格引擎/);

  // 2. 时序: Agent 维度图例 = 活跃 Agent; 摘要为峰值 / 均值
  const chart = pane.querySelector(".workbench-chart-card");
  assert.ok(chart.querySelector("svg"));
  assert.equal(chart.querySelectorAll(".wb-legend-item").length, week.agents.length);
  assert.equal(chart.querySelectorAll(".wb-point").length, week.agents.length * week.timeline.points.length, "≤14 点画点标记");
  assert.equal(chart.querySelector(".wb-summary-peak").textContent, week.timeline.peakSummary.replaceAll("**", ""));
  await [...chart.querySelectorAll(".chart-dim-tabs .seg-opt")].find(b => b.textContent === "Token 构成").click();
  assert.deepEqual(pane.querySelectorAll(".workbench-chart-card .wb-legend-item").map(item => item.textContent), ["输入 Prompt", "输出 Output", "缓存命中 Read"]);
  await [...pane.querySelectorAll(".workbench-chart-card .chart-dim-tabs .seg-opt")].find(b => b.textContent === "费用").click();
  assert.equal(pane.querySelector(".workbench-chart-card .wb-legend-item").textContent, "折算总费用 ($)");

  // 3. 模型分布: 合并视图逐行, 多渠道可展开; 原始渠道平铺全部来源
  const models = pane.querySelector(".canonical-card");
  const sourceCount = week.models.reduce((sum, model) => sum + Math.max(1, model.sources.length), 0);
  assert.match(models.textContent, new RegExp(`${week.models.length} 款主模型 · ${sourceCount} 个渠道`));
  assert.equal(models.querySelectorAll(".canonical-row").length, week.models.length);
  const first = models.querySelectorAll(".canonical-row")[0];
  assert.match(first.textContent, new RegExp(`${week.models[0].displayName}.*规范键: ${week.models[0].canonicalKey}`));
  assert.ok(first.textContent.includes(week.models[0].costText));
  const unpriced = week.models.find(model => model.costText === null);
  assert.ok(unpriced, "fixture 含未定价模型");
  const merged = week.models.findIndex(model => model.sources.length > 1);
  await pane.querySelectorAll(".canonical-card .canonical-row")[merged].querySelector(".wb-expand").click();
  assert.equal(pane.querySelectorAll(".canonical-card .wb-source").length, week.models[merged].sources.length);
  await [...pane.querySelectorAll(".canonical-card .seg-opt")].find(b => b.textContent === "原始渠道").click();
  assert.equal(pane.querySelectorAll(".canonical-card .wb-raw-row").length, sourceCount);

  // 4. Agent 表现: 只列活跃 Agent; 非今日范围不下发项目分布
  const agents = pane.querySelector(".agent-matrix-card");
  assert.match(agents.textContent, new RegExp(`${week.agents.length} 个活跃`));
  assert.equal(agents.querySelectorAll(".wb-agent").length, week.agents.length);
  assert.equal(agents.querySelectorAll(".wb-stack i").length, week.agents.length * 3);
  await agents.querySelector(".wb-expand").click();
  assert.doesNotMatch(pane.querySelector(".agent-matrix-card").textContent, /今日 Top 工程/);

  // 5. Token 构成: 四象限取原始口径文案, 24 格今日时段
  const composition = pane.querySelector(".composition-card");
  assert.deepEqual(composition.querySelectorAll(".composition-box-value").map(value => value.textContent), [
    week.kpi.inputTokensText, week.kpi.outputTokensText, week.kpi.cacheReadTokensText, week.kpi.cacheCreationTokensText,
  ]);
  assert.equal(composition.querySelectorAll(".wb-hour").length, 24);
  assert.equal(composition.querySelectorAll(".wb-hour.zero").length, week.todayHourlyTokens.filter(value => value === 0).length);

  // 6. 切到「今日」: 重新取数, 项目分布只在今日出现
  await [...pane.querySelectorAll(".time-range-picker .seg-opt")].find(b => b.textContent === "今日").click();
  assert.equal(app.calls.filter(call => call.command === "get_usage_analytics").at(-1).args.range, "today");
  assert.equal(pane.querySelector(".time-range-picker .seg-opt.active").textContent, "今日");
  assert.equal(pane.querySelector("#kpi-tiles .kpi-value").textContent, analytics.today.kpi.totalTokensText);
  // 展开状态跨范围保留 (mac @State expandedAgentIDs): 第 4 步展开的 Claude Code 此时显示今日项目
  const claude = pane.querySelectorAll(".agent-matrix-card .wb-agent").find(row => row.textContent.includes("Claude Code"));
  assert.equal(claude.querySelector(".wb-expand").getAttribute("aria-expanded"), "true");
  assert.match(pane.querySelector(".agent-matrix-card").textContent, /今日 Top 工程:.*bruce/);

  // 7. 会话来源与采集探针 (mac footer) 保留
  assert.match(pane.textContent, /会话来源与采集探针/);
  assert.ok(pane.textContent.includes("所有会话仅在本机分析，绝不上报远程服务器"));
});

test("legacy artifacts and missing snapshots render dashes, never zero-cost guesses (C070)", async () => {
  const legacy = Object.fromEntries(
    JSON.parse(readFileSync(new URL("../../../tests/fixtures/viewmodel-parity/agent-usage-valid.analytics.json", import.meta.url), "utf8"))
      .map(snapshot => [snapshot.range, snapshot]),
  );
  const app = await boot({ html: "settings.html", workbench: legacy });
  await app.document.querySelector('[data-category="agentUsage"]').click();
  await settle();
  const pane = app.node("pane-agentUsage");
  const tiles = pane.querySelectorAll("#kpi-tiles .kpi-tile");
  assert.equal(tiles[1].querySelector(".kpi-value").textContent, "—");
  assert.equal(tiles[1].querySelector(".wb-chip").textContent, "无明细");
  assert.equal(tiles[2].querySelector(".kpi-value").textContent, "—");
  assert.match(pane.querySelector(".canonical-card").textContent, /暂无模型消耗数据/);

  const empty = await boot({ html: "settings.html", workbench: {} });
  await empty.document.querySelector('[data-category="agentUsage"]').click();
  await settle();
  const root = empty.node("workbench-root");
  assert.ok(root.querySelector(".time-range-picker"), "无快照时仍可切换范围");
  assert.equal(root.querySelector("#kpi-tiles"), null);
  assert.equal(empty.errors.length, 0);
});

test("workbench exports go through the save dialog with mac file names and the selected range (C070)", async () => {
  const app = await boot({ html: "settings.html" });
  await app.document.querySelector('[data-category="agentUsage"]').click();
  await settle();
  let start = app.calls.length;
  await app.node("workbench-export-csv").click();
  let calls = app.calls.slice(start);
  assert.match(calls[0].args.options.defaultPath, /^bruce_agent_usage_\d{4}-\d{2}-\d{2}\.csv$/);
  assert.equal(calls[1].command, "export_workbench_csv");
  assert.equal(calls[1].args.range, "7d");
  assert.equal(calls[1].args.path, "C:\\\\Users\\\\demo\\\\导出.csv");
  start = app.calls.length;
  await app.node("workbench-export-json").click();
  calls = app.calls.slice(start);
  assert.equal(calls[0].args.options.defaultPath, "bruce_agent_usage_artifact.json");
  assert.equal(calls[1].command, "export_workbench_json");
});

test("manual refresh submits one refresh intent without another collection/read", async () => {
  const app = await boot();
  const start = app.calls.length;
  await app.node("refresh").click();
  assert.deepEqual(app.calls.slice(start).map(x => x.command), ["refresh_now"]);
});

test("model default tier and calendar month selection use distinct periods", async () => {
  const panel = structuredClone(fixture);
  const row = name => ({ name, share: 1, colorHex: "#123456", totalText: "1K", pctText: "100%" });
  panel.usage.models = { currentMonthKey: "2026-07", tiers: [0, 1, 2].map(i => ({ label: `tier ${i}`, rows: [row(`tier-model-${i}`)] })),
    months: [{ id: "2026-07", rows: [row("month-model")] }] };
  const app = await boot({ panel });
  assert.match(app.node("stack").textContent, /tier-model-0/);
  const chip = app.node("stack").querySelector('[data-month="2026-07"]');
  await chip.click();
  assert.match(app.node("stack").textContent, /month-model/);
  assert.doesNotMatch(app.node("stack").textContent, /tier-model-0/);
  await app.node("stack").querySelector(".tier-seg button").click();
  assert.match(app.node("stack").textContent, /tier-model-0/);
});

test("refresh failure retains cached cards without any top status line (C079)", async () => {
  const app = await boot();
  const panel = { ...fixture, runtime: { phase: "failed", lastSuccessAt: "2026-10-08T00:00:00Z", error: "服务暂不可用" },
    diagnostics: [{ kind: "serviceIssue", serviceId: "codex", status: "error", note: "请重新授权" }] };
  await app.emit("dashboard-updated", panel);
  // HUD 状态牌仍显失败/过期 (C009 显式运行态保留)
  assert.match(app.node("runtime-status").textContent, /失败|过期/);
  // 顶部零输出 (C079/C080): 两个承载元素都不存在
  assert.equal(app.node("dashboard-status"), null, "顶部无状态行元素 (C080)");
  assert.equal(app.node("dashboard-diagnostics"), null, "顶部无诊断行元素 (C079)");
  // 缓存卡片保留, 失败说明在订阅卡内部呈现
  assert.ok(app.node("stack").children.length >= 2);
  assert.doesNotMatch(app.node("stack").textContent, /服务暂不可用/);
});

test("single-account sections render each window row and collector note exactly once", async () => {
  // 真实 parity fixture: kimi 单窗口 + codex 双窗口, 两者都是单账号 section 且
  // status=ok。修复前该结构渲染两遍额度行与两遍 note (Rust 对单账号也下发
  // accounts[单条], 而 mac 视图在非多账号分支不读该字段)。
  const app = await boot();
  const card = app.node("stack").querySelector('[data-card="subscription"]');
  assert.equal(card.querySelectorAll(".win-row").length, 3, "1 + 2 行, 不得重复");
  assert.equal(card.querySelectorAll(".account-card").length, 0, "单账号不出账号子卡");
  assert.equal(card.querySelectorAll(".note-line").length, 0, "status=ok 不得暴露 collector note");
  assert.doesNotMatch(card.textContent, /fixture/);
});

test("collapsed subscription summary uses the most-utilized window of each provider", async () => {
  const app = await boot();
  const card = app.node("stack").querySelector('[data-card="subscription"]');
  const meters = card.querySelector(".collapsed-summary").querySelectorAll(".meter");
  // 单账号 section 的 collapsedWindow 恒为 null: 修复前退化取首个窗口 (codex 5h 7%
  // → normal), mac collapsedPeakWindow 取最紧张窗口 (codex 7d 70% → warning)。
  assert.equal(meters.length, 2);
  assert.equal(meters[0].className, "meter normal");
  assert.equal(meters[1].className, "meter warning");
  assert.equal(meters[1].children[0].style.width, "70%");
});

test("account-level subscription state, additional text and all accounts are visible after expanding", async () => {
  const panel = { ...fixture, subscription: { updatedText: null, sections: [{ id: "codex", name: "ChatGPT", status: "partial", note: "部分账号异常",
    extraText: "额外信息", windows: [], accountCountText: "2 个账号",
    collapsedWindow: { label: "每周", usedPercent: 70, percentText: "70%", resetText: "3 天后" },
    accounts: [{ id: "a", name: "工作账号", status: "error", note: "授权已过期", lastSuccessText: "上次成功 12:00",
      windows: [{ label: "每周", usedPercent: 20, percentText: "20%", resetText: "" }] },
      { id: "b", name: "个人账号", status: "ok", windows: [{ label: "每周", usedPercent: 70, percentText: "70%", resetText: "" }] }] }] } };
  const app = await boot({ panel });
  const card = () => app.node("stack").querySelector('[data-card="subscription"]');
  // 头部元数据恒显; 多账号默认折叠 (mac 同语义): 正文只有 collapsedWindow 一行
  assert.match(card().textContent, /额外信息/);
  assert.match(card().textContent, /2 个账号/);
  assert.equal(card().querySelectorAll(".account-card").length, 0);
  assert.equal(card().querySelectorAll(".win-row").length, 1);
  assert.doesNotMatch(card().textContent, /工作账号/);
  // section.note 仅 error/empty 渲染 → partial 段的 note 不出现
  assert.doesNotMatch(card().textContent, /部分账号异常/);
  const toggle = card().querySelector(".sub-name-toggle");
  assert.equal(toggle.getAttribute("aria-expanded"), "false");
  await toggle.click();
  assert.equal(card().querySelector(".sub-name-toggle").getAttribute("aria-expanded"), "true");
  assert.equal(card().querySelectorAll(".account-card").length, 2);
  assert.match(card().textContent, /工作账号/);
  assert.match(card().textContent, /个人账号/);
  // 账号级 note 仅 account.status=="error" 渲染; lastSuccessText 恒随账号展示
  assert.match(card().textContent, /授权已过期/);
  assert.match(card().textContent, /上次成功 12:00/);
  // mac 卡内不存在 status→中文的状态标签行
  assert.doesNotMatch(card().textContent, /失败|过期未续|部分/);
});

test("balance-only sections render the amount and status dual slot without a header chip", async () => {
  const panel = { ...fixture, subscription: { updatedText: null, sections: [{ id: "deepseek", name: "DeepSeek", status: "ok",
    windows: [], accounts: [], balance: { label: "账户余额", amountText: "¥ 38.21" } }] } };
  const app = await boot({ panel });
  const card = app.node("stack").querySelector('[data-card="subscription"]');
  assert.equal(card.querySelectorAll(".bal-chip").length, 0, "纯余额型抑制头部胶囊");
  assert.equal(card.querySelectorAll(".bal-slots .slot").length, 2);
  assert.match(card.textContent, /可用余额/);
  assert.match(card.textContent, /订阅状态/);
  assert.match(card.textContent, /¥ 38\.21/);
  assert.match(card.textContent, /正常/);
});

test("hero tier colors travel as CSS variables and never as inline background", async () => {
  const app = await boot();
  const card = app.node("stack").querySelector('[data-card="usage"]');
  // valid fixture usageTier=sage; 修复前写死 moss (#63885E→#82A57C)
  assert.equal(card.style["--hero-grad-start"], "#7D9B76");
  assert.equal(card.style["--hero-grad-end"], "#9DB597");
  // 反向哨兵: hero 与收起态数字都不得写内联背景 —— 内联 background-image 会压过
  // Nothing 主题的 radial 点阵覆写 (C027 实测回归, 见 C029)。
  for (const node of [card.querySelector(".hero-num"), card.querySelector(".mini-num")]) {
    assert.doesNotMatch(node.style.cssText || "", /background/);
  }
  const panel = structuredClone(fixture);
  panel.usage.usageTier = "forest";
  const other = await boot({ panel });
  const otherCard = other.node("stack").querySelector('[data-card="usage"]');
  assert.equal(otherCard.style["--hero-grad-start"], "#26452A");
  assert.equal(otherCard.style["--hero-grad-end"], "#456B42");
  // 未知档位回落 sage, 不得留空
  const fallback = structuredClone(fixture);
  fallback.usage.usageTier = "unknown-tier";
  const third = await boot({ panel: fallback });
  assert.equal(third.node("stack").querySelector('[data-card="usage"]').style["--hero-grad-start"], "#7D9B76");
});

test("styles.css consumes tier variables and keeps Nothing overrides on new components", () => {
  const css = readFileSync(new URL("../src/styles.css", import.meta.url), "utf8");
  assert.match(css, /\.hero-num\s*\{[^}]*--hero-grad-start/, "hero 必须消费档位变量");
  assert.match(css, /\.collapsed-summary \.mini-num\s*\{[^}]*--hero-grad-start/, "收起态数字必须消费档位变量");
  // Nothing hero = Doto 字体自身的点阵 + 纯色 accent (mac NothingFont.display); 不得再叠加
  // radial 遮罩 —— 遮罩会把 Doto 的点再切碎, 与 mac 渲染不一致 (C067 并排实测)。
  const nothingHero = css.match(/\.theme-nothing \.hero-num\s*\{[^}]*\}/)[0];
  assert.match(nothingHero, /font-family:\s*"Doto"/, "Nothing hero 使用 Doto");
  assert.match(nothingHero, /background:\s*none/, "Nothing hero 走纯色");
  assert.doesNotMatch(nothingHero, /radial-gradient/, "Nothing hero 不叠加点阵遮罩");
  assert.match(css, /\.theme-nothing \.collapsed-summary \.mini-num\s*\{[^}]*background:\s*none/, "Nothing 收起态数字走纯色");
  for (const rule of [".theme-nothing .account-card", ".theme-nothing .bal-slots .slot", ".theme-nothing .tag-chip"]) {
    assert.ok(css.includes(rule), `styles.css 缺少 Nothing 覆写 ${rule}`);
  }
});

test("agent rows keep distribution details collapsed until expanded, then show mac groups", async () => {
  const panel = structuredClone(fixture);
  panel.hourly.rows[0].models = [
    { name: "m1", share: 0.5, total: 62000, totalText: "62K" },
    { name: "m2", share: 0.3, total: 37200, totalText: "37.2K" },
    { name: "m3", share: 0.1, total: 12400, totalText: "12.4K" },
    { name: "其他", share: 0.1, total: 12400, totalText: "12.4K" },
    { name: "trace", share: 0.004, total: 496, totalText: "496" },
  ];
  const app = await boot({ panel });
  const firstRow = () => app.node("stack").querySelectorAll(".agent-row")[0];
  // 默认收起 (mac @State 同语义): 明细不渲染, chevron 与 aria 状态一致
  assert.equal(firstRow().querySelectorAll(".legend-row").length, 0);
  assert.equal(firstRow().querySelector(".line1").getAttribute("aria-expanded"), "false");
  assert.equal(firstRow().querySelector(".row-chev").classList.contains("open"), false, "chevron.right 未旋转");
  assert.ok(firstRow().querySelector(".row-chev svg"), "chevron 为线性图标 (mac SF Symbol 等价)");
  await firstRow().querySelector(".line1").click();
  const row = firstRow();
  assert.equal(row.querySelector(".line1").getAttribute("aria-expanded"), "true");
  assert.equal(row.querySelector(".row-chev").classList.contains("open"), true, "展开后 chevron 旋转 90°");
  assert.deepEqual([...row.querySelectorAll(".detail-title")].map((n) => n.textContent), ["模型占比", "项目分布"]);
  // 模型 5 条 (含「其他」与极小份额) + 项目 2 条, 全部渲染 (前端不得截断)
  assert.equal(row.querySelectorAll(".legend-row").length, 7);
  assert.match(row.textContent, /其他/);
  const rows = [...row.querySelectorAll(".legend-row")];
  // 图例格式: 名称 …… pct% · 总量
  assert.equal(rows[0].querySelector(".pct").textContent, "50%");
  assert.equal(rows[0].querySelector(".sep").textContent, " · 62K");
  assert.equal(rows[4].querySelector(".pct").textContent, "<1%", "极小非零份额特例");
  // 100% 堆叠条: 每组一条, 段宽按 share
  assert.equal(row.querySelectorAll(".share-bar").length, 2);
  assert.equal(row.querySelectorAll(".share-bar")[0].querySelectorAll(".share-seg").length, 5);
  // 键盘可展开
  await firstRow().querySelector(".line1").dispatch("keydown", { key: "Enter" });
  assert.equal(firstRow().querySelectorAll(".legend-row").length, 0, "可再次收起");
});

test("hourly chart, sparklines and live badge follow mac shapes", async () => {
  const app = await boot();
  const stack = () => app.node("stack");
  // 24 点走势为 SVG 折线 (mac LineMark 默认线性插值, 非点柱)
  assert.equal(stack().querySelectorAll(".spark .b").length, 0);
  assert.equal(stack().querySelectorAll(".spark svg path.spark-curve").length, 2);
  // 14 日柱顶恒显每日总量
  const totals = [...stack().querySelectorAll(".day-total")].map((n) => n.textContent);
  assert.deepEqual(totals, ["127K", "184K"]);
  // LIVE 文案 (mac LiveIndicator)
  assert.equal(stack().querySelector(".live-text").textContent, "LIVE");
  // 收起态迷你曲线 + 峰值文案
  const hourlyCard = stack().querySelector('[data-card="hourly"]');
  await hourlyCard.querySelector(".card-head").click();
  const collapsed = app.node("stack").querySelector('[data-card="hourly"]');
  assert.ok(collapsed.querySelector(".mini-spark svg path.spark-curve"), "收起态迷你折线");
  assert.equal(collapsed.querySelector(".mini-peak").textContent, "峰值 71K");
});

test("collapsed cards drag-reorder and persist cardOrder", async () => {
  const app = await boot();
  const stack = app.node("stack");
  const cards = () => [...app.node("stack").children].map((c) => c.dataset.card);
  assert.deepEqual(cards(), ["usage", "subscription", "hourly"]);
  const handle = app.node("stack").children[0].querySelector(".drag-handle");
  assert.ok(handle, "卡片头存在拖拽手柄");
  await handle.dispatch("dragstart");
  await app.node("stack").children[2].dispatch("drop");
  const saved = app.calls.filter((call) => call.command === "save_settings_command").pop();
  // 注意: harness 在 vm 上下文里跑 app.js, 数组需展开为宿主数组再比较
  assert.deepEqual([...saved.args.settings.cardOrder], ["subscription", "hourly", "usage"]);
  assert.deepEqual(cards(), ["subscription", "hourly", "usage"]);
  void stack;
});

test("Nothing theme renders segmented meters and dot-matrix day columns", async () => {
  const app = await boot({ panel: structuredClone(fixture) });
  // Fluent: 连续量条 + 百分比宽度, 无分段
  assert.equal(app.node("stack").querySelectorAll(".meter.segmented").length, 0);
  assert.equal(app.node("stack").querySelectorAll(".day-dots").length, 0);
  // 切到 Nothing (真实 settings-updated 链路) 后重建卡片
  app.state.settings.theme = "nothing";
  await app.emit("settings-updated", app.state.settings);
  const stack = app.node("stack");
  // 量条: 每条 24 段 (codex 5h 7% → round(0.07×24)=2 段填充; 7d 70% → 17 段)
  const segmented = [...stack.querySelectorAll(".meter.segmented")];
  assert.equal(segmented.length, 3, "订阅卡三行窗口各一条");
  assert.equal(segmented[0].children.length, 24);
  const filled = (meter) => meter.children.filter((cell) => cell.style.background).length;
  assert.equal(filled(segmented[0]), 8, "kimi 32% → round(0.32×24) = 8 段");
  assert.equal(filled(segmented[1]), 2, "codex 5h 7% → 2 段");
  assert.equal(filled(segmented[2]), 17, "codex 7d 70% → 17 段");
  // 日柱: 点阵 24 格, 填充数按当日占比 (fixture 两日 127K/184K)
  const grids = [...stack.querySelectorAll(".day-dots")];
  assert.equal(grids.length, 2);
  assert.equal(grids[0].children.length, 24);
  const filledDots = (grid) => grid.children.filter((cell) => cell.style.background).length;
  assert.equal(filledDots(grids[0]), 17, "127K/184K → round(0.69×24)=17");
  assert.equal(filledDots(grids[1]), 24, "峰值日铺满");
  // 末段吃掉剩余格: 合计恰为 filled
  assert.equal(filledDots(grids[0]) + 0, 17);
});

test("styles.css defines the Nothing segmented meter and dot grid", () => {
  const css = readFileSync(new URL("../src/styles.css", import.meta.url), "utf8");
  assert.match(css, /\.meter\.segmented\s*\{[^}]*gap:\s*2px/);
  assert.match(css, /\.meter\.segmented > i\s*\{\s*flex:\s*1;\s*background:\s*#222222/);
  assert.match(css, /\.day-dots\s*\{[^}]*grid-template-columns:\s*repeat\(3, 6px\)/);
  assert.match(css, /\.theme-nothing \.daily-chart \.day-total\s*\{\s*opacity:\s*0/);
});

test("Nothing theme renders hero dot-square, threshold legend, project console, and authentic typography tokens", async () => {
  const panel = structuredClone(fixture);
  panel.usage.totalTokensText = "128.4K";
  panel.hourly.rows[0].projects = [
    { name: "Bruce", share: 0.75, total: 96000, totalText: "96K" },
    { name: "OtherApp", share: 0.25, total: 32000, totalText: "32K" },
  ];
  const app = await boot({ panel });
  // 切到 Nothing 主题
  app.state.settings.theme = "nothing";
  await app.emit("settings-updated", app.state.settings);

  const stack = app.node("stack");

  // 1. Hero 总量数字拆分: 带有 .dot-square 4x4 方块
  const heroNum = stack.querySelector(".hero-num");
  assert.ok(heroNum.querySelector(".dot-square"), "Nothing 下带有 .dot-square 独立小数方块");
  assert.equal(heroNum.textContent, "1284K", "文本内容正确且小方块分隔");

  // 2. 订阅卡底部阈值图例: 3 档 (<50, 50–79, ≥80)
  const legend = stack.querySelector(".nothing-threshold-legend");
  assert.ok(legend, "Nothing 主题订阅卡包含三档阈值图例");
  const legendTexts = [...legend.querySelectorAll(".thresh-text")].map((t) => t.textContent);
  assert.deepEqual(legendTexts, ["<50", "50–79", "≥80"]);

  // 3. 项目统计控制台: 展开首个 agent 检验 Dot-Leader console
  const getFirstRow = () => stack.querySelectorAll(".agent-row")[0];
  await getFirstRow().querySelector(".line1").click();
  const prjConsole = getFirstRow().querySelector(".nothing-prj-console");
  assert.ok(prjConsole, "Nothing 主题下项目分布使用点阵终端控制台渲染");
  assert.match(prjConsole.querySelector(".prj-console-title").textContent, /PRJ\.CONSOLE/);
  assert.match(prjConsole.querySelector(".prj-console-count").textContent, /2 WORKSPACES/);
  const prjRows = prjConsole.querySelectorAll(".prj-console-row");
  assert.equal(prjRows.length, 2);
  assert.equal(prjRows[0].querySelector(".prj-tag").textContent, "[P1]");
  assert.equal(prjRows[0].querySelector(".prj-name").textContent, "Bruce");
  assert.ok(prjRows[0].querySelector(".prj-leader"), "包含点阵导引虚线");
  assert.equal(prjRows[0].querySelectorAll(".prj-tick").length, 6, "包含 6-Tick 微型液晶进度格");

  // 4. styles.css 中的字体定义与几何契约
  const css = readFileSync(new URL("../src/styles.css", import.meta.url), "utf8");
  assert.match(css, /@font-face\s*\{[^}]*font-family:\s*"Doto"/, "必须引入 Doto 字体");
  assert.match(css, /@font-face\s*\{[^}]*font-family:\s*"Space Grotesk"/, "必须引入 Space Grotesk 字体");
  assert.match(css, /@font-face\s*\{[^}]*font-family:\s*"Space Mono"/, "必须引入 Space Mono 字体");
  assert.match(css, /\.theme-nothing #panel\s*\{[^}]*border-radius:\s*10px/, "面板圆角对齐 macOS 10px");
  assert.match(css, /\.theme-nothing #panel\s*\{[^}]*background:\s*#000000/, "面板底色对齐 macOS #000000 OLED 纯黑");
  // mac: 卡内 LIVE 为 5pt 实心方点; 顶部 Header 状态灯在 Nothing 下仍是圆点 (Circle)
  assert.match(css, /\.theme-nothing \.live-dot::after\s*\{[^}]*border-radius:\s*0/, "LIVE 指示灯对齐方块几何");
  assert.doesNotMatch(css, /\.theme-nothing \.hud-dot\s*\{[^}]*border-radius:\s*0/, "Header 状态灯保持圆形");
});

test("styles.css defines the P2 shapes and keeps theme overrides for them", () => {
  const css = readFileSync(new URL("../src/styles.css", import.meta.url), "utf8");
  for (const rule of [".daily-chart .day-total", ".share-bar", ".legend-row", ".mini-spark", ".live-text", ".drag-handle", ".card.usage-card"]) {
    assert.ok(css.includes(rule), `styles.css 缺少 ${rule}`);
  }
  // 拖拽手柄仅折叠态可见; Nothing 走势色为 heroGreen; 趋势/纹样不得用内联色
  assert.match(css, /\.card\.collapsed > \.card-head \.drag-handle\s*\{\s*display:\s*inline-flex/);
  // mac Nothing 走势线为 heroGreen (#30D158 dark), 用量卡背景为 16pt 点阵层
  assert.match(css, /\.theme-nothing \.spark\s*\{\s*color:\s*#30D158/);
  assert.match(css, /\.theme-nothing \.usage-bg\s*\{[^}]*radial-gradient/);
});

test("settings expose Cline with mac-aligned display names", async () => {
  const app = await boot({ html: "settings.html" });
  await app.document.querySelector('[data-category="subscription"]').click();
  const pane = app.node("pane-subscription");
  assert.match(pane.textContent, /Cline/, "C028: Cline 必须出现在启用服务与顺序");
  assert.match(pane.textContent, /Kimi/);
  assert.match(pane.textContent, /Z\.ai/);
  assert.doesNotMatch(pane.textContent, /Kimi For Coding|ChatGPT \/ Codex/, "显示名对齐 mac");
  app.node("account-provider").value = "clineQuotaAccounts";
  app.node("account-id").value = "work";
  app.node("account-secret").value = "fixture-cline-key";
  await app.node("account-save").click();
  const call = app.calls.find(x => x.command === "save_credential_account");
  assert.equal(call.args.field, "clineQuotaAccounts");
  assert.equal(call.args.payload.api_key, "fixture-cline-key");
});

test("styles.css hides head metadata when collapsed and defines subscription components", () => {
  const css = readFileSync(new URL("../src/styles.css", import.meta.url), "utf8");
  // 折叠态 status 槽被 mini 摘要取代: 「最后更新」与 LIVE 所在的状态件必须随折叠隐藏
  assert.match(css, /\.card\.collapsed > \.card-head \.card-status\s*\{\s*display:\s*none/);
  assert.match(css, /\.card\.collapsed > \.card-head \.collapsed-summary\s*\{\s*display:\s*flex/);
  for (const rule of [".sub-extra", ".sub-name-toggle", ".account-card", ".account-head", ".last-success", ".tag-chip", ".bal-slots", ".slot-value"]) {
    assert.ok(css.includes(rule), `styles.css 缺少 ${rule}`);
  }
});

test("styles.css defines T07 workbench and Fluent 2 toggle controls", () => {
  const css = readFileSync(new URL("../src/styles.css", import.meta.url), "utf8");
  for (const rule of [
    ".kpi-tiles-grid",
    ".kpi-tile",
    ".wb-chart",
    ".wb-row",
    ".wb-stack",
    ".composition-grid",
    ".wb-hour-cells",
  ]) {
    assert.ok(css.includes(rule), `styles.css 缺少工作台组件 ${rule}`);
  }
  assert.match(css, /appearance:\s*none;/);
  assert.match(css, /transform:\s*translateX\(18px\)/);
});

test("saved card order, provider order and usage visibility affect dashboard", async () => {
  const panel = { ...fixture, subscription: { sections: ["kimi", "codex"].map(id => ({ id, name: id, windows: [], accounts: [] })) } };
  const app = await boot({ panel, settings: { ...defaults, cardOrder: ["subscription", "hourly", "usage"], providerOrder: ["codex", "kimi"] } });
  assert.equal(app.node("stack").children[0].dataset.card, "subscription");
  assert.ok(app.node("stack").textContent.indexOf("codex") < app.node("stack").textContent.indexOf("kimi"));
  app.state.settings.usageEnabled = false;
  await app.emit("settings-updated", app.state.settings);
  assert.equal(app.node("stack").querySelector('[data-card="usage"]'), null);
});

test("independent settings support consent, model prices, provider gates and maintenance", async () => {
  const app = await boot({ html: "settings.html", settings: { ...defaults, pricingOverrides: { "custom-model": { inputPricePerMillion: 3, outputPricePerMillion: 4, currency: "USD" } } } });
  const pricing = app.node("pane-modelPricing-content");
  assert.match(pricing.textContent, /fixture-model/, "内置价格表渲染");
  assert.match(pricing.textContent, /今日 TOKEN 预估折算总费用/);
  assert.match(pricing.textContent, /全部 \(\d+\)/);
  assert.match(pricing.textContent, /Fixture Vendor/, "厂商列来自 mac 目录镜像");
  assert.match(pricing.textContent, /custom-model/, "已校准模型进入表格");
  assert.match(pricing.textContent, /人工校准/, "来源列标注人工校准");
  assert.match(app.node("runtime-info").textContent, /isolated-data/);
  assert.match(app.node("runtime-info").textContent, /stale/);
  assert.match(app.node("runtime-info").textContent, /PROVIDER_RATE_LIMIT/);
  assert.doesNotMatch(app.node("runtime-info").textContent, /\[object Object\]/);
  assert.equal(app.node("setting-version").textContent, "0.11.5", "通用页版本号来自 get_runtime_info");
  // 授权页对齐 mac 语义: 确认授权 / 撤销全部授权即时生效 (无需全局保存)
  await app.node("consent-confirm").click();
  assert.equal(app.state.settings.consentVersion, 1);
  assert.equal(app.state.settings.usageEnabled, true);
  assert.equal(app.node("consent-state").textContent, "当前授权有效");
  await app.node("consent-revoke").click();
  assert.equal(app.state.settings.consentVersion, 0);
  assert.equal(app.state.settings.usageEnabled, false);
  assert.equal(app.node("consent-state").textContent, "尚未授权");
  // 单个开关即时保存, 且基于后端最新设置合并, 不吞掉既有价格校准
  await app.node("consent-confirm").click();
  app.node("setting-usage").checked = false;
  await app.node("setting-usage").dispatch("change");
  assert.equal(app.state.settings.usageEnabled, false);
  assert.equal(app.state.settings.consentVersion, 1, "其他字段沿用最新值");
  assert.equal(app.state.settings.pricingOverrides["custom-model"].inputPricePerMillion, 3, "既有校准不被即时保存吞掉");
  // 授权页单一开关: 切换即撤销 / 确认授权 (修复前该开关不接任何动作)
  app.node("setting-usage-consent").checked = false;
  await app.node("setting-usage-consent").dispatch("change");
  assert.equal(app.state.settings.consentVersion, 0);
  assert.equal(app.node("consent-state").textContent, "尚未授权");
});

test("exports use the native save dialog with cancel and fallback paths", async () => {
  // 1) 对话框可用: 选定路径原样交给导出命令
  const app = await boot({ html: "settings.html", dialogPath: "C:\\Users\\demo\\账单.csv" });
  await app.node("export-billing").click();
  const chosen = app.calls.filter((call) => call.command === "export_billing").pop();
  assert.equal(chosen.args.path, "C:\\Users\\demo\\账单.csv");
  assert.match(app.node("settings-status").textContent, /账单已导出/);
  // 2) 用户取消: 不写文件
  const cancelled = await boot({ html: "settings.html", dialogPath: null });
  await cancelled.node("export-billing").click();
  assert.equal(cancelled.calls.some((call) => call.command === "export_billing"), false, "取消时不得写入");
  assert.match(cancelled.node("settings-status").textContent, /已取消导出/);
  // 3) 对话框不可用 (未授权/异常): 回落到默认导出目录
  const fallback = await boot({ html: "settings.html", reject: { "plugin:dialog|save": "DIALOG_UNAVAILABLE" } });
  await fallback.node("export-diagnostics").click();
  const call = fallback.calls.filter((item) => item.command === "export_diagnostics").pop();
  assert.ok(call, "回落到无 path 导出");
  assert.equal(call.args.path, null);
  assert.match(fallback.node("settings-status").textContent, /诊断报告已导出/);
});

test("model pricing pane filters, calibrates and previews settings json"
, async () => {
  const app = await boot({ html: "settings.html" });
  const pane = () => app.node("pane-modelPricing-content");
  // 说明卡的文件名与展示路径必须与真实落盘一致: 标签写 settings.json,
  // 且路径反斜杠不得被 JS 无效转义吞掉 (曾渲染为 %APPDATABruceconfigsettings.json).
  assert.match(pane().textContent, /配置文件实时映射 \(settings\.json\)/);
  assert.equal(
    pane().querySelector(".pricing-path").textContent,
    "%APPDATA%\\Bruce\\config\\settings.json",
  );
  // 总览 + 搜索 + 三态筛选 + 8 列表格
  assert.match(pane().textContent, /今日 TOKEN 预估折算总费用/);
  assert.match(pane().textContent, /基于当前本机全部活跃 Agent 真实 Token 吞吐量进行折算/);
  const headers = [...pane().querySelectorAll(".pricing-table th")].map((n) => n.textContent);
  assert.deepEqual(headers, ["模型与厂商", "今日用量", "来源", "输入单价", "输出单价", "缓存命中", "今日折算", "操作"]);
  assert.deepEqual([...pane().querySelectorAll(".pricing-chip")].map((n) => n.textContent), ["全部 (1)", "已有用量 (0)", "已校准 (0)"]);
  assert.equal(pane().querySelector(".pricing-vendor").textContent, "Fixture Vendor");
  assert.match(pane().textContent, /当前全部使用官方内置基准单价/);
  // 搜索无命中 → 空态
  const search = pane().querySelector(".pricing-search");
  search.value = "不存在的模型";
  await search.dispatch("input");
  assert.match(pane().textContent, /未找到匹配的模型定价规则/);
  search.value = "";
  await search.dispatch("input");
  // 打开校准弹窗并保存 → 写入 pricingOverrides 并更新来源列
  pane().querySelector(".pricing-table .col-ops .plain-btn").click();
  const sheet = app.node("pricing-sheet");
  assert.ok(sheet, "校准弹窗已打开");
  assert.equal(sheet.querySelector(".sheet-title").textContent, "模型单价人工校准");
  assert.equal(sheet.querySelector(".row-sub").textContent, "Fixture Model (fixture-model) · Fixture Vendor");
  assert.deepEqual([...sheet.querySelectorAll(".row-title")].map((n) => n.textContent), ["输入单价 (Prompt / Input)", "输出单价 (Completion / Output)", "缓存读取命中 (Cache Hit / Read)", "备注说明 (可选)"]);
  assert.match(sheet.querySelector(".sheet-estimate p").textContent, /每消耗 1M 输入 \+ 200k 输出，折算费用约为 \$[\d.]+ USD/);
  assert.deepEqual([...sheet.querySelectorAll("button")].map((n) => n.textContent), ["取消", "保存校准"]);
  app.node("calibration-input").value = "1.25";
  app.node("calibration-note").value = "采购折扣";
  await app.node("calibration-save").click();
  const saved = app.calls.filter((call) => call.command === "save_settings_command").pop();
  assert.equal(saved.args.settings.pricingOverrides["fixture-model"].inputPricePerMillion, 1.25);
  assert.equal(saved.args.settings.pricingOverrides["fixture-model"].note, "采购折扣");
  assert.equal(app.node("pricing-sheet"), null, "保存后弹窗关闭");
  assert.match(pane().textContent, /人工校准/, "来源列更新为人工校准");
  assert.match(pane().textContent, /已校准 \(1\)/, "筛选计数更新");
});

test("maintenance pane clears snapshot and previews redacted diagnostics", async () => {
  const app = await boot({ html: "settings.html" });
  await app.node("cache-clear").click();
  assert.ok(app.calls.some((call) => call.command === "clear_snapshot_cache"), "清理按钮走 clear_snapshot_cache");
  await app.node("diagnostics-preview").click();
  const preview = app.node("diagnostics-report");
  assert.equal(app.node("diagnostics-preview").textContent, "诊断预览", "预览按钮标签不得被结果覆盖");
  assert.match(preview.textContent, /PROVIDER_RATE_LIMIT/);
  assert.match(preview.textContent, /0\.11\.5/);
  assert.match(preview.textContent, /不含凭证、账号标识、完整本机路径与业务数据/);
  assert.doesNotMatch(preview.textContent, /[\\/]/, "脱敏: 预览不得含任何路径分隔符");
  assert.equal(preview.classList.contains("hidden"), false, "预览展开");
});

test("subscription rows carry brand badge, credential form, plan tag, state and enable toggle", async () => {
  const accounts = [
    { field: "codexQuotaAccounts", accountId: "sivan", displayName: "sivan", authorizationState: "ok" },
    { field: "codexQuotaAccounts", accountId: "alt", displayName: "alt", authorizationState: "ok" },
    { field: "clineQuotaAccounts", accountId: "work", displayName: "work", authorizationState: "reauthRequired" },
  ];
  const app = await boot({ html: "settings.html", accounts });
  const rows = [...app.node("setting-providers").querySelectorAll(".provider-row")];
  assert.equal(rows.length, 10, "10 家 provider 行");
  const byName = (name) => rows.find((row) => row.querySelector(".provider-name").textContent === name);
  const kimi = byName("Kimi");
  assert.ok(kimi.querySelector(".pbadge svg"), "品牌图形徽章");
  assert.equal(kimi.querySelector(".provider-sub").textContent, "Web 令牌");
  assert.equal(kimi.querySelector(".plan-chip").textContent, "Fixture Plan", "套餐标签来自 artifact");
  assert.equal(kimi.querySelector(".auth-state").textContent, "未配置");
  const codex = byName("Codex");
  assert.equal(codex.querySelector(".provider-sub").textContent, "OAuth 设备码 · 2 个账号");
  assert.equal(codex.querySelector(".auth-state").textContent, "已配置");
  const cline = byName("Cline");
  assert.equal(cline.querySelector(".auth-state").textContent, "需要重新授权");
  assert.equal(cline.querySelector(".auth-state").classList.contains("warn"), true);
  // 启用开关落在行内, 保存时按行收集
  const toggles = [...app.node("setting-providers").querySelectorAll("input.provider-toggle")];
  assert.equal(toggles.length, 10);
  for (const toggle of toggles) toggle.checked = true;
  const codexToggle = toggles.find((node) => node.dataset.provider === "codex");
  codexToggle.checked = false;
  await codexToggle.dispatch("change");
  assert.deepEqual([...app.state.settings.enabledProviders].sort(),
    ["claude", "cline", "deepseek", "grok", "kimi", "opencodeGo", "stepfun", "volcengine", "zhipu"],
    "仅 codex 被取消启用");
});

test("credential accounts are keyed objects and save clears secret inputs", async () => {
  const app = await boot({ html: "settings.html" });
  app.node("account-provider").value = "kimiQuotaAccounts";
  await app.node("account-provider").dispatch("change");
  app.node("account-id").value = "work";
  app.node("account-name").value = "工作";
  app.node("account-secret").value = "fixture-secret";
  await app.node("account-save").click();
  const call = app.calls.find(x => x.command === "save_credential_account");
  assert.equal(call.args.field, "kimiQuotaAccounts");
  assert.equal(call.args.accountId, "work");
  assert.equal(call.args.payload.api_key, "fixture-secret");
  assert.equal(app.node("account-secret").value, "");
  assert.doesNotMatch(app.document.body.textContent, /fixture-secret/);
});

test("invalid credentials/price overrides do not persist and command failures are visible", async () => {
  // 非法单价覆盖 (来自配置文件的越界值) 必须在任何即时保存时被拦下, 控件回滚
  const app = await boot({ html: "settings.html", settings: { ...defaults, pricingOverrides: { broken: { inputPricePerMillion: -1 } } } });
  const themeChoices = [...app.node("pane-general").querySelectorAll(".fluent-seg")][0].querySelectorAll(".seg-opt");
  await themeChoices[1].click();
  assert.equal(app.calls.some(call => call.command === "save_settings_command"), false, "非法覆盖不得写回");
  assert.equal(app.node("setting-theme").value, "fluent", "保存失败回滚分段选择");
  assert.equal(app.node("settings-status").dataset.tone, "warn");
  // 命令失败 (热键冲突) 要在界面可见, 且热键框回滚为已生效值
  const failing = await boot({ html: "settings.html", reject: { save_settings_command: "热键冲突" } });
  failing.node("setting-hotkey").value = "Control+Alt+K";
  await failing.node("setting-hotkey").dispatch("change");
  assert.match(failing.node("settings-status").textContent, /热键冲突/);
  assert.equal(failing.node("setting-hotkey").value, "", "冲突热键不留在输入框里冒充已生效");
  // 失败的开关同样回滚
  failing.node("setting-notifications").checked = false;
  await failing.node("setting-notifications").dispatch("change");
  assert.equal(failing.node("setting-notifications").checked, true);
});

test("Zhipu optional API address supplies the collector's required default", async () => {
  const app = await boot({ html: "settings.html" });
  app.node("account-provider").value = "zhipuQuotaAccounts";
  app.node("account-id").value = "work";
  app.node("account-secret").value = "fixture-key";
  await app.node("account-save").click();
  const call = app.calls.find(x => x.command === "save_credential_account");
  assert.equal(call.args.payload.base_url, "https://open.bigmodel.cn/api/paas/v4");
});

test("dashboard dismisses via Escape key calling hide_dashboard", async () => {
  const app = await boot();
  const start = app.calls.length;
  await app.window.dispatch("keydown", { key: "Escape" });
  assert.deepEqual(app.calls.slice(start).map(x => x.command), ["hide_dashboard"]);
});

test("both windows keep DOM ids unique", async () => {
  // 重复 id 会让 getElementById 命中较早元素并把结果写错位置 (C031 实测:
  // 诊断预览内容被写进同名按钮的标签)。逐页遍历断言 id 唯一。
  for (const html of ["index.html", "settings.html"]) {
    const app = await boot({ html });
    const seen = new Map();
    const visited = new Set();   // 桩遍历可能重复访问同一节点, 按元素身份去重
    const walk = (element) => {
      if (visited.has(element)) return;
      visited.add(element);
      const id = element.attributes?.id;
      if (id) seen.set(id, (seen.get(id) || 0) + 1);
      for (const child of element.children) if (typeof child === "object") walk(child);
    };
    walk(app.document);
    const duplicates = [...seen.entries()].filter(([, count]) => count > 1).map(([id]) => id);
    assert.deepEqual(duplicates, [], `${html} 存在重复 id`);
  }
});

test("styles.css guarantees adaptive height and pinned footer without flex truncation", () => {
  const css = readFileSync(new URL("../src/styles.css", import.meta.url), "utf8");
  assert.match(css, /#panel\s*\{[^}]*height:\s*100%;/);
  assert.match(css, /#panel\s*\{[^}]*max-height:\s*100%;/);
  assert.match(css, /#scroll\s*\{[^}]*min-height:\s*0;/);
  assert.match(css, /#scroll\s*\{[^}]*flex:\s*1 1 0;/);
  assert.match(css, /#footer\s*\{[^}]*flex:\s*0 0 auto;/);
});

// ---------- C067: Windows 看板按 mac 源码逐项对齐的回归锁 ----------

test("styles.css never puts `inherit` inside a font shorthand (C067)", () => {
  // `font: 600 12.5px/1.3 inherit` 是无效声明, 浏览器整条丢弃: 卡片标题失去半粗,
  // 模型档位按钮回落到 UA 13.33px —— 这是 Windows 与 mac 观感差异的根因之一。
  const css = readFileSync(new URL("../src/styles.css", import.meta.url), "utf8");
  // 单独的 `font: inherit` 是合法的 CSS 全局关键字; 只有与其他取值混写才失效
  assert.doesNotMatch(css, /font:\s*[^\s;{}][^;{}]*\s+inherit\s*;/);
});

test("heatmap legend swatches carry level colors in both themes (C067)", () => {
  const css = readFileSync(new URL("../src/styles.css", import.meta.url), "utf8");
  for (let level = 1; level <= 5; level += 1) {
    assert.match(css, new RegExp(`\\.heat-legend \\.sw\\.l${level}[^{]*\\{[^}]*background`), `classic 图例 l${level} 有底色`);
    assert.match(css, new RegExp(`\\.theme-nothing \\.heat-legend \\.sw\\.l${level}[^{]*\\{[^}]*background`), `Nothing 图例 l${level} 有底色`);
  }
});

test("classic daily bars scale by day total and stack segments by in-day share (C067)", async () => {
  const app = await boot();
  const bars = [...app.node("stack").querySelectorAll(".day-bars")];
  // fixture 两日 127K / 184K: 峰值日比例 1, 另一日 127/184
  assert.equal(bars.length, 2);
  assert.equal(bars[1].style["--ratio"], "1.0000");
  assert.equal(Number(bars[0].style["--ratio"]).toFixed(2), (127 / 184).toFixed(2));
  for (const bar of bars) {
    const total = bar.children.reduce((sum, seg) => sum + parseFloat(seg.style.height), 0);
    assert.ok(Math.abs(total - 100) < 0.01, "段高为当日内份额, 合计 100%");
  }
  // 修复前 .day 由内容定高, flex:1 的柱容器恒为 0 高 —— 必须撑满图表高度
  const css = readFileSync(new URL("../src/styles.css", import.meta.url), "utf8");
  assert.match(css, /\.daily-chart \.day\s*\{[^}]*height:\s*100%/);
  assert.match(css, /\.daily-chart \.day-bars\s*\{[^}]*var\(--ratio/);
});

test("card header follows mac CollapsibleCardHeader order and embeds the collapsed mini summary (C067)", async () => {
  const app = await boot();
  const usage = app.node("stack").querySelector('[data-card="usage"]');
  const head = usage.querySelector(".card-head");
  const order = head.children.map((child) => child.className);
  assert.deepEqual(order, ["drag-handle", "card-title", "card-status", "collapsed-summary", "chev"]);
  assert.equal(head.querySelector(".card-status .live-text").textContent, "LIVE", "LIVE 位于状态件 (行尾)");
  const sub = app.node("stack").querySelector('[data-card="subscription"]');
  assert.ok(sub.querySelector(".card-head .card-status .updated"), "最后更新位于状态件 (行尾)");
  assert.ok(head.querySelector(".chev svg"), "chevron 为线性图标");
});

test("model usage chevron toggles top-3 and full list without an extra text row (C067)", async () => {
  const panel = structuredClone(fixture);
  const row = (name) => ({ name, share: 0.2, colorHex: "#123456", totalText: "1K", pctText: "20%" });
  panel.usage.models = { currentMonthKey: "2026-07",
    tiers: [{ label: "本月", rows: ["a", "b", "c", "d", "e"].map(row) }, { label: "3 月", rows: [] }, { label: "6 月", rows: [] }],
    months: [] };
  const app = await boot({ panel });
  const rows = () => app.node("stack").querySelectorAll(".model-row").length;
  assert.equal(rows(), 3);
  assert.doesNotMatch(app.node("stack").textContent, /展开全部/);
  const expand = app.node("stack").querySelector(".models-expand");
  assert.equal(expand.getAttribute("aria-expanded"), "false");
  await expand.click();
  assert.equal(rows(), 5);
  assert.equal(app.node("stack").querySelector(".models-expand").getAttribute("aria-expanded"), "true");
  // 空档位: mac「暂无模型数据」
  await app.node("stack").querySelectorAll(".tier-seg button")[1].click();
  assert.match(app.node("stack").textContent, /暂无模型数据/);
});

test("HUD header mirrors mac dashboardTopHeader in both themes (C067)", async () => {
  const app = await boot();
  assert.equal(app.node("runtime-status").textContent, "SYS.OK", "健康态与 mac 同字");
  assert.equal(app.node("hud-agents").textContent, "● 2 AGENTS ACTIVE");
  app.state.settings.theme = "nothing";
  await app.emit("settings-updated", app.state.settings);
  assert.equal(app.node("hud-agents").textContent, "2 AGENTS RUNNING");
  // 运行态异常仍显式可见 (C009), 且标记告警样式
  await app.emit("dashboard-updated", { ...fixture, runtime: { phase: "stale" } });
  assert.equal(app.node("runtime-status").textContent, "数据过期");
  assert.equal(app.node("runtime-status").classList.contains("degraded"), true);
});

test("Nothing dot columns fill top-down like mac nothingCellSlots (C067)", async () => {
  const panel = structuredClone(fixture);
  panel.usage.days = [{ date: "2026-07-28", total: 100, totalText: "100", segments: [
    { agentId: "kimi-code-cli", color: "blue", colorHex: "#0a84ff", value: 25 },
    { agentId: "codex", color: "purple", colorHex: "#bf5af2", value: 75 },
  ] }];
  const app = await boot({ panel });
  app.state.settings.theme = "nothing";
  await app.emit("settings-updated", app.state.settings);
  const cells = app.node("stack").querySelector(".day-dots").children.map((cell) => cell.style.background || null);
  // 峰值日铺满 24 格; 首段 (kimi, round(0.25×24)=6 格) 落在顶部, 末段 (codex) 吃掉余下 18 格到底
  assert.deepEqual(cells.slice(0, 6), new Array(6).fill("#8CCB98"));
  assert.deepEqual(cells.slice(6), new Array(18).fill("#4A9E5C"));
});

test("Nothing tokens keep accents green and thresholds on mac values (C067)", async () => {
  const css = readFileSync(new URL("../src/styles.css", import.meta.url), "utf8");
  const nothing = css.slice(css.indexOf("PART 3: Nothing"), css.indexOf("PART 4: T07"));
  // 当月/选中月份标签为 hero accent 绿, 不得沿用阈值红; Nothing 块不再把 --accent 覆写为红
  assert.match(nothing, /\.theme-nothing \.chip\.current \.m, \.theme-nothing \.chip\.selected \.m\s*\{\s*color:\s*#4A9E5C/);
  assert.doesNotMatch(nothing, /--accent:\s*#E44B47/);
  assert.match(nothing, /\.theme-nothing \.win-row \.wp\.critical\s*\{\s*color:\s*#D71921/);
  // 设置窗口在 mac 不随界面风格切换: Nothing 块不得包含设置窗口覆写
  for (const selector of [".navitem", ".sidenav", ".fluent-card", ".time-range-btn", ".kpi-tile"]) {
    assert.ok(!nothing.includes(selector), `Nothing 块不应覆写设置窗口 ${selector}`);
  }
  const app = await boot({ panel: structuredClone(fixture) });
  app.state.settings.theme = "nothing";
  await app.emit("settings-updated", app.state.settings);
  const legend = [...app.node("stack").querySelectorAll(".thresh-box")].map((box) => box.style.background);
  assert.deepEqual(legend, ["#4A9E5C", "#D4A843", "#D71921"]);
});

test("provider badges pass brand colors as CSS variables with a dark-brand fallback (C067)", async () => {
  const panel = { ...fixture, subscription: { updatedText: null, sections: [
    { id: "kimi", name: "Kimi", status: "ok", windows: [{ label: "每周", usedPercent: 10, percentText: "10%", resetText: "" }], accounts: [] },
    { id: "zhipu", name: "Z.ai", status: "ok", windows: [{ label: "每周", usedPercent: 10, percentText: "10%", resetText: "" }], accounts: [] },
  ] } };
  const app = await boot({ panel });
  const badges = [...app.node("stack").querySelectorAll(".sub-head .pbadge")];
  assert.equal(badges[0].style["--brand"], "#0a84ff");
  assert.equal(badges[0].style["--brand-nothing"], "#0a84ff");
  assert.equal(badges[1].style["--brand"], "#2D2D2D");
  assert.equal(badges[1].style["--brand-nothing"], "#999999", "深色品牌在 Nothing 下退回 secondary 灰");
  assert.equal(badges[0].style.background, undefined, "不得写内联 background, 以免压过主题覆写");
});

// ---------- C068: 订阅段 Provider 定向刷新按钮 (mac ProviderRefreshButton 契约) ----------

// golden fixture 是视图模型契约输出; 真实面板由 Rust runtime_core::panel_json 在其上为
// 已知 provider 的 section 附加 `provider`。测试按同一语义补齐, 未知 section 不附加。
function withProviders(panel, providers = { kimi_coding: "kimi", codex_4eversivan: "codex" }) {
  const copy = structuredClone(panel);
  for (const section of copy.subscription.sections) {
    if (providers[section.id]) section.provider = providers[section.id];
  }
  return copy;
}

test("each known provider section ends with a scoped refresh button that invokes refresh_subscription (C068)", async () => {
  // 缺 provider 键 (契约原样输出) 时 fail-closed: 不渲染按钮
  const bare = await boot();
  assert.equal(bare.node("stack").querySelectorAll(".sub-refresh").length, 0);
  const app = await boot({ panel: withProviders(fixture) });
  const buttons = () => [...app.node("stack").querySelectorAll(".sub-head .sub-refresh")];
  assert.deepEqual(buttons().map((b) => b.dataset.provider), ["kimi", "codex"]);
  assert.deepEqual(buttons().map((b) => b.getAttribute("aria-label")), ["刷新 Kimi 订阅额度", "刷新 ChatGPT 订阅额度"]);
  assert.ok(buttons()[0].querySelector("svg"), "常态为 arrow.clockwise 图标");
  const start = app.calls.length;
  await buttons()[1].click();
  assert.deepEqual(app.calls.slice(start).map((c) => [c.command, c.args?.sectionId]), [["refresh_subscription", "codex_4eversivan"]]);
});

test("scoped refresh buttons follow the mac presentation policy (C068)", async () => {
  // 目标刷新中: 进度环 + 禁用 + 「正在刷新」; 其他 provider 仍可点
  const app = await boot({ panel: { ...withProviders(fixture), runtime: { phase: "fresh", quotaRefreshAllowed: true, refreshingProviders: ["codex"] } } });
  const byProvider = (provider) => app.node("stack").querySelector(`.sub-refresh[data-provider="${provider}"]`);
  assert.equal(byProvider("codex").disabled, true);
  assert.ok(byProvider("codex").querySelector(".sub-spinner"));
  assert.equal(byProvider("codex").getAttribute("aria-label"), "正在刷新 ChatGPT 订阅额度");
  assert.equal(byProvider("kimi").disabled, false);
  // 全量刷新进行中: 全部禁用
  await app.emit("dashboard-updated", { ...withProviders(fixture), runtime: { phase: "refreshing", quotaRefreshAllowed: true, refreshingProviders: [] } });
  assert.equal(byProvider("kimi").disabled, true);
  assert.equal(byProvider("codex").disabled, true);
  // 未授权出站查询: 禁用
  await app.emit("dashboard-updated", { ...withProviders(fixture), runtime: { phase: "fresh", quotaRefreshAllowed: false, refreshingProviders: [] } });
  assert.equal(byProvider("kimi").disabled, true);
});

test("scoped refresh is fail-closed for unknown sections and does not toggle multi-account expansion (C068)", async () => {
  const panel = { ...fixture, subscription: { updatedText: null, sections: [
    { id: "mystery_x", name: "Mystery", status: "ok", windows: [{ label: "每周", usedPercent: 10, percentText: "10%", resetText: "" }], accounts: [] },
    { id: "cline", provider: "cline", name: "Cline", status: "ok", windows: [], accountCountText: "2 个账号",
      collapsedWindow: { label: "5h", usedPercent: 2, percentText: "2%", resetText: "" },
      accounts: [{ id: "a", name: "a", status: "ok", windows: [] }, { id: "b", name: "b", status: "ok", windows: [] }] },
  ] } };
  // 默认设置未启用 cline: 按钮渲染但禁用 (未启用 → 不可运行)
  const disabled = await boot({ panel });
  assert.equal(disabled.node("stack").querySelector(".sub-refresh").disabled, true);
  const app = await boot({ panel, settings: { ...defaults, enabledProviders: [...defaults.enabledProviders, "cline"] } });
  const refreshes = [...app.node("stack").querySelectorAll(".sub-refresh")];
  assert.deepEqual(refreshes.map((b) => b.dataset.provider), ["cline"], "未知 provider 不渲染按钮");
  await refreshes[0].click();
  assert.equal(app.node("stack").querySelector(".sub-name-toggle").getAttribute("aria-expanded"), "false");
  assert.ok(app.calls.some((c) => c.command === "refresh_subscription" && c.args.sectionId === "cline"));
});

test("scoped refresh refusal is silent and only restores the button (C080, mac parity)", async () => {
  const app = await boot({ panel: withProviders(fixture), reject: { refresh_subscription: "SCOPED_REFRESH_UNCONFIGURED" } });
  const button = app.node("stack").querySelector(".sub-refresh");
  await button.click();
  // 顶部零输出: 不存在任何承载拒绝文案的元素
  assert.equal(app.node("dashboard-status"), null, "顶部无状态行元素");
  assert.equal(app.node("dashboard-diagnostics"), null, "顶部无诊断行元素");
  // 可见反馈仅为按钮恢复可点 (对齐 mac RefreshScheduler.refreshSubscription 的静默 return)
  assert.equal(button.disabled, false, "拒绝后按钮恢复可点");
  assert.equal(app.node("runtime-status").textContent, "SYS.OK", "定向刷新被拒不代表整体运行失败");
});

test("settings saves are serialized and each merges the latest backend state (C069)", async () => {
  const app = await boot({ html: "settings.html" });
  // 连续操作 (不等待前一次完成) 不得相互覆盖
  const intervalChoices = [...app.node("pane-general").querySelectorAll(".fluent-seg")][1].querySelectorAll(".seg-opt");
  const pending = [intervalChoices[0].click(), app.node("card-down-usage").click()];
  app.node("setting-notifications").checked = false;
  pending.push(app.node("setting-notifications").dispatch("change"));
  await Promise.all(pending);
  assert.equal(app.state.settings.refreshIntervalSecs, 300);
  assert.deepEqual([...app.state.settings.cardOrder], ["subscription", "usage", "hourly"]);
  assert.equal(app.state.settings.notificationsEnabled, false);
  assert.equal(app.node("setting-notifications-state").textContent, "已关闭", "mac 开关旁状态字");
  const saves = app.calls.filter((call) => call.command === "save_settings_command").length;
  assert.equal(saves, 3, "每个控件各保存一次");
});

test("Claude local login state renders status text and imports from the machine (C075)", async () => {
  const followed = await boot({ html: "settings.html" });
  assert.ok(followed.calls.some((call) => call.command === "claude_local_status"), "初始化即探测本机登录态");
  assert.equal(followed.node("claude-local-state").textContent, "已启用，自动跟随本机 Claude CLI 登录态");
  assert.equal(followed.node("claude-local-state").classList.contains("ok"), true);
  const start = followed.calls.length;
  await followed.node("claude-local-import").click();
  assert.deepEqual(
    followed.calls.slice(start).map((call) => call.command).filter((name) => name === "import_claude_from_local"),
    ["import_claude_from_local"],
  );
  assert.equal(followed.node("claude-local-status").textContent, "已读取本机 Claude 登录态并保存");

  const missing = await boot({ html: "settings.html", claudeLocal: { status: "notFound", storedAccountCount: 0 } });
  assert.equal(missing.node("claude-local-state").textContent, "未检测到本机 Claude 登录态，登录 Claude CLI 后自动跟随");
  assert.equal(missing.node("claude-local-state").classList.contains("off"), true);

  const expired = await boot({ html: "settings.html", claudeLocal: { status: "expired", storedAccountCount: 1 } });
  assert.equal(expired.node("claude-local-state").textContent, "登录已过期，运行一次 Claude CLI 可自动恢复，Bruce 会重新跟随");
});

test("dashboard top carries no runtime status line in any phase (C079)", async () => {
  const app = await boot();
  const withRuntime = (runtime, diagnostics = []) => ({ ...fixture, runtime, diagnostics });

  // 部分失败 / 冷启动恢复 / 致命失败 / 中文文案: 顶部一律保持空白
  for (const runtime of [
    { phase: "partial", error: "COLLECTION_PARTIAL" },
    { phase: "stale", error: "SNAPSHOT_RESTORED", lastSuccessAt: "2026-10-22T08:00:00Z" },
    { phase: "failed", error: "SOME_NEW_CODE" },
    { phase: "failed", error: "服务暂不可用" },
  ]) {
    await app.emit("dashboard-updated", withRuntime(runtime));
    assert.equal(app.node("dashboard-status"), null, `phase=${runtime.phase} 顶部无状态行元素`);
    assert.equal(app.node("dashboard-diagnostics"), null);
  }
  // 状态牌语义未变 (C009): 健康态 SYS.OK, 异常态中文 + degraded
  await app.emit("dashboard-updated", withRuntime({ phase: "fresh" }));
  assert.equal(app.node("runtime-status").textContent, "SYS.OK");
  await app.emit("dashboard-updated", withRuntime({ phase: "partial" }));
  assert.equal(app.node("runtime-status").textContent, "部分失败");
  assert.equal(app.node("runtime-status").classList.contains("degraded"), true);
});

test("service faults stay inside the subscription card, never at the dashboard top (C079)", async () => {
  const app = await boot();
  await app.emit("dashboard-updated", {
    ...fixture,
    runtime: { phase: "partial", error: "COLLECTION_PARTIAL" },
    diagnostics: [
      { kind: "serviceIssue", serviceId: "claude", status: "error", note: "Claude 凭证被拒绝, 请重新登录 Claude CLI" },
      { kind: "serviceIssue", serviceId: "kimi", status: "error", note: "查询失败: Provider 请求触发限流 (HTTP 429)" },
      { kind: "agentIssue", agentId: "grok", status: "not_found", note: "未发现会话记录" },
    ],
  });
  // 顶部两个承载元素都不存在 (零输出)
  assert.equal(app.node("dashboard-status"), null);
  assert.equal(app.node("dashboard-diagnostics"), null);
  // 会话探针与失败说明都不上主看板 (归订阅卡内部与设置中心)
  assert.doesNotMatch(app.node("stack").textContent, /未发现会话记录/);
});

