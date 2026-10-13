import test from "node:test";
import assert from "node:assert/strict";
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

test("account-level subscription status, additional text and all accounts are visible", async () => {
  const panel = { ...fixture, subscription: { sections: [{ id: "codex", name: "ChatGPT", status: "partial", note: "部分账号异常",
    extraText: "额外信息", windows: [], accounts: [{ id: "a", name: "工作账号", status: "stale", lastSuccessText: "上次成功 12:00", windows: [], note: "授权已过期" },
      { id: "b", name: "个人账号", status: "ok", windows: [] }] }] } };
  const app = await boot({ panel });
  assert.match(app.node("stack").textContent, /工作账号/);
  assert.match(app.node("stack").textContent, /个人账号/);
  assert.match(app.node("stack").textContent, /上次成功 12:00/);
  assert.match(app.node("stack").textContent, /额外信息/);
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

test("DeepSeek monthly ledger shows baseline, consumption, credits and trend points", async () => {
  const monthly = { state: "trend", estimatedConsumptionText: "¥ 0.20", currentBalanceText: "¥ 110.10", coverageText: "自 26/10/01 起累计推算", creditNote: "入账未计入消费", trendPoints: [{ observedAt: "2026-10-01T00:00:00Z", cumulativeConsumption: 0 }, { observedAt: "2026-10-02T00:00:00Z", cumulativeConsumption: 0.2 }] };
  const panel = { ...fixture, subscription: { sections: [{ id: "deepseek", name: "DeepSeek", windows: [], accounts: [], deepSeekMonthlyUsage: monthly }] } };
  const app = await boot({ panel });
  assert.match(app.node("stack").textContent, /¥ 0.20/);
  assert.match(app.node("stack").textContent, /26\/10\/01/);
  assert.match(app.node("stack").textContent, /入账未计入消费/);
  assert.ok(app.node("stack").querySelector(".ledger-trend"));
});

test("dashboard dismisses via Escape key calling hide_dashboard", async () => {
  const app = await boot();
  const start = app.calls.length;
  await app.window.dispatch("keydown", { key: "Escape" });
  assert.deepEqual(app.calls.slice(start).map(x => x.command), ["hide_dashboard"]);
});
