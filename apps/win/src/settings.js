// Bruce 设置窗口 (mac SettingsWindowController 对应物):
// 通用设置 + 订阅凭证 Onboarding 引导; 保存后立即触发采集。
const { invoke } = window.__TAURI__.core;

/* ---------- 通用设置 ---------- */
async function loadSettings() {
  const settings = await invoke("get_settings");
  document.getElementById("setting-interval").value = Math.round(settings.refreshIntervalSecs / 60);
  document.getElementById("setting-notifications").checked = settings.notificationsEnabled;
  document.getElementById("setting-hotkey").value = settings.hotkey;
}

document.getElementById("settings-save").addEventListener("click", async () => {
  const status = document.getElementById("settings-status");
  try {
    const settings = await invoke("get_settings");
    settings.refreshIntervalSecs =
      Math.max(1, Number(document.getElementById("setting-interval").value) || 30) * 60;
    settings.notificationsEnabled = document.getElementById("setting-notifications").checked;
    settings.hotkey = document.getElementById("setting-hotkey").value.trim();
    await invoke("save_settings_command", { settings });
    status.textContent = "已保存";
  } catch (error) {
    status.textContent = `失败: ${error}`;
  }
});

/* ---------- 订阅凭证 (Onboarding 引导) ---------- */
const CREDENTIAL_FIELD_LABELS = {
  kimiQuotaAccounts: "Kimi For Coding",
  deepseekQuotaAccounts: "DeepSeek",
  volcengineQuotaAccounts: "火山引擎",
  zhipuQuotaAccounts: "智谱",
  claudeOAuth: "Claude OAuth",
  claudeQuotaAccounts: "Claude 配额账号",
  grokOAuth: "Grok OAuth",
  grokQuotaAccounts: "Grok 配额账号",
  opencodeGoQuotaAccounts: "OpenCode GO",
  codexQuotaAccounts: "Codex 配额账号",
  stepfunQuotaAccounts: "StepFun",
  providerEnv: "Provider 环境注入",
  providerMeta: "Provider 元信息",
};

async function loadCredentials() {
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
    label.textContent = `${CREDENTIAL_FIELD_LABELS[field] ?? field}${configuredNow ? " (已配置, 留空保留)" : ""}`;
    const textarea = document.createElement("textarea");
    textarea.dataset.field = field;
    textarea.rows = 2;
    textarea.placeholder = field.endsWith("Accounts")
      ? '[{"accountID": "...", "apiKey": "..."}]'
      : "{...}";
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
    await loadCredentials();
  } catch (error) {
    status.textContent = `失败: ${error}`;
  }
});

/* ---------- 启动 ---------- */
(async function init() {
  await Promise.all([loadSettings(), loadCredentials()]);
})();
