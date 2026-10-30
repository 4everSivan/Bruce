import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { analytics, boot, defaults, fixture, memoryStorage, settle } from "./dom.mjs";

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
  assert.equal(app.node("crumb").textContent, "设置 / 模型用量");
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
  const panel = { ...fixture, runtime: { phase: "failed", lastSuccessAt: "2026-10-08T00:00:00Z", error: "COLLECTION_FAILED" },
    diagnostics: [{ kind: "serviceIssue", serviceId: "codex", status: "error", note: "请重新授权" }] };
  await app.emit("dashboard-updated", panel);
  // C100: HUD 顶部状态灯呈红色 error, 悬停提示展示原因
  assert.equal(app.node("runtime-status"), null, "C100 已移除 #runtime-status 文字牌");
  assert.equal(app.node("hud-dot-wrap").classList.contains("tone-error"), true);
  assert.equal(app.node("hud-dot-wrap").getAttribute("title"), "刷新失败 · 本次采集失败", "runtime.error 机器码按中文释义展示");
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
  const clineOpt = [...app.document.querySelectorAll("#provider-add-row .cfg-picker-option")]
    .find(opt => opt.textContent === "Cline");
  await clineOpt.click();
  await app.node("provider-add-confirm").click();
  app.node("cfg-cline-apiKey").value = "fixture-cline-key";
  await app.node("cfg-cline-apiKey").dispatch("input");
  await app.node("cfg-save-cline").click();
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
  // T11 方案 B: 版本行迁入维护页软件更新卡, 后端快照未到时由 get_runtime_info 预填 (v 前缀);
  // 通用页不再有版本行。
  assert.equal(app.node("setting-version").textContent, "v0.11.5", "维护页软件更新卡版本值 (get_runtime_info 预填, v 前缀)");
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
  // C082: 只列出已添加的 Provider —— 启用集合 (kimi/codex/claude/deepseek) 与
  // 已配置集合 (codex/cline) 的并集, 不再 10 家全列。
  assert.equal(rows.length, 5, "只列已添加的 provider 行");
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
  // 行结构: 拖拽手柄 + 配置按钮, 不再有上移/下移按钮
  assert.equal(rows.every((row) => row.querySelector(".drag-handle")), true, "每行有拖拽手柄");
  assert.equal(app.node("setting-providers").querySelector(".order-btns"), null, "不再使用上移/下移");
  // 启用开关落在行内, 保存时按行收集
  const toggles = [...app.node("setting-providers").querySelectorAll("input.provider-toggle")];
  assert.equal(toggles.length, 5);
  // C090: 每个开关只写自己 Provider 的启用态 (不再整页收集复选框), 故逐个提交。
  const codexToggle = toggles.find((node) => node.dataset.provider === "codex");
  for (const toggle of toggles) {
    if (toggle === codexToggle || toggle.checked) continue;
    toggle.checked = true;
    await toggle.dispatch("change");
  }
  codexToggle.checked = false;
  await codexToggle.dispatch("change");
  assert.deepEqual([...app.state.settings.enabledProviders].sort(),
    ["claude", "cline", "deepseek", "kimi"],
    "仅 codex 被取消启用");
  // 启用态唯一事实源为 subscriptionProviders[id].enabled, enabledProviders 是其派生投影。
  assert.equal(app.state.settings.subscriptionProviders.codex.enabled, false);
  assert.equal(app.state.settings.subscriptionProviders.cline.enabled, true);
});

test("each provider row opens its own config dialog with mac texts (C082)", async () => {
  // 该用例需要覆盖火山引擎/Z.ai 行, 故启用集合包含这两家。
  const app = await boot({
    html: "settings.html",
    settings: { ...defaults, enabledProviders: ["kimi", "volcengine", "zhipu", "codex", "claude", "deepseek"] },
  });
  assert.equal(app.node("provider-dialog").classList.contains("hidden"), true, "对话框默认关闭");
  await app.node("provider-configure-kimi").click();
  assert.equal(app.node("provider-dialog").classList.contains("hidden"), false, "配置按钮打开对话框");
  assert.match(app.node("provider-dialog").textContent, /配置 Kimi/);
  assert.match(app.node("cfg-status").textContent, /未配置/);
  assert.equal(app.node("cfg-kimi-apiKey").getAttribute("placeholder"), "sk-•••••••••••••••• (输入后不回显)");
  assert.match(app.node("provider-dialog").textContent, /在 kimi\.com\/code 申请 Kimi For Coding API key/);
  assert.match(app.node("provider-dialog").textContent, /只保存到本应用的本机凭据文件/);
  await app.node("cfg-cancel-kimi").click();
  assert.equal(app.node("provider-dialog").classList.contains("hidden"), true, "取消关闭对话框");

  // 火山引擎: 双具名字段 + 脚注
  await app.node("provider-configure-volcengine").click();
  assert.ok(app.node("cfg-volcengine-accessKeyId"), "Access Key 字段");
  assert.ok(app.node("cfg-volcengine-secretAccessKey"), "Secret Key 字段");
  assert.match(app.node("provider-dialog").textContent, /此处仅做本地格式校验/);

  // Z.ai: 站点单选派生 base_url
  await app.node("cfg-cancel-volcengine").click();
  await app.node("provider-configure-zhipu").click();
  assert.ok(app.node("cfg-zhipu-site-domestic"), "国内站单选");
  assert.ok(app.node("cfg-zhipu-site-global"), "国外站单选");
  app.node("cfg-zhipu-apiKey").value = "fixture-key";
  app.node("cfg-zhipu-site-global").checked = true;
  // C096: 必填字段未填齐时「保存并验证」置灰, 故需像真实输入那样派发 input。
  await app.node("cfg-zhipu-apiKey").dispatch("input");
  await app.node("cfg-save-zhipu").click();
  const zhipu = app.calls.filter(x => x.command === "save_credential_account").pop();
  assert.equal(zhipu.args.field, "zhipuQuotaAccounts");
  assert.equal(zhipu.args.payload.base_url, "https://api.z.ai/api/paas/v4");

  // 添加服务只列尚未添加的 Provider
  const options = [...app.document.querySelectorAll("#provider-add-row .cfg-picker-option")];
  assert.equal(options.length, 4, "10 家减去已添加的 6 家");
});

test("volcengine dialog imports from CC Switch behind a read-only confirm (C083)", async () => {
  const app = await boot({
    html: "settings.html",
    settings: { ...defaults, enabledProviders: ["volcengine"] },
  });
  await app.node("provider-configure-volcengine").click();
  await app.node("cfg-volcengine-ccswitch").click();
  assert.match(
    app.node("provider-dialog").textContent,
    /只读访问 CC Switch 数据库, 不会修改 CC Switch 的任何数据/,
    "确认文案须声明只读",
  );
  await app.node("cfg-ccswitch-confirm").click();
  assert.ok(
    app.calls.some(c => c.command === "import_volcengine_from_ccswitch"),
    "确认后调用导入命令",
  );
  assert.equal(app.state.settings.subscriptionProviders.volcengine.verificationStatus, "ok");
  assert.ok(app.calls.some(c => c.command === "refresh_subscription"), "验证通过即定向刷新");
});

test("provider dialog saves with verification status and re-verifies (C082)", async () => {
  const app = await boot({ html: "settings.html" });
  await app.node("provider-configure-kimi").click();
  // C096: 字段未填齐时「保存并验证」置灰, 填齐即启用 (对齐 mac)。
  assert.equal(app.node("cfg-save-kimi").disabled, true, "未填齐时保存按钮禁用");
  app.node("cfg-kimi-apiKey").value = "fixture-kimi-key";
  await app.node("cfg-kimi-apiKey").dispatch("input");
  assert.equal(app.node("cfg-save-kimi").disabled, false, "填齐后保存按钮启用");
  await app.node("cfg-save-kimi").click();
  const save = app.calls.find(x => x.command === "save_credential_account");
  assert.equal(save.args.field, "kimiQuotaAccounts");
  assert.equal(save.args.payload.api_key, "fixture-kimi-key");
  const verify = app.calls.find(x => x.command === "verify_subscription");
  assert.equal(verify.args.provider, "kimi");
  assert.equal(app.state.settings.subscriptionProviders.kimi.verificationStatus, "ok");
  assert.equal(app.state.settings.subscriptionProviders.kimi.failureReason, null);
  assert.ok(
    app.calls.some(x => x.command === "refresh_subscription"),
    "验证通过即触发该 Provider 定向刷新",
  );
});

test("credential accounts are keyed objects and save clears secret inputs", async () => {
  const app = await boot({ html: "settings.html" });
  await app.node("provider-configure-kimi").click();
  app.node("cfg-kimi-apiKey").value = "fixture-secret";
  await app.node("cfg-kimi-apiKey").dispatch("input");
  await app.node("cfg-save-kimi").click();
  const call = app.calls.find(x => x.command === "save_credential_account");
  assert.equal(call.args.field, "kimiQuotaAccounts");
  assert.match(call.args.accountId, /^kimi-[0-9a-f]{8}$/);
  assert.equal(call.args.payload.api_key, "fixture-secret");
  assert.equal(app.node("cfg-kimi-apiKey").value, "");
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
  const app = await boot({
    html: "settings.html",
    settings: { ...defaults, enabledProviders: ["zhipu"] },
  });
  await app.node("provider-configure-zhipu").click();
  app.node("cfg-zhipu-apiKey").value = "id-part.secret-part";
  await app.node("cfg-zhipu-apiKey").dispatch("input");
  await app.node("cfg-save-zhipu").click();
  const call = app.calls.find(x => x.command === "save_credential_account");
  assert.equal(call.args.payload.base_url, "https://open.bigmodel.cn/api/paas/v4");
});

// C081: 三家 OAuth Provider 的 oauth 必须是采集端解析器认得的原生形状,
// 扁平 {access_token} 会被采集端静默忽略 (保存成功但永远查不出额度)。
// 载荷对象来自 harness 的独立 realm, 故按序列化结果比对 (deepStrictEqual 会因原型不同失败)。
const oauthJSON = value => JSON.stringify(value);

test("oauth providers save collector-native oauth shapes (C081)", async () => {
  const claude = await boot({ html: "settings.html" });
  await claude.node("provider-configure-claude").click();
  claude.node("cfg-claude-paste").value = '{"accessToken":"fixture-access","refreshToken":"fixture-refresh"}';
  await claude.node("cfg-claude-paste").dispatch("input");
  await claude.node("cfg-save-claude").click();
  const claudeCall = claude.calls.find(x => x.command === "save_credential_account");
  assert.equal(
    oauthJSON(claudeCall.args.payload.oauth),
    oauthJSON({ claudeAiOauth: { accessToken: "fixture-access", refreshToken: "fixture-refresh" } })
  );

  const grok = await boot({
    html: "settings.html",
    settings: { ...defaults, enabledProviders: ["grok"] },
  });
  await grok.node("provider-configure-grok").click();
  grok.node("cfg-grok-paste").value = '{"https://auth.x.ai::injected":{"key":"fixture-grok"}}';
  await grok.node("cfg-grok-paste").dispatch("input");
  await grok.node("cfg-save-grok").click();
  const grokCall = grok.calls.find(x => x.command === "save_credential_account");
  assert.equal(
    oauthJSON(grokCall.args.payload.oauth),
    oauthJSON({ "https://auth.x.ai::injected": { key: "fixture-grok" } })
  );

  const opencode = await boot({
    html: "settings.html",
    settings: { ...defaults, enabledProviders: ["opencodeGo"] },
  });
  await opencode.node("provider-configure-opencodeGo").click();
  opencode.node("cfg-opencodeGo-paste").value = '{"auth":"Fe26.2**fixture","workspaceId":"wrk_fixture"}';
  await opencode.node("cfg-opencodeGo-paste").dispatch("input");
  await opencode.node("cfg-save-opencodeGo").click();
  const opencodeCall = opencode.calls.find(x => x.command === "save_credential_account");
  assert.equal(
    oauthJSON(opencodeCall.args.payload.oauth),
    oauthJSON({ auth: "Fe26.2**fixture", workspaceId: "wrk_fixture" })
  );
});

