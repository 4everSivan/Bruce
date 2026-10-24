#!/usr/bin/env node
// Bruce 应用内更新清单生成器 (T09 / 07-软件更新 §4.2 R1.3)。
// 输入本地产物与 VERSION, 按 07 §4.2 R1.1 产出 latest.json:
//   platforms.darwin-universal  { url, sha256, signature }
//   platforms.windows-x86_64    { url, signature }   (minisign, 取 .sig 文件内容)
// tauri-plugin-updater 反序列化整张 platforms 表, 每个条目都必须有 url + signature,
// 否则 Windows 客户端整份清单解析失败。
//
// 用法 (由 scripts/upload-win-release.ps1 在 release-windows 作业内调用, 仓库根):
//   node scripts/generate-update-manifest.mjs \
//     --mac-zip Bruce.zip --mac-sums SHA256SUMS --mac-sig Bruce.zip.sig \
//     --win-setup apps/win/src-tauri/target/release/bundle/nsis/Bruce_x.y.z_x64-setup.exe \
//     --win-sig  <同路径>.sig \
//     --notes    release-notes-x.y.z.md \
//     --tag      vx.y.z \
//     --out      latest.json
// sha256 来源: --mac-zip 直接计算 与 --mac-sums 提取 至少给一个; 同时给出时交叉核对,
// 不一致即失败 (CI 两者都给: 下载的 zip 必须与 mac 作业写下的 SHA256SUMS 一致)。
//
// 纪律: 任一输入缺失/为空/校验不符立即非零退出, 绝不产出半成品清单 (与 build-release-app.sh 同哲学)。

import { createHash } from "node:crypto";
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { resolve, win32 } from "node:path";

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
  console.error("用法: node scripts/generate-update-manifest.mjs (--mac-zip PATH | --mac-sums PATH --mac-asset NAME) --mac-sig PATH --win-setup PATH --win-sig PATH --notes PATH [--version-file PATH] [--repo O/R] [--tag v<VERSION>] [--pub-date ISO] [--out PATH]");
  process.exit(1);
}

function requireFile(path, label) {
  if (!path) usageExit(`缺少 --${label} 参数`);
  if (!existsSync(resolve(path))) usageExit(`${label} 不存在: ${path}`);
  return resolve(path);
}

// minisign 签名取 .sig 文件内容 (base64 文本); 空文件视为未签名产物
function readSignature(label) {
  const sigPath = requireFile(opts[label], label);
  const signature = readFileSync(sigPath, "utf8").trim();
  if (!signature) usageExit(`.sig 文件为空: ${sigPath} (未签名产物禁止进入更新清单)`);
  return signature;
}

// ---- 版本: 单一事实源 VERSION, 拒绝 v 前缀与格式漂移 ----
const versionPath = requireFile(VERSION_FILE, "version-file");
const version = readFileSync(versionPath, "utf8").trim();
if (!/^\d+\.\d+\.\d+$/.test(version)) {
  usageExit(`VERSION 内容非法: "${version}" (需要 X.Y.Z 纯三段)`);
}
// 清单 version 与下载 URL 都由 VERSION 派生; 调用方传入实际发版 tag 时必须一致, 否则
// 清单会指向另一个 Release (例如打了 v0.13.0 但 VERSION 仍是 0.12.2)。
const tag = `v${version}`;
if (opts.tag && opts.tag !== tag) {
  usageExit(`发版 tag ${opts.tag} 与 VERSION ${version} 不一致 (应为 ${tag}), 拒绝产出指向错误 Release 的清单`);
}

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
const macSignature = readSignature("mac-sig");

// ---- Windows: setup.exe + minisign .sig ----
const setupPath = requireFile(opts["win-setup"], "win-setup");
// Windows runner 传入的是反斜杠路径; win32.basename 同时识别 \ 与 /, 两端都只取文件名。
const setupName = win32.basename(setupPath);
const signature = readSignature("win-sig");

// ---- notes: 从 release-notes-<ver>.md 压缩为纯文本摘要 (要点以「; 」连接, 上限 8 条) ----
const notesPath = requireFile(opts.notes, "notes");
// 只取顶级要点 (CHANGELOG 形如 `- **标题 (Cxxx)**：说明`) 的加粗标题并去掉卡号: 说明正文
// 面向开发者 (配置键/诊断码), 且不少条目的正文全在嵌套子要点里, 取正文会出现空条目。
// 8 条名额按小节轮转分配、输出保持原文顺序, 避免新功能条目多时修复类整节被挤掉。
const NOTES_LIMIT = 8;
const sections = [[]];
for (const line of readFileSync(notesPath, "utf8").split(/\r?\n/)) {
  if (/^#+ /.test(line)) {
    sections.push([]);
  } else if (/^- /.test(line)) {
    const bold = line.match(/^- \*\*(.+?)\*\*/);
    const title = (bold ? bold[1] : line.slice(2))
      .replace(/\s*[(（][CT]\d+[^)）]*[)）]/g, "")
      .replace(/[`*]/g, "")
      .trim();
    if (title) sections.at(-1).push(title);
  }
}
const quota = sections.map(() => 0);
for (let taken = 0, progressed = true; taken < NOTES_LIMIT && progressed;) {
  progressed = false;
  sections.forEach((items, i) => {
    if (taken < NOTES_LIMIT && quota[i] < items.length) {
      quota[i] += 1;
      taken += 1;
      progressed = true;
    }
  });
}
const notes = sections.flatMap((items, i) => items.slice(0, quota[i])).join("; ");

// ---- 产出 ----
const manifest = {
  version,
  pub_date: opts["pub-date"] || new Date().toISOString(),
  notes,
  platforms: {
    "darwin-universal": {
      url: `https://github.com/${REPO}/releases/download/${tag}/${encodeURIComponent(MAC_ASSET)}`,
      sha256: macSha,
      signature: macSignature,
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
console.log(`  darwin-universal  sha256=${macSha.slice(0, 16)}… sig=${macSignature.slice(0, 16)}…`);
console.log(`  windows-x86_64    setup=${setupName} sig=${signature.slice(0, 16)}…`);
console.log(`  notes: ${notes ? notes.length + " 字符" : "(空)"}`);
