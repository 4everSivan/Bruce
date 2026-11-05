#!/usr/bin/env node
// 官方网站构建（T27）。
//
// 官网是纯静态页面，但版本号与下载资产大小不写死在源码里：`website/` 的源文件用
// `{{VERSION}}` / `{{DMG_SIZE}}` / `{{EXE_SIZE}}` 占位，构建时由本脚本注入。
//   - `{{VERSION}}`  取自仓库根 `VERSION`（唯一权威值）；
//   - 资产大小取自 GitHub Release（tag = vVERSION），网络不可用时回退到
//     `local/build/site-release-cache.json` 里上一次成功的结果；
//   - 构建产物一律落在 `local/dist/site/`（见 AGENTS.md 第三节产物收拢纪律）。
//
// 用法：node scripts/build-site.mjs [--strict]
//   --strict  CI / 发布场景使用：占位符未能全部解析即失败，绝不发布半成品。
// 规则与契约见 docs/devel/design/13-官方网站.md。

import { cp, mkdir, readdir, readFile, rm, stat, writeFile } from "node:fs/promises";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..");
const siteSrc = join(repoRoot, "website");
const outDir = join(repoRoot, "local", "dist", "site");
const cacheFile = join(repoRoot, "local", "build", "site-release-cache.json");
const strict = process.argv.includes("--strict");

const COPY = ["index.html", "css", "js", "assets"];
const TEXT_EXT = new Set([".html", ".js", ".css"]);
const SIZE_PLACEHOLDER = /\{\{(DMG_SIZE|EXE_SIZE)\}\}/g;

const fail = (message) => {
  console.error(`FAIL: ${message}`);
  process.exit(1);
};

const version = (await readFile(join(repoRoot, "VERSION"), "utf8")).trim();
if (!/^\d+\.\d+\.\d+$/.test(version)) fail(`VERSION 不是合法的 x.y.z 版本号: ${JSON.stringify(version)}`);

const formatSize = (bytes) => `${(bytes / 1e6).toFixed(1)} MB`;

async function readCache() {
  try {
    const cached = JSON.parse(await readFile(cacheFile, "utf8"));
    return cached && cached.version === version ? cached : null;
  } catch {
    return null;
  }
}

async function writeCache(sizes) {
  try {
    await mkdir(dirname(cacheFile), { recursive: true });
    await writeFile(cacheFile, JSON.stringify({ version, ...sizes }, null, 2) + "\n");
  } catch (error) {
    console.warn(`warn: 发布资产缓存写入失败 (${error.message})，忽略`);
  }
}

// 从 Release 元数据取两件产物的字节数；任一步失败返回 null，由调用方决定回退或报错。
async function fetchAssetSizes() {
  const token = process.env.GITHUB_TOKEN || process.env.GH_TOKEN;
  const headers = {
    Accept: "application/vnd.github+json",
    "User-Agent": "bruce-site-build",
  };
  if (token) headers.Authorization = `Bearer ${token}`;
  const response = await fetch(
    `https://api.github.com/repos/4everSivan/Bruce/releases/tags/v${version}`,
    { headers, signal: AbortSignal.timeout(8000) }
  );
  if (!response.ok) throw new Error(`GitHub API ${response.status}`);
  const release = await response.json();
  const assets = new Map((release.assets || []).map((asset) => [asset.name, asset.size]));
  const dmg = assets.get(`Bruce-${version}.dmg`);
  const exe = assets.get(`Bruce_${version}_x64-setup.exe`);
  if (!Number.isFinite(dmg) || !Number.isFinite(exe)) throw new Error(`v${version} 缺少 dmg / exe 产物`);
  return { dmg: formatSize(dmg), exe: formatSize(exe), source: "github" };
}

let sizes = null;
try {
  sizes = await fetchAssetSizes();
  await writeCache({ dmg: sizes.dmg, exe: sizes.exe });
} catch (error) {
  const cached = await readCache();
  if (cached) {
    sizes = { dmg: cached.dmg, exe: cached.exe, source: "cache" };
    console.warn(`warn: 读取 Release 失败 (${error.message})，使用本地上次缓存`);
  } else {
    console.warn(`warn: 读取 Release 失败 (${error.message})，且无缓存；资产大小将渲染为「—」`);
  }
}

const lookups = {
  VERSION: version,
  DMG_SIZE: sizes ? sizes.dmg : "—",
  EXE_SIZE: sizes ? sizes.exe : "—",
};

if (strict && !sizes) fail("--strict 模式下必须解析出发布资产大小（网络不可用且无缓存）");

await rm(outDir, { recursive: true, force: true });
await mkdir(outDir, { recursive: true });
for (const entry of COPY) {
  const from = join(siteSrc, entry);
  try {
    await stat(from);
  } catch {
    fail(`website/${entry} 不存在，站点源码不完整`);
  }
  await cp(from, join(outDir, entry), { recursive: true });
}

async function* walk(dir) {
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) yield* walk(path);
    else yield path;
  }
}

let substituted = 0;
let textFiles = 0;
const leftovers = [];

for await (const file of walk(outDir)) {
  const ext = file.slice(file.lastIndexOf("."));
  if (!TEXT_EXT.has(ext)) continue;
  textFiles += 1;
  let text = await readFile(file, "utf8");
  text = text.replace(/\{\{(VERSION|DMG_SIZE|EXE_SIZE)\}\}/g, (match, key) => {
    substituted += 1;
    return lookups[key];
  });
  await writeFile(file, text);
  for (const match of text.matchAll(/\{\{[A-Z_]+\}\}/g)) leftovers.push(`${relative(outDir, file)}: ${match[0]}`);
}

if (leftovers.length > 0) fail(`构建产物仍有未解析占位符:\n  ${leftovers.join("\n  ")}`);

const files = [];
for await (const file of walk(outDir)) files.push(file);
const bytes = (await Promise.all(files.map((file) => stat(file)))).reduce((sum, info) => sum + info.size, 0);

console.log(`output   ${relative(repoRoot, outDir)}/  (${files.length} files, ${(bytes / 1024).toFixed(0)} KB)`);
console.log(`version  ${version}`);
console.log(`sizes    dmg ${lookups.DMG_SIZE} / exe ${lookups.EXE_SIZE}  (${sizes ? sizes.source : "unresolved"})`);
console.log(`injected ${substituted} placeholders across ${textFiles} text files`);
console.log("ok: site built");
