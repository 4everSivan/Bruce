
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

/* ---------- 主题强调色 (C220: 对齐 Nothing 深色绿, Windows 恒深色) ---------- */
// hero 渐变、成本、月度 chip、代码流 tint 统一取 #4A9E5C 绿色系; 不再按 usageTier
// 五档换色 (mac C220 同步退役 tier 彩色)。设置页仍使用全局 --accent 蓝色。
const HERO_GRADIENT = ["#2A6B3C", "#8CCB98"];
// 色值只以 CSS 自定义属性下发, 由 styles.css 的 .hero-num / .mini-num 消费;
// 严禁在此写内联背景 —— 内联 background-image 会压过 Nothing 主题的纯色
// 覆写 (C027 实测回归, 见 C029)。
function applyAccentVars(node) {
  node.style.setProperty("--hero-grad-start", HERO_GRADIENT[0]);
  node.style.setProperty("--hero-grad-end", HERO_GRADIENT[1]);
}

/* ---------- 份额文案与色阶 (对齐 mac sharePercentText / distributionGroup) ---------- */
// mac 用 String(format: "%.0f%%") = C 库舍入 (ties-to-even); 用 Math.round 会在
// 恰好 .5 的份额上差 1 个百分点 (如 0.125 → mac "12", JS "13"), 故显式实现。
function roundHalfEven(value) {
  const floor = Math.floor(value);
  const diff = value - floor;
  if (diff > 0.5) return floor + 1;
  if (diff < 0.5) return floor;
  return floor % 2 === 0 ? floor : floor + 1;
}
// 份额文案: 极小非零份额显示 "<1%" (mac sharePercentText 同特例).
function sharePercentText(share) {
  if (share > 0 && share < 0.005) return "<1%";
  return `${roundHalfEven(share * 100)}%`;
}
// 同色系色阶派生: mac 对模型行使用逐 agent 硬编码的四档色阶, Windows 以 HSL
// 提亮近似 (保持色相/饱和度, 逐档 +7/15/23 个百分点), 产出不透明色以避免与卡底混合。
function hexToRgb(hex) {
  const value = String(hex || "").replace("#", "");
  const full = value.length === 3 ? value.split("").map((c) => c + c).join("") : value.padEnd(6, "0").slice(0, 6);
  return [0, 2, 4].map((index) => parseInt(full.slice(index, index + 2), 16) / 255);
}
function rgbToHsl(rgb) {
  const [r, g, b] = rgb;
  const max = Math.max(r, g, b);
  const min = Math.min(r, g, b);
  const lightness = (max + min) / 2;
  const delta = max - min;
  if (delta === 0) return [0, 0, lightness];
  const saturation = lightness > 0.5 ? delta / (2 - max - min) : delta / (max + min);
  const hue = max === r ? ((g - b) / delta + (g < b ? 6 : 0)) : max === g ? (b - r) / delta + 2 : (r - g) / delta + 4;
  return [hue / 6, saturation, lightness];
}
function hslToHex(hue, saturation, lightness) {
  const channel = (offset) => {
    const t = ((offset + hue) % 1 + 1) % 1;
    const q = lightness < 0.5 ? lightness * (1 + saturation) : lightness + saturation - lightness * saturation;
    const p = 2 * lightness - q;
    const value = t < 1 / 6 ? p + (q - p) * 6 * t : t < 1 / 2 ? q : t < 2 / 3 ? p + (q - p) * (2 / 3 - t) * 6 : p;
    return Math.round(Math.max(0, Math.min(1, value)) * 255).toString(16).padStart(2, "0");
  };
  return `#${channel(1 / 3)}${channel(0)}${channel(-1 / 3)}`;
}
const MODEL_SHADE_LIFTS = [0, 0.07, 0.15, 0.23];
// 项目分布色阶为 mac 冻结四色 (projectBarShades), 第 4 条起复用末档。
const PROJECT_SHADES = ["#30b0c7", "#55c2d4", "#7ad4e1", "#9fe5ed"];
function modelShade(hex, index) {
  const [hue, saturation, lightness] = rgbToHsl(hexToRgb(hex));
  return hslToHex(hue, saturation, Math.min(0.92, lightness + MODEL_SHADE_LIFTS[Math.min(index, MODEL_SHADE_LIFTS.length - 1)]));
}
function projectShade(index) {
  return PROJECT_SHADES[Math.min(index, PROJECT_SHADES.length - 1)];
}

/* ---------- Nothing 主题绿阶 (C263: 三端代码生成, 见 config/brand-registry.json) ---------- */
// 色值与 agent 档位来自 brand-registry.generated.js; 未知 agent 用 UTF-8 FNV-1a 64
// 散列落档 (与 Rust/Swift 逐字节一致, 修正旧 UTF-16 32-bit 实现)。
// Windows 恒深色, 故只消费 dark 侧色序。
const BRAND_REGISTRY = window.BRUCE_BRAND_REGISTRY;
function nothingRampHex(agentID) {
  const ramp = BRAND_REGISTRY.nothingRamp.dark;
  const known = BRAND_REGISTRY.agentTiers[agentID];
  if (known !== undefined) return ramp[known];
  const hash = BRAND_REGISTRY.fnv1a64(agentID);
  return ramp[Number(hash % BigInt(ramp.length))];
}
function isNothingTheme() {
  return document.body.classList.contains("theme-nothing");
}

/* ---------- SF Symbols 等价线性图标 (mac chevron.right / chevron.down) ---------- */
// 16×16 视窗自绘描边几何, 颜色经 currentColor 由 CSS 决定 (不引第三方图标库)。
const ICON_PATHS = {
  chevronRight: ["M6 3.5 L10.5 8 L6 12.5"],
  chevronDown: ["M3.5 6 L8 10.5 L12.5 6"],
  // arrow.clockwise: 300° 圆弧 + 顶部向右箭头 (与底栏刷新图标同一几何)
  arrowClockwise: ["M12.76 5.25A5.5 5.5 0 1 1 8 2.5", "M6.3 0.8L8.3 2.5L6.3 4.2"],
  // activity (mac SF Symbol waveform.path.ecg): 空态脉冲线
  activity: ["M1 8h2.2l1.4-4.2 2.6 8.4 1.9-5.8 1.3 1.6H15"],
  // creditcard (mac SF Symbol creditcard): 圆角卡体 + 磁条
  creditCard: ["M2 4.5h12a1 1 0 0 1 1 1v5a1 1 0 0 1-1 1H2a1 1 0 0 1-1-1v-5a1 1 0 0 1 1-1z", "M1 7.25h14"],
};
function icon(name, strokeWidth = 2.2) {
  const svg = svgEl("svg", { viewBox: "0 0 16 16", "aria-hidden": "true" });
  for (const d of ICON_PATHS[name]) {
    svg.append(svgEl("path", {
      d, fill: "none", stroke: "currentColor", "stroke-width": String(strokeWidth),
      "stroke-linecap": "round", "stroke-linejoin": "round",
    }));
  }
  return svg;
}

/* ---------- SVG 迷你走势 (mac LineMark 默认线性插值 + 渐变面积) ---------- */
let sparkSeq = 0;
// 颜色经 currentColor 传递, 由 CSS 决定 (Nothing 主题覆写为 heroGreen);
// 严禁内联描边色 —— 会压过主题覆写 (C029 教训)。mac 仪表盘折线未设
// interpolationMethod, 即逐点直线连接 (只有设置页时序图用 catmullRom)。
function lineSpark(points, height) {
  const width = 240;
  // mac chartYScale(domain: 0...max*1.1): 顶部留 10% 余量, 峰值线不被裁掉
  const peak = Math.max(...points, 1) * 1.1;
  const step = points.length > 1 ? width / (points.length - 1) : width;
  const coords = points.map((value, index) => `${(index * step).toFixed(2)},${(height - (value / peak) * height).toFixed(2)}`);
  if (coords.length === 1) coords.push(`${width},${coords[0].split(",")[1]}`);
  const pathD = `M ${coords.join(" L ")}`;
  const areaD = `${pathD} L ${width},${height} L 0,${height} Z`;
  const svg = svgEl("svg", {
    viewBox: `0 0 ${width} ${height}`,
    preserveAspectRatio: "none",
    class: "sparkline",
    "aria-hidden": "true",
  });
  const gradientId = `spark-fill-${sparkSeq += 1}`;
  const gradient = svgEl("linearGradient", { id: gradientId, x1: "0", y1: "0", x2: "0", y2: "1" });
  // classic: 主色 18% → 2% (mac AreaMark); Nothing 由 CSS 覆写为 16% → 0
  gradient.append(svgEl("stop", { offset: "0%", "stop-color": "currentColor", "stop-opacity": "0.18", class: "stop-top" }));
  gradient.append(svgEl("stop", { offset: "100%", "stop-color": "currentColor", "stop-opacity": "0.02", class: "stop-bottom" }));
  const defs = svgEl("defs", {});
  defs.append(gradient);
  svg.append(defs);
  svg.append(svgEl("path", {
    d: areaD,
    fill: `url(#${gradientId})`,
    class: "spark-area",
  }));
  svg.append(svgEl("path", {
    d: pathD,
    fill: "none",
    stroke: "currentColor",
    "stroke-width": "1.5",
    "vector-effect": "non-scaling-stroke",
    "stroke-linejoin": "round",
    "stroke-linecap": "round",
    class: "spark-curve",
  }));
  return svg;
}

