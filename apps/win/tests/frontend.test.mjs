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

test("distribution lists keep the 其他 aggregate row instead of truncating to three", async () => {
  const panel = structuredClone(fixture);
  panel.hourly.rows[0].models = [
    { name: "m1", share: 0.5, total: 62000, totalText: "62K" },
    { name: "m2", share: 0.3, total: 37200, totalText: "37.2K" },
    { name: "m3", share: 0.1, total: 12400, totalText: "12.4K" },
    { name: "其他", share: 0.1, total: 12400, totalText: "12.4K" },
  ];
  const app = await boot({ panel });
  const firstAgent = app.node("stack").querySelectorAll(".agent-row")[0];
  // 模型 4 行 (Top3 + 其他) + fixture 项目 2 行
  assert.equal(firstAgent.querySelectorAll(".dist-row").length, 6);
  assert.match(firstAgent.textContent, /其他/);
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
  const app = await boot({ html: "settings.html" });
  assert.match(app.node("model-prices").textContent, /fixture-model/);
  assert.match(app.node("runtime-info").textContent, /isolated-data/);
  assert.match(app.node("runtime-info").textContent, /stale/);
  assert.match(app.node("runtime-info").textContent, /PROVIDER_RATE_LIMIT/);
  assert.doesNotMatch(app.node("runtime-info").textContent, /\[object Object\]/);
  app.node("setting-consent").checked = true;
  app.node("setting-usage").checked = false;
  app.node("setting-pricing-overrides").value = '{"custom-model":{"inputPricePerMillion":3,"outputPricePerMillion":4}}';
  await app.node("settings-save").click();
  assert.equal(app.state.settings.consentVersion, 1);
  assert.equal(app.state.settings.usageEnabled, false);
  assert.equal(app.state.settings.pricingOverrides["custom-model"].inputPricePerMillion, 3);
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
  const app = await boot({ html: "settings.html", reject: { save_settings_command: "热键冲突" } });
  app.node("setting-pricing-overrides").value = '{"broken":{"inputPricePerMillion":-1}}';
  await app.node("settings-save").click();
  assert.equal(app.calls.some(x => x.command === "save_settings_command"), false);
  app.node("setting-pricing-overrides").value = "{}";
  await app.node("settings-save").click();
  assert.match(app.node("settings-status").textContent, /热键冲突/);
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

test("styles.css guarantees adaptive height and pinned footer without flex truncation", () => {
  const css = readFileSync(new URL("../src/styles.css", import.meta.url), "utf8");
  assert.match(css, /#panel\s*\{[^}]*height:\s*100%;/);
  assert.match(css, /#panel\s*\{[^}]*max-height:\s*100%;/);
  assert.match(css, /#scroll\s*\{[^}]*min-height:\s*0;/);
  assert.match(css, /#scroll\s*\{[^}]*flex:\s*1 1 0;/);
  assert.match(css, /#footer\s*\{[^}]*flex:\s*0 0 auto;/);
});

