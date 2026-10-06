// Bruce Windows 看板: 三视图 (看板/凭证引导/设置) + 调度事件驱动刷新。
// 数据契约见 apps/win/viewmodel/src/models.rs (camelCase JSON)。
const { invoke } = window.__TAURI__.core;
const { listen } = window.__TAURI__.event;

// MARK: - 看板渲染

function render(panel) {
  const usage = panel.usage;
  const hero = document.getElementById("hero");
  const live = document.getElementById("live");

  if (!usage) {
    hero.classList.add("hidden");
    renderDiagnostics(panel.diagnostics);
    return;
  }

  hero.classList.remove("hidden");
  live.classList.toggle("hidden", !usage.isLive);
  document.getElementById("hero-total").textContent = usage.totalTokensText;
  document.getElementById("hero-cost").textContent = usage.costText ?? "";

  const breakdown = document.getElementById("breakdown");
  breakdown.innerHTML = "";
  for (const item of usage.breakdown) {
    const cell = document.createElement("div");
    cell.className = "cell";
    const label = document.createElement("span");
    label.className = "label";
    label.textContent = item.label;
    const value = document.createElement("span");
    value.textContent = item.valueText;
    cell.append(label, value);
    breakdown.append(cell);
  }

  renderHourly(panel.hourly);
  renderDiagnostics(panel.diagnostics);
}

function renderHourly(hourly) {
  const host = document.getElementById("hourly");
  const rows = document.getElementById("hourly-rows");
  rows.innerHTML = "";
  if (!hourly || !hourly.rows.length) {
    host.classList.add("hidden");
    return;
  }
  host.classList.remove("hidden");
  for (const row of hourly.rows) {
    const item = document.createElement("div");
    item.className = "hourly-row";

    const line = document.createElement("div");
    line.className = "name-line";
    const name = document.createElement("span");
    const dot = document.createElement("span");
    dot.className = "dot";
    dot.style.background = row.colorHex;
    name.append(dot, document.createTextNode(row.name));
    const total = document.createElement("span");
    total.textContent = row.todayTotalText;
    line.append(name, total);
    item.append(line);

    for (const bar of [...row.models, ...row.projects].slice(0, 3)) {
      const track = document.createElement("div");
      track.className = "bar";
      const fill = document.createElement("div");
      fill.style.width = `${Math.round(bar.share * 100)}%`;
      fill.style.background = "var(--accent)";
      track.append(fill);
      item.append(track);
    }
    rows.append(item);
  }
}

function renderDiagnostics(diagnostics) {
  const card = document.getElementById("diagnostics");
  const list = document.getElementById("diagnostic-list");
  list.innerHTML = "";
  if (!diagnostics.length) {
    card.classList.add("hidden");
    return;
  }
  card.classList.remove("hidden");
  for (const diagnostic of diagnostics) {
    const li = document.createElement("li");
    li.textContent =
      diagnostic.kind === "agentIssue"
        ? `${diagnostic.agentId}: ${diagnostic.status} ${diagnostic.note}`
        : diagnostic.kind;
    list.append(li);
  }
}

// MARK: - 视图切换

function switchView(name) {
  for (const view of ["dashboard", "credentials", "settings"]) {
    document.getElementById(`view-${view}`).classList.toggle("hidden", view !== name);
  }
  for (const tab of document.querySelectorAll(".tab")) {
    tab.classList.toggle("active", tab.dataset.view === name);
  }
  if (name === "credentials") loadCredentialsView();
  if (name === "settings") loadSettingsView();
}

for (const tab of document.querySelectorAll(".tab")) {
  tab.addEventListener("click", () => switchView(tab.dataset.view));
}

// MARK: - 凭证视图 (Onboarding 引导)

const CREDENTIAL_FIELD_LABELS = {
  kimiQuotaAccounts: "Kimi For Coding (账号数组 JSON)",
  deepseekQuotaAccounts: "DeepSeek (账号数组 JSON)",
  volcengineQuotaAccounts: "火山引擎 (账号数组 JSON)",
  zhipuQuotaAccounts: "智谱 (账号数组 JSON)",
  claudeOAuth: "Claude OAuth (JSON)",
  claudeQuotaAccounts: "Claude 配额账号 (JSON)",
  grokOAuth: "Grok OAuth (JSON)",
  grokQuotaAccounts: "Grok 配额账号 (JSON)",
  opencodeGoQuotaAccounts: "OpenCode Go (账号数组 JSON)",
  codexQuotaAccounts: "Codex 配额账号 (JSON)",
  stepfunQuotaAccounts: "StepFun (账号数组 JSON)",
  providerEnv: "Provider 环境注入 (JSON)",
  providerMeta: "Provider 元信息 (JSON)",
};

