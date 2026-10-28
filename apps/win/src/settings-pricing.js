// Settings section: model pricing pane (TD-011).
(() => {
  const core = window.BruceSettingsCore;
  const S = window.BruceSettingsSections;
  const coreState = core.state;
  const { invoke, listen, providers, CATEGORIES, node, byId, UP, REFRESH_PRESETS, TIME_RANGES, SESSION_PROBES, svgEl, catmullRomToBezier, applyTheme, message, persist, input, row, card, segmented, button, actions, segmentRenderers, objectJSON, validateOverrides, orderedAll, move, switchCategory } = core;
  // 跨分节调用经共享命名空间在调用时解析 (脚本按顺序加载, 调用发生在全部加载完成之后)。
  const chip = (...args) => S.chip(...args);

  const PRICING_FILTERS = ["全部", "已有用量", "已校准"];
  let pricingFilter = "全部";
  let pricingQuery = "";
  let pricingEditing = null;

  function numberOr(value, fallback) {
    return Number.isFinite(value) ? value : fallback;
  }

  // 有效定价行: 行集与展示元数据来自 mac 目录镜像 (BuiltinModelPricingCatalog),
  // 保持目录顺序 (mac 的分组顺序: Kimi → OpenAI → DeepSeek → 智谱 → StepFun → 混元 →
  // Anthropic → xAI); 用户新增的覆盖项 (不在目录内) 追加在末尾。
  // 今日折算与 mac 同式: 用量 × (输入+输出)/2 / 1e6
  function effectivePricingRows() {
    const overrides = coreState.settings.pricingOverrides || {};
    const usage = new Map((coreState.currentRuntimeInfo?.modelUsage || []).map((row) => [String(row.model).toLowerCase(), row.tokens || 0]));
    const catalog = new Map(coreState.currentModelPrices.map((entry) => [entry.model, entry]));
    const extra = Object.keys(overrides).filter((key) => !catalog.has(key)).sort((a, b) => a.localeCompare(b));
    const keys = [...coreState.currentModelPrices.map((entry) => entry.model), ...extra];
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
    const artifactTotal = coreState.currentRuntimeInfo?.totalCostUsd;
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
    const tokens = (coreState.currentRuntimeInfo?.modelUsage || []).reduce((sum, row) => sum + (row.tokens || 0), 0);
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
      ? JSON.stringify({ pricingOverrides: coreState.settings.pricingOverrides || {} }, null, 2)
      : "// 当前全部使用官方内置基准单价。添加自定义或校准项后将在此展示配置代码：\n{ \"pricingOverrides\": {} }";
    configCard.append(preview);
    container.append(configCard);
    // 隐藏的 JSON 编辑区保留 (全局保存写回 pricingOverrides)
    const overridesField = node("textarea", null, { id: "setting-pricing-overrides", class: "hidden" });
    overridesField.value = JSON.stringify(coreState.settings.pricingOverrides || {}, null, 2);
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
      const overrides = { ...(coreState.settings.pricingOverrides || {}) };
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
      const overrides = { ...(coreState.settings.pricingOverrides || {}) };
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

  Object.assign(window.BruceSettingsSections, {
    numberOr, effectivePricingRows, formatTokens, pricingTodayTotal, renderPricingPane,
    renderModelPrices, openCalibrationSheet, closeCalibrationSheet, persistOverrides, saveCalibration,
    resetPricingOverride, resetAllPricing, showResetAllConfirm,
  });
})();
