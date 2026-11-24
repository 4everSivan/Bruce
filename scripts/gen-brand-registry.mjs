#!/usr/bin/env node
// 生成跨端品牌注册表产物 (C263)。
//
// 输入: config/brand-registry.json（Nothing 色阶 + 已知 Agent 固定档位）
// 输出:
//   - apps/win/src/brand-registry.generated.js（window.BRUCE_BRAND_REGISTRY）
//   - apps/win/viewmodel/src/brand_registry.rs（Rust 常量与档位查询）
//   - apps/macos/Sources/BruceAppCore/BrandRegistryGenerated.swift（Swift 常量）
//
// 三端产物由同一份 JSON 生成，修正此前 Windows 绿阶 vs macOS 杏色阶、以及
// app.js UTF-16 32-bit FNV-1a 与 Swift/Rust UTF-8 64-bit 的漂移。
//
// 用法:
//   node scripts/gen-brand-registry.mjs            # 生成/刷新产物
//   node scripts/gen-brand-registry.mjs --check    # 校验产物与 JSON 一致 (verify-local / CI)

import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..");
const sourcePath = join(repoRoot, "config/brand-registry.json");
const jsOut = join(repoRoot, "apps/win/src/brand-registry.generated.js");
const rustOut = join(repoRoot, "apps/win/viewmodel/src/brand_registry.rs");
const swiftOut = join(repoRoot, "apps/macos/Sources/BruceAppCore/BrandRegistryGenerated.swift");

const REGISTRY = JSON.parse(readFileSync(sourcePath, "utf8"));

function fail(message) {
  console.error(`品牌注册表无效: ${message}`);
  process.exit(1);
}