async function loadCredentialsView() {
  const [allowlist, configured] = await Promise.all([
    invoke("credential_allowlist"),
    invoke("get_credential_fields"),
  ]);
  const host = document.getElementById("credential-fields");
  host.innerHTML = "";
  for (const field of allowlist) {
    const configuredNow = configured.includes(field);
    const block = document.createElement("div");
    block.className = "credential-field";
    const label = document.createElement("label");
    label.textContent = `${CREDENTIAL_FIELD_LABELS[field] ?? field}${configuredNow ? " (已配置)" : ""}`;
    const textarea = document.createElement("textarea");
    textarea.dataset.field = field;
    textarea.rows = 3;
    textarea.placeholder = field.endsWith("Accounts") ? '[{"accountID": "...", "apiKey": "..."}]' : "{...}";
    if (configuredNow) {
      // 不回显明文凭证, 只标记已配置; 留空 = 保留原值。
      textarea.placeholder = "已配置 (留空保留; 填入新值覆盖)";
    }
    block.append(label, textarea);
    host.append(block);
  }
}

document.getElementById("credentials-save").addEventListener("click", async () => {
  const status = document.getElementById("credentials-status");
  try {
    // 合并语义 (后端): 请求带值的键覆盖, 显式 null 删除, 未提及保留原值。
    const payloads = {};
    for (const textarea of document.querySelectorAll("#credential-fields textarea")) {
      const field = textarea.dataset.field;
      const raw = textarea.value.trim();
      if (!raw) continue;
      payloads[field] = raw === "null" ? null : JSON.parse(raw);
    }
    await invoke("save_credentials_command", { payloads });
    status.textContent = "已保存并触发刷新";
    await loadCredentialsView();
  } catch (error) {
    status.textContent = `失败: ${error}`;
  }
});

// MARK: - 设置视图

async function loadSettingsView() {
  const settings = await invoke("get_settings");
  document.getElementById("setting-interval").value = Math.round(settings.refreshIntervalSecs / 60);
  document.getElementById("setting-notifications").checked = settings.notificationsEnabled;
  document.getElementById("setting-theme").value = settings.theme;
  document.getElementById("setting-hotkey").value = settings.hotkey;
}

document.getElementById("settings-save").addEventListener("click", async () => {
  const status = document.getElementById("settings-status");
  try {
    const settings = await invoke("get_settings");
    settings.refreshIntervalSecs =
      Math.max(1, Number(document.getElementById("setting-interval").value) || 30) * 60;
    settings.notificationsEnabled = document.getElementById("setting-notifications").checked;
    settings.theme = document.getElementById("setting-theme").value;
    settings.hotkey = document.getElementById("setting-hotkey").value.trim();
    await invoke("save_settings_command", { settings });
    applyTheme(settings.theme);
    status.textContent = "已保存";
  } catch (error) {
    status.textContent = `失败: ${error}`;
  }
});

function applyTheme(theme) {
  document.body.className = theme === "nothing" ? "theme-nothing" : "theme-fluent";
}

// MARK: - 刷新

async function refresh() {
  const button = document.getElementById("refresh");
  button.disabled = true;
  button.textContent = "采集中…";
  try {
    render(await invoke("get_dashboard"));
  } catch (error) {
    console.error("get_dashboard 失败", error);
  } finally {
    button.disabled = false;
    button.textContent = "刷新";
  }
}

document.getElementById("refresh").addEventListener("click", async () => {
  await refresh();
  await invoke("refresh_now");
});

// MARK: - 启动

(async function init() {
  const settings = await invoke("get_settings");
  applyTheme(settings.theme);
  await refresh();
  // 后台调度器广播: 采集完成后自动更新看板。
  await listen("dashboard-updated", (event) => render(event.payload));
})();
