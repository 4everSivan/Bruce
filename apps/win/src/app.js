
const el = (tag, cls, text) => {
  const node = document.createElement(tag);
  if (cls) node.className = cls;
  if (text != null) node.textContent = text;
  return node;
};
const svgEl = (tag, attrs) => {
  const node = document.createElementNS("http://www.w3.org/2000/svg", tag);
  for (const [key, value] of Object.entries(attrs)) node.setAttribute(key, value);
  return node;
};

function makeCollapsible(card, summary) {
  const head = card.querySelector(".card-head");
  head.setAttribute("role", "button");
  head.setAttribute("tabindex", "0");
  head.setAttribute("aria-expanded", "true");
  if (summary) {
    const mini = el("div", "collapsed-summary");
    mini.append(summary());
    card.append(mini);
  }
  const toggle = () => {
    const collapsed = card.classList.toggle("collapsed");
    head.classList.toggle("collapsed", collapsed);
    head.setAttribute("aria-expanded", String(!collapsed));
  };
  head.addEventListener("click", toggle);
  head.addEventListener("keydown", event => {
    if (event.key === "Enter" || event.key === " ") { event.preventDefault(); toggle(); }
  });
}

/* ---------- Token 用量卡 ---------- */
function usageCard(usage) {
  const card = el("div", "card");
  const head = el("div", "card-head");
  head.append(el("span", "card-title", "Token 用量"));
  if (usage.isLive) {
    const live = el("span", "hud-dot-wrap live");
    live.append(el("span", "hud-dot"));
    head.append(live);
  }
  head.append(el("span", "chev", "\u276F"));
  card.append(head);
  makeCollapsible(card, () => {
    const mini = document.createElement("span");
    const num = document.createElement("b");
    num.textContent = usage.totalTokensText;
    num.style.cssText = "font-size:17px;font-weight:700;color:#82A57C;font-variant-numeric:tabular-nums;";
    mini.append(num);
    for (const level of usage.collapsedWeekLevels) {
      const bar = document.createElement("span");
      bar.style.cssText = "flex:1;height:10px;border-radius:2px;" + (
        level === 0 ? "background:rgba(255,255,255,.07);"
        : `background:${["#7D9B76","#63885E","#4C7249","#385B38","#26452A"][level-1]};`);
      mini.append(bar);
    }
    return mini;
  });

  // hero 行: 40pt 渐变数字 + tokens + 右侧成本
  const hero = el("div", "hero-row");
  hero.append(el("span", "hero-num", usage.totalTokensText));
  hero.append(el("span", "hero-unit", "tokens"));
  if (usage.costText) hero.append(el("span", "hero-cost", usage.costText));
  card.append(hero);

  card.append(el("div", "divider"));

  // 四格细分
  const row = el("div", "breakdown");
  for (const item of usage.breakdown) {
    const cell = el("div", "cell");
    cell.append(el("div", "label", item.label));
    cell.append(el("div", "value", item.valueText));
    row.append(cell);
  }
  card.append(row);

  // 按月 (3 列 chip, 标题行右侧半年汇总)
  if (usage.monthly.length) {
    const sec = el("div", null); sec.id = "monthly-sec";
    const head2 = el("div", "monthly-head");
    head2.append(el("span", "sec", "按月 · 近 6 个月"));
    if (usage.halfYear) {
      const sum = el("span", "sum");
      sum.append(document.createTextNode("近半年 "));
      sum.append(el("b", null, usage.halfYear.totalText));
      sum.append(document.createTextNode(` · 月均 ${usage.halfYear.averageText}`));
      head2.append(sum);
    }
    sec.append(head2);
    const grid = el("div", "monthly-grid");
    const models = usage.models;
    let selectedKey = models ? models.currentMonthKey : "";
    let mode = "tier0";
    let renderModelRows = () => {};
    let renderSeg = () => {};
    const renderGrid = () => {
      grid.innerHTML = "";
      for (const month of usage.monthly) {
        const chip = el("div", "chip");
        chip.dataset.month = month.key;
        if (month.isCurrent) chip.classList.add("current");
        if (models && mode === "month" && month.key === selectedKey) chip.classList.add("selected");
        chip.append(el("div", "m", month.label));
        chip.append(el("div", "t", month.totalText));
        if (models && month.key) {
          chip.setAttribute("role", "button");
          chip.setAttribute("tabindex", "0");
          const selectMonth = () => { selectedKey = month.key; mode = "month"; renderGrid(); renderSeg(); renderModelRows(); };
          chip.addEventListener("click", selectMonth);
          chip.addEventListener("keydown", event => {
            if (event.key === "Enter" || event.key === " ") { event.preventDefault(); selectMonth(); }
          });
        }
        grid.append(chip);
      }
    };
    renderGrid();
    sec.append(grid);
    card.append(sec);

    // 模型用量: 三档 segment + 月卡联动, 默认本月 top3 + 展开钮;
    // 无模型月度数据 (models 为 null) 时整块隐藏, 对齐 mac 行为。
    if (models) {
      // 模型用量: 三档 segment + 月卡联动, 默认本月 top3 + 展开钮
      const msec = el("div", null); msec.id = "models-sec";
      const mhead = el("div", "models-head");
      const left = el("div", "sec-row");
      const titleSpan = el("span", "sec", "模型用量");
      left.append(titleSpan);
      const expand = el("span", null, "\u2304");
      expand.style.cssText = "font-size:10px;color:var(--subdued);cursor:pointer;transition:transform .15s;";
      left.append(expand);
      mhead.append(left);
      const seg = el("div", "tier-seg");
      renderSeg = () => {
        seg.innerHTML = "";
        models.tiers.forEach((tier, index) => {
          const b = el("button", null, tier.label);
          if (mode === `tier${index}`) b.classList.add("active");
          b.addEventListener("click", () => { mode = `tier${index}`; renderGrid(); renderSeg(); renderModelRows(); });
          seg.append(b);
        });
      };
      renderSeg();
      mhead.append(seg);
      msec.append(mhead);
      const rowsHost = el("div");
      let expanded = false;
      renderModelRows = () => {
        titleSpan.textContent = "模型用量" + (mode === "month" ? ` · ${(usage.monthly.find((m) => m.key === selectedKey) || {}).label || ""}` : "");
        rowsHost.innerHTML = "";
        let rows;
        if (mode === "month") {
          const period = models.months.find((m) => m.id === selectedKey);
          rows = period ? period.rows.slice(0, expanded ? period.rows.length : 3) : [];
        } else {
          const index = Number(mode.slice(4));
          const tier = models.tiers[index];
          rows = tier ? tier.rows.slice(0, expanded ? tier.rows.length : 3) : [];
        }
        for (const row of rows) {
          const line = el("div", "model-row");
          const sw = el("span", "sw"); sw.style.background = row.colorHex;
          line.append(sw, el("span", "name", row.name));
          const track = el("div", "track");
          const fill = el("div"); fill.style.width = `${Math.round(row.share * 100)}%`; fill.style.background = row.colorHex;
          track.append(fill); line.append(track);
          line.append(el("span", "pct", row.pctText));
          line.append(el("span", "tot", row.totalText));
          rowsHost.append(line);
        }
        if (!rows.length) rowsHost.append(el("div", "models-more", "暂无模型数据"));
        const total = mode === "month"
          ? (models.months.find((m) => m.id === selectedKey) || { rows: [] }).rows.length
          : (models.tiers[Number(mode.slice(4))]?.rows || []).length;
        if (total > 3) {
          const more = el("div", "models-more", expanded ? "收起" : `展开全部 ${total} 项`);
          more.addEventListener("click", () => { expanded = !expanded; renderModelRows(); });
          rowsHost.append(more);
        }
      };
      renderModelRows();
      msec.append(rowsHost);
      card.append(msec);
    }
  }

  // 热力图: 标题 + 网格 + 日期轴 + 图例
  if (usage.heatmap.length) {
    const sec = el("div", null); sec.id = "heat-sec";
    sec.append(el("div", "sec", "热力图 · 近半年"));
    const grid = el("div", "heatmap");
    let first = null, last = null;
    for (const week of usage.heatmap) {
      const col = el("div", "col");
      for (const cell of week.cells) {
        const box = el("div", "cell");
        if (!cell) { box.classList.add("empty"); }
        else {
          if (cell.level > 0) box.classList.add(`l${cell.level}`);
          box.title = `${cell.date}  ${cell.total.toLocaleString()}`;
          if (!first) first = cell.date;
          last = cell.date;
        }
        col.append(box);
      }
      grid.append(col);
    }
    sec.append(grid);
    const axis = el("div", "heat-axis");
    const fmt = (value) => { const p = value.split("-"); return `${p[0].slice(2)}/${p[1]}/${p[2]}`; };
    if (first) axis.append(el("span", null, fmt(first)));
    axis.append(el("span", null, ""));
    if (last) axis.append(el("span", null, fmt(last)));
    sec.append(axis);
    const legend = el("div", "heat-legend");
    legend.append(document.createTextNode("少"));
    for (let level = 0; level <= 5; level += 1) {
      const sw = el("span", `sw${level ? ` l${level}` : ""}`);
      legend.append(sw);
    }
    legend.append(document.createTextNode("多"));
    sec.append(legend);
    card.append(sec);
  }
  return card;
}