/* ---------- 卡片背景字符流纹样 (mac CodeStreamBackground 的静态等价) ---------- */
// 确定性伪随机字符网格渲染成单个 SVG data URI, 由 CSS 变量挂到卡片 background-image;
// 不进 DOM 节点 (mac 侧是逐字 Text 网格, Windows 用背景层等价且零布局成本)。
const CODE_STREAM_CHARS = ".:+*#";
const codeStreamCache = new Map();
function codeStreamImage(tint) {
  if (codeStreamCache.has(tint)) return codeStreamCache.get(tint);
  const cols = 26;
  const rows = 20;
  const cell = 16;
  let seed = 0x2f6e2b1;
  const random = () => {
    seed = (seed * 1103515245 + 12345) & 0x7fffffff;
    return seed / 0x7fffffff;
  };
  let glyphs = "";
  for (let row = 0; row < rows; row += 1) {
    for (let col = 0; col < cols; col += 1) {
      const glyph = CODE_STREAM_CHARS[Math.floor(random() * CODE_STREAM_CHARS.length)];
      const opacity = (0.05 + random() * 0.09).toFixed(3);
      glyphs += `<text x="${col * cell}" y="${row * cell + 10}" font-size="9" font-family="monospace" fill="${tint}" fill-opacity="${opacity}">${glyph}</text>`;
    }
  }
  const uri = `url("data:image/svg+xml,${encodeURIComponent(`<svg xmlns="http://www.w3.org/2000/svg" width="${cols * cell}" height="${rows * cell}">${glyphs}</svg>`)}")`;
  codeStreamCache.set(tint, uri);
  return uri;
}

/* ---------- 折叠态卡片拖拽排序 (mac: 仅折叠态提供拖拽手柄) ---------- */
let draggingCard = null;
async function reorderCards(from, to) {
  if (from === to) return;
  const order = [...new Set([...(currentSettings.cardOrder || []), "usage", "subscription", "hourly"])];
  const fromIndex = order.indexOf(from);
  const toIndex = order.indexOf(to);
  if (fromIndex < 0 || toIndex < 0) return;
  order.splice(toIndex, 0, order.splice(fromIndex, 1)[0]);
  currentSettings = { ...currentSettings, cardOrder: order };
  if (currentPanel) render(currentPanel);
  // C251: 以后端最新设置为基线只改 cardOrder; 看板缓存的整份副本可能早于设置窗口
  // 或后台的写入, 直接回传会把它们回滚。
  try { await invoke("save_settings_command", { settings: { ...await invoke("get_settings"), cardOrder: order } }); }
  catch (error) { showError(error); }
}
// 手柄由 cardHead 预置在标题之前 (mac DashboardDragHandle 位于展开按钮左侧、
// 物理独立于它), 这里只接线拖放事件; 仅收起态由 CSS 显示。
function attachDragHandle(card, key) {
  const handle = card.querySelector(".drag-handle");
  if (!handle) return;
  handle.setAttribute("draggable", "true");
  // 点击手柄不得冒泡成标题行的展开/收起 (mac 两者为兄弟控件)
  handle.addEventListener("click", (event) => event.stopPropagation?.());
  handle.addEventListener("dragstart", (event) => {
    draggingCard = key;
    card.classList.add("dragging");
    if (event.dataTransfer) {
      event.dataTransfer.effectAllowed = "move";
      event.dataTransfer.setData("text/plain", key);
    }
  });
  handle.addEventListener("dragend", () => {
    draggingCard = null;
    card.classList.remove("dragging");
    document.querySelectorAll(".card.drop-target").forEach((node) => node.classList.remove("drop-target"));
  });
  card.addEventListener("dragover", (event) => {
    if (draggingCard && draggingCard !== key) {
      event.preventDefault();
      card.classList.add("drop-target");
    }
  });
  card.addEventListener("dragleave", () => card.classList.remove("drop-target"));
  card.addEventListener("drop", (event) => {
    event.preventDefault();
    card.classList.remove("drop-target");
    if (draggingCard && draggingCard !== key) reorderCards(draggingCard, key);
  });
}

// 卡片标题行 (mac CollapsibleCardHeader): [拖拽手柄] [定宽标题] [状态件]; 收起态
// 迷你摘要与 chevron 由 makeCollapsible 追加。状态件 (LIVE / 最后更新) 经 CSS
// margin-left:auto 推到行尾, 等价 mac 的 Spacer。
function cardHead(card, title, status) {
  const head = el("div", "card-head");
  const handle = el("span", "drag-handle");
  for (let index = 0; index < 6; index += 1) handle.append(el("i"));
  handle.setAttribute("title", "拖拽调整卡片顺序");
  handle.setAttribute("aria-hidden", "true");
  const slot = el("span", "card-status");
  if (status) slot.append(status);
  head.append(handle, el("span", "card-title", title), slot);
  card.append(head);
  return head;
}

// C262: 卡片折叠状态提升到模块级; 后台刷新 (dashboard-updated) 重建卡片时恢复,
// 不再把用户收起的卡片重新展开。
const collapsedCards = new Set();
// C262: 模型用量视图状态 (选中月份 / 三档维度 / 展开全部) 跨后台刷新保持。
const usageViewState = { monthKey: null, mode: "tier0", modelsExpanded: false };

function applyCollapsedState(card, stateKey) {
  const collapsed = collapsedCards.has(stateKey);
  card.classList.toggle("collapsed", collapsed);
  const head = card.querySelector(".card-head");
  if (head) {
    head.classList.toggle("collapsed", collapsed);
    head.setAttribute("aria-expanded", String(!collapsed));
  }
}

function makeCollapsible(card, summary, onExpand = null, stateKey = null) {
  const head = card.querySelector(".card-head");
  head.setAttribute("role", "button");
  head.setAttribute("tabindex", "0");
  head.setAttribute("aria-expanded", "true");
  if (summary) {
    // 收起态摘要嵌在标题行内 (取代状态件), 而非另起一行
    const mini = el("span", "collapsed-summary");
    mini.append(summary());
    head.append(mini);
  }
  const chev = el("span", "chev");
  chev.append(icon("chevronRight"));
  head.append(chev);
  const toggle = () => {
    const collapsed = card.classList.toggle("collapsed");
    head.classList.toggle("collapsed", collapsed);
    head.setAttribute("aria-expanded", String(!collapsed));
    if (stateKey) {
      if (collapsed) collapsedCards.add(stateKey);
      else collapsedCards.delete(stateKey);
    }
    // C212: 展开时通知卡片重置默认明细 (仅 Agent 卡使用).
    if (!collapsed && typeof onExpand === "function") onExpand();
  };
  head.addEventListener("click", toggle);
  head.addEventListener("keydown", event => {
    if (event.key === "Enter" || event.key === " ") { event.preventDefault(); toggle(); }
  });
  if (stateKey) applyCollapsedState(card, stateKey);
}

