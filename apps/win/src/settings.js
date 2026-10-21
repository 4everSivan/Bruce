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
  let currentDashboard = null;
  // 套餐名: 由 artifact 提供 (mac C024 起套餐名只在设置页行内呈现), 经 get_dashboard 取。
  let providerPlans = {};

  const TIME_RANGES = [
    { key: "today", label: "今日" },
    { key: "7d", label: "近 7 天" },
    { key: "30d", label: "近 30 天" },
    { key: "month", label: "本月" },
    { key: "all", label: "全部历史" },
  ];
  // mac AgentUsageWorkbenchView @State timeRange 初值 .sevenDays
  let selectedTimeRange = "7d";

  function svgEl(tag, attrs = {}) {
    const el = document.createElementNS ? document.createElementNS("http://www.w3.org/2000/svg", tag) : document.createElement(tag);
    for (const [k, v] of Object.entries(attrs)) el.setAttribute(k, v);
    return el;
  }

  function catmullRomToBezier(points, height, width) {
    if (!points || points.length === 0) return { pathD: "", areaD: "" };
    if (points.length === 1) {
      const y = points[0].y;
      return {
        pathD: `M 0,${y.toFixed(1)} L ${width},${y.toFixed(1)}`,
        areaD: `M 0,${y.toFixed(1)} L ${width},${y.toFixed(1)} L ${width},${height} L 0,${height} Z`,
      };
    }
    let pathD = `M ${points[0].x.toFixed(1)},${points[0].y.toFixed(1)}`;
    for (let i = 0; i < points.length - 1; i++) {
      const p0 = points[Math.max(i - 1, 0)];
      const p1 = points[i];
      const p2 = points[i + 1];
      const p3 = points[Math.min(i + 2, points.length - 1)];

      const cp1x = p1.x + (p2.x - p0.x) / 6;
      let cp1y = p1.y + (p2.y - p0.y) / 6;
      const cp2x = p2.x - (p3.x - p1.x) / 6;
      let cp2y = p2.y - (p3.y - p1.y) / 6;

      cp1y = Math.max(0, Math.min(height, cp1y));
      cp2y = Math.max(0, Math.min(height, cp2y));

      pathD += ` C ${cp1x.toFixed(1)},${cp1y.toFixed(1)} ${cp2x.toFixed(1)},${cp2y.toFixed(1)} ${p2.x.toFixed(1)},${p2.y.toFixed(1)}`;
    }
    const firstX = points[0].x.toFixed(1);
    const lastX = points[points.length - 1].x.toFixed(1);
    const areaD = `${pathD} L ${lastX},${height} L ${firstX},${height} Z`;
    return { pathD, areaD };
  }

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

  // 界面风格 (Fluent / Nothing) 只作用于看板: mac SettingsView 恒用 SettingsDemoTokens
  // Fluent 平面 token, 不随 interfaceStyle 切换 (C067), 故设置窗口固定 Fluent。
  const applyTheme = () => {
    document.body.classList.remove("theme-nothing");
    document.body.classList.add("theme-fluent");
  };

  // 状态行位于内容区顶部 (mac settingsErrorMessage 同位置); 失败类消息以告警色呈现。
  function message(host, text, tone = "info") {
    if (!host) return;
    host.textContent = text;
    host.dataset.tone = tone;
  }

  // mac 设置即时生效 (C069): 每个控件变更立即保存, 无全局「保存设置」。保存串行排队,
  // 每次都基于后端最新设置合并本次改动, 连续操作不会相互覆盖; 失败时由调用方回滚控件,
  // 并在状态行给出原因 (例如热键冲突)。成功不打扰 (mac 无保存提示)。
  let saveQueue = Promise.resolve();
  function persist(patch, { revert } = {}) {
    const run = async () => {
      const status = byId("settings-status");
      try {
        const updated = { ...await invoke("get_settings"), ...patch };
        validateOverrides(updated.pricingOverrides || {});
        const minutes = Math.round((updated.refreshIntervalSecs || 0) / 60);
        if (!Number.isInteger(minutes) || minutes < 1 || minutes > 1440) throw new Error("刷新间隔须为 1–1440 的整数分钟");
        await invoke("save_settings_command", { settings: updated });
        settings = updated;
        window.dispatchEvent(new CustomEvent("settings-saved", { detail: updated }));
        if (status?.dataset.tone === "warn") message(status, "");
        return true;
      } catch (error) {
        revert?.();
        message(status, `保存失败：${error.message || error}`, "warn");
        return false;
      }
    };
    saveQueue = saveQueue.then(run, run);
    return saveQueue;
  }
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
  // mac paneCaption 与 FluentCard 为兄弟节点: 分组标题位于卡片上方, 卡片内只有行。
  function card(parent, title = null) {
    if (title) parent.append(node("h2", title, { class: "card-caption" }));
    const block = node("section", null, { class: "fluent-card" });
    parent.append(block);
    return block;
  }
  // mac FluentSegmentedPicker 等价: 深底 + 1px 描边 + 6px 圆角, 选中项浅底白字。
  // 原生 <select> 仍是值的唯一载体 (读取/保存/历史值追加逻辑不变), 仅视觉上由分段
  // 按钮代理; select 置于按钮之前, 使行 <label> 的激活目标落在隐藏的 select 上,
  // 点击行标题不会误选第一个分段。
  const segmentRenderers = [];
  function segmented(select, onChange) {
    select.setAttribute("class", "seg-source");
    select.setAttribute("tabindex", "-1");
    select.setAttribute("aria-hidden", "true");
    const group = node("div", null, { class: "fluent-seg", role: "radiogroup" });
    const render = () => {
      group.replaceChildren();
      for (const option of select.querySelectorAll("option")) {
        const value = option.getAttribute("value");
        const isOn = select.value === value;
        const choice = node("button", option.textContent, {
          type: "button", class: isOn ? "seg-opt active" : "seg-opt", role: "radio", "aria-checked": String(isOn),
        });
        choice.addEventListener("click", () => {
          if (select.value === value) return;
          const previous = select.value;
          select.value = value;
          render();
          return onChange?.(value, () => { select.value = previous; render(); });
        });
        group.append(choice);
      }
    };
    render();
    segmentRenderers.push(render);
    const wrap = node("div", null, { class: "seg-wrap" });
    wrap.append(select, group);
    return wrap;
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
        button(btns, `card-up-${id}`, "上移", () => reorder(cardOrder, index, -1, "cardOrder"));
        button(btns, `card-down-${id}`, "下移", () => reorder(cardOrder, index, 1, "cardOrder"));
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
        toggle.addEventListener("change", () => persist({ enabledProviders: checkedProviders() }, {
          revert: () => { toggle.checked = !toggle.checked; },
        }));
        line.append(toggle);
        const btns = node("div", null, { class: "order-btns" });
        button(btns, `provider-up-${id}`, "上移", () => reorder(providerOrder, index, -1, "providerOrder"));
        button(btns, `provider-down-${id}`, "下移", () => reorder(providerOrder, index, 1, "providerOrder"));
        line.append(btns);
        host.append(line);
      });
    }
  }

  function checkedProviders() {
    return [...(byId("setting-providers")?.querySelectorAll("input") || [])].filter(v => v.checked).map(v => v.dataset.provider);
  }

  // 上移 / 下移即时生效; 保存失败时恢复原顺序
  function reorder(order, index, delta, key) {
    const before = [...order];
    move(order, index, delta);
    renderOrders();
    return persist({ [key]: [...order] }, {
      revert: () => { order.splice(0, order.length, ...before); renderOrders(); },
    });
  }

  // MARK: - 分类面板构建

  function buildGeneral(host) {
    host.replaceChildren();
    // mac generalPane 首卡无分组标题; 行序: 界面风格 → 刷新间隔 → 系统通知 → 版本
    // (配色模式 / 钥匙串 / 外部 CLI 来源为 mac 独有能力, Windows 恒深色且无钥匙串)。
    const c1 = card(host);
    const theme = node("select", null, { id: "setting-theme" });
    theme.append(node("option", "经典", { value: "fluent" }), node("option", "Nothing", { value: "nothing" }));
    row(c1, "界面风格", segmented(theme, (value, revert) => persist({ theme: value }, { revert })),
      "经典为深色材质面板; Nothing 为纯色平面风格, 无模糊无玻璃 (Windows 恒深色)");
    // 刷新间隔对齐 mac 允许集合 (5/15/30/60 分钟); 当前值不在集合内时由 loadSettings
    // 追加为一项, 避免静默改写用户既有配置。
    const interval = node("select", null, { id: "setting-interval" });
    for (const minutes of REFRESH_PRESETS) interval.append(node("option", `${minutes} 分钟`, { value: String(minutes) }));
    row(c1, "刷新间隔", segmented(interval, (value, revert) => persist({ refreshIntervalSecs: Number(value) * 60 }, { revert })),
      "已授权模块的自动采集周期，变更后立即重新计时");
    // mac: 开关旁以「已开启 / 已关闭」状态字呈现当前值
    const notifyWrap = node("div", null, { class: "toggle-with-state" });
    const notify = input("setting-notifications", "checkbox");
    notifyWrap.append(notify, node("span", "", { id: "setting-notifications-state", class: "toggle-state" }));
    notify.addEventListener("change", () => {
      syncToggleState("setting-notifications");
      return persist({ notificationsEnabled: notify.checked }, {
        revert: () => { notify.checked = !notify.checked; syncToggleState("setting-notifications"); },
      });
    });
    row(c1, "系统通知", notifyWrap, "预警与额度提醒; 关闭后 Bruce 不会投递通知");
    row(c1, "版本", node("span", "—", { id: "setting-version", class: "row-value" }));

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
      return saveHotkey();
    });
    row(card(host, "全局快捷键"), "唤出看板", hotkeyWrap, "唤出或隐藏置顶看板; 留空关闭全局快捷键");

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
      return saveHotkey();
    });
    // 手动键入的热键在失焦 / 回车时生效
    byId("setting-hotkey")?.addEventListener("change", () => saveHotkey());

    const c2 = card(host, "看板卡片顺序");
    c2.append(node("p", "点击上移 / 下移调整置顶面板各卡片的堆叠顺序, 即时生效; 看板中收起的卡片也可直接拖拽排序。", { class: "hint" }));
    c2.append(node("div", null, { id: "setting-card-order", class: "order-list" }));
  }

  // 热键即时生效; 注册失败 (如被其他程序占用) 时回滚为已生效的热键并提示原因。
  function saveHotkey() {
    const field = byId("setting-hotkey");
    if (!field) return Promise.resolve();
    const hotkey = field.value.trim();
    if (hotkey === (settings.hotkey || "")) return Promise.resolve();
    return persist({ hotkey }, { revert: () => { field.value = settings.hotkey || ""; } });
  }

  function syncToggleState(id) {
    const box = byId(id), state = byId(`${id}-state`);
    if (!box || !state) return;
    state.textContent = box.checked ? "已开启" : "已关闭";
    state.className = box.checked ? "toggle-state on" : "toggle-state";
  }

  function buildAgentUsage(host) {
    host.replaceChildren();

    // T07 工作台容器
    const workbenchRoot = node("div", null, { id: "workbench-root" });
    host.append(workbenchRoot);

    // 1. 会话来源与采集探针 (对齐 mac AgentUsageWorkbenchView.sessionProbeFooterCard)
    const cSources = card(host, "会话来源与采集探针");
    row(cSources, "Rust Collector", node("span", "可用", { class: "status-tag ok" }), "扫描本机会话目录并计算 Token 增量缓存与指纹");

    const probeList = node("div", null, { id: "session-probes" });
    cSources.append(probeList);

    const act = actions(cSources);
    act.append(node("span", "所有会话仅在本机分析，绝不上报远程服务器", { class: "card-actions-note" }));
    button(act, "session-rescan", "重新检查", async () => {
      try {
        message(byId("settings-status"), "正在重新扫描本机会话…");
        await invoke("refresh_now");
        await loadRuntimeInfo();
        await loadPlans();
        message(byId("settings-status"), "会话扫描已刷新");
      } catch (error) {
        message(byId("settings-status"), `扫描失败: ${error.message || error}`);
      }
    });

    // 2. Agent 会话采集授权 (对齐 mac)
    const cUsage = card(host, "Agent 会话采集");
    const usageToggle = input("setting-usage", "checkbox");
    usageToggle.addEventListener("change", () => persist({ usageEnabled: usageToggle.checked }, {
      revert: () => { usageToggle.checked = !usageToggle.checked; },
    }));
    row(cUsage, "读取本机 Agent 会话用量", usageToggle, "开启后在本机读取会话记录，计算 Token 用量与费用。");
    const summary = node("div", null, { class: "hint-box" });
    summary.append(node("p", "授权后应用将：", { class: "hint-title" }));
    const ul = node("ul", null, { class: "hint-list" });
    ul.append(node("li", "只读扫描本机 Agent 会话目录（如 Claude Code, Codex, Kimi, OpenCode 等）与 CC Switch 数据库；"));
    ul.append(node("li", "在用户本机闭环计算 Token 总量与估算费用，无自有云端服务端；"));
    ul.append(node("li", "严格执行只读模式（mode=ro），绝不修改、删除或上传任何外部会话日志。"));
    summary.append(ul);
    cUsage.append(summary);

    renderAgentUsageWorkbench();
    renderSessionProbes();
  }

  // MARK: - Agent 用量工作台 (C070, 对齐 mac AgentUsageWorkbenchView 及其卡片)
  //
  // 数值全部来自 get_usage_analytics (Rust viewmodel analytics, 与 mac golden 逐字段对拍);
  // 前端只负责呈现与交互状态, 不做任何汇总或估算。

  // Rust/C `{:.N}` 按精确二进制值舍入、平局取偶; JS toFixed 平局进位。
  // 只在恰为平局时改取偶, 使悬停数值文案与 mac 逐字符一致。
  function fixedEven(value, digits) {
    const rounded = value.toFixed(digits);
    const [whole, fraction = ""] = value.toFixed(20).split(".");
    const tail = fraction.slice(digits);
    if (!/^50*$/.test(tail)) return rounded;
    const kept = fraction.slice(0, digits);
    const lastDigit = Number((digits ? kept : whole).slice(-1));
    return lastDigit % 2 === 0 ? (digits ? `${whole}.${kept}` : whole) : rounded;
  }

  // mac PanelFormat.tokenCount / Rust format::token_count: K/M 一位小数、B 两位, 去尾零。
  function tokenCount(value) {
    const trim = text => text.replace(/\.?0+$/, "");
    if (value < 1000) return String(value);
    if (value < 1_000_000) return `${trim(fixedEven(value / 1000, 1))}K`;
    if (value < 1_000_000_000) return `${trim(fixedEven(value / 1_000_000, 1))}M`;
    return `${trim(fixedEven(value / 1_000_000_000, 2))}B`;
  }

  const percentText = value => `${fixedEven(value, 1)}%`;

  const TOKEN_TYPE_SERIES = [
    { key: "type_input", name: "输入 Prompt", color: "#4C9CFF", short: "输入" },
    { key: "type_output", name: "输出 Output", color: "#A855F7", short: "输出" },
    { key: "type_cache", name: "缓存命中 Read", color: "#10B981", short: "缓存" },
  ];
  const CHART_MODES = [["agent", "Agent"], ["model", "模型"], ["tokenType", "Token 构成"], ["cost", "费用"]];

  const workbench = {
    snapshot: null,
    seq: 0,
    chartMode: "agent",
    chartType: "line",
    selectedIndex: null,
    mergedModels: true,
    expandedModels: new Set(),
    expandedAgents: new Set(),
    hoveredHour: null,
  };

  function chip(text, color, cls = "wb-chip") {
    return node("span", text, { class: cls, style: `--chip: ${color};` });
  }

  // 「**粗体**」片段 (峰值 / 均值摘要) -> 文本 + <strong>
  function markdownLine(text, cls) {
    const line = node("span", null, { class: cls });
    String(text).split("**").forEach((part, index) => {
      if (part) line.append(index % 2 ? node("strong", part) : part);
    });
    return line;
  }

  function segButtons(options, value, onPick, cls = "") {
    const group = node("div", null, { class: `fluent-seg ${cls}`.trim(), role: "radiogroup" });
    for (const [key, label] of options) {
      const isOn = key === value;
      const choice = node("button", label, {
        type: "button", class: isOn ? "seg-opt active" : "seg-opt", role: "radio", "aria-checked": String(isOn),
      });
      choice.addEventListener("click", () => (isOn ? undefined : onPick(key)));
      group.append(choice);
    }
    return group;
  }

  function cardHeader(title, badge, badgeColor, sub, trailing = []) {
    const head = node("div", null, { class: "wb-head" });
    const meta = node("div", null, { class: "wb-head-meta" });
    const line = node("div", null, { class: "wb-title-line" });
    line.append(node("span", title, { class: "wb-title" }));
    if (badge) line.append(chip(badge, badgeColor, "wb-chip wb-chip-lg"));
    meta.append(line, node("span", sub, { class: "wb-sub" }));
    head.append(meta, node("span", null, { class: "wb-spacer" }), ...trailing);
    return head;
  }

  // mac chevron.down.circle / chevron.up.circle.fill
  function expandButton(expanded, help, onToggle) {
    const toggle = node("button", null, {
      type: "button", class: expanded ? "wb-expand on" : "wb-expand", title: help, "aria-label": help, "aria-expanded": String(expanded),
    });
    const glyph = svgEl("svg", { viewBox: "0 0 16 16", "aria-hidden": "true" });
    glyph.append(svgEl("circle", { cx: "8", cy: "8", r: "6.75", class: "wb-expand-ring" }));
    glyph.append(svgEl("path", { d: expanded ? "M5.2 9.4 8 6.6l2.8 2.8" : "M5.2 6.6 8 9.4l2.8-2.8", class: "wb-expand-chevron" }));
    toggle.append(glyph);
    toggle.addEventListener("click", onToggle);
    return toggle;
  }

  async function renderAgentUsageWorkbench() {
    const root = byId("workbench-root");
    if (!root) return;
    const seq = ++workbench.seq;
    let snapshot = null;
    try {
      snapshot = await invoke("get_usage_analytics", { range: selectedTimeRange });
    } catch (error) {
      message(byId("settings-status"), `用量分析读取失败：${error.message || error}`, "warn");
    }
    // 期间又切换了范围或收到新快照: 丢弃过期结果
    if (seq !== workbench.seq) return;
    workbench.snapshot = snapshot;
    workbench.selectedIndex = null;
    drawWorkbench();
  }

  function drawWorkbench() {
    const root = byId("workbench-root");
    if (!root) return;
    const snapshot = workbench.snapshot;
    root.replaceChildren(workbenchToolbar());
    if (!snapshot) return;
    const slots = ["timeline", "models", "agents", "composition"].map(name => node("div", null, { id: `wb-${name}`, class: "wb-slot" }));
    root.append(kpiTiles(snapshot.kpi), ...slots);
    drawTimeline();
    drawModels();
    drawAgents();
    drawComposition();
  }

  function fillSlot(name, content) {
    const slot = byId(`wb-${name}`);
    if (slot) slot.replaceChildren(content);
  }

  function workbenchToolbar() {
    const bar = node("div", null, { class: "wb-toolbar" });
    bar.append(segButtons(TIME_RANGES.map(range => [range.key, range.label]), selectedTimeRange, key => {
      selectedTimeRange = key;
      return renderAgentUsageWorkbench();
    }, "time-range-picker"));
    bar.append(node("span", null, { class: "wb-spacer" }));
    const csv = button(bar, "workbench-export-csv", "导出 CSV 账单", () => runExport("export_workbench_csv", "CSV 账单", "csv", {
      // mac Date.now.formatted(.iso8601.year().month().day()) 为 UTC 日期
      defaultName: `bruce_agent_usage_${new Date().toISOString().slice(0, 10)}.csv`,
      args: { range: selectedTimeRange },
    }));
    csv.setAttribute("title", "导出归一化模型与 Token 账单 CSV");
    const json = button(bar, "workbench-export-json", "导出 JSON 明细", () => runExport("export_workbench_json", "JSON 明细", "json", {
      defaultName: "bruce_agent_usage_artifact.json",
    }));
    json.setAttribute("title", "导出完整会话用量 JSON 原始结构");
    return bar;
  }

  // MARK: 4 格核心 KPI 磁贴

  function kpiTiles(kpi) {
    const grid = node("div", null, { class: "kpi-tiles-grid", id: "kpi-tiles" });
    const rangeLabel = TIME_RANGES.find(range => range.key === selectedTimeRange)?.label || "";
    const tiles = [
      ["总 Token", kpi.totalTokensText, `${kpi.equivalentMText} Tokens`, rangeLabel, "var(--settings-accent)"],
      ["费用", kpi.costText, kpi.averageCostPerMillionText, kpi.costTagText, "var(--ok)"],
      ["缓存收益", kpi.cacheHitRateText, kpi.cacheSavedCostText, "已省", "#10B981"],
      ["活跃 Agent", `${kpi.activeAgentsCount} 个`, kpi.topAgentText, "全域", "#8B5CF6"],
    ];
    for (const [title, value, sub, tag, color] of tiles) {
      const tile = node("div", null, { class: "kpi-tile" });
      const head = node("div", null, { class: "kpi-head" });
      head.append(node("span", title, { class: "kpi-label" }), chip(tag, color));
      tile.append(head, node("div", value, { class: "kpi-value" }), node("div", sub, { class: "kpi-sub", title: sub }));
      grid.append(tile);
    }
    return grid;
  }

  // MARK: 时序趋势 (mac TimelineChartCard)

  function chartSeries(snapshot) {
    switch (workbench.chartMode) {
      case "agent":
        return snapshot.agents.map(agent => ({ key: agent.agentId, name: agent.name, color: agent.colorHex, value: point => point.seriesValues[agent.agentId] || 0 }));
      case "model":
        return snapshot.models.slice(0, 5).map(model => ({ key: `model_${model.canonicalKey}`, name: model.displayName, color: model.colorHex, value: point => point.seriesValues[`model_${model.canonicalKey}`] || 0 }));
      case "tokenType":
        return TOKEN_TYPE_SERIES.map(type => ({ ...type, value: point => point.seriesValues[type.key] || 0 }));
      default:
        return [{ key: "cost", name: "折算总费用 ($)", color: "#10B981", value: point => point.costUsd }];
    }
  }

  // 纵轴刻度: 约 4 段的「整」步长 (1/2/2.5/5 × 10^n)
  function niceTicks(max) {
    if (!(max > 0)) return { top: 1, ticks: [0] };
    const raw = max / 4;
    const magnitude = 10 ** Math.floor(Math.log10(raw));
    const step = [1, 2, 2.5, 5, 10].map(factor => factor * magnitude).find(value => value >= raw);
    const top = Math.ceil(max / step) * step;
    const ticks = [];
    for (let index = 0; index * step <= top + step / 2; index += 1) ticks.push(index * step);
    return { top, ticks };
  }

  // mac yAxisValue: 费用 "$x.xx"; token "x.xM" / "xK" / 整数
  function axisLabel(value) {
    if (workbench.chartMode === "cost") return `$${fixedEven(value, 2)}`;
    const whole = Math.trunc(value);
    if (whole >= 1_000_000) return `${fixedEven(whole / 1_000_000, 1)}M`;
    if (whole >= 1_000) return `${fixedEven(whole / 1_000, 0)}K`;
    return String(whole);
  }

  function drawTimeline() {
    const snapshot = workbench.snapshot;
    const timeline = snapshot.timeline;
    const series = chartSeries(snapshot);
    const card = node("section", null, { class: "fluent-card wb-card workbench-chart-card" });
    card.append(cardHeader("时序趋势", null, null, "多维度用量走势与峰值下钻分析", [
      segButtons([["line", "折线"], ["area", "面积"]], workbench.chartType, type => { workbench.chartType = type; drawTimeline(); }, "chart-type-picker"),
      segButtons(CHART_MODES, workbench.chartMode, mode => { workbench.chartMode = mode; workbench.selectedIndex = null; drawTimeline(); }, "chart-dim-tabs"),
    ]));
    const legend = node("div", null, { class: "wb-legend" });
    for (const item of series) {
      const entry = node("span", null, { class: "wb-legend-item" });
      entry.append(node("i", null, { class: "wb-dot", style: `background: ${item.color};` }), item.name);
      legend.append(entry);
    }
    card.append(legend);
    if (!timeline.points.length || !series.length) {
      const empty = node("div", null, { class: "wb-chart-empty" });
      empty.append(node("span", "⌁", { class: "wb-chart-empty-icon" }), node("span", "当前时间跨度暂无活跃用量点"));
      card.append(empty);
    } else {
      card.append(timelineChart(timeline.points, series));
    }
    card.append(node("div", null, { class: "wb-summary", id: "wb-timeline-summary" }));
    fillSlot("timeline", card);
    drawTimelineSummary();
  }

  function timelineChart(points, series) {
    const width = 1000;
    const height = 200;
    const values = points.flatMap(point => series.map(item => item.value(point)));
    const { top, ticks } = niceTicks(Math.max(0, ...values));
    // Swift Charts 对字符串 x 值用分带刻度: 点位于各带中心, 首末点不贴边
    const xAt = index => ((index + 0.5) / points.length) * width;
    const yAt = value => height - (value / top) * height;

    const chart = node("div", null, { class: "wb-chart" });
    const yAxis = node("div", null, { class: "wb-chart-y" });
    for (const tick of ticks) yAxis.append(node("span", axisLabel(tick), { style: `bottom: ${(tick / top) * 100}%;` }));
    const plot = node("div", null, { class: "wb-chart-plot" });
    const svg = svgEl("svg", { viewBox: `0 0 ${width} ${height}`, preserveAspectRatio: "none" });
    for (const tick of ticks) {
      svg.append(svgEl("line", { x1: 0, x2: width, y1: yAt(tick), y2: yAt(tick), class: "wb-grid", "vector-effect": "non-scaling-stroke" }));
    }
    const defs = svgEl("defs");
    svg.append(defs);
    series.forEach((item, index) => {
      const { pathD, areaD } = catmullRomToBezier(points.map((point, at) => ({ x: xAt(at), y: yAt(item.value(point)) })), height, width);
      if (workbench.chartType === "area") {
        const gradient = svgEl("linearGradient", { id: `wb-grad-${index}`, x1: "0", y1: "0", x2: "0", y2: "1" });
        gradient.append(svgEl("stop", { offset: "0%", "stop-color": item.color, "stop-opacity": "0.35" }));
        gradient.append(svgEl("stop", { offset: "100%", "stop-color": item.color, "stop-opacity": "0.04" }));
        defs.append(gradient);
        svg.append(svgEl("path", { d: areaD, fill: `url(#wb-grad-${index})` }));
      }
      svg.append(svgEl("path", { d: pathD, fill: "none", stroke: item.color, "stroke-width": "2", "vector-effect": "non-scaling-stroke", class: "wb-line" }));
    });
    const rule = svgEl("line", { id: "wb-rule", x1: 0, x2: 0, y1: 0, y2: height, class: "wb-rule hidden", "vector-effect": "non-scaling-stroke" });
    svg.append(rule);
    plot.append(svg);
    // mac 在 ≤14 个点时画点标记; HTML 圆点避免 preserveAspectRatio=none 把圆拉成椭圆
    if (points.length <= 14) {
      series.forEach(item => points.forEach((point, index) => {
        plot.append(node("i", null, {
          class: "wb-point",
          style: `left: ${(xAt(index) / width) * 100}%; bottom: ${(item.value(point) / top) * 100}%; background: ${item.color};`,
        }));
      }));
    }
    // 悬停选点 (mac chartXSelection): 就近点, 移出清除
    const select = index => {
      if (index === workbench.selectedIndex) return;
      workbench.selectedIndex = index;
      rule.setAttribute("class", index == null ? "wb-rule hidden" : "wb-rule");
      if (index != null) {
        rule.setAttribute("x1", xAt(index));
        rule.setAttribute("x2", xAt(index));
      }
      drawTimelineSummary();
    };
    plot.addEventListener("mousemove", event => {
      const rect = plot.getBoundingClientRect?.();
      if (!rect || !rect.width) return;
      const band = Math.floor(((event.clientX - rect.left) / rect.width) * points.length);
      select(Math.min(points.length - 1, Math.max(0, band)));
    });
    plot.addEventListener("mouseleave", () => select(null));

    const xAxis = node("div", null, { class: "wb-chart-x" });
    const labelCount = Math.min(points.length, 8);
    const labelIndexes = new Set(Array.from({ length: labelCount }, (_, at) => (labelCount > 1 ? Math.round((at * (points.length - 1)) / (labelCount - 1)) : 0)));
    for (const index of labelIndexes) {
      xAxis.append(node("span", points[index].label, { style: `left: ${(xAt(index) / width) * 100}%;` }));
    }
    chart.append(yAxis, plot, xAxis);
    return chart;
  }

  function drawTimelineSummary() {
    const host = byId("wb-timeline-summary");
    const snapshot = workbench.snapshot;
    if (!host || !snapshot) return;
    host.replaceChildren();
    const point = workbench.selectedIndex == null ? null : snapshot.timeline.points[workbench.selectedIndex];
    if (!point) {
      host.append(
        markdownLine(snapshot.timeline.peakSummary, "wb-summary-peak"),
        node("span", null, { class: "wb-spacer" }),
        markdownLine(snapshot.timeline.avgSummary, "wb-summary-avg"),
      );
      return;
    }
    host.append(node("span", `📍 ${point.label}`, { class: "wb-summary-label" }));
    if (workbench.chartMode === "cost") {
      host.append(node("span", `$${fixedEven(point.costUsd, 4)}`, { class: "wb-summary-value cost" }));
      return;
    }
    host.append(node("span", `${tokenCount(point.totalTokens)} Tokens`, { class: "wb-summary-value" }));
    const parts = workbench.chartMode === "agent"
      ? snapshot.agents.slice(0, 3).map(agent => [agent.name, point.seriesValues[agent.agentId], agent.colorHex])
      : workbench.chartMode === "model"
        ? snapshot.models.slice(0, 3).map(model => [model.displayName, point.seriesValues[`model_${model.canonicalKey}`], model.colorHex])
        : TOKEN_TYPE_SERIES.map(type => [type.short, point.seriesValues[type.key], type.color]);
    for (const [name, value, color] of parts) {
      if (value > 0) host.append(node("span", `${name}: ${tokenCount(value)}`, { class: "wb-summary-part", style: `color: ${color};` }));
    }
  }

  // MARK: 模型分布 (mac CanonicalModelAnalyticsCard)

  function drawModels() {
    const models = workbench.snapshot.models;
    const sourceCount = models.reduce((sum, model) => sum + Math.max(1, model.sources.length), 0);
    const card = node("section", null, { class: "fluent-card wb-card canonical-card" });
    card.append(cardHeader("模型分布", `${models.length} 款主模型 · ${sourceCount} 个渠道`, "var(--ok)", "自动归并同类模型，支持展开查看各渠道细分贡献", [
      segButtons([["merged", "合并视图"], ["raw", "原始渠道"]], workbench.mergedModels ? "merged" : "raw", view => { workbench.mergedModels = view === "merged"; drawModels(); }),
    ]));
    const list = node("div", null, { class: "wb-list" });
    if (!models.length) {
      list.append(node("div", "暂无模型消耗数据", { class: "wb-empty" }));
    } else if (workbench.mergedModels) {
      for (const model of models) list.append(modelRow(model));
    } else {
      const sources = models.flatMap(model => model.sources).sort((left, right) => right.tokens - left.tokens);
      sources.forEach((source, index) => {
        const item = node("div", null, { class: "wb-row wb-raw-row" });
        const meta = node("div", null, { class: "wb-row-meta" });
        meta.append(node("span", source.rawModelName, { class: "wb-mono-name" }), node("span", `来源 Agent: ${source.agentDisplayName}`, { class: "wb-row-sub" }));
        item.append(node("span", `#${index + 1}`, { class: "wb-rank" }), meta, node("span", null, { class: "wb-spacer" }), node("span", source.tokensText, { class: "wb-tokens" }));
        if (source.costText) item.append(node("span", source.costText, { class: "wb-cost" }));
        list.append(item);
      });
    }
    card.append(list);
    fillSlot("models", card);
  }

  function modelRow(model) {
    const expanded = workbench.expandedModels.has(model.canonicalKey);
    const multi = model.sources.length > 1;
    const group = node("div", null, { class: "canonical-row" });
    const line = node("div", null, { class: "wb-row" });
    const meta = node("div", null, { class: "wb-row-meta" });
    const title = node("div", null, { class: "wb-name-line" });
    title.append(node("span", model.displayName, { class: "wb-name" }), node("span", model.vendor, { class: "wb-tag" }));
    if (multi) title.append(chip(`合并 ${model.sources.length} 个渠道`, "var(--settings-accent)"));
    meta.append(title, node("span", `规范键: ${model.canonicalKey}`, { class: "wb-row-sub wb-mono" }));
    const figures = node("div", null, { class: "wb-figures" });
    const shareLine = node("div", null, { class: "wb-share-line" });
    const bar = node("span", null, { class: "wb-share-bar" });
    bar.append(node("i", null, { style: `width: max(2px, ${Math.min(100, Math.max(0, model.sharePercent))}%); background: ${model.colorHex};` }));
    shareLine.append(bar, node("span", percentText(model.sharePercent), { class: "wb-share" }));
    const amountLine = node("div", null, { class: "wb-amount-line" });
    amountLine.append(node("span", model.totalTokensText, { class: "wb-tokens" }));
    if (model.costText) amountLine.append(node("span", model.costText, { class: "wb-cost" }));
    figures.append(shareLine, amountLine);
    line.append(node("i", null, { class: "wb-dot wb-dot-lg", style: `background: ${model.colorHex};` }), meta, node("span", null, { class: "wb-spacer" }), figures);
    line.append(multi
      ? expandButton(expanded, expanded ? "收起渠道明细" : `展开 ${model.sources.length} 个渠道明细`, () => {
        workbench.expandedModels[expanded ? "delete" : "add"](model.canonicalKey);
        drawModels();
      })
      : node("span", null, { class: "wb-expand-placeholder" }));
    group.append(line);
    if (expanded && multi) {
      const tree = node("div", null, { class: "wb-sources" });
      for (const source of model.sources) {
        const item = node("div", null, { class: "wb-source" });
        item.append(
          node("span", "↳", { class: "wb-source-arrow" }),
          node("span", source.rawModelName, { class: "wb-mono-name" }),
          node("span", source.agentDisplayName, { class: "wb-tag" }),
          node("span", null, { class: "wb-spacer" }),
          node("span", `${source.tokensText} (${percentText(source.shareOfModelPercent)})`, { class: "wb-source-share" }),
        );
        if (source.costText) item.append(node("span", source.costText, { class: "wb-cost" }));
        tree.append(item);
      }
      group.append(tree);
    }
    return group;
  }

  // MARK: Agent 表现 (mac AgentComparisonMatrixCard)

  function drawAgents() {
    const agents = workbench.snapshot.agents;
    const card = node("section", null, { class: "fluent-card wb-card agent-matrix-card" });
    card.append(cardHeader("Agent 表现", `${agents.length} 个活跃`, "var(--settings-accent)", "透视各 Agent 用量占比、Token 结构与关联工程"));
    const list = node("div", null, { class: "wb-list" });
    if (!agents.length) list.append(node("div", "暂无活跃 Agent 消耗数据", { class: "wb-empty" }));
    for (const agent of agents) list.append(agentRow(agent));
    card.append(list);
    fillSlot("agents", card);
  }

  function agentRow(agent) {
    const expanded = workbench.expandedAgents.has(agent.agentId);
    const hasDetails = agent.topProjects.length > 0 || agent.topModels.length > 0;
    const group = node("div", null, { class: "wb-agent" });
    const line = node("div", null, { class: "wb-row" });
    const meta = node("div", null, { class: "wb-row-meta" });
    const title = node("div", null, { class: "wb-name-line" });
    title.append(node("span", agent.name, { class: "wb-name" }), node("span", agent.status, { class: "wb-tag strong" }));
    meta.append(title);
    if (agent.note) meta.append(node("span", agent.note, { class: "wb-row-sub" }));
    // 构成比例条: 输入 (含缓存写入) 蓝 + 输出紫 + 缓存读取绿, 三段之和 = 总量
    const total = Math.max(1, agent.inputTokens + agent.outputTokens + agent.cacheReadTokens);
    const stack = node("span", null, { class: "wb-stack" });
    for (const [value, color] of [[agent.inputTokens, "#4C9CFF"], [agent.outputTokens, "#A855F7"], [agent.cacheReadTokens, "#10B981"]]) {
      stack.append(node("i", null, { style: `width: max(1px, ${(value / total) * 100}%); background: ${color};` }));
    }
    const figures = node("div", null, { class: "wb-figures" });
    const amounts = node("div", null, { class: "wb-amount-line" });
    amounts.append(
      node("span", agent.totalTokensText, { class: "wb-tokens" }),
      node("span", agent.costText, { class: "wb-cost" }),
      node("span", percentText(agent.sharePercent), { class: "wb-share wb-share-narrow" }),
    );
    figures.append(stack, amounts);
    line.append(node("i", null, { class: "wb-dot wb-dot-lg", style: `background: ${agent.colorHex};` }), meta, node("span", null, { class: "wb-spacer" }), figures);
    line.append(hasDetails
      ? expandButton(expanded, expanded ? "收起关联工程与模型" : "展开关联工程与模型下钻", () => {
        workbench.expandedAgents[expanded ? "delete" : "add"](agent.agentId);
        drawAgents();
      })
      : node("span", null, { class: "wb-expand-placeholder" }));
    group.append(line);
    if (expanded && hasDetails) {
      const detail = node("div", null, { class: "wb-agent-detail" });
      if (agent.topProjects.length) {
        const row = node("div", null, { class: "wb-detail-row" });
        const tags = node("div", null, { class: "wb-flow" });
        for (const project of agent.topProjects.slice(0, 4)) {
          const tag = node("span", null, { class: "wb-flow-tag" });
          tag.append(node("span", project.name, { class: "wb-mono-name" }), node("span", `(${tokenCount(project.total)})`, { class: "wb-flow-dim" }));
          tags.append(tag);
        }
        row.append(node("span", "📁 今日 Top 工程:", { class: "wb-detail-label" }), tags);
        detail.append(row);
      }
      if (agent.topModels.length) {
        const row = node("div", null, { class: "wb-detail-row" });
        const tags = node("div", null, { class: "wb-flow" });
        for (const model of agent.topModels.slice(0, 3)) {
          const tag = node("span", null, { class: "wb-flow-tag" });
          tag.append(node("i", null, { class: "wb-dot wb-dot-sm", style: `background: ${model.colorHex};` }), node("span", model.displayName, { class: "wb-flow-name" }), node("span", `(${model.totalTokensText})`, { class: "wb-flow-dim" }));
          tags.append(tag);
        }
        row.append(node("span", "⚡️ 主要消耗模型:", { class: "wb-detail-label" }), tags);
        detail.append(row);
      }
      group.append(detail);
    }
    return group;
  }

  // MARK: Token 构成与今日时段 (mac TokenCompositionCard)

  function drawComposition() {
    const { kpi, todayHourlyTokens: hours } = workbench.snapshot;
    const card = node("section", null, { class: "fluent-card wb-card composition-card" });
    card.append(cardHeader("Token 构成与时段", "Prompt Cache 专项分析", "var(--ok)", "所选范围的输入、输出与缓存读写结构，以及今日 24 小时活跃分布"));
    const grid = node("div", null, { class: "composition-grid" });
    const quadrants = [
      ["Prompt Input", "用户提示词与工程上下文", kpi.inputTokensText, "输入基础", "#4C9CFF"],
      ["Model Output", "大模型生成与代码产出", kpi.outputTokensText, "高单价", "#A855F7"],
      ["Prompt Cache Read", `命中率 ${kpi.cacheHitRateText} · ${kpi.cacheSavedCostText}`, kpi.cacheReadTokensText, "已节省", "#10B981"],
      ["Cache Creation", "写入提示缓存的上下文", kpi.cacheCreationTokensText, "写入", "#F59E0B"],
    ];
    for (const [title, sub, value, tag, color] of quadrants) {
      const box = node("div", null, { class: "composition-box", style: `--chip: ${color};` });
      const head = node("div", null, { class: "kpi-head" });
      head.append(node("span", title, { class: "composition-box-label" }), chip(tag, color));
      box.append(head, node("div", value, { class: "composition-box-value" }), node("div", sub, { class: "composition-box-sub", title: sub }));
      grid.append(box);
    }
    card.append(grid, node("div", null, { class: "wb-divider" }));

    const heat = node("div", null, { class: "wb-hours" });
    const head = node("div", null, { class: "wb-hours-head" });
    const probe = node("span", null, { class: "wb-hours-probe", id: "wb-hours-probe" });
    head.append(node("span", "今日 24 小时交互密度 (00:00 - 23:00)", { class: "wb-hours-title" }), node("span", null, { class: "wb-spacer" }), probe);
    const peak = Math.max(1, ...hours);
    const cells = node("div", null, { class: "wb-hour-cells" });
    const showProbe = () => {
      const hour = workbench.hoveredHour;
      probe.textContent = hour == null ? "鼠标悬停查看单时段用量" : `📍 ${String(hour).padStart(2, "0")}:00 : ${tokenCount(hours[hour] || 0)} Tokens`;
      probe.className = hour == null ? "wb-hours-probe" : "wb-hours-probe on";
    };
    hours.forEach((value, hour) => {
      const cell = node("i", null, {
        class: value ? "wb-hour" : "wb-hour zero",
        // mac accent.opacity(0.25 + 0.75 × 强度): 只作用于填充, 悬停描边不随之变淡
        style: value ? `background: color-mix(in srgb, var(--settings-accent) ${(25 + 75 * (value / peak)).toFixed(1)}%, transparent);` : "",
        title: `${String(hour).padStart(2, "0")}:00`,
      });
      cell.addEventListener("mouseenter", () => { workbench.hoveredHour = hour; showProbe(); });
      cell.addEventListener("mouseleave", () => { workbench.hoveredHour = null; showProbe(); });
      cells.append(cell);
    });
    const ticks = node("div", null, { class: "wb-hour-ticks" });
    for (const label of ["00:00", "04:00", "08:00", "12:00", "16:00", "20:00", "23:00"]) ticks.append(node("span", label));
    heat.append(head, cells, ticks);
    card.append(heat);
    fillSlot("composition", card);
    showProbe();
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

  // MARK: - 模型计费 (对齐 mac ModelPricingSettingsView)

  const PRICING_FILTERS = ["全部", "已有用量", "已校准"];
  let pricingFilter = "全部";
  let pricingQuery = "";
  let pricingEditing = null;
  let currentModelPrices = [];

  function numberOr(value, fallback) {
    return Number.isFinite(value) ? value : fallback;
  }

  // 有效定价行: 行集与展示元数据来自 mac 目录镜像 (BuiltinModelPricingCatalog),
  // 保持目录顺序 (mac 的分组顺序: Kimi → OpenAI → DeepSeek → 智谱 → StepFun → 混元 →
  // Anthropic → xAI); 用户新增的覆盖项 (不在目录内) 追加在末尾。
  // 今日折算与 mac 同式: 用量 × (输入+输出)/2 / 1e6
  function effectivePricingRows() {
    const overrides = settings.pricingOverrides || {};
    const usage = new Map((currentRuntimeInfo?.modelUsage || []).map((row) => [String(row.model).toLowerCase(), row.tokens || 0]));
    const catalog = new Map(currentModelPrices.map((entry) => [entry.model, entry]));
    const extra = Object.keys(overrides).filter((key) => !catalog.has(key)).sort((a, b) => a.localeCompare(b));
    const keys = [...currentModelPrices.map((entry) => entry.model), ...extra];
    return keys.map((key) => {
      const base = catalog.get(key) || {};
      const over = Object.prototype.hasOwnProperty.call(overrides, key) ? overrides[key] || {} : null;
      const inputPrice = numberOr(over?.inputPricePerMillion, numberOr(base.inputPricePerMillion, 0));
      const outputPrice = numberOr(over?.outputPricePerMillion, numberOr(base.outputPricePerMillion, 0));
      const cachePrice = numberOr(over?.cacheReadPricePerMillion, base.cacheReadPricePerMillion ?? null);
      const tokens = usage.get(key.toLowerCase()) || 0;
      const cost = tokens > 0 ? (tokens * (inputPrice + outputPrice)) / 2 / 1_000_000 : null;
      return {
        key,
        displayName: base.displayName || key,
        vendor: base.vendor || "",
        inputPrice,
        outputPrice,
        cachePrice,
        tokens,
        cost,
        isCustom: Boolean(over),
        note: over?.note || base.note || "",
        currency: over?.currency || base.currency || "USD",
      };
    });
  }

  function formatTokens(value) {
    if (value >= 1_000_000) return `${(value / 1_000_000).toFixed(2)}M`;
    if (value >= 1_000) return `${(value / 1_000).toFixed(1)}k`;
    return String(value);
  }

  function pricingTodayTotal(rows) {
    const artifactTotal = currentRuntimeInfo?.totalCostUsd;
    if (Number.isFinite(artifactTotal)) return artifactTotal;
    return rows.reduce((sum, row) => sum + (row.cost || 0), 0);
  }

  function renderPricingPane() {
    const host = byId("pane-modelPricing-content");
    if (!host) return;
    const previous = byId("pricing-host");
    const container = previous || node("div", null, { id: "pricing-host" });
    container.replaceChildren();
    if (!previous) host.append(container);

    const rows = effectivePricingRows();
    const withUsage = rows.filter((row) => row.tokens > 0);
    const custom = rows.filter((row) => row.isCustom);
    const query = pricingQuery.trim().toLowerCase();
    const visible = rows.filter((row) => {
      if (pricingFilter === "已有用量" && row.tokens <= 0) return false;
      if (pricingFilter === "已校准" && !row.isCustom) return false;
      if (!query) return true;
      return [row.key, row.displayName, row.vendor].some((value) => String(value).toLowerCase().includes(query));
    });

    // 1. 今日费用总览
    const summary = card(container, null);
    summary.classList.add("pricing-summary");
    summary.append(node("h2", "今日 TOKEN 预估折算总费用", { class: "pricing-title" }));
    summary.append(node("p", "基于当前本机全部活跃 Agent 真实 Token 吞吐量进行折算", { class: "row-sub" }));
    const amount = node("div", null, { class: "pricing-amount" });
    amount.append(node("span", `$${pricingTodayTotal(rows).toFixed(2)}`, { class: "pricing-money" }));
    const tokens = (currentRuntimeInfo?.modelUsage || []).reduce((sum, row) => sum + (row.tokens || 0), 0);
    if (tokens > 0) amount.append(node("span", `/ ${formatTokens(tokens)}`, { class: "pricing-tokens" }));
    summary.append(amount);

    // 2. 搜索 + 三态筛选
    const filterBar = node("div", null, { class: "pricing-filter" });
    const search = input("pricing-search", "search", { placeholder: "搜索模型或厂商 (如 k3, deepseek, gpt...)", class: "pricing-search" });
    search.value = pricingQuery;
    search.addEventListener("input", () => { pricingQuery = search.value; renderPricingPane(); });
    filterBar.append(search);
    for (const mode of PRICING_FILTERS) {
      const count = mode === "全部" ? rows.length : mode === "已有用量" ? withUsage.length : custom.length;
      const chip = node("button", `${mode} (${count})`, { type: "button", class: mode === pricingFilter ? "pricing-chip active" : "pricing-chip" });
      chip.addEventListener("click", () => { pricingFilter = mode; renderPricingPane(); });
      filterBar.append(chip);
    }
    container.append(filterBar);

    // 3. 定价表 (8 列, 与 mac 表格同列序)
    const tableCard = card(container, null);
    tableCard.classList.add("pricing-table-card");
    if (!visible.length) {
      const empty = node("div", null, { class: "pricing-empty" });
      empty.append(node("span", "🗂", { class: "pricing-empty-icon" }), node("span", "未找到匹配的模型定价规则"));
      tableCard.append(empty);
    } else {
      const wrap = node("div", null, { class: "pricing-table-wrap" });
      const table = node("table", null, { class: "fluent-table pricing-table" });
      const header = node("tr");
      for (const [text, cls] of [["模型与厂商", "col-model"], ["今日用量", "col-usage"], ["来源", "col-source"],
        ["输入单价", "col-price"], ["输出单价", "col-price"], ["缓存命中", "col-cache"], ["今日折算", "col-cost"], ["操作", "col-ops"]]) {
        header.append(node("th", text, { class: cls }));
      }
      table.append(header);
      for (const row of visible) {
        const line = node("tr");
        const modelCell = node("td", null, { class: "col-model", title: row.key });
        const modelLine = node("div", null, { class: "pricing-model-line" });
        modelLine.append(node("span", row.key, { class: "pricing-model" }));
        if (row.tokens > 0) modelLine.append(node("span", "●", { class: "pricing-dot" }));
        modelCell.append(modelLine);
        if (row.vendor) modelCell.append(node("span", row.vendor, { class: "pricing-vendor" }));
        line.append(modelCell);
        line.append(node("td", row.tokens > 0 ? formatTokens(row.tokens) : "—",
          { class: row.tokens > 0 ? "col-usage usage-pill" : "col-usage muted" }));
        line.append(node("td", row.isCustom ? "人工校准" : "内置基线",
          { class: row.isCustom ? "col-source source-custom" : "col-source source-builtin" }));
        line.append(node("td", `$${row.inputPrice.toFixed(2)} /1M`, { class: "col-price" }));
        line.append(node("td", `$${row.outputPrice.toFixed(2)} /1M`, { class: "col-price" }));
        line.append(node("td", Number.isFinite(row.cachePrice) ? `$${row.cachePrice.toFixed(3)} /1M` : "—", { class: "col-cache muted" }));
        line.append(node("td", row.cost && row.cost > 0 ? `$${row.cost.toFixed(2)}` : "—",
          { class: row.cost && row.cost > 0 ? "col-cost pricing-cost" : "col-cost muted" }));
        const ops = node("td", null, { class: "col-ops" });
        button(ops, `price-edit-${row.key}`, "编辑", () => { pricingEditing = row; renderPricingPane(); openCalibrationSheet(); }, "btn plain-btn");
        if (row.isCustom) {
          button(ops, `price-restore-${row.key}`, "⟲", () => resetPricingOverride(row.key), "btn plain-btn");
        }
        line.append(ops);
        table.append(line);
      }
      wrap.append(table);
      tableCard.append(wrap);
    }
    container.append(tableCard);

    // 4. settings.json 联动预览
    const configCard = card(container, null);
    const configHead = node("div", null, { class: "pricing-config-head" });
    configHead.append(node("h2", "配置文件实时映射 (settings.json)", { class: "card-caption-inline" }));
    configHead.append(node("span", "%APPDATA%\\Bruce\\config\\settings.json", { class: "pricing-path" }));
    if (custom.length) {
      button(configHead, "pricing-reset-all", "全部重置为基准", showResetAllConfirm, "btn plain-btn danger-text");
    }
    configCard.append(configHead);
    configCard.append(node("p", "除在当前图形界面调整外，您也可以直接在 Bruce 的配置文件中声明 pricingOverrides 节点进行批量人工校准。", { class: "hint" }));
    const preview = node("pre", null, { id: "pricing-config-preview", class: "pricing-config" });
    preview.textContent = custom.length
      ? JSON.stringify({ pricingOverrides: settings.pricingOverrides || {} }, null, 2)
      : "// 当前全部使用官方内置基准单价。添加自定义或校准项后将在此展示配置代码：\n{ \"pricingOverrides\": {} }";
    configCard.append(preview);
    container.append(configCard);
    // 隐藏的 JSON 编辑区保留 (全局保存写回 pricingOverrides)
    const overridesField = node("textarea", null, { id: "setting-pricing-overrides", class: "hidden" });
    overridesField.value = JSON.stringify(settings.pricingOverrides || {}, null, 2);
    container.append(overridesField);
  }

  function renderModelPrices() {
    // 兼容旧入口: 改为重绘整页 (价格数据 + 表)
    renderPricingPane();
  }

  // 校准弹窗 (对齐 mac ModelPricingCalibrationSheet)
  function openCalibrationSheet() {
    // 注意: 不能把局部变量命名为 row —— 会遮蔽模块级 row() 行构建函数 (C032 实测)
    const entry = pricingEditing;
    if (!entry) return;
    const host = byId("pane-modelPricing-content");
    byId("pricing-sheet")?.remove();
    const overlay = node("div", null, { id: "pricing-sheet", class: "sheet-overlay" });
    const sheet = node("div", null, { class: "sheet" });
    sheet.append(node("h2", "模型单价人工校准", { class: "sheet-title" }));
    sheet.append(node("p", `${entry.displayName} (${entry.key})${entry.vendor ? ` · ${entry.vendor}` : ""}`, { class: "row-sub" }));
    if (entry.isCustom) sheet.append(node("span", "当前已校准", { class: "sheet-badge" }));

    const form = node("div", null, { class: "form-grid" });
    const inputField = entry.inputPrice.toFixed(2);
    const outputField = entry.outputPrice.toFixed(2);
    const cacheField = Number.isFinite(entry.cachePrice) ? entry.cachePrice.toFixed(4) : "";
    row(form, "输入单价 (Prompt / Input)", input("calibration-input", "text", { value: inputField, placeholder: "0.00" }), "每 100 万 (1M) Tokens 费用");
    row(form, "输出单价 (Completion / Output)", input("calibration-output", "text", { value: outputField, placeholder: "0.00" }), "每 100 万 (1M) Tokens 费用");
    row(form, "缓存读取命中 (Cache Hit / Read)", input("calibration-cache", "text", { value: cacheField, placeholder: "0.00" }), "每 100 万 (1M) Tokens 费用 (留空按 10% 默认折算)");
    row(form, "备注说明 (可选)", input("calibration-note", "text", { value: entry.note, placeholder: "如：采购折扣套餐 / 内部计费合约" }));
    sheet.append(form);

    const sampleCost = (1_000_000 * (entry.inputPrice + entry.outputPrice)) / 2 / 1_000_000 + (200_000 * entry.outputPrice) / 1_000_000 - (200_000 * entry.outputPrice) / 1_000_000;
    const estimate = node("div", null, { class: "sheet-estimate" });
    estimate.append(node("div", "实时折算公式与效果预估", { class: "sheet-estimate-title" }));
    estimate.append(node("p", `每消耗 1M 输入 + 200k 输出，折算费用约为 $${(entry.inputPrice + 0.2 * entry.outputPrice).toFixed(3)} USD`, { class: "row-sub" }));
    sheet.append(estimate);
    void sampleCost;

    const act = node("div", null, { class: "sheet-actions" });
    if (entry.isCustom) button(act, "calibration-restore", "恢复内置默认基准", () => { resetPricingOverride(entry.key); closeCalibrationSheet(); }, "btn danger");
    button(act, "calibration-cancel", "取消", closeCalibrationSheet);
    button(act, "calibration-save", "保存校准", saveCalibration, "btn primary");
    sheet.append(act);
    overlay.append(sheet);
    overlay.addEventListener("click", (event) => { if (event.target === overlay) closeCalibrationSheet(); });
    host.append(overlay);
  }

  function closeCalibrationSheet() {
    byId("pricing-sheet")?.remove();
    pricingEditing = null;
  }

  // 返回是否已保存: 失败原因已由 persist 写入状态行, 调用方只需决定是否关闭弹窗。
  async function persistOverrides(overrides, statusText) {
    validateOverrides(overrides);
    const saved = await persist({ pricingOverrides: overrides });
    if (saved) {
      message(byId("settings-status"), statusText);
      renderPricingPane();
    }
    return saved;
  }

  async function saveCalibration() {
    const entry = pricingEditing;
    if (!entry) return;
    try {
      const overrides = { ...(settings.pricingOverrides || {}) };
      const value = {};
      const input = byId("calibration-input").value.trim();
      const output = byId("calibration-output").value.trim();
      const cache = byId("calibration-cache").value.trim();
      const note = byId("calibration-note").value.trim();
      if (input) value.inputPricePerMillion = Number(input);
      if (output) value.outputPricePerMillion = Number(output);
      if (cache) value.cacheReadPricePerMillion = Number(cache);
      if (note) value.note = note;
      value.currency = entry.currency || "USD";
      overrides[entry.key] = value;
      if (await persistOverrides(overrides, "已保存校准")) closeCalibrationSheet();
    } catch (error) {
      message(byId("settings-status"), `保存失败：${error.message || error}`);
    }
  }

  async function resetPricingOverride(key) {
    try {
      const overrides = { ...(settings.pricingOverrides || {}) };
      delete overrides[key];
      if (await persistOverrides(overrides, `已恢复 ${key} 的内置基准`)) closeCalibrationSheet();
    } catch (error) {
      message(byId("settings-status"), `恢复失败：${error.message || error}`);
    }
  }

  async function resetAllPricing() {
    try {
      if (await persistOverrides({}, "已恢复全部内置基准")) closeCalibrationSheet();
    } catch (error) {
      message(byId("settings-status"), `恢复失败：${error.message || error}`);
    }
  }

  function showResetAllConfirm() {
    byId("pricing-reset-confirm")?.remove();
    const host = byId("pane-modelPricing-content");
    const overlay = node("div", null, { id: "pricing-reset-confirm", class: "sheet-overlay" });
    const sheet = node("div", null, { class: "sheet" });
    sheet.append(node("h2", "确定恢复所有模型定价为内置基准？", { class: "sheet-title" }));
    sheet.append(node("p", "此操作将清除所有人工校准与自定义模型的单价覆盖配置。", { class: "row-sub" }));
    const act = node("div", null, { class: "sheet-actions" });
    button(act, "reset-all-cancel", "取消", () => byId("pricing-reset-confirm")?.remove());
    button(act, "reset-all-confirm", "恢复默认", resetAllPricing, "btn danger");
    sheet.append(act);
    overlay.append(sheet);
    host.append(overlay);
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
    // mac 单一模块授权开关: 切换即等价于「确认授权 / 撤销全部授权」
    const consentToggle = input("setting-usage-consent", "checkbox");
    consentToggle.addEventListener("change", () => applyConsent(consentToggle.checked));
    row(c1, "Agent 用量", consentToggle, "允许按授权范围采集本机会话用量");
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
    const exportWrap = node("div", null, { class: "actions-inline-flat" });
    button(exportWrap, "export-billing", "导出…", () => runExport("export_billing", "账单", "csv"), "btn");
    row(c1, "导出账单", exportWrap, "token 用量与花费统计 CSV（写入导出目录并回显路径）");
    const diagWrap = node("div", null, { class: "actions-inline-flat" });
    button(diagWrap, "export-diagnostics", "导出…", () => runExport("export_diagnostics", "诊断报告", "json"), "btn");
    row(c1, "导出诊断包", diagWrap, "脱敏 JSON（不含凭证、账号与完整本机路径）");
    c1.append(node("p", "Windows 侧导出写入 %APPDATA%\\Bruce\\exports\\ 并在此回显完整路径（mac 走系统保存对话框，适配取舍见 design 05 §4.4）。", { class: "hint" }));

    const c2 = card(host, "运行环境与诊断");
    c2.append(node("pre", null, { id: "runtime-info", class: "runtime-info-box" }));
    const act = actions(c2);
    button(act, "runtime-reload", "刷新运行状态", loadRuntimeInfo);
    button(act, "diagnostics-preview", "诊断预览", showDiagnosticsPreview);
    // 预览容器 id 与按钮 id 必须不同 (C031 实测: 同名会让 getElementById 命中按钮,
    // 把 JSON 写进按钮标签并让预览框保持空)
    c2.append(node("pre", null, { id: "diagnostics-report", class: "runtime-info-box hidden" }));
  }

  // 导出: 先经系统保存对话框选位置 (与 mac NSSavePanel 等价), 再交给后端写入并回显路径。
  // 对话框不可用 (插件未授权/异常) 时回落到默认导出目录; 用户取消则不写文件。
  async function runExport(command, label, extension, { defaultName = null, args = {} } = {}) {
    const status = byId("settings-status");
    let requested = null;
    let dialogAvailable = true;
    try {
      requested = await invoke("plugin:dialog|save", {
        options: {
          title: `导出${label}`,
          defaultPath: defaultName || `Bruce-${command === "export_billing" ? "billing" : "diagnostics"}.${extension}`,
          filters: [{ name: label, extensions: [extension] }],
        },
      });
    } catch {
      dialogAvailable = false;
    }
    if (dialogAvailable && !requested) {
      message(status, "已取消导出");
      return;
    }
    try {
      const result = await invoke(command, { ...args, path: requested ?? null });
      message(status, `${label}已导出：${result?.path || "默认导出目录"}`);
    } catch (error) {
      message(status, `${label}导出失败：${error.message || error}`);
    }
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
    const box = byId("setting-usage-consent");
    const saved = await persist({ consentVersion: granted ? 1 : 0, usageEnabled: granted }, {
      revert: () => { if (box) box.checked = !granted; },
    });
    if (!saved) { message(status, "授权更新失败", "warn"); return; }
    if (box) box.checked = granted;
    const state = byId("consent-state");
    if (state) { state.textContent = granted ? "当前授权有效" : "尚未授权"; state.className = granted ? "auth-state ok" : "auth-state off"; }
    message(status, granted ? "已确认授权" : "已撤销全部授权");
  }

  // MARK: - 数据交互逻辑

  async function loadRuntimeInfo() {
    try {
      const info = await invoke("get_runtime_info");
      currentRuntimeInfo = info;
      const status = info.status && typeof info.status === "object" ? info.status : { phase: info.status || info.phase };
      const version = byId("setting-version");
      if (version) version.textContent = info.version || "—";
      const navVersion = byId("nav-version");
      if (navVersion) navVersion.textContent = info.version || "";
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
      currentModelPrices = await invoke("get_model_prices") || {};
    } catch {
      currentModelPrices = {};
    }
    renderPricingPane();
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
    syncToggleState("setting-notifications");
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
    for (const render of segmentRenderers) render();
    applyTheme();
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
      currentDashboard = panel;
      const plans = {};
      for (const section of panel?.subscription?.sections || []) {
        if (section.plan) plans[providerKeyOfSection(section.id)] = section.plan;
      }
      providerPlans = plans;
      renderOrders();
      renderAgentUsageWorkbench();
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

    const gHost = byId("pane-general-content");
    const uHost = byId("pane-agentUsage-content");
    const sHost = byId("pane-subscription-content");
    const cHost = byId("pane-consent-content");
    const mHost = byId("pane-maintenance-content");

    if (gHost) buildGeneral(gHost);
    if (uHost) buildAgentUsage(uHost);
    if (sHost) buildSubscription(sHost);
    if (cHost) buildConsent(cHost);
    if (mHost) buildMaintenance(mHost);

    try {
      await Promise.all([loadSettings(), loadCredentials(), loadPrices(), loadRuntimeInfo(), loadPlans()]);
      await listen("settings-updated", async () => {
        try { await loadSettings(); } catch { message(byId("settings-status"), "设置读取失败"); }
      });
      await listen("dashboard-updated", event => {
        currentDashboard = event.payload;
        showConnectionResult(event.payload);
        renderAgentUsageWorkbench();
      });
    } catch {
      message(byId("settings-status"), "部分配置读取失败，请重新打开设置");
    }
  })();

  window.BruceSettings = { ready, applyTheme, switchCategory };
})();
