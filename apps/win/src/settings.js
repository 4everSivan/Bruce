// One settings controller serves the dashboard tabs and the independent window.
// Credential values are write-only: inventory contains labels/IDs, never secrets.
(() => {
  const { invoke } = window.__TAURI__.core;
  const providers = [
    ["kimi", "Kimi For Coding", "kimiQuotaAccounts"], ["deepseek", "DeepSeek", "deepseekQuotaAccounts"],
    ["volcengine", "火山引擎", "volcengineQuotaAccounts"], ["zhipu", "智谱", "zhipuQuotaAccounts"],
    ["codex", "ChatGPT / Codex", "codexQuotaAccounts"], ["claude", "Claude", "claudeQuotaAccounts"],
    ["grok", "Grok", "grokQuotaAccounts"], ["opencodeGo", "OpenCode GO", "opencodeGoQuotaAccounts"],
    ["stepfun", "StepFun", "stepfunQuotaAccounts"],
  ];
  const node = (tag, text, attrs = {}) => {
    const value = document.createElement(tag);
    if (text != null) value.textContent = text;
    for (const [key, data] of Object.entries(attrs)) value.setAttribute(key, data);
    return value;
  };
  const byId = id => document.getElementById(id);
  let settings = {}, allowlist = [], providerOrder = [], cardOrder = [];
  const applyTheme = theme => {
    document.body.classList.toggle("theme-nothing", theme === "nothing");
    document.body.classList.toggle("theme-fluent", theme !== "nothing");
  };
  function message(host, text) { host.textContent = text; }
  function input(id, type = "text", attrs = {}) { return node("input", null, { id, type, ...attrs }); }
  function row(parent, title, control) {
    const label = node("label", null, { class: "row" });
    label.append(node("span", title), control); parent.append(label); return control;
  }
  function section(parent, title) {
    const block = node("section", null, { class: "settings-card" });
    block.append(node("h2", title)); parent.append(block); return block;
  }
  function button(parent, id, title, callback) {
    const value = node("button", title, { id, type: "button" });
    value.addEventListener("click", callback); parent.append(value); return value;
  }
  function actions(parent) { const value = node("div", null, { class: "actions" }); parent.append(value); return value; }
  function objectJSON(raw, label) {
    let value;
    try { value = JSON.parse(raw); } catch { throw new Error(`${label} 不是有效 JSON`); }
    if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error(`${label} 必须是对象`);
    return value;
  }
  function validateOverrides(value) {
    const priceKeys = ["inputPricePerMillion", "outputPricePerMillion", "cacheReadPricePerMillion"];
    for (const [model, pricing] of Object.entries(value)) {
      if (!model.trim() || !pricing || typeof pricing !== "object" || Array.isArray(pricing)) throw new Error("模型价格格式无效");
      for (const [key, rate] of Object.entries(pricing)) {
        if (priceKeys.includes(key)) {
          if (!Number.isFinite(rate) || rate < 0) throw new Error("模型价格必须是非负数字");
        } else if (!["currency", "note"].includes(key) || typeof rate !== "string") throw new Error("模型价格字段无效");
      }
    }
    return value;
  }
  function orderedAll(order, all) { return [...new Set([...order.filter(id => all.includes(id)), ...all])]; }
  function move(order, index, delta) {
    const other = index + delta;
    if (other < 0 || other >= order.length) return;
    [order[index], order[other]] = [order[other], order[index]];
  }
  function renderOrders() {
    const cards = byId("setting-card-order"); cards.replaceChildren();
    cardOrder.forEach((id, index) => {
      const line = node("div", null, { class: "order-row" });
      line.append(node("span", { usage: "Token 用量", subscription: "订阅额度", hourly: "Agent 用量" }[id]));
      button(line, `card-up-${id}`, "上移", () => { move(cardOrder, index, -1); renderOrders(); });
      button(line, `card-down-${id}`, "下移", () => { move(cardOrder, index, 1); renderOrders(); });
      cards.append(line);
    });
    const host = byId("setting-providers");
    // Preserve unsaved checkbox edits while the user reorders providers.
    const prior = new Map([...host.querySelectorAll("input")].map(value => [value.dataset.provider, value.checked]));
    host.replaceChildren();
    providerOrder.forEach((id, index) => {
      const descriptor = providers.find(value => value[0] === id);
      const line = node("div", null, { class: "order-row" });
      const check = input(`provider-${id}`, "checkbox", { "data-provider": id });
      check.checked = prior.has(id) ? prior.get(id) : (settings.enabledProviders || providers.map(value => value[0])).includes(id);
      const label = node("label"); label.append(check, node("span", descriptor[1])); line.append(label);
      button(line, `provider-up-${id}`, "上移", () => { move(providerOrder, index, -1); renderOrders(); });
      button(line, `provider-down-${id}`, "下移", () => { move(providerOrder, index, 1); renderOrders(); });
      host.append(line);
    });
  }
  function buildSettings(host) {
    host.replaceChildren();
    const general = section(host, "通用与外观");
    row(general, "刷新间隔（分钟）", input("setting-interval", "number", { min: "1", max: "1440" }));
    row(general, "配额预警通知", input("setting-notifications", "checkbox"));
    const theme = node("select", null, { id: "setting-theme" });
    theme.append(node("option", "Fluent", { value: "fluent" }), node("option", "Nothing 点阵", { value: "nothing" }));
    row(general, "主题", theme);
    row(general, "全局热键（留空关闭）", input("setting-hotkey", "text", { placeholder: "Control+Shift+B", autocomplete: "off" }));
    button(general, "hotkey-record", "录制热键", () => {
      byId("setting-hotkey").focus?.(); message(byId("settings-status"), "在热键输入框按下组合键；Esc 取消录制");
      byId("setting-hotkey").dataset.recording = "true";
    });
    byId("setting-hotkey").addEventListener("keydown", event => {
      if (byId("setting-hotkey").dataset.recording !== "true") return;
      event.preventDefault();
      if (event.key === "Escape") { byId("setting-hotkey").dataset.recording = "false"; return; }
      if (["Control", "Alt", "Shift", "Meta"].includes(event.key)) return;
      const parts = [event.ctrlKey && "Control", event.altKey && "Alt", event.shiftKey && "Shift", event.metaKey && "Super"].filter(Boolean);
      if (!parts.length) { message(byId("settings-status"), "请使用 Ctrl、Alt、Shift 或 Windows 键与其他键组合"); return; }
      parts.push(event.key.length === 1 ? event.key.toUpperCase() : event.key);
      byId("setting-hotkey").value = parts.join("+"); byId("setting-hotkey").dataset.recording = "false";
    });
    general.append(node("h3", "看板顺序"), node("div", null, { id: "setting-card-order" }));
    const usage = section(host, "Agent 用量");
    row(usage, "读取本机 Agent 会话用量", input("setting-usage", "checkbox"));
    usage.append(node("p", "开启后在本机读取会话记录，计算 Token 用量与费用。", { class: "hint" }));
    const pricing = section(host, "模型计费");
    pricing.append(node("p", "价格按每百万 Token 计算；自定义覆盖会用于下一次采集的费用估算。", { class: "hint" }));
    pricing.append(node("details", null, { id: "model-prices-details" }));
    byId("model-prices-details").append(node("summary", "查看内置模型价格"), node("div", null, { id: "model-prices" }));
    row(pricing, "模型名称", input("price-model", "text", { placeholder: "模型 ID" }));
    row(pricing, "输入价格", input("price-input", "number", { min: "0", step: "any" }));
    row(pricing, "输出价格", input("price-output", "number", { min: "0", step: "any" }));
    row(pricing, "缓存读取价格（可选）", input("price-cache", "number", { min: "0", step: "any" }));
    row(pricing, "币种", input("price-currency", "text", { value: "USD" }));
    button(pricing, "price-add", "添加或替换价格覆盖", () => {
      try {
        const model = byId("price-model").value.trim();
        if (!model || !byId("price-input").value || !byId("price-output").value) throw new Error("请填写模型名称和输入、输出价格");
        const overrides = objectJSON(byId("setting-pricing-overrides").value || "{}", "价格覆盖");
        const value = { inputPricePerMillion: Number(byId("price-input").value), outputPricePerMillion: Number(byId("price-output").value), currency: byId("price-currency").value.trim() || "USD" };
        if (byId("price-cache").value) value.cacheReadPricePerMillion = Number(byId("price-cache").value);
        overrides[model] = value; validateOverrides(overrides);
        byId("setting-pricing-overrides").value = JSON.stringify(overrides, null, 2);
        message(byId("settings-status"), "已加入编辑内容，请保存设置");
      } catch (error) { message(byId("settings-status"), error.message); }
    });
    const overrides = node("textarea", null, { id: "setting-pricing-overrides", rows: "5", spellcheck: "false", "aria-label": "自定义模型价格覆盖" });
    pricing.append(overrides);
    button(pricing, "price-reset", "清空价格覆盖", () => { overrides.value = "{}"; });
    const subscriptions = section(host, "订阅额度");
    subscriptions.append(node("p", "选择启用的服务并调整显示顺序；账号在订阅凭证中管理。", { class: "hint" }), node("div", null, { id: "setting-providers" }));
    const consent = section(host, "授权与隐私");
    row(consent, "允许向已启用的订阅服务查询额度", input("setting-consent", "checkbox"));
    consent.append(node("p", "查询会将对应账号的凭证发送给该订阅服务。用量计算与配置保存在本机；关闭授权后停止订阅查询。", { class: "hint" }));
    const maintenance = section(host, "维护");
    maintenance.append(node("pre", null, { id: "runtime-info" }));
    button(maintenance, "runtime-reload", "刷新运行状态", loadRuntimeInfo);
    const footer = actions(host);
    button(footer, "settings-save", "保存设置", saveSettings);
    footer.append(node("span", null, { id: "settings-status", role: "status" }));
  }
  async function loadRuntimeInfo() {
    try {
      const info = await invoke("get_runtime_info");
      const status = info.status && typeof info.status === "object" ? info.status : { phase: info.status || info.phase };
      byId("runtime-info").textContent = [
        `数据目录：${info.dataRoot || "未知"}`, `缓存目录：${info.cacheRoot || "未知"}`,
        `快照文件：${info.snapshotPath || "未知"}`, `状态：${status.phase || "未知"}`,
        `最近成功：${status.lastSuccessAt || "尚无"}`, `错误：${status.error || "无"}`,
        `诊断：${(status.diagnosticCodes || []).join("、") || "无"}`,
      ].join("\n");
    } catch { message(byId("runtime-info"), "无法读取运行状态"); }
  }
  async function loadPrices() {
    try {
      const prices = await invoke("get_model_prices");
      const host = byId("model-prices"); host.replaceChildren();
      const table = node("table");
      const header = node("tr");
      for (const text of ["模型", "输入", "输出", "缓存读取", "币种"]) header.append(node("th", text));
      table.append(header);
      for (const [model, price] of Object.entries(prices).sort(([a], [b]) => a.localeCompare(b))) {
        const line = node("tr");
        for (const text of [model, price.inputPricePerMillion, price.outputPricePerMillion, price.cacheReadPricePerMillion ?? "—", price.currency]) line.append(node("td", String(text)));
        table.append(line);
      }
      host.append(table);
    } catch { message(byId("model-prices"), "模型价格暂不可用"); }
  }
  async function loadSettings() {
    settings = await invoke("get_settings");
    byId("setting-interval").value = Math.round(settings.refreshIntervalSecs / 60);
    byId("setting-notifications").checked = settings.notificationsEnabled;
    byId("setting-hotkey").value = settings.hotkey || "";
    byId("setting-theme").value = settings.theme;
    byId("setting-consent").checked = settings.consentVersion === 1;
    byId("setting-usage").checked = settings.usageEnabled !== false;
    byId("setting-pricing-overrides").value = JSON.stringify(settings.pricingOverrides || {}, null, 2);
    cardOrder = orderedAll(settings.cardOrder || [], ["usage", "subscription", "hourly"]);
    providerOrder = orderedAll(settings.providerOrder || [], providers.map(value => value[0]));
    renderOrders(); applyTheme(settings.theme);
  }
  async function saveSettings() {
    const status = byId("settings-status"), save = byId("settings-save"); save.disabled = true;
    try {
      const interval = Number(byId("setting-interval").value);
      if (!Number.isInteger(interval) || interval < 1 || interval > 1440) throw new Error("刷新间隔须为 1–1440 的整数分钟");
      const overrides = validateOverrides(objectJSON(byId("setting-pricing-overrides").value || "{}", "价格覆盖"));
      const updated = { ...await invoke("get_settings"), refreshIntervalSecs: interval * 60,
        notificationsEnabled: byId("setting-notifications").checked, hotkey: byId("setting-hotkey").value.trim(),
        theme: byId("setting-theme").value, consentVersion: byId("setting-consent").checked ? 1 : 0,
        usageEnabled: byId("setting-usage").checked, cardOrder: [...cardOrder], providerOrder: [...providerOrder],
        enabledProviders: [...byId("setting-providers").querySelectorAll("input")].filter(value => value.checked).map(value => value.dataset.provider), pricingOverrides: overrides };
      await invoke("save_settings_command", { settings: updated });
      settings = updated; applyTheme(updated.theme);
      window.dispatchEvent(new CustomEvent("settings-saved", { detail: updated }));
      message(status, "已保存");
    } catch (error) { message(status, `保存失败：${error.message || error}`); }
    finally { save.disabled = false; }
  }
  function buildCredentials(host) {
    host.replaceChildren();
    const block = section(host, "订阅凭证与账号");
    block.append(node("p", "凭证保存在当前用户专属的本机目录。留空保留现有账号；保存不会展示已存储的密钥。", { class: "hint" }), node("div", null, { id: "credential-accounts" }));
    const provider = node("select", null, { id: "account-provider" });
    for (const [, name, field] of providers) provider.append(node("option", name, { value: field }));
    provider.value = providers[0][2];
    row(block, "服务", provider);
    row(block, "账号标识", input("account-id", "text", { placeholder: "例如 work 或 personal", autocomplete: "off" }));
    row(block, "显示名称", input("account-name", "text", { placeholder: "例如工作账号" }));
    row(block, "密钥 / Access Token", input("account-secret", "password", { autocomplete: "new-password" }));
    row(block, "附加密钥 / Refresh Token（按服务需要）", input("account-secondary", "password", { autocomplete: "new-password" }));
    row(block, "智谱 API 地址（可选）", input("account-base-url", "text", { placeholder: "https://open.bigmodel.cn/api/paas/v4" }));
    const site = node("select", null, { id: "account-site" });
    site.append(node("option", "国内", { value: "domestic" }), node("option", "国际", { value: "global" }));
    row(block, "StepFun 站点", site);
    const extra = node("details");
    extra.append(node("summary", "OAuth 或其他附加凭证"), node("textarea", null, { id: "account-extra", rows: "3", placeholder: "可粘贴完整 OAuth JSON", autocomplete: "off", spellcheck: "false", "aria-label": "OAuth 附加凭证" }));
    block.append(extra);
    provider.addEventListener("change", () => {
      byId("account-secret").value = ""; byId("account-secondary").value = ""; byId("account-extra").value = "";
    });
    const accountActions = actions(block);
    button(accountActions, "account-save", "保存此账号", saveAccount);
    button(accountActions, "credentials-validate", "检查已保存账号连接", validateConnections);
    accountActions.append(node("span", null, { id: "account-status", role: "status" }));
    block.append(node("div", null, { id: "connection-status", role: "status" }));
    const importer = section(host, "导入账号");
    importer.append(node("p", "选择本机 Codex auth.json 导入其账号；也可选择 Bruce 凭证 JSON。导入前校验格式，其他账号会保留。", { class: "hint" }));
    importer.append(input("credential-import-file", "file", { accept: ".json,application/json" }));
    button(importer, "credential-import", "导入所选文件", async () => {
      try {
        const file = byId("credential-import-file").files?.[0];
        if (!file) throw new Error("请选择 JSON 文件");
        const auth = objectJSON(await file.text(), "导入文件");
        if (auth.tokens) await invoke("import_codex_auth", { auth });
        else {
          const payloads = validatePayloads(auth);
          // Account import uses account-level merge to preserve existing accounts.
          for (const [field, value] of Object.entries(payloads)) {
            if (field.endsWith("Accounts") && value) {
              for (const [accountId, payload] of Object.entries(value)) await invoke("save_credential_account", { field, accountId, payload });
            } else await invoke("save_credentials_command", { payloads: { [field]: value } });
          }
        }
        byId("credential-import-file").value = "";
        message(byId("credentials-status"), "导入完成"); await loadCredentials();
      } catch (error) { message(byId("credentials-status"), `导入失败：${error.message || error}`); }
    });
    const advanced = node("details", null, { class: "settings-card" });
    advanced.append(node("summary", "高级：完整凭证字段"), node("p", "仅在需要替换整个字段时使用。账号字段必须是以账号标识为键的对象；留空保留，填写 null 删除该字段。", { class: "hint" }), node("div", null, { id: "credential-fields" }));
    const controls = actions(advanced);
    button(controls, "credentials-save", "保存完整字段", saveCredentials);
    host.append(advanced, node("span", null, { id: "credentials-status", role: "status" }));
  }
  function validatePayloads(payloads) {
    for (const [field, value] of Object.entries(payloads)) {
      if (!allowlist.includes(field)) throw new Error("包含不支持的凭证字段");
      if (value === null) continue;
      if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("凭证字段必须是对象或 null");
      if (field.endsWith("Accounts")) {
        for (const [id, payload] of Object.entries(value)) {
          if (!id.trim() || !payload || typeof payload !== "object" || Array.isArray(payload)) throw new Error("账号凭证格式无效");
        }
      }
    }
    return payloads;
  }
  function clearSecrets() {
    for (const id of ["account-secret", "account-secondary", "account-extra"]) byId(id).value = "";
  }
  async function saveAccount() {
    const save = byId("account-save"); save.disabled = true;
    try {
      const field = byId("account-provider").value, accountId = byId("account-id").value.trim();
      const secret = byId("account-secret").value.trim(), secondary = byId("account-secondary").value.trim();
      if (!accountId || accountId.length > 200 || /[\x00-\x1f]/.test(accountId)) throw new Error("请填写有效的账号标识");
      const extra = byId("account-extra").value.trim();
      let payload = extra ? objectJSON(extra, "附加凭证") : {};
      if (field === "volcengineQuotaAccounts") {
        if (!secret || !secondary) throw new Error("火山引擎需要 Access Key 与 Secret Key");
        payload = { ...payload, accessKeyId: secret, secretAccessKey: secondary };
      } else if (["claudeQuotaAccounts", "grokQuotaAccounts", "opencodeGoQuotaAccounts"].includes(field)) {
        if (!secret && !extra) throw new Error("请填写 Access Token 或 OAuth 凭证");
        payload = { oauth: { ...payload, ...(secret ? { access_token: secret } : {}), ...(secondary ? { refresh_token: secondary } : {}) } };
      } else if (field === "codexQuotaAccounts") {
        if (!secret) throw new Error("请填写 Access Token，或通过 auth.json 导入");
        payload = { ...payload, access_token: secret, ...(secondary ? { refresh_token: secondary } : {}) };
      } else if (field === "stepfunQuotaAccounts") {
        if (!secret) throw new Error("请填写 Token");
        const site = byId("account-site").value;
        payload = { ...payload, token: secret, site, is_global: site === "global" };
      } else {
        if (!secret) throw new Error("请填写 API Key");
        payload.api_key = secret;
        if (field === "zhipuQuotaAccounts") {
          const url = new URL(byId("account-base-url").value.trim() || "https://open.bigmodel.cn/api/paas/v4");
          if (url.protocol !== "https:") throw new Error("API 地址须使用 HTTPS");
          payload.base_url = url.href;
        }
      }
      payload.display_name = byId("account-name").value.trim() || accountId;
      await invoke("save_credential_account", { field, accountId, payload });
      clearSecrets(); message(byId("account-status"), "账号已保存"); await loadCredentials();
    } catch (error) { message(byId("account-status"), `保存失败：${error.message || error}`); }
    finally { save.disabled = false; }
  }
  async function loadCredentials() {
    const [fields, configured, accounts] = await Promise.all([
      invoke("credential_allowlist"), invoke("get_credential_fields"), invoke("get_credential_accounts"),
    ]);
    allowlist = fields;
    const host = byId("credential-fields"); host.replaceChildren();
    for (const field of fields) {
      const block = node("div", null, { class: "credential-field" });
      const title = providers.find(value => value[2] === field)?.[1] || field;
      const label = node("label", `${title}${configured.includes(field) ? "（已配置，留空保留）" : ""}`);
      const textarea = node("textarea", null, { rows: "2", "data-field": field, autocomplete: "off", spellcheck: "false", "aria-label": title });
      textarea.placeholder = field.endsWith("Accounts") ? '{"work":{"display_name":"工作","api_key":"…"}}' : "{…}";
      block.append(label, textarea); host.append(block);
    }
    const inventory = byId("credential-accounts"); inventory.replaceChildren();
    for (const account of accounts || []) {
      const line = node("div", null, { class: "order-row" });
      const label = providers.find(value => value[2] === account.field)?.[1] || account.field;
      line.append(node("span", `${label} · ${account.displayName || account.accountId}${account.authorizationState === "reauthRequired" ? " · 需要重新授权" : ""}`));
      button(line, `edit-${account.field}-${account.accountId}`, "替换凭证", () => {
        clearSecrets(); byId("account-provider").value = account.field;
        byId("account-id").value = account.accountId; byId("account-name").value = account.displayName || "";
        message(byId("account-status"), "填写新凭证后保存此账号");
      });
      button(line, `remove-${account.field}-${account.accountId}`, "移除账号", async () => {
        try {
          await invoke("remove_credential_account", { field: account.field, accountId: account.accountId });
          message(byId("account-status"), "账号已移除"); await loadCredentials();
        } catch { message(byId("account-status"), "移除账号失败"); }
      });
      inventory.append(line);
    }
    if (!accounts?.length) inventory.append(node("p", "尚未配置账号", { class: "hint" }));
  }
  async function saveCredentials() {
    const save = byId("credentials-save"); save.disabled = true;
    try {
      const payloads = {};
      for (const textarea of byId("credential-fields").querySelectorAll("textarea")) {
        const raw = textarea.value.trim(); if (!raw) continue;
        payloads[textarea.dataset.field] = raw === "null" ? null : objectJSON(raw, "凭证字段");
      }
      validatePayloads(payloads);
      if (!Object.keys(payloads).length) throw new Error("没有需要保存的内容");
      await invoke("save_credentials_command", { payloads });
      message(byId("credentials-status"), "已保存"); await loadCredentials();
    } catch (error) { message(byId("credentials-status"), `保存失败：${error.message || error}`); }
    finally { save.disabled = false; }
  }
  async function validateConnections() {
    try {
      const saved = await invoke("get_settings");
      if (saved.consentVersion !== 1) throw new Error("请先在授权与隐私中允许订阅查询并保存设置");
      await invoke("refresh_now"); message(byId("connection-status"), "正在检查已启用账号，等待查询结果…");
    } catch (error) { message(byId("connection-status"), error.message || String(error)); }
  }
  function showConnectionResult(panel) {
    const host = byId("connection-status"); if (!host) return;
    const lines = [];
    for (const section of panel.subscription?.sections || []) {
      lines.push(`${section.name}：${section.status === "ok" ? "连接正常" : section.note || section.status || "等待结果"}`);
      for (const account of section.accounts || []) lines.push(`${account.name}：${account.status === "ok" ? "连接正常" : account.note || account.status}`);
    }
    if (panel.runtime?.error) lines.push(panel.runtime.error);
    host.textContent = lines.join("\n") || "尚无订阅查询结果";
  }
  const ready = (async () => {
    const settingsHost = byId("settings-content"), credentialsHost = byId("credentials-content");
    if (!settingsHost || !credentialsHost) return;
    buildSettings(settingsHost); buildCredentials(credentialsHost);
    try {
      await Promise.all([loadSettings(), loadCredentials(), loadPrices(), loadRuntimeInfo()]);
      await window.__TAURI__.event.listen("settings-updated", async () => { try { await loadSettings(); } catch { message(byId("settings-status"), "设置读取失败"); } });
      await window.__TAURI__.event.listen("dashboard-updated", event => showConnectionResult(event.payload));
    } catch { message(byId("settings-status"), "部分配置读取失败，请重新打开设置"); }
  })();
  window.BruceSettings = { ready, applyTheme };
})();
