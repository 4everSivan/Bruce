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
  let settings = {}, allowlist = [], providerOrder = [], cardOrder = [];
  let credentialAccounts = [];
  // 被读取侧丢弃的账号原因 (C092): 只含字段 / 账号 ID / 原因文案, 不含凭据值。
  let credentialRejections = [];
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
        // 后端归一后回传 (C090): enabled_providers 由 subscriptionProviders 派生,
        // 取回传值作本地缓存, 避免两处启用口径漂移 (测试桩返回空值时回落到本次提交值)。
        const saved = await invoke("save_settings_command", { settings: updated });
        settings = saved || updated;
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
  /// 该 Provider 的账号记录。形状不合规的账号在读取侧即被丢弃 (规则 21 fail-closed),
  /// 因此「有账号」等价于「存在完整可用凭据记录」; 被丢弃账号的原因另经
  /// `credentialRejections` 回传 (C092), 不混进本清单。
  function accountsFor(id) { return credentialAccounts.filter(account => account.field === providerDescriptor(id)[2]); }
  /// 其中「完整可用凭据记录」(C084 / 设计规则 23): 后端逐条下发 `usable`。
  /// 只读发现写入的 metadata-only 记录 (authorization_state = reauthRequired) 会在对话框
  /// 里呈现, 但**不计入「已配置」** —— 它们没有可出站的令牌。旧后端无该字段时按可用处理。
  function usableAccountsFor(id) { return accountsFor(id).filter(account => account.usable !== false); }
  /// 该 Provider 被丢弃账号的原因清单 (C092)。
  function rejectionsFor(id) { return credentialRejections.filter(item => item.field === providerDescriptor(id)[2]); }
  // 状态尾件 (mac subscriptionStatusTail): 未配置 / 已配置 / 验证失败 / 需重新登录
  // C081: 判据为 fail-closed —— 形状不合法的账号在读取时即被丢弃, 故
  // 「有账号」等价于「存在完整可用凭据记录」。
  // C091: 在配置判据之上叠加 verificationStatus; 本机 CLI 只读跟随计入「已配置」。
  /// 本机 CLI 登录态是否可作为「已配置」依据 (C091 / 设计规则 26)。
  /// 对齐 mac `ProviderRegistry` 的 claudeAppOrLocalProbe / grokAppOrLocalProbe:
  /// 正在跟随的本机登录态等价于已配置, 即使没有落盘账号 (C075 的零配置跟随不落盘)。
  function localFollowConfigured(id) {
    if (id === "claude") return claudeLocalInfo?.status === "followed";
    // C085: Grok 与 Claude 同范式, 本机只读跟随计入「已配置」(设计规则 26)。
    if (id === "grok") return grokLocalInfo?.status === "followed";
    return false;
  }

  /// 「已配置」判据 (C081 / C091 / C084): 存在**完整可用**凭据记录, 或正在只读跟随本机
  /// CLI 登录态。只读发现写入的 metadata-only 记录不算 —— 否则没有令牌的账号会让看板
  /// 去查询必然失败的额度。行尾件、启用开关禁用态、对话框横幅与授权摘要共用此判据。
  function providerConfigured(id) { return usableAccountsFor(id).length > 0 || localFollowConfigured(id); }

  function providerState(id) {
    const accounts = accountsFor(id);
    // C084: 需要重新授权的账号 (设备码发现) 优先呈现 —— 它们不计入「已配置」, 但用户必须
    // 看到「有账号待授权」, 否则只能看到「未配置」而无从下手。规则 21 登记措辞。
    if (accounts.some(account => account.authorizationState === "reauthRequired")) {
      return { text: "需要重新授权", cls: "warn" };
    }
    if (!providerConfigured(id)) return { text: "未配置", cls: "off" };
    const status = subscriptionProviderState(id).verificationStatus;
    if (status === "failed") return { text: "验证失败", cls: "warn" };
    if (status === "needsRelogin") return { text: "需重新登录", cls: "warn" };
    return { text: "已配置", cls: "ok" };
  }
  // 设置尚未载入时视为空集 (C090): 不得回落为「全部启用」, 否则首轮渲染会把全部开关画成开启。
  function enabledProvidersOf() { return settings.enabledProviders || []; }

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
        line.append(node("span", { usage: "Token 用量", subscription: "订阅额度", hourly: "模型用量" }[id] || id));
        const btns = node("div", null, { class: "order-btns" });
        button(btns, `card-up-${id}`, "上移", () => reorder(cardOrder, index, -1, "cardOrder"));
        button(btns, `card-down-${id}`, "下移", () => reorder(cardOrder, index, 1, "cardOrder"));
        line.append(btns);
        cards.append(line);
      });
    }

    const host = byId("setting-providers");
    if (host) {
      host.replaceChildren();
      // C082: 只列出已添加的 Provider; 行 = 拖拽手柄 + 品牌徽章 + 名称/副标题 +
      // 套餐标签 + 状态尾件 + 「配置」按钮 + 启用开关 (未配置且未启用时禁用)。
      for (const id of orderedAddedProviders()) {
        const descriptor = providerDescriptor(id);
        const state = providerState(id);
        const configured = providerConfigured(id);
        const line = node("div", null, { class: "provider-row" });
        line.dataset.provider = id;
        const handle = node("span", "⠿", { class: "drag-handle", draggable: "true", title: "拖拽调整顺序", "aria-hidden": "true" });
        handle.addEventListener("dragstart", event => {
          dragProviderId = id;
          event.dataTransfer?.setData("text/plain", id);
          if (event.dataTransfer) event.dataTransfer.effectAllowed = "move";
        });
        handle.addEventListener("dragend", () => { dragProviderId = null; });
        line.append(handle);
        line.append(providerBadge(id, descriptor[1]));
        const meta = node("div", null, { class: "provider-meta" });
        meta.append(node("span", descriptor[1], { class: "provider-name" }));
        meta.append(node("span", providerSubtitle(id), { class: "provider-sub" }));
        line.append(meta);
        if (providerPlans[id]) line.append(node("span", providerPlans[id], { class: "plan-chip" }));
        line.append(node("span", state.text, { class: `auth-state ${state.cls}` }));
        button(line, `provider-configure-${id}`, "配置", () => openProviderDialog(id), "btn");
        const toggle = input(`provider-${id}`, "checkbox", { "data-provider": id, class: "provider-toggle" });
        // C090: 开关恒取已保存的启用态 (唯一事实源), 不沿用重绘前的勾选 —— 验证结果、
        // 移除等外部变更改写启用态后, 旧勾选会让开关与真实启用态相反。
        const enabled = subscriptionProviderState(id).enabled;
        toggle.checked = enabled;
        toggle.disabled = !configured && !enabled;
        toggle.setAttribute("aria-label", `${descriptor[1]} 启用开关`);
        toggle.addEventListener("change", async () => {
          // C090: 启用态写入 subscriptionProviders[id].enabled (唯一事实源),
          // enabled_providers 由后端派生, 不再由前端直接写。
          const map = subscriptionProviderMap();
          map[id] = { ...(map[id] || subscriptionProviderState(id)), enabled: toggle.checked };
          await persist({ subscriptionProviders: map }, {
            revert: () => { toggle.checked = !toggle.checked; },
          });
          renderSubscriptionViews();
        });
        line.append(toggle);
        line.addEventListener("dragover", event => { event.preventDefault(); });
        line.addEventListener("drop", event => {
          event.preventDefault();
          const dragged = dragProviderId || event.dataTransfer?.getData("text/plain");
          dragProviderId = null;
          reorderProviders(dragged, id);
        });
        host.append(line);
      }
      if (!orderedAddedProviders().length) {
        // C096: 空态补副标题「从下方添加服务」(对齐 mac FluentRow 的 sub)。
        const empty = node("div", null, { class: "provider-empty" });
        empty.append(node("span", "尚未配置任何订阅 Provider", { class: "row-title" }));
        empty.append(node("span", "从下方添加服务", { class: "row-sub" }));
        host.append(empty);
      }
    }
    renderProviderAddRow();
  }

  /// 订阅行与授权摘要都依赖启用态与「已配置」判据 (C090 / C094): 启用态变化后一起重绘,
  /// 否则摘要停留在旧的启用集合上。
  function renderSubscriptionViews() {
    renderOrders();
    renderConsentSummary();
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
    // mac generalPane 首卡无分组标题; 行序: 界面风格 → 刷新间隔 → 看板布局 → 系统通知
    // (配色模式 / 钥匙串 / 外部 CLI 来源为 mac 独有能力, Windows 恒深色且无钥匙串;
    // 原「版本」行已迁维护页软件更新卡 —— 07 §4.2 R3 方案 B)。
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
    const layout = node("select", null, { id: "setting-layout-mode" });
    layout.append(node("option", "纵向级联 (滚动)", { value: "stack" }), node("option", "顶栏 Tab (单卡)", { value: "tabbed" }));
    row(c1, "看板布局", segmented(layout, (value, revert) => persist({ layoutMode: value }, { revert })),
      "选择置顶面板呈现方式，顶栏 Tab 模式通过右上角小图标在用量、订阅与活跃卡片间快速切换");
    // mac: 开关旁以「已开启 / 已关闭」状态字呈现当前值
    const notifyWrap = node("div", null, { class: "toggle-with-state" });
    const notify = input("setting-notifications", "checkbox");
    notifyWrap.append(node("span", "", { id: "setting-notifications-state", class: "toggle-state" }), notify);
    notify.addEventListener("change", () => {
      syncToggleState("setting-notifications");
      return persist({ notificationsEnabled: notify.checked }, {
        revert: () => { notify.checked = !notify.checked; syncToggleState("setting-notifications"); },
      });
    });
    row(c1, "系统通知", notifyWrap, "预警与额度提醒; 关闭后 Bruce 不会投递通知");

    // 方案 1: 任务栏托盘悬停预览开关
    const previewWrap = node("div", null, { class: "toggle-with-state" });
    const previewToggle = input("setting-tray-hover-preview", "checkbox");
    previewWrap.append(node("span", "", { id: "setting-tray-hover-preview-state", class: "toggle-state" }), previewToggle);
    previewToggle.addEventListener("change", () => {
      syncToggleState("setting-tray-hover-preview");
      return persist({ trayHoverPreview: previewToggle.checked }, {
        revert: () => { previewToggle.checked = !previewToggle.checked; syncToggleState("setting-tray-hover-preview"); },
      });
    });
    row(c1, "托盘实时预览", previewWrap, "鼠标悬停任务栏托盘图标时，弹出 420px 亚克力微缩实时预览卡");

    const hotkeyWrap = node("div", null, { class: "hotkey-field-wrap" });
    hotkeyWrap.append(input("setting-hotkey", "text", { placeholder: "Control+Shift+B", autocomplete: "off" }));
    const recordButton = button(hotkeyWrap, "hotkey-record", "录制热键", () => {
      const field = byId("setting-hotkey");
      if (!field) return;
      if (field.dataset.recording === "true") {
        setHotkeyRecording(false);
        message(byId("settings-status"), "已取消快捷键录制");
        return;
      }
      field.value = "";
      setHotkeyRecording(true);
      field.focus?.();
      message(byId("settings-status"), "在热键输入框按下组合键；按 Esc 取消录制");
    });
    // 按下录制按钮时保留输入框焦点: WebView2 会先派发输入框 blur 再派发按钮 click,
    // 若放任失焦, blur 先结束录制、click 又重新开始, 「再点一次取消」永远走不到 (mac 录制按钮即切换语义)。
    recordButton.addEventListener("mousedown", event => {
      if (byId("setting-hotkey")?.dataset.recording === "true") event.preventDefault();
    });
    button(hotkeyWrap, "hotkey-clear", "清除", () => {
      const field = byId("setting-hotkey");
      setHotkeyRecording(false);
      if (field) field.value = "";
      return saveHotkey();
    });
    row(card(host, "全局快捷键"), "唤出看板", hotkeyWrap, "唤出或隐藏置顶看板; 留空关闭全局快捷键");

    byId("setting-hotkey")?.addEventListener("keydown", event => {
      const field = byId("setting-hotkey");
      if (field?.dataset.recording !== "true") return;
      event.preventDefault();
      const parsed = normalizeHotkeyEvent(event);
      if (parsed.action === "ignore") return;
      if (parsed.action === "cancel") {
        setHotkeyRecording(false);
        message(byId("settings-status"), "已取消快捷键录制");
        return;
      }
      if (parsed.action === "error") {
        message(byId("settings-status"), parsed.reason, "warn");
        return;
      }
      setHotkeyRecording(false);
      field.value = parsed.accelerator;
      return saveHotkey();
    });
    byId("setting-hotkey")?.addEventListener("blur", () => {
      const field = byId("setting-hotkey");
      if (field?.dataset.recording === "true") {
        setHotkeyRecording(false);
      }
    });
    // 手动键入的热键在失焦 / 回车时生效
    byId("setting-hotkey")?.addEventListener("change", () => {
      if (byId("setting-hotkey")?.dataset.recording === "true") return Promise.resolve();
      return saveHotkey();
    });

    const c2 = card(host, "看板卡片顺序");
    c2.append(node("p", "点击上移 / 下移调整置顶面板各卡片的堆叠顺序, 即时生效; 看板中收起的卡片也可直接拖拽排序。", { class: "hint" }));
    c2.append(node("div", null, { id: "setting-card-order", class: "order-list" }));
  }

  const HOTKEY_CODE_MAP = {
    Space: "Space",
    Minus: "-",
    Equal: "=",
    BracketLeft: "[",
    BracketRight: "]",
    Backslash: "\\",
    Semicolon: ";",
    Quote: "'",
    Backquote: "`",
    Comma: ",",
    Period: ".",
    Slash: "/",
    ArrowUp: "Up",
    ArrowDown: "Down",
    ArrowLeft: "Left",
    ArrowRight: "Right",
    Enter: "Enter",
    Tab: "Tab",
    Backspace: "Backspace",
    Delete: "Delete",
    Insert: "Insert",
    Home: "Home",
    End: "End",
    PageUp: "PageUp",
    PageDown: "PageDown",
    Escape: "Escape",
    PrintScreen: "PrintScreen",
    ScrollLock: "ScrollLock",
    Pause: "Pause",
    // 小键盘键与主键盘同名键在 global-hotkey 中是不同的键 (Numpad1 ≠ Digit1), 必须原样保留
    NumpadAdd: "NumpadAdd",
    NumpadSubtract: "NumpadSubtract",
    NumpadMultiply: "NumpadMultiply",
    NumpadDivide: "NumpadDivide",
    NumpadDecimal: "NumpadDecimal",
    NumpadEnter: "NumpadEnter",
    NumpadEqual: "NumpadEqual",
  };
  // 无 event.code 时按 event.key 回退可接受的命名键 (与 global-hotkey 解析表一致)
  const HOTKEY_NAMED_KEYS = new Set([
    "Enter", "Tab", "Backspace", "Delete", "Insert", "Home", "End", "PageUp", "PageDown",
    "Escape", "PrintScreen", "ScrollLock", "Pause",
  ]);
  const HOTKEY_UNSUPPORTED = "unsupported";

  const SHIFTED_DIGIT_KEY_MAP = {
    "!": "1",
    "@": "2",
    "#": "3",
    "$": "4",
    "%": "5",
    "^": "6",
    "&": "7",
    "*": "8",
    "(": "9",
    ")": "0",
  };

  const RESERVED_HOTKEYS = new Set([
    "Alt+Tab",
    "Alt+F4",
    "Control+Escape",
    "Control+Shift+Escape",
    "Super+L",
    "Super+D",
    "Super+R",
    "Super+E",
  ]);

  function resolveHotkeyPrimaryKey(event) {
    const code = typeof event.code === "string" ? event.code : "";
    if (code) {
      if (/^(Control|Shift|Alt|Meta|OS)(Left|Right)?$/.test(code)) return null;
      const keyMatch = code.match(/^Key([A-Z])$/);
      if (keyMatch) return keyMatch[1];
      const digitMatch = code.match(/^Digit([0-9])$/);
      if (digitMatch) return digitMatch[1];
      const numpadMatch = code.match(/^Numpad([0-9])$/);
      if (numpadMatch) return `Numpad${numpadMatch[1]}`;
      if (/^F([1-9]|1[0-9]|2[0-4])$/.test(code)) return code;
      if (HOTKEY_CODE_MAP[code]) return HOTKEY_CODE_MAP[code];
      return HOTKEY_UNSUPPORTED;
    }
    const key = typeof event.key === "string" ? event.key : "";
    if (!key || ["Control", "Alt", "Shift", "Meta", "OS", "Dead", "Process"].includes(key)) return null;
    if (key === " " || key === "Spacebar" || key === "Space") return "Space";
    const arrowMatch = key.match(/^Arrow(Up|Down|Left|Right)$/);
    if (arrowMatch) return arrowMatch[1];
    if (event.shiftKey && SHIFTED_DIGIT_KEY_MAP[key]) return SHIFTED_DIGIT_KEY_MAP[key];
    if (/^F([1-9]|1[0-9]|2[0-4])$/.test(key) || HOTKEY_NAMED_KEYS.has(key)) return key;
    if (/^[a-z0-9]$/i.test(key)) return key.toUpperCase();
    if (Object.values(HOTKEY_CODE_MAP).includes(key) && key.length === 1) return key;
    return HOTKEY_UNSUPPORTED;
  }

  function normalizeHotkeyEvent(event) {
    const noMods = !event.ctrlKey && !event.altKey && !event.shiftKey && !event.metaKey;
    if (noMods && (event.key === "Escape" || event.code === "Escape" || event.key === "Backspace" || event.key === "Delete")) {
      return { action: "cancel" };
    }
    const primary = resolveHotkeyPrimaryKey(event);
    if (!primary) return { action: "ignore" };
    if (primary === HOTKEY_UNSUPPORTED) return { action: "error", reason: "该键不支持作为全局快捷键，请换一个" };
    const mods = [
      event.ctrlKey && "Control",
      event.altKey && "Alt",
      event.shiftKey && "Shift",
      event.metaKey && "Super",
    ].filter(Boolean);
    const isFunctionKey = /^F([1-9]|1[0-9]|2[0-4])$/.test(primary);
    const hasPrimaryMod = Boolean(event.ctrlKey || event.altKey || event.metaKey);
    if (!hasPrimaryMod && !(event.shiftKey && isFunctionKey)) {
      return { action: "error", reason: "请使用 Ctrl、Alt、Win（或 Shift+F1~F24）与其他键组合" };
    }
    const accelerator = [...mods, primary].join("+");
    if (RESERVED_HOTKEYS.has(accelerator)) {
      return { action: "error", reason: `${accelerator} 为系统保留快捷键，请更换组合` };
    }
    return { action: "commit", accelerator };
  }

  function setHotkeyRecording(active) {
    const field = byId("setting-hotkey");
    const btn = byId("hotkey-record");
    if (!field) return;
    const wasRecording = field.dataset.recording === "true";
    field.dataset.recording = active ? "true" : "false";
    field.classList.toggle("recording", Boolean(active));
    if (btn) {
      btn.textContent = active ? "按键中… (Esc 取消)" : "录制热键";
      btn.classList.toggle("recording", Boolean(active));
    }
    if (active) {
      field.placeholder = "请按下组合键…";
    } else {
      field.placeholder = "Control+Shift+B";
      field.value = settings.hotkey || "";
    }
    if (wasRecording !== Boolean(active)) {
      invoke("set_hotkey_recording", { recording: Boolean(active) }).catch(() => {
        // 进入录制注销失败只影响能否录到当前热键; 退出录制恢复失败则当前热键已失效, 必须告知
        if (!active) message(byId("settings-status"), "已生效的全局快捷键恢复失败，请重新录制", "warn");
      });
    }
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

  // MARK: - 订阅 Provider 配置对话框 (C082, 对齐 mac SettingsView 的 providerConfigSheet)

  // 逐 Provider 配置描述: 字段 (键/标签/占位符)、引导文案、控制台外链、脚注、附加区。
  // 文案逐字对齐 mac SettingsView.apiKeyProviderDialog / ProviderSettingsSection。
  const PROVIDER_CONFIG = {
    kimi: {
      kind: "apiKey",
      fields: [["apiKey", "API Key", "sk-•••••••••••••••• (输入后不回显)"]],
      guide: "在 kimi.com/code 申请 Kimi For Coding API key",
    },
    deepseek: {
      kind: "apiKey",
      fields: [["apiKey", "API Key", "sk-•••••••••••••••• (输入后不回显)"]],
      guide: "在 DeepSeek 平台获取 API key",
    },
    volcengine: {
      kind: "apiKey",
      fields: [["accessKeyId", "Access Key", "AK•••••••• (输入后不回显)"], ["secretAccessKey", "Secret Key", "SK•••••••• (输入后不回显)"]],
      guide: "在火山引擎控制台获取 Access Key 与 Secret Key",
      footnote: "此处仅做本地格式校验, 完整额度试查由 Collector 运行时承担",
    },
    zhipu: {
      kind: "apiKey",
      fields: [["apiKey", "API Key", "•••••••• (输入后不回显)"]],
      guide: "在 Z.ai（BigModel）控制台获取 API key",
      footnote: "此处仅做本地格式校验, 完整额度试查由 Collector 运行时承担",
      sitePicker: true,
    },
    stepfun: {
      kind: "apiKey",
      fields: [["token", "Oasis-Token", "•••••••• (输入后不回显)"]],
      // C086 / 设计规则 20 & 24: 网页登录入口落地后恢复与 mac 逐字一致的引导文案。
      guide: "可点击上方一键登录自动绑定(支持国内/国际站)，或控制台按 F12 复制 Cookie",
      link: { title: "打开 StepFun 控制台", url: "https://platform.stepfun.com" },
      footnote: "凭据安全保存在本应用的本机凭据文件 (仅当前用户可读), 支持国内站与国际站多账号混合添加; 未选择站点时按令牌自动判定",
      sitePicker: true,
      webLogin: true,
    },
    cline: {
      kind: "apiKey",
      fields: [["apiKey", "API Key", "•••••••• (输入后不回显)"]],
      guide: "在 Cline 控制台 Settings > API Keys 创建 API Key",
      link: { title: "打开 Cline 控制台", url: "https://app.cline.bot" },
      footnote: "ClinePass 三窗口额度 (5h / 7d / 30d) 由采集端读取账户计划与逐单台账自动计算",
    },
    codex: {
      kind: "codex",
      guide: "通过 OpenAI 官方设备码登录获取额度; 也可只读发现本机 CLI 或 CC Switch 已登录账号的元数据.",
      link: { title: "打开 Codex 设备码登录页", url: "https://auth.openai.com/codex/device" },
      footnote: "设备码登录全程在官方页面完成, 验证码只在本机展示; 发现的本机账号只写元数据、不导入令牌, 需在本应用内重新授权后才参与额度查询。",
    },
    claude: {
      kind: "localFollow",
      guide: "未检测到本机 Claude 登录态, 登录 Claude CLI 后自动跟随",
      pasteLabel: "粘贴 Claude 访问令牌或凭证 JSON (高级)",
    },
    grok: {
      kind: "localFollow",
      guide: "未检测到 Grok 登录态, 请先通过 Grok CLI 登录 (~/.grok/auth.json)",
      pasteLabel: "粘贴 Grok 访问令牌或凭证 JSON",
    },
    opencodeGo: {
      kind: "paste",
      pasteLabel: "打开 opencode.ai → 登录 → 开发者工具 → Application → Cookies → 复制 auth 值 (Fe26.2**...) 与 workspace URL 中的 wrk_ ID, 粘贴 JSON",
    },
  };

  const VERIFICATION_LABELS = {
    none: ["已配置 · 未验证", "off"],
    ok: ["已配置", "ok"],
    failed: ["验证失败", "warn"],
    // C096: 对话框横幅用「需要重新登录」(对齐 mac `ProviderStatusBanner` 的文案);
    // 行尾件用的是「需重新登录」(mac `subscriptionStatusTail`), 两者 mac 本就不同, 不统一。
    needsRelogin: ["需要重新登录", "warn"],
  };

  let dragProviderId = null;
  // CC Switch 库可用性 (C083): 决定火山引擎对话框是否显示「从 CC Switch 导入」。
  let ccSwitchAvailable = false;

  async function loadCCSwitchStatus() {
    try {
      ccSwitchAvailable = Boolean((await invoke("ccswitch_status"))?.available);
    } catch {
      ccSwitchAvailable = false;
    }
  }

  // Codex 发现来源可用性 (C084): 决定对话框里两个「发现…账号」按钮的显隐。
  let codexSources = { cliAuth: false, ccSwitch: false };

  async function loadCodexSources() {
    try {
      const sources = await invoke("codex_discovery_sources");
      codexSources = { cliAuth: Boolean(sources?.cliAuth), ccSwitch: Boolean(sources?.ccSwitch) };
    } catch {
      codexSources = { cliAuth: false, ccSwitch: false };
    }
  }

  /// 从 CC Switch 只读导入火山引擎凭证并验证 (C083): 导入成功后立即落验证状态。
  async function importVolcengineFromCCSwitch() {
    try {
      const result = await invoke("import_volcengine_from_ccswitch");
      await loadCredentials();
      await applyVerification("volcengine", result?.status || "none", result?.reason || null);
      if (result?.status === "ok") {
        invoke("refresh_subscription", { sectionId: quotaFieldOf("volcengine") }).catch(() => {});
      }
      renderProviderDialog("volcengine");
      message(byId("cfg-status"), result?.status === "ok" ? "已从 CC Switch 导入并验证通过" : "已从 CC Switch 导入");
    } catch (error) {
      message(byId("cfg-status"), `导入失败：${error.message || error}`, "warn");
    }
  }

  function configFor(id) { return PROVIDER_CONFIG[id] || { kind: "apiKey", fields: [["apiKey", "API Key", "•••••••• (输入后不回显)"]] }; }

  /// 已添加的 Provider 集合 (C082): 键存在即已添加。尚未迁移时按当前启用集合派生 ——
  /// 升级不改变可见集合, 也不在启动时产生额外写入; 用户首次增删后即为显式集合。
  function addedProviderIds() {
    if (settings.subscriptionProviders) return Object.keys(settings.subscriptionProviders);
    const enabled = enabledProvidersOf();
    const configured = providers.map(value => value[0]).filter(id => accountsFor(id).length > 0);
    return [...new Set([...enabled, ...configured])];
  }

  /// 可写入的已添加映射 (把派生结果物化为显式集合)。
  function subscriptionProviderMap() {
    if (settings.subscriptionProviders) return { ...settings.subscriptionProviders };
    return Object.fromEntries(addedProviderIds().map(id => [id, subscriptionProviderState(id)]));
  }

  /// 单个 Provider 的已添加 / 验证 / 启用状态 (C082 / C090)。
  /// 未迁移时按启用集合播种, 与后端 `added_subscription_providers` 同口径 ——
  /// 否则升级后所有启用开关会显示为关。
  function subscriptionProviderState(id) {
    const stored = (settings.subscriptionProviders || {})[id];
    if (stored) {
      return { enabled: false, lastVerifiedAt: null, verificationStatus: "none", failureReason: null, ...stored };
    }
    return {
      enabled: enabledProvidersOf().includes(id),
      lastVerifiedAt: null,
      verificationStatus: "none",
      failureReason: null,
    };
  }

  /// 已添加集合按 providerOrder 排序; 未在顺序表内的追加在后。
  function orderedAddedProviders() {
    const added = new Set(addedProviderIds());
    return orderedAll(providerOrder, [...added]).filter(id => added.has(id));
  }

  /// 保存验证状态 (C082) 并按验证结果驱动启用开关 (C090, 对齐 mac `applyingVerification`):
  /// ok → 启用; failed / needsRelogin → 禁用 (fail-closed)。启用态的唯一事实源是
  /// `subscriptionProviders[id].enabled`, `enabled_providers` 由后端派生。
  async function applyVerification(id, status, reason = null) {
    const map = subscriptionProviderMap();
    const previous = map[id] || {};
    map[id] = {
      ...previous,
      enabled: status === "ok",
      lastVerifiedAt: status === "ok" ? new Date().toISOString() : previous.lastVerifiedAt || null,
      verificationStatus: status,
      failureReason: reason || null,
    };
    await persist({ subscriptionProviders: map });
    renderSubscriptionViews();
  }

  /// 已添加 Provider 的凭证形态副标题 (对齐 mac subscriptionRowSubtitle)。
  function providerSubtitle(id) {
    const count = accountsFor(id).length;
    const kind = CREDENTIAL_FORMS[id] || "API Key";
    return count > 1 ? `${kind} · ${count} 个账号` : kind;
  }

  /// 由凭证内容派生稳定账号 ID (同凭证重复保存即 upsert)。
  /// 由凭证内容派生稳定账号 ID (同凭证重复保存即 upsert)。
  /// C093: StepFun 的站点是可选派生元数据, **不参与账号身份** —— 否则「旧版无条件写入
  /// 国内站 → 修复后再存一次」会生成第二个账号, 旧账号还停在错误站点。以 token 为身份后,
  /// 重新保存即 upsert 到同一账号, 顺带改写或清除站点 (未选站点 → 由采集端按令牌推导)。
  function credentialAccountId(id, credential) {
    // 身份字段: StepFun 以 token、OpenCode GO 以 workspaceId 为身份 (C093 / C085) ——
    // 同一身份重新保存即 upsert, 不会因重新粘贴多出一条账号。
    const identity = credential && typeof credential === "object"
      ? id === "stepfun"
        ? { token: credential.token }
        : id === "opencodeGo"
          ? { workspaceId: credential.oauth?.workspaceId }
          : credential
      : credential;
    const text = `${id}:${JSON.stringify(identity)}`;
    let hash = 5381;
    for (let index = 0; index < text.length; index += 1) hash = ((hash * 33) ^ text.charCodeAt(index)) >>> 0;
    return `${id}-${hash.toString(16).padStart(8, "0")}`;
  }

  /// 对话框字段值 → 采集端凭据载荷 (形状契约见设计规则 21)。
  function providerCredential(id, values) {
    const config = configFor(id);
    if (config.kind === "apiKey") {
      const trimmed = key => (values[key] || "").trim();
      if (id === "volcengine") {
        if (!trimmed("accessKeyId") || !trimmed("secretAccessKey")) throw new Error("火山引擎需要 Access Key 与 Secret Key");
        return { accessKeyId: trimmed("accessKeyId"), secretAccessKey: trimmed("secretAccessKey") };
      }
      if (id === "zhipu") {
        if (!trimmed("apiKey")) throw new Error("请填写 API Key");
        return {
          api_key: trimmed("apiKey"),
          base_url: values.site === "global" ? "https://api.z.ai/api/paas/v4" : "https://open.bigmodel.cn/api/paas/v4",
        };
      }
      if (id === "stepfun") {
        if (!trimmed("token")) throw new Error("请填写 Oasis-Token");
        // C093 / 设计规则 28: 未显式选择站点时不写入 site, 由采集端从令牌推导
        // (国际站 app_id 20700)。写入默认「国内站」会把国际站令牌查错站点。
        const site = values.site;
        return site
          ? { token: trimmed("token"), site, is_global: site === "global" }
          : { token: trimmed("token") };
      }
      if (!trimmed("apiKey")) throw new Error("请填写 API Key");
      return { api_key: trimmed("apiKey") };
    }
    if (id === "codex") throw new Error("Codex 请使用上方「登录新账号」完成设备码登录");
    // Claude / Grok / OpenCode GO: 粘贴凭证 JSON (Claude 亦接受纯令牌)。
    const raw = (values.paste || "").trim();
    if (!raw) throw new Error("请粘贴凭证 JSON");
    let parsed = null;
    try { parsed = JSON.parse(raw); } catch { parsed = null; }
    if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
      return { oauth: oauthPayload(quotaFieldOf(id), parsed, (values.secret || "").trim(), "") };
    }
    if (id === "claude" && raw.length > 10) return { oauth: oauthPayload(quotaFieldOf(id), {}, raw, "") };
    throw new Error("凭证必须是 JSON 对象");
  }

  function quotaFieldOf(id) { return providerDescriptor(id)[2]; }

  /// 打开某个 Provider 的配置对话框。
  function openProviderDialog(id) {
    const host = byId("provider-dialog");
    if (!host) return;
    host.dataset.provider = id;
    host.classList.remove("hidden");
    renderProviderDialog(id);
    const focus = host.querySelector(".cfg-field input, .cfg-paste textarea");
    focus?.focus();
  }

  function closeProviderDialog() {
    stopStepFunWebLogin(true);
    const host = byId("provider-dialog");
    if (!host) return;
    host.classList.add("hidden");
    host.replaceChildren();
    delete host.dataset.provider;
  }

  /// 对话框内容: 标题 + 状态横幅 + 已配置账号 + 字段组 + 固定说明 + 附加区 +
  /// 引导行 + 脚注 + 就地错误 + footer (对齐 mac APIKeyProviderConfigDialog)。
  function renderProviderDialog(id) {
    const host = byId("provider-dialog");
    if (!host) return;
    const config = configFor(id);
    const descriptor = providerDescriptor(id);
    const state = subscriptionProviderState(id);
    const configured = providerConfigured(id);
    host.replaceChildren();

    const dialog = node("div", null, { class: "cfg-dialog" });
    const head = node("div", null, { class: "cfg-head" });
    head.append(providerBadge(id, descriptor[1]), node("span", `配置 ${descriptor[1]}`, { class: "cfg-title" }));
    dialog.append(head);

    const body = node("div", null, { class: "cfg-body" });
    // 状态横幅
    const [label, tone] = configured
      ? VERIFICATION_LABELS[state.verificationStatus] || VERIFICATION_LABELS.none
      : ["未配置", "off"];
    const detail = state.verificationStatus === "failed" && state.failureReason
      ? `验证失败: ${state.failureReason}`
      : state.verificationStatus === "ok"
        // C096: 对齐 mac ProviderStatusBanner 的「已配置 · 上次验证 <时间> · 验证通过」。
        ? `${label}${state.lastVerifiedAt ? ` · 上次验证 ${localTime(state.lastVerifiedAt)}` : ""} · 验证通过`
        : label;
    const banner = node("div", null, { class: `cfg-banner ${configured ? tone : "off"}` });
    banner.append(node("span", null, { class: "cfg-dot", "aria-hidden": "true" }), node("span", detail, { id: "cfg-status", role: "status" }));
    body.append(banner);

    // 账号列表: 形状不合规的账号在读取侧已被丢弃, 故这里只列「计入已配置」的记录。
    const accounts = accountsFor(id);
    if (accounts.length) {
      body.append(node("div", `已配置账号 (${accounts.length})`, { class: "cfg-section" }));
      for (const account of accounts) {
        const line = node("div", null, { class: "cfg-account" });
        line.append(node("span", account.displayName || account.accountId, { class: "cfg-account-name" }));
        if (account.authorizationState === "reauthRequired") line.append(node("span", "需要重新授权", { class: "auth-state warn" }));
        button(line, `cfg-remove-${account.accountId}`, "移除", () => {
          // C096: 账号移除前二次确认 (对齐 mac SettingsView.swift:162 的 confirmationDialog),
          // 不再直接删除 —— 误点即丢凭据。
          const confirm = node("div", null, { class: "cfg-confirm" });
          confirm.append(node("p", `移除 ${account.displayName || account.accountId} 账号?`, { class: "cfg-label" }));
          const act = actions(confirm);
          button(act, `cfg-remove-confirm-${account.accountId}`, "移除账号", async () => {
            try {
              await invoke("remove_credential_account", { field: account.field, accountId: account.accountId });
              await loadCredentials();
              renderProviderDialog(id);
            } catch (error) { message(byId("cfg-status"), `移除失败：${error.message || error}`, "warn"); }
          }, "btn danger");
          button(act, `cfg-remove-cancel-${account.accountId}`, "取消", () => renderProviderDialog(id), "btn");
          body.append(confirm);
        }, "btn link");
        body.append(line);
      }
    }
    // C092: 被读取侧丢弃的旧账号原因。它们不计入「已配置」(规则 21 fail-closed) 且不进
    // 账号清单, 但必须把原因摆出来 —— 否则格式校验收紧后旧账号只是静默变成「未配置」,
    // 用户既不知为何也不知如何处置 (处置入口: 重新配置覆盖, 或用「移除服务」连隐藏账号一并删除)。
    const rejections = rejectionsFor(id);
    if (rejections.length) {
      body.append(node("p", `存在 ${rejections.length} 个格式不合规的旧账号, 未计入「已配置」: ${rejections.map(item => `${item.accountId}（${item.reason}）`).join("; ")}`, { class: "hint", id: `cfg-rejections-${id}` }));
    }

    // Claude 本机登录态跟随 (C075) 现位于对话框内, 元素 id 保持不变。
    if (config.kind === "localFollow" && id === "claude") {
      body.append(node("p", "启用 Claude 订阅后自动只读跟随本机 Claude CLI 登录态（%USERPROFILE%\\.claude\\.credentials.json，缺失时回退 %USERPROFILE%\\.claude.json），不回写、不弹窗。", { class: "hint" }));
      const line = node("div", null, { class: "auth-state-line" });
      line.append(node("span", "检测中…", { id: "claude-local-state", class: "auth-state" }));
      body.append(line);
      const act = actions(body);
      button(act, "claude-local-detect", "立即检测", loadClaudeLocalStatus);
      button(act, "claude-local-import", "读取本机登录态", importClaudeFromLocal, "btn primary");
      act.append(node("span", null, { id: "claude-local-status", role: "status", class: "status-msg" }));
      // 打开对话框即重新探测 (与 mac 打开配置窗口时的实时只读探测同语义)。
      renderClaudeLocalState();
      loadClaudeLocalStatus();
    }

    // C085 / 设计规则 20: Grok 本机登录态跟随 (与 Claude 同范式, mac
    // OfficialLocalProviderSettingsSection)。
    if (config.kind === "localFollow" && id === "grok") {
      body.append(node("p", "启用 Grok 订阅后自动只读跟随本机 Grok CLI 登录态（%USERPROFILE%\\.grok\\auth.json），不回写、不弹窗。", { class: "hint" }));
      const line = node("div", null, { class: "auth-state-line" });
      line.append(node("span", "检测中…", { id: "grok-local-state", class: "auth-state" }));
      body.append(line);
      const act = actions(body);
      button(act, "grok-local-detect", "重新检测", loadGrokLocalStatus);
      button(act, "grok-local-import", "从本机导入", importGrokFromLocal, "btn primary");
      act.append(node("span", null, { id: "grok-local-status", role: "status", class: "status-msg" }));
      renderGrokLocalState();
      loadGrokLocalStatus();
    }

    // 字段组 / 粘贴区
    if (config.kind === "apiKey") {
      for (const [key, label2, placeholder] of config.fields) {
        const group = node("div", null, { class: "cfg-field" });
        group.append(node("label", label2, { class: "cfg-label", for: `cfg-${id}-${key}` }));
        group.append(node("input", null, { id: `cfg-${id}-${key}`, type: "password", placeholder, autocomplete: "new-password", class: "cfg-input" }));
        body.append(group);
      }
      if (config.sitePicker && id === "zhipu") {
        body.append(sitePickerRow(id, [["domestic", "国内站 (open.bigmodel.cn)"], ["global", "国外站 (api.z.ai)"]]));
      }
      if (config.sitePicker && id === "stepfun") {
        // C093 / 设计规则 28: StepFun 站点**不预选** —— 未显式选择时不写入 site,
        // 由采集端从令牌推导 (国际站 app_id 20700)。预选「国内站」会把国际站令牌
        // 查错站点 (采集端优先信任已保存的 site)。
        body.append(sitePickerRow(id, [["domestic", "国内站 (stepfun.com)"], ["global", "国际站 (stepfun.ai)"]], null));
      }
    } else if (config.kind === "paste" || config.kind === "localFollow") {
      // C085: Claude 的粘贴入口收进「高级」折叠区并默认折叠 —— 零配置跟随才是主路径,
      // 手粘令牌是兜底 (对齐 mac ClaudeProviderSettingsSection 的高级入口)。
      const advanced = id === "claude" ? node("details", null, { class: "cfg-advanced" }) : null;
      if (advanced) advanced.append(node("summary", "高级：粘贴令牌或凭证 JSON"));
      const pasteHost = advanced || body;
      const group = node("div", null, { class: "cfg-paste" });
      group.append(node("p", config.pasteLabel, { class: "hint" }));
      group.append(node("textarea", null, { id: `cfg-${id}-paste`, rows: "4", spellcheck: "false", autocomplete: "off", class: "code-area", "aria-label": `${descriptor[1]} 凭证 JSON` }));
      pasteHost.append(group);
      if (id === "claude") {
        const group2 = node("div", null, { class: "cfg-field" });
        group2.append(node("label", "或粘贴纯访问令牌", { class: "cfg-label", for: `cfg-${id}-secret` }));
        group2.append(node("input", null, { id: `cfg-${id}-secret`, type: "password", placeholder: "sk-ant-•••••••• (输入后不回显)", autocomplete: "new-password", class: "cfg-input" }));
        pasteHost.append(group2);
      }
      if (advanced) body.append(advanced);
    } else if (config.kind === "codex") {
      // C084 / 设计规则 23: 设备码登录 + 只读账号发现 (对齐 mac CodexProviderConfigDialog)。
      renderCodexSections(body);
    }

    body.append(node("p", "只保存到本应用的本机凭据文件 (仅当前用户可读), 不会写入其他应用的数据库", { class: "hint" }));
    // StepFun: 网页登录自动绑定区与控制面板 (C086 / 设计规则 24, 对齐 mac StepFunWebLoginView)
    if (id === "stepfun" && config.webLogin) {
      renderStepFunWebLoginSection(body);
    }
    // 火山引擎: 从 CC Switch 只读导入 (C083, 对齐 mac 的确认对话框)
    if (id === "volcengine" && ccSwitchAvailable) {
      const block = node("div", null, { class: "cfg-extra" });
      button(block, "cfg-volcengine-ccswitch", "从 CC Switch 导入", () => {
        block.replaceChildren();
        const confirm = node("div", null, { class: "cfg-confirm" });
        confirm.append(node("p", "从 CC Switch 导入火山引擎凭证?", { class: "cfg-label" }));
        confirm.append(node("p", "只读访问 CC Switch 数据库, 不会修改 CC Switch 的任何数据", { class: "hint" }));
        const act = actions(confirm);
        button(act, "cfg-ccswitch-confirm", "导入", importVolcengineFromCCSwitch, "btn primary");
        button(act, "cfg-ccswitch-cancel", "取消", () => renderProviderDialog(id));
        block.append(confirm);
      });
      body.append(block);
    }
    // 引导行
    const guide = node("div", null, { class: "cfg-guide" });
    guide.append(node("span", "🌐", { class: "cfg-guide-icon", "aria-hidden": "true" }));
    guide.append(node("span", config.guide || "", { class: "cfg-guide-text" }));
    if (config.link) {
      const link = node("a", config.link.title, { href: config.link.url, target: "_blank", rel: "noreferrer", class: "cfg-link" });
      guide.append(link);
    }
    body.append(guide);
    if (config.footnote) body.append(node("p", config.footnote, { class: "hint" }));
    dialog.append(body);

    // footer
    const foot = node("div", null, { class: "cfg-foot" });
    button(foot, `cfg-remove-provider-${id}`, "移除服务", () => {
      // C089 / 设计规则 25: 移除前二次确认 (对齐 mac removeSubscriptionProvider 的破坏性语义)。
      const confirm = node("div", null, { class: "cfg-confirm" });
      confirm.append(node("p", `移除 ${descriptor[1]} 服务?`, { class: "cfg-label" }));
      confirm.append(node("p", "将删除该服务的全部账号凭证并停止查询; 重新添加需再次配置", { class: "hint" }));
      const act = actions(confirm);
      button(act, `cfg-remove-confirm-${id}`, "移除", () => removeProvider(id), "btn danger");
      button(act, `cfg-remove-cancel-${id}`, "取消", () => renderProviderDialog(id), "btn");
      body.append(confirm);
    }, "btn link danger");
    if (configured) {
      button(foot, `cfg-reverify-${id}`, "重新验证", () => reverifyProvider(id), "btn link");
    }
    foot.append(node("div", null, { class: "cfg-spacer" }));
    button(foot, `cfg-cancel-${id}`, "取消", closeProviderDialog);
    const saveButton = button(foot, `cfg-save-${id}`, "保存并验证", () => saveProviderCredential(id), "btn primary");
    // C096: 必填字段未填齐时「保存并验证」置灰 (对齐 mac), 填齐即启用 —— 不再点后才报错。
    const syncSaveDisabled = () => { saveButton.disabled = !providerFieldsFilled(id); };
    syncSaveDisabled();
    for (const field of dialog.querySelectorAll("input") || []) field.addEventListener("input", syncSaveDisabled);
    for (const field of dialog.querySelectorAll("textarea") || []) field.addEventListener("input", syncSaveDisabled);
    dialog.append(foot);
    host.append(dialog);
  }

  /// 对话框必填字段是否已填齐 (C096)。mac 在未填齐时置灰「保存并验证」。
  function providerFieldsFilled(id) {
    const config = configFor(id);
    // 设备码登录类 (Codex) 无密钥字段, 由登录流程自身把关。
    if (config.kind === "codex") return true;
    if (config.kind === "apiKey") {
      return (config.fields || []).every(([key]) => (byId(`cfg-${id}-${key}`)?.value || "").trim().length > 0);
    }
    // 粘贴类 (Claude / Grok / OpenCode GO): 粘贴框或 Claude 的纯令牌入口二者其一。
    if ((byId(`cfg-${id}-paste`)?.value || "").trim()) return true;
    return id === "claude" && (byId(`cfg-${id}-secret`)?.value || "").trim().length > 0;
  }

  // ── Codex 设备码登录与只读发现 (C084 / 设计规则 23) ──────────────────────────

  /// 设备码登录会话: 轮询由前端按服务端 interval 驱动, 便于呈现「等待授权 / 完成」阶段。
  let codexDeviceLogin = null;
  let codexPollTimer = null;

  /// Codex 对话框专属区: 登录新账号 (验证码 + 重新打开验证页 + 取消 + 阶段态) 与两条
  /// 只读发现入口 (按来源文件存在与否显隐)。
  function renderCodexSections(body) {
    const login = node("div", null, { class: "cfg-extra" });
    login.append(node("p", "登录新账号：点击后在浏览器打开的官方验证页输入下方验证码。", { class: "hint" }));
    const loginAct = actions(login);
    button(loginAct, "cfg-codex-login", "登录新账号", startCodexLogin, "btn primary");
    loginAct.append(node("span", null, { id: "cfg-codex-login-status", role: "status", class: "status-msg" }));
    login.append(node("div", null, { id: "cfg-codex-device", class: "cfg-device hidden" }));
    body.append(login);

    const discover = node("div", null, { class: "cfg-extra" });
    discover.append(node("p", "发现本机已登录账号（只读元数据，不导入令牌）：", { class: "hint" }));
    const discoverAct = actions(discover);
    if (codexSources.cliAuth) {
      button(discoverAct, "cfg-codex-discover-cli", "发现本机 CLI 账号", () => importCodexDiscovered("本机 CLI"));
    }
    if (codexSources.ccSwitch) {
      button(discoverAct, "cfg-codex-discover-ccswitch", "发现 CC Switch 账号", () => importCodexDiscovered("CC Switch"));
    }
    if (!codexSources.cliAuth && !codexSources.ccSwitch) {
      discover.append(node("p", "未发现本机 Codex CLI (%USERPROFILE%\\.codex\\auth.json) 或 CC Switch (%USERPROFILE%\\.cc-switch\\codex_oauth_auth.json) 账号文件", { class: "hint" }));
    }
    discoverAct.append(node("span", null, { id: "cfg-codex-discover-status", role: "status", class: "status-msg" }));
    body.append(discover);
    renderCodexDevicePanel();
  }

  async function startCodexLogin() {
    stopCodexPoll();
    const status = byId("cfg-codex-login-status");
    try {
      const started = await invoke("codex_device_start");
      codexDeviceLogin = {
        deviceAuthId: started.deviceAuthId,
        userCode: started.userCode,
        // 0 是合法间隔 (服务端可要求立即轮询), 不能用 `||` 回落。
        intervalSeconds: Number.isFinite(Number(started.intervalSeconds)) ? Number(started.intervalSeconds) : 5,
        expiresInSeconds: Number.isFinite(Number(started.expiresInSeconds)) ? Number(started.expiresInSeconds) : 900,
        issuedAtMillis: Date.now(),
      };
      renderCodexDevicePanel();
      message(status, started.browserOpened ? "已在浏览器打开验证页" : "请手动打开验证页输入验证码");
      scheduleCodexPoll();
    } catch (error) {
      codexDeviceLogin = null;
      renderCodexDevicePanel();
      message(status, `登录发起失败：${error.message || error}`, "warn");
    }
  }

  function renderCodexDevicePanel() {
    const panel = byId("cfg-codex-device");
    if (!panel) return;
    panel.replaceChildren();
    if (!codexDeviceLogin) {
      panel.classList.add("hidden");
      return;
    }
    panel.classList.remove("hidden");
    panel.append(node("p", `验证码：${codexDeviceLogin.userCode}`, { class: "cfg-code", id: "cfg-codex-user-code" }));
    const act = actions(panel);
    button(act, "cfg-codex-reopen", "重新打开验证页", () => { invoke("open_verification_page").catch(() => {}); });
    button(act, "cfg-codex-cancel", "取消", cancelCodexLogin, "btn");
    act.append(node("span", "等待授权中…", { id: "cfg-codex-stage", role: "status", class: "status-msg" }));
  }

  function scheduleCodexPoll() {
    stopCodexPoll();
    if (!codexDeviceLogin) return;
    codexPollTimer = setTimeout(pollCodexLogin, codexDeviceLogin.intervalSeconds * 1000);
  }

  function stopCodexPoll() {
    if (codexPollTimer) {
      clearTimeout(codexPollTimer);
      codexPollTimer = null;
    }
  }

  function cancelCodexLogin() {
    stopCodexPoll();
    codexDeviceLogin = null;
    renderCodexDevicePanel();
    message(byId("cfg-codex-login-status"), "已取消登录");
  }

  async function pollCodexLogin() {
    const session = codexDeviceLogin;
    if (!session) return;
    try {
      const result = await invoke("codex_device_poll", {
        deviceAuthId: session.deviceAuthId,
        userCode: session.userCode,
        issuedAtMillis: session.issuedAtMillis,
        expiresInSeconds: session.expiresInSeconds,
      });
      if (result?.status === "pending") {
        scheduleCodexPoll();
        return;
      }
      stopCodexPoll();
      codexDeviceLogin = null;
      if (result?.status === "expired") {
        renderCodexDevicePanel();
        message(byId("cfg-codex-login-status"), "验证码已过期，请重新发起登录", "warn");
        return;
      }
      await loadCredentials();
      rerenderOpenDialog();
      message(byId("cfg-codex-login-status"), `已登录 ${result?.email || result?.accountId || "新账号"}`);
    } catch (error) {
      stopCodexPoll();
      codexDeviceLogin = null;
      renderCodexDevicePanel();
      message(byId("cfg-codex-login-status"), `登录失败：${error.message || error}`, "warn");
    }
  }

  /// 只读发现本机账号 (C084): 只写元数据, 发现后账号显示为「需要重新授权」。
  async function importCodexDiscovered(sourceLabel) {
    try {
      const result = await invoke("codex_import_discovered");
      await loadCredentials();
      rerenderOpenDialog();
      const added = Number(result?.added) || 0;
      message(
        byId("cfg-codex-discover-status"),
        added > 0 ? `已从${sourceLabel}发现 ${added} 个账号（需重新授权）` : "未发现新账号",
      );
    } catch (error) {
      message(byId("cfg-codex-discover-status"), `发现失败：${error.message || error}`, "warn");
    }
  }

  /// 重绘当前打开的对话框 (登录 / 发现后账号列表需要刷新)。
  function rerenderOpenDialog() {
    const id = byId("provider-dialog")?.dataset.provider;
    if (id) renderProviderDialog(id);
  }

  // ── StepFun 网页登录自动捕获 (C086 / 设计规则 24, 对齐 mac StepFunWebLoginView) ──

  const STEPFUN_SITE_NAMES = {
    domestic: "🇨🇳 国内站",
    global: "🌐 国际站",
  };
  let stepfunWebSession = null;
  let stepfunPollTimer = null;

  function stepfunSiteDisplayName(site) {
    return STEPFUN_SITE_NAMES[site] || STEPFUN_SITE_NAMES.domestic;
  }

  function renderStepFunWebLoginSection(body) {
    const block = node("div", null, { class: "cfg-extra", id: "cfg-stepfun-web-extra" });
    block.append(node("div", "网页登录自动绑定", { class: "cfg-label" }));
    const act = actions(block);
    button(act, "cfg-stepfun-login-domestic", "🇨🇳 登录国内站", () => startStepFunWebLogin("domestic"), "btn primary");
    button(act, "cfg-stepfun-login-global", "🌐 登录国际站", () => startStepFunWebLogin("global"), "btn primary");
    block.append(node("p", "在内置窗口登录对应站点，完成后自动提取 Oasis-Token 绑定", { class: "hint" }));
    block.append(node("div", null, { id: "cfg-stepfun-web-panel", class: "cfg-device hidden" }));
    body.append(block);
    renderStepFunWebPanel();
  }

  function renderStepFunWebPanel() {
    const panel = byId("cfg-stepfun-web-panel");
    if (!panel) return;
    panel.replaceChildren();
    if (!stepfunWebSession) {
      panel.classList.add("hidden");
      return;
    }
    panel.classList.remove("hidden");
    const site = stepfunWebSession.site;
    const siteName = stepfunSiteDisplayName(site);

    // 1. 顶部导航栏: 标题 + 状态行 + 站点切换 + 取消 (对齐 StepFunWebLoginView 顶部栏)
    const nav = node("div", null, { class: "cfg-web-nav" });
    nav.append(node("div", `登录阶跃星辰开放平台 · ${siteName}`, { class: "cfg-label", id: "cfg-stepfun-web-title" }));
    nav.append(node("p", stepfunWebSession.statusText || `正在加载 ${siteName} 登录页面...`, {
      id: "cfg-stepfun-web-status",
      role: "status",
      class: "status-msg",
    }));
    const navAct = actions(nav);
    button(
      navAct,
      "cfg-stepfun-web-site-domestic",
      "🇨🇳 国内站",
      () => switchStepFunWebSite("domestic"),
      site === "domestic" ? "btn primary" : "btn",
    );
    button(
      navAct,
      "cfg-stepfun-web-site-global",
      "🌐 国际站",
      () => switchStepFunWebSite("global"),
      site === "global" ? "btn primary" : "btn",
    );
    button(navAct, "cfg-stepfun-web-cancel", "取消", () => cancelStepFunWebLogin(), "btn");
    panel.append(nav);

    // 2. 网页操作快捷工具栏: 后退 / 前进 / 刷新 / 订阅页 / 平台首页 / 当前 URL
    const toolbar = node("div", null, { class: "cfg-web-toolbar" });
    const toolAct = actions(toolbar);
    button(toolAct, "cfg-stepfun-web-back", "后退", () => runStepFunWebAction("back"), "btn");
    button(toolAct, "cfg-stepfun-web-forward", "前进", () => runStepFunWebAction("forward"), "btn");
    button(toolAct, "cfg-stepfun-web-reload", "刷新", () => runStepFunWebAction("reload"), "btn");
    button(
      toolAct,
      "cfg-stepfun-web-plan",
      site === "global" ? "订阅页 (/plan-subscribe)" : "订阅页 (/step-plan)",
      () => runStepFunWebAction("plan"),
      "btn",
    );
    button(
      toolAct,
      "cfg-stepfun-web-home",
      site === "global" ? "平台首页 (stepfun.ai)" : "平台首页 (stepfun.com)",
      () => runStepFunWebAction("home"),
      "btn",
    );
    toolbar.append(node("p", stepfunWebSession.currentUrl || "", {
      id: "cfg-stepfun-web-url",
      class: "hint wb-mono",
    }));
    panel.append(toolbar);

    // 3. 底部操作栏: 清除登录缓存 / 我已登录，立即绑定
    const foot = actions(panel);
    button(foot, "cfg-stepfun-web-clear", "清除登录缓存", clearStepFunWebSession, "btn danger");
    button(foot, "cfg-stepfun-web-bind", "我已登录，立即绑定", () => pollStepFunWebLogin(true), "btn primary");
  }

  async function startStepFunWebLogin(site) {
    stopStepFunWebPoll();
    const siteName = stepfunSiteDisplayName(site);
    stepfunWebSession = {
      site,
      intervalMs: 2000,
      currentUrl: site === "global" ? "https://platform.stepfun.ai/plan-subscribe" : "https://platform.stepfun.com/step-plan",
      statusText: `正在加载 ${siteName} 登录页面...`,
    };
    renderStepFunWebPanel();
    try {
      const opened = await invoke("stepfun_web_login_open", { site });
      if (!stepfunWebSession || stepfunWebSession.site !== site) return;
      if (opened?.url) stepfunWebSession.currentUrl = opened.url;
      if (Number.isFinite(Number(opened?.intervalMs))) {
        stepfunWebSession.intervalMs = Number(opened.intervalMs);
      }
      stepfunWebSession.statusText = `等待 ${siteName} 登录完成中...`;
      renderStepFunWebPanel();
      scheduleStepFunWebPoll();
    } catch (error) {
      stepfunWebSession = null;
      renderStepFunWebPanel();
      message(byId("cfg-status"), `网页登录窗口打开失败：${error.message || error}`, "warn");
    }
  }

  async function switchStepFunWebSite(site) {
    if (stepfunWebSession?.site === site) return;
    await startStepFunWebLogin(site);
  }

  async function runStepFunWebAction(action) {
    if (!stepfunWebSession) return;
    try {
      const res = await invoke("stepfun_web_login_action", { action, site: stepfunWebSession.site });
      if (stepfunWebSession && res?.url) {
        stepfunWebSession.currentUrl = res.url;
        renderStepFunWebPanel();
      }
    } catch (error) {
      if (byId("cfg-stepfun-web-status")) {
        message(byId("cfg-stepfun-web-status"), `操作失败：${error.message || error}`, "warn");
      }
    }
  }

  async function clearStepFunWebSession() {
    if (!stepfunWebSession) return;
    try {
      const res = await invoke("stepfun_web_login_clear_session", { site: stepfunWebSession.site });
      if (!stepfunWebSession) return;
      if (res?.url) stepfunWebSession.currentUrl = res.url;
      stepfunWebSession.statusText = res?.message || `已清空 ${stepfunSiteDisplayName(stepfunWebSession.site)} 登录缓存，正在刷新...`;
      renderStepFunWebPanel();
    } catch (error) {
      if (byId("cfg-stepfun-web-status")) {
        message(byId("cfg-stepfun-web-status"), `清除缓存失败：${error.message || error}`, "warn");
      }
    }
  }

  function scheduleStepFunWebPoll() {
    stopStepFunWebPoll();
    if (!stepfunWebSession) return;
    stepfunPollTimer = setTimeout(() => pollStepFunWebLogin(false), stepfunWebSession.intervalMs);
  }

  function stopStepFunWebPoll() {
    if (stepfunPollTimer) {
      clearTimeout(stepfunPollTimer);
      stepfunPollTimer = null;
    }
  }

  function stopStepFunWebLogin(closeRemote = false) {
    stopStepFunWebPoll();
    const hadSession = Boolean(stepfunWebSession);
    stepfunWebSession = null;
    if (closeRemote && hadSession) {
      invoke("stepfun_web_login_close").catch(() => {});
    }
  }

  function cancelStepFunWebLogin() {
    stopStepFunWebLogin(true);
    renderStepFunWebPanel();
    message(byId("cfg-status"), "已取消网页登录");
  }

  async function pollStepFunWebLogin(manual = false) {
    const session = stepfunWebSession;
    if (!session) return;
    try {
      const result = await invoke("stepfun_web_login_poll", {
        site: session.site,
        manual: Boolean(manual),
      });
      if (!stepfunWebSession || stepfunWebSession.site !== session.site) return;
      if (result?.currentUrl) stepfunWebSession.currentUrl = result.currentUrl;
      if (result?.status === "closed") {
        stopStepFunWebLogin(false);
        renderStepFunWebPanel();
        return;
      }
      if (result?.status === "captured") {
        stopStepFunWebLogin(false);
        await loadCredentials();
        await reverifyProvider("stepfun");
        rerenderOpenDialog();
        message(byId("cfg-status"), result.message || "已通过网页登录自动绑定 StepFun");
        return;
      }
      if (result?.message) {
        stepfunWebSession.statusText = result.message;
        renderStepFunWebPanel();
      }
      scheduleStepFunWebPoll();
    } catch (error) {
      if (!stepfunWebSession) return;
      stepfunWebSession.statusText = `校验失败：${error.message || error}`;
      renderStepFunWebPanel();
      if (!manual) scheduleStepFunWebPoll();
    }
  }

  /// 移除服务 (C089 / 设计规则 25)。
  ///
  /// 对齐 mac `SubscriptionService.removeSubscriptionProvider`: ① 删除该 Provider 全部凭据
  /// → ② 移出已添加集合。启用集合由后端从 `subscriptionProviders` 派生 (C090), 故移出即关闭
  /// 查询与看板展示, 不需要单独写 `enabledProviders`。
  /// ① 由后端一次原子写完成 (`remove_provider_credentials`): 连同界面不可见的不合规账号与
  /// 遗留整体 OAuth 字段一并删除, 失败时一个都不删 —— 不再逐账号调用, 避免「删了一半」。
  /// ① 失败即中止, 不动已添加集合 (fail-closed)。
  async function removeProvider(id) {
    try {
      await invoke("remove_provider_credentials", { provider: id });
    } catch (error) {
      message(byId("cfg-status"), `移除失败：${error.message || error}`, "warn");
      return;
    }
    const map = subscriptionProviderMap();
    delete map[id];
    const saved = await persist({ subscriptionProviders: map });
    await loadCredentials();
    if (!saved) return;
    renderOrders();
    closeProviderDialog();
  }

  /// 站点单选行。`defaultIndex` 为 null 表示**不预选** (C093: StepFun 未选择时
  /// 不写入 site, 交由采集端从令牌推导); 默认仍预选首项 (Z.ai 需要派生 base_url)。
  function sitePickerRow(id, options, defaultIndex = 0) {
    const group = node("div", null, { class: "cfg-field" });
    group.append(node("span", "站点", { class: "cfg-label" }));
    const picker = node("div", null, { class: "cfg-radios", role: "radiogroup", "aria-label": "站点" });
    options.forEach(([value, title], index) => {
      const option = node("label", null, { class: "cfg-radio" });
      const radio = node("input", null, { type: "radio", name: `cfg-${id}-site`, value, id: `cfg-${id}-site-${value}`, class: "cfg-radio-input" });
      if (defaultIndex !== null && index === defaultIndex) radio.checked = true;
      option.append(radio, node("span", title));
      picker.append(option);
    });
    group.append(picker);
    return group;
  }

  /// 站点选择的显式值; 未选择返回 null (C093)。
  function siteValue(id) {
    if (byId(`cfg-${id}-site-global`)?.checked) return "global";
    if (byId(`cfg-${id}-site-domestic`)?.checked) return "domestic";
    return null;
  }

  /// 读取对话框字段值 (按元素 id 前缀收集, 避免复合选择器依赖)。
  function dialogValues(id) {
    const host = byId("provider-dialog");
    const values = {};
    const prefix = `cfg-${id}-`;
    const collect = element => {
      if (!element.id || !element.id.startsWith(prefix) || element.type === "radio") return;
      values[element.id.slice(prefix.length)] = element.value;
    };
    for (const element of host?.querySelectorAll("input") || []) collect(element);
    for (const element of host?.querySelectorAll("textarea") || []) collect(element);
    if (configFor(id).sitePicker) values.site = siteValue(id);
    return values;
  }

  /// 保存并验证 (C082): 写入凭据 → 立即结构校验 → 落验证状态 → ok 时触发定向刷新。
  async function saveProviderCredential(id) {
    const saveButton = byId(`cfg-save-${id}`);
    if (saveButton) saveButton.disabled = true;
    try {
      const credential = providerCredential(id, dialogValues(id));
      const accountId = credentialAccountId(id, credential);
      const payload = { ...credential, display_name: `${providerDescriptor(id)[1]} · ${accountId.split("-").pop()}` };
      await invoke("save_credential_account", { field: quotaFieldOf(id), accountId, payload });
      await loadCredentials();
      await reverifyProvider(id);
      renderProviderDialog(id);
    } catch (error) {
      message(byId("cfg-status"), `保存失败：${error.message || error}`, "warn");
    } finally {
      if (saveButton) saveButton.disabled = false;
    }
  }

  /// 重新验证 (C082): 后端按写入路径同一套结构校验判定, 通过则触发定向刷新。
  async function reverifyProvider(id) {
    try {
      const result = await invoke("verify_subscription", { provider: id });
      await applyVerification(id, result.status || "none", result.reason || null);
      if (result.status === "ok") invoke("refresh_subscription", { sectionId: providerDescriptor(id)[2] }).catch(() => {});
      return result;
    } catch (error) {
      message(byId("cfg-status"), `验证失败：${error.message || error}`, "warn");
      return { status: "failed", reason: String(error.message || error) };
    }
  }

  function localTime(iso) {
    const date = new Date(iso);
    if (Number.isNaN(date.getTime())) return "";
    return `${date.getMonth() + 1}月${date.getDate()}日 ${String(date.getHours()).padStart(2, "0")}:${String(date.getMinutes()).padStart(2, "0")}`;
  }

  /// 「添加服务」行: 自定义下拉 (原生 select 无法渲染品牌图形) + 添加按钮。
  function renderProviderAddRow() {
    const host = byId("provider-add-row");
    if (!host) return;
    const added = new Set(addedProviderIds());
    const candidates = providers.map(value => value[0]).filter(id => !added.has(id));
    host.replaceChildren();
    host.append(node("span", "添加服务", { class: "row-title" }));
    host.append(node("span", "只列出尚未配置的 Provider, 添加后打开配置窗口", { class: "row-sub" }));
    const picker = node("div", null, { class: "cfg-picker" });
    // C096: 两步交互「选择 → 添加…」(对齐 mac `ProviderPopUpPicker`) —— 选中仅暂存,
    // 必须再点「添加…」才入列表并打开配置对话框, 避免误选直接产生已添加行。
    let pending = null;
    const triggerLabel = node("span", candidates.length ? "选择 Provider" : "全部已添加");
    const trigger = node("button", null, { id: "provider-to-add", type: "button", class: "btn cfg-picker-trigger" });
    trigger.disabled = !candidates.length;
    trigger.append(triggerLabel);
    const menu = node("div", null, { class: "cfg-picker-menu hidden", role: "listbox" });
    // C096: 按钮顺序对齐 mac —— 下拉选择器在前、「添加…」在后 (此前按钮被插在选择器之前)。
    const addButton = node("button", "添加…", { id: "provider-add-confirm", type: "button", class: "btn primary" });
    addButton.disabled = true;
    for (const id of candidates) {
      const option = node("button", null, { type: "button", class: "cfg-picker-option", role: "option" });
      option.append(providerBadge(id, providerDescriptor(id)[1]), node("span", providerDescriptor(id)[1]));
      option.addEventListener("click", () => {
        pending = id;
        triggerLabel.replaceChildren(node("span", providerDescriptor(id)[1]));
        addButton.disabled = false;
        menu.classList.add("hidden");
      });
      menu.append(option);
    }
    trigger.addEventListener("click", () => menu.classList.toggle("hidden"));
    addButton.addEventListener("click", () => { if (pending) return addProvider(pending); });
    picker.append(trigger, menu);
    host.append(picker, addButton);
  }

  /// 添加服务 (C082): 入已添加集合后立即打开配置对话框 (对齐 mac「添加…」)。
  /// 新添加的 Provider 一律**关闭** (对齐 mac: 验证通过才启用, C090)。
  async function addProvider(id) {
    const map = subscriptionProviderMap();
    if (!map[id]) map[id] = { enabled: false, lastVerifiedAt: null, verificationStatus: "none", failureReason: null };
    await persist({ subscriptionProviders: map });
    renderOrders();
    openProviderDialog(id);
  }

  /// 拖拽重排 (C082): 顺序写入 providerOrder, 与看板展示顺序同源。
  function reorderProviders(dragged, target) {
    if (!dragged || dragged === target) return;
    const order = orderedAddedProviders();
    const from = order.indexOf(dragged);
    const to = order.indexOf(target);
    if (from < 0 || to < 0) return;
    order.splice(to, 0, ...order.splice(from, 1));
    providerOrder = orderedAll(order, providers.map(value => value[0]));
    renderOrders();
    persist({ providerOrder: [...providerOrder] }, { revert: () => { providerOrder = orderedAll(settings.providerOrder || [], providers.map(value => value[0])); renderOrders(); } });
  }

  function buildSubscription(host) {
    host.replaceChildren();
    const c1 = card(host, "订阅服务");
    c1.append(node("div", null, { id: "setting-providers", class: "provider-list" }));

    // 添加服务 (C082): 只列尚未添加的 Provider。
    const c2 = card(host, "添加服务");
    c2.append(node("div", null, { id: "provider-add-row", class: "fluent-row" }));

    // C096: 底部提示位于**两张卡下方**且逐字含「统一」(对齐 mac SettingsView.swift:1000)。
    host.append(node("p", "配置并启用后, Agent 用量将在统一授权生效时查询对应云端额度; 拖拽行调整看板展示顺序", { class: "hint subscription-hint" }));

    // 配置对话框浮层: 设置窗口内模态 (mac 为 sheet), 不新建系统窗口。
    const dialogHost = node("div", null, { id: "provider-dialog", class: "cfg-overlay hidden", role: "dialog", "aria-modal": "true" });
    dialogHost.addEventListener("click", event => { if (event.target === dialogHost) closeProviderDialog(); });
    host.append(dialogHost);

    // 本机登录态探测 (C075/C082): 面板构建即探测一次, 结果缓存供对话框渲染。
    loadClaudeLocalStatus();
    // C085: Grok 同范式探测。
    loadGrokLocalStatus();
    loadCCSwitchStatus();
    // Codex 发现来源 (C084): 决定对话框里「发现…账号」按钮的显隐。
    loadCodexSources();
  }

  /// 重建「授权后应用将：」摘要列表 (C094 / 设计规则 29)。
  ///
  /// 云端额度行只列「已启用 ∧ 已配置」的 Provider (对齐 mac
  /// `enabledConfiguredSubscriptionProviders`); 空集走兜底文案。不得以启用集合直接充当
  /// 摘要 —— 全新安装启用集合为空, 但升级前它默认含全部 Provider, 直接列出会与
  /// 「不会访问云端额度接口」的兜底文案自相矛盾。本机登录态探测完成后需重跑 (C091)。
  function renderConsentSummary() {
    const list = byId("consent-list");
    if (!list) return;
    const enabled = enabledProvidersOf()
      .filter(id => providerConfigured(id))
      .map(id => providerDescriptor(id)[1]);
    list.replaceChildren(
      node("li", "扫描本机 Agent 会话目录和 CC Switch 数据库（只读）"),
      node("li", `每 ${Math.round((settings.refreshIntervalSecs || 1800) / 60)} 分钟自动刷新已授权模块`),
      node("li", enabled.length
        ? `确认授权后查询已启用订阅 Provider 的云端额度：${enabled.join(" / ")}`
        : "未配置启用的订阅额度 Provider，不会访问云端额度接口"),
      node("li", "可随时在此撤销授权暂停采集"),
    );
  }

  function buildConsent(host) {
    host.replaceChildren();
    const c1 = card(host, "授权与隐私");
    // mac 语义: 单一模块授权开关 + 「确认授权 / 撤销全部授权」两个动作按钮
    // (采集与云端额度查询同属一次授权), 说明文案随刷新间隔与已启用 provider 动态变化。
    // mac 单一模块授权开关: 切换即等价于「确认授权 / 撤销全部授权」
    const consentToggle = input("setting-usage-consent", "checkbox");
    consentToggle.addEventListener("change", () => applyConsent(consentToggle.checked));
    row(c1, "模型用量", consentToggle, "允许按授权范围采集本机会话用量");
    const lines = node("div", null, { class: "auth-lines" });
    const list = node("ul", null, { id: "consent-list", class: "hint-list" });
    lines.append(node("p", "授权后应用将：", { class: "hint-title" }), list);
    c1.append(lines);
    renderConsentSummary();
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
    // 方案 B (07 §4.2 R3): 软件更新卡置维护页顶部, 先于数据/诊断; 固定文案取共享表现层。
    const cu = card(host, UP.copy.caption);
    const autoWrap = node("div", null, { class: "toggle-with-state" });
    const autoBox = input("setting-auto-update", "checkbox");
    autoWrap.append(node("span", "", { id: "setting-auto-update-state", class: "toggle-state" }), autoBox);
    autoBox.addEventListener("change", () => {
      syncToggleState("setting-auto-update");
      return persist({ autoCheckUpdate: autoBox.checked }, {
        revert: () => { autoBox.checked = !autoBox.checked; syncToggleState("setting-auto-update"); },
      });
    });
    row(cu, UP.copy.autoCheckTitle, autoWrap, UP.copy.autoCheckSubtitle);
    // 版本渠道与上次检查为动态副标题, row() 只接受静态字符串 —— 手砌同构行 (镜像 row() 内部)。
    const versionRow = node("label", null, { class: "fluent-row" });
    const versionMeta = node("div", null, { class: "row-meta" });
    versionMeta.append(node("span", UP.copy.currentVersionTitle, { class: "row-title" }));
    versionMeta.append(node("span", "", { id: "update-channel-sub", class: "row-sub" }));
    versionRow.append(versionMeta, node("span", "—", { id: "setting-version", class: "row-value" }));
    cu.append(versionRow);
    const checkRow = node("label", null, { class: "fluent-row" });
    const checkMeta = node("div", null, { class: "row-meta" });
    checkMeta.append(node("span", UP.copy.checkTitle, { class: "row-title" }));
    checkMeta.append(node("span", "", { id: "update-last-check", class: "row-sub" }));
    const checkBtn = node("button", UP.copy.checkButton, { id: "btn-update-check", type: "button", class: "btn" });
    checkBtn.addEventListener("click", () => invoke("update_check", { manual: true }).catch(() => {}));
    checkRow.append(checkMeta, checkBtn);
    cu.append(checkRow);
    cu.append(node("div", null, { id: "update-stage", class: "update-stage" }));

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

  // MARK: - 软件更新 (T11, 07-软件更新 §4.2 R4)
  // 状态区渲染完全消费共享表现层 UP; 后端 update-state 事件快照为唯一事实源,
  // 与 mac SoftwareUpdateHarness 读同一份 fixture —— 不在此层再造文案。

  let updateSnapshot = null;

  function dispatchUpdateAction(key) {
    const release = updateSnapshot?.release || {};
    const commands = {
      downloadAndInstall: () => invoke("update_download"),
      skipVersion: () => invoke("update_skip", { version: release.version }),
      openReleasePage: () => invoke("open_release_page"),
      cancelDownload: () => invoke("update_cancel"),
      installAndRelaunch: () => invoke("update_install"),
      later: () => invoke("update_dismiss_ready"),
      retry: () => invoke("update_check", { manual: true }),
      manualDownload: () => invoke("open_release_page"),
      resumeChecks: () => invoke("update_unskip"),
    };
    (commands[key] || (() => {}))().catch(() => {});
  }

  function updateActionButton(parent, act) {
    const cls = act.role === "primary" ? "btn primary" : act.role === "plain" ? "btn" : "btn link";
    const el = node("button", act.title, { type: "button", class: cls });
    el.addEventListener("click", () => dispatchUpdateAction(act.key));
    parent.append(el);
    return el;
  }

  function renderUpdateStage(view) {
    const stage = byId("update-stage");
    if (!stage) return;
    stage.replaceChildren();
    if (view.kind === "hidden") return;
    if (view.kind === "spinner" || view.kind === "confirmation") {
      const line = node("div", null, { class: "update-line" });
      if (view.kind === "confirmation") line.append(node("span", "✓", { class: "ok-tick" }));
      else line.append(node("span", null, { class: "update-spinner" }));
      line.append(document.createTextNode(view.text));
      stage.append(line);
      return;
    }
    if (view.kind === "banner") {
      const banner = node("div", null, { class: "update-banner" });
      const head = node("div", null, { class: "update-banner-head" });
      head.append(node("span", view.title, { class: "update-banner-title" }));
      const flow = node("span", null, { class: "ver-flow" });
      flow.append(node("span", view.fromVersion, { class: "from" }),
        node("span", "→", { class: "arrow" }), node("span", view.toVersion, { class: "to" }));
      head.append(flow);
      banner.append(head);
      const notes = node("div", null, { class: "update-notes" });
      if (view.notesTruncated) {
        const renderNotes = expanded => {
          notes.replaceChildren(document.createTextNode(expanded ? view.fullNotes : view.collapsedNotes));
          const toggle = node("span", expanded ? UP.copy.collapseNotes : UP.copy.expandNotes, { class: "more" });
          toggle.addEventListener("click", () => renderNotes(!expanded));
          notes.append(toggle);
        };
        renderNotes(false);
      } else {
        notes.append(document.createTextNode(view.fullNotes));
      }
      banner.append(notes);
      if (view.hint) banner.append(node("p", view.hint, { class: "update-hint" }));
      const actions = node("div", null, { class: "update-banner-actions" });
      for (const act of view.actions) updateActionButton(actions, act);
      if (view.sizeText) actions.append(node("span", view.sizeText, { class: "update-size" }));
      banner.append(actions);
      stage.append(banner);
      return;
    }
    if (view.kind === "download") {
      const wrap = node("div", null, { class: "update-progress" });
      const track = node("div", null, { class: "track" });
      const fill = node("div", null, { class: "fill" });
      fill.style.width = Math.floor((view.fraction || 0) * 100) + "%";
      track.append(fill);
      const meta = node("div", null, { class: "meta" });
      meta.append(node("span", view.meta));
      for (const act of view.actions) updateActionButton(meta, act);
      wrap.append(track, meta);
      stage.append(wrap);
      return;
    }
    if (view.kind === "ready") {
      const line = node("div", null, { class: "update-line" });
      line.append(node("span", "✓", { class: "ok-tick" }), document.createTextNode(view.text));
      const actions = node("div", null, { class: "update-banner-actions" });
      for (const act of view.actions) updateActionButton(actions, act);
      stage.append(line, actions);
      return;
    }
    if (view.kind === "failure") {
      const line = node("div", null, { class: "update-line" });
      line.append(node("span", view.title, { class: "warn-t" }), document.createTextNode(view.detail));
      for (const act of view.actions) updateActionButton(line, act);
      stage.append(line);
      return;
    }
    if (view.kind === "skipped") {
      const line = node("div", null, { class: "update-line" });
      line.append(document.createTextNode(view.text));
      for (const act of view.actions) updateActionButton(line, act);
      stage.append(line);
    }
  }

  function renderUpdateUI() {
    const snap = updateSnapshot;
    if (!snap) return;
    const value = byId("setting-version");
    if (value) {
      const pair = UP.currentVersion(snap.localVersion || null);
      value.textContent = pair.value;
      const channelSub = byId("update-channel-sub");
      if (channelSub) channelSub.textContent = pair.subtitle;
    }
    const lastCheck = byId("update-last-check");
    if (lastCheck) lastCheck.textContent = UP.lastCheckSubtitle(snap.lastCheckAt);
    const autoBox = byId("setting-auto-update");
    if (autoBox) {
      autoBox.checked = Boolean(snap.autoCheck);
      syncToggleState("setting-auto-update");
    }
    const view = UP.stageView(snap.phase, {
      release: snap.release, localVersion: snap.localVersion, canSelfInstall: true,
    });
    renderUpdateStage(view);
    const flags = UP.stageFlags(snap.phase || { kind: "idle" });
    const badge = byId("nav-update-dot");
    if (badge) badge.classList.toggle("hidden", !flags.navBadge);
    const checkBtn = byId("btn-update-check");
    if (checkBtn) checkBtn.disabled = !flags.checkEnabled;
    const status = byId("settings-status");
    if (snap.installFailure) message(status, UP.installFailureStatusLine(snap.installFailure), "warn");
    else if (snap.phase && snap.phase.kind === "failed") message(status, UP.failureStatusLine(snap.phase), "warn");
  }

  async function initSoftwareUpdate() {
    try {
      updateSnapshot = await invoke("update_state");
      renderUpdateUI();
    } catch { /* 后端命令不可用 (浏览器直开) 时维持占位 */ }
    await listen("update-state", event => {
      updateSnapshot = event.payload;
      renderUpdateUI();
    });
  }

  // MARK: - 数据交互逻辑

  async function loadRuntimeInfo() {
    try {
      const info = await invoke("get_runtime_info");
      currentRuntimeInfo = info;
      const status = info.status && typeof info.status === "object" ? info.status : { phase: info.status || info.phase };
      const version = byId("setting-version");
      // 版本值归维护页软件更新卡渲染 (含 dev 降级文案); 后端快照未到时先给 v 前缀占位。
      if (version && !updateSnapshot) version.textContent = info.version ? `v${info.version}` : "—";
      const navVersion = byId("nav-version");
      if (navVersion) navVersion.textContent = info.version ? `v${info.version}` : "";
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
    if (byId("setting-tray-hover-preview")) byId("setting-tray-hover-preview").checked = settings.trayHoverPreview !== false;
    syncToggleState("setting-tray-hover-preview");
    if (byId("setting-hotkey")) byId("setting-hotkey").value = settings.hotkey || "";
    if (byId("setting-theme")) byId("setting-theme").value = settings.theme;
    if (byId("setting-layout-mode")) byId("setting-layout-mode").value = settings.layoutMode || "stack";
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
    // settings-updated 也走此处: 启用态可能已变, 摘要须随行一起重绘 (C094)。
    renderSubscriptionViews();
    for (const render of segmentRenderers) render();
    applyTheme();
  }

  // C081: 三家 OAuth Provider 的 oauth 原生形状 —— 与采集端解析器契约一致
  // (collector-provider 的 claude_token / grok_token / opencode_credential)。
  // 形状不对时采集端会静默查不出额度, 故在此按 Provider 组装, 并由后端二次校验。
  function oauthPayload(field, extra, secret, secondary) {
    if (field === "opencodeGoQuotaAccounts") {
      const auth = String(extra.auth || "").trim();
      const workspaceId = String(extra.workspaceId || "").trim();
      if (!auth || !workspaceId) throw new Error("请粘贴包含 auth 与 workspaceId 的 JSON");
      return { ...extra, auth, workspaceId };
    }
    if (field === "claudeQuotaAccounts") {
      const wrapped = extra.claudeAiOauth || extra["claude.ai_oauth"];
      if (wrapped && typeof wrapped === "object") return extra;
      // 裸 OAuth 条目或纯令牌: 统一包成 claudeAiOauth 包装。
      const entry = { ...extra };
      if (secret) entry.accessToken = secret;
      if (secondary) entry.refreshToken = secondary;
      if (!entry.accessToken) throw new Error("请填写 Access Token 或粘贴 Claude OAuth 凭证 JSON");
      return { claudeAiOauth: entry };
    }
    // Grok: 顶层 key 与作用域条目采集端均可解析, 原样保留; 纯令牌按注入作用域包装。
    if (extra.key || Object.keys(extra).some(key => key.startsWith("https://auth.x.ai::"))) return extra;
    if (!secret) throw new Error("请填写 Access Token 或粘贴 Grok 凭证 JSON");
    return { "https://auth.x.ai::injected": { key: secret } };
  }

  async function loadCredentials() {
    const [fields, , accounts, rejections] = await Promise.all([
      invoke("credential_allowlist"),
      invoke("get_credential_fields"),
      invoke("get_credential_accounts"),
      invoke("get_credential_rejections"),
    ]);
    allowlist = fields;
    credentialAccounts = accounts || [];
    credentialRejections = rejections || [];
    renderOrders();
    // 授权摘要与行尾件都依赖「已配置」判据 (C091 / C094): 凭据加载完成后重跑一次,
    // 否则摘要会停留在「无已配置 Provider」的兜底文案上。
    renderConsentSummary();
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

  // MARK: - Claude 本机登录态 (C075)

  // 状态行文案与 mac ClaudeProviderSettingsSection 同语义: 已跟随 / 未发现 / 已过期。
  // C082: 本机登录态探测在订阅额度页构建时执行 (对齐 mac `refreshOfficialLocalAvailability`
  // 的 onAppear), 结果缓存供 Claude 配置对话框渲染; 对话框内的元素 id 与 C075 保持一致。
  let claudeLocalInfo = null;

  function renderClaudeLocalState() {
    const state = byId("claude-local-state");
    if (!state || !claudeLocalInfo) return;
    const stored = claudeLocalInfo.storedAccountCount || 0;
    if (claudeLocalInfo.status === "followed") {
      state.textContent = stored > 0
        ? `已存 ${stored} 个账号凭证，正在使用`
        : "已启用，自动跟随本机 Claude CLI 登录态";
      state.className = "auth-state ok";
    } else if (claudeLocalInfo.status === "expired") {
      state.textContent = "登录已过期，运行一次 Claude CLI 可自动恢复，Bruce 会重新跟随";
      state.className = "auth-state off";
    } else if (claudeLocalInfo.status === "unavailable") {
      state.textContent = "本机登录态检测不可用";
      state.className = "auth-state off";
    } else {
      state.textContent = "未检测到本机 Claude 登录态，登录 Claude CLI 后自动跟随";
      state.className = "auth-state off";
    }
  }

  async function loadClaudeLocalStatus() {
    try {
      claudeLocalInfo = await invoke("claude_local_status");
    } catch {
      claudeLocalInfo = { status: "unavailable", storedAccountCount: 0 };
    }
    renderClaudeLocalState();
    // 行尾件与授权摘要都依赖本机登录态 (C091 / C094): 探测完成后刷新对应区域。
    if (byId("setting-providers")) renderOrders();
    if (byId("consent-list") || byId("setting-providers")) renderConsentSummary();
  }

  async function importClaudeFromLocal() {
    try {
      const result = await invoke("import_claude_from_local");
      message(byId("claude-local-status"), result?.status === "notFound"
        ? "未发现本机 Claude 登录态，请先登录 Claude CLI 或改用粘贴导入"
        : "已读取本机 Claude 登录态并保存");
      await loadCredentials();
      await loadClaudeLocalStatus();
    } catch (error) { message(byId("claude-local-status"), `读取失败：${error.message || error}`); }
  }

  // MARK: - Grok 本机登录态 (C085 / 设计规则 20)

  // 与 Claude 同范式 (mac OfficialLocalProviderSettingsSection): 只读
  // %USERPROFILE%\.grok\auth.json, 状态行四态文案与「重新检测 / 从本机导入」入口。
  let grokLocalInfo = null;

  function renderGrokLocalState() {
    const state = byId("grok-local-state");
    if (!state || !grokLocalInfo) return;
    const stored = grokLocalInfo.storedAccountCount || 0;
    if (grokLocalInfo.status === "followed") {
      state.textContent = stored > 0
        ? `已存 ${stored} 个账号凭证，正在使用`
        : "已启用，自动跟随本机 Grok CLI 登录态";
      state.className = "auth-state ok";
    } else if (grokLocalInfo.status === "expired") {
      state.textContent = "登录已过期，运行一次 Grok CLI 可自动恢复，Bruce 会重新跟随";
      state.className = "auth-state off";
    } else {
      state.textContent = "未检测到本机 Grok 登录态，登录 Grok CLI 后自动跟随";
      state.className = "auth-state off";
    }
  }

  async function loadGrokLocalStatus() {
    try {
      grokLocalInfo = await invoke("grok_local_status");
    } catch {
      grokLocalInfo = { status: "notFound", storedAccountCount: 0 };
    }
    renderGrokLocalState();
    // 行尾件与授权摘要共用「已配置」判据 (C091 / C094): 探测完成后刷新对应区域。
    if (byId("setting-providers")) renderOrders();
    if (byId("consent-list") || byId("setting-providers")) renderConsentSummary();
  }

  async function importGrokFromLocal() {
    try {
      const result = await invoke("import_grok_from_local");
      message(byId("grok-local-status"), result?.status === "notFound"
        ? "未发现本机 Grok 登录态，请先通过 Grok CLI 登录或改用粘贴导入"
        : "已读取本机 Grok 登录态并保存");
      await loadCredentials();
      await loadGrokLocalStatus();
    } catch (error) { message(byId("grok-local-status"), `读取失败：${error.message || error}`); }
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
      await Promise.all([loadSettings(), loadCredentials(), loadPrices(), loadRuntimeInfo(), loadPlans(), loadClaudeLocalStatus(), initSoftwareUpdate()]);
      await listen("settings-updated", async () => {
        try { await loadSettings(); } catch { message(byId("settings-status"), "设置读取失败"); }
      });
      await listen("dashboard-updated", event => {
        currentDashboard = event.payload;
        renderAgentUsageWorkbench();
      });
      // StepFun 双轨捕获 (C086): WebView2 页面加载事件到达时同步更新当前 URL 并立即试捕一次。
      await listen("stepfun-page-load", event => {
        if (!stepfunWebSession) return;
        const payload = event?.payload || {};
        if (payload.url) {
          stepfunWebSession.currentUrl = payload.url;
          renderStepFunWebPanel();
        }
        if (payload.loading === false) {
          pollStepFunWebLogin(false);
        }
      });
    } catch {
      message(byId("settings-status"), "部分配置读取失败，请重新打开设置");
    }
  })();

  window.BruceSettings = { ready, applyTheme, switchCategory };
})();