/* ---------- Token 用量卡 (mac UsageHeroCard) ---------- */
function usageCard(usage) {
  const card = el("div", "card usage-card");
  // 主题 accent 注入卡片容器, .hero-num 与 .mini-num 经 CSS 变量继承取色
  applyAccentVars(card);
  // 背景纹样层: classic 字符流 tint 取 accent 浅阶 (C220); Nothing 由 CSS 改为点阵。
  // 独立成层以便只对纹样做底部渐隐 mask。
  const tint = HERO_GRADIENT[1];
  card.style.setProperty("--code-stream", codeStreamImage(tint));
  const background = el("div", "usage-bg");
  background.setAttribute("aria-hidden", "true");
  card.append(background);
  cardHead(card, "Token 用量", null);
  // 收起态 (C235 方案 A4): 17pt 总量 + 右侧双行摘要 (命中率 | 成本 + 较昨日 · 省费 · 本月)
  makeCollapsible(card, () => {
    const summary = usage.collapsedSummary || {};
    const hitText = summary.cacheHitRateText || "—";
    const hasHit = hitText !== "—";
    const hasCost = Boolean(usage.costText);
    const mini = el("span", "usage-mini");
    const right = el("span", "usage-mini-right");

    const top = el("span", "usage-mini-top");
    const hitItem = el("span", "usage-mini-hit");
    hitItem.append(
      el("span", "usage-mini-lbl", "命中"),
      el("b", hasHit ? "usage-mini-val" : "usage-mini-val muted", hitText)
    );
    const costEl = el("b", hasCost ? "usage-mini-val cost" : "usage-mini-val muted", usage.costText || "—");
    top.append(hitItem, el("i", "usage-mini-sep"), costEl);
    right.append(top);

    const subSegments = [];
    if (summary.dayDeltaText) {
      const cls = summary.dayDeltaNegative
        ? "down"
        : (summary.dayDeltaText === "持平" ? null : "hi");
      const seg = el("span", "usage-mini-seg");
      seg.append("较昨日", el("b", cls, summary.dayDeltaText));
      subSegments.push(seg);
    }
    if (summary.cacheSavingsText) {
      const seg = el("span", "usage-mini-seg");
      seg.append("省", el("b", "hi", summary.cacheSavingsText));
      subSegments.push(seg);
    }
    if (summary.monthTotalText) {
      const seg = el("span", "usage-mini-seg");
      seg.append("本月", el("b", null, summary.monthTotalText));
      subSegments.push(seg);
    }
    if (subSegments.length > 0) {
      const sub = el("span", "usage-mini-sub");
      subSegments.forEach((seg, index) => {
        if (index > 0) sub.append(el("span", "usage-mini-dot", "·"));
        sub.append(seg);
      });
      right.append(sub);
    }

    mini.append(el("b", "mini-num", usage.totalTokensText), right);
    return mini;
  }, null, "usage");

  // hero 行: 40pt 档位渐变数字 (Nothing: Doto 52 纯色 + 方块小数点) + tokens + 右侧成本
  const hero = el("div", "hero-row");
  const heroNum = el("span", "hero-num");
  if (isNothingTheme() && usage.totalTokensText && usage.totalTokensText.includes(".")) {
    const dotIdx = usage.totalTokensText.indexOf(".");
    heroNum.append(
      el("span", null, usage.totalTokensText.slice(0, dotIdx)),
      el("span", "dot-square"),
      el("span", null, usage.totalTokensText.slice(dotIdx + 1))
    );
  } else {
    heroNum.textContent = usage.totalTokensText;
  }
  hero.append(heroNum);
  hero.append(el("span", "hero-unit", "tokens"));
  if (usage.costText) hero.append(el("span", "hero-cost", usage.costText));
  card.append(hero);

  card.append(el("div", "divider"));

  // 四格细分 (各格按内容定宽)
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
    // C262: 选中月份 / 三档维度 / 展开全部提升到模块级, 后台刷新重建卡片时恢复。
    if (models) {
      const available = new Set(usage.monthly.map((month) => month.key));
      if (!usageViewState.monthKey || !available.has(usageViewState.monthKey)) {
        usageViewState.monthKey = models.currentMonthKey || "";
        if (usageViewState.mode === "month") usageViewState.mode = "tier0";
      }
    }
    let selectedKey = models ? (usageViewState.monthKey || models.currentMonthKey || "") : "";
    let mode = models ? usageViewState.mode : "tier0";
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
          chip.setAttribute("aria-label", `${month.label} ${month.totalText}，查看该月模型用量`);
          const selectMonth = () => {
            selectedKey = month.key;
            mode = "month";
            usageViewState.monthKey = month.key;
            usageViewState.mode = "month";
            renderGrid();
            renderSeg();
            renderModelRows();
          };
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

    // 模型用量 (mac modelUsageSection): 标题旁 chevron 切换「前 3 / 全部」, 右侧三档
    // segment 与月卡联动, 默认本月; 无模型月度数据 (models 为 null) 时整块隐藏。
    if (models) {
      const msec = el("div", null); msec.id = "models-sec";
      const mhead = el("div", "models-head");
      const left = el("div", "sec-row");
      const titleSpan = el("span", "sec", "模型用量");
      let expanded = usageViewState.modelsExpanded;
      const expand = el("button", "models-expand");
      expand.type = "button";
      expand.append(icon("chevronDown"));
      left.append(titleSpan, expand);
      mhead.append(left);
      const seg = el("div", "tier-seg");
      renderSeg = () => {
        seg.innerHTML = "";
        models.tiers.forEach((tier, index) => {
          const b = el("button", null, tier.label);
          b.type = "button";
          if (mode === `tier${index}`) b.classList.add("active");
          b.addEventListener("click", () => {
            mode = `tier${index}`;
            usageViewState.mode = mode;
            renderGrid();
            renderSeg();
            renderModelRows();
          });
          seg.append(b);
        });
      };
      renderSeg();
      mhead.append(seg);
      msec.append(mhead);
      const rowsHost = el("div");
      renderModelRows = () => {
        titleSpan.textContent = "模型用量" + (mode === "month" ? ` · ${(usage.monthly.find((m) => m.key === selectedKey) || {}).label || ""}` : "");
        expand.setAttribute("aria-expanded", String(expanded));
        expand.setAttribute("aria-label", expanded ? "收起全部模型" : "展开全部模型");
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
        if (!rows.length) rowsHost.append(el("div", "models-empty", "暂无模型数据"));
      };
      expand.addEventListener("click", () => {
        expanded = !expanded;
        usageViewState.modelsExpanded = expanded;
        renderModelRows();
      });
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
    usage.heatmap.forEach((week, column) => {
      const col = el("div", "col");
      week.cells.forEach((cell, row) => {
        const box = el("div", "cell");
        // C223 起模型按完整 7 天块输出, 正常不会有 null; 保留空槽兜底.
        if (!cell) {
          box.classList.add("empty");
        } else {
          if (cell.level > 0) box.classList.add(`l${Math.min(cell.level, 5)}`);
          box.title = `${cell.date}  ${cell.total.toLocaleString()}`;
          if (!first) first = cell.date;
          last = cell.date;
        }
        col.append(box);
      });
      grid.append(col);
    });
    sec.append(grid);
    // C202 底部单行: 起始日期居左 · 程度图例居中 · 截止日期居右
    const footer = el("div", "heat-footer");
    const fmt = (value) => { const p = value.split("-"); return `${p[0].slice(2)}/${p[1]}/${p[2]}`; };
    footer.append(el("span", "heat-start", first ? fmt(first) : ""));
    const legend = el("div", "heat-legend");
    legend.setAttribute("aria-label", "热力图程度图例: 颜色从少到多");
    legend.append(el("span", null, "少"));
    for (let level = 0; level <= 5; level += 1) legend.append(el("span", `sw${level ? ` l${level}` : ""}`));
    legend.append(el("span", null, "多"));
    footer.append(legend, el("span", "heat-end", last ? fmt(last) : ""));
    sec.append(footer);
    card.append(sec);
  }
  return card;
}

/* ---------- 订阅用量卡 ---------- */
// 品牌色板以 mac BruceAppCore.ProviderBrandPalette.hex 为唯一事实源 (styles.css 契约:
// 配色 token 按 mac 源码数值), 双端逐家对齐; C026 起补齐 cline (#18181b)、zhipu 改用
// Z.ai 官方锁版深色 (#2D2D2D); grok/zhipu/cline 沿用 mac 深色品牌色形态。
const PROVIDER_COLORS = { kimi: "#0a84ff", deepseek: "#4d6bfe", volcengine: "#ff6a00", zhipu: "#2D2D2D", codex: "#10a37f", claude: "#d97757", grok: "#111111", opencodeGo: "#8a63d2", stepfun: "#0c5efc", cline: "#18181b", grokBot: "#111111" };
// 品牌图形数据由 provider-brand.js 提供 (scripts/gen-provider-glyphs.mjs 生成),
// C263 起不再在 app.js 内联第二份。
const PROVIDER_GLYPHS = window.BRUCE_PROVIDER_GLYPHS || {};
// 单账号 section id 带 service 后缀 (如 "codex_4eversivan"), 归一出 provider 键
// 供徽章、余额胶囊取品牌色与看板排序; 多账号 section id 本身就是 provider 键, 原样返回。
function providerKey(id) {
  const raw = String(id || "");
  if (raw === "kimi_coding") return "kimi";
  if (raw === "grok-bot" || raw === "grokbot" || raw.startsWith("grokbot_")) return "grokBot";
  if (raw === "opencode-go" || raw.startsWith("opencode_go_")) return "opencodeGo";
  return raw.split("_")[0];
}
// 品牌图形徽章 (C026): 品牌色瓷砖 + 品牌图形 (PROVIDER_GLYPHS, 由
// scripts/gen-provider-glyphs.mjs 生成); 无图形数据的 provider 回退首字母。
// SVG 用 DOM API 构建 (而非 innerHTML), 与前端测试的极简 DOM 边界保持兼容。
// mac ProviderBrandPalette.isDarkBrand / nothingDarkHex: 深色品牌在 Nothing 深色表面不可读,
// grokBot 保持纯白球体 #FFFFFF, 其余退回 secondary 灰 #999999。
const DARK_BRANDS = new Set(["grok", "grokBot", "zhipu", "cline"]);
function badge(providerID, name) {
  const key = providerKey(providerID);
  const b = el("span", "pbadge");
  // 品牌色以 CSS 变量下发: classic 为实底瓷砖 + 白图形, Nothing 由 CSS 改为
  // 品牌色 16% 底 + 品牌色图形 (mac S3 柔彩定稿); 不写内联 background 以免压过主题覆写。
  const color = PROVIDER_COLORS[key] || "#8e8e93";
  const nothingColor = key === "grokBot"
    ? "#FFFFFF"
    : (DARK_BRANDS.has(key) ? "#999999" : color);
  b.style.setProperty("--brand", color);
  b.style.setProperty("--brand-nothing", nothingColor);
  const glyph = PROVIDER_GLYPHS[key];
  if (glyph) {
    b.append(glyphSvg(glyph));
  } else {
    b.textContent = (name || "?").trim().charAt(0).toUpperCase();
  }
  return b;
}
function glyphSvg(glyph) {
  const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  svg.setAttribute("viewBox", glyph.vb);
  svg.setAttribute("fill", "currentColor");
  svg.setAttribute("aria-hidden", "true");
  for (const [d, opacity] of glyph.shapes) {
    const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
    path.setAttribute("d", d);
    if (opacity !== 1) path.setAttribute("fill-opacity", String(opacity));
    svg.append(path);
  }
  return svg;
}
function meterLevel(percent) { return percent < 50 ? "normal" : percent < 80 ? "warning" : "critical"; }
function clampedPercent(value) { return Number.isFinite(value) ? Math.max(0, Math.min(100, value)) : 0; }
// mac Nothing 量条: 24 段方角, 段间 2pt, 高 10; 填充段数 = round(clamp(fraction,0,1) * 24),
// 纯色取阈值档色 (normal #4A9E5C / warning #D4A843 / critical #D71921)。
const NOTHING_METER_SEGMENTS = 24;
const NOTHING_THRESHOLD_COLORS = { normal: "#4A9E5C", warning: "#D4A843", critical: "#D71921" };
function nothingMeter(level, usedPercent) {
  const meter = el("div", `meter segmented ${level}`);
  const filled = Math.round((clampedPercent(usedPercent) / 100) * NOTHING_METER_SEGMENTS);
  for (let index = 0; index < NOTHING_METER_SEGMENTS; index += 1) {
    const segment = el("i");
    if (index < filled) segment.style.background = NOTHING_THRESHOLD_COLORS[level] || NOTHING_THRESHOLD_COLORS.normal;
    meter.append(segment);
  }
  return meter;
}
function windowRow(row, protectedSnapshot = false) {
  const line = el("div", "win-row");
  line.append(el("span", "wl", row.label));
  const level = meterLevel(row.usedPercent);
  const meter = isNothingTheme()
    ? nothingMeter(level, row.usedPercent)
    : el("div", `meter ${level}`);
  if (!isNothingTheme()) {
    const fill = el("span"); fill.style.width = `${Math.round(clampedPercent(row.usedPercent))}%`;
    meter.append(fill);
  }
  line.append(meter);
  const percentText = protectedSnapshot && !row.percentText.includes("已保护")
    ? `${row.percentText} (已保护)`
    : row.percentText;
  line.append(el("span", `wp ${level}`, percentText));
  line.append(el("span", "wr", protectedSnapshot ? "已拦截" : row.resetText));
  return line;
}

