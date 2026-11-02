// @managed-by: test-anything
// @module: provider_brand
// @type: unit_test
// @cases_doc: tests/docs/cases/u_provider_brand_cases.md
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(here, "..", "..");
const local = JSON.parse(
  readFileSync(join(here, "..", "fixtures", "provider_brand_fixtures.json"), "utf8")
);
const brand = JSON.parse(readFileSync(join(repoRoot, local.brand_cases_path), "utf8"));

const context = { window: {} };
vm.createContext(context);
vm.runInContext(readFileSync(join(repoRoot, local.provider_glyph_source), "utf8"), context);
const glyphs = context.window.BRUCE_PROVIDER_GLYPHS;

// @case: UT-provider_brand-001
// @feature: FP-provider_brand-01
// @scenario: normal
test("UT-provider_brand-001: Agent glyph 覆盖", () => {
  // Arrange
  const agents = brand.agents;
  // Act + Assert
  assert.deepEqual(Object.keys(glyphs).sort(), [...local.expected_glyph_keys].sort());
  for (const agent of agents) {
    if (!agent.glyph) continue;
    assert.ok(agent.glyph in glyphs, `${agent.id} 的 glyph 未登记: ${agent.glyph}`);
  }
});

// @case: UT-provider_brand-002
// @feature: FP-provider_brand-02
// @scenario: normal
test("UT-provider_brand-002: 模型 glyph 覆盖", () => {
  // Arrange
  const models = brand.models;
  // Act + Assert
  for (const model of models) {
    if (!model.glyph) continue;
    assert.ok(model.glyph in glyphs, `${model.key} 的 glyph 未登记: ${model.glyph}`);
  }
});

// @case: UT-provider_brand-003
// @feature: FP-provider_brand-03
// @scenario: boundary
test("UT-provider_brand-003: 几何结构合法", () => {
  // Arrange
  const entries = Object.entries(glyphs);
  // Act + Assert
  assert.equal(entries.length, local.expected_glyph_keys.length);
  for (const [key, glyph] of entries) {
    assert.equal(typeof glyph.vb, "string", `${key}.vb`);
    assert.ok(glyph.vb.length > 0, `${key}.vb 为空`);
    assert.ok(Array.isArray(glyph.shapes), `${key}.shapes 必须是数组`);
    assert.ok(glyph.shapes.length > 0, `${key}.shapes 为空`);
    for (const shape of glyph.shapes) {
      assert.ok(Array.isArray(shape), `${key} shape 必须是数组`);
      assert.equal(shape.length, 2, `${key} shape 必须是 [path, opacity]`);
      assert.equal(typeof shape[0], "string", `${key} path`);
      assert.ok(shape[0].length > 0, `${key} path 为空`);
      assert.equal(typeof shape[1], "number", `${key} opacity`);
      assert.ok(Number.isFinite(shape[1]), `${key} opacity 必须是有限数`);
    }
  }
});

// @case: UT-provider_brand-004
// @feature: FP-provider_brand-04
// @scenario: exception
test("UT-provider_brand-004: 未知身份不回退到假图标", () => {
  // Arrange
  const unknown = new Set([...brand.unknownAgents, ...brand.unknownModels, ...local.unknown_identifiers]);
  // Act + Assert
  assert.ok(unknown.size > 0);
  for (const id of unknown) {
    assert.equal(glyphs[id], undefined, `未登记身份不应出现在 glyph 表: ${id}`);
  }
});
