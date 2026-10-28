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
// TD-011: 设置窗口拆分为 settings-state + 分节脚本 + settings.js 引导, 脚本清单以
// settings.html 的加载顺序为准 (拆分后仍逐文件做语法检查并合并做接线断言)。
const settingsHtmlSource = readFileSync(join(repoRoot, "apps/win/src/settings.html"), "utf8");
const settingsScripts = [...settingsHtmlSource.matchAll(/<script src="(settings[^"]*\.js)"/g)].map((match) => match[1]);

let failed = false;
const fail = (message) => {
  console.error(`FAIL: ${message}`);
  failed = true;
};

for (const file of ["app.js", ...settingsScripts]) {
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
// 软件更新卡结构断言 (T11, 07-软件更新 §4.2 R3 方案 B): 文案对拍由
// update-presentation.test.mjs 执行, 这里锁住「接线不得被裁撤」的结构面 ——
// 通用页版本行不得回潮、维护页卡/角标/样式/插件接入缺一即红灯。
{
  const settingsHtml = settingsHtmlSource;
  const settingsJs = settingsScripts
    .map((file) => readFileSync(join(repoRoot, "apps/win/src", file), "utf8"))
    .join("\n");
  const stylesCss = readFileSync(join(repoRoot, "apps/win/src/styles.css"), "utf8");
  const rustConf = JSON.parse(readFileSync(join(repoRoot, "apps/win/src-tauri/tauri.conf.json"), "utf8"));
  const rustLib = readFileSync(join(repoRoot, "apps/win/src-tauri/src/software_update.rs"), "utf8");
  const cargo = readFileSync(join(repoRoot, "apps/win/src-tauri/Cargo.toml"), "utf8");

  if (/row\(c1, "版本"/.test(settingsJs)) {
    fail("通用页仍存在「版本」行 (方案 B: 版本行迁入维护页软件更新卡, 07 §4.2 R3)");
  } else {
    console.log("ok: 通用页版本行已迁入维护页软件更新卡 (方案 B)");
  }
  for (const [label, source, pattern] of [
    ["settings.html 载入表现层", settingsHtml, /<script src="update-presentation\.js"><\/script>/],
    ["settings.html 导航角标", settingsHtml, /id="nav-update-dot"/],
    ["settings.js 维护页状态区", settingsJs, /id: "update-stage"/],
    ["settings.js 订阅更新事件", settingsJs, /listen\("update-state"/],
    ["settings.js 检查更新命令", settingsJs, /invoke\("update_check"/],
    ["styles.css PART U 状态区", stylesCss, /\.update-stage/],
    ["styles.css PART U 横幅", stylesCss, /\.update-banner/],
    ["styles.css PART U 进度", stylesCss, /\.update-progress/],
    ["styles.css 导航角标", stylesCss, /\.nav-dot/],
    ["Cargo 接入 updater 插件", cargo, /tauri-plugin-updater/],
  ]) {
    if (!pattern.test(source)) fail(`${label} 缺失 (T11 更新链裁撤即断)`);
  }
  const endpoint = rustConf?.plugins?.updater?.endpoints?.[0];
  const rustEndpoint = rustLib.match(/const MANIFEST_URL[^"]*"([^"]+)"/)?.[1];
  if (!endpoint) fail("tauri.conf.json 缺 plugins.updater.endpoints (插件检查无清单源)");
  else if (rustEndpoint && rustEndpoint !== endpoint) {
    fail(`清单直链两处漂移: conf=${endpoint} rust=${rustEndpoint}`);
  } else {
    console.log(`ok: 更新清单端点一致 (${endpoint})`);
  }
}

// 交互回归 + 面板几何对拍 (demo 内联镜像 ↔ Rust runtime_core fixture, C035)
for (const suite of ["apps/win/tests/frontend.test.mjs", "apps/win/tests/geometry-parity.test.mjs", "apps/win/tests/update-presentation.test.mjs"]) {
  const behavior = spawnSync(process.execPath, ["--test", suite], {
    cwd: repoRoot, stdio: "inherit",
  });
  if (behavior.error || behavior.status !== 0) {
    console.error(`Windows 前端测试失败: ${suite}`, behavior.error?.message || `Exit Code ${behavior.status}`);
    process.exit(behavior.status || 1);
  }
}
