#!/usr/bin/env node
// 生成订阅 Provider 品牌图形数据 (C026)。
//
// 输入: docs/assets/provider-icons/*.svg (逐图标来源/许可证见 SOURCES.json)
// 输出:
//   - apps/macos/Sources/BruceAppCore/ProviderBrandGlyphData.swift
//   - apps/win/src/app.js 内的 PROVIDER_GLYPHS 生成块 (markers 包裹)
//
// 归一化口径: 所有几何统一为绝对 M/L/C/Z 命令 (圆弧与简写曲线在生成期展开为
// 三次贝塞尔), 使 SwiftUI 端只需一个极小的解析器, 两端共享同一份路径数据。
//
// 用法:
//   node scripts/gen-provider-glyphs.mjs            # 生成/刷新产物
//   node scripts/gen-provider-glyphs.mjs --check    # 校验产物与源文件一致 (CI)
//   node scripts/gen-provider-glyphs.mjs --dump-json  # 输出归一化数据 (开发期比对)
//
// 开发期像素级自检 (需 rsvg-convert + Pillow, 不进入标准验证):
//   见变更卡 C026 证据记录 —— 归一化几何与原始 SVG 渲染差异 0.00%。

import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..");
const assetsDir = join(repoRoot, "docs/assets/provider-icons");
const swiftOut = join(repoRoot, "apps/macos/Sources/BruceAppCore/ProviderBrandGlyphData.swift");
const winJs = join(repoRoot, "apps/win/src/app.js");

const BEGIN_MARK = "// BEGIN GENERATED provider-glyphs";
const END_MARK = "// END GENERATED provider-glyphs";

// provider id -> [源文件, 仅取该 class 的图形, viewBox 覆盖]
const ICONS = {
  kimi: ["kimi.svg", null, null],
  deepseek: ["deepseek.svg", null, null],
  volcengine: ["volcengine.svg", null, null],
  // Z.ai: 官方 logo 内 st23 图层即 Z 字形; 按字形紧致包围盒裁切 viewBox
  zhipu: ["zai-logo-official.svg", "st23", "5.7 5.7 18.6 18.6"],
  codex: ["openai-icon.svg", null, null],
  claude: ["claude.svg", null, null],
  grok: ["grok-icon.svg", null, null],
  opencodeGo: ["opencode.svg", null, null],
  stepfun: ["stepfun.svg", null, null],
  cline: ["cline.svg", null, null],
};

const NUMBER_RE = /[-+]?(?:\d*\.\d+|\d+\.?)(?:[eE][-+]?\d+)?/g;
const COMMAND_RE = /[MmLlHhVvCcSsQqTtAaZz]/;

// ---------------------------------------------------------------- 路径归一化

function fmt(value) {
  let text = value.toFixed(3).replace(/0+$/, "").replace(/\.$/, "");
  if (text === "-0" || text === "") text = "0";
  return text;
}

function tokenize(d) {
  const tokens = [];
  const pattern = /([MmLlHhVvCcSsQqTtAaZz])|([-+]?(?:\d*\.\d+|\d+\.?)(?:[eE][-+]?\d+)?)/g;
  let match;
  while ((match = pattern.exec(d)) !== null) {
    tokens.push(match[1] ?? match[2]);
  }
  return tokens;
}

