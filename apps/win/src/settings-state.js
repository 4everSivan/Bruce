// Settings shared state, constants and DOM/form helpers (TD-011 split of settings.js).
// Loaded first: every settings-*.js section reads window.BruceSettingsCore.
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
    agentUsage: { title: "模型用量", crumb: "设置 / 模型用量" },
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
  // 软件更新共享表现层 (T11): 文案与状态区语义和 mac 同源, 双端同读
  // tests/fixtures/update-copy-parity/cases.json 对拍 (check-win-frontend.mjs 执行)。
  const UP = window.BruceUpdatePresentation;
  // mac 允许的自动采集周期 (OnboardingConfiguration.allowedRefreshIntervalMinutes)
  const REFRESH_PRESETS = [5, 15, 30, 60];

  // 共享可变状态 (TD-011): 所有分节脚本读写同一对象, 界面更新不会分叉。
  const state = {
    settings: {},
    allowlist: [],
    providerOrder: [],
    cardOrder: [],
    credentialAccounts: [],
    // 被读取侧丢弃的账号原因 (C092): 只含字段 / 账号 ID / 原因文案, 不含凭据值。
    credentialRejections: [],
    currentRuntimeInfo: null,
    currentDashboard: null,
    // 套餐名: 由 artifact 提供 (mac C024 起套餐名只在设置页行内呈现), 经 get_dashboard 取。
    providerPlans: {},
    // mac AgentUsageWorkbenchView @State timeRange 初值 .sevenDays
    selectedTimeRange: "7d",
    currentModelPrices: [],
    stepfunWebSession: null,
    saveQueue: Promise.resolve(),
  };
  const coreState = state;
  const TIME_RANGES = [
    { key: "today", label: "今日" },
    { key: "7d", label: "近 7 天" },
    { key: "30d", label: "近 30 天" },
    { key: "month", label: "本月" },
    { key: "all", label: "全部历史" },
  ];
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
    { id: "codex", name: "ChatGPT / Codex", sub: "本机会话目录 (~/.codex/sessions, 含 Orca 内置 Codex)" },
    { id: "kimi-code-cli", name: "Kimi Code", sub: "本机会话目录 (~/.kimi/history)" },
    { id: "opencode", name: "OpenCode", sub: "本机会话目录 (%APPDATA%\\OpenCode)" },
    { id: "grok", name: "Grok", sub: "本机会话目录 (~/.grok)" },
    { id: "volcengine", name: "火山引擎 / 豆包", sub: "本机会话目录" },
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
  function persist(patch, { revert } = {}) {
    const run = async () => {
      const status = byId("settings-status");
      try {
        const updated = { ...await invoke("get_settings"), ...patch };
        validateOverrides(updated.pricingOverrides || {});
        const minutes = Math.round((updated.refreshIntervalSecs || 0) / 60);
        if (!Number.isInteger(minutes) || minutes < 1 || minutes > 1440) throw new Error("刷新间隔须为 1–1440 的整数分钟");
        // 后端归一后回传 (C090): enabled_providers 由 subscriptionProviders 派生,
        // 取回传值作本地缓存, 避免两处启用口径漂移 (测试桩返回空值时回落到本次提交值)。
        const saved = await invoke("save_settings_command", { settings: updated });
        coreState.settings = saved || updated;
        window.dispatchEvent(new CustomEvent("settings-saved", { detail: updated }));
        if (status?.dataset.tone === "warn") message(status, "");
        return true;
      } catch (error) {
        revert?.();
        message(status, `保存失败：${error.message || error}`, "warn");
        return false;
      }
    };
    coreState.saveQueue = coreState.saveQueue.then(run, run);
    return coreState.saveQueue;
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


  window.BruceSettingsSections = window.BruceSettingsSections || {};
  window.BruceSettingsCore = {
    state,
    invoke, listen, providers, CATEGORIES, node, byId, UP, REFRESH_PRESETS, TIME_RANGES, SESSION_PROBES, svgEl, catmullRomToBezier, applyTheme, message, persist, input, row, card, segmented, button, actions, segmentRenderers, objectJSON, validateOverrides, orderedAll, move, switchCategory,
  };
})();
