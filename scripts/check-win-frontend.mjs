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
import { spawnSync } from "node:child_process";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..");
const appSource = readFileSync(join(repoRoot, "apps/win/src/app.js"), "utf8");
const htmlSource = readFileSync(join(repoRoot, "apps/win/src/index.html"), "utf8");

let failed = false;
const fail = (message) => {
  console.error(`FAIL: ${message}`);
  failed = true;
};

for (const file of ["app.js", "settings.js"]) {
  try {
    new vm.Script(readFileSync(join(repoRoot, "apps/win/src", file), "utf8"), { filename: file });
    console.log(`ok: ${file} 语法合法`);
  } catch (error) {
    fail(`${file} 语法错误: ${error.message}`);
  }
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

// 版本号单一事实源 (C056): 仓库根 VERSION 为权威值, tauri.conf.json 是它的镜像。
// v0.12.0 发布实测: conf 硬编码停留在 0.11.5 未随 VERSION 提升, 导致安装包被命名为
// Bruce_0.11.5_x64-setup.exe 且应用内「版本」行显示 0.11.5 —— 而该缺陷只能在 tag
// 发布时才暴露。此处把一致性前移到每次 push, 漂移即红灯。
{
  const authoritative = readFileSync(join(repoRoot, "VERSION"), "utf8").trim();
  const confPath = "apps/win/src-tauri/tauri.conf.json";
  const conf = JSON.parse(readFileSync(join(repoRoot, confPath), "utf8"));
  if (conf.version !== authoritative) {
    fail(
      `${confPath} 的 version="${conf.version}" 与仓库根 VERSION="${authoritative}" 不一致` +
        " (安装包命名与应用内版本行均取自 conf, 必须同步提升)",
    );
  } else {
    console.log(`ok: Windows 应用版本与 VERSION 一致 (${authoritative})`);
  }
}

if (failed) {
  process.exit(1);
}
console.log("Windows 前端结构冒烟通过");
// 交互回归 + 面板几何对拍 (demo 内联镜像 ↔ Rust runtime_core fixture, C035)
for (const suite of ["apps/win/tests/frontend.test.mjs", "apps/win/tests/geometry-parity.test.mjs"]) {
  const behavior = spawnSync(process.execPath, ["--test", suite], {
    cwd: repoRoot, stdio: "inherit",
  });
  if (behavior.error || behavior.status !== 0) {
    console.error(`Windows 前端测试失败: ${suite}`, behavior.error?.message || `Exit Code ${behavior.status}`);
    process.exit(behavior.status || 1);
  }
}
