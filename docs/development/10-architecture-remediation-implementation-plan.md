# Architecture Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Finish architecture debt from the 2026-08-05 design: explicit refresh intents, observable credential persistence, execution pipeline, provider registry, unified collector services, and panel/harness/token-manager decomposition — without changing UI layout or artifact contracts.

**Architecture:** Horizontal phases S1→S5. Scheduler becomes a timer/capacity façade; business orchestration moves to `RefreshExecutionPipeline` and `CredentialUpdateCoordinator`. Provider extension uses a registry. Python App/CLI share one service builder behind `RunContext`. Panel mapping and harnesses split by responsibility.

**Tech Stack:** Swift 6.2 / macOS 26 (`macos/BruceApp`), Python 3 collector + bridge, executable Harnesses (not XCTest), `zsh scripts/verify-local.sh`.

**Spec:** `docs/development/09-architecture-remediation-design.md`  
**Local skill mirror (gitignored):** `docs/superpowers/specs/2026-08-05-architecture-remediation-design.md`

## Global Constraints

- **UI layout freeze:** Do not change SwiftUI hierarchy, padding, spacing, frame, font hierarchy, card sections, settings control order, or liquid glass look. `Sources/BruceApp/Views/**` default zero intentional diff.
- **Behavior freeze:** artifact fields, Bridge schema, Codex one forced-refresh + one retry-only per cycle, CLI legacy auth kept.
- **Only allowed user-visible semantic change:** Keychain credential write failure → diagnostic (`CREDENTIAL_PERSIST_FAILED`) and possible module status `partial` via existing channels — no new Alert, no new Settings section.
- **No secrets** in diagnostics, logs, or artifact.
- **No new providers** or product features in this campaign.
- **No production collect** without explicit user authorization (`constitution.md` Production Operation Mode).
- **Every task ends green:** at least the listed harness/pytest commands; prefer full `zsh scripts/verify-local.sh` at phase boundaries.
- **Commits:** Conventional Commits; one logical task or small task group per commit; do not commit secrets or `data/`.

## File Map (target end state)

| Path | Role |
|------|------|
| `macos/BruceApp/Sources/BruceAppCore/RefreshTypes.swift` | `RefreshTriggerReason`, `RefreshIntent`, merge helpers |
| `macos/BruceApp/Sources/BruceAppCore/CredentialUpdateCoordinator.swift` | Apply rotation updates; return `CredentialUpdateApplyResult` |
| `macos/BruceApp/Sources/BruceAppCore/RefreshExecutionPipeline.swift` | One refresh lifecycle |
| `macos/BruceApp/Sources/BruceAppCore/RefreshScheduler.swift` | Timer, capacity, intent queue, apply pipeline result |
| `macos/BruceApp/Sources/BruceOnboardingCore/ProviderRegistry.swift` | Descriptors, injection/configured rules |
| `macos/BruceApp/Sources/BruceApp/SubscriptionService.swift` | Subscription CRUD workflows (thin Coordinator façade OK) |
| `macos/BruceApp/Sources/BruceApp/LocalCredentialProbe.swift` | Local file/Keychain probes |
| `macos/BruceApp/Sources/BruceApp/Settings/*ProviderSettingsSection.swift` | Settings sections (layout-identical move) |
| `agent-usage/collector/runtime_context.py` or expand `runtime.py` | `RunContext` |
| `agent-usage/collector/service_catalog.py` | Unified `build_quota_services` |
| `tests/fixtures/credential-expiry/*` | Shared expiry fixtures |
| `macos/BruceApp/Sources/BruceAppCore/SubscriptionPresentationPolicy.swift` | Panel subscription display rules |
| Panel split files under `BruceAppCore/` | Models / usage / subscription mapping |

---

## Phase S1 — RefreshIntent + Credential Write Observability

### Task 1: RefreshIntent types + state field

**Files:**
- Create: `macos/BruceApp/Sources/BruceAppCore/RefreshTypes.swift`
- Modify: `macos/BruceApp/Sources/BruceAppCore/RefreshScheduler.swift` (`ModuleScheduleState`)
- Test: `macos/BruceApp/Tests/Harnesses/RefreshSchedulerHarness/RefreshSchedulerHarness.swift`

