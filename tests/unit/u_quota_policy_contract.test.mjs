// @managed-by: test-anything
// @module: quota_policy_contract
// @type: unit_test
// @cases_doc: tests/docs/cases/u_quota_policy_contract_cases.md
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(here, "..", "..");
const local = JSON.parse(
  readFileSync(join(here, "..", "fixtures", "quota_policy_contract_fixtures.json"), "utf8")
);
const readJson = (relative) => JSON.parse(readFileSync(join(repoRoot, relative), "utf8"));

const quota = readJson(local.quota_policy_path);
const carry = readJson(local.quota_carry_over_path);
const refresh = readJson(local.refresh_policy_path);

function assertUniqueNames(cases, label) {
  const names = cases.map((item) => item.name);
  const unique = new Set(names);
  assert.equal(unique.size, names.length, `${label} 用例名称重复`);
  for (const name of names) assert.ok(typeof name === "string" && name.length > 0);
}

// @case: UT-quota_policy_contract-001
// @feature: FP-quota_policy_contract-01
// @scenario: normal
test("UT-quota_policy_contract-001: 查询门禁用例结构", () => {
  // Arrange
  const cases = quota.cases;
  // Act + Assert
  assert.equal(cases.length, local.expected_quota_case_count);
  assertUniqueNames(cases, "quota-policy-parity");
  for (const item of cases) {
    const expected = item.expected;
    assert.equal(typeof expected.includeExternalQuotas, "boolean", `${item.name}.includeExternalQuotas`);
    assert.ok(Array.isArray(expected.skipProviders), `${item.name}.skipProviders`);
    assert.ok(Array.isArray(expected.rateLimitedProviders), `${item.name}.rateLimitedProviders`);
  }
});

// @case: UT-quota_policy_contract-002
// @feature: FP-quota_policy_contract-02
// @scenario: exception
test("UT-quota_policy_contract-002: provider 集合一致性", () => {
  // Arrange
  const cases = quota.cases;
  // Act + Assert
  for (const item of cases) {
    const enabled = new Set(item.enabledProviders || []);
    for (const provider of item.expected.skipProviders) {
      assert.ok(enabled.has(provider), `${item.name}: skip provider 不在 enabledProviders: ${provider}`);
    }
    for (const provider of item.expected.rateLimitedProviders) {
      assert.ok(enabled.has(provider), `${item.name}: rateLimited provider 不在 enabledProviders: ${provider}`);
    }
  }
});

// @case: UT-quota_policy_contract-003
// @feature: FP-quota_policy_contract-03
// @scenario: normal
test("UT-quota_policy_contract-003: 回填用例结构", () => {
  // Arrange
  const cases = carry.cases;
  // Act + Assert
  assert.equal(cases.length, local.expected_carry_over_case_count);
  assertUniqueNames(cases, "quota-carry-over-parity");
  for (const item of cases) {
    assert.ok(item.previous === null || Array.isArray(item.previous), `${item.name}.previous 必须是数组或 null`);
    for (const field of ["current", "expected"]) {
      assert.ok(Array.isArray(item[field]), `${item.name}.${field} 必须是数组`);
    }
    for (const field of ["includeExternalQuotas", "skipProviders", "rateLimitedProviders"]) {
      assert.ok(field in item.policy, `${item.name}.policy 缺少 ${field}`);
    }
  }
});

// @case: UT-quota_policy_contract-004
// @feature: FP-quota_policy_contract-04
// @scenario: boundary
test("UT-quota_policy_contract-004: 刷新边界用例结构", () => {
  // Arrange
  const expectedSizes = local.expected_refresh_arrays;
  // Act + Assert
  for (const [field, size] of Object.entries(expectedSizes)) {
    assert.ok(Array.isArray(refresh[field]), `${field} 必须是数组`);
    assert.equal(refresh[field].length, size, `${field} 条数漂移`);
  }
  for (const item of refresh.boundaryIds) {
    for (const value of item.expected) {
      assert.ok(value === null || Number.isFinite(value), `${item.name} expected 含非法时间戳: ${value}`);
    }
    for (const service of item.services || []) {
      for (const window of service.windows || []) {
        if (!("resetsAt" in window)) continue;
        const value = window.resetsAt;
        assert.ok(value === null || Number.isFinite(value), `${item.name}.${service.id} resetsAt 非法: ${value}`);
      }
    }
  }
});