// C264: 出口阻断的单行紧凑问题卡片 (design/11 §3.2)。
const EGRESS_REASON_TITLE = {
  EGRESS_COUNTRY_MISMATCH: "出口 IP 泄漏",
  EGRESS_CN_DIRECT: "当前线路为国内出口",
  EGRESS_PROBE_TIMEOUT: "出口探测超时",
  EGRESS_PROXY_UNREACHABLE: "专用代理不可用",
  EGRESS_PROXY_AUTH: "专用代理需要认证",
  EGRESS_BAD_STATUS: "出口信标异常",
  EGRESS_COUNTRY_UNKNOWN: "无法识别出口国家",
  EGRESS_CONFIG_INVALID: "出口保护配置无效",
};
function countryFlag(code) {
  const value = String(code || "").toUpperCase();
  if (!/^[A-Z]{2}$/.test(value)) return "";
  return String.fromCodePoint(...[...value].map((char) => 127397 + char.charCodeAt(0)));
}
function egressIssueCard(section) {
  const egress = section.egress || {};
  const title = EGRESS_REASON_TITLE[egress.reason] || "出口校验未通过";
  const compare = egress.expected && egress.observed
    ? `预期 ${egress.expected} · 探测为 ${egress.observed}`
    : (egress.maskedIp ? `探测 IP ${egress.maskedIp}` : "");
  const card = el("div", "egress-issue");
  card.setAttribute("role", "note");
  if (compare) card.title = compare;
  const iconEl = el("span", "egress-issue-icon");
  iconEl.append(icon("activity", 1.8));
  const copy = el("div", "egress-issue-copy");
  const line = el("div", "egress-issue-title");
  line.append(el("b", null, title), el("i", "egress-issue-sep"));
  line.append(el("span", "egress-issue-promise", "已拦截查额以保护账号 · 保持历史快照"));
  copy.append(line);
  const actions = el("div", "egress-issue-actions");
  const settingsBtn = el("button", "egress-issue-action", "去设置");
  settingsBtn.type = "button";
  settingsBtn.addEventListener("click", () => openSettingsPane("subscription"));
  const retryBtn = el("button", "egress-issue-action", "重测");
  retryBtn.type = "button";
  retryBtn.addEventListener("click", async () => {
    retryBtn.disabled = true;
    try { await invoke("refresh_subscription", { sectionId: section.id }); }
    catch { retryBtn.disabled = false; }
  });
  actions.append(settingsBtn, el("i", "egress-issue-sep"), retryBtn);
  card.append(iconEl, copy, actions);
  return card;
}

// 订阅段 Provider 定向刷新 (mac ProviderRefreshButton + SubscriptionRefreshControlPolicy)。
// 目标 provider 取自运行时层附在 section 上的 `provider` (Rust runtime_core 单点归一,
// 只对已知 provider 附加); 缺失即不渲染按钮 (fail-closed, 前端不猜测目标)。
// 呈现与 mac 契约一致: 目标刷新中显示进度并禁用; 全量刷新中 / 未授权 / 未启用时禁用。
function providerRefreshButton(section) {
  const provider = section.provider;
  if (!provider) return null;
  const runtime = currentPanel?.runtime || {};
  const refreshing = (runtime.refreshingProviders || []).includes(provider);
  const runnable = runtime.quotaRefreshAllowed !== false
    && (!currentSettings.enabledProviders || currentSettings.enabledProviders.includes(provider));
  const enabled = runnable && !refreshing && runtime.phase !== "refreshing";
  const button = el("button", refreshing ? "sub-refresh busy" : "sub-refresh");
  button.type = "button";
  button.disabled = !enabled;
  button.dataset.provider = provider;
  button.setAttribute("aria-label", refreshing ? `正在刷新 ${section.name} 订阅额度` : `刷新 ${section.name} 订阅额度`);
  button.setAttribute("title", `只重新查询 ${section.name} 的订阅额度, 不影响其他订阅与本地统计`);
  button.append(refreshing ? el("span", "sub-spinner") : icon("arrowClockwise", 2.1));
  button.addEventListener("click", async (event) => {
    event.stopPropagation?.();
    if (button.disabled) return;
    button.disabled = true;
    try {
      await invoke("refresh_subscription", { sectionId: section.id });
    } catch {
      // 被拒时静默 (C080, 对齐 mac RefreshScheduler.refreshSubscription 的静默 return):
      // 顶部不产生任何文案, 可见反馈仅为按钮恢复可点; 详情留在控制台。
      button.disabled = false;
    }
  });
  return button;
}

// 多账号 (accounts >= 2) 与纯余额型判定, 对齐 mac SubscriptionProviderSection 的两个计算属性。
function isMultiAccount(section) { return (section.accounts || []).length >= 2; }
function isBalanceBased(section) {
  return !(section.windows || []).length && !isMultiAccount(section) && Boolean(section.balance);
}
// 收起态迷你量条取数: 该 provider 最紧张的窗口 (单账号取 windows, 多账号跨账号取
// max usedPercent), 与 mac collapsedPeakWindow 同语义; 纯余额型 (无窗口) 为 null,
// 收起态不出该 provider 的迷你量条。视图模型输出已被 mac golden 逐字段锁定, 该
// 展示态推导故留在渲染层, 不改契约字段。
function collapsedPeakWindow(section) {
  let peak = null;
  for (const row of [...(section.windows || []), ...(section.accounts || []).flatMap((a) => a.windows || [])]) {
    if (peak === null || row.usedPercent > peak.usedPercent) peak = row;
  }
  return peak;
}
// 多账号展开状态: mac 用 @State 默认折叠, 前端同语义 (跨刷新保持, 不持久化)。
const expandedSections = new Set();
// 订阅卡空状态 (C157, mac SubscriptionEmptyStatePolicy): 只做未配置 / 无数据两态.
// eligible = 已添加 ∧ enabled ∧ verificationStatus == ok ∧ 非临时屏蔽 (jev).
// 有配置但未验证 / 已停用的订阅归入未配置, 不引入第三态.
function subscriptionEmptyState() {
  const providers = (currentSettings && currentSettings.subscriptionProviders) || {};
  const eligible = Object.keys(providers).filter((id) => {
    if (id === "jev") return false;
    const provider = providers[id] || {};
    return provider.enabled === true && provider.verificationStatus === "ok";
  });
  return eligible.length > 0 ? "noData" : "notConfigured";
}

function subscriptionEmptyCard() {
  const state = subscriptionEmptyState();
  const copy = state === "noData"
    ? {
        status: "无数据",
        title: "暂未获取到额度",
        desc: "这次采集没有返回订阅额度，可手动刷新重试。",
        action: "刷新额度",
        icon: "arrowClockwise",
      }
    : {
        status: "未配置",
        title: "尚未添加订阅",
        desc: "添加并验证账号后，显示 5 小时与每周额度。",
        action: "添加订阅",
        icon: "creditCard",
      };
  const card = el("div", "card sub-empty-card");
  cardHead(card, "订阅用量", el("span", "updated", copy.status));
  makeCollapsible(card, () => el("span", "sub-empty-mini", copy.status), null, "subscription");

  const body = el("div", "sub-empty");
  const frame = el("span", "sub-empty-frame");
  frame.append(icon(copy.icon, 1.6));
  const button = el("button", "btn sub-empty-btn", copy.action);
  button.type = "button";
  button.addEventListener("click", () => {
    if (state === "noData") {
      invoke("refresh_now").catch(() => {});
    } else {
      openSettingsPane("subscription");
    }
  });
  body.append(
    frame,
    el("span", "sub-empty-title", copy.title),
    el("span", "sub-empty-desc", copy.desc),
    button,
  );
  card.append(body);
  return card;
}

