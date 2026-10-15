// Settings controller for Bruce independent settings window.
// Aligns 1:1 with mac SettingsView (WinUI NavigationView Fluent sidebar layout).
(() => {
  const tauriCore = window.__TAURI__?.core || window.__TAURI_INTERNALS__;
  const invoke = tauriCore?.invoke || (window.__TAURI__ && window.__TAURI__.invoke) || (async () => null);
  const listen = window.__TAURI__?.event?.listen || (async () => () => {});
  // provider 清单: 显示名与顺序对齐 mac SubscriptionProviderID.displayName
  // (11 家中 Jev 双端界面隐藏; Cline 为 C028 补齐)。
  const providers = [
    ["kimi", "Kimi", "kimiQuotaAccounts"],
    ["deepseek", "DeepSeek", "deepseekQuotaAccounts"],
    ["volcengine", "火山引擎", "volcengineQuotaAccounts"],
    ["zhipu", "Z.ai", "zhipuQuotaAccounts"],
    ["codex", "Codex", "codexQuotaAccounts"],
    ["claude", "Claude", "claudeQuotaAccounts"],
    ["grok", "Grok", "grokQuotaAccounts"],
    ["opencodeGo", "OpenCode GO", "opencodeGoQuotaAccounts"],
    ["stepfun", "StepFun", "stepfunQuotaAccounts"],
    ["cline", "Cline", "clineQuotaAccounts"],
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
  // mac 允许的自动采集周期 (OnboardingConfiguration.allowedRefreshIntervalMinutes)
  const REFRESH_PRESETS = [5, 15, 30, 60];
  let settings = {}, allowlist = [], providerOrder = [], cardOrder = [];
  let credentialAccounts = [];
  let currentRuntimeInfo = null;
  // 套餐名: 由 artifact 提供 (mac C024 起套餐名只在设置页行内呈现), 经 get_dashboard 取。
  let providerPlans = {};
  const SESSION_PROBES = [
    { id: "claude-code", name: "Claude Code", sub: "本机会话目录 (~/.claude/projects)" },
    { id: "codex", name: "ChatGPT / Codex", sub: "本机会话目录 (~/.codex/sessions)" },
    { id: "kimi-code-cli", name: "Kimi Code", sub: "本机会话目录 (~/.kimi/history)" },
    { id: "opencode", name: "OpenCode", sub: "本机会话目录 (%APPDATA%\\OpenCode)" },
    { id: "grok", name: "Grok", sub: "本机会话目录 (~/.grok)" },
    { id: "volcengine", name: "火山引擎 / 豆包", sub: "本机会话目录" },
    { id: "orca", name: "Orca", sub: "本机会话目录" },
    { id: "pi", name: "Pi", sub: "本机会话目录" },
    { id: "zcode", name: "ZCode", sub: "本机会话目录" },
    { id: "codebuddy", name: "CodeBuddy", sub: "本机会话目录" },
  ];

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

  // MARK: - 订阅 provider 展示 (对齐 mac SettingsView.subscriptionProviderRow)

  // 品牌色板 (与看板同源): 事实源 mac ProviderBrandPalette.hex, 双端逐家对齐 (C012/C026)。
  const PROVIDER_COLORS = {
    kimi: "#0a84ff", deepseek: "#4d6bfe", volcengine: "#ff6a00", zhipu: "#2D2D2D",
    codex: "#10a37f", claude: "#d97757", grok: "#111111", opencodeGo: "#8a63d2",
    stepfun: "#0c5efc", cline: "#18181b",
  };
  // 品牌图形来自 provider-brand.js 生成产物 (与 app.js 内联块同源, 由 --check 锁定)。
  const PROVIDER_GLYPHS = window.BRUCE_PROVIDER_GLYPHS || {};
  function providerBadge(id, name) {
    const badge = node("span", null, { class: "pbadge", "aria-hidden": "true" });
    badge.style.background = PROVIDER_COLORS[id] || "#8e8e93";
    const glyph = PROVIDER_GLYPHS[id];
    if (glyph) {
      const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
      svg.setAttribute("viewBox", glyph.vb);
      svg.setAttribute("fill", "currentColor");
      for (const [d, opacity] of glyph.shapes) {
        const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
        path.setAttribute("d", d);
        if (opacity !== 1) path.setAttribute("fill-opacity", String(opacity));
        svg.append(path);
      }
      badge.append(svg);
    } else {
      badge.textContent = (name || "?").trim().charAt(0).toUpperCase();
    }
    return badge;
  }
  // 凭证形态副标题 (mac subscriptionRowSubtitle)
  const CREDENTIAL_FORMS = {
    kimi: "Web 令牌", codex: "OAuth 设备码", claude: "CLI 登录态", grok: "CLI 登录态",
    opencodeGo: "OAuth 设备码", stepfun: "Step Plan Token",
  };
  function providerDescriptor(id) { return providers.find(value => value[0] === id) || [id, id, "", ""]; }
  function accountsFor(id) { return credentialAccounts.filter(account => account.field === providerDescriptor(id)[2]); }
  // 状态尾件 (mac subscriptionStatusTail): 未配置 / 已配置 / 需要重新授权
  function providerState(id) {
    const accounts = accountsFor(id);
    if (!accounts.length) return { text: "未配置", cls: "off" };
    if (accounts.some(account => account.authorizationState === "reauthRequired")) return { text: "需要重新授权", cls: "warn" };
    return { text: "已配置", cls: "ok" };
  }
  function enabledProvidersOf() { return settings.enabledProviders || providers.map(value => value[0]); }

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
      const prior = new Map([...host.querySelectorAll("input[type=checkbox]")].map(value => [value.dataset.provider, value.checked]));
      host.replaceChildren();
      providerOrder.forEach((id, index) => {
        const descriptor = providerDescriptor(id);
        const state = providerState(id);
        const line = node("div", null, { class: "provider-row" });
        line.append(providerBadge(id, descriptor[1]));
        const meta = node("div", null, { class: "provider-meta" });
        meta.append(node("span", descriptor[1], { class: "provider-name" }));
        const accounts = accountsFor(id);
        const suffix = accounts.length > 1 ? ` · ${accounts.length} 个账号` : "";
        meta.append(node("span", `${CREDENTIAL_FORMS[id] || "API Key"}${suffix}`, { class: "provider-sub" }));
        line.append(meta);
        if (providerPlans[id]) line.append(node("span", providerPlans[id], { class: "plan-chip" }));
        line.append(node("span", state.text, { class: `auth-state ${state.cls}` }));
        const toggle = input(`provider-${id}`, "checkbox", { "data-provider": id, class: "provider-toggle" });
        toggle.checked = prior.has(id) ? prior.get(id) : enabledProvidersOf().includes(id);
        toggle.setAttribute("aria-label", `${descriptor[1]} 启用开关`);
        line.append(toggle);
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
    // 刷新间隔对齐 mac 允许集合 (5/15/30/60 分钟); 当前值不在集合内时由 loadSettings
    // 追加为一项, 避免静默改写用户既有配置。
    const interval = node("select", null, { id: "setting-interval", class: "fluent-select" });
    for (const minutes of REFRESH_PRESETS) interval.append(node("option", `${minutes} 分钟`, { value: String(minutes) }));
    row(c1, "刷新间隔", interval, "已授权模块的自动采集周期，变更后立即重新计时");
    row(c1, "配额预警通知", input("setting-notifications", "checkbox"), "预警与额度提醒；关闭后 Bruce 不会投递通知");
    const theme = node("select", null, { id: "setting-theme", class: "fluent-select" });
    theme.append(node("option", "Fluent", { value: "fluent" }), node("option", "Nothing 点阵", { value: "nothing" }));
    row(c1, "外观主题", theme, "经典 Fluent 为深色材质面板；Nothing 为纯色平面风格（Windows 恒深色）");
    row(c1, "版本", node("span", "—", { id: "setting-version", class: "row-value" }), "当前运行的 Bruce 版本");

    const hotkeyWrap = node("div", null, { class: "hotkey-field-wrap" });
    hotkeyWrap.append(input("setting-hotkey", "text", { placeholder: "Control+Shift+B", autocomplete: "off" }));
    button(hotkeyWrap, "hotkey-record", "录制热键", () => {
      const field = byId("setting-hotkey");
      field.focus?.();
      message(byId("settings-status"), "在热键输入框按下组合键；按 Esc 取消录制");
      field.dataset.recording = "true";
    });
    button(hotkeyWrap, "hotkey-clear", "清除", () => {
      const field = byId("setting-hotkey");
      if (field) { field.value = ""; field.dataset.recording = "false"; }
      message(byId("settings-status"), "已清除热键，保存设置后生效");
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

    // 1. 会话来源 (对齐 mac SettingsView agentUsagePane)
    const cSources = card(host, "会话来源");
    row(cSources, "Rust Collector", node("span", "可用", { class: "status-tag ok" }), "扫描本机会话并聚合 token 用量");

    const probeList = node("div", null, { id: "session-probes" });
    cSources.append(probeList);

    const act = actions(cSources);
    button(act, "session-rescan", "重新检查", async () => {
      try {
        message(byId("settings-status"), "正在重新扫描本机会话…");
        await invoke("refresh_now");
        await loadRuntimeInfo();
        message(byId("settings-status"), "会话扫描已刷新");
      } catch (error) {
        message(byId("settings-status"), `扫描失败: ${error.message || error}`);
      }
    });

    // 2. Agent 会话采集授权 (对齐 mac)
    const cUsage = card(host, "Agent 会话采集");
    row(cUsage, "读取本机 Agent 会话用量", input("setting-usage", "checkbox"), "开启后在本机读取会话记录，计算 Token 用量与费用。");
    const summary = node("div", null, { class: "hint-box" });
    summary.append(node("p", "授权后应用将：", { class: "hint-title" }));
    const ul = node("ul", null, { class: "hint-list" });
    ul.append(node("li", "只读扫描本机 Agent 会话目录（如 Claude Code, Codex, Kimi, OpenCode 等）与 CC Switch 数据库；"));
    ul.append(node("li", "在用户本机闭环计算 Token 总量与估算费用，无自有云端服务端；"));
    ul.append(node("li", "严格执行只读模式（mode=ro），绝不修改、删除或上传任何外部会话日志。"));
    summary.append(ul);
    cUsage.append(summary);

    renderSessionProbes();
  }

  function renderSessionProbes() {
    const host = byId("session-probes");
    if (!host) return;
    host.replaceChildren();

    const diagnostics = currentRuntimeInfo?.diagnostics || [];
    const usage = currentRuntimeInfo?.usage;
    const activeAgents = new Set((usage?.breakdown || []).map(b => b.agentId || b.label));

    for (const probe of SESSION_PROBES) {
      const line = node("div", null, { class: "probe-row" });
      const meta = node("div", null, { class: "probe-meta" });
      meta.append(node("span", probe.name, { class: "probe-name" }));
      meta.append(node("span", probe.sub, { class: "probe-sub" }));
      line.append(meta);

      const diag = diagnostics.find(d => d.agentId === probe.id || d.module === probe.id);
      const hasUsage = activeAgents.has(probe.id) || activeAgents.has(probe.name);

      let statusText = "就绪";
      let statusCls = "status-tag ok";

      if (diag) {
        if (diag.note && diag.note.includes("未发现会话")) {
          statusText = "未发现会话记录";
          statusCls = "status-tag neutral";
        } else if (diag.status === "not_found" || diag.status === "missing") {
          statusText = "未安装";
          statusCls = "status-tag neutral";
        } else if (diag.status === "unauthorized") {
          statusText = "未授权";
          statusCls = "status-tag warn";
        } else if (diag.note) {
          statusText = diag.note;
          statusCls = "status-tag neutral";
        }
      } else if (!hasUsage) {
        statusText = "未发现会话记录";
        statusCls = "status-tag neutral";
      }

      line.append(node("span", statusText, { class: statusCls }));
      host.append(line);
    }
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
    const c1 = card(host, "订阅服务");
    c1.append(node("p", "配置并启用后, Agent 用量将在授权生效时查询对应云端额度; 上移/下移调整看板展示顺序。", { class: "hint" }));
    c1.append(node("div", null, { id: "setting-providers", class: "provider-list" }));

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
    row(c3, "Z.ai API 地址（可选）", input("account-base-url", "text", { placeholder: "https://open.bigmodel.cn/api/paas/v4" }));
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
    // mac 语义: 单一模块授权开关 + 「确认授权 / 撤销全部授权」两个动作按钮
    // (采集与云端额度查询同属一次授权), 说明文案随刷新间隔与已启用 provider 动态变化。
    row(c1, "Agent 用量", input("setting-usage-consent", "checkbox"), "允许按授权范围采集本机会话用量");
    const lines = node("div", null, { class: "auth-lines" });
    const list = node("ul", null, { class: "hint-list" });
    list.append(
      node("li", "扫描本机 Agent 会话目录和 CC Switch 数据库（只读）"),
      node("li", `每 ${Math.round((settings.refreshIntervalSecs || 1800) / 60)} 分钟自动刷新已授权模块`),
    );
    const enabled = enabledProvidersOf().map(id => providerDescriptor(id)[1]);
    list.append(node("li", enabled.length
      ? `确认授权后查询已启用订阅 Provider 的云端额度：${enabled.join(" / ")}`
      : "未配置启用的订阅额度 Provider，不会访问云端额度接口"));
    list.append(node("li", "可随时在此撤销授权暂停采集"));
    lines.append(node("p", "授权后应用将：", { class: "hint-title" }), list);
    c1.append(lines);
    const state = node("div", null, { class: "auth-state-line" });
    state.append(node("span", settings.consentVersion === 1 ? "当前授权有效" : "尚未授权", { id: "consent-state", class: settings.consentVersion === 1 ? "auth-state ok" : "auth-state off" }));
    c1.append(state);
    const act = actions(c1);
    button(act, "consent-revoke", "撤销全部授权", () => applyConsent(false), "btn danger");
    button(act, "consent-confirm", "确认授权", () => applyConsent(true), "btn primary");
    act.append(node("span", null, { id: "consent-status", role: "status", class: "status-msg" }));
  }

  function buildMaintenance(host) {
    host.replaceChildren();
    const c1 = card(host, "数据");
    const cacheWrap = node("div", null, { class: "actions-inline-flat" });
    button(cacheWrap, "cache-clear", "清理", () => clearCache(), "btn danger");
    row(c1, "清理用量缓存", cacheWrap, "仅删除本应用快照，不影响配置、凭证与账单统计");
    c1.append(node("p", "导出账单与诊断包需要系统文件保存对话框, Windows 侧尚未接入 (见 C032/后续卡)。", { class: "hint" }));

    const c2 = card(host, "运行环境与诊断");
    c2.append(node("pre", null, { id: "runtime-info", class: "runtime-info-box" }));
    const act = actions(c2);
    button(act, "runtime-reload", "刷新运行状态", loadRuntimeInfo);
    button(act, "diagnostics-preview", "诊断预览", showDiagnosticsPreview);
    // 预览容器 id 与按钮 id 必须不同 (C031 实测: 同名会让 getElementById 命中按钮,
    // 把 JSON 写进按钮标签并让预览框保持空)
    c2.append(node("pre", null, { id: "diagnostics-report", class: "runtime-info-box hidden" }));
  }

  // 清理缓存: 仅删快照 (与 mac「清理用量缓存」语义一致), 随后后端会请求一次刷新。
  async function clearCache() {
    const status = byId("settings-status");
    try {
      await invoke("clear_snapshot_cache");
      message(status, "缓存已清理");
      await loadRuntimeInfo();
    } catch (error) {
      message(status, `缓存清理失败：${error.message || error}`);
    }
  }

  // 诊断预览: 与 mac 一致输出脱敏内容 (不含凭证、完整本机路径与业务数据), 供人工核对。
  function showDiagnosticsPreview() {
    const box = byId("diagnostics-report");
    if (!box) return;
    const info = currentRuntimeInfo || {};
    const status = info.status && typeof info.status === "object" ? info.status : { phase: info.status };
    const redact = value => String(value || "").split(/[\\/]/).filter(Boolean).slice(-1)[0] || "未知";
    const report = {
      application: { version: info.version || "未知", platform: "windows" },
      module: { phase: status.phase || "未知", lastSuccessAt: status.lastSuccessAt || null, error: status.error || null },
      diagnostics: (status.diagnosticCodes || []).slice(0, 20),
      snapshots: { snapshotFile: redact(info.snapshotPath), cacheFolder: redact(info.cacheRoot), dataFolder: redact(info.dataRoot) },
      redaction: "不含凭证、账号标识、完整本机路径与业务数据",
    };
    box.textContent = JSON.stringify(report, null, 2);
    box.classList.remove("hidden");
  }

  // 授权动作即时生效 (对齐 mac confirmConsent/revokeAllConsent 的即时语义)
  async function applyConsent(granted) {
    const status = byId("consent-status");
    try {
      const current = { ...await invoke("get_settings") };
      const updated = { ...current, consentVersion: granted ? 1 : 0, usageEnabled: granted ? true : false };
      await invoke("save_settings_command", { settings: updated });
      settings = updated;
      const box = byId("setting-usage-consent");
      if (box) box.checked = granted;
      const state = byId("consent-state");
      if (state) { state.textContent = granted ? "当前授权有效" : "尚未授权"; state.className = granted ? "auth-state ok" : "auth-state off"; }
      window.dispatchEvent(new CustomEvent("settings-saved", { detail: updated }));
      message(status, granted ? "已确认授权" : "已撤销全部授权");
    } catch (error) {
      message(status, `授权更新失败：${error.message || error}`);
    }
  }

  // MARK: - 数据交互逻辑

  async function loadRuntimeInfo() {
    try {
      const info = await invoke("get_runtime_info");
      currentRuntimeInfo = info;
      const status = info.status && typeof info.status === "object" ? info.status : { phase: info.status || info.phase };
      const version = byId("setting-version");
      if (version) version.textContent = info.version || "—";
      const box = byId("runtime-info");
      if (box) {
        box.textContent = [
          `数据目录：${info.dataRoot || "未知"}`,
          `缓存目录：${info.cacheRoot || "未知"}`,
          `快照文件：${info.snapshotPath || "未知"}`,
          `状态：${status.phase || "未知"}`,
          `最近成功：${status.lastSuccessAt || "尚无"}`,
          `错误：${status.error || "无"}`,
          `诊断：${(status.diagnosticCodes || []).join("、") || "无"}`,
        ].join("\n");
      }
      renderSessionProbes();
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
    const intervalSelect = byId("setting-interval");
    if (intervalSelect) {
      const minutes = Math.round(settings.refreshIntervalSecs / 60);
      // 当前值不在 mac 允许集合内 (历史配置) 时追加为一项, 避免静默改写为默认 30 分钟
      if (minutes > 0 && !REFRESH_PRESETS.includes(minutes) && !intervalSelect.querySelector(`option[value="${minutes}"]`)) {
        intervalSelect.append(node("option", `${minutes} 分钟`, { value: String(minutes) }));
      }
      intervalSelect.value = String(minutes);
    }
    if (byId("setting-notifications")) byId("setting-notifications").checked = settings.notificationsEnabled;
    if (byId("setting-hotkey")) byId("setting-hotkey").value = settings.hotkey || "";
    if (byId("setting-theme")) byId("setting-theme").value = settings.theme;
    if (byId("setting-usage-consent")) byId("setting-usage-consent").checked = settings.consentVersion === 1;
    if (byId("setting-usage")) byId("setting-usage").checked = settings.usageEnabled !== false;
    const consentState = byId("consent-state");
    if (consentState) {
      consentState.textContent = settings.consentVersion === 1 ? "当前授权有效" : "尚未授权";
      consentState.className = settings.consentVersion === 1 ? "auth-state ok" : "auth-state off";
    }
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
        // 授权版本由授权页的确认/撤销动作即时写入 (对齐 mac 即时语义), 此处沿用现值
        consentVersion: settings.consentVersion ?? 0,
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
    credentialAccounts = accounts || [];
    renderOrders();
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
      for (const account of credentialAccounts) {
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
      if (!credentialAccounts.length) inventory.append(node("p", "尚未配置账号", { class: "hint" }));
    }
  }

  // 套餐名: 取自 artifact (mac C024 起只在设置页行内呈现套餐标签), 按 provider 归一化键归并。
  function providerKeyOfSection(id) {
    if (id === "kimi_coding") return "kimi";
    for (const [key] of providers) {
      if (id === key || id.startsWith(`${key}_`)) return key;
    }
    if (id.startsWith("opencode_go_")) return "opencodeGo";
    return id;
  }
  async function loadPlans() {
    try {
      const panel = await invoke("get_dashboard");
      const plans = {};
      for (const section of panel?.subscription?.sections || []) {
        if (section.plan) plans[providerKeyOfSection(section.id)] = section.plan;
      }
      providerPlans = plans;
      renderOrders();
    } catch { providerPlans = {}; }
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
      const plan = section.plan ? ` · ${section.plan}` : "";
      lines.push(`${section.name}：${section.status === "ok" ? "连接正常" : section.note || section.status || "等待结果"}${plan}`);
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
      await Promise.all([loadSettings(), loadCredentials(), loadPrices(), loadRuntimeInfo(), loadPlans()]);
      await listen("settings-updated", async () => {
        try { await loadSettings(); } catch { message(byId("settings-status"), "设置读取失败"); }
      });
      await listen("dashboard-updated", event => showConnectionResult(event.payload));
    } catch {
      message(byId("settings-status"), "部分配置读取失败，请重新打开设置");
    }
  })();

  window.BruceSettings = { ready, applyTheme, switchCategory };
})();