// SVG 规范 F.6.5 端点参数化 -> 中心参数化, 再按 <=90° 分段转三次贝塞尔。
function arcToCubics(x0, y0, rx, ry, phiDeg, largeArc, sweep, x1, y1, out) {
  if (rx === 0 || ry === 0) {
    out.push(["L", [x1, y1]]);
    return;
  }
  rx = Math.abs(rx);
  ry = Math.abs(ry);
  const phi = (phiDeg * Math.PI) / 180;
  const cosP = Math.cos(phi);
  const sinP = Math.sin(phi);
  const dx2 = (x0 - x1) / 2;
  const dy2 = (y0 - y1) / 2;
  const x1p = cosP * dx2 + sinP * dy2;
  const y1p = -sinP * dx2 + cosP * dy2;
  const lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry);
  if (lambda > 1) {
    const s = Math.sqrt(lambda);
    rx *= s;
    ry *= s;
  }
  const num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p;
  const den = rx * rx * y1p * y1p + ry * ry * x1p * x1p;
  let coef = Math.sqrt(Math.max(0, num / den));
  if (largeArc === sweep) coef = -coef;
  const cxp = (coef * rx * y1p) / ry;
  const cyp = (-coef * ry * x1p) / rx;
  const cx = cosP * cxp - sinP * cyp + (x0 + x1) / 2;
  const cy = sinP * cxp + cosP * cyp + (y0 + y1) / 2;

  const angle = (ux, uy, vx, vy) => {
    const dot = ux * vx + uy * vy;
    const norm = Math.hypot(ux, uy) * Math.hypot(vx, vy);
    const a = Math.acos(Math.max(-1, Math.min(1, dot / norm)));
    return ux * vy - uy * vx < 0 ? -a : a;
  };

  const theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry);
  let dtheta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry);
  if (!sweep && dtheta > 0) dtheta -= 2 * Math.PI;
  else if (sweep && dtheta < 0) dtheta += 2 * Math.PI;

  const segments = Math.max(1, Math.trunc(Math.abs(dtheta) / (Math.PI / 2) + 0.9999));
  const delta = dtheta / segments;
  const t = (4 / 3) * Math.tan(delta / 4);
  let th = theta1;
  for (let i = 0; i < segments; i += 1) {
    const th2 = th + delta;
    const cos1 = Math.cos(th);
    const sin1 = Math.sin(th);
    const cos2 = Math.cos(th2);
    const sin2 = Math.sin(th2);
    const e1x = cosP * rx * cos1 - sinP * ry * sin1 + cx;
    const e1y = sinP * rx * cos1 + cosP * ry * sin1 + cy;
    const e2x = cosP * rx * cos2 - sinP * ry * sin2 + cx;
    const e2y = sinP * rx * cos2 + cosP * ry * sin2 + cy;
    const d1x = -cosP * rx * sin1 - sinP * ry * cos1;
    const d1y = -sinP * rx * sin1 + cosP * ry * cos1;
    const d2x = -cosP * rx * sin2 - sinP * ry * cos2;
    const d2y = -sinP * rx * sin2 + cosP * ry * cos2;
    out.push([
      "C",
      [e1x + t * d1x, e1y + t * d1y, e2x - t * d2x, e2y - t * d2y, e2x, e2y],
    ]);
    th = th2;
  }
  out[out.length - 1] = ["C", out[out.length - 1][1].slice(0, 4).concat([x1, y1])];
}

// 任意 SVG path -> 绝对 M/L/C/Z 命令列表 [[cmd, [args...]], ...]
function normalizePath(d) {
  const tokens = tokenize(d);
  const out = [];
  let i = 0;
  let cx = 0;
  let cy = 0;
  let start = [0, 0];
  let prevC2 = null;
  let prevQ = null;
  let lastCmd = null;

  const num = () => {
    const value = Number(tokens[i]);
    i += 1;
    return value;
  };

  while (i < tokens.length) {
    let cmd;
    if (COMMAND_RE.test(tokens[i])) {
      cmd = tokens[i];
      i += 1;
    } else {
      cmd = lastCmd === "M" ? "L" : lastCmd === "m" ? "l" : lastCmd;
      if (cmd === null || cmd === undefined) {
        throw new Error(`path 以数字开头: ${d.slice(0, 40)}`);
      }
    }
    const rel = cmd === cmd.toLowerCase();
    const upper = cmd.toUpperCase();

    if (upper === "M") {
      let x = num();
      let y = num();
      if (rel) {
        x += cx;
        y += cy;
      }
      out.push(["M", [x, y]]);
      cx = x;
      cy = y;
      start = [x, y];
      prevC2 = null;
      prevQ = null;
    } else if (upper === "L") {
      let x = num();
      let y = num();
      if (rel) {
        x += cx;
        y += cy;
      }
      out.push(["L", [x, y]]);
      cx = x;
      cy = y;
      prevC2 = null;
      prevQ = null;
    } else if (upper === "H") {
      let x = num();
      if (rel) x += cx;
      out.push(["L", [x, cy]]);
      cx = x;
      prevC2 = null;
      prevQ = null;
    } else if (upper === "V") {
      let y = num();
      if (rel) y += cy;
      out.push(["L", [cx, y]]);
      cy = y;
      prevC2 = null;
      prevQ = null;
    } else if (upper === "C") {
      let a = [num(), num(), num(), num(), num(), num()];
      if (rel) {
        a = [a[0] + cx, a[1] + cy, a[2] + cx, a[3] + cy, a[4] + cx, a[5] + cy];
      }
      out.push(["C", a]);
      prevC2 = [a[2], a[3]];
      cx = a[4];
      cy = a[5];
      prevQ = null;
    } else if (upper === "S") {
      let a = [num(), num(), num(), num()];
      if (rel) {
        a = [a[0] + cx, a[1] + cy, a[2] + cx, a[3] + cy];
      }
      const c1 = prevC2 ? [2 * cx - prevC2[0], 2 * cy - prevC2[1]] : [cx, cy];
      out.push(["C", [c1[0], c1[1], a[0], a[1], a[2], a[3]]]);
      prevC2 = [a[0], a[1]];
      cx = a[2];
      cy = a[3];
      prevQ = null;
    } else if (upper === "Q") {
      let a = [num(), num(), num(), num()];
      if (rel) {
        a = [a[0] + cx, a[1] + cy, a[2] + cx, a[3] + cy];
      }
      const c1 = [cx + (2 / 3) * (a[0] - cx), cy + (2 / 3) * (a[1] - cy)];
      const c2 = [a[2] + (2 / 3) * (a[0] - a[2]), a[3] + (2 / 3) * (a[1] - a[3])];
      out.push(["C", [c1[0], c1[1], c2[0], c2[1], a[2], a[3]]]);
      prevQ = [a[0], a[1]];
      cx = a[2];
      cy = a[3];
      prevC2 = null;
    } else if (upper === "T") {
      let a = [num(), num()];
      if (rel) {
        a = [a[0] + cx, a[1] + cy];
      }
      const q = prevQ ? [2 * cx - prevQ[0], 2 * cy - prevQ[1]] : [cx, cy];
      const c1 = [cx + (2 / 3) * (q[0] - cx), cy + (2 / 3) * (q[1] - cy)];
      const c2 = [a[0] + (2 / 3) * (q[0] - a[0]), a[1] + (2 / 3) * (q[1] - a[1])];
      out.push(["C", [c1[0], c1[1], c2[0], c2[1], a[0], a[1]]]);
      prevQ = q;
      cx = a[0];
      cy = a[1];
      prevC2 = null;
    } else if (upper === "A") {
      const rx = num();
      const ry = num();
      const rot = num();
      const largeArc = Math.trunc(num());
      const sweep = Math.trunc(num());
      let x = num();
      let y = num();
      if (rel) {
        x += cx;
        y += cy;
      }
      arcToCubics(cx, cy, rx, ry, rot, largeArc, sweep, x, y, out);
      cx = x;
      cy = y;
      prevC2 = null;
      prevQ = null;
    } else if (upper === "Z") {
      out.push(["Z", []]);
      [cx, cy] = start;
      prevC2 = null;
      prevQ = null;
    } else {
      throw new Error(`未知命令 ${cmd}`);
    }
    lastCmd = cmd;
  }
  return out;
}