// 设置分类深链 (C262): 目标页签作为命令参数交给后端登记, 设置窗口消费后切换;
// 不再依赖同源 localStorage + focus 轮询。
function openSettingsPane(pane) {
  invoke("open_settings", { pane }).catch(() => {});
}
// 纯余额型双槽 (mac BalanceDualSlotView): 可用余额 + 订阅状态。
function balanceSlots(section) {
  const wrap = el("div", "bal-slots");
  const amount = el("div", "slot");
  amount.append(el("div", "slot-title", "可用余额"));
  const value = el("div", "slot-value", section.balance?.amountText || "--");
  amount.append(value);
  const status = el("div", "slot");
  status.append(el("div", "slot-title", "订阅状态"));
  const statusValue = el("div", "slot-value status");
  // C225: 态名与点色取顶部状态灯同一张映射表, 不再直出状态码、不再恒绿。
  statusValue.append(el("span", `slot-dot ${sectionTone(section.status)}`), el("span", null, statusLabel(section.status)));
  status.append(statusValue);
  wrap.append(amount, status);
  return wrap;
}
// 账号子卡 (mac ProviderAccountCard): 名称 + tag → 窗口行 → error note → 上次成功。
function accountCard(account, sectionID, protectedSnapshot = false) {
  const block = el("div", "account-card");
  const head = el("div", "account-head");
  head.append(el("span", "account-name", account.name || account.id));
  if (account.tag) head.append(el("span", "tag-chip", account.tag));
  block.append(head);
  for (const row of account.windows || []) {
    block.append(windowRow(row, protectedSnapshot));
  }
  if (account.status === "error" && account.note) block.append(el("div", "note-line", account.note));
  if (account.lastSuccessText) {
    const line = el("div", "last-success", account.lastSuccessText);
    line.setAttribute("aria-label", "这是上次成功的数据");
    block.append(line);
  }
  return block;
}
function subscriptionCard(sub) {
  const card = el("div", "card");
  cardHead(card, "订阅用量", null);
  // 收起态: 各 provider 一组「品牌徽章 + 5pt 迷你量条」, 量条取最紧张窗口;
  // 纯余额型 (无窗口) 不出迷你量条 (mac collapsedMini)。
  makeCollapsible(card, () => {
    const mini = el("span", "sub-mini");
    for (const section of sub.sections) {
      const peak = collapsedPeakWindow(section);
      if (!peak) continue;
      const group = el("span", "sub-mini-group");
      if (section.egress?.status === "blocked") group.classList.add("blocked");
      const meterEl = el("span", `meter ${meterLevel(peak.usedPercent)}`);
      const fill = el("span");
      fill.style.width = `${Math.round(clampedPercent(peak.usedPercent))}%`;
      meterEl.append(fill);
      group.append(badge(section.provider || section.id, section.name), meterEl);
      mini.append(group);
    }
    return mini;
  }, null, "subscription");
  const body = el("div", "sub-body");
  // 段渲染独立成函数: 多账号展开/收起只重建本卡正文, 不触发整栈重渲染
  // (避免清掉模型用量卡片的选中档位/展开态等局部状态)。
  const renderSections = () => {
    body.replaceChildren();
    for (const section of sub.sections) {
      const multi = isMultiAccount(section);
      const balanceBased = isBalanceBased(section);
      const egress = section.egress || null;
      const blocked = egress?.status === "blocked";
      const block = el("div", "sub-section");
      const h = el("div", "sub-head");
      h.append(badge(section.provider || section.id, section.name));
      if (multi) {
        // mac: 多账号时名称本身就是展开开关 (名称 + chevron)
        const expanded = expandedSections.has(section.id);
        const toggle = el("button", "sub-name-toggle");
        toggle.type = "button";
        const chevron = el("span", expanded ? "sub-chev open" : "sub-chev");
        chevron.append(icon("chevronDown"));
        toggle.append(el("span", "sub-name", section.name), chevron);
        toggle.setAttribute("aria-expanded", String(expanded));
        toggle.setAttribute("aria-label", `${section.name} 账号列表`);
        toggle.addEventListener("click", () => {
          if (expandedSections.has(section.id)) expandedSections.delete(section.id);
          else expandedSections.add(section.id);
          renderSections();
        });
        h.append(toggle);
      } else {
        h.append(el("span", "sub-name", section.name));
      }
      // 余额 (Credits / 货币) 以头部元数据胶囊呈现 (C011); 纯余额型改走双槽, 抑制胶囊。
      if (!balanceBased && section.balance) {
        const chip = el("span", "bal-chip");
        const dot = el("span", "dot");
        dot.style.background = PROVIDER_COLORS[providerKey(section.provider || section.id)] || "#8e8e93";
        chip.append(dot, el("b", null, section.balance.amountText));
        chip.title = section.balance.label;
        h.append(chip);
      }
      if (section.accountCountText) h.append(el("span", "acct-count", section.accountCountText));
      if (section.extraText) h.append(el("span", "sub-extra", section.extraText));
      if (egress?.expected) {
        const flag = el("span", blocked ? "egress-flag blocked" : "egress-flag", countryFlag(egress.expected));
        flag.title = [egress.expected, egress.observed, egress.maskedIp].filter(Boolean).join(" · ");
        h.append(flag);
      }
      // 定向刷新按钮钉在头部行尾 (单/多账号位置统一), 与名称展开开关为兄弟控件
      const refresh = providerRefreshButton(section);
      if (refresh) h.append(refresh);
      block.append(h);
      if (blocked) block.append(egressIssueCard(section));

      if (multi) {
        if (expandedSections.has(section.id)) {
          const list = el("div", "account-list-inline");
          for (const account of section.accounts) list.append(accountCard(account, section.id, blocked));
          block.append(list);
        } else if (section.collapsedWindow) {
          block.append(windowRow(section.collapsedWindow, blocked));
        }
      } else if (balanceBased) {
        block.append(balanceSlots(section));
      } else {
        for (const row of section.windows || []) {
          block.append(windowRow(row, blocked));
        }
      }

      // error/empty 段保留 collector 说明, 不静默吞掉 (与 mac 门控一致)
      if ((section.status === "error" || section.status === "empty") && section.note) {
        block.append(el("div", "note-line", section.note));
      }
      // C224: 单账号段 (含纯余额型) 沿用旧快照时标注上次成功时间, 与账号子卡同款;
      // 多账号段由各账号子卡自行呈现 (单账号段不读 section.accounts, 见 design/05)。
      if (!multi && section.lastSuccessText) {
        const line = el("div", "last-success", section.lastSuccessText);
        line.setAttribute("aria-label", "这是上次成功的数据");
        block.append(line);
      }
      body.append(block);
    }
    if (isNothingTheme() || sub.updatedText) {
      const footer = el("div", isNothingTheme() ? "nothing-threshold-legend" : "subscription-footer");
      if (isNothingTheme()) {
        const legend = el("div", "thresh-items");
        const items = [
          { color: "#4A9E5C", text: "<50" },
          { color: "#D4A843", text: "50–79" },
          { color: "#D71921", text: "≥80" },
        ];
        for (const item of items) {
          const span = el("span", "thresh-item");
          const box = el("span", "thresh-box");
          box.style.background = item.color;
          span.append(box, el("span", "thresh-text", item.text));
          legend.append(span);
        }
        footer.append(legend);
      }
      if (sub.updatedText) {
        footer.append(el("span", "updated", sub.updatedText));
      }
      body.append(footer);
    }
  };
  renderSections();
  card.append(body);
  return card;
}

/* ---------- Agent 用量卡 (展开: 14 日日柱 + 逐小时行 + 行级明细下钻) ---------- */
// 行级展开状态: mac 用 @State(默认收起, 不持久化), 前端同语义跨刷新保持。
const expandedAgents = new Set();
// C212: 首次建立 / 切到 hourly 页签时默认打开首个有明细 agent; 消费后普通刷新不重置.
let hourlyExpansionPending = true;

// C216: 紧凑条形明细 (镜像 mac compactShareSection / compactShareRow).
// 段头「模型占比 / 项目占比」+ 数量; 每行 序号 / 名称 / 内联占比条 / 百分比 / Token.
// 不渲染 100% 堆叠条、点阵导引、6-Tick 或 PRJ.CONSOLE 控制台.
const NOTHING_TIER_COLORS = ["#30D158", "#4A9E5C", "#2B7A42"];
function nothingTierColor(index) {
  return NOTHING_TIER_COLORS[Math.min(index, NOTHING_TIER_COLORS.length - 1)];
}

function compactShareSection(title, bars, countText, shadeAt) {
  const section = el("div", "detail-compact");
  const head = el("div", "detail-compact-head");
  head.append(
    el("span", "detail-compact-title", title),
    el("span", "detail-compact-count", countText)
  );
  section.append(head);
  for (const [index, bar] of bars.entries()) {
    const color = shadeAt(index);
    const rowEl = el("div", "detail-compact-row");
    const idx = el("span", "dc-idx", String(index + 1).padStart(2, "0"));
    idx.style.color = color;
    const name = el("span", "dc-name", bar.name);
    const barEl = el("span", "dc-bar");
    const fill = el("i");
    fill.style.width = `${Math.max(2, Math.min(100, bar.share * 100))}%`;
    fill.style.background = color;
    barEl.append(fill);
    const pct = el("span", "dc-pct", sharePercentText(bar.share));
    pct.style.color = color;
    const tokens = el("span", "dc-tokens", bar.totalText);
    rowEl.append(idx, name, barEl, pct, tokens);
    rowEl.setAttribute("aria-label", `${bar.name} ${sharePercentText(bar.share)} · ${bar.totalText}`);
    section.append(rowEl);
  }
  return section;
}

// Agent 身份徽章 (C161): 有 agent-brand.js 时用品牌徽章, 否则退回原来的色点。
function agentBadgeFor({ agentId, seriesHex, size, nothingHex, forceBrand = false }) {
  const brand = window.BRUCE_AGENT_BRAND;
  if (brand && typeof brand.create === "function") {
    return brand.create({
      agentId,
      seriesHex,
      size,
      nothing: isNothingTheme(),
      nothingHex,
      forceBrand,
    });
  }
  const dot = el("span", size >= 14 ? "dot ab-dot-lg" : "dot");
  dot.style.background = seriesHex;
  return dot;
}

// agent 色: classic 取品牌色 (视图模型 colorHex), Nothing 取 5 档绿阶 (mac nothingRampHex),
// 与 14 日点阵分段、图例色块同源。
function agentColor(agentId, colorHex) {
  return isNothingTheme() ? nothingRampHex(agentId) : colorHex;
}

