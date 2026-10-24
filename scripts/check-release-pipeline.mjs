#!/usr/bin/env node
// Windows 发布流水线契约测试 (C036 / T09)。
// 背景: release-windows 与 scripts/*.ps1 只在 tag 场景真正执行, 本机与 push 都验证不到;
// 这里把「已修复缺陷不得回归」固化为结构断言, 让每次 push 都能守住:
//   1. release 列表取数必须分页且展平 (release 数超过 30 后否则发版失败);
//   2. tauri-cli 必须两端钉同一精确版本 (不钉会在 3.x 稳定后跨大版本漂移);
//   3. 上传前必须清理同名残留资产 (重跑幂等);
//   4. 上传逻辑必须留在 scripts/upload-win-release.ps1 且受 AST 语法门禁约束;
//   5. (T09) 更新链资产齐全: 签名私钥门禁、latest.json 与发布目标同源生成、.sig/清单上传不得被裁撤;
//   6. (T09) latest.json 生成器契约: 临时夹具实测正例 (含 Windows 反斜杠路径与真实形态的发布说明)
//      与三类失败例 (tag 漂移/缺签名/哈希不符)。
// 与 scripts/check-win-frontend.mjs 同风格: 纯文本结构断言, 无外部依赖 (第 6 节除外:
// 直接 spawn 本仓库 Node 脚本, 不引入测试框架)。