function pathToD(commands) {
  let d = "";
  for (const [cmd, args] of commands) {
    d += cmd === "Z" ? "Z" : cmd + args.map(fmt).join(" ");
  }
  return d;
}

function polygonToD(points) {
  const values = (points.match(NUMBER_RE) ?? []).map(Number);
  const pts = [];
  for (let i = 0; i + 1 < values.length; i += 2) pts.push([values[i], values[i + 1]]);
  let d = `M${fmt(pts[0][0])} ${fmt(pts[0][1])}`;
  for (const [x, y] of pts.slice(1)) d += `L${fmt(x)} ${fmt(y)}`;
  return `${d}Z`;
}

// ---------------------------------------------------------------- 源文件解析

function extractShapes(svgText, onlyClass) {
  const shapes = [];
  const pattern = /<(path|polygon)\b([^>]*?)\/?>/g;
  let match;
  while ((match = pattern.exec(svgText)) !== null) {
    const [, kind, attrs] = match;
    if (onlyClass && !attrs.includes(`class="${onlyClass}"`)) continue;
    const opacityMatch = attrs.match(/fill-opacity="([^"]+)"/);
    const opacity = opacityMatch ? Number(opacityMatch[1]) : 1;
    if (kind === "path") {
      const d = attrs.match(/\sd="([^"]+)"/);
      if (!d) throw new Error(`path 缺少 d 属性: ${attrs.slice(0, 60)}`);
      shapes.push([d[1], opacity]);
    } else {
      const points = attrs.match(/points="([^"]+)"/);
      if (!points) throw new Error(`polygon 缺少 points 属性: ${attrs.slice(0, 60)}`);
      shapes.push([polygonToD(points[1]), opacity]);
    }
  }
  if (shapes.length === 0) throw new Error(`未提取到图形 (class=${onlyClass})`);
  return shapes;
}

function buildIcons() {
  const sources = JSON.parse(readFileSync(join(assetsDir, "SOURCES.json"), "utf8")).icons;
  const icons = {};
  for (const [pid, [fileName, onlyClass, viewBoxOverride]] of Object.entries(ICONS)) {
    const svg = readFileSync(join(assetsDir, fileName), "utf8");
    const viewBox = viewBoxOverride ?? svg.match(/viewBox="([^"]+)"/)[1];
    const shapes = extractShapes(svg, onlyClass).map(([raw, opacity]) => {
      const d = pathToD(normalizePath(raw));
      if (/[^MLCZ0-9 .,+-]/.test(d)) {
        throw new Error(`${pid}: 归一化结果含非 M/L/C/Z 字符`);
      }
      return { d, opacity };
    });
    icons[pid] = {
      viewBox,
      shapes,
      source: `${sources[pid].library} (${sources[pid].license})`,
    };
  }
  return icons;
}

