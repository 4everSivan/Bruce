// @managed-by: test-anything
// @module: artifact_contract
// @type: benchmark
// @cases_doc: tests/docs/cases/b_artifact_contract_cases.md
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(here, "..", "..");
const validText = readFileSync(
  join(repoRoot, "tests/fixtures/artifacts/agent-usage/valid.json"),
  "utf8"
);

export const meta = {
  module: "artifact_contract",
  cases: ["BM-artifact_contract-001"],
};

function parseAndValidate(text) {
  const body = JSON.parse(text);
  const agents = body.artifact.agents;
  for (const agent of agents) {
    const { input, output, cacheRead, cacheCreation, total } = agent.today;
    if (total !== input + output + cacheRead + cacheCreation) throw new Error("bucket total");
    const sum = (agent.todayModels || []).reduce((acc, item) => acc + item.total, 0);
    if (sum !== total) throw new Error("model breakdown");
  }
  return agents.length;
}

// @case: BM-artifact_contract-001
// @feature: FP-artifact_contract-01
// @scenario: hotspot
export function bench_bm_artifact_contract_001_parse_validate() {
  const iterations = 5000;
  for (let i = 0; i < 200; i += 1) parseAndValidate(validText);
  const start = performance.now();
  for (let i = 0; i < iterations; i += 1) parseAndValidate(validText);
  const totalMs = performance.now() - start;
  return {
    id: "BM-artifact_contract-001",
    module: "artifact_contract",
    workload: "valid agent-usage artifact",
    iterations,
    total_ms: Number(totalMs.toFixed(3)),
    avg_us: Number(((totalMs * 1000) / iterations).toFixed(3)),
    avg_ns: Number(((totalMs * 1_000_000) / iterations).toFixed(1)),
    ops_per_sec: Number(((iterations * 1000) / totalMs).toFixed(1)),
  };
}

export function run() {
  return [bench_bm_artifact_contract_001_parse_validate()];
}