function agentRow(row, rerender) {
  const block = el("div", "agent-row");
  const expanded = expandedAgents.has(row.agentId);
  const line1 = el("div", "line1");
  const dot = agentBadgeFor({
    agentId: row.agentId,
    seriesHex: row.colorHex,
    size: isNothingTheme() ? 9 : 14,
    nothingHex: agentColor(row.agentId, row.colorHex),
  });
  line1.append(dot, el("span", "an", row.name));
  if (row.isExpandable) {
    const chevron = el("span", expanded ? "row-chev open" : "row-chev");
    chevron.append(icon("chevronRight"));
    line1.append(chevron);
  }
  line1.append(el("span", "at", row.todayTotalText));
  block.append(line1);

  // 24 点走势: mac 为线性折线 1.5pt + 渐变面积 (颜色经 currentColor 由 CSS 决定)
  const spark = el("div", "spark");
  spark.style.setProperty("--spark-color", row.colorHex);
  spark.append(lineSpark(row.points.length ? row.points : new Array(24).fill(0), 26));
  block.append(spark);

  if (row.isExpandable) {
    const detail = el("div", "detail");
    const nothing = isNothingTheme();
    if (row.models.length) {
      detail.append(compactShareSection(
        "模型占比",
        row.models,
        nothing ? `${row.models.length} MODELS` : `${row.models.length} 个模型`,
        (index) => nothing ? nothingTierColor(index) : modelShade(row.colorHex, index)
      ));
    }
    if (row.projects.length) {
      if (row.models.length) detail.append(el("div", "detail-compact-divider"));
      detail.append(compactShareSection(
        "项目占比",
        row.projects,
        nothing ? `${row.projects.length} WORKSPACES` : `${row.projects.length} 个工程`,
        (index) => nothing ? nothingTierColor(index) : projectShade(index)
      ));
    }
    if (expanded) block.append(detail);
    // mac: 整行为按钮; Windows 只在行首行挂点击, 图表区仍可悬停而不误触。
    line1.classList.add("expandable");
    line1.setAttribute("role", "button");
    line1.setAttribute("tabindex", "0");
    line1.setAttribute("aria-expanded", String(expanded));
    const toggle = () => {
      if (expandedAgents.has(row.agentId)) expandedAgents.delete(row.agentId);
      else expandedAgents.add(row.agentId);
      rerender();
    };
    line1.addEventListener("click", toggle);
    line1.addEventListener("keydown", (event) => {
      if (event.key === "Enter" || event.key === " ") {
        event.preventDefault();
        toggle();
      }
    });
  }
  return block;
}

function hourlyCard(hourly, usage) {
  const card = el("div", "card");
  cardHead(card, "Agent 用量", null);

  const hasHistory = () => Boolean(
    usage && usage.days && usage.days.some((day) => day.total > 0)
  );
  const resetExpansion = () => {
    expandedAgents.clear();
    const first = hourly.rows.find((row) => row.isExpandable);
    if (first) expandedAgents.add(first.agentId);
  };
  // C212: 首次建立或切到 hourly 页签时消费一次默认展开; 普通刷新保留手动状态.
  if (hourlyExpansionPending) {
    hourlyExpansionPending = false;
    resetExpansion();
  }

  const body = el("div", "hourly-body");
  const renderRefreshButton = (emptyStyle = false) => {
    const button = el(
      "button",
      emptyStyle ? "hourly-refresh hourly-empty-refresh" : "hourly-refresh"
    );
    button.type = "button";
    button.setAttribute("aria-label", "刷新 Agent 用量");
    button.append(icon("arrowClockwise", 2.1));
    button.addEventListener("click", () => requestAgentRefresh(button));
    return button;
  };

  const renderEmpty = () => {
    const wrap = el("div", "hourly-empty");
    const frame = el("span", "hourly-empty-frame");
    frame.append(icon("activity", 1.6));
    wrap.append(
      frame,
      el("span", "hourly-empty-title", hasHistory() ? "今天还没有 Agent 用量" : "暂无 Agent 用量"),
      el("span", "hourly-empty-desc", "检测到 Agent 活动后，这里会显示今日逐小时折线与模型、项目明细。"),
      renderRefreshButton(true)
    );
    return wrap;
  };

  // 行级展开只重建本卡正文, 不触发整栈重渲染 (保留其他卡片的局部状态)。
  const renderRows = () => {
    body.replaceChildren();
    if (hasHistory()) {
      const chart = el("div", "daily-chart");
      const maxTotal = Math.max(...usage.days.map((day) => day.total), 1);
      const nothing = isNothingTheme();
      for (const day of usage.days) {
        const col = el("div", "day");
        col.title = `${day.date}  ${day.totalText}`;
        col.append(el("div", "day-total", day.totalText));
        if (nothing) {
          // mac Nothing 日柱 (nothingCellSlots): 3 列 × 8 行 = 24 格点阵 (6×6, 间隔 2),
          // 格子自上而下编号; 填充格数 = max(1, round(total/maxDayTotal × 24)), 从第
          // 24 - filled 格起按 segments 顺序落槽 (非末段至少 1 格, 末段吃掉剩余直至末格),
          // 故首段位于填充区顶部; 无分段或格数少于段数时退化为 accent 单色。
          const filled = Math.max(1, Math.round((day.total / maxTotal) * 24));
          const segments = day.segments.filter((segment) => segment.value > 0);
          const slots = new Array(24).fill(null);
          if (!segments.length || filled < segments.length) {
            for (let cell = 24 - filled; cell < 24; cell += 1) slots[cell] = "#4A9E5C";
          } else {
            let index = 24 - filled;
            segments.forEach((segment, offset) => {
              const count = offset === segments.length - 1
                ? Math.max(0, 24 - index)
                : Math.max(1, Math.round((segment.value / day.total) * filled));
              const color = nothingRampHex(segment.agentId);
              for (let step = 0; step < count && index < 24; step += 1) slots[index++] = color;
            });
          }
          const grid = el("div", "day-dots");
          for (const color of slots) {
            const dot = el("i");
            if (color) dot.style.background = color;
            grid.append(dot);
          }
          col.append(grid);
        } else {
          // classic: 柱高 = 当日总量 / 14 日峰值 (--ratio), 段高按当日内份额堆叠
          const bars = el("div", "day-bars");
          bars.style.setProperty("--ratio", (day.total / maxTotal).toFixed(4));
          for (const seg of day.segments) {
            const bar = el("div", "seg");
            bar.style.height = `${(seg.value / Math.max(day.total, 1)) * 100}%`;
            bar.style.background = seg.colorHex;
            bars.append(bar);
          }
          col.append(bars);
        }
        chart.append(col);
      }
      body.append(chart);
      const axis = el("div", "daily-axis");
      axis.append(el("span", null, "14 天前"), el("span", null, "7 天前"), el("span", null, "今天"));
      body.append(axis);
      if (usage.legend.length) {
        const legend = el("div", "daily-legend");
        for (const item of usage.legend) {
          const span = el("span");
          const sw = agentBadgeFor({
            agentId: item.agentId,
            seriesHex: item.colorHex,
            size: isNothingTheme() ? 9 : 12,
            nothingHex: agentColor(item.agentId, item.colorHex),
            // C218: 图例 12pt 仍保留品牌真彩/位图与系列色环.
            forceBrand: !isNothingTheme(),
          });
          span.append(sw, el("span", null, item.name));
          legend.append(span);
        }
        body.append(legend);
      }
      body.append(el("div", "divider"));
    }

    if (!hourly.rows.length) {
      body.append(renderEmpty());
      return;
    }

    const titleRow = el("div", "hourly-title-row");
    titleRow.append(el("span", "sec", "今日"), renderRefreshButton(false));
    body.append(titleRow);

    for (const row of hourly.rows) body.append(agentRow(row, renderRows));
  };

  makeCollapsible(card, () => {
    if (!hourly.rows.length) return el("span", "hourly-empty-mini", "暂无用量");
    const mini = el("span", "hourly-mini");
    const points = hourly.collapsedPoints?.length ? hourly.collapsedPoints : new Array(24).fill(0);
    const chart = el("span", "mini-spark");
    chart.append(lineSpark(points, 12));
    mini.append(chart, el("span", "mini-peak", hourly.collapsedPeakText || "逐小时用量"));
    return mini;
  }, () => {
    resetExpansion();
    renderRows();
  }, "hourly");

  renderRows();
  card.append(body);
  return card;
}

/// C212: Agent 卡内刷新; Windows 当前仅一个 collector 模块, refresh_now 即整模块刷新.
/// 与订阅 ProviderRefreshButton 同构: 14×14 无边框图标, 刷新中替换为小型进度环.
async function requestAgentRefresh(button) {
  if (button.disabled) return;
  button.disabled = true;
  button.classList.add("busy");
  button.replaceChildren(el("span", "sub-spinner"));
  try {
    await invoke("refresh_agent_usage_local");
    setTimeout(() => {
      button.disabled = false;
      button.classList.remove("busy");
      button.replaceChildren(icon("arrowClockwise", 2.1));
    }, 700);
  } catch (error) {
    button.disabled = false;
    button.classList.remove("busy");
    button.replaceChildren(icon("arrowClockwise", 2.1));
    showError(error);
  }
}

/* ---------- 应用层: 缓存读取与单一刷新意图 ---------- */
const tauriCore = window.__TAURI__?.core || window.__TAURI_INTERNALS__;
const invoke = tauriCore?.invoke || (window.__TAURI__ && window.__TAURI__.invoke) || (async () => null);
const listen = window.__TAURI__?.event?.listen || (async () => () => {});
let currentPanel = null;
let currentSettings = {
  cardOrder: ["usage", "subscription", "hourly"],
  providerOrder: [],
  usageEnabled: true,
  layoutMode: "stack",
  activeCardId: "usage",
  activeCardID: "usage",
  motionPreference: "system"
};
let lastSlideDirection = "right";
// C262: 最近一次整栈渲染的正文签名; 未变时仅刷新运行态绑定。
let renderedBodySignature = null;

function panelBodySignature(panel) {
  return JSON.stringify([
    panel.usage,
    panel.subscription,
    panel.hourly,
    currentSettings.layoutMode,
    currentSettings.cardOrder,
    currentSettings.providerOrder,
    currentSettings.usageEnabled,
    currentSettings.enabledProviders,
    currentSettings.activeCardId || currentSettings.activeCardID,
    isNothingTheme(),
  ]);
}

