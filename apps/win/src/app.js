
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

/* ---------- 用量档位色阶 (唯一事实源: mac PanelModels.UsageTier.tierColors) ---------- */
// 五档绿色阶 sage/moss/fern/pine/forest: 基色用于热力图与收起态迷你条 (styles.css
// .l1-.l5 同值), 浅色作为 hero 渐变末端. mac heroGradient 为 topLeading→bottomTrailing、
// 基色 30% → 浅色 100%; 档位由视图模型下发的 usageTier 决定 (今日总量 100M 步进),
// 前端不得写死单档.
const TIER_COLORS = {
  sage: ["#7D9B76", "#9DB597"],
  moss: ["#63885E", "#82A57C"],
  fern: ["#4C7249", "#6A9064"],
  pine: ["#385B38", "#557B52"],
  forest: ["#26452A", "#456B42"],
};
// 档位色只以 CSS 自定义属性下发, 由 styles.css 的 .hero-num / .mini-num 消费;
// 严禁在此写内联背景 —— 内联 background-image 会压过 Nothing 主题的纯色
// 覆写 (C027 实测回归, 见 C029)。
function applyTierVars(node, tier) {
  const [start, end] = TIER_COLORS[tier] || TIER_COLORS.sage;
  node.style.setProperty("--hero-grad-start", start);
  node.style.setProperty("--hero-grad-end", end);
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

/* ---------- Nothing 主题绿阶 (镜像 mac PanelAgentColor.nothingRampHex 深色侧) ---------- */
// 呼吸灯绿 #4A9E5C 基色的 5 档绿阶, 亮→暗; 已知高频 agent 固定档位, 未知 agent 用
// FNV-1a 散列稳定落档 (与 mac 同法)。Windows 恒深色, 故只保留 dark 侧色序。
const NOTHING_RAMP = ["#8CCB98", "#5FAF6E", "#4A9E5C", "#35854A", "#2A6B3C"];
const NOTHING_AGENT_TIER = {
  "kimi-code-cli": 0, "claude-code": 1, "codex": 2, "zcode": 3, "opencode": 4,
  "codebuddy": 2, "kimi-work": 4, grok: 2, pi: 4,
};
function nothingRampHex(agentID) {
  const known = NOTHING_AGENT_TIER[agentID];
  if (known !== undefined) return NOTHING_RAMP[known];
  let hash = 0x811c9dc5;
  for (let index = 0; index < agentID.length; index += 1) {
    hash ^= agentID.charCodeAt(index);
    hash = Math.imul(hash, 0x01000193) >>> 0;
  }
  return NOTHING_RAMP[hash % NOTHING_RAMP.length];
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
  try { await invoke("save_settings_command", { settings: currentSettings }); }
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

function makeCollapsible(card, summary) {
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
  };
  head.addEventListener("click", toggle);
  head.addEventListener("keydown", event => {
    if (event.key === "Enter" || event.key === " ") { event.preventDefault(); toggle(); }
  });
}

/* ---------- Token 用量卡 (mac UsageHeroCard) ---------- */
function usageCard(usage) {
  const card = el("div", "card usage-card");
  // 档位色注入卡片容器, .hero-num 与 .mini-num 经 CSS 变量继承取色
  applyTierVars(card, usage.usageTier);
  // 背景纹样层: classic 字符流 tint 取档位浅色 (mac CodeStreamBackground tint = tierColors.1);
  // Nothing 由 CSS 改为点阵。独立成层以便只对纹样做底部渐隐 mask。
  const tint = (TIER_COLORS[usage.usageTier] || TIER_COLORS.sage)[1];
  card.style.setProperty("--code-stream", codeStreamImage(tint));
  const background = el("div", "usage-bg");
  background.setAttribute("aria-hidden", "true");
  card.append(background);
  let live = null;
  if (usage.isLive) {
    live = el("span", "live-badge");
    live.append(el("span", "live-dot"), el("span", "live-text", "LIVE"));
  }
  cardHead(card, "Token 用量", live);
  // 收起态: 17pt 总量 + 近 7 天迷你热力条 (level 0-5, 与展开态热力图同源配色)
  makeCollapsible(card, () => {
    const mini = el("span", "usage-mini");
    const week = el("span", "mini-week");
    for (const level of usage.collapsedWeekLevels) week.append(el("i", level > 0 ? `l${Math.min(level, 5)}` : null));
    mini.append(el("b", "mini-num", usage.totalTokensText), week);
    return mini;
  });

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
          chip.setAttribute("aria-label", `${month.label} ${month.totalText}，查看该月模型用量`);
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

    // 模型用量 (mac modelUsageSection): 标题旁 chevron 切换「前 3 / 全部」, 右侧三档
    // segment 与月卡联动, 默认本月; 无模型月度数据 (models 为 null) 时整块隐藏。
    if (models) {
      const msec = el("div", null); msec.id = "models-sec";
      const mhead = el("div", "models-head");
      const left = el("div", "sec-row");
      const titleSpan = el("span", "sec", "模型用量");
      let expanded = false;
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
          b.addEventListener("click", () => { mode = `tier${index}`; renderGrid(); renderSeg(); renderModelRows(); });
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
      expand.addEventListener("click", () => { expanded = !expanded; renderModelRows(); });
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
        if (!cell) { box.classList.add("empty"); }
        else {
          if (cell.level > 0) box.classList.add(`l${Math.min(cell.level, 5)}`);
          box.title = `${cell.date}  ${cell.total.toLocaleString()}`;
          // Nothing 填充格错相位呼吸的相位 (mac: (列×0.12 + 行×0.05) mod 3.2 秒)
          box.style.setProperty("--d", `${((column * 0.12 + row * 0.05) % 3.2).toFixed(2)}s`);
          if (!first) first = cell.date;
          last = cell.date;
        }
        col.append(box);
      });
      grid.append(col);
    });
    sec.append(grid);
    const axis = el("div", "heat-axis");
    const fmt = (value) => { const p = value.split("-"); return `${p[0].slice(2)}/${p[1]}/${p[2]}`; };
    axis.append(el("span", null, first ? fmt(first) : ""), el("span", null, last ? fmt(last) : ""));
    sec.append(axis);
    const legend = el("div", "heat-legend");
    legend.setAttribute("aria-label", "热力图程度图例: 颜色从少到多");
    legend.append(el("span", null, "少"));
    for (let level = 0; level <= 5; level += 1) legend.append(el("span", `sw${level ? ` l${level}` : ""}`));
    legend.append(el("span", null, "多"));
    sec.append(legend);
    card.append(sec);
  }
  return card;
}

