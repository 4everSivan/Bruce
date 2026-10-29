#!/usr/bin/env node
// Windows 发布流水线契约测试 (C036 / T09)。
// 背景: release-windows 与 scripts/*.ps1 只在 tag 场景真正执行, 本机与 push 都验证不到;
// 这里把「已修复缺陷不得回归」固化为结构断言, 让每次 push 都能守住:
//   1. release 列表取数必须分页且展平 (release 数超过 30 后否则发版失败);
//   2. tauri-cli 必须两端钉同一精确版本 (不钉会在 3.x 稳定后跨大版本漂移);
//   3. 上传前必须清理同名残留资产 (重跑幂等);
//   4. 上传逻辑必须留在 scripts/upload-win-release.ps1 且受 AST 语法门禁约束;
//   5. (T09) 更新链资产齐全: updater 签名配置、签名私钥门禁、latest.json 与发布目标同源生成、
//      双平台 .sig/清单上传不得被裁撤; 签名私钥不得进入受跟踪文件;
//   6. (T09) latest.json 生成器契约: 临时夹具实测正例 (含 Windows 反斜杠路径、真实形态的发布说明、
//      Tauri 插件解析要求) 与四类失败例 (tag 漂移/Windows 缺签名/macOS 缺签名/哈希不符)。
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
const buildTestAppScript = read("scripts/build-test-app.sh");
const tauriConf = JSON.parse(read("apps/win/src-tauri/tauri.conf.json"));
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
const localPinned = [...localBuildScript.matchAll(/Invoke-CargoChecked\s+-CargoArguments\s+@\("install",\s*"tauri-cli",\s*"--version",\s*"=([\d.]+)"/g)].map((m) => m[1]);
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
if (!/function Invoke-CargoChecked[\s\S]*?& cargo @CargoArguments[\s\S]*?\$exitCode = \$LASTEXITCODE[\s\S]*?if \(\$exitCode -ne 0\)/.test(localBuildScript)) {
  fail("build-win-app.ps1 未在 cargo 调用后立即检查原生退出码");
} else if (localBuildScript.split("\n").some((line) => /^\s*cargo\s+/.test(line) && !/^\s*#/.test(line))) {
  fail("build-win-app.ps1 存在绕过 Invoke-CargoChecked 的 cargo 调用");
} else {
  ok("本地 Windows 打包的 cargo 命令统一经退出码检查");
}
if (!/Invoke-CargoChecked\s+-CargoArguments\s+@\("tauri",\s*"build",\s*"--target",\s*\$cargoBuildInfo\.TargetTriple,\s*"--bundles",\s*"nsis"\)/.test(localBuildScript)
  || !/Invoke-CargoChecked\s+-CargoArguments\s+@\("build",\s*"--target",\s*\$cargoBuildInfo\.TargetTriple,\s*"--release"\)/.test(localBuildScript)) {
  fail("build-win-app.ps1 未通过受检 helper 执行 NSIS 与裸程序构建");
}
if (!/rustc -vV/.test(localBuildScript) || !/CARGO_BUILD_TARGET/.test(localBuildScript)
  || !/HostTriple = \$hostTarget/.test(localBuildScript) || !/TargetTriple = \$target/.test(localBuildScript)) {
  fail("build-win-app.ps1 未基于 Rust host / 显式 Cargo target 判定安装包架构");
} else {
  ok("本地打包目标架构读取 Rust host 与显式 Cargo target, 并将目标传给 Cargo");
}
if (!/build-win\\cargo-target/.test(localBuildScript)
  || !/CARGO_TARGET_DIR 必须位于仓库 local/.test(localBuildScript)
  || !/"--target", \$cargoBuildInfo\.TargetTriple/.test(localBuildScript)
  || !/"--target", \$cargoBuildInfo\.HostTriple/.test(localBuildScript)) {
  fail("build-win-app.ps1 构建输出未限制在 local/ 或未显式固定 Cargo target");
} else {
  ok("Cargo target 输出位于 local/ 且每次构建显式固定目标三元组");
}
if (!/\$expectedSetupName = "\{0\}_\{1\}_\{2\}-setup\.exe" -f \$tauriConfig\.productName, \$tauriConfig\.version, \$cargoBuildInfo\.Architecture/.test(localBuildScript)
  || !/Test-Path -LiteralPath \$setupPath -PathType Leaf/.test(localBuildScript)
  || !/Test-Path -LiteralPath \$exePath -PathType Leaf/.test(localBuildScript)
  || /Sort-Object LastWriteTime -Descending/.test(localBuildScript)) {
  fail("build-win-app.ps1 未按配置版本/目标架构检查精确产物, 或仍按修改时间选择旧安装包");
} else {
  ok("本地打包只收拢配置版本/目标架构的现存产物");
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
// Tauri v2 只在 bundle.createUpdaterArtifacts 开启且配置 plugins.updater.pubkey 时产 .sig,
// 否则注入的私钥被静默忽略, 发版到清单生成一步才失败。
const pubkey = tauriConf.plugins?.updater?.pubkey ?? "";
if (tauriConf.bundle?.createUpdaterArtifacts !== true) {
  fail("tauri.conf.json 未开启 bundle.createUpdaterArtifacts (构建不产 .sig, 私钥被忽略)");
} else if (!Buffer.from(pubkey, "base64").toString("utf8").startsWith("untrusted comment: minisign public key")) {
  fail("tauri.conf.json plugins.updater.pubkey 缺失或不是 tauri signer generate 产出的 minisign 公钥");
} else {
  ok("tauri.conf.json 开启 updater 产物并配置 minisign 公钥");
}
// 构建 (产 <setup>.sig) 与上传 (签 Bruce.zip) 两步都要私钥
const keyInjections = workflow.match(/TAURI_SIGNING_PRIVATE_KEY: \$\{\{ secrets\.TAURI_SIGNING_PRIVATE_KEY \}\}/g) ?? [];
if (keyInjections.length < 2) {
  fail(`ci.yml release-windows 签名私钥注入 ${keyInjections.length} 处, 构建与上传步骤各需 1 处 (缺则无更新签名)`);
} else {
  ok("release-windows 构建与上传步骤均从 secrets 注入更新签名私钥");
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
if (!/foreach \(\$name in @\(\$macZip, "SHA256SUMS", \$notesFile\)\)/.test(uploadScript)
  || !/\$asset = \$release\.assets \| Where-Object/.test(uploadScript) || !/Invoke-WebRequest -Uri \$asset\.url/.test(uploadScript)) {
  fail("upload-win-release.ps1 未从选定的 $release 按资产 id 下载 Bruce.zip / SHA256SUMS / 发布说明");
} else if (/gh release download/.test(codeOnly(workflow)) || /gh release download/.test(codeOnly(uploadScript))) {
  fail("发布链路仍按 tag 回拉草稿资产 (gh release download), 残留同 tag 草稿时清单与发布包不同源");
} else {
  ok("清单输入取自与发布目标同一个 release (按资产 id 下载)");
}
// darwin 条目同样必须带签名 (tauri-plugin-updater 要求每个 platforms 条目都有 signature);
// 下载的 zip 须与 SHA256SUMS 交叉核对。
if (!/cargo tauri signer sign \$macZip/.test(uploadScript) || !/--mac-sig \$macSig/.test(uploadScript)
  || !/--mac-zip \$macZip/.test(uploadScript)) {
  fail("upload-win-release.ps1 未对 Bruce.zip 签名、未传 --mac-sig 或未以 --mac-zip 交叉核对哈希");
} else {
  ok("上传脚本签名 Bruce.zip 并以实算哈希交叉核对 SHA256SUMS");
}
const uploadListOk = /@\(\$setup\.Name, \$sumFile, "\$\(\$setup\.Name\)\.sig", \$macSig, \$latestJson\)/.test(uploadScript);
if (!uploadListOk || !/--input \$sigFile/.test(uploadScript) || !/--input \$macSig/.test(uploadScript)
  || !/--input \$latestJson/.test(uploadScript)) {
  fail("upload-win-release.ps1 未同时上传双平台 .sig 与 latest.json (漏传即全员静默无更新)");
} else {
  ok("上传清单含双平台 .sig 与 latest.json (幂等清理同覆盖)");
}
if (!/RequireUpdateSignature/.test(localBuildScript) || !/拒绝产出未签名安装包/.test(localBuildScript)) {
  fail("build-win-app.ps1 缺少 -RequireUpdateSignature 本地签名门禁 (与 CI 口径不对齐)");
} else if (!/\$RequireUpdateSignature -and -not \$sigTimestampOk/.test(localBuildScript)
  || !/\$sigTimestampOk = \$signingEnabled -and/.test(localBuildScript)) {
  // 只查私钥不够: tauri 未开 createUpdaterArtifacts 时有私钥也不产 .sig
  fail("build-win-app.ps1 -RequireUpdateSignature 未检查签名文件与目标安装包的时间关系 (未签名包会被静默收拢)");
} else {
  ok("本地打包脚本具备 -RequireUpdateSignature 门禁 (构建前查私钥 + 构建后检查签名文件存在及时间关系)");
}
if (!/if \(-not \$signingEnabled -and \(Test-Path -LiteralPath \$distSignature\)\)/.test(localBuildScript)
  || !/--no-sign 构建拒绝与 local\\dist 中的旧签名并存/.test(localBuildScript)) {
  fail("build-win-app.ps1 无私钥构建未阻止 local/dist 中的同名旧签名残留");
} else {
  ok("--no-sign 构建遇 local/dist 旧签名时先失败并保留现有产物");
}
// 开启 createUpdaterArtifacts 后无私钥的 tauri build 直接报错, 日常本地打包必须降级 --no-sign
if (!/Invoke-CargoChecked\s+-CargoArguments\s+@\("tauri",\s*"build",\s*"--target",\s*\$cargoBuildInfo\.TargetTriple,\s*"--bundles",\s*"nsis",\s*"--no-sign"\)/.test(localBuildScript)) {
  fail("build-win-app.ps1 无私钥时未以 --no-sign 构建 (createUpdaterArtifacts 开启后日常本地打包会失败)");
} else {
  ok("本地打包脚本无私钥时以 --no-sign 降级构建");
}
if (!/scripts\/tests\/test-build-win-app\.ps1/.test(workflow)) {
  fail("verify-windows 未执行 scripts/tests/test-build-win-app.ps1 行为回归");
} else {
  ok("verify-windows 已接入 Windows 打包失败路径行为测试");
}
// 私钥绝不入仓库: 扫描受跟踪文件中的 minisign 私钥特征 (原文注释头, 或 Tauri 私钥整体 base64 后的
// 固定开头; 注释头长度为 3 的倍数, base64 开头与后续内容无关)。本文件自身含特征文本, 跳过。
const secretKeyHeaders = ["rsign", "minisign"].map((tool) => `untrusted comment: ${tool} encrypted secret key`);
const secretKeyMarkers = [...secretKeyHeaders, ...secretKeyHeaders.map((h) => Buffer.from(h).toString("base64"))];
const tracked = spawnSync("git", ["ls-files", "-z"], { cwd: repoRoot, encoding: "utf8" });
if (tracked.status !== 0) {
  fail(`无法列出受跟踪文件以扫描签名私钥: ${tracked.stderr.trim()}`);
} else {
  const leaks = tracked.stdout.split("\0").filter((path) => path && path !== "scripts/check-release-pipeline.mjs")
    .filter((path) => {
      try {
        const content = readFileSync(join(repoRoot, path));
        return secretKeyMarkers.some((marker) => content.includes(marker));
      } catch {
        return false; // 已删除未提交等不可读条目
      }
    });
  if (leaks.length) fail(`受跟踪文件疑似含 minisign 签名私钥: ${leaks.join(", ")}`);
  else ok("受跟踪文件不含 minisign 签名私钥特征");
}

// 6. (T09) 生成器契约实测: 临时夹具按 CI 调用形态跑正例 + 四类失败例, 全部不触网。
//    失败例同时核对 stderr 关键字, 确认是因预期原因被拒而非夹具自身出错。
if (generatorScript) {
  const dir = mkdtempSync(join(tmpdir(), "bruce-update-manifest-"));
  try {
    const zipBytes = Buffer.from("fake-universal-zip-payload");
    const zipSha = createHash("sha256").update(zipBytes).digest("hex");
    writeFileSync(join(dir, "VERSION"), "0.13.0\n");
    writeFileSync(join(dir, "Bruce.zip"), zipBytes);
    writeFileSync(join(dir, "SHA256SUMS"), `${zipSha}  Bruce.zip\n`);
    const macSigPayload = "dW50cnVzdGVkIG1hYyBzaWduYXR1cmU=";
    writeFileSync(join(dir, "Bruce.zip.sig"), `${macSigPayload}\n`);
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
      "--mac-zip", join(dir, "Bruce.zip"),
      "--mac-sums", join(dir, "SHA256SUMS"),
      "--mac-sig", join(dir, "Bruce.zip.sig"),
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
      // tauri-plugin-updater 反序列化整张 platforms 表: 每个条目都必须有非空 url 与 signature
      const tauriParsable = Object.values(m.platforms).every((entry) =>
        typeof entry.url === "string" && entry.url !== "" && typeof entry.signature === "string" && entry.signature !== "");
      const checks = [
        ["version", m.version === "0.13.0"],
        ["pub_date 固定", m.pub_date === "2026-10-24T00:00:00.000Z"],
        ["Tauri 插件可解析 (每个 platforms 条目都有 url + signature)", tauriParsable],
        ["darwin sha256", m.platforms["darwin-universal"].sha256 === zipSha],
        ["darwin signature", m.platforms["darwin-universal"].signature === macSigPayload],
        ["darwin url", m.platforms["darwin-universal"].url === `https://github.com/4everSivan/Bruce/releases/download/v0.13.0/Bruce.zip`],
        ["win url", m.platforms["windows-x86_64"].url === `https://github.com/4everSivan/Bruce/releases/download/v0.13.0/${setupName}`],
        ["win signature", m.platforms["windows-x86_64"].signature === sigPayload],
        ["notes 摘要", m.notes === "软件更新; 双端看板 Tab 切换; 锁屏暂停订阅刷新; 品牌图形徽章; 看板顶部零输出; 诊断码不再直出; 订阅额度按 provider 独立门控; 断网闸门"],
      ];
      const bad = checks.filter(([, pass]) => !pass).map(([name]) => name);
      if (bad.length) fail(`生成器产物字段不符: ${bad.join(", ")}`);
      else ok("生成器正例: Tauri 可解析, 双平台字段/哈希/签名/URL (含 Windows 反斜杠路径) 与发布说明摘要全部符合 07 §4.2 R1.1 契约");
    }

    // 6b. 失败例: 发版 tag 与 VERSION 不一致 (清单会指向另一个 Release)
    expectRejected(runGen(["--tag", "v0.13.1", "--out", join(dir, "latest-bad-tag.json")]), "发版 tag",
      "生成器对 tag 与 VERSION 不一致仍产出清单 (清单指向错误 Release)",
      "失败例: 发版 tag 与 VERSION 不一致时拒绝产出");

    // 6c. 失败例: Windows 空 .sig (未签名产物) 必须非零退出
    writeFileSync(`${setupPath}.sig`, "  \n");
    expectRejected(runGen(["--out", join(dir, "latest-bad-sig.json")]), `${setupName}.sig`,
      "生成器对 Windows 空 .sig 仍产出清单 (未签名产物泄漏)",
      "失败例: Windows 空 .sig 拒绝产出清单");
    writeFileSync(`${setupPath}.sig`, `${sigPayload}\n`);

    // 6d. 失败例: macOS 空 .sig (darwin 条目缺签名会让 Windows 客户端整份清单解析失败)
    writeFileSync(join(dir, "Bruce.zip.sig"), "\n");
    expectRejected(runGen(["--out", join(dir, "latest-bad-macsig.json")]), "Bruce.zip.sig",
      "生成器对 macOS 空 .sig 仍产出清单 (Tauri 插件无法解析)",
      "失败例: macOS 空 .sig 拒绝产出清单");
    writeFileSync(join(dir, "Bruce.zip.sig"), `${macSigPayload}\n`);

    // 6e. 失败例: 下载的 zip 与 SHA256SUMS 哈希不一致 (交叉核对)
    writeFileSync(join(dir, "SHA256SUMS"), `${"0".repeat(64)}  Bruce.zip\n`);
    expectRejected(runGen(["--out", join(dir, "latest-bad-sha.json")]), "实算 sha256",
      "生成器对 sha256 不一致仍产出清单 (交叉核对缺失)",
      "失败例: zip 实算哈希与 SHA256SUMS 不一致时拒绝产出");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

// 7. (C114) macOS DMG 磁盘镜像发布契约: 用户初装直观体验 + Release 资产齐备
let packageDmgScript = "";
try {
  packageDmgScript = read("scripts/package-dmg.sh");
} catch {}

if (!packageDmgScript) {
  fail("缺少 scripts/package-dmg.sh (macOS DMG 打包脚本)");
} else {
  ok("scripts/package-dmg.sh 存在");
}
if (!/--dmg/.test(buildTestAppScript)) {
  fail("scripts/build-test-app.sh 未支持 --dmg 参数");
} else {
  ok("build-test-app.sh 支持 --dmg 选项");
}
if (!/build-test-app\.sh --universal --dmg/.test(workflow)) {
  fail("ci.yml 未在 build-release-app / release 传入 --dmg 参数构建");
} else {
  ok("ci.yml 流水线已接入 Universal 2 与 DMG 联动构建");
}
if (!/gh release create [^]*dist\/Bruce-\*\.dmg/.test(workflow)) {
  fail("ci.yml release 作业未上传 dist/Bruce-*.dmg 资产");
} else {
  ok("ci.yml release 作业已将 dist/Bruce-*.dmg 纳入 Release 上传清单");
}
if (!/shasum -a 256 Bruce\.zip Bruce-\*\.dmg > SHA256SUMS/.test(workflow)) {
  fail("ci.yml 未将 Bruce-*.dmg 写入 SHA256SUMS");
} else {
  ok("ci.yml 已将 Bruce.zip 与 Bruce-*.dmg 统一写入 SHA256SUMS 校验和");
}

if (failed) {
  process.exit(1);
}
console.log("发布流水线契约测试通过 (Windows & macOS DMG)");
