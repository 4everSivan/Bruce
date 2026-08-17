## 0. Design gate and coordination

- [ ] 0.1 Frontend engineer communicates the UI contract and interaction proposal with Haven Shen; no code change before the design decision is confirmed.
- [ ] 0.2 Haven Shen confirms the Provider header action placement, loading/disabled behavior and whether the recommended scope/merge contract is accepted.
- [ ] 0.3 Coordinator records any requested change as a separate decision item; do not rewrite the existing product design document.

## 1. Swift refresh scope and pipeline (backend/core)

- [ ] 1.1 Add `RefreshScope` and extend `RefreshIntent` merge semantics: same-target dedupe, target union, full refresh precedence.
- [ ] 1.2 Add `refreshSubscription(_:)` and Provider refresh state callbacks to `RefreshScheduler`; preserve capacity, pending, cancellation, backoff and manual notification rules.
- [ ] 1.3 Extend `CollectorRunInputProviding` and `RefreshPipelineRequest` with scope-aware input while keeping full-refresh callers source-compatible.
- [ ] 1.4 Implement scope-aware finalization and `ScopedQuotaSnapshotMerger`; preserve full artifact agents, unrelated services and total cost.
- [ ] 1.5 Keep Codex legacy ID/order/recovery rules and credential rotation semantics unchanged in the targeted path.
- [ ] 1.6 Add `RefreshSchedulerHarness` and merger cases for targeted success, stale fallback, unavailable, duplicate clicks, capacity queue, cancellation and full precedence.

## 2. Bridge and Python collector (backend)

- [ ] 2.1 Add `subscriptionQuotaOnly` and `subscriptionProviders` to Bridge v1 allowlists, request schema and runtime mapping with fail-closed validation.
- [ ] 2.2 Add scope-aware `OnboardingRunInputProvider` credential assembly; only target Provider credentials/meta may cross the Bridge boundary.
- [ ] 2.3 Add quota-only Collector façade and Provider filter; skip local sessions/pricing and keep existing handler/error/credential update behavior.
- [ ] 2.4 Add Python and Bridge contract tests for target isolation, invalid scopes, multi-account output and per-account failures.

## 3. Dashboard UI and wiring (frontend)

- [ ] 3.1 After design approval, add Provider header refresh controls without changing existing card layout, account expansion or window rows.
- [ ] 3.2 Wire `OnboardingCoordinator.refreshSubscription` and observe Provider refresh state separately from credential-operation busy state.
- [ ] 3.3 Implement spinner, disabled states, full-refresh conflict behavior and accessibility labels for single/multi-account Provider sections.
- [ ] 3.4 Add deterministic UI/state coverage or harness assertions for action routing and refresh state presentation.

## 4. Integration and acceptance

- [ ] 4.1 Wire `ApplicationBootstrap` callbacks into `AppModel` and verify artifact cache invalidation after targeted publish.
- [ ] 4.2 Run `python3 -m pytest tests/` and all affected Swift harnesses.
- [ ] 4.3 Run `zsh scripts/verify-local.sh`; record exact output and changed-file evidence.
- [ ] 4.4 Perform manually authorized dashboard acceptance for one configured Provider, one failure/stale case and full-refresh coexistence; do not include secrets in evidence.
- [ ] 4.5 Coordinator produces a requirement-by-requirement acceptance report; final pass remains Haven Shen's decision.