/* ---------- 订阅用量卡 ---------- */
const PROVIDER_COLORS = { kimi: "#0a84ff", deepseek: "#4A9E5C", volcengine: "#ff9f0a", zhipu: "#bf5af2", codex: "#10a37f", claude: "#ff7a59", grok: "#6c63ff", opencodeGo: "#30d158", stepfun: "#64d2ff" };
function badge(providerID, name) {
  const b = el("span", "pbadge");
  b.style.background = PROVIDER_COLORS[providerID] || "#8e8e93";
  b.textContent = (name || "?").trim().charAt(0).toUpperCase();
  return b;
}
function meterLevel(percent) { return percent < 50 ? "normal" : percent < 80 ? "warning" : "critical"; }
function clampedPercent(value) { return Number.isFinite(value) ? Math.max(0, Math.min(100, value)) : 0; }
function windowRow(row) {
  const line = el("div", "win-row");
  line.append(el("span", "wl", row.label));
  const meter = el("div", `meter ${meterLevel(row.usedPercent)}`);
  const fill = el("div"); fill.style.width = `${Math.round(clampedPercent(row.usedPercent))}%`;
  meter.append(fill); line.append(meter);
  line.append(el("span", "wp", row.percentText));
  line.append(el("span", "wr", row.resetText));
  return line;
}
function subscriptionCard(sub) {
  const card = el("div", "card");
  const head = el("div", "card-head");
  head.append(el("span", "card-title", "订阅用量"));
  if (sub.updatedText) head.append(el("span", "updated", sub.updatedText));
  head.append(el("span", "chev", "\u276F"));
  card.append(head);
  makeCollapsible(card, () => {
    const mini = document.createElement("span");
    for (const section of sub.sections) {
      const peak = section.collapsedWindow || section.windows?.[0];
      if (!peak) continue;
      const group = document.createElement("span");
      group.style.cssText = "display:flex;align-items:center;gap:5px;flex:1;min-width:0;";
      group.append(badge(section.id, section.name));
      const meterEl = document.createElement("span");
      meterEl.className = `meter ${meterLevel(peak.usedPercent)}`;
      meterEl.style.cssText = "flex:1;height:5px;";
      const fill = document.createElement("span");
      fill.style.width = `${Math.round(peak.usedPercent)}%`;
      meterEl.append(fill);
      group.append(meterEl);
      mini.append(group);
    }
    return mini;
  });
  for (const section of sub.sections) {
    const block = el("div", "sub-section");
    const h = el("div", "sub-head");
    h.append(badge(section.id, section.name));
    h.append(el("span", "sub-name", section.name));
    if (section.plan) h.append(el("span", "plan-chip", section.plan));
    if (section.accountCountText) h.append(el("span", "acct-count", section.accountCountText));
    block.append(h);
    const windows = section.windows?.length ? section.windows : [section.collapsedWindow].filter(Boolean);
    for (const row of windows) block.append(windowRow(row));
    if (section.balance) {
      const line = el("div", "balance-row");
      line.append(el("span", "bl", section.balance.label));
      line.append(el("span", "bv", section.balance.amountText));
      block.append(line);
    }
    for (const text of [section.note, section.staleText, section.extraText]) {
      if (text) block.append(el("div", "note-line", text));
    }
    const monthlyBlock = (monthly) => {
      const box = el("div", "monthly-ledger");
      box.append(el("div", "note-line", monthly.state === "trend" ? `本月推算消费 ${monthly.estimatedConsumptionText}` : monthly.state === "baseline" ? "正在建立本月趋势" : "月度统计暂不可用"));
      for (const text of [monthly.currentBalanceText && `当前余额 ${monthly.currentBalanceText}`, monthly.coverageText, monthly.creditNote]) {
        if (text) box.append(el("div", "note-line", text));
      }
      const points = monthly.trendPoints || [];
      if (points.length >= 2) {
        const graph = svgEl("svg", { viewBox: "0 0 300 64", role: "img", "aria-label": "本月累计推算消费趋势", class: "ledger-trend" });
        const values = points.map(p => Number(p.cumulativeConsumption) || 0);
        const peak = Math.max(...values, 0.01);
        graph.append(svgEl("polyline", { points: values.map((v, i) => `${i * 300 / (values.length - 1)},${60 - v * 56 / peak}`).join(" "), fill: "none", stroke: "currentColor", "stroke-width": "2" }));
        box.append(graph);
      }
      return box;
    };
    for (const account of section.accounts || []) {
      const accountBlock = el("details", "account-detail");
      accountBlock.open = true;
      const title = el("summary", null, account.name || account.id);
      if (account.plan) title.append(el("span", "plan-chip", account.plan));
      if (account.tag) title.append(el("span", "plan-chip", account.tag));
      accountBlock.append(title);
      for (const row of account.windows || []) accountBlock.append(windowRow(row));
      for (const text of [account.note, account.lastSuccessText, account.staleText]) {
        if (text) accountBlock.append(el("div", "note-line", text));
      }
      if (account.status && account.status !== "ok") accountBlock.append(el("div", "note-line", statusLabel(account.status)));
      if (account.deepSeekMonthlyUsage && !section.deepSeekMonthlyUsage) accountBlock.append(monthlyBlock(account.deepSeekMonthlyUsage));
      block.append(accountBlock);
    }
    if (section.deepSeekMonthlyUsage) {
      block.append(monthlyBlock(section.deepSeekMonthlyUsage));
    }
    card.append(block);
  }
  return card;
}