**Interfaces:**
- Produces:
  - `package enum RefreshTriggerReason: Equatable, Sendable { case timer, manual, wake }`
  - `package struct RefreshIntent: Equatable, Sendable { var reason: RefreshTriggerReason; var includesManual: Bool }`
  - `package enum RefreshIntentMerge` with `static func merge(existing: RefreshIntent?, incoming: RefreshIntent) -> RefreshIntent`
- `ModuleScheduleState`: remove `pendingRerun`; add `pendingIntent: RefreshIntent? = nil`

**Merge rules (must match spec §4.2):**
- `includesManual = existing.includesManual || incoming.includesManual || existing.reason == .manual || incoming.reason == .manual`
- If `includesManual` or either reason is `.manual` → `reason = .manual`; else keep existing reason when present, else incoming

- [ ] **Step 1: Add pure merge unit tests in RefreshSchedulerHarness**

Add a small suite that does not need a full scheduler:

```swift
private static func intentMergeManualWinsOverTimer() throws {
    let existing = RefreshIntent(reason: .timer, includesManual: false)
    let incoming = RefreshIntent(reason: .manual, includesManual: true)
    let merged = RefreshIntentMerge.merge(existing: existing, incoming: incoming)
    try refreshExpect(merged.reason == .manual, "manual reason")
    try refreshExpect(merged.includesManual, "includesManual")
}

private static func intentMergeTimerIntoManualKeepsManual() throws {
    let existing = RefreshIntent(reason: .manual, includesManual: true)
    let incoming = RefreshIntent(reason: .timer, includesManual: false)
    let merged = RefreshIntentMerge.merge(existing: existing, incoming: incoming)
    try refreshExpect(merged.reason == .manual, "stay manual")
    try refreshExpect(merged.includesManual, "stay includesManual")
}

private static func intentMergeNilExistingUsesIncoming() throws {
    let incoming = RefreshIntent(reason: .wake, includesManual: false)
    let merged = RefreshIntentMerge.merge(existing: nil, incoming: incoming)
    try refreshExpect(merged == incoming, "nil existing")
}
```

Wire into harness `main` / suite list.

- [ ] **Step 2: Run harness — expect compile fail (types missing)**

```bash
swift run --package-path macos/BruceApp RefreshSchedulerHarness "$PWD"
```

Expected: compile error `RefreshIntent` / `RefreshIntentMerge` not found.

- [ ] **Step 3: Implement `RefreshTypes.swift` + state field**

```swift
import Foundation

package enum RefreshTriggerReason: Equatable, Sendable {
    case timer
    case manual
    case wake
}

package struct RefreshIntent: Equatable, Sendable {
    package var reason: RefreshTriggerReason
    package var includesManual: Bool

    package init(reason: RefreshTriggerReason, includesManual: Bool) {
        self.reason = reason
        self.includesManual = includesManual
    }

    package static func manual() -> RefreshIntent {
        RefreshIntent(reason: .manual, includesManual: true)
    }

    package static func timer() -> RefreshIntent {
        RefreshIntent(reason: .timer, includesManual: false)
    }

    package static func wake() -> RefreshIntent {
        RefreshIntent(reason: .wake, includesManual: false)
    }
}

package enum RefreshIntentMerge {
    package static func merge(existing: RefreshIntent?, incoming: RefreshIntent) -> RefreshIntent {
        guard let existing else { return incoming }
        let includesManual = existing.includesManual
            || incoming.includesManual
            || existing.reason == .manual
            || incoming.reason == .manual
        let reason: RefreshTriggerReason
        if includesManual {
            reason = .manual
        } else {
            reason = existing.reason
        }
        return RefreshIntent(reason: reason, includesManual: includesManual)
    }
}
```

In `ModuleScheduleState`:

```swift
// delete: var pendingRerun: Bool = false
var pendingIntent: RefreshIntent? = nil
```

Temporarily fix compile: replace every `pendingRerun = true` with setting an intent, and `pendingRerun = false` with `pendingIntent = nil`, and reads of `pendingRerun` with `pendingIntent != nil`. Keep behavior equivalent using `RefreshIntent.manual()` when `isManual`, else `RefreshIntent.timer()` (wake path: `RefreshIntent.wake()`).

