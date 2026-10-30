// Settings section: general, consent, maintenance, software update and data loading (TD-011).
(() => {
  const core = window.BruceSettingsCore;
  const S = window.BruceSettingsSections;
  const coreState = core.state;
  const { invoke, listen, providers, CATEGORIES, node, byId, UP, REFRESH_PRESETS, TIME_RANGES, SESSION_PROBES, svgEl, catmullRomToBezier, applyTheme, message, persist, input, row, card, segmented, button, actions, segmentRenderers, objectJSON, validateOverrides, orderedAll, move, switchCategory } = core;
  // 跨分节调用经共享命名空间在调用时解析 (脚本按顺序加载, 调用发生在全部加载完成之后)。
  const providerDescriptor = (...args) => S.providerDescriptor(...args);
  const providerConfigured = (...args) => S.providerConfigured(...args);
  const enabledProvidersOf = (...args) => S.enabledProvidersOf(...args);
  const renderOrders = (...args) => S.renderOrders(...args);
  const renderSubscriptionViews = (...args) => S.renderSubscriptionViews(...args);
  const renderAgentUsageWorkbench = (...args) => S.renderAgentUsageWorkbench(...args);
  const renderSessionProbes = (...args) => S.renderSessionProbes(...args);
  const renderPricingPane = (...args) => S.renderPricingPane(...args);

  function buildGeneral(host) {
    host.replaceChildren();
    // mac generalPane 首卡无分组标题; 行序与 mac 去掉平台独占行后一致 (C153):
    // 界面风格 → 界面动效 → 看板布局 → 刷新间隔 → 系统通知
    // (配色模式 / 钥匙串 / 外部 CLI 来源为 mac 独有能力, Windows 恒深色且无钥匙串;
    // 原「版本」行已迁维护页软件更新卡 —— 07 §4.2 R3 方案 B)。
    const c1 = card(host);
    const theme = node("select", null, { id: "setting-theme" });
    theme.append(node("option", "经典", { value: "fluent" }), node("option", "Nothing", { value: "nothing" }));
    row(c1, "界面风格", segmented(theme, (value, revert) => persist({ theme: value }, { revert })),
      "经典为深色材质面板; Nothing 为纯色平面风格, 无模糊无玻璃 (Windows 恒深色)");
    // C145: 全局界面动效总开关 (与 mac 通用页同名同三态).
    const motion = node("select", null, { id: "setting-motion-preference" });
    motion.append(
      node("option", "跟随系统", { value: "system" }),
      node("option", "始终播放", { value: "always" }),
      node("option", "始终关闭", { value: "never" })
    );
    row(c1, "界面动效", segmented(motion, (value, revert) => persist({ motionPreference: value }, { revert })),
      "关闭后整个应用不做过渡动画；「始终播放」会忽略系统「减少动画」");
    const layout = node("select", null, { id: "setting-layout-mode" });
    layout.append(node("option", "纵向级联 (滚动)", { value: "stack" }), node("option", "顶栏 Tab (单卡)", { value: "tabbed" }));
    row(c1, "看板布局", segmented(layout, (value, revert) => persist({ layoutMode: value }, { revert })),
      "选择置顶面板呈现方式，顶栏 Tab 模式通过右上角小图标在用量、订阅与活跃卡片间快速切换");
    // 刷新间隔对齐 mac 允许集合 (5/15/30/60 分钟); 当前值不在集合内时由 loadSettings
    // 追加为一项, 避免静默改写用户既有配置。
    const interval = node("select", null, { id: "setting-interval" });
    for (const minutes of REFRESH_PRESETS) interval.append(node("option", `${minutes} 分钟`, { value: String(minutes) }));
    row(c1, "刷新间隔", segmented(interval, (value, revert) => persist({ refreshIntervalSecs: Number(value) * 60 }, { revert })),
      "已授权模块的自动采集周期，变更后立即重新计时");
    // C146: 状态由开关开合位置表达, 行内不再渲染「已开启 / 已关闭」.
    const notifyWrap = node("div", null, { class: "toggle-with-state", style: "display: flex; gap: 8px; align-items: center;" });
    const testBubbleBtn = button(notifyWrap, "setting-test-quota-bubble", "测试气泡", async () => {
      try {
        await invoke("test_quota_alert");
      } catch (err) {
        console.error("test_quota_alert failed:", err);
      }
    });
    testBubbleBtn.className = "fluent-btn";
    const notify = input("setting-notifications", "checkbox");
    notifyWrap.append(notify);
    notify.addEventListener("change", () => persist({ notificationsEnabled: notify.checked }, {
      revert: () => { notify.checked = !notify.checked; },
    }));
    row(c1, "额度预警气泡", notifyWrap, "额度紧缺时在托盘图标上方弹出提示微卡; 关闭后不弹出");

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
      field.value = coreState.settings.hotkey || "";
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
    if (hotkey === (coreState.settings.hotkey || "")) return Promise.resolve();
    return persist({ hotkey }, { revert: () => { field.value = coreState.settings.hotkey || ""; } });
  }

  function syncToggleState(id) {
    const box = byId(id), state = byId(`${id}-state`);
    if (!box || !state) return;
    state.textContent = box.checked ? "已开启" : "已关闭";
    state.className = box.checked ? "toggle-state on" : "toggle-state";
  }

  function renderConsentSummary() {
    const list = byId("consent-list");
    if (!list) return;
    const enabled = enabledProvidersOf()
      .filter(id => providerConfigured(id))
      .map(id => providerDescriptor(id)[1]);
    list.replaceChildren(
      node("li", "扫描本机 Agent 会话目录和 CC Switch 数据库（只读）"),
      node("li", `每 ${Math.round((coreState.settings.refreshIntervalSecs || 1800) / 60)} 分钟自动刷新已授权模块`),
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
    state.append(node("span", coreState.settings.consentVersion === 1 ? "当前授权有效" : "尚未授权", { id: "consent-state", class: coreState.settings.consentVersion === 1 ? "auth-state ok" : "auth-state off" }));
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
    // C146: 去掉开关旁状态字, 开合位置即唯一状态表达.
    autoWrap.append(autoBox);
    autoBox.addEventListener("change", () => persist({ autoCheckUpdate: autoBox.checked }, {
      revert: () => { autoBox.checked = !autoBox.checked; },
    }));
    row(cu, UP.copy.autoCheckTitle, autoWrap, UP.copy.autoCheckSubtitle);
    // 版本值与上次检查为动态内容, row() 只接受静态字符串 —— 手砌同构行 (镜像 row() 内部)。
    const versionRow = node("label", null, { class: "fluent-row" });
    const versionMeta = node("div", null, { class: "row-meta" });
    versionMeta.append(node("span", UP.copy.currentVersionTitle, { class: "row-title" }));
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
    const info = coreState.currentRuntimeInfo || {};
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
      value.textContent = UP.currentVersion(snap.localVersion || null).value;
    }
    const lastCheck = byId("update-last-check");
    if (lastCheck) lastCheck.textContent = UP.lastCheckSubtitle(snap.lastCheckAt);
    const autoBox = byId("setting-auto-update");
    if (autoBox) {
      autoBox.checked = Boolean(snap.autoCheck);
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
      coreState.currentRuntimeInfo = info;
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
      coreState.currentModelPrices = await invoke("get_model_prices") || {};
    } catch {
      coreState.currentModelPrices = {};
    }
    renderPricingPane();
  }

  async function loadSettings() {
    coreState.settings = await invoke("get_settings");
    const intervalSelect = byId("setting-interval");
    if (intervalSelect) {
      const minutes = Math.round(coreState.settings.refreshIntervalSecs / 60);
      // 当前值不在 mac 允许集合内 (历史配置) 时追加为一项, 避免静默改写为默认 30 分钟
      if (minutes > 0 && !REFRESH_PRESETS.includes(minutes) && !intervalSelect.querySelector(`option[value="${minutes}"]`)) {
        intervalSelect.append(node("option", `${minutes} 分钟`, { value: String(minutes) }));
      }
      intervalSelect.value = String(minutes);
    }
    if (byId("setting-notifications")) byId("setting-notifications").checked = coreState.settings.notificationsEnabled;
    if (byId("setting-tray-hover-preview")) byId("setting-tray-hover-preview").checked = coreState.settings.trayHoverPreview !== false;
    syncToggleState("setting-tray-hover-preview");
    if (byId("setting-hotkey")) byId("setting-hotkey").value = coreState.settings.hotkey || "";
    if (byId("setting-theme")) byId("setting-theme").value = coreState.settings.theme;
    if (byId("setting-layout-mode")) byId("setting-layout-mode").value = coreState.settings.layoutMode || "stack";
    if (byId("setting-motion-preference")) byId("setting-motion-preference").value = coreState.settings.motionPreference || "system";
    if (byId("setting-usage-consent")) byId("setting-usage-consent").checked = coreState.settings.consentVersion === 1;
    if (byId("setting-usage")) byId("setting-usage").checked = coreState.settings.usageEnabled !== false;
    const consentState = byId("consent-state");
    if (consentState) {
      consentState.textContent = coreState.settings.consentVersion === 1 ? "当前授权有效" : "尚未授权";
      consentState.className = coreState.settings.consentVersion === 1 ? "auth-state ok" : "auth-state off";
    }
    if (byId("setting-pricing-overrides")) byId("setting-pricing-overrides").value = JSON.stringify(coreState.settings.pricingOverrides || {}, null, 2);
    coreState.cardOrder = orderedAll(coreState.settings.cardOrder || [], ["usage", "subscription", "hourly"]);
    coreState.providerOrder = orderedAll(coreState.settings.providerOrder || [], providers.map(value => value[0]));
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
    coreState.allowlist = fields;
    coreState.credentialAccounts = accounts || [];
    coreState.credentialRejections = rejections || [];
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
      coreState.currentDashboard = panel;
      const plans = {};
      for (const section of panel?.subscription?.sections || []) {
        if (section.plan) plans[providerKeyOfSection(section.id)] = section.plan;
      }
      coreState.providerPlans = plans;
      renderOrders();
      renderAgentUsageWorkbench();
    } catch { coreState.providerPlans = {}; }
  }


  Object.assign(window.BruceSettingsSections, {
    buildGeneral, resolveHotkeyPrimaryKey, normalizeHotkeyEvent, setHotkeyRecording, saveHotkey,
    syncToggleState, renderConsentSummary, buildConsent, buildMaintenance, runExport,
    clearCache, showDiagnosticsPreview, applyConsent, dispatchUpdateAction, updateActionButton,
    renderUpdateStage, renderUpdateUI, initSoftwareUpdate, loadRuntimeInfo, loadPrices,
    loadSettings, oauthPayload, loadCredentials, providerKeyOfSection, loadPlans,
  });
})();
