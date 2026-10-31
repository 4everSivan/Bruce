#!/usr/bin/env node
// 从采集端价卡唯一事实源生成 mac 设置页内置价卡 (C108, T19)。
//
//   node scripts/gen-pricing-catalog.mjs          重新生成 Swift 数据文件
//   node scripts/gen-pricing-catalog.mjs --check  只校验已提交的生成文件是否与 JSON 一致 (verify-local 使用)
//
// 事实源: config/pricing-catalog.json
// 产物:   apps/macos/Sources/BruceOnboardingCore/BuiltinModelPricingCatalog+Data.swift
// 只输出 listed 行 (listed=false 的别名 / 受限型号参与计费但不在设置页单列), 顺序即展示顺序。

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const sourcePath = path.join(root, "config/pricing-catalog.json");
const outputPath = path.join(
  root,
  "apps/macos/Sources/BruceOnboardingCore/BuiltinModelPricingCatalog+Data.swift",
);

const swiftString = (value) => `"${value.replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`;
const swiftNumber = (value) => {
  if (typeof value !== "number" || !Number.isFinite(value) || value < 0) {
    throw new Error(`非法单价: ${value}`);
  }
  return Number.isInteger(value) ? `${value}.0` : String(value);
};

function render(catalog) {
  const rows = catalog.models
    .filter((entry) => entry.listed !== false)
    .map((entry) => {
      const fields = [
        `modelName: ${swiftString(entry.model)}`,
        `displayName: ${swiftString(entry.displayName)}`,
        `vendor: ${swiftString(entry.vendor)}`,
        `inputPricePerMillion: ${swiftNumber(entry.input)}`,
        `outputPricePerMillion: ${swiftNumber(entry.output)}`,
      ];
      if (entry.cacheRead !== null && entry.cacheRead !== undefined) {
        fields.push(`cacheReadPricePerMillion: ${swiftNumber(entry.cacheRead)}`);
      }
      fields.push(`defaultNote: ${swiftString(entry.note)}`);
      return `        BuiltinModelPricing(\n            ${fields.join(",\n            ")}\n        ),`;
    });
  return [
    "// 本文件由 scripts/gen-pricing-catalog.mjs 生成, 请勿手改 (C108, T19)。",
    "// 事实源: config/pricing-catalog.json (采集端计费同源);",
    "// 修改价卡后运行 `node scripts/gen-pricing-catalog.mjs`, verify-local 以 --check 拦截漂移。",
    "",
    "extension BuiltinModelPricingCatalog {",
    `    public static let builtinSchemaVersion: Int = ${catalog.schemaVersion}`,
    `    public static let builtinUpdatedAt: String = ${swiftString(catalog.updatedAt)}`,
    "    public static let builtinModels: [BuiltinModelPricing] = [",
    ...rows,
    "    ]",
    "}",
    "",
  ].join("\n");
}

const catalog = JSON.parse(fs.readFileSync(sourcePath, "utf8"));
if (catalog.schemaVersion !== 1) {
  throw new Error(`pricing-catalog.json schemaVersion 必须为 1, 实际为: ${catalog.schemaVersion}`);
}
if (typeof catalog.updatedAt !== "string" || !/^\d{4}-\d{2}-\d{2}(\.\d+)?$/.test(catalog.updatedAt)) {
  throw new Error(`pricing-catalog.json updatedAt 格式不合法: ${catalog.updatedAt}`);
}
if (!Array.isArray(catalog.models) || catalog.models.length === 0) {
  throw new Error("pricing-catalog.json 缺少 models");
}
const expected = render(catalog);

if (process.argv.includes("--check")) {
  const actual = fs.existsSync(outputPath) ? fs.readFileSync(outputPath, "utf8") : "";
  if (actual !== expected) {
    console.error(
      "mac 内置价卡与 pricing-catalog.json 不一致: 请运行 node scripts/gen-pricing-catalog.mjs 并提交生成文件",
    );
    process.exit(1);
  }
  console.log(`Pricing catalog check passed: ${catalog.models.filter((m) => m.listed !== false).length} listed rows`);
} else {
  fs.writeFileSync(outputPath, expected);
  console.log(`Wrote ${path.relative(root, outputPath)}`);
}
