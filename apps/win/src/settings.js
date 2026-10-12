// Settings controller for Bruce independent settings window.
// Aligns 1:1 with mac SettingsView (WinUI NavigationView Fluent sidebar layout).
(() => {
  const { invoke } = window.__TAURI__.core;
  const providers = [
    ["kimi", "Kimi For Coding", "kimiQuotaAccounts"],
    ["deepseek", "DeepSeek", "deepseekQuotaAccounts"],
    ["volcengine", "火山引擎", "volcengineQuotaAccounts"],
    ["zhipu", "智谱", "zhipuQuotaAccounts"],
    ["codex", "ChatGPT / Codex", "codexQuotaAccounts"],
    ["claude", "Claude", "claudeQuotaAccounts"],
    ["grok", "Grok", "grokQuotaAccounts"],
    ["opencodeGo", "OpenCode GO", "opencodeGoQuotaAccounts"],
    ["stepfun", "StepFun", "stepfunQuotaAccounts"],
  ];
  const CATEGORIES = {
    general: { title: "通用", crumb: "设置 / 通用" },
    agentUsage: { title: "Agent 用量", crumb: "设置 / Agent 用量" },
    modelPricing: { title: "模型计费", crumb: "设置 / 模型计费" },
    subscription: { title: "订阅额度", crumb: "设置 / 订阅额度" },
    consent: { title: "授权与隐私", crumb: "设置 / 授权与隐私" },
    maintenance: { title: "维护", crumb: "设置 / 维护" },
  };

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

  function message(host, text) { if (host) host.textContent = text; }
  function input(id, type = "text", attrs = {}) { return node("input", null, { id, type, ...attrs }); }
  function row(parent, title, control, sub = null) {
    const label = node("label", null, { class: "fluent-row" });
    const meta = node("div", null, { class: "row-meta" });
    meta.append(node("span", title, { class: "row-title" }));
    if (sub) meta.append(node("span", sub, { class: "row-sub" }));
    label.append(meta, control);
    parent.append(label);
    return control;
  }
  function card(parent, title = null) {
    const block = node("section", null, { class: "fluent-card" });
    if (title) block.append(node("h2", title, { class: "card-caption" }));
    parent.append(block);
    return block;
  }
  function button(parent, id, title, callback, cls = "btn") {
    const value = node("button", title, { id, type: "button", class: cls });
    value.addEventListener("click", callback);
    parent.append(value);
    return value;
  }
  function actions(parent) {
    const value = node("div", null, { class: "card-actions" });
    parent.append(value);
    return value;
  }

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

  function switchCategory(key) {
    if (!CATEGORIES[key]) return;
    for (const item of document.querySelectorAll(".navitem")) {
      item.classList.toggle("active", item.dataset.category === key);
    }
    for (const [cat] of Object.entries(CATEGORIES)) {
      const pane = byId(`pane-${cat}`);
      if (pane) pane.classList.toggle("hidden", cat !== key);
    }
    const meta = CATEGORIES[key];
    const crumb = byId("crumb"), title = byId("pane-title");
    if (crumb) crumb.textContent = meta.crumb;
    if (title) title.textContent = meta.title;
  }

  function renderOrders() {
    const cards = byId("setting-card-order");
    if (cards) {
      cards.replaceChildren();
      cardOrder.forEach((id, index) => {
        const line = node("div", null, { class: "order-row" });
        line.append(node("span", { usage: "Token 用量", subscription: "订阅额度", hourly: "Agent 用量" }[id] || id));
        const btns = node("div", null, { class: "order-btns" });
        button(btns, `card-up-${id}`, "上移", () => { move(cardOrder, index, -1); renderOrders(); });
        button(btns, `card-down-${id}`, "下移", () => { move(cardOrder, index, 1); renderOrders(); });
        line.append(btns);
        cards.append(line);
      });
    }

    const host = byId("setting-providers");
    if (host) {
      const prior = new Map([...host.querySelectorAll("input")].map(value => [value.dataset.provider, value.checked]));
      host.replaceChildren();
      providerOrder.forEach((id, index) => {
        const descriptor = providers.find(value => value[0] === id) || [id, id];
        const line = node("div", null, { class: "order-row" });
        const check = input(`provider-${id}`, "checkbox", { "data-provider": id });
        check.checked = prior.has(id) ? prior.get(id) : (settings.enabledProviders || providers.map(value => value[0])).includes(id);
        const label = node("label", null, { class: "provider-check-label" });
        label.append(check, node("span", descriptor[1]));
        line.append(label);
        const btns = node("div", null, { class: "order-btns" });
        button(btns, `provider-up-${id}`, "上移", () => { move(providerOrder, index, -1); renderOrders(); });
        button(btns, `provider-down-${id}`, "下移", () => { move(providerOrder, index, 1); renderOrders(); });
        line.append(btns);
        host.append(line);
      });
    }
  }

  // MARK: - 分类面板构建

  function buildGeneral(host) {
    host.replaceChildren();
    const c1 = card(host, "常规偏好");
    row(c1, "刷新间隔（分钟）", input("setting-interval", "number", { min: "1", max: "1440" }), "周期采集间隔时间，范围 1–1440 分钟");
    row(c1, "配额预警通知", input("setting-notifications", "checkbox"), "当订阅额度使用过半或告急时通过系统通知预警");
    const theme = node("select", null, { id: "setting-theme", class: "fluent-select" });
    theme.append(node("option", "Fluent", { value: "fluent" }), node("option", "Nothing 点阵", { value: "nothing" }));
    row(c1, "外观主题", theme, "选择深色经典 Fluent 风格或 Nothing 点阵风格");

    const hotkeyWrap = node("div", null, { class: "hotkey-field-wrap" });
    hotkeyWrap.append(input("setting-hotkey", "text", { placeholder: "Control+Shift+B", autocomplete: "off" }));
    button(hotkeyWrap, "hotkey-record", "录制热键", () => {
      const field = byId("setting-hotkey");
      field.focus?.();
      message(byId("settings-status"), "在热键输入框按下组合键；按 Esc 取消录制");
      field.dataset.recording = "true";
    });
    row(c1, "全局热键", hotkeyWrap, "唤出或隐藏置顶看板；留空关闭全局快捷键");

    byId("setting-hotkey")?.addEventListener("keydown", event => {
      const field = byId("setting-hotkey");
      if (field.dataset.recording !== "true") return;
      event.preventDefault();
      if (event.key === "Escape") { field.dataset.recording = "false"; return; }
      if (["Control", "Alt", "Shift", "Meta"].includes(event.key)) return;
      const parts = [event.ctrlKey && "Control", event.altKey && "Alt", event.shiftKey && "Shift", event.metaKey && "Super"].filter(Boolean);
      if (!parts.length) { message(byId("settings-status"), "请使用 Ctrl、Alt、Shift 或 Win 键与其他键组合"); return; }
      parts.push(event.key.length === 1 ? event.key.toUpperCase() : event.key);
      field.value = parts.join("+");
      field.dataset.recording = "false";
    });

    const c2 = card(host, "看板卡片顺序");
    c2.append(node("p", "拖动或点击上下移调整置顶面板各卡片的堆叠顺序。", { class: "hint" }));
    c2.append(node("div", null, { id: "setting-card-order", class: "order-list" }));
  }

  function buildAgentUsage(host) {
    host.replaceChildren();
    const c1 = card(host, "Agent 会话采集");
    row(c1, "读取本机 Agent 会话用量", input("setting-usage", "checkbox"), "开启后在本机读取会话记录，计算 Token 用量与费用。");
    c1.append(node("p", "Bruce 采用只读方式扫描本地支持的 Agent 目录（如 Claude Code, Codex, Grok, OpenCode 等），所有数据均在用户本机闭环计算。", { class: "hint" }));
  }

  function buildModelPricing(host) {
    host.replaceChildren();
    const c1 = card(host, "内置模型价格基准");
    const details = node("details", null, { id: "model-prices-details" });
    details.append(node("summary", "查看内置官方模型价格表"));
    details.append(node("div", null, { id: "model-prices", class: "price-table-wrap" }));
    c1.append(details);

    const c2 = card(host, "自定义模型价格覆盖");
    c2.append(node("p", "价格按每百万 Token (USD/CNY) 计算；自定义覆盖将用于下一次采集的费用估算。", { class: "hint" }));
    const form = node("div", null, { class: "form-grid" });
    row(form, "模型标识", input("price-model", "text", { placeholder: "如 gpt-4o 或 claude-3-5-sonnet" }));
    row(form, "输入单价", input("price-input", "number", { min: "0", step: "any", placeholder: "每百万 tokens 价格" }));
    row(form, "输出单价", input("price-output", "number", { min: "0", step: "any", placeholder: "每百万 tokens 价格" }));
    row(form, "缓存读取单价（可选）", input("price-cache", "number", { min: "0", step: "any", placeholder: "可选" }));
    row(form, "币种", input("price-currency", "text", { value: "USD" }));
    c2.append(form);

    const btnRow = node("div", null, { class: "actions-inline" });
    button(btnRow, "price-add", "添加或替换价格覆盖", () => {
      try {
        const model = byId("price-model").value.trim();
        if (!model || !byId("price-input").value || !byId("price-output").value) throw new Error("请填写模型名称和输入、输出价格");
        const overrides = objectJSON(byId("setting-pricing-overrides").value || "{}", "价格覆盖");
        const value = { inputPricePerMillion: Number(byId("price-input").value), outputPricePerMillion: Number(byId("price-output").value), currency: byId("price-currency").value.trim() || "USD" };
        if (byId("price-cache").value) value.cacheReadPricePerMillion = Number(byId("price-cache").value);
        overrides[model] = value;
        validateOverrides(overrides);
        byId("setting-pricing-overrides").value = JSON.stringify(overrides, null, 2);
        message(byId("settings-status"), "已加入价格覆盖编辑内容，请保存设置");
      } catch (error) { message(byId("settings-status"), error.message); }
    }, "btn primary");
    c2.append(btnRow);

    const overrides = node("textarea", null, { id: "setting-pricing-overrides", rows: "5", spellcheck: "false", "aria-label": "自定义模型价格覆盖", class: "code-area" });
    c2.append(overrides);
    const resetRow = node("div", null, { class: "actions-inline" });
    button(resetRow, "price-reset", "清空价格覆盖", () => { overrides.value = "{}"; });
    c2.append(resetRow);
  }

  function buildSubscription(host) {
    host.replaceChildren();
    const c1 = card(host, "启用服务与顺序");
    c1.append(node("p", "勾选启用的订阅服务并调整看板上的呈现顺序。", { class: "hint" }));
    c1.append(node("div", null, { id: "setting-providers", class: "order-list" }));

    const c2 = card(host, "已配置账号");
    c2.append(node("p", "凭证保存在当前用户专属的本机目录。保存后仅展示账号元数据，不回显密钥。", { class: "hint" }));
    c2.append(node("div", null, { id: "credential-accounts", class: "account-list" }));

    const c3 = card(host, "添加或更新账号凭证");
    const providerSel = node("select", null, { id: "account-provider", class: "fluent-select" });
    for (const [, name, field] of providers) providerSel.append(node("option", name, { value: field }));
    providerSel.value = providers[0][2];
    row(c3, "服务提供商", providerSel);
    row(c3, "账号标识", input("account-id", "text", { placeholder: "例如 work 或 personal", autocomplete: "off" }));
    row(c3, "显示名称", input("account-name", "text", { placeholder: "例如工作账号" }));
    row(c3, "密钥 / Access Token", input("account-secret", "password", { autocomplete: "new-password" }));
    row(c3, "附加密钥 / Refresh Token", input("account-secondary", "password", { autocomplete: "new-password" }), "如火山引擎 Secret Key 或 OAuth 刷新凭证");
    row(c3, "智谱 API 地址（可选）", input("account-base-url", "text", { placeholder: "https://open.bigmodel.cn/api/paas/v4" }));
    const site = node("select", null, { id: "account-site", class: "fluent-select" });
    site.append(node("option", "国内", { value: "domestic" }), node("option", "国际", { value: "global" }));
    row(c3, "StepFun 站点", site);

    const extra = node("details", null, { class: "extra-details" });
    extra.append(node("summary", "OAuth 或其他附加凭证 (JSON)"));
    extra.append(node("textarea", null, { id: "account-extra", rows: "3", placeholder: "可粘贴完整 OAuth JSON", autocomplete: "off", spellcheck: "false", "aria-label": "OAuth 附加凭证", class: "code-area" }));
    c3.append(extra);

    providerSel.addEventListener("change", () => {
      byId("account-secret").value = "";
      byId("account-secondary").value = "";
      byId("account-extra").value = "";
    });

    const act = actions(c3);
    button(act, "account-save", "保存此账号", saveAccount, "btn primary");
    button(act, "credentials-validate", "检查已保存账号连接", validateConnections);
    act.append(node("span", null, { id: "account-status", role: "status", class: "status-msg" }));
    c3.append(node("div", null, { id: "connection-status", role: "status", class: "connection-status-box" }));

    const c4 = card(host, "导入账号");
    c4.append(node("p", "选择本机 Codex auth.json 或 Bruce 凭证 JSON 导入账号，导入前自动校验格式。", { class: "hint" }));
    c4.append(input("credential-import-file", "file", { accept: ".json,application/json", class: "file-input" }));
    const impAct = actions(c4);
    button(impAct, "credential-import", "导入所选文件", async () => {
      try {
        const file = byId("credential-import-file").files?.[0];
        if (!file) throw new Error("请选择 JSON 文件");
        const auth = objectJSON(await file.text(), "导入文件");
        if (auth.tokens) await invoke("import_codex_auth", { auth });
        else {
          const payloads = validatePayloads(auth);
          for (const [field, value] of Object.entries(payloads)) {
            if (field.endsWith("Accounts") && value) {
              for (const [accountId, payload] of Object.entries(value)) await invoke("save_credential_account", { field, accountId, payload });
            } else await invoke("save_credentials_command", { payloads: { [field]: value } });
          }
        }
        byId("credential-import-file").value = "";
        message(byId("credentials-status"), "导入完成");
        await loadCredentials();
      } catch (error) { message(byId("credentials-status"), `导入失败：${error.message || error}`); }
    });

    const c5 = card(host, "高级：完整凭证字段维护");
    const adv = node("details");
    adv.append(node("summary", "展开查看或替换完整凭证字段"));
    adv.append(node("p", "仅在需要批量导出或替换整个字段时使用。留空保留原有字段，填写 null 删除对应字段。", { class: "hint" }));
    adv.append(node("div", null, { id: "credential-fields" }));
    const advAct = actions(adv);
    button(advAct, "credentials-save", "保存完整字段", saveCredentials);
    advAct.append(node("span", null, { id: "credentials-status", role: "status", class: "status-msg" }));
    c5.append(adv);
  }

  function buildConsent(host) {
    host.replaceChildren();
    const c1 = card(host, "授权与隐私");
    row(c1, "允许向已启用的订阅服务查询额度", input("setting-consent", "checkbox"), "仅向已启用的第三方服务发送对应的已保存账号凭证。");
    c1.append(node("p", "安全原则：所有 Token 统计、账本记账与模型估算均在本机离线计算；关闭授权后将停止一切对外订阅查询。", { class: "hint" }));
  }

  function buildMaintenance(host) {
    host.replaceChildren();
    const c1 = card(host, "运行环境与诊断");
    c1.append(node("pre", null, { id: "runtime-info", class: "runtime-info-box" }));
    const act = actions(c1);
    button(act, "runtime-reload", "刷新运行状态", loadRuntimeInfo);
  }

  // MARK: - 数据交互逻辑

  async function loadRuntimeInfo() {
    try {
      const info = await invoke("get_runtime_info");
      const status = info.status && typeof info.status === "object" ? info.status : { phase: info.status || info.phase };
      byId("runtime-info").textContent = [
        `数据目录：${info.dataRoot || "未知"}`,
        `缓存目录：${info.cacheRoot || "未知"}`,
        `快照文件：${info.snapshotPath || "未知"}`,
        `状态：${status.phase || "未知"}`,
        `最近成功：${status.lastSuccessAt || "尚无"}`,
        `错误：${status.error || "无"}`,
        `诊断：${(status.diagnosticCodes || []).join("、") || "无"}`,
      ].join("\n");
    } catch { message(byId("runtime-info"), "无法读取运行状态"); }
  }

  async function loadPrices() {
    try {
      const prices = await invoke("get_model_prices");
      const host = byId("model-prices");
      if (!host) return;
      host.replaceChildren();
      const table = node("table", null, { class: "fluent-table" });
      const header = node("tr");
      for (const text of ["模型", "输入", "输出", "缓存读取", "币种"]) header.append(node("th", text));
      table.append(header);
      for (const [model, price] of Object.entries(prices).sort(([a], [b]) => a.localeCompare(b))) {
        const line = node("tr");
        for (const text of [model, price.inputPricePerMillion, price.outputPricePerMillion, price.cacheReadPricePerMillion ?? "—", price.currency]) {
          line.append(node("td", String(text)));
        }
        table.append(line);
      }
      host.append(table);
    } catch { message(byId("model-prices"), "模型价格暂不可用"); }
  }

  async function loadSettings() {
    settings = await invoke("get_settings");
    if (byId("setting-interval")) byId("setting-interval").value = Math.round(settings.refreshIntervalSecs / 60);
    if (byId("setting-notifications")) byId("setting-notifications").checked = settings.notificationsEnabled;
    if (byId("setting-hotkey")) byId("setting-hotkey").value = settings.hotkey || "";
    if (byId("setting-theme")) byId("setting-theme").value = settings.theme;
    if (byId("setting-consent")) byId("setting-consent").checked = settings.consentVersion === 1;
    if (byId("setting-usage")) byId("setting-usage").checked = settings.usageEnabled !== false;
    if (byId("setting-pricing-overrides")) byId("setting-pricing-overrides").value = JSON.stringify(settings.pricingOverrides || {}, null, 2);
    cardOrder = orderedAll(settings.cardOrder || [], ["usage", "subscription", "hourly"]);
    providerOrder = orderedAll(settings.providerOrder || [], providers.map(value => value[0]));
    renderOrders();
    applyTheme(settings.theme);
  }

  async function saveSettings() {
    const status = byId("settings-status"), save = byId("settings-save");
    if (save) save.disabled = true;
    try {
      const interval = Number(byId("setting-interval")?.value || 30);
      if (!Number.isInteger(interval) || interval < 1 || interval > 1440) throw new Error("刷新间隔须为 1–1440 的整数分钟");
      const overrides = validateOverrides(objectJSON(byId("setting-pricing-overrides")?.value || "{}", "价格覆盖"));
      const updated = {
        ...await invoke("get_settings"),
        refreshIntervalSecs: interval * 60,
        notificationsEnabled: byId("setting-notifications")?.checked ?? true,
        hotkey: byId("setting-hotkey")?.value.trim() || "",
        theme: byId("setting-theme")?.value || "fluent",
        consentVersion: byId("setting-consent")?.checked ? 1 : 0,
        usageEnabled: byId("setting-usage")?.checked ?? true,
        cardOrder: [...cardOrder],
        providerOrder: [...providerOrder],
        enabledProviders: [...(byId("setting-providers")?.querySelectorAll("input") || [])].filter(v => v.checked).map(v => v.dataset.provider),
        pricingOverrides: overrides,
      };
      await invoke("save_settings_command", { settings: updated });
      settings = updated;
      applyTheme(updated.theme);
      window.dispatchEvent(new CustomEvent("settings-saved", { detail: updated }));
      message(status, "已保存");
    } catch (error) { message(status, `保存失败：${error.message || error}`); }
    finally { if (save) save.disabled = false; }
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
    for (const id of ["account-secret", "account-secondary", "account-extra"]) {
      const inputEl = byId(id);
      if (inputEl) inputEl.value = "";
    }
  }

  async function saveAccount() {
    const save = byId("account-save");
    if (save) save.disabled = true;
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
      clearSecrets();
      message(byId("account-status"), "账号已保存");
      await loadCredentials();
    } catch (error) { message(byId("account-status"), `保存失败：${error.message || error}`); }
    finally { if (save) save.disabled = false; }
  }

  async function loadCredentials() {
    const [fields, configured, accounts] = await Promise.all([
      invoke("credential_allowlist"),
      invoke("get_credential_fields"),
      invoke("get_credential_accounts"),
    ]);
    allowlist = fields;
    const host = byId("credential-fields");
    if (host) {
      host.replaceChildren();
      for (const field of fields) {
        const block = node("div", null, { class: "credential-field" });
        const title = providers.find(v => v[2] === field)?.[1] || field;
        const label = node("label", `${title}${configured.includes(field) ? "（已配置，留空保留）" : ""}`);
        const textarea = node("textarea", null, { rows: "2", "data-field": field, autocomplete: "off", spellcheck: "false", "aria-label": title, class: "code-area" });
        textarea.placeholder = field.endsWith("Accounts") ? '{"work":{"display_name":"工作","api_key":"…"}}' : "{…}";
        block.append(label, textarea);
        host.append(block);
      }
    }

    const inventory = byId("credential-accounts");
    if (inventory) {
      inventory.replaceChildren();
      for (const account of accounts || []) {
        const line = node("div", null, { class: "account-row" });
        const label = providers.find(v => v[2] === account.field)?.[1] || account.field;
        line.append(node("span", `${label} · ${account.displayName || account.accountId}${account.authorizationState === "reauthRequired" ? " · 需要重新授权" : ""}`, { class: "account-label" }));
        const btns = node("div", null, { class: "account-actions" });
        button(btns, `edit-${account.field}-${account.accountId}`, "替换凭证", () => {
          clearSecrets();
          byId("account-provider").value = account.field;
          byId("account-id").value = account.accountId;
          byId("account-name").value = account.displayName || "";
          message(byId("account-status"), "填写新凭证后保存此账号");
        });
        button(btns, `remove-${account.field}-${account.accountId}`, "移除账号", async () => {
          try {
            await invoke("remove_credential_account", { field: account.field, accountId: account.accountId });
            message(byId("account-status"), "账号已移除");
            await loadCredentials();
          } catch { message(byId("account-status"), "移除账号失败"); }
        }, "btn danger");
        line.append(btns);
        inventory.append(line);
      }
      if (!accounts?.length) inventory.append(node("p", "尚未配置账号", { class: "hint" }));
    }
  }

  async function saveCredentials() {
    const save = byId("credentials-save");
    if (save) save.disabled = true;
    try {
      const payloads = {};
      for (const textarea of byId("credential-fields")?.querySelectorAll("textarea") || []) {
        const raw = textarea.value.trim();
        if (!raw) continue;
        payloads[textarea.dataset.field] = raw === "null" ? null : objectJSON(raw, "凭证字段");
      }
      validatePayloads(payloads);
      if (!Object.keys(payloads).length) throw new Error("没有需要保存的内容");
      await invoke("save_credentials_command", { payloads });
      message(byId("credentials-status"), "已保存");
      await loadCredentials();
    } catch (error) { message(byId("credentials-status"), `保存失败：${error.message || error}`); }
    finally { if (save) save.disabled = false; }
  }

  async function validateConnections() {
    try {
      const saved = await invoke("get_settings");
      if (saved.consentVersion !== 1) throw new Error("请先在授权与隐私中允许订阅查询并保存设置");
      await invoke("refresh_now");
      message(byId("connection-status"), "正在检查已启用账号，等待查询结果…");
    } catch (error) { message(byId("connection-status"), error.message || String(error)); }
  }

  function showConnectionResult(panel) {
    const host = byId("connection-status");
    if (!host) return;
    const lines = [];
    for (const section of panel.subscription?.sections || []) {
      lines.push(`${section.name}：${section.status === "ok" ? "连接正常" : section.note || section.status || "等待结果"}`);
      for (const account of section.accounts || []) {
        lines.push(`${account.name}：${account.status === "ok" ? "连接正常" : account.note || account.status}`);
      }
    }
    if (panel.runtime?.error) lines.push(panel.runtime.error);
    host.textContent = lines.join("\n") || "尚无订阅查询结果";
  }

  // MARK: - 初始化
  const ready = (async () => {
    // 绑定侧栏点击
    for (const navBtn of document.querySelectorAll(".navitem")) {
      navBtn.addEventListener("click", () => switchCategory(navBtn.dataset.category));
    }
    const saveBtn = byId("settings-save");
    if (saveBtn) saveBtn.addEventListener("click", saveSettings);

    const gHost = byId("pane-general-content");
    const uHost = byId("pane-agentUsage-content");
    const pHost = byId("pane-modelPricing-content");
    const sHost = byId("pane-subscription-content");
    const cHost = byId("pane-consent-content");
    const mHost = byId("pane-maintenance-content");

    if (gHost) buildGeneral(gHost);
    if (uHost) buildAgentUsage(uHost);
    if (pHost) buildModelPricing(pHost);
    if (sHost) buildSubscription(sHost);
    if (cHost) buildConsent(cHost);
    if (mHost) buildMaintenance(mHost);

    try {
      await Promise.all([loadSettings(), loadCredentials(), loadPrices(), loadRuntimeInfo()]);
      await window.__TAURI__.event.listen("settings-updated", async () => {
        try { await loadSettings(); } catch { message(byId("settings-status"), "设置读取失败"); }
      });
      await window.__TAURI__.event.listen("dashboard-updated", event => showConnectionResult(event.payload));
    } catch {
      message(byId("settings-status"), "部分配置读取失败，请重新打开设置");
    }
  })();

  window.BruceSettings = { ready, applyTheme, switchCategory };
})();