/* ---------- Agent 用量卡 (展开: 14 日日柱 + 逐小时行) ---------- */
function hourlyCard(hourly, usage) {
  const card = el("div", "card");
  const head = el("div", "card-head");
  head.append(el("span", "card-title", "Agent 用量"));
  head.append(el("span", "chev", "\u276F"));
  card.append(head);
  makeCollapsible(card, () => el("span", null, hourly.collapsedPeakText || "逐小时用量"));

  if (usage && usage.days.length) {
    const chart = el("div", "daily-chart");
    const maxTotal = Math.max(...usage.days.map((d) => d.total), 1);
    for (const day of usage.days) {
      const col = el("div", "day");
      col.title = `${day.date}  ${day.totalText}`;
      for (const seg of day.segments) {
        const bar = el("div", "seg");
        bar.style.height = `${(seg.value / maxTotal) * 100}%`;
        bar.style.background = seg.colorHex;
        col.append(bar);
      }
      chart.append(col);
    }
    card.append(chart);
    const axis = el("div", "daily-axis");
    axis.append(el("span", null, "14 天前"), el("span", null, "7 天前"), el("span", null, "今天"));
    card.append(axis);
    if (usage.legend.length) {
      const legend = el("div", "daily-legend");
      for (const item of usage.legend) {
        const span = el("span");
        const sw = el("span", "sw"); sw.style.background = item.colorHex;
        span.append(sw, document.createTextNode(item.name));
        legend.append(span);
      }
      card.append(legend);
    }
    card.append(el("div", "divider"));
  }

  const titleRow = el("div", "hourly-title-row");
  titleRow.style.marginTop = "8px";
  titleRow.append(el("span", "sec", "逐小时"));
  titleRow.append(el("span", "range", "0 – 23 时"));
  card.append(titleRow);

  for (const row of hourly.rows) {
    const block = el("div", "agent-row");
    const line1 = el("div", "line1");
    const dot = el("span", "dot"); dot.style.background = row.colorHex;
    line1.append(dot, el("span", "an", row.name), el("span", "at", row.todayTotalText));
    block.append(line1);
    // 24 点迷你柱 (Classic 用点柱表达折线走势, 与收起态 mini 同数据源)
    const points = row.points.length ? row.points : new Array(24).fill(0);
    const peak = Math.max(...points, 1);
    const spark = el("div", "spark");
    spark.style.color = row.colorHex;
    for (const value of points.slice(0, 24)) {
      const bar = el("div", "b");
      bar.style.height = `${Math.max((value / peak) * 100, value > 0 ? 6 : 1)}%`;
      bar.style.opacity = value > 0 ? ".75" : ".18";
      spark.append(bar);
    }
    block.append(spark);
    for (const bars of [row.models, row.projects]) {
      for (const [index, bar] of bars.slice(0, 3).entries()) {
        const line = el("div", "dist-row");
        line.append(el("span", "dn", bar.name));
        const track = el("div", "track");
        const fill = el("div");
        fill.style.width = `${Math.round(bar.share * 100)}%`;
        fill.style.background = row.colorHex;
        fill.style.opacity = String(1 - index * 0.3);
        track.append(fill); line.append(track);
        line.append(el("span", "dv", bar.totalText));
        block.append(line);
      }
    }
    card.append(block);
  }
  return card;
}

