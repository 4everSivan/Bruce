#!/usr/bin/env node
// Windows 发布流水线契约测试 (C036 / T09)。
// 背景: release-windows 与 scripts/*.ps1 只在 tag 场景真正执行, 本机与 push 都验证不到;
// 这里把「已修复缺陷不得回归」固化为结构断言, 让每次 push 都能守住:
//   1. release 列表取数必须分页且展平 (release 数超过 30 后否则发版失败);
//   2. tauri-cli 必须两端钉同一精确版本 (不钉会在 3.x 稳定后跨大版本漂移);
//   3. 上传前必须清理同名残留资产 (重跑幂等);
//   4. 上传逻辑必须留在 scripts/upload-win-release.ps1 且受 AST 语法门禁约束;
//   5. (T09) 更新链资产齐全: 签名私钥门禁、latest.json 生成与 .sig/清单上传不得被裁撤;
//   6. (T09) latest.json 生成器契约: 用临时夹具实测正例与两类失败例 (缺签名/哈希不符)。
// 与 scripts/check-win-frontend.mjs 同风格: 纯文本结构断言, 无外部依赖 (第 6 节除外:
// 直接 spawn 本仓库 Node 脚本, 不引入测试框架)。

import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..");
const read = (relative) => readFileSync(join(repoRoot, relative), "utf8");

const workflow = read(".github/workflows/ci.yml");
const uploadScript = read("scripts/upload-win-release.ps1");
const localBuildScript = read("scripts/build-win-app.ps1");
let generatorScript = "";
try {
  generatorScript = read("scripts/generate-update-manifest.mjs");
} catch {
  // 由第 5 节断言报缺
}

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

// 5. (T09) 更新链资产齐全: 签名门禁 → 清单生成 → 双端资产上传, 任一环节被裁撤都会让
//    已装客户端永远收不到更新 (检查失败是静默的), 必须结构性锁死。
if (!generatorScript) {
  fail("缺少 scripts/generate-update-manifest.mjs (latest.json 生成器)");
} else {
  ok("latest.json 生成器存在");
}
if (!/TAURI_SIGNING_PRIVATE_KEY: \$\{\{ secrets\.TAURI_SIGNING_PRIVATE_KEY \}\}/.test(workflow)) {
  fail("ci.yml release-windows 未从 secrets 注入 TAURI_SIGNING_PRIVATE_KEY (构建产物无更新签名)");
} else {
  ok("release-windows 注入更新签名私钥 (secret)");
}
if (!/缺少 TAURI_SIGNING_PRIVATE_KEY/.test(workflow) || !/TAURI_SIGNING_PRIVATE_KEY secret/.test(workflow)) {
  fail("ci.yml 缺少「私钥缺失即失败」门禁 (未签名产物可能被发布)");
} else {
  ok("release-windows 缺私钥时显式失败 (不发布未签名产物)");
}
if (!/generate-update-manifest\.mjs/.test(workflow)) {
  fail("ci.yml 未调用 generate-update-manifest.mjs 生成 latest.json (客户端检查更新无清单可用)");
} else {
  ok("release-windows 生成 latest.json 更新清单");
}
if (!/gh release download "\$env:GITHUB_REF_NAME" --pattern "SHA256SUMS" --pattern "release-notes-\*\.md"/.test(workflow)) {
  fail("ci.yml 清单生成步骤未从草稿回拉 macOS SHA256SUMS 与发布说明 (win runner 无 mac 产物)");
} else {
  ok("清单生成前从草稿回拉 macOS 校验和与发布说明");
}
const uploadListOk = /@\(\$setup\.Name, \$sumFile, "\$\(\$setup\.Name\)\.sig", \$latestJson\)/.test(uploadScript);
if (!uploadListOk || !/--input \$sigFile/.test(uploadScript) || !/--input \$latestJson/.test(uploadScript)) {
  fail("upload-win-release.ps1 未同时上传 .sig 与 latest.json (漏传即全员静默无更新)");
} else {
  ok("上传清单含 .sig 与 latest.json (幂等清理同覆盖)");
}
if (!/RequireUpdateSignature/.test(localBuildScript) || !/拒绝产出未签名安装包/.test(localBuildScript)) {
  fail("build-win-app.ps1 缺少 -RequireUpdateSignature 本地签名门禁 (与 CI 口径不对齐)");
} else {
  ok("本地打包脚本具备 -RequireUpdateSignature 门禁");
}