- [ ] **Step 4: Run merge tests + existing scheduler harness**

```bash
swift run --package-path macos/BruceApp RefreshSchedulerHarness "$PWD"
```

Expected: all pass (including new merge tests).

- [ ] **Step 5: Commit**

```bash
git add macos/BruceApp/Sources/BruceAppCore/RefreshTypes.swift \
  macos/BruceApp/Sources/BruceAppCore/RefreshScheduler.swift \
  macos/BruceApp/Tests/Harnesses/RefreshSchedulerHarness/RefreshSchedulerHarness.swift
git commit -m "refactor(scheduler): introduce RefreshIntent and replace pendingRerun bool"
```

---

### Task 2: Intent-aware queue + lastTriggerWasManual

**Files:**
- Modify: `macos/BruceApp/Sources/BruceAppCore/RefreshScheduler.swift` (`triggerRefresh`, `startRefresh`, `handleResult`, `startQueuedModulesIfCapacityAvailable`)
- Test: `RefreshSchedulerHarness`

**Interfaces:**
- Consumes: `RefreshIntent`, `RefreshIntentMerge`
- Produces: when `startRefresh` begins, `state.lastTriggerWasManual = intent.includesManual` from the intent being executed (parameterize `startRefresh(for:intent:)` or read from a `startingIntent` field set just before start)

**Behavior to preserve:**
- Running + another request → merge into `pendingIntent`, no second process
- Capacity full → set `pendingIntent` on that module
- After success/failure, if `pendingIntent != nil && phase == idle` → rerun with that intent
- Manual-including intent must not fire quota alerts (`lastTriggerWasManual == true`)

- [ ] **Step 1: Add failing harness for manual coalesce + alert suppression**

Reuse patterns from existing “multiple manual while running” tests. Assert:
1. Collector run count increases by exactly 1 after coalesced manuals drain
2. If a timer intent was merged after manual, `lastTriggerWasManual` is still true on the drained run (observe via `onQuotaAlerts` not firing when thresholds would fire — or expose test-only last trigger if already available)

If no clean hook exists, assert via existing quota-alert harness fixtures that manual coalesced runs do not call `onQuotaAlerts`.

- [ ] **Step 2: Run test — fail or incomplete until startRefresh sets lastTriggerWasManual from intent**

- [ ] **Step 3: Implement**

In `triggerRefresh(for:isManual:)`:

```swift
let incoming = isManual ? RefreshIntent.manual() : RefreshIntent.timer()
// wake entry points use RefreshIntent.wake()

if state.phase == .running {
    states[module]?.pendingIntent = RefreshIntentMerge.merge(
        existing: state.pendingIntent, incoming: incoming
    )
    return
}
if runningCount >= capacityLimit {
    states[module]?.pendingIntent = RefreshIntentMerge.merge(
        existing: state.pendingIntent, incoming: incoming
    )
    return
}
startRefresh(for: module, intent: incoming)
```

In `startRefresh`:

```swift
state.lastTriggerWasManual = intent.includesManual
state.pendingIntent = nil  // clear only the intent being started; pending merge already consumed into `intent`
```

In `handleResult` completion path:

```swift
if let pending = state.pendingIntent, state.phase == .idle {
    state.pendingIntent = nil
    states[module] = state
    startRefresh(for: module, intent: pending)
    return
}
```

Capacity drain: pick idle modules with `pendingIntent != nil`, take intent, clear, `startRefresh(for:intent:)`.

- [ ] **Step 4: Run**

```bash
swift run --package-path macos/BruceApp RefreshSchedulerHarness "$PWD"
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git commit -m "fix(scheduler): queue RefreshIntent with manual-preserving merge"
```

---

### Task 3: CredentialUpdateCoordinator (pure apply + result)

**Files:**
- Create: `macos/BruceApp/Sources/BruceAppCore/CredentialUpdateCoordinator.swift`
- Modify: `macos/BruceApp/Sources/BruceAppCore/CollectorRunInput.swift` (delegate or remove body of `apply`)
- Test: prefer new cases in `SubscriptionCredentialsHarness` or `RefreshSchedulerHarness`; may add pure tests next to Onboarding rotation tests if coordinator is testable without Keychain