/// C262: 跳过重建时的轻量运行态刷新 (状态灯 / LIVE / 定向刷新按钮可用态)。
function updateRuntimeBindings(panel) {
  renderStatus(panel);
  const dot = document.getElementById("hud-dot-wrap");
  if (dot) dot.classList.toggle("live", Boolean(panel.usage?.isLive));
  const runtime = panel.runtime || {};
  const refreshing = new Set(runtime.refreshingProviders || []);
  for (const button of document.querySelectorAll(".sub-refresh[data-provider]")) {
    const provider = button.dataset.provider;
    const runnable = runtime.quotaRefreshAllowed !== false
      && (!currentSettings.enabledProviders || currentSettings.enabledProviders.includes(provider));
    const busy = refreshing.has(provider);
    button.disabled = !(runnable && !busy && runtime.phase !== "refreshing");
    button.classList.toggle("busy", busy);
  }
}

/* ---------- 全局界面动效闸门 (C145) ----------
 * 应用内偏好与系统「减少动画」的唯一裁决点: 结果只写 <html data-motion>,
 * CSS 侧统一按 html[data-motion="off"] 全量关闭, JS 侧一律读 motionSuppressed()。
 * 不再让 CSS 媒体查询与 JS 判据各自裁决, 否则应用内设置会被系统值覆盖。 */
const MOTION_MEDIA = "(prefers-reduced-motion: reduce)";
function systemReduceMotion() {
  return typeof window.matchMedia === "function" && window.matchMedia(MOTION_MEDIA).matches;
}
function motionSuppressed() {
  const preference = currentSettings.motionPreference || "system";
  if (preference === "never") return true;
  if (preference === "always") return false;
  return systemReduceMotion();
}
function applyMotionPreference() {
  document.documentElement.dataset.motion = motionSuppressed() ? "off" : "on";
}
applyMotionPreference();
if (typeof window.matchMedia === "function") {
  const motionMedia = window.matchMedia(MOTION_MEDIA);
  if (typeof motionMedia.addEventListener === "function") {
    motionMedia.addEventListener("change", applyMotionPreference);
  }
}

async function selectTab(targetKey) {
  const tabKeys = ["usage", "subscription", "hourly"];
  const currentKey = currentSettings.activeCardId || currentSettings.activeCardID || "usage";
  if (targetKey === currentKey) return;
  if (targetKey === "hourly") hourlyExpansionPending = true;
  const fromIndex = tabKeys.indexOf(currentKey);
  const toIndex = tabKeys.indexOf(targetKey);
  lastSlideDirection = toIndex > fromIndex ? "right" : "left";
  currentSettings.activeCardId = targetKey;
  currentSettings.activeCardID = targetKey;
  try {
    if (typeof localStorage !== "undefined") {
      localStorage.setItem("bruce_active_tab", targetKey);
    }
  } catch (e) {}
  try {
    const updated = { ...await invoke("get_settings"), activeCardId: targetKey };
    await invoke("save_settings_command", { settings: updated });
    // C262: 后端保存成功会广播 settings-updated, 由统一监听重绘一次;
    // 这里不再同步 render, 避免同一次切换叠加两次全量重建。
  } catch (e) {
    // 保存失败时后端不会广播; 本地先按新页签渲染, 保持交互一致。
    if (currentPanel) render(currentPanel);
  }
}

document.getElementById("tab-btn-usage")?.addEventListener("click", () => selectTab("usage"));
document.getElementById("tab-btn-subscription")?.addEventListener("click", () => selectTab("subscription"));
document.getElementById("tab-btn-hourly")?.addEventListener("click", () => selectTab("hourly"));

function statusLabel(status) {
  return {
    ok: "正常",
    fresh: "正常",
    ready: "可刷新",
    refreshing: "刷新中",
    loading: "刷新中",
    partial: "部分失败",
    failed: "刷新失败",
    error: "失败",
    stale: "数据过期",
    unavailable: "不可用",
    idle: "等待刷新",
    empty: "暂无数据",
    notConfigured: "未配置",
    authRequired: "需要授权",
  }[status] || status;
}

const TONE_RANK = { neutral: 0, ok: 1, warn: 2, error: 3 };
const TONE_CLASSES = ["tone-ok", "tone-warn", "tone-error", "tone-neutral", "tone-idle"];

function collectionTone(moduleState, hasData) {
  switch (moduleState) {
    case "failed":
    case "error":
    case "unavailable":
      return "error";
    case "partial":
    case "stale":
    case "authRequired":
      return "warn";
    case "fresh":
    case "ready":
    case "ok":
      return "ok";
    case "idle":
    case "refreshing":
    case "loading":
      return hasData ? "ok" : "neutral";
    case "notConfigured":
    case "empty":
    default:
      return "neutral";
  }
}

function sectionTone(status) {
  switch (status) {
    case "error":
    case "failed":
    case "unavailable":
      return "error";
    case "partial":
    case "stale":
    case "authRequired":
      return "warn";
    case "ok":
    case "fresh":
    case "ready":
      return "ok";
    case "empty":
    case "notConfigured":
    case "idle":
    default:
      return "neutral";
  }
}

// C100: 双端同构的顶部四色状态灯单一判定源 (与 mac BruceAppCore.DashboardStatusToneResolver 逐字对齐)。
// detail 只描述采集侧; 订阅侧更严重时原因点名对应服务, 不挂采集侧 detail。
function resolveDashboardStatus({
  moduleState = "empty",
  subscriptions = [],
  hasData = true,
  detail = null,
} = {}) {
  const isRefreshing = moduleState === "refreshing" || moduleState === "loading";
  const modTone = collectionTone(moduleState, Boolean(hasData));

  let subTone = "neutral";
  let worstSubStatus = "empty";
  for (const subscription of subscriptions || []) {
    const candidate = sectionTone(subscription.status);
    if (TONE_RANK[candidate] > TONE_RANK[subTone]) {
      subTone = candidate;
      worstSubStatus = subscription.status;
    }
  }

  const tone = TONE_RANK[subTone] > TONE_RANK[modTone] ? subTone : modTone;
  const trimmedDetail = typeof detail === "string" ? detail.trim() : "";

  let reason;
  if (isRefreshing) {
    reason = "正在刷新…";
  } else if (tone === "ok") {
    reason = "运行正常";
  } else if (TONE_RANK[subTone] > TONE_RANK[modTone]) {
    const label = statusLabel(worstSubStatus);
    const names = [];
    for (const subscription of subscriptions || []) {
      if (sectionTone(subscription.status) !== subTone) continue;
      const name = typeof subscription.name === "string" ? subscription.name.trim() : "";
      if (name && !names.includes(name)) names.push(name);
    }
    reason = names.length ? `${label} · ${names.join("、")}` : label;
  } else {
    const effectiveState = moduleState === "idle" && !hasData ? "empty" : moduleState;
    const label = statusLabel(effectiveState);
    reason = trimmedDetail && trimmedDetail !== label ? `${label} · ${trimmedDetail}` : label;
  }

  return { tone, isRefreshing, reason };
}

// runtime.error 只承载机器码 (scheduler / SnapshotState::fail); hover 原因只展示中文释义,
// 未登记的码不外露 (沿用 C078 文案纪律: 诊断码不直出看板)。原码仍在设置中心诊断区可查。
const RUNTIME_ERROR_TEXT = {
  COLLECTION_PARTIAL: "部分来源未能采集",
  COLLECTION_FAILED: "本次采集失败",
  COLLECTION_WATCHDOG_TIMEOUT: "采集超时已隔离",
  SNAPSHOT_RESTORED: "显示上次保存的数据",
  SNAPSHOT_WRITE_FAILED: "本地快照写入失败",
  SNAPSHOT_INVALID: "本地快照无法读取",
  SNAPSHOT_READ_FAILED: "本地快照无法读取",
  ARTIFACT_MISSING: "采集结果缺失",
  ARTIFACT_INVALID: "采集结果格式无效",
  NETWORK_UNAVAILABLE: "网络不可用",
};
function runtimeErrorText(code) {
  return (typeof code === "string" && RUNTIME_ERROR_TEXT[code]) || null;
}