import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
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
if (!/node scripts\/generate-update-manifest\.mjs/.test(uploadScript) || !/--tag \$tag/.test(uploadScript)
  || !/\$LASTEXITCODE -ne 0/.test(uploadScript)) {
  fail("upload-win-release.ps1 未生成 latest.json、未传 --tag 或未检查生成器退出码 (客户端无清单可用 / tag 漂移不设防)");
} else {
  ok("上传脚本生成 latest.json, 传入发版 tag 并检查生成器退出码");
}
// 清单输入必须取自上传脚本选定发布的同一个 $release: 按 tag 回拉 (gh release download) 在
// 残留同 tag 草稿时可能命中另一份草稿, 清单里的 mac 哈希与实际发布的包不符。只看非注释行。
const codeOnly = (source) => source.split("\n").filter((line) => !/^\s*#/.test(line)).join("\n");
if (!/\$asset = \$release\.assets \| Where-Object/.test(uploadScript) || !/Invoke-WebRequest -Uri \$asset\.url/.test(uploadScript)) {
  fail("upload-win-release.ps1 未从选定的 $release 按资产 id 下载 macOS 校验和与发布说明");
} else if (/gh release download/.test(codeOnly(workflow)) || /gh release download/.test(codeOnly(uploadScript))) {
  fail("发布链路仍按 tag 回拉草稿资产 (gh release download), 残留同 tag 草稿时清单与发布包不同源");
} else {
  ok("清单输入取自与发布目标同一个 release (按资产 id 下载)");
}
const uploadListOk = /@\(\$setup\.Name, \$sumFile, "\$\(\$setup\.Name\)\.sig", \$latestJson\)/.test(uploadScript);
if (!uploadListOk || !/--input \$sigFile/.test(uploadScript) || !/--input \$latestJson/.test(uploadScript)) {
  fail("upload-win-release.ps1 未同时上传 .sig 与 latest.json (漏传即全员静默无更新)");
} else {
  ok("上传清单含 .sig 与 latest.json (幂等清理同覆盖)");
}
if (!/RequireUpdateSignature/.test(localBuildScript) || !/拒绝产出未签名安装包/.test(localBuildScript)) {
  fail("build-win-app.ps1 缺少 -RequireUpdateSignature 本地签名门禁 (与 CI 口径不对齐)");
} else if (!/\$RequireUpdateSignature -and -not \$sigFresh/.test(localBuildScript)) {
  // 只查私钥不够: tauri 未开 createUpdaterArtifacts 时有私钥也不产 .sig
  fail("build-win-app.ps1 -RequireUpdateSignature 未在构建后核验本轮 .sig 产出 (未签名包会被静默收拢)");
} else {
  ok("本地打包脚本具备 -RequireUpdateSignature 门禁 (构建前查私钥 + 构建后核验本轮 .sig)");
}

// 6. (T09) 生成器契约实测: 临时夹具跑正例 + tag 漂移/缺签名/哈希不符三类失败例, 全部不触网。
//    失败例同时核对 stderr 关键字, 确认是因预期原因被拒而非夹具自身出错。
if (generatorScript) {
  const dir = mkdtempSync(join(tmpdir(), "bruce-update-manifest-"));
  try {
    const zipBytes = Buffer.from("fake-universal-zip-payload");
    const zipSha = createHash("sha256").update(zipBytes).digest("hex");
    writeFileSync(join(dir, "VERSION"), "0.13.0\n");
    writeFileSync(join(dir, "Bruce.zip"), zipBytes);
    writeFileSync(join(dir, "SHA256SUMS"), `${zipSha}  Bruce.zip\n`);
    // release-windows 传入的是 Windows 反斜杠路径: 末段用反斜杠拼接 —— Windows 上是真实子目录,
    // POSIX 上是含反斜杠的文件名, 两端都能复现「URL 带上整条路径」的取名缺陷。
    const setupName = "Bruce_0.13.0_x64-setup.exe";
    const nsisDir = join(dir, "nsis");
    if (process.platform === "win32") mkdirSync(nsisDir);
    const setupPath = `${nsisDir}\\${setupName}`;
    writeFileSync(setupPath, Buffer.from("fake-nsis-setup"));
    const sigPayload = "dW50cnVzdGVkIHNpZ25hdHVyZQ==";
    writeFileSync(`${setupPath}.sig`, `${sigPayload}\n`);
    // 发布说明按 CHANGELOG 真实形态: `- **标题 (卡号)**：面向开发者的说明`, 部分条目正文全在
    // 嵌套子要点里; 新功能 6 条 + 调整 1 条 + 修复 3 条, 覆盖卡号剥离与按小节轮转分配名额。
    writeFileSync(join(dir, "notes.md"), [
      "## Bruce 0.13.0 发布说明",
      "",
      "### 新功能 (Added)",
      "- **软件更新 (T09)**：应用内检查更新, 清单含 `platforms.windows-x86_64`",
      "- **双端看板 Tab 切换 (C066)**：",
      "  - 嵌套子要点不入摘要",
      "- **锁屏暂停订阅刷新 (C091–C093)**：持久化至 `OnboardingConfiguration.pauseSubscriptionRefreshOnScreenLock`",
      "- **品牌图形徽章**：无卡号条目保留标题",
      "- **第五条新功能 (C094)**：超出名额",
      "- **第六条新功能 (C095)**：超出名额",
      "### 调整与优化 (Changed)",
      "- **看板顶部零输出 (C080)**：移除 `#dashboard-status`",
      "### 修复 (Fixed)",
      "- **诊断码不再直出 (C078)**：`SNAPSHOT_RESTORED` 映射为中文",
      "- **订阅额度按 provider 独立门控 (C077)**：补齐 429 冷却",
      "- **断网闸门 (C076)**：断网时不再退避重试",
      "",
    ].join("\n"));

    const runGen = (extra) => spawnSync(process.execPath, [join(repoRoot, "scripts/generate-update-manifest.mjs"),
      "--version-file", join(dir, "VERSION"),
      "--mac-sums", join(dir, "SHA256SUMS"),
      "--win-setup", setupPath,
      "--win-sig", `${setupPath}.sig`,
      "--notes", join(dir, "notes.md"),
      ...extra], { encoding: "utf8" });
    const expectRejected = (result, keyword, failMessage, okMessage) => {
      if (result.status === 0) fail(failMessage);
      else if (!result.stderr.includes(keyword)) fail(`${failMessage} —— 非零退出但原因不符: ${result.stderr.trim()}`);
      else ok(okMessage);
    };

    // 6a. 正例: 固定 pub_date 便于断言, 产物字段逐项精确核对
    const good = runGen(["--tag", "v0.13.0", "--out", join(dir, "latest.json"), "--pub-date", "2026-10-24T00:00:00.000Z"]);
    if (good.status !== 0) {
      fail(`生成器正例失败: ${good.stderr.trim()}`);
    } else {
      const m = JSON.parse(readFileSync(join(dir, "latest.json"), "utf8"));
      const checks = [
        ["version", m.version === "0.13.0"],
        ["pub_date 固定", m.pub_date === "2026-10-24T00:00:00.000Z"],
        ["darwin sha256", m.platforms["darwin-universal"].sha256 === zipSha],
        ["darwin url", m.platforms["darwin-universal"].url === `https://github.com/4everSivan/Bruce/releases/download/v0.13.0/Bruce.zip`],
        ["win url", m.platforms["windows-x86_64"].url === `https://github.com/4everSivan/Bruce/releases/download/v0.13.0/${setupName}`],
        ["win signature", m.platforms["windows-x86_64"].signature === sigPayload],
        ["notes 摘要", m.notes === "软件更新; 双端看板 Tab 切换; 锁屏暂停订阅刷新; 品牌图形徽章; 看板顶部零输出; 诊断码不再直出; 订阅额度按 provider 独立门控; 断网闸门"],
      ];
      const bad = checks.filter(([, pass]) => !pass).map(([name]) => name);
      if (bad.length) fail(`生成器产物字段不符: ${bad.join(", ")}`);
      else ok("生成器正例: 双平台字段/哈希/签名/URL (含 Windows 反斜杠路径) 与发布说明摘要全部符合 07 §4.2 R1.1 契约");
    }

    // 6b. 失败例: 发版 tag 与 VERSION 不一致 (清单会指向另一个 Release)
    expectRejected(runGen(["--tag", "v0.13.1", "--out", join(dir, "latest-bad-tag.json")]), "发版 tag",
      "生成器对 tag 与 VERSION 不一致仍产出清单 (清单指向错误 Release)",
      "失败例: 发版 tag 与 VERSION 不一致时拒绝产出");

    // 6c. 失败例: 空 .sig (未签名产物) 必须非零退出
    writeFileSync(`${setupPath}.sig`, "  \n");
    expectRejected(runGen(["--out", join(dir, "latest-bad-sig.json")]), ".sig 文件为空",
      "生成器对空 .sig 仍产出清单 (未签名产物泄漏)",
      "失败例: 空 .sig 拒绝产出清单");
    writeFileSync(`${setupPath}.sig`, `${sigPayload}\n`);

    // 6d. 失败例: 本地 zip 与 SHA256SUMS 哈希不一致 (交叉核对)
    writeFileSync(join(dir, "SHA256SUMS"), `${"0".repeat(64)}  Bruce.zip\n`);
    expectRejected(runGen(["--mac-zip", join(dir, "Bruce.zip"), "--out", join(dir, "latest-bad-sha.json")]), "实算 sha256",
      "生成器对 sha256 不一致仍产出清单 (交叉核对缺失)",
      "失败例: zip 实算哈希与 SHA256SUMS 不一致时拒绝产出");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

if (failed) {
  process.exit(1);
}
console.log("Windows 发布流水线契约测试通过");
