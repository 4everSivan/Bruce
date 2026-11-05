#!/usr/bin/env node
// 官网同步门禁（T27）：让「网站源码」与「仓库唯一事实源」不再各说各话。
//
// 四条断言（每次 push / verify-local 同跑，规则见 docs/devel/design/13-官方网站.md）：
//   1. 网站源码不得写死版本号——版本只允许以 `{{VERSION}}` 出现在构建前的源文件里；
//   2. 必需占位符必须存在（`{{VERSION}}` 在页面与设置样张里，资产大小占位符在页面里）；
//   3. 订阅厂商图标必须与 `docs/assets/provider-icons/` 逐字节一致（`zai-mark.svg` 为手绘例外）；
//   4. README 的版本徽章与正文版本行必须等于根 `VERSION`。
//
// 用法：node scripts/check-site-sync.mjs [--fix]
//   --fix 从 docs/assets/provider-icons/ 覆盖网站内的图标副本（只同步、不反向写）。

import { copyFile, readFile, readdir, stat } from "node:fs/promises";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..");
const siteRoot = join(repoRoot, "website");
const iconSource = join(repoRoot, "docs", "assets", "provider-icons");
const iconTarget = join(siteRoot, "assets", "provider-icons");
const fix = process.argv.includes("--fix");

// 手绘补充图标：官方 SVG 是多层组合图，官网上只取字形层，故不来自 docs/assets。
const LOCAL_ICONS = new Set(["zai-mark.svg"]);

const problems = [];
const notes = [];
const problem = (message) => problems.push(message);
const note = (message) => notes.push(message);

const read = (path) => readFile(path, "utf8");
const version = (await read(join(repoRoot, "VERSION"))).trim();
if (!/^\d+\.\d+\.\d+$/.test(version)) problem(`VERSION 不是合法的 x.y.z 版本号: ${JSON.stringify(version)}`);

// ---------------------------------------------------------------- 1 & 2. 版本占位符
const SOURCE_FILES = ["website/index.html", "website/js/data.js", "website/js/panel.js",
  "website/js/settings.js", "website/js/site.js", "website/css/base.css",
  "website/css/site.css", "website/css/panel.css", "website/css/settings.css"];
const SEMVER = /(?<![\d.])\d+\.\d+\.\d+(?![\d.])/g;
// 站内联 SVG 的 path 数据是数字串（如 `1.8.5`），不是版本号，扫描前先剥掉 d 属性。
const stripSvg = (source) => source.replace(/\sd="[^"]*"/g, ' d=""');

for (const file of SOURCE_FILES) {
  const text = stripSvg(await read(join(repoRoot, file)));
  for (const match of text.matchAll(SEMVER)) {
    const line = text.slice(0, match.index).split("\n").length;
    problem(`${file}:${line} 写死了版本号 ${match[0]}（应改用 {{VERSION}}，由 scripts/build-site.mjs 注入）`);
  }
}

const indexHtml = await read(join(repoRoot, "website/index.html"));
const settingsJs = await read(join(repoRoot, "website/js/settings.js"));
const required = [
  [indexHtml.includes("{{VERSION}}"), "website/index.html 缺少 {{VERSION}} 占位符"],
  [settingsJs.includes("{{VERSION}}"), "website/js/settings.js 缺少 {{VERSION}} 占位符"],
  [indexHtml.includes("{{DMG_SIZE}}"), "website/index.html 缺少 {{DMG_SIZE}} 占位符"],
  [indexHtml.includes("{{EXE_SIZE}}"), "website/index.html 缺少 {{EXE_SIZE}} 占位符"],
];
for (const [ok, message] of required) if (!ok) problem(message);

// ---------------------------------------------------------------- 3. 厂商图标同步
const providerData = await read(join(repoRoot, "website/js/data.js"));
const referenced = [...new Set([...providerData.matchAll(/icon:\s*"([^"]+)"/g)].map((match) => match[1]))];
if (referenced.length === 0) problem("website/js/data.js 里没有解析到任何厂商图标引用");

const sourceIcons = new Set((await readdir(iconSource)).filter((name) => name.endsWith(".svg")));
for (const name of referenced) {
  const fileName = `${name}.svg`;
  const sitePath = join(iconTarget, fileName);
  let siteBytes;
  try {
    siteBytes = await readFile(sitePath);
  } catch {
    problem(`website/assets/provider-icons/${fileName} 缺失（data.js 引用了该图标）`);
    continue;
  }
  if (LOCAL_ICONS.has(fileName)) {
    note(`website/assets/provider-icons/${fileName} 为手绘补充图标，跳过源比对`);
    continue;
  }
  if (!sourceIcons.has(fileName)) {
    problem(`docs/assets/provider-icons/${fileName} 不存在，网站图标没有可追溯的源文件`);
    continue;
  }
  const sourceBytes = await readFile(join(iconSource, fileName));
  if (!siteBytes.equals(sourceBytes)) {
    if (fix) {
      await copyFile(join(iconSource, fileName), sitePath);
      note(`已同步 docs/assets/provider-icons/${fileName} → website/assets/provider-icons/`);
    } else {
      problem(`website/assets/provider-icons/${fileName} 与 docs/assets 源文件不一致（运行 --fix 同步）`);
    }
  }
}

for (const name of LOCAL_ICONS) {
  try {
    await stat(join(iconTarget, name));
  } catch {
    problem(`website/assets/provider-icons/${name} 缺失（手绘图标清单登记了它）`);
  }
}

// ---------------------------------------------------------------- 4. README 版本行
const readme = await read(join(repoRoot, "README.md"));
const badge = readme.match(/version-v(\d+\.\d+\.\d+)/);
const headline = readme.match(/当前版本 v(\d+\.\d+\.\d+)/);
for (const [match, label] of [[badge, "README 版本徽章"], [headline, "README 「当前版本」行"]]) {
  if (!match) {
    problem(`${label} 缺失，无法校验版本一致性`);
  } else if (match[1] !== version) {
    problem(`${label}写着 v${match[1]}，与根 VERSION ${version} 不一致`);
  }
}

// ---------------------------------------------------------------- 汇总
for (const message of notes) console.log(`note: ${message}`);
if (problems.length > 0) {
  for (const message of problems) console.error(`FAIL: ${message}`);
  console.error(`\n${problems.length} 项官网同步问题（规则见 docs/devel/design/13-官方网站.md）`);
  process.exit(1);
}
console.log(`ok: 官网同步检查通过（版本 ${version}，厂商图标 ${referenced.length} 个）`);
console.log(`  站点源 ${relative(repoRoot, siteRoot)}/ → 构建产物 local/dist/site/`);