// 6. (T09) 生成器契约实测: 临时夹具跑正例 + 缺签名/哈希不符两类失败例, 全部不触网。
if (generatorScript) {
  const dir = mkdtempSync(join(tmpdir(), "bruce-update-manifest-"));
  try {
    const zipBytes = Buffer.from("fake-universal-zip-payload");
    const zipSha = createHash("sha256").update(zipBytes).digest("hex");
    writeFileSync(join(dir, "VERSION"), "0.13.0\n");
    writeFileSync(join(dir, "Bruce.zip"), zipBytes);
    writeFileSync(join(dir, "SHA256SUMS"), `${zipSha}  Bruce.zip\n`);
    const setupName = "Bruce_0.13.0_x64-setup.exe";
    writeFileSync(join(dir, setupName), Buffer.from("fake-nsis-setup"));
    const sigPayload = "dW50cnVzdGVkIHNpZ25hdHVyZQ==";
    writeFileSync(join(dir, `${setupName}.sig`), `${sigPayload}\n`);
    writeFileSync(join(dir, "notes.md"),
      "## Bruce 0.13.0 发布说明\n\n### 新功能 (Added)\n- **双端看板 Tab 切换**: 顶栏三图标导航\n  - 嵌套子要点不入摘要\n- **软件更新 (T09)**: 应用内检查更新\n");

    const runGen = (extra) => spawnSync(process.execPath, [join(repoRoot, "scripts/generate-update-manifest.mjs"),
      "--version-file", join(dir, "VERSION"),
      "--mac-sums", join(dir, "SHA256SUMS"),
      "--win-setup", join(dir, setupName),
      "--win-sig", join(dir, `${setupName}.sig`),
      "--notes", join(dir, "notes.md"),
      ...extra], { encoding: "utf8" });

    // 6a. 正例: 固定 pub_date 便于断言, 产物字段逐项核对
    const good = runGen(["--out", join(dir, "latest.json"), "--pub-date", "2026-10-24T00:00:00.000Z"]);
    if (good.status !== 0) {
      fail(`生成器正例失败: ${good.stderr.trim()}`);
    } else {
      const m = JSON.parse(readFileSync(join(dir, "latest.json"), "utf8"));
      const checks = [
        ["version", m.version === "0.13.0"],
        ["pub_date 固定", m.pub_date === "2026-10-24T00:00:00.000Z"],
        ["darwin sha256", m.platforms["darwin-universal"].sha256 === zipSha],
        ["darwin url", m.platforms["darwin-universal"].url === `https://github.com/4everSivan/Bruce/releases/download/v0.13.0/Bruce.zip`],
        ["win url", m.platforms["windows-x86_64"].url.endsWith(setupName)],
        ["win signature", m.platforms["windows-x86_64"].signature === sigPayload],
        ["notes 摘要", m.notes === "双端看板 Tab 切换: 顶栏三图标导航; 软件更新 (T09): 应用内检查更新"],
      ];
      const bad = checks.filter(([, pass]) => !pass).map(([name]) => name);
      if (bad.length) fail(`生成器产物字段不符: ${bad.join(", ")}`);
      else ok("生成器正例: 双平台字段/哈希/签名/摘要/URL 全部符合 07 §4.2 R1.1 契约");
    }

    // 6b. 失败例: 空 .sig (未签名产物) 必须非零退出
    writeFileSync(join(dir, `${setupName}.sig`), "  \n");
    const emptySig = runGen(["--out", join(dir, "latest-bad.json")]);
    if (emptySig.status === 0) {
      fail("生成器对空 .sig 仍产出清单 (未签名产物泄漏)");
    } else {
      ok("失败例: 空 .sig 拒绝产出清单");
    }

    // 6c. 失败例: 本地 zip 与 SHA256SUMS 哈希不一致 (交叉核对)
    writeFileSync(join(dir, `${setupName}.sig`), `${sigPayload}\n`);
    writeFileSync(join(dir, "SHA256SUMS"), `${"0".repeat(64)}  Bruce.zip\n`);
    const mismatch = spawnSync(process.execPath, [join(repoRoot, "scripts/generate-update-manifest.mjs"),
      "--version-file", join(dir, "VERSION"),
      "--mac-zip", join(dir, "Bruce.zip"),
      "--mac-sums", join(dir, "SHA256SUMS"),
      "--win-setup", join(dir, setupName),
      "--win-sig", join(dir, `${setupName}.sig`),
      "--notes", join(dir, "notes.md"),
      "--out", join(dir, "latest-bad2.json")], { encoding: "utf8" });
    if (mismatch.status === 0) {
      fail("生成器对 sha256 不一致仍产出清单 (交叉核对缺失)");
    } else {
      ok("失败例: zip 实算哈希与 SHA256SUMS 不一致时拒绝产出");
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

if (failed) {
  process.exit(1);
}
console.log("Windows 发布流水线契约测试通过");