test("claude paste keeps a wrapped entry and wraps a bare one (C081)", async () => {
  const wrapped = await boot({ html: "settings.html" });
  await wrapped.node("provider-configure-claude").click();
  wrapped.node("cfg-claude-paste").value = '{"claudeAiOauth":{"accessToken":"fixture-wrapped","scopes":["a"]}}';
  await wrapped.node("cfg-claude-paste").dispatch("input");
  await wrapped.node("cfg-save-claude").click();
  const wrappedCall = wrapped.calls.find(x => x.command === "save_credential_account");
  assert.equal(
    oauthJSON(wrappedCall.args.payload.oauth),
    oauthJSON({ claudeAiOauth: { accessToken: "fixture-wrapped", scopes: ["a"] } })
  );

  const bare = await boot({ html: "settings.html" });
  await bare.node("provider-configure-claude").click();
  bare.node("cfg-claude-paste").value = '{"accessToken":"fixture-bare"}';
  await bare.node("cfg-claude-paste").dispatch("input");
  await bare.node("cfg-save-claude").click();
  const bareCall = bare.calls.find(x => x.command === "save_credential_account");
  assert.equal(
    oauthJSON(bareCall.args.payload.oauth),
    oauthJSON({ claudeAiOauth: { accessToken: "fixture-bare" } })
  );
});

test("OpenCode GO requires auth and workspaceId and surfaces the reason (C081)", async () => {
  const app = await boot({
    html: "settings.html",
    settings: { ...defaults, enabledProviders: ["opencodeGo"] },
  });
  await app.node("provider-configure-opencodeGo").click();
  app.node("cfg-opencodeGo-paste").value = '{"auth":"Fe26.2**fixture"}';
  await app.node("cfg-opencodeGo-paste").dispatch("input");
  await app.node("cfg-save-opencodeGo").click();
  assert.equal(
    app.calls.some(call => call.command === "save_credential_account"),
    false,
    "缺 workspaceId 不得提交"
  );
  assert.match(app.node("cfg-status").textContent, /workspaceId/);
});

test("subscription pane removes legacy bypass credential cards and keeps only two cards (C095)", async () => {
  const app = await boot({ html: "settings.html" });
  const pane = app.node("pane-subscription-content");
  const cardTitles = [...pane.querySelectorAll(".card-caption")].map(n => n.textContent);
  assert.deepEqual(
    cardTitles,
    ["订阅服务", "添加服务"],
    "订阅额度页只保留「订阅服务」与「添加服务」两张卡 (对齐 mac SettingsView.subscriptionPane)"
  );
  assert.equal(pane.querySelectorAll(".fluent-card").length, 2, "订阅额度页仅渲染 2 张卡片容器");
  for (const legacyText of [
    "添加或更新账号凭证",
    "导入账号",
    "高级：完整凭证字段维护",
    "检查已保存账号连接",
  ]) {
    assert.doesNotMatch(
      pane.textContent,
      new RegExp(legacyText),
      `遗留旁路卡片/按钮「${legacyText}」必须已被移除`
    );
  }
  for (const legacyId of [
    "account-provider",
    "account-id",
    "account-save",
    "credentials-validate",
    "connection-status",
    "credential-import",
    "credential-fields",
    "credentials-save",
  ]) {
    assert.equal(app.node(legacyId), null, `遗留 DOM #${legacyId} 不得存在`);
  }
  // Codex 通过专属配置对话框走设备码登录与账号发现 (C084)
  await app.node("provider-configure-codex").click();
  assert.ok(app.node("cfg-codex-login"), "Codex 对话框提供设备码登录入口");
});

test("dashboard dismisses via Escape key calling hide_dashboard", async () => {
  const app = await boot();
  const start = app.calls.length;
  await app.window.dispatch("keydown", { key: "Escape" });
  // C145: 动效开启时先播卷轴退场动画, 由 animationend 收尾后才通知后端隐藏.
  await app.node("panel").dispatch("animationend");
  await settle();
  assert.deepEqual(app.calls.slice(start).map(x => x.command), ["hide_dashboard"]);
});