function validate() {
  if (REGISTRY.schemaVersion !== 1) fail(`schemaVersion 必须为 1，实际 ${REGISTRY.schemaVersion}`);
  for (const mode of ["dark", "light"]) {
    const ramp = REGISTRY.nothingRamp?.[mode];
    if (!Array.isArray(ramp) || ramp.length !== 5) fail(`nothingRamp.${mode} 必须恰好 5 档`);
    for (const color of ramp) {
      if (!/^#[0-9A-Fa-f]{6}$/.test(color)) fail(`nothingRamp.${mode} 含非法色值 ${color}`);
    }
  }
  const tiers = REGISTRY.agentTiers || {};
  for (const [agent, tier] of Object.entries(tiers)) {
    if (!agent.trim()) fail("agentTiers 含空 agent id");
    if (!Number.isInteger(tier) || tier < 0 || tier >= 5) {
      fail(`agentTiers.${agent} 必须为 0..4 的整数`);
    }
  }
}

function sortedTiers() {
  return Object.entries(REGISTRY.agentTiers || {}).sort(([left], [right]) =>
    left.localeCompare(right, "en")
  );
}

function jsList(values) {
  return `[${values.map((value) => JSON.stringify(value)).join(", ")}]`;
}

function generateJs() {
  const tiers = sortedTiers()
    .map(([agent, tier]) => `      ${JSON.stringify(agent)}: ${tier},`)
    .join("\n");
  return `// 本文件由 scripts/gen-brand-registry.mjs 生成, 请勿手改 (C263)。
// 修改 config/brand-registry.json 后运行 node scripts/gen-brand-registry.mjs;
// verify-local 以 --check 拦截漂移。
(function () {
  const data = {
    schemaVersion: ${REGISTRY.schemaVersion},
    updatedAt: ${JSON.stringify(REGISTRY.updatedAt)},
    nothingRamp: {
      dark: ${jsList(REGISTRY.nothingRamp.dark)},
      light: ${jsList(REGISTRY.nothingRamp.light)},
    },
    agentTiers: {
${tiers}
    },
  };
  // UTF-8 字节序列: 与 Rust as_bytes()/Swift utf8 逐字节一致。
  data.utf8Bytes = function utf8Bytes(text) {
    const bytes = [];
    for (const char of String(text)) {
      const code = char.codePointAt(0);
      if (code < 0x80) {
        bytes.push(code);
      } else if (code < 0x800) {
        bytes.push(0xc0 | (code >> 6), 0x80 | (code & 0x3f));
      } else if (code < 0x10000) {
        bytes.push(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f));
      } else {
        bytes.push(
          0xf0 | (code >> 18),
          0x80 | ((code >> 12) & 0x3f),
          0x80 | ((code >> 6) & 0x3f),
          0x80 | (code & 0x3f)
        );
      }
    }
    return bytes;
  };
  // FNV-1a 64 (offset 0xcbf29ce484222325, prime 0x100000001b3): 与 Rust/Swift 端同法。
  // BigInt 保证 64 位不回绕到 32 位 (C263 修正旧 UTF-16 32-bit 实现)。
  data.fnv1a64 = function fnv1a64(text) {
    let hash = 0xcbf29ce484222325n;
    for (const byte of data.utf8Bytes(text)) {
      hash ^= BigInt(byte);
      hash = (hash * 0x100000001b3n) & 0xffffffffffffffffn;
    }
    return hash;
  };
  window.BRUCE_BRAND_REGISTRY = data;
})();
`;
}

function generateRust() {
  const tiers = sortedTiers()
    .map(([agent, tier]) => `        ${JSON.stringify(agent)} => Some(${tier}),`)
    .join("\n");
  return `//! 本文件由 scripts/gen-brand-registry.mjs 生成, 请勿手改 (C263)。
//!
//! 唯一事实源: \`config/brand-registry.json\`。修改后运行
//! \`node scripts/gen-brand-registry.mjs\`; verify-local 以 \`--check\` 拦截漂移。

/// 注册表版本 (与 JSON \`schemaVersion\` 一致)。
pub const SCHEMA_VERSION: u32 = ${REGISTRY.schemaVersion};

/// Nothing 深色档 (亮→暗)。
pub const NOTHING_RAMP_DARK: [&str; 5] = [${REGISTRY.nothingRamp.dark.map((color) => `"${color}"`).join(", ")}];

/// Nothing 浅色档 (杏色, 深→浅)。
pub const NOTHING_RAMP_LIGHT: [&str; 5] = [${REGISTRY.nothingRamp.light.map((color) => `"${color}"`).join(", ")}];

/// 已知 agent 的固定档位; 未知 agent 由调用方用 FNV-1a 散列落档。
pub fn nothing_agent_tier(agent_id: &str) -> Option<usize> {
    match agent_id {
${tiers}
        _ => None,
    }
}
`;
}

function generateSwift() {
  const tiers = sortedTiers()
    .map(([agent, tier]) => `        "${agent}": ${tier},`)
    .join("\n");
  return `// 本文件由 scripts/gen-brand-registry.mjs 生成, 请勿手改 (C263)。
// 修改 config/brand-registry.json 后运行 node scripts/gen-brand-registry.mjs;
// verify-local 以 --check 拦截漂移。
package enum BrandRegistryGenerated {
    /// 注册表版本 (与 JSON schemaVersion 一致)。
    package static let schemaVersion = ${REGISTRY.schemaVersion}

    /// Nothing 深色档 (亮→暗)。
    package static let nothingRampDark: [String] = [
${REGISTRY.nothingRamp.dark.map((color) => `        "${color}",`).join("\n")}
    ]

    /// Nothing 浅色档 (杏色, 深→浅)。
    package static let nothingRampLight: [String] = [
${REGISTRY.nothingRamp.light.map((color) => `        "${color}",`).join("\n")}
    ]

    /// 已知 agent 的固定档位; 未知 agent 由调用方用 FNV-1a 散列落档。
    package static let nothingAgentTiers: [String: Int] = [
${tiers}
    ]
}
`;
}

function readIfExists(path) {
  try {
    return readFileSync(path, "utf8");
  } catch {
    return null;
  }
}

validate();
const outputs = [
  [jsOut, generateJs()],
  [rustOut, generateRust()],
  [swiftOut, generateSwift()],
];

if (process.argv.includes("--check")) {
  const drift = outputs
    .filter(([path, content]) => readIfExists(path) !== content)
    .map(([path]) => path.replace(`${repoRoot}/`, ""));
  if (drift.length) {
    console.error(
      `品牌注册表产物与 config/brand-registry.json 不一致, 请运行 scripts/gen-brand-registry.mjs:\n  ${drift.join("\n  ")}`
    );
    process.exit(1);
  }
  console.log("ok: 品牌注册表三端产物与 config/brand-registry.json 一致");
} else {
  for (const [path, content] of outputs) writeFileSync(path, content);
  console.log(`已生成品牌注册表产物: ${outputs.map(([path]) => path.replace(`${repoRoot}/`, "")).join(", ")}`);
}
