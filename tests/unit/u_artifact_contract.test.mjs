// @managed-by: test-anything
// @module: artifact_contract
// @type: unit_test
// @cases_doc: tests/docs/cases/u_artifact_contract_cases.md
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(here, "..", "..");
const local = JSON.parse(
  readFileSync(join(here, "..", "fixtures", "artifact_contract_fixtures.json"), "utf8")
);
const readJson = (relative) => JSON.parse(readFileSync(join(repoRoot, relative), "utf8"));

const valid = readJson(local.artifact_paths.valid);
const partial = readJson(local.artifact_paths.partial);
const empty = readJson(local.artifact_paths.empty);

// @case: UT-artifact_contract-001
// @feature: FP-artifact_contract-01
// @scenario: normal
test("UT-artifact_contract-001: Agent bucket 总量一致", () => {
  // Arrange
  const agents = valid.artifact.agents;
  // Act + Assert
  assert.ok(agents.length >= 1);
  for (const agent of agents) {
    const { input, output, cacheRead, cacheCreation, total } = agent.today;
    for (const [name, value] of Object.entries({ input, output, cacheRead, cacheCreation, total })) {
      assert.equal(typeof value, "number", `${agent.id}.${name} 必须是数字`);
      assert.ok(value >= 0, `${agent.id}.${name} 不得为负`);
    }
    assert.equal(total, input + output + cacheRead + cacheCreation, `${agent.id} bucket 总量不一致`);
  }
});

// @case: UT-artifact_contract-002
// @feature: FP-artifact_contract-02
// @scenario: normal
test("UT-artifact_contract-002: 模型分项汇总一致", () => {
  // Arrange
  const agents = valid.artifact.agents;
  // Act + Assert
  for (const agent of agents) {
    const models = agent.todayModels || [];
    const sum = models.reduce((acc, item) => acc + item.total, 0);
    assert.equal(sum, agent.today.total, `${agent.id} todayModels 之和与 today.total 不一致`);
    if (models.length === 0) assert.equal(agent.today.total, 0);
  }
});

// @case: UT-artifact_contract-003
// @feature: FP-artifact_contract-03
// @scenario: boundary
test("UT-artifact_contract-003: 空态 artifact", () => {
  // Arrange
  const artifact = empty.artifact;
  // Act + Assert
  assert.equal(artifact.collectionStatus, "empty");
  assert.deepEqual(artifact.agents, []);
  assert.deepEqual(artifact.services, []);
  assert.equal(artifact.totalCostUsd, null);
});

// @case: UT-artifact_contract-004
// @feature: FP-artifact_contract-04
// @scenario: exception
test("UT-artifact_contract-004: 部分失败状态", () => {
  // Arrange
  const agents = partial.artifact.agents;
  const allowed = new Set(local.allowed_agent_statuses);
  // Act
  const statuses = new Set(agents.map((agent) => agent.status));
  // Assert
  for (const status of statuses) assert.ok(allowed.has(status), `未知 agent status: ${status}`);
  assert.ok(statuses.has("ok"), "样本缺少 ok 状态");
  assert.ok(statuses.has("not_found"), "样本缺少 not_found 状态");
  for (const agent of agents) {
    assert.equal(typeof agent.today, "object", `${agent.id} 缺少 today`);
    assert.notEqual(agent.today, null);
  }
});

// @case: UT-artifact_contract-005
// @feature: FP-artifact_contract-05
// @scenario: exception
test("UT-artifact_contract-005: Bridge 响应状态契约", () => {
  // Arrange
  const dir = join(repoRoot, local.bridge_dir);
  const responses = readdirSync(dir)
    .filter((name) => name.startsWith("response-") && name.endsWith(".json"))
    .map((name) => ({ name, body: JSON.parse(readFileSync(join(dir, name), "utf8")) }));
  const seen = new Set();
  // Act + Assert
  for (const { name, body } of responses) {
    assert.equal(body.schemaVersion, 1, `${name} schemaVersion`);
    seen.add(body.status);
    if (body.status === "error") {
      assert.equal(body.artifact, null, `${name} error 响应不得携带 artifact`);
      assert.ok(body.diagnostics.length > 0, `${name} 缺少 diagnostics`);
      for (const item of body.diagnostics) {
        for (const field of ["code", "category", "stage", "message"]) {
          assert.equal(typeof item[field], "string", `${name} diagnostics.${field}`);
          assert.ok(item[field].length > 0, `${name} diagnostics.${field} 为空`);
        }
      }
    } else {
      assert.notEqual(body.artifact, null, `${name} 成功/部分响应必须携带 artifact`);
    }
  }
  for (const status of local.required_bridge_statuses) {
    assert.ok(seen.has(status), `响应样本缺少状态 ${status}`);
  }
});