/* ---------- 订阅用量卡 ---------- */
// 品牌色板以 mac BruceAppCore.ProviderBrandPalette.hex 为唯一事实源 (styles.css 契约:
// 配色 token 按 mac 源码数值), 双端逐家对齐; C026 起补齐 cline (#18181b)、zhipu 改用
// Z.ai 官方锁版深色 (#2D2D2D); grok/zhipu/cline 沿用 mac 深色品牌色形态。
const PROVIDER_COLORS = { kimi: "#0a84ff", deepseek: "#4d6bfe", volcengine: "#ff6a00", zhipu: "#2D2D2D", codex: "#10a37f", claude: "#d97757", grok: "#111111", opencodeGo: "#8a63d2", stepfun: "#0c5efc", cline: "#18181b" };
// BEGIN GENERATED provider-glyphs (scripts/gen-provider-glyphs.mjs, C026 — 请勿手改)
// 源文件与许可证: docs/assets/provider-icons/SOURCES.json
// 几何口径: 绝对 M/L/C/Z, 由浏览器原生解析; vb=viewBox, shapes=[[d, opacity]]
const PROVIDER_GLYPHS = {
  claude: { vb: "0 0 24 24", shapes: [["M4.714 15.956L9.432 13.308L9.511 13.078L9.431 12.95L9.201 12.95L8.411 12.902L5.716 12.829L3.379 12.732L1.114 12.61L0.544 12.489L0.009 11.785L0.064 11.432L0.544 11.111L1.229 11.171L2.747 11.275L5.024 11.432L6.675 11.53L9.122 11.785L9.511 11.785L9.565 11.627L9.432 11.53L9.329 11.432L6.973 9.836L4.423 8.148L3.087 7.176L2.365 6.685L2 6.223L1.842 5.215L2.498 4.493L3.378 4.553L3.602 4.614L4.495 5.3L6.401 6.776L8.891 8.609L9.255 8.913L9.401 8.809L9.419 8.737L9.255 8.463L7.901 6.017L6.456 3.527L5.812 2.495L5.642 1.876C5.578 1.638 5.543 1.393 5.539 1.147L6.287 0.133L6.7 0L7.695 0.134L8.115 0.498L8.734 1.913L9.735 4.14L11.29 7.17L11.745 8.068L11.988 8.9L12.078 9.155L12.237 9.155L12.237 9.01L12.364 7.304L12.601 5.209L12.831 2.514L12.911 1.754L13.287 0.844L14.034 0.352L14.617 0.632L15.097 1.317L15.03 1.761L14.744 3.612L14.186 6.515L13.821 8.457L14.034 8.457L14.277 8.215L15.26 6.909L16.912 4.845L17.64 4.025L18.49 3.121L19.037 2.69L20.069 2.69L20.828 3.819L20.488 4.985L19.425 6.332L18.545 7.474L17.282 9.174L16.492 10.534L16.566 10.644L16.754 10.624L19.607 10.018L21.149 9.738L22.989 9.423L23.821 9.811L23.911 10.206L23.584 11.013L21.617 11.499L19.31 11.961L15.874 12.774L15.831 12.804L15.88 12.865L17.428 13.011L18.09 13.047L19.71 13.047L22.728 13.272L23.518 13.794L23.991 14.432L23.911 14.917L22.698 15.537L21.058 15.148L17.233 14.238L15.923 13.909L15.74 13.909L15.74 14.019L16.833 15.087L18.836 16.897L21.344 19.227L21.471 19.805L21.15 20.26L20.81 20.211L18.606 18.554L17.756 17.807L15.831 16.187L15.704 16.187L15.704 16.357L16.147 17.006L18.49 20.527L18.612 21.607L18.442 21.96L17.835 22.173L17.167 22.051L15.795 20.127L14.38 17.959L13.239 16.016L13.099 16.096L12.425 23.35L12.109 23.72L11.381 24L10.774 23.539L10.452 22.792L10.774 21.316L11.162 19.392L11.478 17.862L11.763 15.962L11.933 15.33L11.921 15.288L11.781 15.306L10.349 17.273L8.169 20.218L6.445 22.063L6.032 22.227L5.316 21.857L5.382 21.195L5.783 20.606L8.169 17.57L9.608 15.688L10.537 14.602L10.531 14.444L10.476 14.444L4.138 18.56L3.008 18.706L2.523 18.25L2.583 17.504L2.814 17.261L4.721 15.949Z", 1]] },
  cline: { vb: "0 0 24 24", shapes: [["M23.365 13.556L21.923 10.661L21.923 8.994C21.923 6.23 19.705 3.992 16.969 3.992L14.505 3.992C14.683 3.625 14.781 3.213 14.781 2.779C14.783 2.044 14.494 1.338 13.975 0.817C13.457 0.296 12.753 0.002 12.018 0C11.283 0.002 10.579 0.296 10.061 0.817C9.542 1.338 9.253 2.044 9.255 2.779C9.255 3.213 9.353 3.625 9.531 3.992L7.067 3.992C4.331 3.992 2.113 6.23 2.113 8.994L2.113 10.661L0.64 13.549C0.491 13.839 0.491 14.185 0.64 14.476L2.112 17.331L2.112 18.998C2.113 21.762 4.33 24 7.067 24L16.969 24C19.705 24 21.923 21.762 21.923 18.998L21.923 17.33L23.363 14.465C23.506 14.179 23.506 13.843 23.365 13.555M10.511 15.915C10.513 17.166 9.501 18.183 8.25 18.188C6.999 18.183 5.987 17.166 5.989 15.915L5.989 11.873C5.987 10.622 6.998 9.606 8.249 9.6C8.851 9.601 9.427 9.842 9.851 10.268C10.276 10.695 10.513 11.272 10.511 11.874ZM17.796 15.915C17.798 17.166 16.787 18.182 15.536 18.188C14.284 18.184 13.272 17.167 13.274 15.915L13.274 11.873C13.271 10.621 14.283 9.603 15.535 9.6C16.136 9.602 16.713 9.842 17.137 10.269C17.561 10.695 17.798 11.273 17.796 11.874Z", 1]] },
  codex: { vb: "0 0 256 260", shapes: [["M239.184 106.203C245.054 88.524 243.022 69.174 233.608 53.1C219.452 28.459 191 15.784 163.213 21.74C147.554 4.322 123.795 -3.423 100.88 1.419C77.964 6.261 59.37 22.956 52.096 45.22C33.844 48.963 18.09 60.391 8.866 76.58C-5.444 101.182 -2.195 132.214 16.899 153.32C11.007 170.99 13.021 190.343 22.424 206.422C36.598 231.072 65.068 243.746 92.87 237.782C105.236 251.707 123.001 259.63 141.624 259.526C170.105 259.551 195.338 241.165 204.038 214.045C222.287 210.295 238.038 198.869 247.267 182.685C261.404 158.127 258.142 127.262 239.184 106.202M141.624 242.54C130.256 242.558 119.244 238.573 110.519 231.285L112.054 230.415L163.724 200.59C166.34 199.055 167.953 196.256 167.971 193.223L167.971 120.373L189.816 133.009C190.034 133.12 190.186 133.329 190.225 133.572L190.225 193.939C190.169 220.757 168.442 242.484 141.624 242.54M37.158 197.93C31.457 188.085 29.41 176.546 31.377 165.341L32.911 166.262L84.633 196.088C87.239 197.617 90.468 197.617 93.074 196.088L156.255 159.663L156.255 184.884C156.243 185.149 156.111 185.393 155.897 185.549L103.562 215.733C80.305 229.131 50.592 221.164 37.158 197.93M23.549 85.38C29.29 75.472 38.351 67.915 49.129 64.047L49.129 125.437C49.09 128.458 50.697 131.261 53.324 132.753L116.198 169.025L94.353 181.661C94.113 181.788 93.826 181.788 93.586 181.661L41.353 151.53C18.142 138.076 10.182 108.386 23.549 85.125ZM203.015 127.075L139.935 90.445L161.73 77.86C161.97 77.733 162.258 77.733 162.498 77.86L214.731 108.044C231.034 117.451 240.439 135.425 238.873 154.182C237.308 172.939 225.052 189.106 207.415 195.679L207.415 134.288C207.324 131.276 205.652 128.535 203.015 127.075M224.757 94.385L223.222 93.463L171.603 63.382C168.981 61.844 165.733 61.844 163.111 63.382L99.98 99.808L99.98 74.587C99.954 74.326 100.071 74.071 100.287 73.922L152.52 43.789C168.862 34.375 189.173 35.253 204.641 46.044C220.109 56.834 227.948 75.592 224.756 94.18ZM88.061 139.097L66.216 126.512C65.995 126.378 65.845 126.153 65.806 125.898L65.806 65.685C65.831 46.828 76.749 29.684 93.827 21.688C110.904 13.692 131.064 16.283 145.563 28.339L144.028 29.209L92.358 59.034C89.743 60.569 88.129 63.368 88.112 66.401ZM99.929 113.517L128.067 97.3L156.255 113.518L156.255 145.952L128.169 162.17L99.981 145.952Z", 1]] },
  deepseek: { vb: "0 0 24 24", shapes: [["M23.748 4.651C23.494 4.527 23.384 4.764 23.236 4.884C23.185 4.924 23.142 4.974 23.099 5.021C22.727 5.418 22.293 5.678 21.726 5.647C20.897 5.601 20.189 5.861 19.563 6.495C19.43 5.713 18.988 5.247 18.316 4.947C17.964 4.792 17.608 4.636 17.361 4.297C17.189 4.057 17.142 3.788 17.056 3.523C17.001 3.363 16.946 3.2 16.763 3.173C16.563 3.142 16.485 3.309 16.407 3.449C16.094 4.021 15.973 4.651 15.985 5.289C16.012 6.725 16.618 7.869 17.823 8.682C17.96 8.776 17.995 8.869 17.952 9.005C17.87 9.285 17.772 9.558 17.686 9.838C17.631 10.017 17.549 10.056 17.358 9.978C16.709 9.7 16.119 9.3 15.621 8.799C14.764 7.971 13.99 7.056 13.024 6.339C12.8 6.174 12.57 6.018 12.335 5.869C11.35 4.912 12.465 4.126 12.722 4.033C12.992 3.935 12.816 3.6 11.944 3.605C11.072 3.608 10.274 3.9 9.257 4.29C9.106 4.348 8.95 4.393 8.792 4.426C7.842 4.247 6.87 4.213 5.909 4.325C4.024 4.535 2.519 5.425 1.412 6.947C0.082 8.776 -0.231 10.854 0.152 13.02C0.555 15.304 1.72 17.195 3.512 18.673C5.369 20.206 7.509 20.957 9.95 20.813C11.432 20.728 13.082 20.529 14.944 18.953C15.414 19.187 15.906 19.281 16.724 19.351C17.353 19.409 17.959 19.32 18.429 19.222C19.164 19.067 19.113 18.386 18.847 18.261C16.692 17.257 17.165 17.666 16.735 17.335C17.83 16.04 19.503 13.737 20.019 10.602C20.069 10.256 20.134 9.768 20.127 9.488C20.123 9.317 20.162 9.25 20.357 9.231C20.898 9.174 21.423 9.013 21.902 8.756C23.299 7.993 23.862 6.74 23.995 5.239C24.015 5.009 23.991 4.772 23.748 4.651M11.58 18.168C9.492 16.526 8.479 15.985 8.06 16.008C7.67 16.032 7.74 16.48 7.826 16.771C7.916 17.059 8.033 17.258 8.197 17.511C8.311 17.678 8.389 17.927 8.084 18.114C7.411 18.53 6.242 17.974 6.187 17.946C4.826 17.145 3.687 16.086 2.886 14.64C2.111 13.247 1.661 11.752 1.587 10.158C1.567 9.773 1.681 9.636 2.064 9.566C2.568 9.47 3.085 9.457 3.594 9.528C5.725 9.839 7.54 10.792 9.061 12.302C9.929 13.162 10.586 14.189 11.263 15.192C11.983 16.258 12.757 17.274 13.743 18.107C14.091 18.398 14.369 18.62 14.635 18.784C13.833 18.874 12.495 18.893 11.58 18.169ZM12.581 11.728C12.581 11.627 12.63 11.533 12.713 11.475C12.796 11.418 12.902 11.405 12.996 11.441C13.039 11.457 13.077 11.482 13.109 11.515C13.165 11.572 13.196 11.649 13.195 11.729C13.195 11.899 13.059 12.036 12.887 12.036C12.805 12.037 12.727 12.005 12.669 11.947C12.612 11.889 12.58 11.811 12.581 11.729M15.691 13.325C15.491 13.406 15.291 13.476 15.1 13.485C14.813 13.495 14.531 13.405 14.302 13.231C14.028 13.001 13.832 12.873 13.751 12.473C13.722 12.278 13.727 12.079 13.766 11.885C13.836 11.558 13.759 11.348 13.528 11.158C13.34 11.002 13.102 10.959 12.839 10.959C12.75 10.952 12.663 10.926 12.585 10.881C12.52 10.851 12.47 10.796 12.448 10.727C12.427 10.659 12.435 10.585 12.471 10.523C12.525 10.444 12.589 10.373 12.663 10.313C13.019 10.111 13.43 10.177 13.809 10.329C14.161 10.473 14.427 10.737 14.81 11.111C15.202 11.562 15.272 11.687 15.495 12.026C15.671 12.29 15.831 12.562 15.941 12.874C16.007 13.068 15.921 13.227 15.691 13.324", 1]] },
  grok: { vb: "0 0 256 246", shapes: [["M63.83 56.843C91.299 29.363 131.465 21.978 165.542 34.973L167.856 35.89C175.501 38.734 182.165 42.78 187.363 46.541L158.506 59.883C131.637 48.597 100.857 56.274 82.071 75.083C56.666 100.497 51.532 144.567 81.307 173.043L0 245.764C4.296 239.841 9.457 234.191 14.75 228.586L20.565 222.456L23.173 219.682C38.703 203.027 51.983 185.912 43.669 162.973L42.903 160.993C28.311 125.496 36.809 83.897 63.831 56.843M220.787 35.256L256 0L245.872 14.069C224.778 43.785 215.416 62.493 224.762 102.728L224.697 102.663C231.927 133.391 224.194 167.466 199.225 192.465C167.747 224.003 117.373 231.023 75.889 202.635L104.812 189.228C131.288 199.638 160.254 195.067 181.072 174.225C201.89 153.381 206.565 123.025 196.102 97.763C194.113 92.973 188.15 91.771 183.977 94.854L98.87 157.755L220.786 35.147Z", 1]] },
  kimi: { vb: "0 0 24 24", shapes: [["M21.765 0.351C22.998 0.351 24 1.353 24 2.586C24 3.819 22.998 4.82 21.765 4.82L19.791 4.82C19.641 4.82 19.531 4.7 19.531 4.56L19.531 2.586C19.532 1.352 20.531 0.352 21.765 0.35M9.41 13.388L17.857 5.011C18.017 4.851 17.927 4.54 17.717 4.54L13.167 4.54C13.167 4.54 13.067 4.56 13.027 4.6L3.928 13.629C3.788 13.769 3.578 13.649 3.578 13.419L3.578 4.81C3.578 4.66 3.478 4.54 3.357 4.54L0.22 4.54C0.1 4.54 0 4.66 0 4.81L0 23.38C0 23.53 0.1 23.65 0.22 23.65L3.357 23.65C3.477 23.65 3.577 23.53 3.577 23.38L3.577 19.59C3.577 19.51 3.607 19.43 3.657 19.38L6.483 16.584C6.553 16.514 6.643 16.504 6.724 16.554L14.27 22.105C15.468 22.923 16.847 23.435 18.288 23.598C18.408 23.608 18.518 23.488 18.518 23.328L18.518 19.76C18.518 19.62 18.438 19.51 18.328 19.5C17.483 19.364 16.679 19.042 15.973 18.558L9.44 13.828C9.3 13.738 9.29 13.508 9.41 13.387", 1]] },
  opencodeGo: { vb: "0 0 24 24", shapes: [["M22 24L2 24L2 0L22 0ZM17 4.8L7 4.8L7 19.2L17 19.2Z", 1]] },
  stepfun: { vb: "0 0 24 24", shapes: [["M22.012 0L23.044 0L23.044 0.927L24 0.927L24 1.895L23.044 1.895L23.044 3.78L22.012 3.78L22.012 1.896L20.134 1.896L20.134 0.926L22.012 0.926ZM2.6 12.371L2.6 1.87L3.569 1.87L3.569 12.372ZM13.023 13.031L23.973 13.031L23.973 13.949L17.765 13.949L17.765 23.528L13.023 23.528L13.023 13.03ZM5.629 3.333L5.629 15.689L0 15.689L0 20.199L10.386 20.199L10.386 8L20.859 8L20.856 3.332Z", 1]] },
  volcengine: { vb: "0 0 24 24", shapes: [["M7.29 5.36L3.148 21.737C3.134 21.799 3.149 21.865 3.188 21.915C3.228 21.966 3.287 21.996 3.351 21.998L11.641 21.998C11.707 22 11.77 21.971 11.812 21.92C11.854 21.869 11.871 21.802 11.856 21.737L7.7 5.359C7.673 5.268 7.59 5.206 7.495 5.206C7.4 5.206 7.317 5.268 7.29 5.359Z", 0.5], ["M4.553 16.18L3.147 21.738C3.133 21.8 3.148 21.866 3.187 21.916C3.226 21.967 3.286 21.997 3.35 21.999L5.77 21.999L1.219 21.999C1.153 22.001 1.091 21.972 1.049 21.921C1.007 21.87 0.991 21.803 1.005 21.739L3.28 12.778C3.308 12.688 3.391 12.627 3.484 12.627C3.578 12.627 3.661 12.688 3.689 12.778Z", 1], ["M14.44 0.15C14.413 0.059 14.33 -0.003 14.235 -0.003C14.14 -0.003 14.057 0.059 14.03 0.15L8.366 21.739C8.351 21.803 8.367 21.871 8.409 21.922C8.451 21.973 8.514 22.002 8.58 22L19.9 22C19.966 22.002 20.029 21.973 20.071 21.922C20.113 21.871 20.13 21.804 20.115 21.739Z", 0.5], ["M16.694 22L19.901 22C19.967 22.001 20.03 21.972 20.072 21.921C20.113 21.87 20.129 21.802 20.115 21.738L18.276 14.745L19.44 10.153C19.467 10.062 19.55 9.999 19.646 9.999C19.741 9.999 19.824 10.062 19.851 10.153L22.802 21.739C22.817 21.803 22.801 21.871 22.759 21.922C22.717 21.973 22.654 22.002 22.588 22Z", 1], ["M10.278 7.741L6.685 21.736C6.669 21.801 6.685 21.869 6.727 21.921C6.769 21.973 6.832 22.002 6.899 22L14.069 22C14.17 22.002 14.26 21.933 14.283 21.834C14.291 21.802 14.291 21.768 14.283 21.736L10.687 7.742C10.659 7.652 10.576 7.591 10.482 7.591C10.389 7.591 10.306 7.652 10.278 7.742Z", 1]] },
  zhipu: { vb: "5.7 5.7 18.6 18.6", shapes: [["M15.47 7.1L14.17 8.95C13.97 9.24 13.63 9.42 13.27 9.42L6.17 9.42L6.17 7.09C6.16 7.1 15.47 7.1 15.47 7.1Z", 1], ["M24.3 7.1L13.14 22.91L5.7 22.91L16.86 7.1Z", 1], ["M14.53 22.91L15.84 21.05C16.04 20.76 16.38 20.58 16.74 20.58L23.83 20.58L23.83 22.91L14.53 22.91Z", 1]] },
};
// END GENERATED provider-glyphs
// 单账号 section id 带 service 后缀 (如 "codex_4eversivan"), 归一出 provider 键
// 供徽章与余额胶囊取品牌色; 多账号 section id 本身就是 provider 键, 原样返回。
function providerKey(id) { return String(id || "").split("_")[0]; }
// 品牌图形徽章 (C026): 品牌色瓷砖 + 品牌图形 (PROVIDER_GLYPHS, 由
// scripts/gen-provider-glyphs.mjs 生成); 无图形数据的 provider 回退首字母。
// SVG 用 DOM API 构建 (而非 innerHTML), 与前端测试的极简 DOM 边界保持兼容。
// mac ProviderBrandPalette.isDarkBrand: 深色品牌在 Nothing 深色表面不可读, 图形退回 secondary 灰。
const DARK_BRANDS = new Set(["grok", "zhipu", "cline"]);
function badge(providerID, name) {
  const key = providerKey(providerID);
  const b = el("span", "pbadge");
  // 品牌色以 CSS 变量下发: classic 为实底瓷砖 + 白图形, Nothing 由 CSS 改为
  // 品牌色 16% 底 + 品牌色图形 (mac S3 柔彩定稿); 不写内联 background 以免压过主题覆写。
  const color = PROVIDER_COLORS[key] || "#8e8e93";
  b.style.setProperty("--brand", color);
  b.style.setProperty("--brand-nothing", DARK_BRANDS.has(key) ? "#999999" : color);
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
function windowRow(row) {
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
  line.append(el("span", `wp ${level}`, row.percentText));
  line.append(el("span", "wr", row.resetText));
  return line;
}
// 订阅段 Provider 定向刷新 (mac ProviderRefreshButton + SubscriptionRefreshControlPolicy)。
// 目标 provider 取自运行时层附在 section 上的 `provider` (Rust runtime_core 单点归一,
// 只对已知 provider 附加); 缺失即不渲染按钮 (fail-closed, 前端不猜测目标)。
const SCOPED_REFRESH_ERRORS = {
  SCOPED_REFRESH_UNAUTHORIZED: "尚未确认授权, 无法刷新订阅额度",
  SCOPED_REFRESH_DISABLED: "该订阅未启用",
  SCOPED_REFRESH_UNCONFIGURED: "该订阅尚未配置凭证",
  SCOPED_REFRESH_RUNNING: "该订阅正在刷新",
  FULL_REFRESH_RUNNING: "全量刷新进行中, 请稍后再试",
};
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
    } catch (error) {
      const code = String(error?.message || error);
      document.getElementById("dashboard-status").textContent = SCOPED_REFRESH_ERRORS[code] || `订阅刷新失败：${code}`;
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
// 纯余额型双槽 (mac BalanceDualSlotView): 可用余额 + 订阅状态。
function balanceSlots(section) {
  const wrap = el("div", "bal-slots");
  const amount = el("div", "slot");
  amount.append(el("div", "slot-title", "可用余额"));
  amount.append(el("div", "slot-value", section.balance?.amountText || "--"));
  const status = el("div", "slot");
  status.append(el("div", "slot-title", "订阅状态"));
  const statusValue = el("div", "slot-value status");
  statusValue.append(el("span", "slot-dot"), el("span", null, section.status === "ok" ? "正常" : section.status));
  status.append(statusValue);
  wrap.append(amount, status);
  return wrap;
}
// 账号子卡 (mac ProviderAccountCard): 名称 + tag → 窗口行 → error note → 上次成功。
function accountCard(account) {
  const block = el("div", "account-card");
  const head = el("div", "account-head");
  head.append(el("span", "account-name", account.name || account.id));
  if (account.tag) head.append(el("span", "tag-chip", account.tag));
  block.append(head);
  for (const row of account.windows || []) block.append(windowRow(row));
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
  cardHead(card, "订阅用量", sub.updatedText ? el("span", "updated", sub.updatedText) : null);
  // 收起态: 各 provider 一组「品牌徽章 + 5pt 迷你量条」, 量条取最紧张窗口;
  // 纯余额型 (无窗口) 不出迷你量条 (mac collapsedMini)。
  makeCollapsible(card, () => {
    const mini = el("span", "sub-mini");
    for (const section of sub.sections) {
      const peak = collapsedPeakWindow(section);
      if (!peak) continue;
      const group = el("span", "sub-mini-group");
      const meterEl = el("span", `meter ${meterLevel(peak.usedPercent)}`);
      const fill = el("span");
      fill.style.width = `${Math.round(clampedPercent(peak.usedPercent))}%`;
      meterEl.append(fill);
      group.append(badge(section.provider || section.id, section.name), meterEl);
      mini.append(group);
    }
    return mini;
  });
  const body = el("div", "sub-body");
  // 段渲染独立成函数: 多账号展开/收起只重建本卡正文, 不触发整栈重渲染
  // (避免清掉模型用量卡片的选中档位/展开态等局部状态)。
  const renderSections = () => {
    body.replaceChildren();
    for (const section of sub.sections) {
      const multi = isMultiAccount(section);
      const balanceBased = isBalanceBased(section);
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
      // 定向刷新按钮钉在头部行尾 (单/多账号位置统一), 与名称展开开关为兄弟控件
      const refresh = providerRefreshButton(section);
      if (refresh) h.append(refresh);
      block.append(h);

      if (multi) {
        if (expandedSections.has(section.id)) {
          const list = el("div", "account-list-inline");
          for (const account of section.accounts) list.append(accountCard(account));
          block.append(list);
        } else if (section.collapsedWindow) {
          block.append(windowRow(section.collapsedWindow));
        }
      } else if (balanceBased) {
        block.append(balanceSlots(section));
      } else {
        for (const row of section.windows || []) block.append(windowRow(row));
      }

      // error/empty 段保留 collector 说明, 不静默吞掉 (与 mac 门控一致)
      if ((section.status === "error" || section.status === "empty") && section.note) {
        block.append(el("div", "note-line", section.note));
      }
      body.append(block);
    }
    if (isNothingTheme()) {
      const legend = el("div", "nothing-threshold-legend");
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
      body.append(legend);
    }
  };
  renderSections();
  card.append(body);
  return card;
}

/* ---------- Agent 用量卡 (展开: 14 日日柱 + 逐小时行 + 行级明细下钻) ---------- */
// 行级展开状态: mac 用 @State(默认收起, 不持久化), 前端同语义跨刷新保持。
const expandedAgents = new Set();

// 100% 堆叠条 (mac stackedShareBar): 段宽按 share, 段不足 100% 时露出轨道底。
function stackedShareBar(bars, shadeAt) {
  const track = el("div", "share-bar");
  for (const [index, bar] of bars.entries()) {
    const seg = el("div", "share-seg");
    seg.style.width = `${Math.max(2, Math.min(100, bar.share * 100))}%`;
    seg.style.background = shadeAt(index);
    track.append(seg);
  }
  return track;
}

// 明细分组 (mac distributionGroup): 标题 + 堆叠条 + `名称 …… pct% · 总量` 图例。
function detailGroup(title, bars, shadeAt) {
  const group = el("div", "detail-group");
  group.append(el("div", "detail-title", title));
  group.append(stackedShareBar(bars, shadeAt));
  const legend = el("div", "share-legend");
  for (const [index, bar] of bars.entries()) {
    const line = el("div", "legend-row");
    const sw = el("span", "sw");
    sw.style.background = shadeAt(index);
    line.append(sw, el("span", "name", bar.name), el("span", "flex-spacer"));
    const value = el("span", "value");
    value.append(el("span", "pct", sharePercentText(bar.share)));
    value.append(el("span", "sep", ` · ${bar.totalText}`));
    line.append(value);
    line.setAttribute("aria-label", `${bar.name} ${sharePercentText(bar.share)} · ${bar.totalText}`);
    legend.append(line);
  }
  group.append(legend);
  return group;
}

// Nothing 风格项目统计控制台 (镜像 mac nothingProjectConsoleSection 方案 A + 色系 1 翡翠绿阶):
// P1 亮绿 (标签/名称同色), P2 翡翠绿 (名称 primary), P3 起暗薄荷绿 (名称 secondary)。
const PROJECT_TIERS = [
  { tag: "#30D158", name: "#30D158", bg: "rgba(48,209,88,.12)", border: "rgba(48,209,88,.35)", leader: "rgba(48,209,88,.35)" },
  { tag: "#4A9E5C", name: "#E8E8E8", bg: "rgba(74,158,92,.10)", border: "rgba(74,158,92,.25)", leader: "rgba(74,158,92,.35)" },
  { tag: "#2B7A42", name: "#999999", bg: "#1A1A1A", border: "#222222", leader: "rgba(43,122,66,.35)" },
];
function nothingProjectConsole(projects) {
  const consoleEl = el("div", "nothing-prj-console");
  const head = el("div", "prj-console-head");
  head.append(
    el("span", "prj-console-title", "项目统计 // PRJ.CONSOLE"),
    el("span", "prj-console-count", `${projects.length} WORKSPACES`)
  );
  consoleEl.append(head);
  for (const [index, bar] of projects.entries()) {
    const rowEl = el("div", "prj-console-row");
    const tier = PROJECT_TIERS[Math.min(index, PROJECT_TIERS.length - 1)];
    // 6-Tick 进度格: round(share×6), 非零份额至少 1 格
    const activeTicks = Math.max(bar.share > 0 ? 1 : 0, Math.min(6, Math.round(bar.share * 6)));

    const tag = el("span", "prj-tag", `[P${index + 1}]`);
    tag.style.color = tier.tag;
    const name = el("span", index === 0 ? "prj-name top" : "prj-name", bar.name);
    name.style.color = tier.name;
    const leader = el("span", "prj-leader");
    leader.style.setProperty("--leader", tier.leader);
    const tokens = el("span", "prj-tokens", bar.totalText);
    const share = el("span", "prj-badge", sharePercentText(bar.share));
    share.style.color = tier.tag;
    share.style.background = tier.bg;
    share.style.borderColor = tier.border;
    const ticks = el("span", "prj-ticks");
    for (let t = 0; t < 6; t += 1) {
      const tick = el("span", "prj-tick");
      tick.style.background = t < activeTicks ? tier.tag : "#222222";
      ticks.append(tick);
    }

    rowEl.append(tag, name, leader, tokens, share, ticks);
    rowEl.setAttribute("aria-label", `${bar.name} ${sharePercentText(bar.share)} · ${bar.totalText}`);
    consoleEl.append(rowEl);
  }
  return consoleEl;
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
  const dot = el("span", "dot");
  dot.style.background = agentColor(row.agentId, row.colorHex);
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
    if (row.models.length) detail.append(detailGroup("模型占比", row.models, (index) => modelShade(row.colorHex, index)));
    if (row.projects.length) {
      if (isNothingTheme()) {
        detail.append(nothingProjectConsole(row.projects));
      } else {
        detail.append(detailGroup("项目分布", row.projects, projectShade));
      }
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
  // 收起态: 12pt 全 agent 合计迷你折线 + 峰值文案 (mac collapsedMini 同结构)
  makeCollapsible(card, () => {
    const mini = el("span", "hourly-mini");
    const points = hourly.collapsedPoints?.length ? hourly.collapsedPoints : new Array(24).fill(0);
    const chart = el("span", "mini-spark");
    chart.append(lineSpark(points, 12));
    mini.append(chart, el("span", "mini-peak", hourly.collapsedPeakText || "逐小时用量"));
    return mini;
  });

  const body = el("div", "hourly-body");
  // 行级展开只重建本卡正文, 不触发整栈重渲染 (保留其他卡片的局部状态)。
  const renderRows = () => {
    body.replaceChildren();
    if (usage && usage.days.length) {
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
          const sw = el("span", "sw");
          sw.style.background = agentColor(item.agentId, item.colorHex);
          span.append(sw, el("span", null, item.name));
          legend.append(span);
        }
        body.append(legend);
      }
      body.append(el("div", "divider"));
    }

    const titleRow = el("div", "hourly-title-row");
    titleRow.append(el("span", "sec", "逐小时"));
    titleRow.append(el("span", "range", "0 – 23 时"));
    body.append(titleRow);

    for (const row of hourly.rows) body.append(agentRow(row, renderRows));
  };
  renderRows();
  card.append(body);
  return card;
}

