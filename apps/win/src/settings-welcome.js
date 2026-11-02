// Settings section: First-launch Welcome & Guided Onboarding Wizard (T22, 10-首次启动欢迎与引导向导 §4.2).
// 方案 A · 双栏沉浸式向导 (780 × 540): 左侧品牌栏 (224px, 含真实应用图标 icons/icon.png) + 3 步竖向进度轨 + 隐私承诺卡;
// 右侧三步卡片舞台 (Step 1 环境扫描与一键启用 / Step 2 订阅额度连接 / Step 3 外观与快捷唤出)。
(() => {
  const core = window.BruceSettingsCore;
  const S = window.BruceSettingsSections;
  const coreState = core.state;
  const { invoke, providers, node, byId, WP, svgEl, persist, message, switchCategory } = core;

  const DEFAULT_LOCAL_SOURCES = [
    { id: "claude", name: "Claude Code", pathHint: "~/.claude/projects", status: "missing" },
    { id: "codex", name: "Codex CLI", pathHint: "~/.codex/sessions", status: "missing" },
    { id: "kimiCli", name: "Kimi Code CLI", pathHint: "~/.kimi-code/sessions", status: "missing" },
    { id: "kimiWork", name: "Kimi Work", pathHint: "kimi-desktop", status: "missing" },
    { id: "opencode", name: "OpenCode", pathHint: "opencode.db", status: "missing" },
    { id: "pi", name: "Pi", pathHint: "~/.pi/agent/sessions", status: "missing" },
    { id: "zcode", name: "ZCode", pathHint: "~/.zcode/cli/db/db.sqlite", status: "missing" },
    { id: "codebuddy", name: "CodeBuddy", pathHint: "~/.codebuddy/projects", status: "missing" },
    { id: "ccSwitch", name: "CC Switch", pathHint: "~/.cc-switch/cc-switch.db", status: "missing" },
  ];

  const AGENT_COLORS = {
    claude: "#d97757",
    codex: "#10a37f",
    kimiCli: "#0a84ff",
    kimiWork: "#0a84ff",
    opencode: "#8a63d2",
    pi: "#f59e0b",
    zcode: "#3b82f6",
    codebuddy: "#06b6d4",
    ccSwitch: "#10b981",
  };

  let welcomeOpen = false;
  let welcomeAutoEvaluated = false;
  let currentStep = 1;
  let step2Feedback = "";

  function isStep1Activated() {
    return coreState.settings?.consentVersion === 1 && coreState.settings?.usageEnabled !== false;
  }

  function currentProbes() {
    const raw = coreState.currentRuntimeInfo?.localProbes;
    if (Array.isArray(raw) && raw.length > 0) return raw;
    return DEFAULT_LOCAL_SOURCES;
  }

  function stepMeta(index) {
    const list = WP?.steps || [];
    return list.find(item => item.index === index) || list[0] || {
      index: 1,
      railTitle: "环境扫描与启用",
      railSubtitle: "只读检测本机 Agent",
      badgeText: "STEP 01 / 03 · LOCAL AGENT SCAN",
      title: "扫描本机 AI Agent 会话环境",
      subtitle: "",
    };
  }

  function openWelcomeWizard() {
    welcomeOpen = true;
    currentStep = 1;
    step2Feedback = "";
    const overlay = byId("welcome-wizard-overlay");
    if (overlay) overlay.classList.remove("hidden");
    renderWelcomeWizard();
  }

  function closeWelcomeWizard() {
    welcomeOpen = false;
    const overlay = byId("welcome-wizard-overlay");
    if (overlay) overlay.classList.add("hidden");
  }

  function maybeAutoPresentWelcome() {
    if (welcomeAutoEvaluated || !WP) return;
    welcomeAutoEvaluated = true;
    const completedVer = coreState.settings?.welcomeCompletedVersion || 0;
    const consentConfirmed = coreState.settings?.consentVersion === 1;
    if (WP.shouldPresentWelcome(completedVer, consentConfirmed, true)) {
      openWelcomeWizard();
    }
  }

  async function completeWelcomeStep1() {
    const ok = await persist({ consentVersion: 1, usageEnabled: true });
    if (ok) {
      invoke("refresh_now").catch(() => {});
      if (S.loadSettings) await S.loadSettings();
      currentStep = 2;
      renderWelcomeWizard();
    }
  }

  async function completeWelcomeWizard() {
    const ok = await persist({
      consentVersion: 1,
      usageEnabled: true,
      welcomeCompletedVersion: WP ? WP.CURRENT_WELCOME_VERSION : 1,
    });
    if (ok) {
      invoke("refresh_now").catch(() => {});
      closeWelcomeWizard();
      invoke("expand_dashboard").catch(() => {});
    }
  }

  function buildSidebar() {
    const copy = WP?.copy || {};
    const aside = node("aside", null, { class: "welcome-sidebar" });

    // 1. 品牌头部 (含真实本机 App 图标 icons/icon.png)
    const brand = node("div", null, { class: "welcome-brand" });
    const icon = node("img", null, {
      src: "icons/icon.png",
      alt: "Bruce",
      class: "welcome-app-icon",
    });
    const brandMeta = node("div", null, { class: "welcome-brand-meta" });
    const titleRow = node("div", null, { class: "welcome-brand-title-row" });
    titleRow.append(
      node("span", copy.brandName || "Bruce", { class: "welcome-brand-name" }),
      node("span", "WELCOME", { class: "welcome-brand-pill" })
    );
    brandMeta.append(
      titleRow,
      node("span", copy.brandTagline || "AI Agent 用量与额度监控", { class: "welcome-brand-sub" })
    );
    brand.append(icon, brandMeta);
    aside.append(brand);

    // 2. 3 步竖向进度轨
    const rail = node("div", null, { class: "welcome-step-rail", role: "tablist" });
    for (const s of WP?.steps || []) {
      const active = s.index === currentStep;
      const done = s.index < currentStep || (s.index === 1 && isStep1Activated());
      const btn = node("button", null, {
        type: "button",
        class: `welcome-rail-item${active ? " active" : ""}${done ? " done" : ""}`,
        "data-step": String(s.index),
      });
      const bullet = node("span", done && !active ? "✓" : String(s.index), { class: "welcome-rail-bullet" });
      const textWrap = node("div", null, { class: "welcome-rail-text" });
      textWrap.append(
        node("span", s.railTitle, { class: "welcome-rail-title" }),
        node("span", s.railSubtitle, { class: "welcome-rail-sub" })
      );
      btn.append(bullet, textWrap);
      btn.addEventListener("click", () => {
        if (s.index === 1 || isStep1Activated()) {
          currentStep = s.index;
          renderWelcomeWizard();
        }
      });
      rail.append(btn);
    }
    aside.append(rail);

    // 3. 底部翡翠绿本地优先隐私承诺卡
    const privacy = node("div", null, { class: "welcome-privacy-card" });
    const pHead = node("div", null, { class: "welcome-privacy-head" });
    pHead.append(
      node("span", "🛡", { class: "welcome-privacy-icon", "aria-hidden": "true" }),
      node("span", copy.privacyTitle || "100% 本地只读闭环", { class: "welcome-privacy-title" })
    );
    privacy.append(
      pHead,
      node("p", copy.privacyBody || "", { class: "welcome-privacy-body" })
    );
    aside.append(privacy);
    return aside;
  }

  function buildStep1Body() {
    const copy = WP?.copy || {};
    const probes = currentProbes();
    const readyCount = probes.filter(item => item.status === "available").length;
    const wrap = node("div", null, { class: "welcome-step-content" });

    const bar = node("div", null, { class: "welcome-scan-header" });
    const barLeft = node("div", null, { class: "welcome-scan-summary" });
    barLeft.append(
      node("span", copy.step1SectionTitle || "本机 AI Agent 会话源（只读扫描）", { class: "welcome-section-label" }),
      node(
        "span",
        WP ? WP.readySourcesSummary(readyCount) : `已发现 ${readyCount} 个就绪源`,
        { class: "welcome-ready-pill", id: "welcome-ready-summary" }
      )
    );
    const rescanBtn = node("button", copy.step1RescanButton || "重新扫描", {
      type: "button",
      id: "welcome-rescan-btn",
      class: "btn link",
    });
    rescanBtn.addEventListener("click", async () => {
      if (S.loadRuntimeInfo) await S.loadRuntimeInfo();
      renderWelcomeWizard();
    });
    bar.append(barLeft, rescanBtn);
    wrap.append(bar);

    const grid = node("div", null, { class: "welcome-probe-grid" });
    for (const item of probes) {
      const ready = item.status === "available";
      const cell = node("div", null, { class: `welcome-probe-card${ready ? " ready" : ""}` });
      const badge = node("span", (item.name || "?").charAt(0).toUpperCase(), {
        class: "welcome-probe-badge",
        "aria-hidden": "true",
      });
      badge.style.background = AGENT_COLORS[item.id] || "#64748b";
      const meta = node("div", null, { class: "welcome-probe-meta" });
      meta.append(
        node("span", item.name, { class: "welcome-probe-name" }),
        node("span", item.pathHint || "", { class: "welcome-probe-path" })
      );
      const tag = node("span", ready ? "● 已就绪" : "未安装", {
        class: `welcome-probe-status ${ready ? "ok" : "off"}`,
      });
      cell.append(badge, meta, tag);
      grid.append(cell);
    }
    wrap.append(grid);

    const gateCard = node("div", null, { class: "welcome-gate-banner" });
    const gateTop = node("div", null, { class: "welcome-gate-top" });
    gateTop.append(node("strong", copy.step1ConsentTitle || "一步启用：本地会话统计 + 本机 0600 凭据存储"));
    if (isStep1Activated()) {
      gateTop.append(
        node("span", "✓ 已启用本机统计与凭据保护", {
          class: "welcome-activated-pill",
          id: "welcome-step1-activated",
        })
      );
    }
    gateCard.append(
      gateTop,
      node("p", copy.step1ConsentBody || "", { class: "welcome-gate-desc" })
    );
    wrap.append(gateCard);

    return wrap;
  }

  function buildStep2Body() {
    const wrap = node("div", null, { class: "welcome-step-content" });

    // 1. 本机 CLI / CC Switch 快捷发现区
    const discoverSection = node("div", null, { class: "welcome-discover-box" });
    const discoverHead = node("div", null, { class: "welcome-scan-header" });
    discoverHead.append(
      node("span", "本机已登录凭证快捷导入 (零输入只读跟随)", { class: "welcome-section-label" }),
      node("span", "一键导入", { class: "welcome-ready-pill" })
    );
    discoverSection.append(discoverHead);

    const discoverList = node("div", null, { class: "welcome-discover-grid" });
    const quickItems = [
      {
        id: "claude-local",
        name: "Claude Code CLI",
        sub: "只读跟随 ~/.claude 登录态",
        btnText: "一键启用",
        action: async () => {
          if (S.importClaudeFromLocal) await S.importClaudeFromLocal();
          step2Feedback = "已触发本机 Claude CLI 登录态只读导入";
          renderWelcomeWizard();
        },
      },
      {
        id: "codex-local",
        name: "Codex CLI",
        sub: "只读发现 ~/.codex/auth.json 账号",
        btnText: "发现账号",
        action: async () => {
          try {
            await invoke("codex_import_discovered", { source: "cliAuth" });
            if (S.loadCredentials) await S.loadCredentials();
            step2Feedback = "已只读发现本机 Codex CLI 账号";
          } catch (err) {
            step2Feedback = `Codex 发现提示：${err.message || err}`;
          }
          renderWelcomeWizard();
        },
      },
      {
        id: "grok-local",
        name: "Grok CLI",
        sub: "只读跟随 ~/.grok/auth.json",
        btnText: "一键启用",
        action: async () => {
          if (S.importGrokFromLocal) await S.importGrokFromLocal();
          step2Feedback = "已触发本机 Grok CLI 登录态只读导入";
          renderWelcomeWizard();
        },
      },
      {
        id: "ccswitch-local",
        name: "CC Switch 凭据库",
        sub: "只读导入火山引擎 Coding Plan",
        btnText: "从 CC Switch 导入",
        action: async () => {
          if (S.importVolcengineFromCCSwitch) await S.importVolcengineFromCCSwitch();
          step2Feedback = "已执行 CC Switch 火山引擎凭据导入";
          renderWelcomeWizard();
        },
      },
    ];

    for (const q of quickItems) {
      const cardEl = node("div", null, { class: "welcome-discover-card" });
      const meta = node("div", null, { class: "welcome-probe-meta" });
      meta.append(
        node("span", q.name, { class: "welcome-probe-name" }),
        node("span", q.sub, { class: "welcome-probe-path" })
      );
      const actBtn = node("button", q.btnText, {
        type: "button",
        class: "btn welcome-mini-btn",
        id: `welcome-${q.id}-btn`,
      });
      actBtn.addEventListener("click", q.action);
      cardEl.append(meta, actBtn);
      discoverList.append(cardEl);
    }
    discoverSection.append(discoverList);
    if (step2Feedback) {
      discoverSection.append(node("div", step2Feedback, { class: "welcome-feedback-line" }));
    }
    wrap.append(discoverSection);

    // 2. 10 家订阅服务快选网格
    wrap.append(node("div", "全部支持的服务商 (点击可前往设置配置，或直接跳过)", { class: "welcome-section-label" }));
    const pGrid = node("div", null, { class: "welcome-provider-grid" });
    for (const [id, name] of providers) {
      const configured = S.providerConfigured ? S.providerConfigured(id) : false;
      const pBtn = node("button", null, {
        type: "button",
        class: `welcome-provider-card${configured ? " configured" : ""}`,
        "data-provider": id,
      });
      const badge = S.providerBadge ? S.providerBadge(id, name) : node("span", name.charAt(0), { class: "pbadge" });
      const meta = node("div", null, { class: "welcome-probe-meta" });
      meta.append(
        node("span", name, { class: "welcome-probe-name" }),
        node("span", configured ? "✓ 已连接" : "去配置 →", {
          class: `welcome-provider-state ${configured ? "ok" : "off"}`,
        })
      );
      pBtn.append(badge, meta);
      pBtn.addEventListener("click", () => {
        closeWelcomeWizard();
        switchCategory("subscription");
        if (S.openProviderDialog) S.openProviderDialog(id);
      });
      pGrid.append(pBtn);
    }
    wrap.append(pGrid);
    return wrap;
  }

  function buildDualRingSvg() {
    const svg = svgEl("svg", { viewBox: "0 0 36 36", class: "welcome-ring-svg" });
    // 外环轨道 + 进度 (72%)
    svg.append(
      svgEl("circle", {
        cx: "18", cy: "18", r: "14",
        fill: "none", stroke: "rgba(255,255,255,0.14)", "stroke-width": "3.2",
      }),
      svgEl("circle", {
        cx: "18", cy: "18", r: "14",
        fill: "none", stroke: "#38bdf8", "stroke-width": "3.2",
        "stroke-dasharray": "63.3 88", "stroke-linecap": "round",
        transform: "rotate(-90 18 18)",
      }),
      // 内环轨道 + 进度 (34%)
      svgEl("circle", {
        cx: "18", cy: "18", r: "9",
        fill: "none", stroke: "rgba(255,255,255,0.14)", "stroke-width": "3.0",
      }),
      svgEl("circle", {
        cx: "18", cy: "18", r: "9",
        fill: "none", stroke: "#f59e0b", "stroke-width": "3.0",
        "stroke-dasharray": "19.2 56.5", "stroke-linecap": "round",
        transform: "rotate(-90 18 18)",
      })
    );
    return svg;
  }

  function buildStep3Body() {
    const copy = WP?.copy || {};
    const wrap = node("div", null, { class: "welcome-step-content" });

    // 1. I-2 双同心环规实时预览卡
    const previewCard = node("div", null, { class: "welcome-preview-card" });
    const barMock = node("div", null, { class: "welcome-menubar-mock" });
    barMock.append(node("span", "菜单栏 / 托盘实时指示预览", { class: "welcome-menubar-label" }));
    const pill = node("div", null, { class: "welcome-menubar-pill" });
    pill.append(buildDualRingSvg());
    const hoverOn = coreState.settings?.trayHoverPreview !== false;
    const isNothing = coreState.settings?.theme === "nothing";
    const metricText = WP ? WP.menuBarPreviewMetricsText(isNothing, !hoverOn) : (hoverOn ? "68%  124K  $1.28" : "");
    if (metricText) {
      pill.append(node("span", metricText, { class: "welcome-menubar-metrics", id: "welcome-preview-metrics" }));
    }
    barMock.append(pill);
    previewCard.append(barMock);

    const legend = node("div", null, { class: "welcome-ring-legend" });
    legend.append(
      node("div", `${copy.step3RingOuterTitle || "外母环 · 全局平均剩余额度"}（${copy.step3RingOuterSubtitle || ""}）`, { class: "welcome-legend-item outer" }),
      node("div", `${copy.step3RingInnerTitle || "内子环 · 最紧缺窗口短板预警"}（${copy.step3RingInnerSubtitle || ""}）`, { class: "welcome-legend-item inner" })
    );
    previewCard.append(legend);
    wrap.append(previewCard);

    // 2. 主题风格 + 看板布局 + 快捷唤出设置
    const prefsGrid = node("div", null, { class: "welcome-prefs-grid" });

    // 2a. 界面风格
    const styleBox = node("div", null, { class: "welcome-pref-box" });
    styleBox.append(node("div", "界面视觉风格", { class: "welcome-section-label" }));
    const styleRow = node("div", null, { class: "welcome-choice-row" });
    const curTheme = coreState.settings?.theme || "fluent";
    for (const [val, label, desc] of [
      ["fluent", "经典 Fluent", "深色材质层"],
      ["nothing", "Nothing 极简", "纯黑点阵工业风"],
    ]) {
      const btn = node("button", null, {
        type: "button",
        class: `welcome-choice-btn${curTheme === val ? " active" : ""}`,
        "data-theme-choice": val,
      });
      btn.append(
        node("span", label, { class: "welcome-choice-title" }),
        node("span", desc, { class: "welcome-choice-sub" })
      );
      btn.addEventListener("click", async () => {
        await persist({ theme: val });
        if (S.loadSettings) await S.loadSettings();
        renderWelcomeWizard();
      });
      styleRow.append(btn);
    }
    styleBox.append(styleRow);
    prefsGrid.append(styleBox);

    // 2b. 看板布局模式
    const layoutBox = node("div", null, { class: "welcome-pref-box" });
    layoutBox.append(node("div", "看板卡片布局", { class: "welcome-section-label" }));
    const layoutRow = node("div", null, { class: "welcome-choice-row" });
    const curLayout = coreState.settings?.layoutMode || "stack";
    for (const [val, label, desc] of [
      ["stack", "纵向级联", "同屏滚动总览"],
      ["tabbed", "顶栏分页", "紧凑单卡切换"],
    ]) {
      const btn = node("button", null, {
        type: "button",
        class: `welcome-choice-btn${curLayout === val ? " active" : ""}`,
        "data-layout-choice": val,
      });
      btn.append(
        node("span", label, { class: "welcome-choice-title" }),
        node("span", desc, { class: "welcome-choice-sub" })
      );
      btn.addEventListener("click", async () => {
        await persist({ layoutMode: val });
        if (S.loadSettings) await S.loadSettings();
        renderWelcomeWizard();
      });
      layoutRow.append(btn);
    }
    layoutBox.append(layoutRow);
    prefsGrid.append(layoutBox);
    wrap.append(prefsGrid);

    // 3. 托盘实时预览与全局热键行
    const bottomPrefs = node("div", null, { class: "welcome-bottom-prefs" });
    const hoverRow = node("label", null, { class: "welcome-inline-row" });
    const hoverMeta = node("div", null, { class: "welcome-probe-meta" });
    hoverMeta.append(
      node("span", "托盘悬停微缩预览与指标", { class: "welcome-probe-name" }),
      node("span", "悬停任务栏图标时弹出实时用量预览卡", { class: "welcome-probe-path" })
    );
    const hoverToggle = node("input", null, {
      type: "checkbox",
      id: "welcome-hover-preview-toggle",
    });
    hoverToggle.checked = hoverOn;
    hoverToggle.addEventListener("change", async () => {
      await persist({ trayHoverPreview: hoverToggle.checked });
      if (S.loadSettings) await S.loadSettings();
      renderWelcomeWizard();
    });
    hoverRow.append(hoverMeta, hoverToggle);

    const hotkeyRow = node("div", null, { class: "welcome-inline-row" });
    const curHotkey = coreState.settings?.hotkey || "";
    const hkMeta = node("div", null, { class: "welcome-probe-meta" });
    hkMeta.append(
      node("span", "全局唤出快捷键", { class: "welcome-probe-name" }),
      node("span", curHotkey ? `当前快捷键：${curHotkey}` : "推荐设为 Control+Shift+B 一键唤出看板", {
        class: "welcome-probe-path",
      })
    );
    const hkBtn = node("button", curHotkey === "Control+Shift+B" ? "已设 Control+Shift+B" : "设为 Control+Shift+B", {
      type: "button",
      id: "welcome-default-hotkey-btn",
      class: "btn welcome-mini-btn",
    });
    hkBtn.addEventListener("click", async () => {
      await persist({ hotkey: "Control+Shift+B" });
      if (S.loadSettings) await S.loadSettings();
      renderWelcomeWizard();
    });
    hotkeyRow.append(hkMeta, hkBtn);

    bottomPrefs.append(hoverRow, hotkeyRow);
    wrap.append(bottomPrefs);
    return wrap;
  }

  function buildFooter() {
    const copy = WP?.copy || {};
    const footer = node("footer", null, { class: "welcome-footer" });

    if (currentStep === 1) {
      const laterBtn = node("button", "稍后配置", {
        type: "button",
        id: "welcome-later-btn",
        class: "btn link",
      });
      laterBtn.addEventListener("click", () => closeWelcomeWizard());

      const primaryBtn = node(
        "button",
        isStep1Activated() ? "下一步：连接订阅额度 →" : (copy.step1PrimaryButton || "启用本地统计并继续 →"),
        {
          type: "button",
          id: "welcome-step1-cta",
          class: "btn primary welcome-primary-cta",
        }
      );
      primaryBtn.addEventListener("click", () => {
        if (isStep1Activated()) {
          currentStep = 2;
          renderWelcomeWizard();
        } else {
          completeWelcomeStep1();
        }
      });
      footer.append(laterBtn, primaryBtn);
    } else if (currentStep === 2) {
      const backBtn = node("button", "← 上一步", {
        type: "button",
        id: "welcome-step2-back",
        class: "btn",
      });
      backBtn.addEventListener("click", () => {
        currentStep = 1;
        renderWelcomeWizard();
      });

      const rightGroup = node("div", null, { class: "welcome-footer-right" });
      const skipBtn = node("button", copy.step2SkipButton || "稍后在设置中添加，跳过此步 →", {
        type: "button",
        id: "welcome-step2-skip",
        class: "btn link",
      });
      skipBtn.addEventListener("click", () => {
        currentStep = 3;
        renderWelcomeWizard();
      });

      const nextBtn = node("button", "下一步：外观与快捷键 →", {
        type: "button",
        id: "welcome-step2-next",
        class: "btn primary welcome-primary-cta",
      });
      nextBtn.addEventListener("click", () => {
        currentStep = 3;
        renderWelcomeWizard();
      });
      rightGroup.append(skipBtn, nextBtn);
      footer.append(backBtn, rightGroup);
    } else {
      const backBtn = node("button", "← 上一步", {
        type: "button",
        id: "welcome-step3-back",
        class: "btn",
      });
      backBtn.addEventListener("click", () => {
        currentStep = 2;
        renderWelcomeWizard();
      });

      const finishBtn = node("button", copy.step3FinishButton || "完成并打开看板 ↵", {
        type: "button",
        id: "welcome-finish-cta",
        class: "btn primary welcome-finish-cta",
      });
      finishBtn.addEventListener("click", () => completeWelcomeWizard());
      footer.append(backBtn, finishBtn);
    }

    return footer;
  }

  function renderWelcomeWizard() {
    const overlay = byId("welcome-wizard-overlay");
    if (!overlay) return;
    overlay.replaceChildren();
    if (!welcomeOpen) {
      overlay.classList.add("hidden");
      return;
    }
    overlay.classList.remove("hidden");

    const shell = node("div", null, {
      class: "welcome-shell",
      role: "dialog",
      "aria-modal": "true",
      "aria-label": WP?.copy?.windowTitle || "欢迎使用 Bruce",
    });

    shell.append(buildSidebar());

    const stage = node("div", null, { class: "welcome-stage" });
    const meta = stepMeta(currentStep);
    const head = node("header", null, { class: "welcome-stage-header" });
    const headText = node("div", null, { class: "welcome-stage-head-text" });
    headText.append(
      node("div", meta.badgeText, { class: "welcome-step-badge" }),
      node("h2", meta.title, { class: "welcome-stage-title" }),
      node("p", meta.subtitle, { class: "welcome-stage-subtitle" })
    );
    const closeBtn = node("button", "×", {
      type: "button",
      id: "welcome-close-btn",
      class: "welcome-close-btn",
      title: "关闭向导",
      "aria-label": "关闭向导",
    });
    closeBtn.addEventListener("click", () => closeWelcomeWizard());
    head.append(headText, closeBtn);
    stage.append(head);

    if (currentStep === 1) {
      stage.append(buildStep1Body());
    } else if (currentStep === 2) {
      stage.append(buildStep2Body());
    } else {
      stage.append(buildStep3Body());
    }

    stage.append(buildFooter());
    shell.append(stage);
    overlay.append(shell);
  }

  Object.assign(window.BruceSettingsSections, {
    openWelcomeWizard,
    closeWelcomeWizard,
    maybeAutoPresentWelcome,
    completeWelcomeStep1,
    completeWelcomeWizard,
    renderWelcomeWizard,
  });
})();