// ---------------------------------------------------------------- 产物渲染

function renderSwift(icons) {
  const lines = [
    "// 本文件由 scripts/gen-provider-glyphs.mjs 生成, 请勿手改 (C026)。",
    "// 源文件与许可证登记: docs/assets/provider-icons/SOURCES.json",
    "//",
    "// 几何口径: 各图形已归一化为绝对 M/L/C/Z 命令 (圆弧与简写曲线在生成期",
    "// 展开为三次贝塞尔), 由 SVGPathBuilder 解析后按 viewBox 等比适配渲染。",
    "",
    "import CoreGraphics",
    "",
    "package enum ProviderBrandGlyphData {",
    "    package struct Shape: Sendable {",
    "        package let path: String",
    "        package let opacity: Double",
    "    }",
    "",
    "    package struct Glyph: Sendable {",
    "        package let viewBox: CGRect",
    "        package let shapes: [Shape]",
    "        /// 来源与许可证 (审计用, 同时约束指示性使用边界)。",
    "        package let source: String",
    "    }",
    "",
    "    package static let glyphs: [String: Glyph] = [",
  ];
  for (const [pid, glyph] of Object.entries(icons).sort(([a], [b]) => a.localeCompare(b))) {
    const [vx, vy, vw, vh] = glyph.viewBox.split(/\s+/);
    lines.push(`        "${pid}": Glyph(`);
    lines.push(`            viewBox: CGRect(x: ${vx}, y: ${vy}, width: ${vw}, height: ${vh}),`);
    lines.push("            shapes: [");
    for (const shape of glyph.shapes) {
      lines.push(`                Shape(path: "${shape.d}", opacity: ${shape.opacity}),`);
    }
    lines.push("            ],");
    lines.push(`            source: "${glyph.source}"`);
    lines.push("        ),");
  }
  lines.push("    ]");
  lines.push("}");
  lines.push("");
  return lines.join("\n");
}

function renderJs(icons) {
  const lines = [
    `${BEGIN_MARK} (scripts/gen-provider-glyphs.mjs, C026 — 请勿手改)`,
    "// 源文件与许可证: docs/assets/provider-icons/SOURCES.json",
    "// 几何口径: 绝对 M/L/C/Z, 由浏览器原生解析; vb=viewBox, shapes=[[d, opacity]]",
    "const PROVIDER_GLYPHS = {",
  ];
  for (const [pid, glyph] of Object.entries(icons).sort(([a], [b]) => a.localeCompare(b))) {
    const shapes = glyph.shapes.map((s) => `["${s.d}", ${s.opacity}]`).join(", ");
    lines.push(`  ${pid}: { vb: "${glyph.viewBox}", shapes: [${shapes}] },`);
  }
  lines.push("};");
  lines.push(END_MARK);
  return lines.join("\n");
}

function patchAppJs(newBlock) {
  const text = readFileSync(winJs, "utf8");
  if (text.includes(BEGIN_MARK)) {
    const head = text.split(BEGIN_MARK)[0];
    const tail = text.split(END_MARK)[1];
    return head + newBlock + tail;
  }
  const anchor = text.match(/^const PROVIDER_COLORS = .*$/m);
  if (!anchor) throw new Error("app.js 中未找到 PROVIDER_COLORS 锚点, 无法插入生成块");
  const insertAt = anchor.index + anchor[0].length;
  return text.slice(0, insertAt) + "\n" + newBlock + text.slice(insertAt);
}

function main() {
  const args = process.argv.slice(2);
  const icons = buildIcons();

  if (args.includes("--dump-json")) {
    process.stdout.write(JSON.stringify(icons, null, 1) + "\n");
    return 0;
  }

  const swift = renderSwift(icons);
  const js = patchAppJs(renderJs(icons));

  if (args.includes("--check")) {
    const drift = [];
    if (readFileSync(swiftOut, "utf8") !== swift) drift.push(swiftOut);
    if (readFileSync(winJs, "utf8") !== js) drift.push(winJs);
    if (drift.length > 0) {
      console.error(
        `生成产物与源文件不一致, 请运行 scripts/gen-provider-glyphs.mjs:\n  ${drift.join("\n  ")}`
      );
      return 1;
    }
    console.log(`provider 品牌图形产物一致 (${Object.keys(icons).length} 个 provider)`);
    return 0;
  }

  writeFileSync(swiftOut, swift);
  writeFileSync(winJs, js);
  const total = Object.values(icons).reduce(
    (sum, glyph) => sum + glyph.shapes.reduce((s, shape) => s + shape.d.length, 0),
    0
  );
  console.log(
    `已生成 ${Object.keys(icons).length} 个 provider 图形 -> Swift + app.js (路径数据 ${total} bytes)`
  );
  return 0;
}

process.exit(main());