/* ---------- 应用层: 缓存读取与单一刷新意图 ---------- */
const tauriCore = window.__TAURI__?.core || window.__TAURI_INTERNALS__;
const invoke = tauriCore?.invoke || (window.__TAURI__ && window.__TAURI__.invoke) || (async () => null);
const listen = window.__TAURI__?.event?.listen || (async () => () => {});
let currentPanel = null;
let currentSettings = { cardOrder: ["usage", "subscription", "hourly"], providerOrder: [], usageEnabled: true };

const HEALTHY_PHASES = new Set(["ok", "fresh", "idle"]);
function statusLabel(status) {
  return { ok: "正常", fresh: "正常", refreshing: "刷新中", loading: "刷新中", partial: "部分失败", failed: "刷新失败", error: "失败", stale: "数据过期", unavailable: "不可用", idle: "等待刷新", empty: "暂无数据", authRequired: "需要授权" }[status] || status;
}

/* ---------- 运行态文案与诊断口径 (C078) ---------- */
// 状态行与诊断行面向用户, 不得直出诊断码。机器码一律映射中文文案; 正常流程产生的码
// 不进用户可见文案 (SNAPSHOT_RESTORED 是每次正常启动 SnapshotState::load 必写的码,
// 而 last_success_at 持久化 —— 直出会让冷启动到首次刷新之间恒挂一行机器码)。
const RUNTIME_ERROR_TEXT = {
  COLLECTION_PARTIAL: "部分订阅查询失败",
  COLLECTION_FAILED: "刷新失败",
  ARTIFACT_MISSING: "未取得采集结果",
  ARTIFACT_INVALID: "采集结果格式异常",
  SNAPSHOT_INVALID: "本地快照损坏, 已重新采集",
  SNAPSHOT_READ_FAILED: "本地快照读取失败",
  SNAPSHOT_WRITE_FAILED: "本地快照写入失败",
  SNAPSHOT_LOCK_FAILED: "本地快照被占用",
  SCOPED_REFRESH_FAILED: "该订阅额度查询失败",
  NETWORK_UNAVAILABLE: "网络不可用, 已暂停自动刷新",
};
const BENIGN_RUNTIME_CODES = new Set(["SNAPSHOT_RESTORED"]);
function runtimeErrorText(code) {
  if (!code) return "";
  if (BENIGN_RUNTIME_CODES.has(code)) return "";
  if (RUNTIME_ERROR_TEXT[code]) return RUNTIME_ERROR_TEXT[code];
  // 未收录的 SCREAMING_SNAKE 码回退通用文案; 已含中文的人工文案原样透出。
  return /^[A-Z][A-Z0-9_]*$/.test(code) ? "采集状态异常" : code;
}
// 「上次成功」以本地可读时间呈现 (ISO 原文对用户无意义); 非 ISO 值原样保留。
function lastSuccessText(value) {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  const pad = (n) => String(n).padStart(2, "0");
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())} ${pad(date.getHours())}:${pad(date.getMinutes())}`;
}
// design/05 规则 11: 主看板只保留「需用户动作」的严重服务级故障 (认证/权限/凭证缺失类);
// 一次性失败 (限流、超时) 不上主看板 —— 仍保留在订阅卡内部与设置页。
// 标记取自 collector 的实际文案; 未命中的失败一律不上看板 (fail-closed, 宁缺勿噪)。
const ACTIONABLE_SERVICE_NOTE_MARKERS = [
  "重新登录", "重新授权", "重新 grok login",
  "凭证被拒绝", "凭证刷新失败", "凭证格式无效", "请求被拒绝",
  "登录态已失效", "会话已失效", "无权访问", "未检测到",
];
function isActionableServiceIssue(diagnostic) {
  if (diagnostic.kind !== "serviceIssue") return false;
  const note = diagnostic.note || "";
  return ACTIONABLE_SERVICE_NOTE_MARKERS.some((marker) => note.includes(marker));
}

function renderStatus(panel) {
  const runtime = panel.runtime || {};
  const diagnostics = panel.diagnostics || [];
  const phase = runtime.phase || (panel.usage || panel.subscription ? "fresh" : "empty");
  // mac Header 恒显 SYS.OK; Windows 保留显式运行态 (C009): 健康时与 mac 同字,
  // 其余状态 (刷新中 / 失败 / 过期 …) 在同一小牌内直出中文并以告警色区分。
  const healthy = HEALTHY_PHASES.has(phase);
  const badge = document.getElementById("runtime-status");
  badge.textContent = healthy ? "SYS.OK" : statusLabel(phase);
  badge.classList.toggle("degraded", !healthy && phase !== "refreshing" && phase !== "loading");
  const details = [runtimeErrorText(runtime.error)];
  if (runtime.lastSuccessAt) details.push(`上次成功 ${lastSuccessText(runtime.lastSuccessAt)}`);
  if (!panel.usage && !panel.subscription && !panel.hourly) details.push("暂无采集数据，可刷新或检查设置。");
  document.getElementById("dashboard-status").textContent = details.filter(Boolean).join(" · ");
  const host = document.getElementById("dashboard-diagnostics");
  if (host) {
    host.replaceChildren();
    // 过滤会话探测项：未发现会话记录与空 Agent 提示归入设置中心，仪表盘仅保留需用户动作的服务级故障
    const serviceIssues = diagnostics.filter(isActionableServiceIssue);
    for (const diagnostic of serviceIssues) {
      const identity = diagnostic.serviceId || diagnostic.module || "";
      const message = diagnostic.note || diagnostic.reason || statusLabel(diagnostic.status || diagnostic.kind);
      host.append(el("div", "note-line", `${identity ? `${identity}: ` : ""}${message}`));
    }
  }
  const refreshing = phase === "refreshing" || phase === "loading";
  const refresh = document.getElementById("refresh");
  refresh.disabled = refreshing;
  refresh.classList.toggle("spinning", refreshing);
}
function render(panel) {
  if (!panel || typeof panel !== "object") throw new Error("看板数据不可用");
  currentPanel = panel;
  const activeCount = panel.hourly?.rows.filter(r => r.todayTotal > 0).length || 0;
  document.getElementById("hud-dot-wrap").classList.toggle("live", Boolean(panel.usage?.isLive));
  // mac dashboardTopHeader: classic「● N AGENTS ACTIVE」/ Nothing「N AGENTS RUNNING」/ 无活跃 STANDBY
  const agents = document.getElementById("hud-agents");
  agents.textContent = activeCount > 0
    ? (isNothingTheme() ? `${activeCount} AGENTS RUNNING` : `● ${activeCount} AGENTS ACTIVE`)
    : "STANDBY";
  agents.classList.toggle("standby", activeCount === 0);
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
    if (card) {
      card.dataset.card = key;
      attachDragHandle(card, key);
      stack.append(card);
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
}
function showError(error) {
  const badge = document.getElementById("runtime-status");
  badge.textContent = "失败";
  badge.classList.add("degraded");
  document.getElementById("dashboard-status").textContent = String(error);
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
  if (currentPanel) renderWhenVisible(currentPanel);
}
window.addEventListener("settings-saved", event => applySettings(event.detail));
// C013: 面板隐藏时跳过全量 DOM 重建 (常驻周期刷新每拍都在重渲染不可见节点);
// 脏标记挂起, 下次可见时补渲一次。document.hidden 在旧环境/测试桩缺省时
// 视为可见, 行为与门控前一致。
let pendingPanel = null;
function renderWhenVisible(panel) {
  if (document.hidden === true) { pendingPanel = panel; return; }
  render(panel);
}
document.addEventListener("visibilitychange", () => {
  if (document.hidden !== true && pendingPanel !== null) {
    const panel = pendingPanel;
    pendingPanel = null;
    render(panel);
  }
});
window.addEventListener("keydown", event => {
  if (event.key === "Escape") {
    invoke("hide_dashboard").catch(() => {});
  }
});
(async function init() {
  try {
    await listen("dashboard-updated", event => { try { renderWhenVisible(event.payload); } catch (error) { showError(error); } });
    await listen("settings-updated", event => applySettings(event.payload));
    applySettings(await invoke("get_settings"));
    render(await invoke("get_dashboard"));
  } catch (error) { showError(error); }
})();