/* ---------- 看板顶部运行态与四色状态灯 (C079/C080/C100) ---------- */
// 看板顶部除 HUD 头外零输出, 完全对齐 mac (mac header 与卡片栈之间无任何元素;
// PanelViewModel 无 runtime 字段)。服务级失败在订阅卡内部的 section/account note
// 呈现, 整体采集错误在设置窗口呈现, Agent 探针信息在设置中心呈现。
// C100 起移除 #runtime-status 文字牌, 顶部由单一四色状态灯 (#hud-dot-wrap) 承载健康度与 hover 原因。
function renderStatus(panel) {
  const runtime = panel.runtime || {};
  const hasData = Boolean(panel.usage || panel.subscription || panel.hourly);
  const phase = runtime.phase || (hasData ? "fresh" : "empty");
  const subscriptions = (panel.subscription?.sections || [])
    .filter((section) => section?.status)
    .map((section) => ({ status: section.status, name: section.name || "" }));
  const resolved = resolveDashboardStatus({
    moduleState: phase,
    subscriptions,
    hasData,
    detail: runtimeErrorText(runtime.error),
  });
  const dotWrap = document.getElementById("hud-dot-wrap");
  if (dotWrap) {
    dotWrap.classList.remove(...TONE_CLASSES);
    dotWrap.classList.add(`tone-${resolved.tone}`);
    if (resolved.tone === "neutral") dotWrap.classList.add("tone-idle");
    dotWrap.classList.toggle("refreshing", resolved.isRefreshing);
    dotWrap.setAttribute("title", resolved.reason);
    dotWrap.setAttribute("aria-label", resolved.reason);
  }
  const refresh = document.getElementById("refresh");
  refresh.disabled = resolved.isRefreshing;
  refresh.classList.toggle("spinning", resolved.isRefreshing);
}
function render(panel, options = {}) {
  if (!panel || typeof panel !== "object") throw new Error("看板数据不可用");
  currentPanel = panel;
  // C262: 数据/设置/主题未变的再次发布 (如刷新开始) 只更新运行态, 跳过整栈重建,
  // 保留卡片折叠、所选月份与展开态以及 DOM 事件监听。
  const signature = panelBodySignature(panel);
  if (!options.force && signature === renderedBodySignature) {
    updateRuntimeBindings(panel);
    return;
  }
  const activeCount = panel.hourly?.rows.filter(r => r.todayTotal > 0).length || 0;
  document.getElementById("hud-dot-wrap").classList.toggle("live", Boolean(panel.usage?.isLive));

  const isTabbed = currentSettings.layoutMode === "tabbed";
  const agents = document.getElementById("hud-agents");
  const hudTabs = document.getElementById("hud-tabs");
  if (isTabbed) {
    if (agents) agents.style.display = "none";
    if (hudTabs) {
      hudTabs.style.display = "inline-flex";
      const tabKeys = ["usage", "subscription", "hourly"];
      const activeKey = currentSettings.activeCardId || currentSettings.activeCardID || "usage";
      const activeIndex = Math.max(0, tabKeys.indexOf(activeKey));
      tabKeys.forEach((key, idx) => {
        const btn = document.getElementById(`tab-btn-${key}`);
        if (btn) btn.classList.toggle("active", idx === activeIndex);
      });
    }
  } else {
    if (agents) {
      agents.style.display = "";
      // mac dashboardTopHeader: classic「● N AGENTS ACTIVE」/ Nothing「N AGENTS RUNNING」/ 无活跃 STANDBY
      agents.textContent = activeCount > 0
        ? (isNothingTheme() ? `${activeCount} AGENTS RUNNING` : `● ${activeCount} AGENTS ACTIVE`)
        : "STANDBY";
      agents.classList.toggle("standby", activeCount === 0);
    }
    if (hudTabs) hudTabs.style.display = "none";
  }

  renderStatus(panel);
  const stack = document.getElementById("stack");
  stack.replaceChildren();
  const providerOrder = currentSettings.providerOrder || [];
  const subscription = panel.subscription ? { ...panel.subscription, sections: [...panel.subscription.sections].sort((a, b) => {
    const rank = section => {
      const key = section.provider || providerKey(section.id);
      return providerOrder.includes(key) ? providerOrder.indexOf(key) : providerOrder.length;
    };
    return rank(a) - rank(b);
  }) } : null;
  const factories = {
    usage: () => currentSettings.usageEnabled !== false && panel.usage ? usageCard(panel.usage) : null,
    subscription: () => subscription
      ? subscriptionCard(subscription)
      : (panel.usage ? subscriptionEmptyCard() : null),
    hourly: () => currentSettings.usageEnabled !== false && panel.hourly ? hourlyCard(panel.hourly, panel.usage) : null,
  };

  if (isTabbed) {
    const tabKeys = ["usage", "subscription", "hourly"];
    let activeKey = currentSettings.activeCardId || currentSettings.activeCardID || "usage";
    let card = factories[activeKey]?.();
    if (!card) {
      for (const k of tabKeys) {
        card = factories[k]?.();
        if (card) { activeKey = k; break; }
      }
    }
    if (card) {
      card.dataset.card = activeKey;
      card.classList.add(lastSlideDirection === "left" ? "card-slide-enter-left" : "card-slide-enter-right");
      stack.append(card);
    }
  } else {
    const order = [...new Set([...(currentSettings.cardOrder || []), "usage", "subscription", "hourly"])];
    for (const key of order) {
      const card = factories[key]?.();
      if (card) {
        card.dataset.card = key;
        attachDragHandle(card, key);
        stack.append(card);
      }
    }
  }

  if (!stack.children.length) {
    const empty = el("div", "card empty-panel-card");
    const inner = el("div", "empty-panel-inner");
    inner.append(el("div", "empty-title", "未配置模块，前往设置"));
    const btn = el("button", "btn empty-btn", "打开设置");
    btn.type = "button";
    btn.addEventListener("click", () => invoke("open_settings"));
    inner.append(btn);
    empty.append(inner);
    stack.append(empty);
  }
  renderedBodySignature = signature;
}
// 致命错误 (面板无法渲染 / IPC 失败): 顶部零输出 (C080/C100), 只把 HUD 状态灯标为红色「失败」,
// 详情走控制台保留可诊断性。
function showError(error) {
  const dotWrap = document.getElementById("hud-dot-wrap");
  if (dotWrap) {
    dotWrap.classList.remove(...TONE_CLASSES, "refreshing");
    dotWrap.classList.add("tone-error");
    dotWrap.setAttribute("title", "失败");
    dotWrap.setAttribute("aria-label", "失败");
  }
  console.error("看板渲染失败:", error);
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
function applyTheme(theme) {
  document.body.classList.toggle("theme-nothing", theme === "nothing");
  document.body.classList.toggle("theme-fluent", theme !== "nothing");
}
function applySettings(settings) {
  currentSettings = settings;
  applyTheme(settings.theme);
  // C145: 动效偏好变更后立即刷新 <html data-motion>, 无需重启.
  applyMotionPreference();
  // 设置变更可能影响卡片顺序/启用集合/布局: 强制重建一次。
  if (currentPanel) renderWhenVisible(currentPanel, { force: true });
}
window.addEventListener("settings-saved", event => applySettings(event.detail));
// C013: 面板隐藏时跳过全量 DOM 重建 (常驻周期刷新每拍都在重渲染不可见节点);
// 脏标记挂起, 下次可见时补渲一次。document.hidden 在旧环境/测试桩缺省时
// 视为可见, 行为与门控前一致。
let pendingPanel = null;
let pendingForce = false;
function renderWhenVisible(panel, options = {}) {
  if (document.hidden === true) {
    pendingPanel = panel;
    pendingForce = Boolean(options.force);
    return;
  }
  render(panel, options);
}

function renderPendingPanel() {
  if (pendingPanel === null) return;
  const panel = pendingPanel;
  const force = pendingForce;
  pendingPanel = null;
  pendingForce = false;
  render(panel, { force });
}

function triggerCurtainEnter() {
  const panelEl = document.getElementById("panel");
  if (!panelEl) return;
  panelEl.classList.remove("curtain-exit");
  panelEl.classList.remove("curtain-enter");
  // C145: 抑制动效时直接落定终态, 不加动画类.
  if (motionSuppressed()) return;
  // 强制回流以重新触发关键帧动效
  if (typeof panelEl.offsetWidth === "number") void panelEl.offsetWidth;
  panelEl.classList.add("curtain-enter");
}

function requestHideDashboard() {
  const panelEl = document.getElementById("panel");
  // C145: 与入场的闸门同源, 不再各自读 matchMedia.
  if (!panelEl || motionSuppressed()) {
    invoke("hide_dashboard").catch(() => {});
    return;
  }
  panelEl.classList.remove("curtain-enter");
  panelEl.classList.add("curtain-exit");
  let completed = false;
  const finish = () => {
    if (completed) return;
    completed = true;
    panelEl.removeEventListener("animationend", finish);
    invoke("hide_dashboard").catch(() => {});
  };
  panelEl.addEventListener("animationend", finish);
  setTimeout(finish, 160);
}

document.addEventListener("visibilitychange", () => {
  if (document.hidden !== true) {
    triggerCurtainEnter();
    renderPendingPanel();
  }
});
window.addEventListener("focus", () => {
  triggerCurtainEnter();
});
function cardShortcutAvailable(cardID) {
  if (!currentPanel) return false;
  if (cardID === "usage") return Boolean(currentPanel.usage);
  // C259: 空订阅页由 usage 存在时渲染的空态卡承载；不存在 subscriptionEmpty 字段。
  if (cardID === "subscription") return Boolean(currentPanel.subscription || currentPanel.usage);
  if (cardID === "hourly") return Boolean(currentPanel.hourly);
  return false;
}

window.addEventListener("keydown", event => {
  if (event.key === "Escape") {
    requestHideDashboard();
    return;
  }
  // C211: Ctrl+1/2/3 固定卡片快捷键; 长按不连发, 裸数字退役.
  if (!event.ctrlKey || event.repeat) return;
  const cardID = event.key === "1" ? "usage"
    : event.key === "2" ? "subscription"
    : event.key === "3" ? "hourly"
    : null;
  if (!cardID) return;
  if (currentSettings.layoutMode === "tabbed") {
    if (!cardShortcutAvailable(cardID)) return;
    event.preventDefault();
    selectTab(cardID);
    return;
  }
  const card = document.querySelector(`#stack [data-card="${cardID}"]`);
  if (!card) return;
  event.preventDefault();
  if (typeof card.scrollIntoView === "function") {
    card.scrollIntoView({ block: "start", behavior: "smooth" });
  }
  const head = card.querySelector(".card-head");
  const collapsed = card.classList.toggle("collapsed");
  if (collapsed) collapsedCards.add(cardID);
  else collapsedCards.delete(cardID);
  if (head) {
    head.classList.toggle("collapsed", collapsed);
    head.setAttribute("aria-expanded", String(!collapsed));
  }
});
(async function init() {
  try {
    await listen("dashboard-updated", event => { try { renderWhenVisible(event.payload); } catch (error) { showError(error); } });
    await listen("settings-updated", event => applySettings(event.payload));
    await listen("dashboard-show-transition", () => triggerCurtainEnter());
    applySettings(await invoke("get_settings"));
    render(await invoke("get_dashboard"));
    triggerCurtainEnter();
  } catch (error) { showError(error); }
})();
