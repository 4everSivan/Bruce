#!/usr/bin/env node
// Bruce 应用内更新清单生成器 (T09 / 07-软件更新 §4.2 R1.3)。
// 输入本地产物与 VERSION, 产出 Tauri updater 兼容的 latest.json:
//   platforms.darwin-universal  { url, sha256 }
//   platforms.windows-x86_64    { url, signature }   (minisign, 取 .sig 文件内容)
//
// 用法 (CI release-windows 作业, 仓库根):
//   node scripts/generate-update-manifest.mjs \
//     --mac-sums SHA256SUMS --mac-asset Bruce.zip \
//     --win-setup apps/win/src-tauri/target/release/bundle/nsis/Bruce_x.y.z_x64-setup.exe \
//     --win-sig  <同路径>.sig \
//     --notes    dist/release-notes-x.y.z.md \
//     --out      latest.json
// 本地 mac 全量场景可改用 --mac-zip dist/Bruce.zip 直接计算 sha256 (与 --mac-sums 二选一,
// 同时给出时以本地 zip 计算值与 sums 交叉核对, 不一致即失败)。
//
// 纪律: 任一输入缺失/为空/校验不符立即非零退出, 绝不产出半成品清单 (与 build-release-app.sh 同哲学)。

import { createHash } from "node:crypto";
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { resolve } from "node:path";

const args = process.argv.slice(2);
const opts = {};
for (let i = 0; i < args.length; i += 2) {
  const key = args[i];
  if (!key.startsWith("--")) usageExit(`参数 ${key} 缺少 -- 前缀`);
  opts[key.slice(2)] = args[i + 1];
}

const REPO = opts.repo || "4everSivan/Bruce";
const VERSION_FILE = opts["version-file"] || "VERSION";
const MAC_ASSET = opts["mac-asset"] || "Bruce.zip";
const OUT = opts.out || "latest.json";

function usageExit(message) {
  console.error(`generate-update-manifest: ${message}`);
  console.error("用法: node scripts/generate-update-manifest.mjs (--mac-zip PATH | --mac-sums PATH --mac-asset NAME) --win-setup PATH --win-sig PATH --notes PATH [--version-file PATH] [--repo O/R] [--tag vX.Y.Z] [--pub-date ISO] [--out PATH]");
  process.exit(1);
}

function requireFile(path, label) {
  if (!path) usageExit(`缺少 --${label} 参数`);
  if (!existsSync(resolve(path))) usageExit(`${label} 不存在: ${path}`);
  return resolve(path);
}

// ---- 版本: 单一事实源 VERSION, 拒绝 v 前缀与格式漂移 ----
const versionPath = requireFile(VERSION_FILE, "version-file");
const version = readFileSync(versionPath, "utf8").trim();
if (!/^\d+\.\d+\.\d+$/.test(version)) {
  usageExit(`VERSION 内容非法: "${version}" (需要 X.Y.Z 纯三段)`);
}
const tag = opts.tag || `v${version}`;

// ---- macOS sha256: 本地 zip 直算 或 从 SHA256SUMS 提取; 两者同给则交叉核对 ----
let macSha = null;
if (opts["mac-zip"]) {
  const zipPath = requireFile(opts["mac-zip"], "mac-zip");
  macSha = createHash("sha256").update(readFileSync(zipPath)).digest("hex");
}
if (opts["mac-sums"]) {
  const sumsPath = requireFile(opts["mac-sums"], "mac-sums");
  const line = readFileSync(sumsPath, "utf8").split("\n")
    .find((l) => l.trim().endsWith(MAC_ASSET));
  if (!line) usageExit(`SHA256SUMS 中找不到资产 ${MAC_ASSET} 的条目`);
  const sumsSha = line.trim().split(/\s+/)[0].toLowerCase();
  if (!/^[0-9a-f]{64}$/.test(sumsSha)) usageExit(`SHA256SUMS 条目哈希非法: ${line.trim()}`);
  if (macSha && macSha !== sumsSha) {
    usageExit(`mac zip 实算 sha256 (${macSha}) 与 SHA256SUMS (${sumsSha}) 不一致, 拒绝产出清单`);
  }
  macSha = macSha || sumsSha;
}
if (!macSha) usageExit("必须提供 --mac-zip 或 --mac-sums 之一以确定 macOS sha256");

// ---- Windows: setup.exe + minisign .sig ----
const setupPath = requireFile(opts["win-setup"], "win-setup");
const sigPath = requireFile(opts["win-sig"], "win-sig");
const setupName = setupPath.split("/").pop();
const signature = readFileSync(sigPath, "utf8").trim();
if (!signature) usageExit(`.sig 文件为空: ${sigPath} (未签名产物禁止进入更新清单)`);

// ---- notes: 从 release-notes-<ver>.md 压缩为纯文本摘要 (要点以「; 」连接, 上限 8 条) ----
const notesPath = requireFile(opts.notes, "notes");
// 只取列 0 的顶级要点 (CHANGELOG 形如 `- **标题**: 描述`); 嵌套子要点 (`  - 子项`) 不入摘要,
// 避免同一条特性的子说明把 8 条上限挤爆。
const bullets = readFileSync(notesPath, "utf8").split("\n")
  .filter((l) => /^- /.test(l))
  .map((l) => l.replace(/^- /, "").replace(/\*\*/g, "").replace(/`/g, "").trim())
  .filter(Boolean)
  .slice(0, 8);
const notes = bullets.join("; ");

// ---- 产出 ----
const manifest = {
  version,
  pub_date: opts["pub-date"] || new Date().toISOString(),
  notes,
  platforms: {
    "darwin-universal": {
      url: `https://github.com/${REPO}/releases/download/${tag}/${encodeURIComponent(MAC_ASSET)}`,
      sha256: macSha,
    },
    "windows-x86_64": {
      url: `https://github.com/${REPO}/releases/download/${tag}/${encodeURIComponent(setupName)}`,
      signature,
    },
  },
};
writeFileSync(resolve(OUT), JSON.stringify(manifest, null, 2) + "\n");
console.log(`latest.json 已生成 -> ${resolve(OUT)}`);
console.log(`  version=${version} tag=${tag}`);
console.log(`  darwin-universal  sha256=${macSha.slice(0, 16)}…`);
console.log(`  windows-x86_64    setup=${setupName} sig=${signature.slice(0, 16)}…`);
console.log(`  notes: ${notes ? notes.length + " 字符" : "(空)"}`);
