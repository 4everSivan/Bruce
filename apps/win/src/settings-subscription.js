// Settings section: subscription provider rows, provider config dialogs and local CLI login (TD-011).
(() => {
  const core = window.BruceSettingsCore;
  const S = window.BruceSettingsSections;
  const coreState = core.state;
  const { invoke, listen, providers, CATEGORIES, node, byId, UP, REFRESH_PRESETS, TIME_RANGES, SESSION_PROBES, svgEl, catmullRomToBezier, applyTheme, message, persist, input, row, card, segmented, button, actions, segmentRenderers, objectJSON, validateOverrides, orderedAll, move, switchCategory } = core;
  // 跨分节调用经共享命名空间在调用时解析 (脚本按顺序加载, 调用发生在全部加载完成之后)。
  const renderConsentSummary = (...args) => S.renderConsentSummary(...args);
  const oauthPayload = (...args) => S.oauthPayload(...args);
  const loadCredentials = (...args) => S.loadCredentials(...args);

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
  /// `coreState.credentialRejections` 回传 (C092), 不混进本清单。
  function accountsFor(id) { return coreState.credentialAccounts.filter(account => account.field === providerDescriptor(id)[2]); }
  /// 其中「完整可用凭据记录」(C084 / 设计规则 23): 后端逐条下发 `usable`。
  /// 只读发现写入的 metadata-only 记录 (authorization_state = reauthRequired) 会在对话框
  /// 里呈现, 但**不计入「已配置」** —— 它们没有可出站的令牌。旧后端无该字段时按可用处理。
  function usableAccountsFor(id) { return accountsFor(id).filter(account => account.usable !== false); }
  /// 该 Provider 被丢弃账号的原因清单 (C092)。
  function rejectionsFor(id) { return coreState.credentialRejections.filter(item => item.field === providerDescriptor(id)[2]); }

  // T18: 账号显示名固定为 "<Provider> · <标签>"; 用户只编辑标签.
  // 默认标签 «账号 N», N 为同 Provider 内最小未占用序号 (排除正在重命名的账号自身).
  function accountPrefix(id) { return providerDescriptor(id)[1]; }
  function accountLabel(id, displayName) {
    const name = (displayName || "").trim();
    const prefix = `${accountPrefix(id)} · `;
    return name.startsWith(prefix) ? name.slice(prefix.length) : name;
  }
  function nextAccountLabel(id, excludingAccountId = null) {
    const used = new Set(
      accountsFor(id)
        .filter(account => account.accountId !== excludingAccountId)
        .map(account => accountLabel(id, account.displayName || account.accountId).toLowerCase())
    );
    let number = 1;
    while (used.has(`账号 ${number}`.toLowerCase())) number += 1;
    return `账号 ${number}`;
  }
  function defaultAccountDisplayName(id, excludingAccountId = null) {
    return `${accountPrefix(id)} · ${nextAccountLabel(id, excludingAccountId)}`;
  }
  function validateAccountLabel(id, label, accountId) {
    const trimmed = label.trim();
    if (!trimmed) return "账号名称不能为空";
    if (Array.from(trimmed).length > 32) return "账号名称最多 32 个字符";
    if (/[\u0000-\u001F\u007F]/.test(trimmed)) return "账号名称不能包含换行或控制字符";
    const candidate = `${accountPrefix(id)} · ${trimmed}`.toLowerCase();
    const duplicate = accountsFor(id).some(account => account.accountId !== accountId
      && (account.displayName || account.accountId || "").trim().toLowerCase() === candidate);
    return duplicate ? "该名称已被同 Provider 的其他账号使用" : null;
  }
  /// 在参考节点后插入 (DOM harness 只提供 parentElement/children, 无 insertAdjacentElement).
  function insertAfter(reference, nodeToInsert) {
    if (typeof reference.insertAdjacentElement === "function") {
      reference.insertAdjacentElement("afterend", nodeToInsert);
      return;
    }
    const parent = reference.parentElement;
    if (!parent) return;
    const index = parent.children.indexOf(reference);
    if (index >= 0) {
      parent.children.splice(index + 1, 0, nodeToInsert);
      nodeToInsert.parentElement = parent;
    } else {
      parent.append(nodeToInsert);
    }
  }
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
  function enabledProvidersOf() { return coreState.settings.enabledProviders || []; }

  function renderOrders() {
    const cards = byId("setting-card-order");
    if (cards) {
      cards.replaceChildren();
      coreState.cardOrder.forEach((id, index) => {
        const line = node("div", null, { class: "order-row" });
        line.append(node("span", { usage: "Token 用量", subscription: "订阅额度", hourly: "模型用量" }[id] || id));
        const btns = node("div", null, { class: "order-btns" });
        button(btns, `card-up-${id}`, "上移", () => reorder(coreState.cardOrder, index, -1, "cardOrder"));
        button(btns, `card-down-${id}`, "下移", () => reorder(coreState.cardOrder, index, 1, "cardOrder"));
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
        if (coreState.providerPlans[id]) line.append(node("span", coreState.providerPlans[id], { class: "plan-chip" }));
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
    if (coreState.settings.subscriptionProviders) return Object.keys(coreState.settings.subscriptionProviders);
    const enabled = enabledProvidersOf();
    const configured = providers.map(value => value[0]).filter(id => accountsFor(id).length > 0);
    return [...new Set([...enabled, ...configured])];
  }

  /// 可写入的已添加映射 (把派生结果物化为显式集合)。
  function subscriptionProviderMap() {
    if (coreState.settings.subscriptionProviders) return { ...coreState.settings.subscriptionProviders };
    return Object.fromEntries(addedProviderIds().map(id => [id, subscriptionProviderState(id)]));
  }

  /// 单个 Provider 的已添加 / 验证 / 启用状态 (C082 / C090)。
  /// 未迁移时按启用集合播种, 与后端 `added_subscription_providers` 同口径 ——
  /// 否则升级后所有启用开关会显示为关。
  function subscriptionProviderState(id) {
    const stored = (coreState.settings.subscriptionProviders || {})[id];
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

  /// 已添加集合按 coreState.providerOrder 排序; 未在顺序表内的追加在后。
  function orderedAddedProviders() {
    const added = new Set(addedProviderIds());
    return orderedAll(coreState.providerOrder, [...added]).filter(id => added.has(id));
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
        // T18: 行内重命名. 只编辑标签, 前缀「<Provider> ·」由系统维护.
        button(line, `cfg-rename-${account.accountId}`, "重命名", () => {
          byId(`cfg-rename-editor-${account.accountId}`)?.remove();
          const editor = node("div", null, { class: "cfg-confirm", id: `cfg-rename-editor-${account.accountId}` });
          editor.append(node("p", `重命名 ${account.displayName || account.accountId}`, { class: "cfg-label" }));
          const input = node("input", null, {
            id: `cfg-rename-input-${account.accountId}`,
            class: "cfg-input",
            type: "text",
            value: accountLabel(id, account.displayName || account.accountId),
            autocomplete: "off",
          });
          editor.append(input);
          editor.append(node("p", `前缀「${accountPrefix(id)} ·」由系统维护；留空保存恢复默认名`, { class: "hint" }));
          const error = node("p", null, { class: "status-msg warn" });
          editor.append(error);
          const act = actions(editor);
          button(act, `cfg-rename-save-${account.accountId}`, "保存", async () => {
            const raw = input.value.trim();
            if (raw) {
              const problem = validateAccountLabel(id, raw, account.accountId);
              if (problem) {
                error.textContent = problem;
                return;
              }
            }
            const displayName = raw
              ? `${accountPrefix(id)} · ${raw}`
              : defaultAccountDisplayName(id, account.accountId);
            try {
              await invoke("rename_credential_account", {
                field: account.field,
                accountId: account.accountId,
                displayName,
              });
              await loadCredentials();
              renderProviderDialog(id);
            } catch (err) {
              error.textContent = `重命名失败：${err.message || err}`;
            }
          }, "btn primary");
          button(act, `cfg-rename-cancel-${account.accountId}`, "取消", () => renderProviderDialog(id), "btn");
          insertAfter(line, editor);
        }, "btn link");
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
    if (!coreState.stepfunWebSession) {
      panel.classList.add("hidden");
      return;
    }
    panel.classList.remove("hidden");
    const site = coreState.stepfunWebSession.site;
    const siteName = stepfunSiteDisplayName(site);

    // 1. 顶部导航栏: 标题 + 状态行 + 站点切换 + 取消 (对齐 StepFunWebLoginView 顶部栏)
    const nav = node("div", null, { class: "cfg-web-nav" });
    nav.append(node("div", `登录阶跃星辰开放平台 · ${siteName}`, { class: "cfg-label", id: "cfg-stepfun-web-title" }));
    nav.append(node("p", coreState.stepfunWebSession.statusText || `正在加载 ${siteName} 登录页面...`, {
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
    toolbar.append(node("p", coreState.stepfunWebSession.currentUrl || "", {
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
    coreState.stepfunWebSession = {
      site,
      intervalMs: 2000,
      currentUrl: site === "global" ? "https://platform.stepfun.ai/plan-subscribe" : "https://platform.stepfun.com/step-plan",
      statusText: `正在加载 ${siteName} 登录页面...`,
    };
    renderStepFunWebPanel();
    try {
      const opened = await invoke("stepfun_web_login_open", { site });
      if (!coreState.stepfunWebSession || coreState.stepfunWebSession.site !== site) return;
      if (opened?.url) coreState.stepfunWebSession.currentUrl = opened.url;
      if (Number.isFinite(Number(opened?.intervalMs))) {
        coreState.stepfunWebSession.intervalMs = Number(opened.intervalMs);
      }
      coreState.stepfunWebSession.statusText = `等待 ${siteName} 登录完成中...`;
      renderStepFunWebPanel();
      scheduleStepFunWebPoll();
    } catch (error) {
      coreState.stepfunWebSession = null;
      renderStepFunWebPanel();
      message(byId("cfg-status"), `网页登录窗口打开失败：${error.message || error}`, "warn");
    }
  }

  async function switchStepFunWebSite(site) {
    if (coreState.stepfunWebSession?.site === site) return;
    await startStepFunWebLogin(site);
  }

  async function runStepFunWebAction(action) {
    if (!coreState.stepfunWebSession) return;
    try {
      const res = await invoke("stepfun_web_login_action", { action, site: coreState.stepfunWebSession.site });
      if (coreState.stepfunWebSession && res?.url) {
        coreState.stepfunWebSession.currentUrl = res.url;
        renderStepFunWebPanel();
      }
    } catch (error) {
      if (byId("cfg-stepfun-web-status")) {
        message(byId("cfg-stepfun-web-status"), `操作失败：${error.message || error}`, "warn");
      }
    }
  }

  async function clearStepFunWebSession() {
    if (!coreState.stepfunWebSession) return;
    try {
      const res = await invoke("stepfun_web_login_clear_session", { site: coreState.stepfunWebSession.site });
      if (!coreState.stepfunWebSession) return;
      if (res?.url) coreState.stepfunWebSession.currentUrl = res.url;
      coreState.stepfunWebSession.statusText = res?.message || `已清空 ${stepfunSiteDisplayName(coreState.stepfunWebSession.site)} 登录缓存，正在刷新...`;
      renderStepFunWebPanel();
    } catch (error) {
      if (byId("cfg-stepfun-web-status")) {
        message(byId("cfg-stepfun-web-status"), `清除缓存失败：${error.message || error}`, "warn");
      }
    }
  }

  function scheduleStepFunWebPoll() {
    stopStepFunWebPoll();
    if (!coreState.stepfunWebSession) return;
    stepfunPollTimer = setTimeout(() => pollStepFunWebLogin(false), coreState.stepfunWebSession.intervalMs);
  }

  function stopStepFunWebPoll() {
    if (stepfunPollTimer) {
      clearTimeout(stepfunPollTimer);
      stepfunPollTimer = null;
    }
  }

  function stopStepFunWebLogin(closeRemote = false) {
    stopStepFunWebPoll();
    const hadSession = Boolean(coreState.stepfunWebSession);
    coreState.stepfunWebSession = null;
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
    const session = coreState.stepfunWebSession;
    if (!session) return;
    try {
      const result = await invoke("stepfun_web_login_poll", {
        site: session.site,
        manual: Boolean(manual),
      });
      if (!coreState.stepfunWebSession || coreState.stepfunWebSession.site !== session.site) return;
      if (result?.currentUrl) coreState.stepfunWebSession.currentUrl = result.currentUrl;
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
        coreState.stepfunWebSession.statusText = result.message;
        renderStepFunWebPanel();
      }
      scheduleStepFunWebPoll();
    } catch (error) {
      if (!coreState.stepfunWebSession) return;
      coreState.stepfunWebSession.statusText = `校验失败：${error.message || error}`;
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
      const payload = { ...credential };
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

  /// 拖拽重排 (C082): 顺序写入 coreState.providerOrder, 与看板展示顺序同源。
  function reorderProviders(dragged, target) {
    if (!dragged || dragged === target) return;
    const order = orderedAddedProviders();
    const from = order.indexOf(dragged);
    const to = order.indexOf(target);
    if (from < 0 || to < 0) return;
    order.splice(to, 0, ...order.splice(from, 1));
    coreState.providerOrder = orderedAll(order, providers.map(value => value[0]));
    renderOrders();
    persist({ providerOrder: [...coreState.providerOrder] }, { revert: () => { coreState.providerOrder = orderedAll(coreState.settings.providerOrder || [], providers.map(value => value[0])); renderOrders(); } });
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


  Object.assign(window.BruceSettingsSections, {
    providerBadge, providerDescriptor, accountsFor, usableAccountsFor, rejectionsFor,
    localFollowConfigured, providerConfigured, providerState, enabledProvidersOf, renderOrders,
    renderSubscriptionViews, reorder, loadCCSwitchStatus, loadCodexSources, importVolcengineFromCCSwitch,
    configFor, addedProviderIds, subscriptionProviderMap, subscriptionProviderState, orderedAddedProviders,
    applyVerification, providerSubtitle, credentialAccountId, providerCredential, quotaFieldOf,
    openProviderDialog, closeProviderDialog, renderProviderDialog, providerFieldsFilled, renderCodexSections,
    startCodexLogin, renderCodexDevicePanel, scheduleCodexPoll, stopCodexPoll, cancelCodexLogin,
    pollCodexLogin, importCodexDiscovered, rerenderOpenDialog, stepfunSiteDisplayName, renderStepFunWebLoginSection,
    renderStepFunWebPanel, startStepFunWebLogin, switchStepFunWebSite, runStepFunWebAction, clearStepFunWebSession,
    scheduleStepFunWebPoll, stopStepFunWebPoll, stopStepFunWebLogin, cancelStepFunWebLogin, pollStepFunWebLogin,
    removeProvider, sitePickerRow, siteValue, dialogValues, saveProviderCredential,
    reverifyProvider, localTime, renderProviderAddRow, addProvider, reorderProviders,
    buildSubscription, renderClaudeLocalState, loadClaudeLocalStatus, importClaudeFromLocal, renderGrokLocalState,
    loadGrokLocalStatus, importGrokFromLocal,
  });
})();
