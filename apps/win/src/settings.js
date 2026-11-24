// Settings window bootstrap (TD-011): wires navigation, composes the category panes from the
// section scripts and owns the shared settings/dashboard/stepfun event listeners.
// Shared state and DOM helpers live in settings-state.js; section implementations in the
// settings-subscription / settings-workbench / settings-pricing / settings-maintenance scripts.
(() => {
  const core = window.BruceSettingsCore;
  const S = window.BruceSettingsSections;
  const { byId, invoke, listen, message, applyTheme, switchCategory, state } = core;

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

    if (gHost) S.buildGeneral(gHost);
    if (uHost) S.buildAgentUsage(uHost);
    if (sHost) S.buildSubscription(sHost);
    if (cHost) S.buildConsent(cHost);
    if (mHost) S.buildMaintenance(mHost);

    try {
      // C262: 深链走命令参数 + 事件; 先注册事件再取一次待消费值, 避免窗口刚就绪时的竞态。
      await listen("settings-pane-requested", () => { applyPendingPane(); });
      // C262: loadClaudeLocalStatus 已由 buildSubscription 在面板构建时探测一次, 不再重复。
      await Promise.all([S.loadSettings(), S.loadCredentials(), S.loadPrices(), S.loadRuntimeInfo(), S.loadPlans(), S.initSoftwareUpdate(), S.initPricingCatalog()]);
      await listen("settings-updated", async () => {
        try { await S.loadSettings(); } catch { message(byId("settings-status"), "设置读取失败"); }
      });
      await listen("dashboard-updated", event => {
        state.currentDashboard = event.payload;
        S.renderAgentUsageWorkbench();
      });
      // StepFun 双轨捕获 (C086): WebView2 页面加载事件到达时同步更新当前 URL 并立即试捕一次。
      await listen("stepfun-page-load", event => {
        if (!state.stepfunWebSession) return;
        const payload = event?.payload || {};
        if (payload.url) {
          state.stepfunWebSession.currentUrl = payload.url;
          S.renderStepFunWebPanel();
        }
        if (payload.loading === false) {
          S.pollStepFunWebLogin(false);
        }
      });
    } catch {
      message(byId("settings-status"), "部分配置读取失败，请重新打开设置");
    }
  })();

  // C262: 订阅空态 CTA 的分类深链改为后端命令参数 (`open_settings({pane})`) 登记,
  // 设置窗口在初始化与 `settings-pane-requested` 事件到达时取走并切换; 取走即清,
  // 未知分类由 switchCategory 的 CATEGORIES 白名单忽略。不再使用 localStorage 轮询。
  async function applyPendingPane() {
    let pane = null;
    try { pane = await invoke("take_pending_settings_pane"); } catch {}
    if (pane) switchCategory(pane);
  }
  ready.then(applyPendingPane).catch(() => {});

  window.BruceSettings = { ready, applyTheme, switchCategory };
})();
