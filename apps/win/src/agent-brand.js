// Agent / 模型厂商品牌身份徽章 (C161) —— 与 mac `AgentBrandBadge` 同口径。
//
// 三档: 真彩档 (≥14pt, 有官方位图用位图, 否则品牌底色+图形, 外圈系列色环) /
// 系列色档 (<14pt, 系列色瓷砖 + 白图形) / Nothing 档 (单色方角) / 字标兜底。
// 依赖: provider-brand.js 的 window.BRUCE_PROVIDER_GLYPHS (矢量图形数据);
// 位图: assets/agent-icons/agent-<id>.png (由 scripts/gen-provider-glyphs.mjs 投放)。
(function () {
  const ICON_BASE = "assets/agent-icons/";
  const DEFAULT_NOTHING = "#4A9E5C";
  const SVG_NS = "http://www.w3.org/2000/svg";

  // 已知 Agent: image = 官方 App 位图, glyph = 矢量图形键, tile/mark = 品牌档配色。
  const AGENT_ASSETS = {
    zcode: { image: "agent-zcode", glyph: "zcode", tile: "#0A0A0A", mark: "#FFFFFF", mono: "Z" },
    "claude-code": { glyph: "claude", tile: "#F2EEE6", mark: "#D97757", mono: "C" },
    codex: { image: "agent-codex", glyph: "codex", tile: "#0A0A0A", mark: "#FFFFFF", mono: "X" },
    "kimi-code-cli": { glyph: "kimi", tile: "#0B0B0B", mark: "#FFFFFF", mono: "K" },
    "kimi-work": { glyph: "kimi", tile: "#0B0B0B", mark: "#FFFFFF", mono: "K" },
    opencode: { glyph: "opencodeGo", tile: "#1C1C1E", mark: "#CFCECD", mono: "O" },
    codebuddy: { image: "agent-codebuddy", tile: "#5B3DF5", mark: "#FFFFFF", mono: "C" },
    grok: { glyph: "grok", tile: "#0B0B0B", mark: "#FFFFFF", mono: "G" },
    pi: { tile: "", mark: "", mono: "π" },
  };

  // 模型厂商: 按规范键/显示名子串匹配, 顺序与 mac AgentBrandPalette 一致
  // (tests/fixtures/agent-brand-parity 双端对拍, C166)。
  const MODEL_ASSETS = [
    { needles: ["claude", "sonnet", "opus"], asset: { glyph: "claude", tile: "#F2EEE6", mark: "#D97757", mono: "C" } },
    { needles: ["deepseek"], asset: { glyph: "deepseek", tile: "#FFFFFF", mark: "#4D6BFE", mono: "D" } },
    { needles: ["glm", "zhipu"], asset: { glyph: "zhipu", tile: "#FFFFFF", mark: "#1F63EC", mono: "G" } },
    { needles: ["gpt", "openai", "codex"], asset: { glyph: "codex", tile: "#FFFFFF", mark: "#0B0B0B", mono: "G" } },
    { needles: ["kimi", "k3"], asset: { glyph: "kimi", tile: "#0B0B0B", mark: "#FFFFFF", mono: "K" } },
    { needles: ["grok", "xai"], asset: { glyph: "grok", tile: "#0B0B0B", mark: "#FFFFFF", mono: "G" } },
    { needles: ["cline"], asset: { glyph: "cline", tile: "#0B0B0B", mark: "#FFFFFF", mono: "C" } },
  ];

  function make(tag, className) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    return node;
  }

  function assetForAgent(agentId) {
    return AGENT_ASSETS[agentId] || null;
  }

  function assetForModel(text) {
    const key = String(text || "").toLowerCase();
    for (const entry of MODEL_ASSETS) {
      if (entry.needles.some((needle) => key.includes(needle))) return entry.asset;
    }
    return null;
  }

  function glyphShapes(glyphId) {
    const table = window.BRUCE_PROVIDER_GLYPHS || {};
    return table[glyphId] || null;
  }

  function buildGlyph(glyphId) {
    const glyph = glyphShapes(glyphId);
    if (!glyph || typeof document.createElementNS !== "function") return null;
    const svg = document.createElementNS(SVG_NS, "svg");
    svg.setAttribute("viewBox", glyph.vb);
    svg.setAttribute("aria-hidden", "true");
    for (const [d, opacity] of glyph.shapes) {
      const path = document.createElementNS(SVG_NS, "path");
      path.setAttribute("d", d);
      if (opacity !== 1) path.setAttribute("fill-opacity", String(opacity));
      svg.append(path);
    }
    return svg;
  }

  function monogram(asset, options) {
    const mono = make("span", "ab-mono");
    mono.textContent =
      (asset && asset.mono) || String(options.displayName || "?").trim().charAt(0).toUpperCase() || "?";
    return mono;
  }

  function buildImage(asset) {
    const img = make("img", "ab-img");
    img.setAttribute("src", ICON_BASE + asset.image + ".png");
    img.setAttribute("alt", "");
    return img;
  }

  // opts: { agentId?, modelKey?, displayName?, seriesHex, size?, nothing?, nothingHex? }
  function create(opts) {
    const options = opts || {};
    const size = Number(options.size) || 14;
    const isNothing = Boolean(options.nothing);
    const series = options.seriesHex || "#8E8E93";
    const nothingHex = options.nothingHex || DEFAULT_NOTHING;
    const asset = options.agentId
      ? assetForAgent(options.agentId)
      : assetForModel(options.modelKey || options.displayName || "");
    const brandStyle = size >= 14 && !isNothing;

    const badge = make("span", "ab-badge");
    badge.style.setProperty("--ab-size", size + "px");
    badge.style.setProperty("--ab-series", series);
    badge.style.setProperty("--ab-tile", brandStyle && asset && asset.tile ? asset.tile : series);
    badge.style.setProperty(
      "--ab-mark",
      isNothing ? nothingHex : brandStyle && asset && asset.mark ? asset.mark : "#FFFFFF"
    );
    if (isNothing) {
      badge.style.setProperty("--ab-nothing", nothingHex);
      badge.classList.add("ab-badge--nothing");
    } else if (brandStyle) {
      badge.classList.add("ab-badge--ring");
    }

    let painted = false;
    if (brandStyle && asset && asset.image) {
      badge.classList.add("ab-badge--img");
      const img = buildImage(asset);
      // 位图缺失或加载失败: 移除位图并露出同档矢量图形, 无图形时退字标 (C166; 与 mac
      // AgentBrandIconStore 缺失静默降级一致, 此前 svg 被 .ab-badge--img 隐藏, 徽章留空)
      img.addEventListener("error", () => {
        img.remove();
        badge.classList.remove("ab-badge--img");
        if (!badge.querySelector("svg")) badge.append(monogram(asset, options));
      });
      badge.append(img);
      painted = true;
    }
    if (asset && asset.glyph) {
      const svg = buildGlyph(asset.glyph);
      if (svg) {
        badge.append(svg);
        painted = true;
      }
    }
    if (!painted) badge.append(monogram(asset, options));
    badge.setAttribute("aria-hidden", "true");
    return badge;
  }

  window.BRUCE_AGENT_BRAND = { create, assetForAgent, assetForModel };
})();
