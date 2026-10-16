#!/usr/bin/env node
// Windows 发布流水线契约测试 (C036)。
// 背景: release-windows 与 scripts/*.ps1 只在 tag 场景真正执行, 本机与 push 都验证不到;
// 这里把「已修复缺陷不得回归」固化为结构断言, 让每次 push 都能守住:
//   1. release 列表取数必须分页且展平 (release 数超过 30 后否则发版失败);
//   2. tauri-cli 必须两端钉同一精确版本 (不钉会在 3.x 稳定后跨大版本漂移);
//   3. 上传前必须清理同名残留资产 (重跑幂等);
//   4. 上传逻辑必须留在 scripts/upload-win-release.ps1 且受 AST 语法门禁约束。
// 与 scripts/check-win-frontend.mjs 同风格: 纯文本结构断言, 无外部依赖。

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..");
const read = (relative) => readFileSync(join(repoRoot, relative), "utf8");

const workflow = read(".github/workflows/ci.yml");
const uploadScript = read("scripts/upload-win-release.ps1");
const localBuildScript = read("scripts/build-win-app.ps1");

let failed = false;
const fail = (message) => {
  console.error(`FAIL: ${message}`);
  failed = true;
};
const ok = (message) => console.log(`ok: ${message}`);

// 1. 分页取数 + 展平 (C036 缺陷一; --slurp 输出为外层数组套各页数组, 必须逐页展平)
if (!/gh api --paginate --slurp "[^"]*releases\?per_page=\d+"/.test(uploadScript)) {
  fail("upload-win-release.ps1 未使用分页取数 `gh api --paginate --slurp ...?per_page=N`");
} else {
  ok("release 列表走 gh api --paginate --slurp 分页取数");
}
if (!/\$releases = @\(\)/.test(uploadScript) || !/foreach \(\$page in \$pages\) \{ \$releases \+= \$page \}/.test(uploadScript)) {
  fail("upload-win-release.ps1 缺少逐页展平 (`--slurp` 返回外层数组套各页数组, 不展平会把 upload_url 取成数组)");
} else {
  ok("分页结果逐页展平为扁平 release 列表");
}
if (/gh api\s+"repos\/\$repo\/releases"/.test(uploadScript)) {
  fail("upload-win-release.ps1 仍存在无分页参数的 release 列表取数 (超过 30 条 release 后发版失败)");
}

// 2. tauri-cli 两端钉同一精确版本
const pinned = [...workflow.matchAll(/cargo install tauri-cli --version "=([\d.]+)"/g)].map((m) => m[1]);
const localPinned = [...localBuildScript.matchAll(/cargo install tauri-cli --version "=([\d.]+)"/g)].map((m) => m[1]);
if (pinned.length !== 1 || localPinned.length !== 1) {
  fail(`tauri-cli 钉版缺失 (CI ${pinned.length} 处 / 本地 ${localPinned.length} 处, 各需 1 处)`);
} else if (pinned[0] !== localPinned[0]) {
  fail(`tauri-cli 版本两端不一致 (CI ${pinned[0]} vs 本地 ${localPinned[0]}), 会造成打包链路漂移`);
} else {
  ok(`tauri-cli 两端钉同一精确版本 ${pinned[0]}`);
}
for (const [label, source] of [["ci.yml", workflow], ["build-win-app.ps1", localBuildScript]]) {
  if (/cargo install tauri-cli --locked/.test(source)) {
    fail(`${label} 仍存在未钉版的 \`cargo install tauri-cli --locked\` (--locked 只钉 CLI 依赖树, 不钉 CLI 版本)`);
  }
}

// 3. 重跑幂等: 上传前清理同名残留资产
if (!/releases\/assets\/\$\(\$stale\.id\)"/.test(uploadScript) || !/--method DELETE/.test(uploadScript)) {
  fail("upload-win-release.ps1 未在上传前清理同名残留资产 (重跑会 422 already_exists)");
} else {
  ok("上传前按 assets[].name 清理同名残留 (重跑幂等)");
}

// 4. 上传逻辑归属 + AST 语法门禁
if (!/run: pwsh -NoProfile -ExecutionPolicy Bypass -File scripts\/upload-win-release\.ps1/.test(workflow)) {
  fail("ci.yml 的上传步骤未调用 scripts/upload-win-release.ps1");
} else {
  ok("release-windows 上传步骤调用独立脚本");
}
const gateLoop = workflow.match(/foreach \(\$path in @\(([^)]*\.ps1[^)]*)\)\)/);
if (!/ParseFile\(\$path, \[ref\]\$null, \[ref\]\$errors\)/.test(workflow) || !gateLoop) {
  fail("verify-windows 缺少发布脚本 AST 语法门禁步骤 (发布脚本只在 tag 场景执行, 语法错误会拖到发版才暴露)");
} else {
  const gated = [...gateLoop[1].matchAll(/"([^"]+\.ps1)"/g)].map((m) => m[1]);
  const required = ["scripts/build-win-app.ps1", "scripts/upload-win-release.ps1"];
  const missing = required.filter((path) => !gated.includes(path));
  if (missing.length > 0) {
    fail(`AST 语法门禁未覆盖: ${missing.join(", ")}`);
  } else {
    ok(`发布脚本 AST 语法门禁覆盖: ${gated.join(", ")}`);
  }
}

if (failed) {
  process.exit(1);
}
console.log("Windows 发布流水线契约测试通过");
