// @managed-by: test-anything
// @module: quota_policy_contract
// @type: benchmark
// @cases_doc: tests/docs/cases/b_quota_policy_contract_cases.md
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(here, "..", "..");
const quota = JSON.parse(
  readFileSync(join(repoRoot, "tests/fixtures/quota-policy-parity/cases.json"), "utf8")
);
const carry = JSON.parse(
  readFileSync(join(repoRoot, "tests/fixtures/quota-carry-over-parity/cases.json"), "utf8")
);
const refresh = JSON.parse(
  readFileSync(join(repoRoot, "tests/fixtures/refresh-policy-parity/cases.json"), "utf8")
);

export const meta = {
  module: "quota_policy_contract",
  cases: ["BM-quota_policy_contract-001"],
};

function validateAll() {
  const quotaNames = new Set();
  for (const item of quota.cases) {
    if (quotaNames.has(item.name)) throw new Error("duplicate quota case");
    quotaNames.add(item.name);
    const expected = item.expected;
    const enabled = new Set(item.enabledProviders || []);
    for (const provider of [...expected.skipProviders, ...expected.rateLimitedProviders]) {
      if (!enabled.has(provider)) throw new Error("provider outside enabled set");
    }
  }
  const carryNames = new Set();
  for (const item of carry.cases) {
    if (carryNames.has(item.name)) throw new Error("duplicate carry case");
    carryNames.add(item.name);
    if (!Array.isArray(item.current) || !Array.isArray(item.expected)) throw new Error("carry arrays");
  }
  if (refresh.boundaryIds.length === 0 || refresh.boundaryWake.length === 0 || refresh.backoff.length === 0) {
    throw new Error("refresh arrays empty");
  }
  return quota.cases.length + carry.cases.length + refresh.boundaryIds.length;
}

// @case: BM-quota_policy_contract-001
// @feature: FP-quota_policy_contract-01
// @scenario: hotspot
export function bench_bm_quota_policy_contract_001_fixture_validation() {
  const iterations = 2000;
  for (let i = 0; i < 100; i += 1) validateAll();
  const start = performance.now();
  for (let i = 0; i < iterations; i += 1) validateAll();
  const totalMs = performance.now() - start;
  return {
    id: "BM-quota_policy_contract-001",
    module: "quota_policy_contract",
    workload: "21 quota + 15 carry-over + refresh cases",
    iterations,
    total_ms: Number(totalMs.toFixed(3)),
    avg_us: Number(((totalMs * 1000) / iterations).toFixed(3)),
    avg_ns: Number(((totalMs * 1_000_000) / iterations).toFixed(1)),
    ops_per_sec: Number(((iterations * 1000) / totalMs).toFixed(1)),
  };
}

export function run() {
  return [bench_bm_quota_policy_contract_001_fixture_validation()];
}
