#!/usr/bin/env node
// CI 工具依赖契约检查 (C170)。
// 背景: 2026-10-31 verify 作业在 macOS runner 上因缺少 ripgrep 失败, 而
// check-bundle-resources.zsh 的 `if ! rg -q` 把「命令不存在」误判成「脚本未调用」,
// 报错信息与事实相反; check-collector-fixtures.sh 的 `if rg` 则静默跳过凭证扫描。
// 三条结构断言 (每次 push 与本地 verify-local 同跑):
//   1. ci.yml 中运行 verify-local / 打包脚本的作业必须显式安装 ripgrep;
//   2. 依赖 rg 的门禁脚本必须先做 `command -v rg` 预检;
//   3. 在抹掉 rg 的 PATH 下实跑, 必须 exit 1 且提示「缺少 ripgrep」, 不得出现误导文本。
// 与 scripts/check-release-pipeline.mjs 同风格: 纯文本结构断言, 无外部依赖。

import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..");
const read = (relative) => readFileSync(join(repoRoot, relative), "utf8");

let failed = false;
const fail = (message) => {
  console.error(`FAIL: ${message}`);
  failed = true;
};
const ok = (message) => console.log(`ok: ${message}`);

// 1. ci.yml: 按 2 空格缩进的作业名切块, 运行门禁脚本的作业必须带 ripgrep 安装步骤。
const workflow = read(".github/workflows/ci.yml");
const jobs = new Map();
let currentJob = null;
for (const line of workflow.split("\n")) {
  const jobMatch = /^ {2}([A-Za-z0-9_-]+):\s*$/.exec(line);
  if (jobMatch) {
    currentJob = jobMatch[1];
    jobs.set(currentJob, []);
    continue;
  }
  if (currentJob) jobs.get(currentJob).push(line);
}

const gateScriptPattern = /zsh scripts\/(?:verify-local|build-test-app|build-release-app)\.sh/;
const gateJobs = [...jobs].filter(([, lines]) => gateScriptPattern.test(lines.join("\n")));
if (gateJobs.length === 0) {
  fail("ci.yml 未找到运行 verify-local / 打包脚本的作业");
}
for (const [name, lines] of gateJobs) {
  if (/brew install ripgrep/.test(lines.join("\n"))) {
    ok(`ci.yml ${name} 作业安装 ripgrep`);
  } else {
    fail(`ci.yml ${name} 作业运行门禁脚本但未安装 ripgrep (macOS runner 不预装 rg)`);
  }
}

// 2. 依赖 rg 的脚本必须先预检, 命令缺失不得被当成规则不满足。
const rgScripts = ["scripts/check-bundle-resources.zsh", "scripts/check-collector-fixtures.sh"];
for (const relative of rgScripts) {
  if (/command -v rg\b/.test(read(relative))) {
    ok(`${relative} 已做 rg 预检`);
  } else {
    fail(`${relative} 未在依赖 rg 前执行 command -v rg 预检`);
  }
}

// 3. 缺 rg 的实际失败语义 (仅 macOS 可执行: 依赖 zsh 与 /bin 工具链)。
if (process.platform === "darwin") {
  const restrictedEnv = {
    PATH: "/usr/bin:/bin:/usr/sbin:/sbin",
    HOME: process.env.HOME ?? "/tmp",
    TMPDIR: process.env.TMPDIR ?? "/tmp",
  };
  const runWithoutRg = (relative) =>
    spawnSync("/bin/zsh", [join(repoRoot, relative)], {
      cwd: repoRoot,
      env: restrictedEnv,
      encoding: "utf8",
    });

  for (const relative of rgScripts) {
    const result = runWithoutRg(relative);
    const output = `${result.stdout ?? ""}${result.stderr ?? ""}`.trim();
    if (result.status !== 1) {
      fail(`${relative} 缺少 rg 时未以退出码 1 失败 (status=${result.status})`);
    } else if (!output.includes("缺少 ripgrep")) {
      fail(`${relative} 缺少 rg 时未提示「缺少 ripgrep」: ${output}`);
    } else {
      ok(`${relative} 缺少 rg 时明确失败`);
    }
  }

  const bundleOutput = runWithoutRg("scripts/check-bundle-resources.zsh").stderr ?? "";
  if (bundleOutput.includes("未调用 Bruce_copy_bundle_resources")) {
    fail("check-bundle-resources.zsh 在缺少 rg 时仍输出误导性「未调用」断言 (命令缺失 ≠ 规则不满足)");
  }
} else {
  ok("跳过受限 PATH 实跑 (仅在 macOS 门禁执行)");
}

if (failed) {
  console.error("CI 工具依赖契约检查失败");
  process.exit(1);
}
console.log("CI 工具依赖契约检查通过 (ripgrep 安装、脚本预检与失败语义一致)");