test("motion gate: never suppresses curtain motion, always keeps it", async () => {
  const off = await boot({ settings: { ...defaults, motionPreference: "never" } });
  assert.equal(off.document.documentElement.dataset.motion, "off");
  assert.ok(
    !off.node("panel").classList.contains("curtain-enter"),
    "关闭动效时不得挂入场动画类",
  );
  const start = off.calls.length;
  await off.window.dispatch("keydown", { key: "Escape" });
  await settle();
  assert.deepEqual(
    off.calls.slice(start).map(x => x.command),
    ["hide_dashboard"],
    "关闭动效时 Esc 直接隐藏, 不等动画",
  );

  const forced = await boot({ settings: { ...defaults, motionPreference: "always" } });
  assert.equal(forced.document.documentElement.dataset.motion, "on");
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

test("dashboard scroll area hides its scrollbar like mac but stays scrollable (C101)", () => {
  // mac 看板 ScrollView 恒隐藏滚动指示条 (.scrollIndicators(.hidden) + C044 看门狗),
  // Windows 同样不画滚动条; overflow-y 必须仍为 auto, 否则滚轮也滚不动。
  const css = readFileSync(new URL("../src/styles.css", import.meta.url), "utf8");
  assert.match(css, /#scroll\s*\{[^}]*overflow-y:\s*auto;/);
  assert.match(css, /#scroll\s*\{[^}]*scrollbar-width:\s*none;/);
  assert.match(css, /#scroll::-webkit-scrollbar\s*\{[^}]*display:\s*none;/);
  assert.doesNotMatch(css, /#scroll\s*\{[^}]*scrollbar-color:/);
  assert.doesNotMatch(css, /#scroll::-webkit-scrollbar-thumb/);
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

test("HUD header mirrors mac dashboardTopHeader in both themes (C067 / C100)", async () => {
  const app = await boot();
  assert.equal(app.node("runtime-status"), null, "C100 移除 SYS.OK 文字牌");
  assert.equal(app.document.querySelector(".hud-brand").textContent, "Bruce", "品牌字统一为 Bruce");
  assert.equal(app.node("hud-dot-wrap").classList.contains("tone-ok"), true);
  assert.equal(app.node("hud-dot-wrap").getAttribute("title"), "运行正常");
  assert.equal(app.node("hud-agents").textContent, "● 2 AGENTS ACTIVE");
  app.state.settings.theme = "nothing";
  await app.emit("settings-updated", app.state.settings);
  assert.equal(app.document.querySelector(".hud-brand").textContent, "Bruce", "Nothing 主题品牌字同样统一为 Bruce");
  assert.equal(app.node("hud-agents").textContent, "2 AGENTS RUNNING");
  // 运行态异常由顶部四色状态灯 (C100) 与 hover 原因承载
  await app.emit("dashboard-updated", { ...fixture, runtime: { phase: "stale" } });
  assert.equal(app.node("hud-dot-wrap").classList.contains("tone-warn"), true);
  assert.equal(app.node("hud-dot-wrap").getAttribute("title"), "数据过期");
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
  assert.equal(app.node("hud-dot-wrap").classList.contains("tone-ok"), true, "定向刷新被拒不代表整体运行失败");
  assert.equal(app.node("hud-dot-wrap").getAttribute("title"), "运行正常");
});

test("settings saves are serialized and each merges the latest backend state (C069)", async () => {
  const app = await boot({ html: "settings.html" });
  // 连续操作 (不等待前一次完成) 不得相互覆盖
  // C153: 按 select id 定位分段控件, 不依赖通用页行序下标.
  const intervalGroup = app.node("setting-interval").parentElement.querySelector(".fluent-seg");
  const intervalChoices = intervalGroup.querySelectorAll(".seg-opt");
  const pending = [intervalChoices[0].click(), app.node("card-down-usage").click()];
  app.node("setting-notifications").checked = false;
  pending.push(app.node("setting-notifications").dispatch("change"));
  await Promise.all(pending);
  assert.equal(app.state.settings.refreshIntervalSecs, 180);
  assert.deepEqual([...app.state.settings.cardOrder], ["subscription", "usage", "hourly"]);
  assert.equal(app.state.settings.notificationsEnabled, false);
  // C146: 开关旁不再有状态字节点, 开合位置即唯一状态表达.
  assert.equal(app.node("setting-notifications-state"), null, "不得再渲染已开启/已关闭状态字");
  const saves = app.calls.filter((call) => call.command === "save_settings_command").length;
  assert.equal(saves, 3, "每个控件各保存一次");
});

test("refresh interval offers 3 / 6 minute presets plus a custom minute field (C160)", async () => {
  const app = await boot({ html: "settings.html" });
  const select = app.node("setting-interval");
  const labels = [...select.querySelectorAll("option")].map((option) => option.textContent);
  assert.deepEqual(labels, ["3 分钟", "6 分钟", "自定义"], "预设与自定义分段必须与 mac 一致");
  // 默认 30 分钟不在预设内 -> 回显为自定义, 但只读展示当前值, 不展开输入框
  assert.equal(select.value, "custom");
  const field = app.node("setting-interval-custom");
  const customWrap = app.node("setting-interval-custom-wrap");
  const current = app.node("setting-interval-current");
  const editBtn = app.node("setting-interval-edit");
  const editGroup = app.node("setting-interval-edit-group");
  assert.equal(customWrap.style.display, "flex");
  assert.equal(current.textContent, "30 分钟");
  assert.equal(current.style.display, "");
  assert.equal(editBtn.style.display, "");
  assert.equal(editGroup.style.display, "none", "打开设置时不得出现输入框");
  assert.equal(field.value, "30");
  // 选 6 分钟 -> 保存 360 秒并收起自定义组
  const group = select.parentElement.querySelector(".fluent-seg");
  await group.querySelectorAll(".seg-opt")[1].click();
  assert.equal(app.state.settings.refreshIntervalSecs, 360);
  assert.equal(customWrap.style.display, "none");
  // 选自定义 -> 用户主动点击后才展开输入并回填当前生效值
  await group.querySelectorAll(".seg-opt")[2].click();
  assert.equal(customWrap.style.display, "flex");
  assert.equal(editGroup.style.display, "flex");
  assert.equal(current.style.display, "none");
  assert.equal(editBtn.style.display, "none");
  assert.equal(field.value, "6");
  // 输入 12 分钟 -> 保存 720 秒并退出编辑态, 回到只读展示
  field.value = "12";
  await field.dispatch("change");
  assert.equal(app.state.settings.refreshIntervalSecs, 720);
  assert.equal(editGroup.style.display, "none");
  assert.equal(current.textContent, "12 分钟");
  // 「编辑」可再次进入编辑态
  await editBtn.click();
  assert.equal(editGroup.style.display, "flex");
  assert.equal(field.value, "12");
  // 越界输入 -> 还原当前生效值, 不写回, 保持编辑态
  const savesBefore = app.calls.filter((call) => call.command === "save_settings_command").length;
  field.value = "0";
  await field.dispatch("change");
  assert.equal(field.value, "12");
  assert.equal(app.state.settings.refreshIntervalSecs, 720);
  assert.equal(editGroup.style.display, "flex");
  assert.equal(
    app.calls.filter((call) => call.command === "save_settings_command").length,
    savesBefore,
    "越界输入不得触发保存",
  );
});

test("Claude local login state renders status text and imports from the machine (C075)", async () => {
  // C082: 本机登录态控件移入 Claude 配置对话框 (元素 id 与 C075 一致), 面板构建时仍先探测一次。
  const followed = await boot({ html: "settings.html" });
  assert.ok(followed.calls.some((call) => call.command === "claude_local_status"), "面板构建即探测本机登录态");
  await followed.node("provider-configure-claude").click();
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
  await missing.node("provider-configure-claude").click();
  assert.equal(missing.node("claude-local-state").textContent, "未检测到本机 Claude 登录态，登录 Claude CLI 后自动跟随");
  assert.equal(missing.node("claude-local-state").classList.contains("off"), true);

  const expired = await boot({ html: "settings.html", claudeLocal: { status: "expired", storedAccountCount: 1 } });
  await expired.node("provider-configure-claude").click();
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
  // C100: 状态灯承载四色与 hover 原因
  await app.emit("dashboard-updated", withRuntime({ phase: "fresh" }));
  assert.equal(app.node("hud-dot-wrap").classList.contains("tone-ok"), true);
  assert.equal(app.node("hud-dot-wrap").getAttribute("title"), "运行正常");
  await app.emit("dashboard-updated", withRuntime({ phase: "partial", error: "COLLECTION_PARTIAL" }));
  assert.equal(app.node("hud-dot-wrap").classList.contains("tone-warn"), true);
  assert.equal(app.node("hud-dot-wrap").getAttribute("title"), "部分失败 · 部分来源未能采集");
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

test("dashboard tabbed layout toggles single card, supports directional slide and persists selection (C088)", async () => {
  // 1. Stack 默认布局: 显示 hud-agents, 隐藏 hud-tabs, 堆叠多张卡片
  const stackApp = await boot({ settings: { ...defaults, layoutMode: "stack" } });
  assert.equal(stackApp.node("hud-tabs").style.display, "none");
  assert.equal(stackApp.node("hud-agents").style.display, "");
  assert.ok(stackApp.node("stack").children.length >= 2, "stack 模式展示级联多卡");

  // 2. Tabbed 布局: 隐藏 hud-agents, 显示 hud-tabs, stack 仅渲染单卡
  const tabApp = await boot({ settings: { ...defaults, layoutMode: "tabbed", activeCardId: "usage" } });
  assert.equal(tabApp.node("hud-tabs").style.display, "inline-flex");
  assert.equal(tabApp.node("hud-agents").style.display, "none");
  assert.equal(tabApp.node("stack").children.length, 1, "tab 模式仅展示 1 张激活卡片");
  assert.equal(tabApp.node("tab-btn-usage").classList.contains("active"), true);
  assert.equal(tabApp.node("tab-active-dot").style.display, "block", "角标融合: 有活跃 Agent 时第 3 图标显示绿点");

  // 3. 点击切卡至 subscription
  await tabApp.node("tab-btn-subscription").click();
  await settle();
  assert.equal(tabApp.node("tab-btn-subscription").classList.contains("active"), true);
  assert.equal(tabApp.node("tab-btn-usage").classList.contains("active"), false);
  assert.equal(tabApp.node("stack").children.length, 1);
  assert.equal(tabApp.state.settings.activeCardId, "subscription", "持久化已激活卡片");

  // 4. 键盘数字键 3 切至 hourly
  await tabApp.window.dispatch("keydown", { key: "3" });
  await settle();
  assert.equal(tabApp.node("tab-btn-hourly").classList.contains("active"), true);
  assert.equal(tabApp.node("stack").children.length, 1);
  assert.equal(tabApp.state.settings.activeCardId, "hourly");
});



// MARK: - C089 / C090 / C091 / C093 / C094 / C096 订阅额度页语义与文案

test("removing a service deletes every credential and drops it from the added set (C089)", async () => {
  const accounts = [
    { field: "kimiQuotaAccounts", accountId: "k1", displayName: "k1", authorizationState: "ok" },
    { field: "kimiQuotaAccounts", accountId: "k2", displayName: "k2", authorizationState: "ok" },
    { field: "clineQuotaAccounts", accountId: "c1", displayName: "c1", authorizationState: "ok" },
  ];
  const app = await boot({
    html: "settings.html",
    accounts,
    settings: { ...defaults, enabledProviders: ["kimi", "cline"] },
  });
  await app.node("provider-configure-kimi").click();
  // 二次确认: 点「移除服务」不得立即删除 (对齐 mac 的破坏性语义)
  await app.node("cfg-remove-provider-kimi").click();
  assert.equal(
    app.calls.some(call => call.command === "remove_credential_account"),
    false,
    "确认前不得删除凭据",
  );
  await app.node("cfg-remove-confirm-kimi").click();
  // 一次原子删除整个 Provider 的凭据 (含界面不可见的不合规账号), 不再逐账号调用
  const removed = app.calls.filter(call => call.command === "remove_provider_credentials");
  assert.deepEqual(removed.map(call => call.args.provider), ["kimi"], "删除该 Provider 的全部凭据");
  assert.equal(
    app.calls.some(call => call.command === "remove_credential_account"),
    false,
    "不得逐账号删除 (中途失败会留下半删状态)",
  );
  assert.equal(app.state.settings.subscriptionProviders.kimi, undefined, "移出已添加集合");
  assert.deepEqual(
    [...app.state.settings.enabledProviders],
    ["cline"],
    "启用集合随已添加集合收敛, 移除即停止查询",
  );

  // 重新添加: 账号列表为空, 且默认关闭 —— 旧账号不复活
  const option = [...app.document.querySelectorAll("#provider-add-row .cfg-picker-option")]
    .find(node => node.textContent.includes("Kimi"));
  await option.click();
  await app.node("provider-add-confirm").click();
  await settle();
  assert.equal(app.state.settings.subscriptionProviders.kimi.enabled, false);
  assert.equal(app.node("provider-dialog").dataset.provider, "kimi", "重新添加即打开配置对话框");
  assert.doesNotMatch(app.node("provider-dialog").textContent, /已配置账号/, "重新添加后无旧账号");
  assert.equal(app.node("cfg-status").textContent, "未配置");
});

test("a failed service removal keeps the service and all of its state (C089)", async () => {
  const app = await boot({
    html: "settings.html",
    accounts: [{ field: "kimiQuotaAccounts", accountId: "k1", displayName: "k1", authorizationState: "ok" }],
    reject: { remove_provider_credentials: "凭证存储事务不可用" },
    settings: {
      ...defaults,
      enabledProviders: ["kimi"],
      subscriptionProviders: {
        kimi: { enabled: true, lastVerifiedAt: null, verificationStatus: "ok", failureReason: null },
      },
    },
  });
  await app.node("provider-configure-kimi").click();
  await app.node("cfg-remove-provider-kimi").click();
  const saves = app.calls.filter(call => call.command === "save_settings_command").length;
  await app.node("cfg-remove-confirm-kimi").click();
  assert.match(app.node("cfg-status").textContent, /移除失败：凭证存储事务不可用/, "失败原因就地可见");
  assert.equal(
    app.calls.filter(call => call.command === "save_settings_command").length,
    saves,
    "凭据删除失败时不得改动已添加集合",
  );
  assert.equal(app.state.settings.subscriptionProviders.kimi.enabled, true, "启用态保持不变");
  assert.equal(app.node("provider-dialog").classList.contains("hidden"), false, "对话框保持打开");
});

test("verification result drives the enable switch and re-adding starts disabled (C090)", async () => {
  const app = await boot({ html: "settings.html", settings: { ...defaults, enabledProviders: ["kimi"] } });
  // 添加服务为两步交互 (C096): 选中仅暂存, 必须再点「添加…」
  const option = [...app.document.querySelectorAll("#provider-add-row .cfg-picker-option")]
    .find(node => node.textContent.includes("Grok"));
  await option.click();
  assert.equal(
    app.state.settings.subscriptionProviders?.grok,
    undefined,
    "选中下拉项不产生已添加行",
  );
  assert.equal(app.node("provider-add-confirm").disabled, false, "选中后「添加…」可点");
  await app.node("provider-add-confirm").click();
  assert.equal(app.state.settings.subscriptionProviders.grok.enabled, false, "新添加的 Provider 默认关闭");
  assert.equal(
    app.state.settings.enabledProviders.includes("grok"),
    false,
    "未验证的新 Provider 不进入启用集合",
  );
});

test("verification ok enables and failed / needsRelogin disables, and the switch follows (C090)", async () => {
  let next = { status: "ok", reason: null };
  const app = await boot({
    html: "settings.html",
    accounts: [{ field: "kimiQuotaAccounts", accountId: "k1", displayName: "k1", authorizationState: "ok" }],
    verify: () => next,
    settings: {
      ...defaults,
      enabledProviders: [],
      subscriptionProviders: {
        kimi: { enabled: false, lastVerifiedAt: null, verificationStatus: "none", failureReason: null },
      },
    },
  });
  // 首轮渲染不得把未启用的开关画成开启 (设置载入前不回落为「全部启用」)
  assert.equal(app.node("provider-kimi").checked, false, "启动时开关与已保存启用态一致");

  await app.node("provider-configure-kimi").click();
  app.node("cfg-kimi-apiKey").value = "fixture-kimi-key";
  await app.node("cfg-kimi-apiKey").dispatch("input");
  await app.node("cfg-save-kimi").click();
  assert.equal(app.state.settings.subscriptionProviders.kimi.enabled, true, "验证 ok → 启用");
  assert.deepEqual(app.state.settings.enabledProviders, ["kimi"]);
  assert.equal(app.node("provider-kimi").checked, true, "开关随验证结果打开");

  next = { status: "failed", reason: "API key 无效或已过期" };
  await app.node("cfg-reverify-kimi").click();
  assert.equal(app.state.settings.subscriptionProviders.kimi.enabled, false, "验证 failed → 禁用");
  assert.equal(app.state.settings.subscriptionProviders.kimi.failureReason, "API key 无效或已过期");
  assert.equal(app.node("provider-kimi").checked, false, "开关随验证失败关闭");

  next = { status: "ok", reason: null };
  await app.node("cfg-reverify-kimi").click();
  assert.equal(app.node("provider-kimi").checked, true);
  next = { status: "needsRelogin", reason: null };
  await app.node("cfg-reverify-kimi").click();
  assert.equal(app.state.settings.subscriptionProviders.kimi.enabled, false, "验证 needsRelogin → 禁用");
  assert.equal(app.node("provider-kimi").checked, false, "开关随需重新登录关闭");

  // 外部变更 (后端 settings-updated) 后开关取已保存启用态, 不沿用重绘前的勾选
  app.state.settings.subscriptionProviders.kimi.enabled = true;
  app.state.settings.enabledProviders = ["kimi"];
  await app.emit("settings-updated", app.state.settings);
  assert.equal(app.node("provider-kimi").checked, true, "开关跟随已保存启用态");
});

test("row status tail reflects verification status and local CLI follow (C091)", async () => {
  const accounts = [
    { field: "kimiQuotaAccounts", accountId: "k1", displayName: "k1", authorizationState: "ok" },
    { field: "clineQuotaAccounts", accountId: "c1", displayName: "c1", authorizationState: "ok" },
  ];
  const app = await boot({
    html: "settings.html",
    accounts,
    settings: {
      ...defaults,
      enabledProviders: ["kimi", "cline"],
      subscriptionProviders: {
        kimi: { enabled: false, lastVerifiedAt: null, verificationStatus: "failed", failureReason: "API key 无效或已过期" },
        cline: { enabled: false, lastVerifiedAt: null, verificationStatus: "needsRelogin", failureReason: null },
      },
    },
  });
  const tail = (name) => [...app.node("setting-providers").querySelectorAll(".provider-row")]
    .find(row => row.querySelector(".provider-name").textContent === name)
    .querySelector(".auth-state");
  assert.equal(tail("Kimi").textContent, "验证失败", "验证失败不得伪装成已配置");
  assert.equal(tail("Kimi").classList.contains("warn"), true);
  assert.equal(tail("Cline").textContent, "需重新登录");

  // 本机 CLI 只读跟随计入「已配置」(对齐 mac claudeAppOrLocalProbe)
  const followed = await boot({
    html: "settings.html",
    accounts: [],
    claudeLocal: { status: "followed", storedAccountCount: 0 },
    settings: { ...defaults, enabledProviders: ["claude"] },
  });
  const followedRow = [...followed.node("setting-providers").querySelectorAll(".provider-row")][0];
  assert.equal(followedRow.querySelector(".auth-state").textContent, "已配置", "跟随中视为已配置");

  const absent = await boot({
    html: "settings.html",
    accounts: [],
    claudeLocal: { status: "notFound", storedAccountCount: 0 },
    settings: { ...defaults, enabledProviders: ["claude"] },
  });
  const absentRow = [...absent.node("setting-providers").querySelectorAll(".provider-row")][0];
  assert.equal(absentRow.querySelector(".auth-state").textContent, "未配置");
});

test("local CLI follow counts as configured for the switch, dialog and verification (C091)", async () => {
  const added = { claude: { enabled: false, lastVerifiedAt: null, verificationStatus: "none", failureReason: null } };
  const app = await boot({
    html: "settings.html",
    accounts: [],
    claudeLocal: { status: "followed", storedAccountCount: 0 },
    settings: { ...defaults, enabledProviders: [], subscriptionProviders: added },
  });
  // 行尾件、开关、对话框横幅共用同一「已配置」判据 (对齐 mac `.disabled(!configured)`)
  assert.equal(app.node("provider-claude").disabled, false, "跟随中 → 开关可用");
  await app.node("provider-configure-claude").click();
  assert.equal(app.node("cfg-status").textContent, "已配置 · 未验证", "对话框不得写「未配置」");
  assert.ok(app.node("cfg-reverify-claude"), "跟随中可重新验证");
  await app.node("cfg-reverify-claude").click();
  assert.equal(app.calls.find(call => call.command === "verify_subscription").args.provider, "claude");
  assert.equal(app.state.settings.subscriptionProviders.claude.enabled, true, "跟随验证通过 → 启用");
  assert.equal(app.node("provider-claude").checked, true);

  const absent = await boot({
    html: "settings.html",
    accounts: [],
    claudeLocal: { status: "notFound", storedAccountCount: 0 },
    settings: { ...defaults, enabledProviders: [], subscriptionProviders: added },
  });
  assert.equal(absent.node("provider-claude").disabled, true, "未配置且未启用 → 开关禁用");
  await absent.node("provider-configure-claude").click();
  assert.equal(absent.node("cfg-status").textContent, "未配置");
  assert.equal(absent.node("cfg-reverify-claude"), null);
});

test("StepFun site is written only when explicitly chosen (C093)", async () => {
  const unselected = await boot({
    html: "settings.html",
    settings: { ...defaults, enabledProviders: ["stepfun"] },
  });
  await unselected.node("provider-configure-stepfun").click();
  assert.equal(unselected.node("cfg-stepfun-site-domestic").checked, false, "站点默认不预选");
  assert.equal(unselected.node("cfg-stepfun-site-global").checked, false, "站点默认不预选");
  unselected.node("cfg-stepfun-token").value = "fixture-oasis-token";
  await unselected.node("cfg-stepfun-token").dispatch("input");
  await unselected.node("cfg-save-stepfun").click();
  const saved = unselected.calls.filter(call => call.command === "save_credential_account").pop();
  assert.equal("site" in saved.args.payload, false, "未选择站点时不写入 site, 交由采集端按令牌推导");
  assert.equal("is_global" in saved.args.payload, false);

  const chosen = await boot({
    html: "settings.html",
    settings: { ...defaults, enabledProviders: ["stepfun"] },
  });
  await chosen.node("provider-configure-stepfun").click();
  chosen.node("cfg-stepfun-token").value = "fixture-oasis-token";
  await chosen.node("cfg-stepfun-token").dispatch("input");
  chosen.node("cfg-stepfun-site-global").checked = true;
  await chosen.node("cfg-save-stepfun").click();
  const explicit = chosen.calls.filter(call => call.command === "save_credential_account").pop();
  assert.equal(explicit.args.payload.site, "global", "显式选择写入 site");
  assert.equal(explicit.args.payload.is_global, true);
});

test("consent summary lists only enabled and configured providers (C094)", async () => {
  const app = await boot({
    html: "settings.html",
    accounts: [{ field: "kimiQuotaAccounts", accountId: "k1", displayName: "k1", authorizationState: "ok" }],
    settings: { ...defaults, enabledProviders: ["kimi", "cline"] },
  });
  const summary = app.node("consent-list").textContent;
  assert.match(summary, /Kimi/, "已启用且已配置的 Provider 进入摘要");
  assert.doesNotMatch(summary, /Cline/, "未配置的 Provider 不得出现在摘要");

  const empty = await boot({ html: "settings.html", accounts: [], settings: { ...defaults, enabledProviders: [] } });
  assert.match(empty.node("consent-list").textContent, /不会访问云端额度接口/, "空集走兜底文案");
});

test("consent summary follows verification, the switch and settings updates (C094)", async () => {
  const app = await boot({
    html: "settings.html",
    accounts: [{ field: "kimiQuotaAccounts", accountId: "k1", displayName: "k1", authorizationState: "ok" }],
    claudeLocal: { status: "notFound", storedAccountCount: 0 },
    settings: {
      ...defaults,
      enabledProviders: [],
      subscriptionProviders: {
        kimi: { enabled: false, lastVerifiedAt: null, verificationStatus: "none", failureReason: null },
      },
    },
  });
  const summary = () => app.node("consent-list").textContent;
  assert.match(summary(), /不会访问云端额度接口/, "已配置但未启用不入摘要");

  await app.node("provider-configure-kimi").click();
  app.node("cfg-kimi-apiKey").value = "fixture-kimi-key";
  await app.node("cfg-kimi-apiKey").dispatch("input");
  await app.node("cfg-save-kimi").click();
  assert.match(summary(), /查询已启用订阅 Provider 的云端额度：Kimi/, "验证通过启用后摘要立即出现该 Provider");

  app.node("provider-kimi").checked = false;
  await app.node("provider-kimi").dispatch("change");
  assert.equal(app.state.settings.subscriptionProviders.kimi.enabled, false);
  assert.match(summary(), /不会访问云端额度接口/, "手动关闭后摘要立即移除");

  app.state.settings.subscriptionProviders.kimi.enabled = true;
  app.state.settings.enabledProviders = ["kimi"];
  await app.emit("settings-updated", app.state.settings);
  assert.match(summary(), /Kimi/, "后端 settings-updated 后摘要同步");
});

test("subscription pane wording and layout follow mac (C096)", async () => {
  const app = await boot({ html: "settings.html", accounts: [], settings: { ...defaults, enabledProviders: [] } });
  // 底部提示位于两张卡下方且逐字含「统一」
  const hint = app.document.querySelectorAll(".subscription-hint");
  assert.equal(hint.length, 1);
  assert.match(hint[0].textContent, /统一授权生效时/);
  const cards = [...app.node("pane-subscription-content").querySelectorAll(".fluent-card")];
  assert.equal(cards.at(-1).querySelector(".subscription-hint"), null, "提示不在卡内");
  // 空态副标题
  assert.match(app.node("setting-providers").textContent, /尚未配置任何订阅 Provider/);
  assert.match(app.node("setting-providers").textContent, /从下方添加服务/);
});

test("verified dialog banner carries the mac suffix and account removal asks first (C096)", async () => {
  const accounts = [{ field: "kimiQuotaAccounts", accountId: "k1", displayName: "k1", authorizationState: "ok" }];
  const app = await boot({
    html: "settings.html",
    accounts,
    settings: {
      ...defaults,
      enabledProviders: ["kimi"],
      subscriptionProviders: {
        kimi: { enabled: true, lastVerifiedAt: "2026-10-22T08:00:00Z", verificationStatus: "ok", failureReason: null },
      },
    },
  });
  await app.node("provider-configure-kimi").click();
  assert.match(app.node("cfg-status").textContent, /· 验证通过/, "验证通过横幅带 mac 后缀");

  // 账号移除需二次确认
  await app.node("cfg-remove-k1").click();
  assert.equal(
    app.calls.some(call => call.command === "remove_credential_account"),
    false,
    "确认前不得删除账号",
  );
  assert.match(app.node("provider-dialog").textContent, /移除 k1 账号\?/);
  await app.node("cfg-remove-confirm-k1").click();
  const removed = app.calls.find(call => call.command === "remove_credential_account");
  assert.equal(removed.args.accountId, "k1", "确认后才删除");
});

test("rejected legacy accounts are explained in the dialog and stay out of the account list (C092)", async () => {
  const app = await boot({
    html: "settings.html",
    accounts: [],
    rejections: [{ field: "kimiQuotaAccounts", accountId: "legacy", reason: "api_key 含空白字符, 格式不合理" }],
    settings: { ...defaults, enabledProviders: ["kimi"] },
  });
  const row = [...app.node("setting-providers").querySelectorAll(".provider-row")][0];
  assert.equal(row.querySelector(".auth-state").textContent, "未配置", "不合规账号不计入已配置");
  assert.equal(row.querySelector(".provider-sub").textContent, "Web 令牌", "账号数不把不合规记录算进去");
  await app.node("provider-configure-kimi").click();
  assert.match(
    app.node("cfg-rejections-kimi").textContent,
    /存在 1 个格式不合规的旧账号.*legacy（api_key 含空白字符, 格式不合理）/,
    "对话框须说明原因",
  );
});

test("re-saving the same StepFun token upserts one account and clears a stale site (C093)", async () => {
  const app = await boot({ html: "settings.html", settings: { ...defaults, enabledProviders: ["stepfun"] } });
  // 旧版行为: 站点单选默认选中并写入国内站
  await app.node("provider-configure-stepfun").click();
  app.node("cfg-stepfun-token").value = "fixture-oasis-token";
  await app.node("cfg-stepfun-token").dispatch("input");
  app.node("cfg-stepfun-site-domestic").checked = true;
  await app.node("cfg-save-stepfun").click();
  const first = app.calls.filter(call => call.command === "save_credential_account").pop();
  assert.equal(first.args.payload.site, "domestic");

  // 修复后再存同一 token 且不选站点: 必须 upsert 到同一账号并清除旧站点
  await app.node("provider-configure-stepfun").click();
  app.node("cfg-stepfun-token").value = "fixture-oasis-token";
  await app.node("cfg-stepfun-token").dispatch("input");
  await app.node("cfg-save-stepfun").click();
  const second = app.calls.filter(call => call.command === "save_credential_account").pop();
  assert.equal(second.args.accountId, first.args.accountId, "同一 token 必须落在同一账号 (不产生重复)");
  assert.equal("site" in second.args.payload, false, "未选站点时清除旧站点, 由采集端按令牌推导");
  assert.equal("is_global" in second.args.payload, false);
});

test("add button follows the picker and the banner uses the mac relogin wording (C096)", async () => {
  const app = await boot({
    html: "settings.html",
    accounts: [{ field: "kimiQuotaAccounts", accountId: "k1", displayName: "k1", authorizationState: "ok" }],
    settings: {
      ...defaults,
      enabledProviders: ["kimi"],
      subscriptionProviders: {
        kimi: { enabled: false, lastVerifiedAt: null, verificationStatus: "needsRelogin", failureReason: null },
      },
    },
  });
  const children = [...app.node("provider-add-row").children];
  const pickerIndex = children.findIndex(child => child.classList?.contains("cfg-picker"));
  const buttonIndex = children.findIndex(child => child.id === "provider-add-confirm");
  assert.ok(pickerIndex >= 0 && buttonIndex >= 0, "选择器与「添加…」都存在");
  assert.ok(pickerIndex < buttonIndex, "「添加…」必须位于选择器之后");

  // 对话框横幅用 mac ProviderStatusBanner 的「需要重新登录」;
  // 行尾件保持 mac subscriptionStatusTail 的「需重新登录」—— mac 本就不同。
  await app.node("provider-configure-kimi").click();
  assert.match(app.node("cfg-status").textContent, /需要重新登录/);
  const row = [...app.node("setting-providers").querySelectorAll(".provider-row")][0];
  assert.equal(row.querySelector(".auth-state").textContent, "需重新登录");
});

test("hotkey recorder normalizes physical key codes, blocks reserved combos, and suspends backend hotkey during recording (C099)", async () => {
  const app = await boot({ html: "settings.html" });
  await app.document.querySelector('[data-category="general"]').click();

  const field = app.node("setting-hotkey");
  const recordBtn = app.node("hotkey-record");

  // 1. 进入录制态: 按钮文案更新且通知后端挂起全局热键
  await recordBtn.click();
  assert.equal(field.dataset.recording, "true");
  assert.match(recordBtn.textContent, /按键中/);
  assert.ok(app.calls.some(c => c.command === "set_hotkey_recording" && c.args.recording === true));

  // 2. Ctrl+Shift+1: 浏览器上报 key="!" 但物理 code="Digit1"，必须规范化为 Control+Shift+1
  await field.dispatch("keydown", { ctrlKey: true, shiftKey: true, key: "!", code: "Digit1" });
  assert.equal(field.dataset.recording, "false");
  assert.equal(field.value, "Control+Shift+1");
  assert.equal(app.state.settings.hotkey, "Control+Shift+1");
  assert.ok(app.calls.some(c => c.command === "set_hotkey_recording" && c.args.recording === false));

  // 3. Alt+Space: key=" " 规范化为 Alt+Space
  await recordBtn.click();
  await field.dispatch("keydown", { altKey: true, key: " ", code: "Space" });
  assert.equal(field.value, "Alt+Space");
  assert.equal(app.state.settings.hotkey, "Alt+Space");

  // 4. 系统保留热键 (Alt+Tab) 与纯 Shift+字母拦截，不落盘
  await recordBtn.click();
  await field.dispatch("keydown", { altKey: true, key: "Tab", code: "Tab" });
  assert.equal(field.dataset.recording, "true", "系统保留组合键拦截后仍留在录制态重录");
  assert.equal(app.node("settings-status").dataset.tone, "warn");
  await field.dispatch("keydown", { shiftKey: true, key: "A", code: "KeyA" });
  assert.equal(field.dataset.recording, "true", "纯 Shift+字母不允许作为全局热键");

  // 5. Escape 取消录制并恢复已生效热键显示
  await field.dispatch("keydown", { key: "Escape", code: "Escape" });
  assert.equal(field.dataset.recording, "false");
  assert.equal(field.value, "Alt+Space");

  // 6. 失焦 (blur) 自动退出录制态并恢复原值
  await recordBtn.click();
  assert.equal(field.value, "");
  await field.dispatch("blur");
  assert.equal(field.dataset.recording, "false");
  assert.equal(field.value, "Alt+Space");
});

test("hotkey recorder keeps numpad keys distinct, rejects unsupported keys, cancels from the button, and reports a failed resume (C099)", async () => {
  const app = await boot({ html: "settings.html", settings: { ...defaults, hotkey: "Control+Shift+B" } });
  await app.document.querySelector('[data-category="general"]').click();
  const field = app.node("setting-hotkey");
  const recordBtn = app.node("hotkey-record");

  // 1. 小键盘数字在 global-hotkey 中与主键盘数字是不同的键, 必须录成 Numpad1 而不是 1
  await recordBtn.click();
  await field.dispatch("keydown", { ctrlKey: true, altKey: true, key: "1", code: "Numpad1" });
  assert.equal(field.value, "Control+Alt+Numpad1");
  assert.equal(app.state.settings.hotkey, "Control+Alt+Numpad1");
  await recordBtn.click();
  await field.dispatch("keydown", { ctrlKey: true, key: "+", code: "NumpadAdd" });
  assert.equal(app.state.settings.hotkey, "Control+NumpadAdd", "小键盘 + 不得拼成无法解析的 Control++");

  // 2. global-hotkey 不认识的键码直接拦截提示, 不落盘也不退出录制
  await recordBtn.click();
  await field.dispatch("keydown", { ctrlKey: true, key: "ContextMenu", code: "ContextMenu" });
  assert.equal(field.dataset.recording, "true");
  assert.equal(app.node("settings-status").dataset.tone, "warn");
  assert.match(app.node("settings-status").textContent, /不支持/);
  assert.equal(app.state.settings.hotkey, "Control+NumpadAdd");

  // 3. 录制中按下录制按钮不夺走输入框焦点 (WebView2 先 blur 后 click), 再次点击即取消录制
  let prevented = false;
  await recordBtn.dispatch("mousedown", { preventDefault() { prevented = true; } });
  assert.equal(prevented, true, "录制中按下按钮必须阻止输入框失焦");
  await recordBtn.click();
  assert.equal(field.dataset.recording, "false");
  assert.equal(field.value, "Control+NumpadAdd");
  assert.equal(app.node("settings-status").textContent, "已取消快捷键录制");
  const recordingCalls = app.calls.filter(c => c.command === "set_hotkey_recording").map(c => c.args.recording);
  assert.deepEqual(recordingCalls.slice(-2), [true, false], "进入与退出录制各通知后端一次");
  prevented = false;
  await recordBtn.dispatch("mousedown", { preventDefault() { prevented = true; } });
  assert.equal(prevented, false, "非录制态不干预按钮默认焦点行为");

  // 4. 退出录制时后端恢复已生效热键失败: 必须提示用户当前热键已失效
  const failing = await boot({ html: "settings.html", settings: { ...defaults, hotkey: "Control+Shift+B" }, reject: { set_hotkey_recording: "HOTKEY_RESUME_FAILED" } });
  await failing.document.querySelector('[data-category="general"]').click();
  await failing.node("hotkey-record").click();
  await settle();
  assert.notEqual(failing.node("settings-status").dataset.tone, "warn", "进入录制失败不打扰");
  await failing.node("setting-hotkey").dispatch("keydown", { key: "Escape", code: "Escape" });
  await settle();
  assert.equal(failing.node("settings-status").dataset.tone, "warn");
  assert.match(failing.node("settings-status").textContent, /恢复失败/);
});

test("top HUD four-color status light matches shared parity fixture and drives DOM tone/tooltip (C100)", async () => {
  const app = await boot();
  const parity = JSON.parse(
    readFileSync(new URL("../../../tests/fixtures/status-tone-parity/cases.json", import.meta.url), "utf8"),
  );
  assert.ok(parity.cases.length >= 20, "共享 fixture 覆盖全部判定分支");
  for (const item of parity.cases) {
    const resolved = app.context.resolveDashboardStatus({
      moduleState: item.moduleState,
      subscriptions: item.subscriptions,
      hasData: item.hasData,
      detail: item.detail,
    });
    assert.equal(resolved.tone, item.expectedTone, `${item.name}: tone`);
    assert.equal(resolved.isRefreshing, item.expectedRefreshing, `${item.name}: isRefreshing`);
    assert.equal(resolved.reason, item.expectedReason, `${item.name}: reason`);
  }

  // DOM 呈现: 四色状态灯 + refreshing 脉冲 + hover 原因 + 品牌字 Bruce + 无 #runtime-status
  const dotWrap = app.node("hud-dot-wrap");
  assert.equal(app.node("runtime-status"), null, "删除 #runtime-status 文字牌");
  assert.equal(dotWrap.getAttribute("role"), "status", "迁移 role=status 语义");
  assert.equal(app.document.querySelector(".hud-brand").textContent, "Bruce");

  // 1. 绿 (ok)
  await app.emit("dashboard-updated", { ...fixture, runtime: { phase: "fresh" } });
  assert.equal(dotWrap.classList.contains("tone-ok"), true);
  assert.equal(dotWrap.classList.contains("refreshing"), false);
  assert.equal(dotWrap.getAttribute("title"), "运行正常");
  assert.equal(dotWrap.getAttribute("aria-label"), "运行正常");

  // 2. 黄 (warn: 订阅段 partial 提升采集 fresh), 原因点名该服务
  const subWarnPanel = structuredClone(fixture);
  subWarnPanel.runtime = { phase: "fresh" };
  subWarnPanel.subscription.sections[0].status = "partial";
  await app.emit("dashboard-updated", subWarnPanel);
  assert.equal(dotWrap.classList.contains("tone-warn"), true);
  assert.equal(dotWrap.getAttribute("title"), "部分失败 · Kimi");

  // 3. 红 (error: 订阅段 error 提升采集 partial): 原因点名订阅服务, 不挂采集侧错误
  const subErrorPanel = structuredClone(fixture);
  subErrorPanel.runtime = { phase: "partial", error: "COLLECTION_PARTIAL" };
  subErrorPanel.subscription.sections[0].status = "error";
  await app.emit("dashboard-updated", subErrorPanel);
  assert.equal(dotWrap.classList.contains("tone-error"), true);
  assert.equal(dotWrap.getAttribute("title"), "失败 · Kimi");

  // 3b. Windows runtime.error 只是机器码: 已登记的码展示中文释义, 未登记的码绝不外露
  await app.emit("dashboard-updated", { ...fixture, runtime: { phase: "stale", error: "SNAPSHOT_RESTORED" } });
  assert.equal(dotWrap.getAttribute("title"), "数据过期 · 显示上次保存的数据");
  await app.emit("dashboard-updated", { ...fixture, runtime: { phase: "stale", error: "NETWORK_UNAVAILABLE" } });
  assert.equal(dotWrap.getAttribute("title"), "数据过期 · 网络不可用");
  await app.emit("dashboard-updated", { ...fixture, runtime: { phase: "failed", error: "SOME_FUTURE_CODE" } });
  assert.equal(dotWrap.getAttribute("title"), "刷新失败");
  for (const code of ["COLLECTION_PARTIAL", "COLLECTION_FAILED", "SNAPSHOT_RESTORED", "SNAPSHOT_WRITE_FAILED",
    "SNAPSHOT_INVALID", "SNAPSHOT_READ_FAILED", "ARTIFACT_MISSING", "ARTIFACT_INVALID", "NETWORK_UNAVAILABLE"]) {
    await app.emit("dashboard-updated", { ...fixture, runtime: { phase: "partial", error: code } });
    assert.doesNotMatch(dotWrap.getAttribute("title"), /[A-Z]{2,}_[A-Z]/, `${code} 不得以机器码出现在悬停原因中`);
    assert.notEqual(dotWrap.getAttribute("title"), "部分失败", `${code} 应有中文释义`);
  }

  // 4. 中性灰 (neutral / idle: 首次启动无数据)
  await app.emit("dashboard-updated", { usage: null, subscription: null, hourly: null, diagnostics: [], runtime: { phase: "empty" } });
  assert.equal(dotWrap.classList.contains("tone-neutral"), true);
  assert.equal(dotWrap.classList.contains("tone-idle"), true);
  assert.equal(dotWrap.getAttribute("title"), "暂无数据");

  // 5. 刷新中脉冲 (refreshing + 底色保持当前态色)
  await app.emit("dashboard-updated", { ...fixture, runtime: { phase: "refreshing" } });
  assert.equal(dotWrap.classList.contains("tone-ok"), true);
  assert.equal(dotWrap.classList.contains("refreshing"), true);
  assert.equal(dotWrap.getAttribute("title"), "正在刷新…");
  assert.equal(app.node("refresh").disabled, true);

  // 5b. 首帧数据到达前不得预先亮绿灯「运行正常」
  const indexHtml = readFileSync(new URL("../src/index.html", import.meta.url), "utf8");
  assert.match(indexHtml, /id="hud-dot-wrap" class="hud-dot-wrap tone-neutral tone-idle"[^>]*title="暂无数据"/);

  // 6. styles.css 契约: 无 .hud-sysok 残留, Nothing 品牌字无 uppercase, 定义四色 tone 规则
  const css = readFileSync(new URL("../src/styles.css", import.meta.url), "utf8");
  assert.doesNotMatch(css, /\.hud-sysok\b/, "styles.css 已删除 .hud-sysok 规则");
  const nothingBrand = css.match(/\.theme-nothing \.hud-brand\s*\{[^}]*\}/)[0];
  assert.doesNotMatch(nothingBrand, /text-transform:\s*uppercase/, "Nothing .hud-brand 不得強制 uppercase");
  for (const toneRule of [".hud-dot-wrap.tone-ok", ".hud-dot-wrap.tone-warn", ".hud-dot-wrap.tone-error", ".hud-dot-wrap.tone-neutral"]) {
    assert.ok(css.includes(toneRule), `styles.css 包含 ${toneRule}`);
  }
});

test("codex dialog drives device login and discovery buttons follow local files (C084)", async () => {
  const flush = async (times = 8) => {
    for (let i = 0; i < times; i += 1) {
      await new Promise(resolve => setTimeout(resolve, 0));
      await settle();
    }
  };
  const app = await boot({
    html: "settings.html",
    settings: { ...defaults, enabledProviders: ["codex"] },
  });
  await app.node("provider-configure-codex").click();
  // 两个来源都存在时两个发现入口都出现
  assert.ok(app.node("cfg-codex-discover-cli"), "本机 CLI 来源存在即显示发现按钮");
  assert.ok(app.node("cfg-codex-discover-ccswitch"), "CC Switch 来源存在即显示发现按钮");

  await app.node("cfg-codex-login").click();
  assert.ok(app.calls.some(c => c.command === "codex_device_start"), "点击登录即发起设备码申请");
  assert.match(app.node("provider-dialog").textContent, /ABCD-1234/, "展示服务端下发的验证码");
  assert.equal(app.node("cfg-codex-device").classList.contains("hidden"), false, "设备码面板可见");
  await app.node("cfg-codex-reopen").click();
  assert.ok(app.calls.some(c => c.command === "open_verification_page"), "可重新打开验证页");

  // 轮询 pending → authorized (fixture intervalSeconds=0)
  await flush();
  const polls = app.calls.filter(c => c.command === "codex_device_poll");
  assert.ok(polls.length >= 2, `授权完成前逐轮轮询 (实际 ${polls.length} 次)`);
  assert.equal(polls[0].args.userCode, "ABCD-1234", "轮询带上服务端下发的验证码");
  // 授权完成后账号落库并进入已配置
  assert.match(app.node("provider-dialog").textContent, /acct-1/, "授权后账号出现在已配置清单");
  assert.match(app.node("provider-dialog").textContent, /已登录 a@b\.c/, "回执点名新登录账号");
  const codexTail = () => [...app.node("setting-providers").querySelectorAll(".provider-row")]
    .find(row => row.querySelector(".provider-name").textContent === "Codex")
    .querySelector(".auth-state");
  assert.equal(codexTail().textContent, "已配置");
});

test("codex discovered metadata accounts need reauthorization and stay out of configured (C084)", async () => {
  const app = await boot({
    html: "settings.html",
    accounts: [{ field: "codexQuotaAccounts", accountId: "discovered-1", displayName: "discovered-1", authorizationState: "reauthRequired", usable: false }],
    settings: { ...defaults, enabledProviders: [] },
  });
  const row = () => [...app.node("setting-providers").querySelectorAll(".provider-row")]
    .find(item => item.querySelector(".provider-name").textContent === "Codex");
  // 发现的账号只写元数据: 行尾件提示「需要重新授权」, 但不得计入「已配置」
  assert.equal(row().querySelector(".auth-state").textContent, "需要重新授权");
  assert.equal(app.node("provider-codex").disabled, true, "元数据账号不得启用 (fail-closed)");

  await app.node("provider-configure-codex").click();
  assert.match(app.node("provider-dialog").textContent, /需要重新授权/, "对话框列出待授权账号");
  assert.match(app.node("provider-dialog").textContent, /未配置/, "横幅不得写已配置");
  await app.node("cfg-codex-discover-cli").click();
  assert.ok(app.calls.some(c => c.command === "codex_import_discovered"), "发现按钮调用只读发现命令");
  assert.match(app.node("provider-dialog").textContent, /发现 1 个账号（需重新授权）/, "发现回执说明只写元数据");
});

test("codex dialog hides discovery entries when no local account files exist (C084)", async () => {
  const app = await boot({
    html: "settings.html",
    codexSources: { cliAuth: false, ccSwitch: false },
    settings: { ...defaults, enabledProviders: ["codex"] },
  });
  await app.node("provider-configure-codex").click();
  assert.equal(app.node("cfg-codex-discover-cli"), null, "无 CLI 文件时不显示对应入口");
  assert.equal(app.node("cfg-codex-discover-ccswitch"), null, "无 CC Switch 文件时不显示对应入口");
  assert.match(app.node("provider-dialog").textContent, /未发现本机 Codex CLI/, "给出缺失说明");
});

test("grok dialog follows the local CLI login and counts as configured (C085)", async () => {
  const app = await boot({
    html: "settings.html",
    accounts: [],
    grokLocal: { status: "followed", storedAccountCount: 0 },
    settings: { ...defaults, enabledProviders: ["grok"] },
  });
  // 本机只读跟随计入「已配置」(设计规则 26), 不落盘也应显示已配置。
  const row = () => [...app.node("setting-providers").querySelectorAll(".provider-row")]
    .find(item => item.querySelector(".provider-name").textContent === "Grok");
  assert.equal(row().querySelector(".auth-state").textContent, "已配置");

  await app.node("provider-configure-grok").click();
  assert.match(app.node("provider-dialog").textContent, /%USERPROFILE%\\\.grok\\auth\.json/, "说明只读来源");
  assert.match(app.node("grok-local-state").textContent, /自动跟随本机 Grok CLI 登录态/);
  assert.equal(app.node("grok-local-state").classList.contains("ok"), true);
  await app.node("grok-local-detect").click();
  assert.ok(app.calls.some(c => c.command === "grok_local_status"), "重新检测调用探测命令");
  await app.node("grok-local-import").click();
  assert.ok(app.calls.some(c => c.command === "import_grok_from_local"), "从本机导入调用导入命令");

  // 未发现 / 已过期时不计入「已配置」
  for (const [status, text] of [["notFound", "未检测到本机 Grok 登录态"], ["expired", "登录已过期"]]) {
    const other = await boot({
      html: "settings.html",
      accounts: [],
      grokLocal: { status, storedAccountCount: 0 },
      settings: { ...defaults, enabledProviders: ["grok"] },
    });
    const otherRow = [...other.node("setting-providers").querySelectorAll(".provider-row")]
      .find(item => item.querySelector(".provider-name").textContent === "Grok");
    assert.equal(otherRow.querySelector(".auth-state").textContent, "未配置", `${status} 不得计入已配置`);
    await other.node("provider-configure-grok").click();
    assert.match(other.node("grok-local-state").textContent, new RegExp(text));
  }
});

test("claude dialog keeps the paste entry collapsed behind an advanced section (C085)", async () => {
  const app = await boot({
    html: "settings.html",
    accounts: [],
    claudeLocal: { status: "followed", storedAccountCount: 0 },
    settings: { ...defaults, enabledProviders: ["claude"] },
  });
  await app.node("provider-configure-claude").click();
  const details = app.node("provider-dialog").querySelector(".cfg-advanced");
  assert.ok(details, "粘贴入口收进 .cfg-advanced 折叠区");
  assert.equal(details.getAttribute("open"), null, "默认折叠 (无 open 属性)");
  assert.ok(details.querySelector("#cfg-claude-paste"), "折叠区内仍是原粘贴元素 (id 不变)");
  assert.ok(details.querySelector("#cfg-claude-secret"), "纯令牌入口同样在折叠区内");
});

test("opencode GO account id derives from workspaceId so re-pasting upserts (C085)", async () => {
  const app = await boot({ html: "settings.html", settings: { ...defaults, enabledProviders: ["opencodeGo"] } });
  const paste = async (workspaceId) => {
    await app.node("provider-configure-opencodeGo").click();
    app.node("cfg-opencodeGo-paste").value = JSON.stringify({ auth: "Fe26.2**fixture", workspaceId });
    await app.node("cfg-opencodeGo-paste").dispatch("input");
    await app.node("cfg-save-opencodeGo").click();
    return app.calls.filter(c => c.command === "save_credential_account").pop().args.accountId;
  };
  const first = await paste("wrk_first");
  const again = await paste("wrk_first");
  assert.equal(first, again, "同一 workspaceId 重复粘贴必须 upsert 到同一账号");
  const other = await paste("wrk_second");
  assert.notEqual(first, other, "不同 workspaceId 视为不同账号");
});

test("stepfun dialog supports embedded web login auto-capture, site switch, session clear and manual fallback (C086)", async () => {
  const app = await boot({
    html: "settings.html",
    settings: {
      ...defaults,
      enabledProviders: [],
      subscriptionProviders: {
        stepfun: { enabled: false, lastVerifiedAt: null, verificationStatus: "none", failureReason: null },
      },
    },
    stepfunPoll: [
      { status: "captured", site: "global", currentUrl: "https://platform.stepfun.ai/plan-subscribe", accountId: "stepfun-web1", message: "🎉 检测到 🌐 国际站 登录完成，已提取 Oasis-Token" },
    ],
  });
  await app.node("provider-configure-stepfun").click();

  // 1. 网页登录自动绑定入口与手动粘贴并存，引导与 mac 逐字对齐
  assert.ok(app.node("cfg-stepfun-login-domestic"), "包含国内站网页登录按钮");
  assert.ok(app.node("cfg-stepfun-login-global"), "包含国际站网页登录按钮");
  assert.match(app.node("provider-dialog").textContent, /可点击上方一键登录自动绑定\(支持国内\/国际站\)，或控制台按 F12 复制 Cookie/);
  assert.equal(app.node("cfg-stepfun-web-panel").classList.contains("hidden"), true, "初始隐藏网页登录控制面板");

  // 2. 点击「登录国内站」打开网页窗口并展开控制面板
  await app.node("cfg-stepfun-login-domestic").click();
  assert.ok(app.calls.some(c => c.command === "stepfun_web_login_open" && c.args.site === "domestic"));
  assert.equal(app.node("cfg-stepfun-web-panel").classList.contains("hidden"), false, "打开网页窗口后显示控制面板");
  assert.equal(app.node("cfg-stepfun-web-title").textContent, "登录阶跃星辰开放平台 · 🇨🇳 国内站");
  assert.equal(app.node("cfg-stepfun-web-url").textContent, "https://platform.stepfun.com/step-plan");

  // 3. 工具栏导航与清理缓存可正常调用
  await app.node("cfg-stepfun-web-home").click();
  assert.ok(app.calls.some(c => c.command === "stepfun_web_login_action" && c.args.action === "home"));
  assert.equal(app.node("cfg-stepfun-web-url").textContent, "https://platform.stepfun.com");
  await app.node("cfg-stepfun-web-clear").click();
  assert.ok(app.calls.some(c => c.command === "stepfun_web_login_clear_session"));
  assert.match(app.node("cfg-stepfun-web-status").textContent, /已清空 .* 登录缓存/);

  // 4. 切换到国际站，再由页面加载事件触发轮询完成自动捕获
  await app.node("cfg-stepfun-web-site-global").click();
  assert.ok(app.calls.some(c => c.command === "stepfun_web_login_open" && c.args.site === "global"));
  assert.equal(app.node("cfg-stepfun-web-title").textContent, "登录阶跃星辰开放平台 · 🌐 国际站");

  await app.emit("stepfun-page-load", { url: "https://platform.stepfun.ai/plan-subscribe", loading: false });
  assert.ok(app.calls.some(c => c.command === "verify_subscription" && c.args.provider === "stepfun"), "捕获后触发订阅验证");
  assert.equal(app.state.settings.subscriptionProviders.stepfun.enabled, true, "验证通过后启用 StepFun");
  assert.match(app.node("provider-dialog").textContent, /StepFun · web1/, "捕获的账号进入已配置列表");
});

test("tray hover preview toggle persists in settings and preview.html has 420px ring flyout structure (T12)", async () => {
  const fs = await import("node:fs");
  const path = await import("node:path");

  // 1. preview.html 静态结构与 420px 环形仪表断言
  const previewHtmlPath = path.resolve("apps/win/src/preview.html");
  assert.ok(fs.existsSync(previewHtmlPath), "preview.html 必须存在");
  const htmlContent = fs.readFileSync(previewHtmlPath, "utf-8");
  assert.match(htmlContent, /class="micro-preview-card"/, "包含 420px 微缩卡容器");
  assert.match(htmlContent, /id="ringCircle"/, "包含 42px 环形仪表圆弧");
  assert.match(htmlContent, /id="expandBtn"/, "包含展开看板按钮");
  assert.match(htmlContent, /expand_dashboard/, "绑定 expand_dashboard IPC 命令");

  // 2. 设置中心通用页托盘实时预览开关联动
  const app = await boot({
    html: "settings.html",
    settings: {
      ...defaults,
      trayHoverPreview: true,
    },
  });

  const previewToggle = app.node("setting-tray-hover-preview");
  const previewState = app.node("setting-tray-hover-preview-state");
  assert.ok(previewToggle, "包含托盘实时预览开关");
  assert.ok(previewState, "包含开关状态文本");
  assert.equal(previewToggle.checked, true, "默认开启");
  assert.equal(previewState.textContent, "已开启", "状态文字为已开启");

  // 切换为关闭
  previewToggle.checked = false;
  await previewToggle.dispatch("change");
  assert.equal(previewState.textContent, "已关闭", "切换后状态文字为已关闭");
  assert.equal(app.state.settings.trayHoverPreview, false, "持久化保存为 false");
});


test("tray preview card renders backend panel.preview from the real panel contract (C115)", async () => {
  const fs = await import("node:fs");
  const path = await import("node:path");
  // 与 Rust preview_fixture_matches_backend_serialization 同一份 fixture: 后端对 golden 面板的序列化结果
  const preview = JSON.parse(fs.readFileSync(path.resolve("tests/fixtures/viewmodel-parity/agent-usage-valid.preview.json"), "utf8"));
  const app = await boot({ html: "preview.html", panel: { ...fixture, preview } });
  assert.deepEqual(app.errors, []);
  assert.equal(app.node("ringPercentText").textContent, "30%");
  assert.equal(app.node("topProviderName").textContent, "ChatGPT");
  assert.equal(app.node("topResetCountdown").textContent, "重置 78 天后");
  assert.equal(app.node("kpiCostText").textContent, "≈ ¥2.702");
  assert.equal(app.node("kpiTokensText").textContent, "184K Tokens");
  assert.equal(app.node("activeAgentCountText").textContent, "2 活跃");
  assert.equal(app.node("statusText").textContent, "运行正常");

  // 无有效配额窗口 / 定价缺失: 显示「—」而不是伪造的 100% 与 $0.00
  await app.emit("dashboard-updated", { ...fixture, preview: { ...preview, remainingPct: null, topProvider: null, resetText: null, topWindowLabel: null, costText: null, statusTone: "warn" } });
  assert.equal(app.node("ringPercentText").textContent, "—");
  assert.equal(app.node("topProviderName").textContent, "暂无订阅额度");
  assert.equal(app.node("kpiCostText").textContent, "—");
  assert.equal(app.node("statusText").textContent, "部分告警");
  assert.ok(app.node("statusChip").classList.contains("warn"));
});

test("account rows can be renamed without touching credentials (T18)", async () => {
  const accounts = [
    { field: "kimiQuotaAccounts", accountId: "k1", displayName: "Kimi · 账号 1", authorizationState: "ok" },
    { field: "kimiQuotaAccounts", accountId: "k2", displayName: "Kimi · 账号 2", authorizationState: "ok" },
  ];
  const app = await boot({
    html: "settings.html",
    accounts,
    settings: {
      ...defaults,
      enabledProviders: ["kimi"],
      subscriptionProviders: {
        kimi: { enabled: true, lastVerifiedAt: null, verificationStatus: "ok", failureReason: null },
      },
    },
  });
  await app.node("provider-configure-kimi").click();
  await app.node("cfg-rename-k1").click();
  const input = app.node("cfg-rename-input-k1");
  assert.equal(input.value, "账号 1", "编辑框只显示标签, 不包含 Provider 前缀");

  input.value = "工作";
  await app.node("cfg-rename-save-k1").click();
  const rename = app.calls.find(call => call.command === "rename_credential_account");
  assert.equal(rename.args.field, "kimiQuotaAccounts");
  assert.equal(rename.args.accountId, "k1");
  assert.equal(rename.args.displayName, "Kimi · 工作");
  assert.equal(
    app.calls.some(call => call.command === "save_credential_account"),
    false,
    "重命名不得重写凭证",
  );

  // 同 Provider 重名就地拒绝, 不发起命令.
  const before = app.calls.filter(call => call.command === "rename_credential_account").length;
  await app.node("cfg-rename-k1").click();
  app.node("cfg-rename-input-k1").value = "账号 2";
  await app.node("cfg-rename-save-k1").click();
  assert.equal(
    app.calls.filter(call => call.command === "rename_credential_account").length,
    before,
    "重名不得发起重命名",
  );
  assert.match(app.node("provider-dialog").textContent, /该名称已被同 Provider 的其他账号使用/);

  // 留空保存恢复默认名 (排除自身后取最小未占用序号).
  await app.node("cfg-rename-k1").click();
  app.node("cfg-rename-input-k1").value = "";
  await app.node("cfg-rename-save-k1").click();
  const restores = app.calls.filter(call => call.command === "rename_credential_account");
  assert.equal(restores.at(-1).args.displayName, "Kimi · 账号 1");
});

// ---------- C152: 设置窗口侧栏按窗口宽度锁定比例 ----------

test("settings sidebar locks a 17.6% window-width ratio instead of a fixed pixel width (C152)", async () => {
  const css = readFileSync(new URL("../src/styles.css", import.meta.url), "utf8");
  const start = css.indexOf(".sidenav {");
  const block = css.slice(start, css.indexOf("}", start) + 1);
  assert.ok(start >= 0, "缺少 .sidenav 规则");
  assert.match(block, /width:\s*17\.6%;/, "侧栏宽度应锁定窗口的 17.6%");
  assert.match(block, /min-width:\s*160px;/, "长标签可读性下限 160px");
  assert.doesNotMatch(block, /width:\s*216px;/, "不得回退到固定 216px");

  const conf = JSON.parse(readFileSync(new URL("../src-tauri/tauri.conf.json", import.meta.url), "utf8"));
  const settings = conf.app.windows.find((window) => window.label === "settings");
  assert.equal(settings.width, 1000, "设置窗口默认宽度应与 mac 对齐为 1000");
  assert.equal(settings.height, 680);
  assert.equal(settings.minWidth, 980);
  assert.equal(settings.resizable, true, "比例锁定不等于固定尺寸, 窗口仍可缩放");
});

// ---------- C153: 通用页配置项分组顺序 ----------

test("general pane rows keep the appearance → layout → refresh → notification order (C153 / C159)", async () => {
  const source = readFileSync(new URL("../src/settings-maintenance.js", import.meta.url), "utf8");
  const order = ["界面风格", "界面动效", "看板布局", "刷新间隔", "额度预警气泡"];
  const positions = order.map((label) => source.indexOf(`row(c1, "${label}"`));
  positions.forEach((position, index) => {
    assert.ok(position >= 0, `通用页缺少「${order[index]}」行`);
  });
  assert.deepEqual(
    [...positions].sort((a, b) => a - b),
    positions,
    `通用页行序应保持 ${order.join(" → ")}`,
  );
});

// ---------- C157: 订阅卡空状态与 Tab 回退 ----------

const emptySubscriptionPanel = () => ({ ...structuredClone(fixture), subscription: null });

test("stack mode renders the not-configured subscription empty card (C157)", async () => {
  const app = await boot({
    panel: emptySubscriptionPanel(),
    settings: { ...defaults, subscriptionProviders: {} },
  });
  const card = app.node("stack").querySelector(".sub-empty-card");
  assert.ok(card, "栈模式必须渲染订阅空态卡");
  assert.ok(card.textContent.includes("订阅用量"));
  assert.ok(card.textContent.includes("尚未添加订阅"));
  assert.ok(card.textContent.includes("未配置"));
  const start = app.calls.length;
  await card.querySelector(".sub-empty-btn").click();
  assert.deepEqual(
    app.calls.slice(start).map((call) => call.command),
    ["open_settings"],
    "添加订阅必须打开设置",
  );
});

test("eligible provider without sections renders the no-data empty card (C157)", async () => {
  const app = await boot({
    panel: emptySubscriptionPanel(),
    settings: {
      ...defaults,
      subscriptionProviders: {
        kimi: { enabled: true, verificationStatus: "ok", lastVerifiedAt: null },
      },
    },
  });
  const card = app.node("stack").querySelector(".sub-empty-card");
  assert.ok(card, "有 eligible provider 时仍渲染空态卡");
  assert.ok(card.textContent.includes("暂未获取到额度"));
  assert.ok(card.textContent.includes("无数据"));
  const start = app.calls.length;
  await card.querySelector(".sub-empty-btn").click();
  assert.deepEqual(
    app.calls.slice(start).map((call) => call.command),
    ["refresh_now"],
    "无数据空态必须触发刷新",
  );
});

test("tabbed subscription tab shows the empty card instead of falling back to usage (C157)", async () => {
  const app = await boot({
    panel: emptySubscriptionPanel(),
    settings: {
      ...defaults,
      subscriptionProviders: {},
      layoutMode: "tabbed",
      activeCardId: "subscription",
    },
  });
  const stack = app.node("stack");
  const card = stack.querySelector(".sub-empty-card");
  assert.ok(card, "订阅页签必须显示空态卡");
  assert.equal(card.dataset.card, "subscription");
  assert.ok(!stack.textContent.includes("Token 用量"), "不得回退显示 Token 用量卡");
});

test("only enabled, verified, non-jev providers count as eligible for the no-data state (C157)", async () => {
  const cases = [
    [{ jev: { enabled: true, verificationStatus: "ok" } }, "尚未添加订阅", "临时屏蔽的 jev 不算 eligible"],
    [{ kimi: { enabled: true, verificationStatus: "none" } }, "尚未添加订阅", "仅添加未验证归入未配置"],
    [{ kimi: { enabled: true, verificationStatus: "failed" } }, "尚未添加订阅", "验证失败归入未配置"],
    [{ kimi: { enabled: false, verificationStatus: "ok" } }, "尚未添加订阅", "已停用归入未配置"],
    [{ jev: { enabled: true, verificationStatus: "ok" }, zhipu: { enabled: true, verificationStatus: "ok" } }, "暂未获取到额度", "jev 之外仍有 eligible 即为无数据"],
  ];
  for (const [subscriptionProviders, expected, message] of cases) {
    const app = await boot({ panel: emptySubscriptionPanel(), settings: { ...defaults, subscriptionProviders } });
    const card = app.node("stack").querySelector(".sub-empty-card");
    assert.ok(card, message);
    assert.ok(card.textContent.includes(expected), message);
  }
});

test("add-subscription CTA deep-links the settings window to the subscription pane (C157)", async () => {
  const storage = memoryStorage();
  const dashboard = await boot({ panel: emptySubscriptionPanel(), settings: { ...defaults, subscriptionProviders: {} }, storage });
  await dashboard.node("stack").querySelector(".sub-empty-btn").click();
  await settle();
  assert.equal(storage.getItem("bruce_settings_pane"), "subscription", "面板先落 pending pane 再打开设置");

  // 设置窗口首次加载即消费 pending pane, 读完清空。
  const settings = await boot({ html: "settings.html", storage });
  await settle();
  const active = () => settings.document.querySelector(".navitem.active")?.dataset.category;
  assert.equal(active(), "subscription", "首次打开应直达订阅额度");
  assert.equal(settings.node("pane-subscription").classList.contains("hidden"), false);
  assert.equal(storage.getItem("bruce_settings_pane"), null, "深链只消费一次");

  // 常驻隐藏的设置窗口: 再次聚焦时消费新请求; 无请求的聚焦不改分类。
  await settings.document.querySelector('[data-category="general"]').click();
  await settings.window.dispatch("focus");
  assert.equal(active(), "general", "无 pending pane 的聚焦不得切分类");
  storage.setItem("bruce_settings_pane", "subscription");
  await settings.window.dispatch("focus");
  assert.equal(active(), "subscription", "聚焦时消费新的深链请求");
  storage.setItem("bruce_settings_pane", "not-a-pane");
  await settings.window.dispatch("focus");
  assert.equal(active(), "subscription", "未知分类直接忽略");
  assert.equal(storage.getItem("bruce_settings_pane"), null);
});

test("a failed open_settings withdraws the pending pane so the next normal open is not hijacked (C157)", async () => {
  const storage = memoryStorage();
  const app = await boot({
    panel: emptySubscriptionPanel(),
    settings: { ...defaults, subscriptionProviders: {} },
    reject: { open_settings: "window unavailable" },
    storage,
  });
  await app.node("stack").querySelector(".sub-empty-btn").click();
  await settle();
  assert.equal(storage.getItem("bruce_settings_pane"), null);
});

// ---------- C158: 渲染后补间的纯逻辑 ----------

test("motion helpers tokenize amounts, detect skeleton changes, and expose stable keys (C158)", async () => {
  const app = await boot();
  const motion = app.window.BruceMotion;
  assert.ok(motion, "motion.js 必须在 app.js 之前加载");
  const { tokenize, sameSkeleton, numericAmount, meterValues, balanceValues, percentValues } = motion.internals;

  const tokens = tokenize("¥ 1,234.56");
  assert.equal(tokens.filter((token) => token.digit).length, 6, "只把数字放进可滚动列");
  assert.equal(tokens[0].value, "¥", "货币符号保持静态");

  assert.equal(
    sameSkeleton(tokenize("128.45"), tokenize("126.08")),
    true,
    "同位数同分隔符应逐位滚动",
  );
  assert.equal(
    sameSkeleton(tokenize("999.99"), tokenize("1,000.12")),
    false,
    "位数/千分位变化应退化为整体换行",
  );
  assert.equal(numericAmount("¥ 1,234.56"), 1234.56, "方向解析忽略符号与千分位");

  const meters = meterValues(fixture);
  assert.ok(meters.size > 0, "旧面板必须能取出量条值");
  const balances = balanceValues(fixture);
  assert.ok([...balances.keys()].every((key) => key.endsWith("||bal") || key.endsWith("||chip")));
  const percents = percentValues(fixture);
  assert.ok(percents.size > 0, "旧面板必须能取出百分比文本");
  assert.ok([...percents.keys()].every((key) => key.endsWith("||pct")));

  assert.ok(
    app.node("stack").querySelector(".win-row[data-motion-key]"),
    "窗口行必须带稳定 motion key",
  );
  assert.ok(
    app.node("stack").querySelector("[data-percent-key]"),
    "百分比文本必须带稳定 percent key",
  );
});

test("segment plan holds the start color during the stagger delay and only lists changed segments (C158)", async () => {
  const app = await boot();
  const { segmentPlan } = app.window.BruceMotion.internals;

  const grow = segmentPlan(10, 40); // 2 → 10 段, 同为 normal
  assert.deepEqual(Array.from(grow, step => step.index), [2, 3, 4, 5, 6, 7, 8, 9]);
  assert.ok(grow.every(step => step.from === "empty" && step.to === "normal"));
  assert.deepEqual(Array.from(grow, step => step.delay), [0, 6, 12, 18, 24, 30, 36, 42], "自交界处向外 6ms 错峰");
  assert.ok(grow.every(step => step.fill === "backwards"), "delay 期间必须保持起点色, 不得先闪终值");
  assert.ok(grow.every(step => step.duration === 140), "单段 0.14s (design/05 规则 34)");

  const levelUp = segmentPlan(40, 60); // 10 → 14 段, normal → warning
  assert.equal(levelUp.length, 14, "已亮段换档位色 + 新亮段");
  assert.ok(levelUp.filter(step => step.index < 10).every(step => step.from === "normal" && step.to === "warning"));
  assert.ok(levelUp.filter(step => step.index >= 10).every(step => step.from === "empty" && step.to === "warning"));
  assert.ok(levelUp.every(step => step.fill === "backwards"));

  const shrink = segmentPlan(60, 40);
  assert.ok(shrink.filter(step => step.index >= 10).every(step => step.to === "empty"));
  assert.equal(segmentPlan(41, 41).length, 0, "同值不空转");
});

test("renderer stamps exactly the motion keys the tween layer computes (C158)", async () => {
  const app = await boot();
  const { keys, internals } = app.window.BruceMotion;
  const stack = app.node("stack");
  const meters = internals.meterValues(fixture);
  const percents = internals.percentValues(fixture);
  const balances = internals.balanceValues(fixture);
  const stamped = attribute => [...stack.querySelectorAll(`[${attribute}]`)].map(node => node.getAttribute(attribute));

  assert.ok(stamped("data-motion-key").length > 0);
  for (const key of stamped("data-motion-key")) assert.ok(meters.has(key), `渲染器 key 补间层未知: ${key}`);
  for (const key of stamped("data-percent-key")) assert.ok(percents.has(key), `百分比 key 补间层未知: ${key}`);
  for (const key of stamped("data-balance-key")) assert.ok(balances.has(key), `余额 key 补间层未知: ${key}`);

  // 收起行 / 迷你条的保留 key 不会与任何窗口 label 撞键。
  assert.notEqual(keys.mini("kimi"), keys.meter("kimi", "", "mini"));
  assert.notEqual(keys.collapsed("kimi"), keys.meter("kimi", "", "collapsed"));
});

// ---------- C159: 订阅额度预警气泡微卡 ----------

test("quota-alert.html defines 280pt capsule micro-card with R3-A countdown and auto-dismiss (C159)", async () => {
  const html = readFileSync(new URL("../src/quota-alert.html", import.meta.url), "utf8");
  assert.ok(html.includes("width: 280px"), "气泡微卡宽度固定 280px");
  assert.ok(html.includes("badge-icon"), "包含品牌瓷砖徽章容器");
  assert.ok(html.includes("progress-track"), "包含 4pt 进度条容器");
  assert.ok(html.includes("countdown-timer"), "包含 R3-A 电子表倒计时容器");
  assert.ok(html.includes("window-chip"), "包含窗口卡片感微标签");
  assert.ok(html.includes("6000"), "包含 6 秒自动平滑淡出定时器");
  assert.ok(html.includes("show_dashboard_from_alert"), "点击卡片主体唤出主看板并收起气泡");
  assert.ok(html.includes("hide_quota_alert_window"), "点击关闭微按钮收起气泡");
  assert.ok(html.includes("theme-nothing"), "适配 Nothing 极客点阵主题");
  assert.ok(html.includes("progress-track segmented"), "包含 Nothing 风格 14 段方块分段量条结构");
});