**Interfaces:**
- Consumes: `CredentialStore`, `CredentialRotationMerge`, `CredentialRotationUpdate`
- Produces:

```swift
package struct CredentialUpdateFailure: Equatable, Sendable {
    package let provider: String
    package let accountId: String
    package let reason: String
}

package struct CredentialUpdateApplyResult: Equatable, Sendable {
    package var appliedCount: Int
    package var skippedCount: Int
    package var failed: [CredentialUpdateFailure]
}

package struct CredentialUpdateCoordinator: Sendable {
    package init(credentialStore: CredentialStore)
    package func apply(credentialUpdates: [JSONValue]) -> CredentialUpdateApplyResult
}
```

Rules:
- Skip (count as skipped): bad shape, codex provider, unknown provider, merge returns nil
- Fail: `saveCredential` throws → append failure with `error.localizedDescription` truncated, **never include token values**
- Success: increment `appliedCount`

- [ ] **Step 1: Write failing tests**

```swift
// Failing store
final class ThrowingCredentialStore: CredentialStore {
    func loadCredential(forAccount account: String) throws -> String? { nil }
    func saveCredential(_ value: String, forAccount account: String) throws {
        throw NSError(domain: "test", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "keychain denied"
        ])
    }
    // implement delete if required by protocol
}

// Apply one valid kimi oauthTokens/replace update → failed.count == 1, appliedCount == 0
// Apply codex update → skipped, no save
// Apply valid with InMemory store → appliedCount == 1, load shows merged tokens
```

Use existing `InMemoryCredentialStore` from OnboardingCore if available.

- [ ] **Step 2: Run — fail (type missing)**

- [ ] **Step 3: Implement coordinator**

Move parsing logic from `CollectorRunInput.rotationUpdate` into coordinator (package or private).  
`OnboardingRunInputProvider.apply(credentialUpdates:)` becomes:

```swift
package func apply(credentialUpdates: [JSONValue]) -> CredentialUpdateApplyResult {
    CredentialUpdateCoordinator(credentialStore: credentialStore)
        .apply(credentialUpdates: credentialUpdates)
}
```

Or delete apply from provider and only use coordinator from scheduler (Task 4). Prefer single owner: **Coordinator only**; provider method can thin-wrap for compatibility then delete in Task 4.

- [ ] **Step 4: Run harnesses**

```bash
swift run --package-path macos/BruceApp SubscriptionCredentialsHarness
swift run --package-path macos/BruceApp RefreshSchedulerHarness "$PWD"
swift build --package-path macos/BruceApp
```

- [ ] **Step 5: Commit**

```bash
git commit -m "feat(credentials): add CredentialUpdateCoordinator with apply result"
```

---

### Task 4: Wire coordinator into Scheduler handleResult (observable partial)

**Files:**
- Modify: `macos/BruceApp/Sources/BruceAppCore/RefreshScheduler.swift`
- Modify: `macos/BruceApp/Sources/BruceApp/ApplicationBootstrap.swift`
- Test: `RefreshSchedulerHarness`

**Interfaces:**
- Change `onCredentialUpdates` from  
  `((CollectorModule, [JSONValue]) -> Void)?`  
  to either:
  - **Preferred:** Scheduler holds `CredentialUpdateCoordinator?` (or `() -> CredentialUpdateCoordinator`) injected at init; remove callback
  - Or callback returns `CredentialUpdateApplyResult`

Recommended:

```swift
// RefreshScheduler
private let credentialUpdates: CredentialUpdateCoordinator?

// in handleResult success branch, before/after publish as today (updates still before publish):
let applyResult = credentialUpdates?.apply(credentialUpdates: response.credentialUpdates)
    ?? CredentialUpdateApplyResult(appliedCount: 0, skippedCount: 0, failed: [])
// merge diagnostics into response diagnostics copy
// if !applyResult.failed.isEmpty && response has artifact && status was success → treat as partial
```

Diagnostic shape (no secrets):

```swift
BridgeDiagnostic(
    code: "CREDENTIAL_PERSIST_FAILED",
    stage: "credentialUpdate",
    category: "storage", // or existing category enum/string used by bridge
    message: "\(provider) 凭证写回失败" // no token
)
```

