#!/usr/bin/env node
// Windows 前端结构冒烟 (C005): CI 对 apps/win/src 的最低防线。
// 背景: 0184900 曾只回写 app.js/styles.css 而漏 index.html, 前端引用未定义
// 全局与缺失 DOM 节点, 加载即白屏, 而 CI 仅验证 Rust 无法暴露。本脚本锁定:
//   1. app.js 语法合法 (vm 编译, 不执行);
//   2. app.js 中 getElementById 引用的 id 在 index.html 全部有定义;
//   3. demo 模板残留哨兵: 生产数据流走 get_dashboard, 禁止模板注入全局 PANEL。

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..");
const appSource = readFileSync(join(repoRoot, "apps/win/src/app.js"), "utf8");
const htmlSource = readFileSync(join(repoRoot, "apps/win/src/index.html"), "utf8");

let failed = false;
const fail = (message) => {
  console.error(`FAIL: ${message}`);
  failed = true;
};

try {
  new vm.Script(appSource, { filename: "app.js" });
  console.log("ok: app.js 语法合法");
} catch (error) {
  fail(`app.js 语法错误: ${error.message}`);
}

const referenced = new Set();
for (const match of appSource.matchAll(/getElementById\(\s*["']([\w-]+)["']\s*\)/g)) {
  referenced.add(match[1]);
}
const defined = new Set();
for (const match of htmlSource.matchAll(/id="([\w-]+)"/g)) {
  defined.add(match[1]);
}
let missing = 0;
for (const id of [...referenced].sort()) {
  if (!defined.has(id)) {
    fail(`app.js 引用 #${id} 但 index.html 未定义`);
    missing += 1;
  }
}
if (missing === 0) {
  console.log(`ok: DOM id 交叉 (${referenced.size} 个引用全部可达)`);
}

if (/\bPANEL\b/.test(appSource)) {
  fail("app.js 引用 demo 模板注入全局 PANEL (生产数据流应走 get_dashboard)");
} else {
  console.log("ok: 无 demo 残留全局");
}

if (failed) {
  process.exit(1);
}
console.log("Windows 前端结构冒烟通过");
