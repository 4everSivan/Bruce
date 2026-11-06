/* ============================================================
   BRUCE — website responsive check
   本地开发工具，不参与构建（website/tools/ 不在构建白名单）。

   用法：
     node website/tools/responsive-check.mjs
     node website/tools/responsive-check.mjs --playwright /path/to/playwright/index.mjs
     node website/tools/responsive-check.mjs --shots

   断言：320–1440 各档位下牌堆可见、断点模式正确、无横向溢出、
   ≤720 三张顶条可切换；退出码 0 才算通过。
   ============================================================ */
import { createServer } from "node:http";
import { existsSync } from "node:fs";
import { readFile, readdir, mkdir, writeFile } from "node:fs/promises";
import { dirname, extname, join, normalize } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { homedir } from "node:os";

const HERE = dirname(fileURLToPath(import.meta.url));
const SITE_ROOT = normalize(join(HERE, ".."));
const OUT_DIR = normalize(join(SITE_ROOT, "..", "local", "site-audit"));
const WIDTHS = [320, 390, 768, 1024, 1100, 1101, 1440];
const VIEW_H = 900;
const MIME = {
  ".html": "text/html",
  ".css": "text/css",
  ".js": "text/javascript",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".woff2": "font/woff2",
  ".json": "application/json",
};

function startServer(root) {
  return new Promise((resolve) => {
    const server = createServer(async (req, res) => {
      let p = decodeURIComponent((req.url || "/").split("?")[0]);
      if (p === "/") p = "/index.html";
      const file = normalize(join(root, p));
      if (!file.startsWith(root)) {
        res.writeHead(403);
        res.end();
        return;
      }
      try {
        const buf = await readFile(file);
        res.writeHead(200, { "content-type": MIME[extname(file)] || "application/octet-stream" });
        res.end(buf);
      } catch {
        res.writeHead(404);
        res.end("404");
      }
    });
    server.listen(0, "127.0.0.1", () => resolve(server));
  });
}

async function resolvePlaywright() {
  const i = process.argv.indexOf("--playwright");
  if (i > -1 && process.argv[i + 1]) return process.argv[i + 1];
  if (process.env.PLAYWRIGHT_MODULE) return process.env.PLAYWRIGHT_MODULE;
  try {
    const mod = await import("playwright");
    if (mod.chromium) return "playwright";
  } catch {
    /* 继续找 npx 缓存 */
  }
  const npx = join(homedir(), ".npm", "_npx");
  if (existsSync(npx)) {
    for (const dir of await readdir(npx)) {
      const p = join(npx, dir, "node_modules", "playwright", "index.mjs");
      if (existsSync(p)) return p;
    }
  }
  return null;
}

async function loadPlaywright() {
  const spec = await resolvePlaywright();
  if (!spec) {
    console.error("找不到 Playwright：请先安装，或用 --playwright <index.mjs> 指定路径。");
    process.exit(1);
  }
  if (spec === "playwright") return import("playwright");
  return import(pathToFileURL(spec).href);
}

function assert(ok, label, detail) {
  const line = `${ok ? "PASS" : "FAIL"}  ${label}${detail ? "  " + detail : ""}`;
  console.log(line);
  return ok;
}

async function measure(page) {
  return page.evaluate(() => {
    const deck = document.querySelector("#panel-deck");
    const host = document.querySelector("#panel-stage");
    const dr = deck.getBoundingClientRect();
    const items = [...document.querySelectorAll(".deck__item")];
    const sheets = items.map((el) => {
      const sh = el.querySelector(".deck__sheet");
      const r = sh.getBoundingClientRect();
      return { theme: el.dataset.theme, display: getComputedStyle(sh).display, w: Math.round(r.width) };
    });
    const peeks = items.map((el) => {
      const p = el.querySelector(".deck__peek");
      return { theme: el.dataset.theme, display: getComputedStyle(p).display, h: Math.round(p.getBoundingClientRect().height) };
    });
    const front = document.querySelector(".deck__item.is-front");
    const peekEl = document.querySelector(".deck__peek");
    return {
      vw: window.innerWidth,
      docW: document.documentElement.scrollWidth,
      mode: host.getAttribute("data-mode"),
      top: Math.round(dr.top + window.scrollY),
      w: Math.round(dr.width),
      h: Math.round(dr.height),
      peekW: peekEl ? Math.round(peekEl.getBoundingClientRect().width) : 0,
      itemsVisible: items.filter((el) => {
        const r = el.getBoundingClientRect();
        return r.width > 0 && r.height > 0 && getComputedStyle(el).display !== "none";
      }).length,
      sheetsVisible: sheets.filter((s) => s.display !== "none" && s.w > 0).length,
      front: front ? front.dataset.theme : null,
      sheets,
      peeks,
      zoom: getComputedStyle(deck).zoom,
      transform: getComputedStyle(deck).transform,
    };
  });
}

