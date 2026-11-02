// @managed-by: test-anything
// @module: pricing_catalog
// @type: unit_test
// @cases_doc: tests/docs/cases/u_pricing_catalog_cases.md
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(here, "..", "..");
const catalog = JSON.parse(readFileSync(join(repoRoot, "config/pricing-catalog.json"), "utf8"));
const fixtures = JSON.parse(
  readFileSync(join(here, "..", "fixtures", "pricing_catalog_fixtures.json"), "utf8")
);

function parseVersion(value) {
  const match = /^(\d{4})-(\d{2})-(\d{2})\.(\d+)$/.exec(String(value));
  if (!match) return null;
  return match.slice(1).map(Number);
}

// @case: UT-pricing_catalog-001
// @feature: FP-pricing_catalog-01
// @scenario: normal
test("UT-pricing_catalog-001: 目录顶层结构与 schemaVersion", () => {
  // Arrange
  const expected = fixtures;
  // Act
  const { schemaVersion, updatedAt, models } = catalog;
  // Assert
  assert.equal(schemaVersion, expected.expected_schema_version);
  assert.equal(typeof updatedAt, "string");
  assert.ok(updatedAt.length > 0);
  assert.ok(Array.isArray(models));
  assert.equal(models.length, expected.expected_model_count);
});

// @case: UT-pricing_catalog-002
// @feature: FP-pricing_catalog-02
// @scenario: boundary
test("UT-pricing_catalog-002: 模型 ID 全局唯一", () => {
  // Arrange
  const ids = catalog.models.map((model) => model.model);
  // Act
  const unique = new Set(ids);
  // Assert
  for (const id of ids) assert.equal(typeof id, "string", `非法 model id: ${id}`);
  for (const id of ids) assert.ok(id.length > 0, "model id 不得为空");
  assert.equal(unique.size, ids.length);
  assert.equal(unique.size, fixtures.expected_model_count);
});

// @case: UT-pricing_catalog-003
// @feature: FP-pricing_catalog-03
// @scenario: exception
test("UT-pricing_catalog-003: 计费字段合法", () => {
  // Arrange
  const required = fixtures.required_model_fields;
  // Act + Assert
  for (const model of catalog.models) {
    for (const field of ["displayName", "vendor", "note"]) {
      assert.equal(typeof model[field], "string", `${model.model}.${field} 必须是字符串`);
      assert.ok(model[field].length > 0, `${model.model}.${field} 不得为空`);
    }
    for (const field of ["input", "output"]) {
      assert.equal(typeof model[field], "number", `${model.model}.${field} 必须是数字`);
      assert.ok(Number.isFinite(model[field]), `${model.model}.${field} 必须是有限数`);
      assert.ok(model[field] >= 0, `${model.model}.${field} 不得为负`);
    }
    // cacheRead 在 source 中是 Option<f64>：null 表示缺省，非 null 时必须是有限非负数。
    if (model.cacheRead !== null && model.cacheRead !== undefined) {
      assert.equal(typeof model.cacheRead, "number", `${model.model}.cacheRead 必须是数字`);
      assert.ok(Number.isFinite(model.cacheRead), `${model.model}.cacheRead 必须是有限数`);
      assert.ok(model.cacheRead >= 0, `${model.model}.cacheRead 不得为负`);
    }
    for (const field of required) assert.ok(field in model, `${model.model} 缺少字段 ${field}`);
  }
});

// @case: UT-pricing_catalog-004
// @feature: FP-pricing_catalog-04
// @scenario: normal
test("UT-pricing_catalog-004: updatedAt 版本戳格式", () => {
  // Arrange
  const current = catalog.updatedAt;
  const older = "2000-01-01.0";
  // Act
  const parts = parseVersion(current);
  const olderParts = parseVersion(older);
  // Assert
  assert.ok(parts, `updatedAt 不符合 YYYY-MM-DD.N: ${current}`);
  assert.ok(olderParts);
  assert.ok(!Number.isNaN(Date.parse(current.slice(0, 10))));
  assert.ok(JSON.stringify(parts) > JSON.stringify(olderParts), "字典序比较应判定当前版本更新");
  assert.equal(parseVersion("2026-10-31"), null, "缺少修订号应被判为非法");
});