Use the same `BridgeDiagnostic` type already in AppCore. Match field names exactly to the existing struct.

- [ ] **Step 1: Failing harness**

Mock executor returns success artifact + one credentialUpdate. Inject throwing credential store via coordinator. Assert:
- `onStatusChange` ends at `.partial` (not `.fresh`)
- published diagnostics contain code `CREDENTIAL_PERSIST_FAILED`
- artifact still published (store has artifact)

- [ ] **Step 2: Run — fail**

- [ ] **Step 3: Implement wiring**

Update `ApplicationBootstrap`:

```swift
// remove:
// scheduler.onCredentialUpdates = { runInputProvider.apply(...) }

// inject coordinator into scheduler init (add parameter)
let credentialCoordinator = CredentialUpdateCoordinator(credentialStore: ...)
// pass store used by runInputProvider
```

Preserve order: apply credential updates **before** `store.publish` (existing comment).

- [ ] **Step 4: Run**

```bash
swift run --package-path macos/BruceApp RefreshSchedulerHarness "$PWD"
swift run --package-path macos/BruceApp LocalIntegrationHarness "$PWD" "$(command -v python3)" "$PWD/bridge/run_bridge.py"
```

- [ ] **Step 5: S1 gate + commit**

```bash
zsh scripts/verify-local.sh
git commit -m "feat(scheduler): surface credential persist failures as partial diagnostics"
```

**S1 done when:** no `pendingRerun` symbol; write failures observable; UI layout untouched; verify-local green.

---

## Phase S2 — RefreshExecutionPipeline

### Task 5: Define pipeline types and skeleton

**Files:**
- Create: `macos/BruceApp/Sources/BruceAppCore/RefreshExecutionPipeline.swift`
- Test: new cases in `RefreshSchedulerHarness` or new file `Tests/Harnesses/RefreshSchedulerHarness/PipelineTests.swift` (same target)

**Interfaces:**

```swift
package struct RefreshPipelineRequest: Sendable {
    package let module: CollectorModule
    package let intent: RefreshIntent
    package let staleAfter: TimeInterval
    package let now: Date
}

package struct CompletedRun: Sendable {
    package let response: CollectorBridgeResponse // use actual response type name from CollectorRunner
    package let credentialApply: CredentialUpdateApplyResult
    package let quotaAlertEntries: [QuotaAlertEvaluator.Entry] // match real type
    package let includesManual: Bool
}

package enum RefreshPipelineResult: Sendable {
    case completed(CompletedRun)
    case runInputFailed(CollectorRunInputError)
    case collectorFailed(Error)
    case publishFailed(Error)
    case cancelled
}

@MainActor
package struct RefreshExecutionPipeline {
    package init(
        executor: CollectorExecuting,
        store: ArtifactStore,
        runInputProvider: (any CollectorRunInputProviding)?,
        credentialUpdates: CredentialUpdateCoordinator?,
        codexTokenManager: (any CodexChallengeHandling)?,
        isStopped: @escaping () -> Bool
    )
    package func run(_ request: RefreshPipelineRequest) async -> RefreshPipelineResult
}
```

Adjust type names to match codebase (`CollectorRunOutput`, bridge response fields).

- [ ] **Step 1: Add compile-only harness that constructs pipeline and calls run with mock executor (expect cancelled/stopped or empty input)**

- [ ] **Step 2: Implement skeleton returning `.cancelled` if `isStopped()` else minimal path**

- [ ] **Step 3: Build green**

```bash
swift build --package-path macos/BruceApp
```

- [ ] **Step 4: Commit**

```bash
git commit -m "refactor(scheduler): add RefreshExecutionPipeline skeleton"
```

---

### Task 6: Move executeRefresh body into pipeline

**Files:**
- Modify: `RefreshExecutionPipeline.swift`, `RefreshScheduler.swift`
- Keep: `CodexQuotaRecovery.swift`, `ArtifactFinalizer.swift` (call sites only)