async function checkEngine(name, launcher, browserType, url, shots) {
  let browser;
  try {
    browser = await launcher.launch(browserType === "chromium" ? { channel: "chrome", headless: true } : {});
  } catch (err) {
    console.log(`SKIP  ${name} 浏览器不可用：${err.message.split("\n")[0]}`);
    return true;
  }
  let ok = true;
  let page;
  try {
    for (const w of WIDTHS) {
      const ctx = await browser.newContext({ viewport: { width: w, height: VIEW_H } });
      page = await ctx.newPage();
      const errors = [];
      page.on("pageerror", (e) => errors.push(e.message));
      await page.goto(url, { waitUntil: "networkidle" });
      await page.waitForTimeout(450);
      const m = await measure(page);
      const expectThumb = w <= 720;
      const prefix = `${name} ${String(w).padStart(4)}px`;

      ok = assert(m.mode === (expectThumb ? "thumb" : "stack"), `${prefix} 模式`, m.mode) && ok;
      ok = assert(m.w > 0 && m.h > 0, `${prefix} 牌堆可见`, `${m.w}x${m.h} @${m.top}`) && ok;
      ok = assert(m.docW <= m.vw + 1, `${prefix} 无横向溢出`, `docW=${m.docW} vw=${m.vw}`) && ok;
      ok = assert(errors.length === 0, `${prefix} 无 JS 错误`, errors.join(" | ")) && ok;
      ok = assert(m.zoom === "1" || m.zoom === "normal", `${prefix} 未使用 zoom`, m.zoom) && ok;

      if (expectThumb) {
        ok = assert(m.itemsVisible === 3, `${prefix} 三张顶条`, String(m.itemsVisible)) && ok;
        ok = assert(m.sheetsVisible === 1 && m.front, `${prefix} 仅当前卡展开`, `${m.sheetsVisible}/${m.front}`) && ok;
        const peeksVisible = m.peeks.filter((p) => p.display !== "none" && p.h > 0).length;
        ok = assert(peeksVisible === 3, `${prefix} 顶条可见`, String(peeksVisible)) && ok;
        const activeSheet = m.sheets.find((s) => s.display !== "none");
        ok = assert(activeSheet && Math.abs(activeSheet.w - m.peekW) <= 2, `${prefix} 顶条与卡同宽`, `${m.peekW} / ${activeSheet ? activeSheet.w : 0}`) && ok;
        ok = assert(m.top < 600, `${prefix} 首屏可见`, `top=${m.top}`) && ok;
      } else {
        ok = assert(m.itemsVisible === 3, `${prefix} 三卡全部渲染`, String(m.itemsVisible)) && ok;
        ok = assert(m.peeks.every((p) => p.display === "none"), `${prefix} 顶条隐藏`, "") && ok;
        ok = assert(m.top < VIEW_H, `${prefix} 牌堆进入视口`, `top=${m.top}`) && ok;
      }

      if (shots) {
        await mkdir(OUT_DIR, { recursive: true });
        const buf = await page.screenshot({ fullPage: false });
        await writeFile(join(OUT_DIR, `responsive-${name}-${w}.png`), buf);
      }
      await ctx.close();
    }

    /* ≤720 顶条切换 */
    const ctx = await browser.newContext({ viewport: { width: 390, height: VIEW_H } });
    page = await ctx.newPage();
    await page.goto(url, { waitUntil: "networkidle" });
    await page.waitForTimeout(450);
    const before = await measure(page);
    await page.click('.deck__peek[data-deck-theme="nothing"]');
    await page.waitForTimeout(250);
    const after = await measure(page);
    ok = assert(before.front !== after.front && after.front === "nothing", `${name}  390px 顶条切换`, `${before.front} → ${after.front}`) && ok;
    ok = assert(after.sheetsVisible === 1 && after.sheets[0].display !== "none", `${name}  390px 切换后单卡展开`, "") && ok;
    await ctx.close();
  } finally {
    await browser.close();
  }
  return ok;
}

const server = await startServer(SITE_ROOT);
const { port } = server.address();
const url = `http://127.0.0.1:${port}/`;
const pw = await loadPlaywright();
const shots = process.argv.includes("--shots");

let ok = true;
ok = (await checkEngine("chromium", pw.chromium, "chromium", url, shots)) && ok;
ok = (await checkEngine("webkit", pw.webkit, "webkit", url, shots)) && ok;

server.close();
console.log(ok ? "\n响应式检查通过" : "\n响应式检查失败");
process.exit(ok ? 0 : 1);