/* ---------- 应用层: 缓存读取与单一刷新意图 ---------- */
const { invoke } = window.__TAURI__.core;
const { listen } = window.__TAURI__.event;
let currentPanel = null;
let currentSettings = { cardOrder: ["usage", "subscription", "hourly"], providerOrder: [], usageEnabled: true };

function statusLabel(status) {
  return { ok: "正常", fresh: "正常", refreshing: "刷新中", loading: "刷新中", partial: "部分失败", failed: "刷新失败", error: "失败", stale: "数据过期", unavailable: "不可用", idle: "等待刷新", empty: "暂无数据", authRequired: "需要授权" }[status] || status;
}
function renderStatus(panel) {
  const runtime = panel.runtime || {};
  const diagnostics = panel.diagnostics || [];
  const phase = runtime.phase || (diagnostics.length ? "partial" : panel.usage || panel.subscription ? "fresh" : "empty");
  document.getElementById("runtime-status").textContent = statusLabel(phase);
  const details = [runtime.error];
  if (runtime.lastSuccessAt) details.push(`上次成功 ${runtime.lastSuccessAt}`);
  if (!panel.usage && !panel.subscription && !panel.hourly) details.push("暂无采集数据，可刷新或检查设置。");
  document.getElementById("dashboard-status").textContent = details.filter(Boolean).join(" · ");
  const host = document.getElementById("dashboard-diagnostics");
  host.replaceChildren();
  for (const diagnostic of diagnostics) {
    const identity = diagnostic.serviceId || diagnostic.agentId || diagnostic.module || "";
    const message = diagnostic.note || diagnostic.reason || ({ missingArtifact: "暂无数据", emptyUsageAgents: "尚未发现 Agent 用量" }[diagnostic.kind]) || statusLabel(diagnostic.status || diagnostic.kind);
    host.append(el("div", "note-line", `${identity ? `${identity}: ` : ""}${message}`));
  }
  document.getElementById("refresh").disabled = phase === "refreshing" || phase === "loading";
}
function render(panel) {
  if (!panel || typeof panel !== "object") throw new Error("看板数据不可用");
  currentPanel = panel;
  const activeCount = panel.hourly?.rows.filter(r => r.todayTotal > 0).length || 0;
  document.getElementById("hud-dot-wrap").classList.toggle("live", Boolean(panel.usage?.isLive));
  document.getElementById("hud-agents").textContent = activeCount > 0 ? `● ${activeCount} AGENTS ACTIVE` : "STANDBY";
  renderStatus(panel);
  const stack = document.getElementById("stack");
  stack.replaceChildren();
  const providerOrder = currentSettings.providerOrder || [];
  const subscription = panel.subscription ? { ...panel.subscription, sections: [...panel.subscription.sections].sort((a, b) => {
    const rank = id => providerOrder.includes(id) ? providerOrder.indexOf(id) : providerOrder.length;
    return rank(a.id) - rank(b.id);
  }) } : null;
  const factories = {
    usage: () => currentSettings.usageEnabled !== false && panel.usage ? usageCard(panel.usage) : null,
    subscription: () => subscription ? subscriptionCard(subscription) : null,
    hourly: () => currentSettings.usageEnabled !== false && panel.hourly ? hourlyCard(panel.hourly, panel.usage) : null,
  };
  const order = [...new Set([...(currentSettings.cardOrder || []), "usage", "subscription", "hourly"])];
  for (const key of order) {
    const card = factories[key]?.();
    if (card) { card.dataset.card = key; stack.append(card); }
  }
}
function showError(error) {
  document.getElementById("runtime-status").textContent = "失败";
  document.getElementById("dashboard-status").textContent = String(error);
}
for (const tab of document.querySelectorAll("[data-view]")) {
  tab.addEventListener("click", () => {
    for (const button of document.querySelectorAll("[data-view]")) button.classList.toggle("active", button === tab);
    for (const view of ["dashboard", "credentials", "settings"]) document.getElementById(`view-${view}`).classList.toggle("hidden", view !== tab.dataset.view);
  });
}
document.getElementById("refresh").addEventListener("click", async () => {
  const button = document.getElementById("refresh");
  button.disabled = true;
  try { await invoke("refresh_now"); }
  catch (error) { showError(error); }
  finally { button.disabled = false; }
});
document.getElementById("foot-settings").addEventListener("click", async () => {
  try { await invoke("open_settings"); } catch (error) { showError(error); }
});
document.getElementById("foot-quit").addEventListener("click", async () => {
  try { await invoke("quit_app"); } catch (error) { showError(error); }
});
function applySettings(settings) {
  currentSettings = settings;
  window.BruceSettings?.applyTheme(settings.theme);
  if (currentPanel) render(currentPanel);
}
window.addEventListener("settings-saved", event => applySettings(event.detail));
(async function init() {
  try {
    await listen("dashboard-updated", event => { try { render(event.payload); } catch (error) { showError(error); } });
    await listen("settings-updated", event => applySettings(event.payload));
    await window.BruceSettings?.ready;
    applySettings(await invoke("get_settings"));
    render(await invoke("get_dashboard"));
  } catch (error) { showError(error); }
})();