**Order (fixed):**
1. run input  
2. load previous artifact once  
3. first collect  
4. Codex recovery if `module == .agentUsage`  
5. finalize  
6. credential apply  
7. publish + merge credential diagnostics / partial demotion  
8. quota alert evaluation (compute entries; Scheduler decides callback using `includesManual`)  
9. return `.completed`

- [ ] **Step 1: Port existing RefreshSchedulerHarness execution cases without changing assertions**

- [ ] **Step 2: Move code; Scheduler `executeRefresh` becomes:**

```swift
let result = await pipeline.run(RefreshPipelineRequest(
    module: module,
    intent: currentIntent,
    staleAfter: configuration.staleAfter,
    now: clock.now()
))
apply(result, for: module)
onRunCycleCompleted?()
```

- [ ] **Step 3: Implement `apply(result:for:)` mapping phases (copy from old handleResult phase logic only)**

- [ ] **Step 4: Run**

```bash
swift run --package-path macos/BruceApp RefreshSchedulerHarness "$PWD"
```

Expected: same pass count as before move (± new tests).

- [ ] **Step 5: S2 gate + commit**

```bash
zsh scripts/verify-local.sh
git commit -m "refactor(scheduler): run refreshes through RefreshExecutionPipeline"
```

**S2 done when:** `executeRefresh` has no inline recovery/finalizer/publish; UI untouched.

---

## Phase S3 — Provider Registry + Onboarding/Settings Split

### Task 7: ProviderRegistry + unified assembleCredentials

**Files:**
- Create: `macos/BruceApp/Sources/BruceOnboardingCore/ProviderRegistry.swift`
- Modify: `macos/BruceApp/Sources/BruceAppCore/CollectorRunInput.swift` (`assembleSubscriptionCredentials`)
- Test: `SubscriptionCredentialsHarness`, existing injection cases

**Interfaces:**

```swift
public enum InjectionKind: Sendable { /* as design §6.2 */ }
public enum ConfiguredRule: Sendable { /* as design §6.2 */ }
public struct ProviderDescriptor: Sendable {
    public let id: SubscriptionProviderID
    public let credentialAccounts: [String]
    public let injectionKind: InjectionKind
    public let configuredRule: ConfiguredRule
}
public enum ProviderRegistry {
    public static var all: [ProviderDescriptor] { get }
    public static func descriptor(for id: SubscriptionProviderID) -> ProviderDescriptor
}
```

Golden rule: output credentials JSON **byte-for-byte same keys/nesting** as current `assembleSubscriptionCredentials` for each enabled provider (compare harness fixtures).

- [ ] **Step 1: Snapshot current harness expected credentials objects (or add equality tests per provider)**

- [ ] **Step 2: Implement registry + rewrite assemble to switch on `InjectionKind` only**

- [ ] **Step 3: Run**

```bash
swift run --package-path macos/BruceApp SubscriptionCredentialsHarness
swift run --package-path macos/BruceApp CollectorRunnerHarness "$(command -v python3)" "$PWD/bridge/run_bridge.py"
```

- [ ] **Step 4: Commit**

```bash
git commit -m "refactor(onboarding): introduce ProviderRegistry for credential injection"
```

---

### Task 8: ConfiguredRule + LocalCredentialProbe

**Files:**
- Modify: `OnboardingCoordinator.swift` (`credentialConfigured`)
- Create: `macos/BruceApp/Sources/BruceApp/LocalCredentialProbe.swift`
- Move probe helpers from Coordinator into probe

- [ ] **Step 1: Tests for claude/grok app-vs-local configured priority (existing harness cases must keep passing)**

- [ ] **Step 2: Implement ConfiguredRule evaluation helper in OnboardingCore (pure where possible); probes stay in App layer**

- [ ] **Step 3: Run Onboarding + Subscription harnesses**

- [ ] **Step 4: Commit**

```bash
git commit -m "refactor(onboarding): centralize configured rules and local credential probes"
```

---

### Task 9: SubscriptionService + Coordinator façade

**Files:**
- Create: `macos/BruceApp/Sources/BruceApp/SubscriptionService.swift`
- Modify: `OnboardingCoordinator.swift` — methods become one-line forwards
- **Do not change** Settings call sites yet

- [ ] **Step 1: Move subscription methods body to SubscriptionService (same signatures)**

