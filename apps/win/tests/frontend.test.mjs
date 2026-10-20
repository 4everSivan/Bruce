import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { boot, defaults, fixture } from "./dom.mjs";

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
  app.node("setting-theme").value = "nothing";
  app.node("setting-hotkey").value = "Control+Shift+J";
  await app.node("settings-save").click();
  assert.equal(app.state.settings.theme, "nothing");
  assert.equal(app.state.settings.hotkey, "Control+Shift+J");
  assert.equal(app.document.body.classList.contains("theme-nothing"), true);
  await app.document.querySelector('[data-category="subscription"]').click();
  assert.equal(app.node("pane-subscription").classList.contains("hidden"), false);
});

test("settings pane-agentUsage renders T07 analytics workbench with 4 KPI tiles, time range picker, smooth timeline chart, canonical models and agent matrix", async () => {
  const app = await boot({ html: "settings.html" });
  await app.document.querySelector('[data-category="agentUsage"]').click();
  const pane = app.node("pane-agentUsage");
  assert.equal(pane.classList.contains("hidden"), false);

  // 1. 4 大核心 KPI 磁贴
  const kpiGrid = pane.querySelector("#kpi-tiles");
  assert.ok(kpiGrid, "必须包含 #kpi-tiles 容器");
  assert.equal(kpiGrid.querySelectorAll(".kpi-tile").length, 4, "必须渲染 4 个 KPI 磁贴");
  assert.match(kpiGrid.textContent, /总 Token 消耗/);
  assert.match(kpiGrid.textContent, /折算费用/);
  assert.match(kpiGrid.textContent, /Cache 命中率/);
  assert.match(kpiGrid.textContent, /活跃 Agent/);
  assert.match(kpiGrid.textContent, /184K/);

  // 2. 5 档时间选择器切换
  const timeBtns = pane.querySelectorAll(".time-range-btn");
  assert.equal(timeBtns.length, 5, "包含 5 档时间切片按钮");
  const sevenDayBtn = [...timeBtns].find((b) => b.textContent === "近 7 天");
  assert.ok(sevenDayBtn);
  await sevenDayBtn.click();
  assert.equal(pane.querySelector(".time-range-btn.active").textContent, "近 7 天");

  // 3. 时序趋势分析卡片与平滑图表
  const chartCard = pane.querySelector(".workbench-chart-card");
  assert.ok(chartCard, "包含时序走势卡片");
  assert.ok(chartCard.querySelector("svg"), "渲染 SVG 图表");
  assert.equal(chartCard.querySelectorAll(".dim-tab-btn").length, 4, "包含 4 档维度切换");

  // 4. 规范模型智能归一化大盘
  const canCard = pane.querySelector(".canonical-card");
  assert.ok(canCard, "包含规范模型卡片");
  assert.match(canCard.textContent, /Kimi K2.5/);
  assert.match(canCard.textContent, /GPT-5.4/);
  assert.ok(canCard.querySelectorAll(".canonical-row").length >= 2);

  // 5. 多 Agent 矩阵对比
  const matrixCard = pane.querySelector(".agent-matrix-card");
  assert.ok(matrixCard, "包含 Agent 矩阵对比卡片");
  assert.match(matrixCard.textContent, /Kimi Code/);
  assert.match(matrixCard.textContent, /Codex CLI/);

  // 6. Token 构成分析
  const compCard = pane.querySelector(".composition-card");
  assert.ok(compCard, "包含 Token 构成卡片");
  assert.equal(compCard.querySelectorAll(".composition-box").length, 4);

  // 7. 会话来源与授权下沉保留
  assert.ok(pane.textContent.includes("Rust Collector"));
  assert.ok(pane.textContent.includes("Claude Code"));
  assert.ok(pane.textContent.includes("未发现会话记录"));
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

test("refresh failure retains cached cards and exposes stale/error diagnostics", async () => {
  const app = await boot();
  const panel = { ...fixture, runtime: { phase: "failed", lastSuccessAt: "2026-10-08T00:00:00Z", error: "服务暂不可用" },
    diagnostics: [{ kind: "serviceIssue", serviceId: "codex", status: "error", note: "请重新授权" }] };
  await app.emit("dashboard-updated", panel);
  assert.match(app.node("runtime-status").textContent, /失败|过期/);
  assert.match(app.node("dashboard-status").textContent, /服务暂不可用/);
  assert.match(app.node("dashboard-diagnostics").textContent, /请重新授权/);
  assert.ok(app.node("stack").children.length >= 2);
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
  assert.match(css, /\.theme-nothing \.hero-num\s*\{[^}]*radial-gradient/, "Nothing 点阵覆写必须保留");
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
  assert.equal(firstRow().querySelector(".row-chev").textContent, "\u2304");
  await firstRow().querySelector(".line1").click();
  const row = firstRow();
  assert.equal(row.querySelector(".line1").getAttribute("aria-expanded"), "true");
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
  // 24 点走势为 SVG 平滑贝塞尔曲线 (非点柱)
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
  assert.ok(collapsed.querySelector(".mini-spark svg path.spark-curve"), "收起态迷你贝塞尔曲线");
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

test("styles.css defines the P2 shapes and keeps theme overrides for them", () => {
  const css = readFileSync(new URL("../src/styles.css", import.meta.url), "utf8");
  for (const rule of [".daily-chart .day-total", ".share-bar", ".legend-row", ".mini-spark", ".live-text", ".drag-handle", ".card.usage-card"]) {
    assert.ok(css.includes(rule), `styles.css 缺少 ${rule}`);
  }
  // 拖拽手柄仅折叠态可见; Nothing 走势色为 heroGreen; 趋势/纹样不得用内联色
  assert.match(css, /\.card\.collapsed > \.card-head \.drag-handle\s*\{\s*display:\s*inline-flex/);
  assert.match(css, /\.theme-nothing \.spark\s*\{\s*color:\s*#4A9E5C/);
  assert.match(css, /\.theme-nothing \.card\.usage-card\s*\{[^}]*radial-gradient/);
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
  // 折叠态 status 槽被 mini 摘要取代: 「最后更新」与 LIVE 必须随折叠隐藏
  assert.match(css, /\.card\.collapsed > \.card-head \.updated/);
  assert.match(css, /\.card\.collapsed > \.card-head \.hud-dot-wrap/);
  for (const rule of [".sub-extra", ".sub-name-toggle", ".account-card", ".account-head", ".last-success", ".tag-chip", ".bal-slots", ".slot-value"]) {
    assert.ok(css.includes(rule), `styles.css 缺少 ${rule}`);
  }
});

test("styles.css defines T07 workbench and Fluent 2 toggle controls", () => {
  const css = readFileSync(new URL("../src/styles.css", import.meta.url), "utf8");
  for (const rule of [
    ".time-range-picker",
    ".kpi-tiles-grid",
    ".kpi-tile",
    ".workbench-chart-card",
    ".canonical-card",
    ".agent-matrix-card",
    ".composition-card",
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
  // 全局保存覆盖其余设置项, 且不吞掉既有价格校准 (校准来源改为 settings.pricingOverrides)
  app.node("setting-usage").checked = false;
  await app.node("settings-save").click();
  assert.equal(app.state.settings.usageEnabled, false);
  assert.equal(app.state.settings.pricingOverrides["custom-model"].inputPricePerMillion, 3, "既有校准不被全局保存吞掉");
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
  toggles.find((node) => node.dataset.provider === "codex").checked = false;
  await app.node("settings-save").click();
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
  // 非法单价覆盖 (来自配置文件的越界值) 必须在保存时被拦下
  const app = await boot({ html: "settings.html", settings: { ...defaults, pricingOverrides: { broken: { inputPricePerMillion: -1 } } } });
  await app.node("settings-save").click();
  assert.equal(app.calls.some(call => call.command === "save_settings_command"), false, "非法覆盖不得写回");
  // 命令失败要在界面可见
  const failing = await boot({ html: "settings.html", reject: { save_settings_command: "热键冲突" } });
  await failing.node("settings-save").click();
  assert.match(failing.node("settings-status").textContent, /热键冲突/);
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