- [ ] **Step 2: Build + run OnboardingCoreHarness / app compile**

```bash
swift build --package-path macos/BruceApp
swift run --package-path macos/BruceApp BruceOnboardingCoreHarness
```

- [ ] **Step 3: Commit**

```bash
git commit -m "refactor(app): extract SubscriptionService behind OnboardingCoordinator façade"
```

---

### Task 10: Settings file split (layout-identical)

**Files:**
- Create: e.g. `macos/BruceApp/Sources/BruceApp/Settings/DeepSeekProviderSettingsSection.swift` (and one per provider)
- Modify: `SettingsView.swift` — `subscriptionProviderManagement` switch calls extracted views
- **Gate:** diff must not change padding/spacing/frame/font values or control order

- [ ] **Step 1: Cut-paste one provider group (DeepSeek) to new file without editing modifiers**

- [ ] **Step 2: `swift build` + visual self-check of diff (`git diff -U0` review for layout tokens)**

- [ ] **Step 3: Repeat remaining providers**

- [ ] **Step 4: S3 gate**

```bash
zsh scripts/verify-local.sh
git commit -m "refactor(settings): split provider sections into files without layout changes"
```

**S3 done when:** registry drives inject/configured; Coordinator slimmed; Settings split; no layout token changes.

---

## Phase S4 — Collector Unification + Expiry Contract

### Task 11: Shared expiry fixtures + dual-end tests (lock first)

**Files:**
- Create: `tests/fixtures/credential-expiry/*.json` (at least: claude valid/expired ms/expired s/bad date; grok valid/expired)
- Create: `tests/test_credential_expiry_contract.py`
- Modify: Swift harness (OnboardingCore or SubscriptionCredentials) to load same fixtures from repo path

**Python example:**

```python
import json
from pathlib import Path
from agent-usage path import quota_official  # use project's import style (sys.path / importlib)

FIXTURES = Path(__file__).parent / "fixtures" / "credential-expiry"

def test_claude_expired_ms_matches_matrix():
    raw = (FIXTURES / "claude_expired_ms.json").read_text()
    # call the same helper SubscriptionCredentialEvaluator mirrors
    assert quota_official._is_expired(...) is True
```

Match exact helper names in `quota_official.py` (`_is_expired`, etc.).

- [ ] **Step 1: Write fixtures from real evaluator edge cases**

- [ ] **Step 2: Python tests pass; Swift tests pass on same files**

```bash
python3 -m pytest tests/test_credential_expiry_contract.py -q
swift run --package-path macos/BruceApp BruceOnboardingCoreHarness
```

- [ ] **Step 3: Commit**

```bash
git commit -m "test(credentials): add shared Swift/Python expiry contract fixtures"
```

---

### Task 12: RunContext introduction

**Files:**
- Create or expand: `agent-usage/collector/runtime.py` / `runtime_context.py`
- Modify: `collect_usage.py` `run` / `run_app` / `_configure_runtime`

**Interface:**

```python
@dataclass
class RunContext:
    app_mode: bool
    home: str
    now: datetime.datetime
    credentials: dict
    credential_updates: list
    credential_challenges: list
    # paths, http hooks, capabilities, days, timeout
```

- [ ] **Step 1: Existing pytest as baseline (`python3 -m pytest tests/ -q`)**

- [ ] **Step 2: Thread RunContext through collect without changing outputs**

- [ ] **Step 3: pytest full green**

- [ ] **Step 4: Commit**

```bash
git commit -m "refactor(collector): introduce RunContext for per-run state"
```

---

### Task 13: Unified build_quota_services

**Files:**
- Create: `agent-usage/collector/service_catalog.py`
- Modify: `collect_usage.py` — delete duplicate `_collect_app_services` body; both modes call `build_quota_services(ctx)`
- Test: `tests/test_collector_contexts.py`, `tests/test_collector_official.py`, `tests/test_collector_cli.py`

- [ ] **Step 1: Add characterization tests if gaps exist for App vs CLI service ids**

- [ ] **Step 2: Implement catalog; keep note/status strings identical to fixtures**

- [ ] **Step 3:**

```bash
python3 -m pytest tests/ -q
```

- [ ] **Step 4: S4 gate**

```bash
zsh scripts/verify-local.sh
git commit -m "refactor(collector): unify App/CLI quota service building"
```

**S4 done when:** one builder; RunContext in use; expiry dual tests; no UI files changed.

---

## Phase S5 — Panel / Harness / TokenManager

### Task 14: SubscriptionPresentationPolicy + Panel file split

**Files:**
- Create: `SubscriptionPresentationPolicy.swift`, `PanelModels.swift`, `UsageMapping.swift`, `SubscriptionMapping.swift` (names flexible)
- Modify: shrink `PanelViewModel.swift` to re-export or thin mapper entry
- **Do not modify** `Sources/BruceApp/Views/**` bodies

- [ ] **Step 1: Move pure rules into policy with table-driven tests in PanelViewModelHarness**

- [ ] **Step 2: Split files; harness pass count unchanged**

```bash
swift run --package-path macos/BruceApp PanelViewModelHarness
```

- [ ] **Step 3: Commit**

```bash
git commit -m "refactor(panel): extract presentation policy and split view model files"
```

---

### Task 15: Harness file splits (no assertion changes)

**Files:**
- Split sources under `Tests/Harnesses/RefreshSchedulerHarness/` and `Tests/BruceOnboardingCoreHarness/`
- Update `Package.swift` only if new targets; prefer multi-file same target

- [ ] **Step 1: Extract one suite file; main still calls all suites**

- [ ] **Step 2: Run both harnesses — same number of tests**

- [ ] **Step 3: Commit**

```bash
git commit -m "test: split oversized harness sources by scenario"
```

---

### Task 16: CodexTokenManager façade over Resolver + Reducer

**Files:**
- Create: `CodexTokenResolver.swift`, `CredentialStateReducer.swift` under `BruceOnboardingCore`
- Modify: `CodexTokenManager.swift` to delegate
- Test: `CodexTokenManagerTests.swift` + reducer table tests

- [ ] **Step 1: Extract pure state transitions to reducer with tests**

- [ ] **Step 2: Move cache/in-flight to resolver; Manager keeps public API**

- [ ] **Step 3:**

```bash
swift run --package-path macos/BruceApp BruceOnboardingCoreHarness
zsh scripts/verify-local.sh
```

- [ ] **Step 4: Final commit**

```bash
git commit -m "refactor(codex): split token manager into resolver and state reducer"
```

**S5 / campaign done when:** checklist in design §10 is satisfied.

---

## Phase Boundary Checklist (every S*)

```bash
# Layout gate (human): no unintended diff under
git diff main -- macos/BruceApp/Sources/BruceApp/Views/
git diff main -- macos/BruceApp/Sources/BruceApp/SettingsView.swift
# (Settings splits may move lines; reject padding/spacing/frame value changes)

zsh scripts/verify-local.sh
```

---

## Self-Review (plan vs spec)

| Spec section | Tasks |
|--------------|-------|
| S1 RefreshIntent | Task 1–2 |
| S1 CredentialUpdateCoordinator + partial | Task 3–4 |
| S2 Pipeline | Task 5–6 |
| S3 Registry / Service / Settings / Probe | Task 7–10 |
| S4 Expiry / RunContext / unified services | Task 11–13 |
| S5 Panel / Harness / TokenManager | Task 14–16 |
| UI layout freeze | Global + each phase gate |
| Behavior freeze / no new providers | Global |
| verify-local at boundaries | Tasks 4, 6, 10, 13, 16 |

**Placeholder scan:** no TBD/TODO left in task steps.  
**Type consistency:** `RefreshIntent`, `CredentialUpdateApplyResult`, `RefreshPipelineResult` names used consistently across tasks.

---

## Execution Handoff

Plan complete and saved to:

- **Tracked:** `docs/development/10-architecture-remediation-implementation-plan.md`
- **Local mirror (optional):** copy to `docs/superpowers/plans/2026-08-05-architecture-remediation.md` if desired (gitignored)

**Two execution options:**

1. **Subagent-Driven (recommended)** — fresh subagent per task, review between tasks  
2. **Inline Execution** — this session with executing-plans, checkpoints between tasks  

**Which approach?** Start at **Task 1** unless you specify otherwise.
