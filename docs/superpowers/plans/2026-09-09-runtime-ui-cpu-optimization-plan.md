# Bruce UI Runtime CPU Optimization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop hidden or unnecessary Widget and menu-bar animation work while retaining visible motion at a bounded refresh rate.

**Architecture:** Keep the Widget as a single self-contained HTML file, but give its Canvas renderer explicit visibility and interaction states. Move menu-bar summary rendering and refresh-glyph animation onto separate paths so only summary changes invoke `ImageRenderer`; a small AppKit glyph handles rotation independently. Pure scheduling policy lives in `BruceAppCore` so the behavior can be tested without booting the full app.

**Tech Stack:** Swift 6.2, SwiftUI, AppKit, Combine, Core Animation/AppKit views, dependency-free JavaScript Canvas, Node.js built-in test APIs for the Widget harness.

**Spec:** `docs/superpowers/specs/2026-09-09-runtime-cpu-optimization-design.md`

## Global Constraints

- Minimum platform remains macOS 14; the Widget remains a single runtime HTML file.
- Hidden, non-visible, reduced-motion, or disabled Widget states must not create a continuous animation loop.
- Visible Widget animation is retained and limited to 4-8 fps; the interactive burst ends 400ms after the last pointer event.
- Menu-bar animation ticks must not call the complete `ImageRenderer` path.
- Artifact fields, refresh cadence, accessibility wording, credential ownership, and panel behavior remain unchanged.
- Tests use synthetic model state and fake DOM/scheduler objects; no real session, Keychain, network, or live Collector run is required.

---

## File Map

- Create: `macos/BruceApp/Sources/BruceAppCore/MenuBarRenderPolicy.swift` — pure menu-bar render key, coalescing, and animation-rate policy.
- Create: `macos/BruceApp/Sources/BruceApp/MenuBarRefreshGlyphController.swift` — AppKit-only small glyph attachment and rotation.
- Modify: `macos/BruceApp/Sources/BruceApp/MenuBarStatusItemController.swift` — consume the policy, coalesce summary renders, and stop passing rotation into full SwiftUI rendering.
- Modify: `macos/BruceApp/Sources/BruceApp/MenuBarViews.swift` — make `MenuBarLabelView` render a stable base label while the glyph controller owns refresh motion.
- Modify: `macos/BruceApp/Package.swift` — register the performance-policy harness target.
- Create: `macos/BruceApp/Tests/Harnesses/PerformancePolicyHarness/PerformancePolicyHarness.swift` — test pure render/coalescing decisions.
- Modify: `agent-usage/widget/index.html` — implement the Widget visibility/interaction state machine and bounded scheduler.
- Create: `scripts/widget-performance-harness.mjs` — run the Widget renderer in a fake DOM and assert scheduling behavior.

## Task 1: Add a testable menu-bar render policy

**Files:**
- Create: `macos/BruceApp/Sources/BruceAppCore/MenuBarRenderPolicy.swift`
- Modify: `macos/BruceApp/Package.swift`
- Create: `macos/BruceApp/Tests/Harnesses/PerformancePolicyHarness/PerformancePolicyHarness.swift`

**Interfaces:**
- Produces `MenuBarRenderSnapshot(summaryKey:isRefreshing:)` with `Equatable` and `Sendable` conformance.
- Produces `MenuBarRenderCoalescer.request() -> Bool` and `MenuBarRenderCoalescer.consume()` for one-pending-render semantics.
- Produces `MenuBarRenderPolicy.summaryNeedsRender(previous:current:) -> Bool` and `MenuBarRenderPolicy.animationIntervalSeconds -> Double`.

- [ ] **Step 1: Write failing policy tests**

Add a harness test with these exact invariants:

```swift
let unchanged = MenuBarRenderSnapshot(summaryKey: "Bruce, 100 tokens", isRefreshing: false)
let refreshing = MenuBarRenderSnapshot(summaryKey: "Bruce, 100 tokens", isRefreshing: true)
let changed = MenuBarRenderSnapshot(summaryKey: "Bruce, 200 tokens", isRefreshing: false)

try expect(MenuBarRenderPolicy.summaryNeedsRender(previous: nil, current: unchanged))
try expect(!MenuBarRenderPolicy.summaryNeedsRender(previous: unchanged, current: refreshing))
try expect(MenuBarRenderPolicy.summaryNeedsRender(previous: unchanged, current: changed))
try expect(MenuBarRenderPolicy.animationIntervalSeconds >= 0.125)

let coalescer = MenuBarRenderCoalescer()
try expect(coalescer.request())
try expect(!coalescer.request())
coalescer.consume()
try expect(coalescer.request())
```

The harness must fail to compile because the policy types do not exist yet.
Define the harness-local HarnessFailure error and expect(_:_:) helper used by
the examples, so the executable target does not depend on XCTest.

- [ ] **Step 2: Run the focused harness and verify failure**

Run:

```bash
swift run --package-path macos/BruceApp PerformancePolicyHarness
```

Expected: compilation failure naming the missing policy types or target.

- [ ] **Step 3: Implement the pure policy and register the target**

Implement the narrow API without AppKit dependencies:

```swift
package struct MenuBarRenderSnapshot: Equatable, Sendable {
    package let summaryKey: String
    package let isRefreshing: Bool

    package init(summaryKey: String, isRefreshing: Bool) {
        self.summaryKey = summaryKey
        self.isRefreshing = isRefreshing
    }
}

@MainActor
package final class MenuBarRenderCoalescer {
    private var pending = false

    package init() {}

    package func request() -> Bool {
        guard !pending else { return false }
        pending = true
        return true
    }

    package func consume() {
        pending = false
    }
}

package enum MenuBarRenderPolicy {
    package static let maximumAnimationFPS = 8.0
    package static var animationIntervalSeconds: Double {
        1.0 / maximumAnimationFPS
    }

    package static func summaryNeedsRender(
        previous: MenuBarRenderSnapshot?,
        current: MenuBarRenderSnapshot
    ) -> Bool {
        previous?.summaryKey != current.summaryKey
    }
}
```

Add an executable target named `PerformancePolicyHarness` with path `Tests/Harnesses/PerformancePolicyHarness` and dependency `BruceAppCore`.

- [ ] **Step 4: Run the focused harness and verify success**

Run:

```bash
swift run --package-path macos/BruceApp PerformancePolicyHarness
```

Expected: all policy assertions pass and the harness prints a passing count.

- [ ] **Step 5: Commit the policy boundary**

```bash
git add macos/BruceApp/Package.swift \
  macos/BruceApp/Sources/BruceAppCore/MenuBarRenderPolicy.swift \
  macos/BruceApp/Tests/Harnesses/PerformancePolicyHarness/PerformancePolicyHarness.swift
git commit -m "test(ui): add menu bar render policy boundary"
```

## Task 2: Gate and throttle the Widget pixel field

**Files:**
- Modify: `agent-usage/widget/index.html:411-512,594-612`
- Create: `scripts/widget-performance-harness.mjs`

**Interfaces:**
- `KimiPixelField.mount()` continues to return `render()` and `destroy()`.
- The returned controller additionally provides `setVisible(visible: boolean)` and `setInteractive(active: boolean)`.
- Pointer events call `setInteractive(true)` and schedule the existing 400ms post-leave return to static mode.
- `setVisible(false)` cancels every pending timeout/frame and immediately renders the static layer once.

- [ ] **Step 1: Write the fake-DOM scheduling test**

Create a dependency-free Node harness that extracts the first `Kimi Pixel Field renderer` script from `index.html`, supplies a fake canvas/container, and records calls to `requestAnimationFrame`, `cancelAnimationFrame`, `setTimeout`, `clearTimeout`, and `getBoundingClientRect`.

The assertions must cover the public controller contract:

```js
const field = window.KimiPixelField.mount(container, { driftSpeed: 16 });
assert.equal(scheduler.pendingAnimationCount(), 0, 'mount must stay static while invisible');

field.setVisible(true);
assert.equal(scheduler.lastTimeoutDelay(), 125, 'visible animation is capped at 8 fps');

field.setVisible(false);
assert.equal(scheduler.pendingCount(), 0, 'hiding cancels all animation work');

field.setInteractive(true);
assert.equal(scheduler.frameRequests(), 1, 'interaction may request one immediate frame');
field.destroy();
assert.equal(scheduler.pendingCount(), 0, 'destroy releases every scheduled callback');
```

Use `node:assert`, `node:fs`, and `node:vm` only; do not add a package dependency.

- [ ] **Step 2: Run the Widget harness and verify the current failure**

Run:

```bash
node scripts/widget-performance-harness.mjs
```

Expected: the current implementation fails because `mount()` starts a continuous rAF when `driftSpeed` is non-zero and does not expose visibility controls.

- [ ] **Step 3: Add explicit motion state and bounded scheduling**

Replace the unconditional animation branch with state-driven scheduling. The implementation must follow this shape:

```js
let visible = false;
let interactive = false;
let visibleTimer = 0;
let interactionTimer = 0;

function motionAllowed() {
  return !destroyed && !reduced && Number(config.driftSpeed) > 0;
}

function scheduleVisibleTick() {
  if (!visible || interactive || !motionAllowed() || visibleTimer) return;
  visibleTimer = global.setTimeout(() => {
    visibleTimer = 0;
    draw(performance.now());
    scheduleVisibleTick();
  }, 125);
}

function stopMotion() {
  if (frame) global.cancelAnimationFrame(frame);
  if (visibleTimer) global.clearTimeout(visibleTimer);
  if (interactionTimer) global.clearTimeout(interactionTimer);
  frame = visibleTimer = interactionTimer = 0;
}
```

`setVisible(false)` must call `stopMotion()` and `draw()` once. `setVisible(true)` must call `scheduleVisibleTick()`. Pointer interaction may use one rAF for immediate feedback, then return to the 125ms visible loop or static mode. `ResizeObserver` may still rebuild geometry, but rebuild must not restart animation while `visible` is false.

Move `getBoundingClientRect()`, computed color, and font initialization out of `draw()` wherever the cached geometry remains valid. A resize or style change may invalidate those cached values.

- [ ] **Step 4: Connect visibility and interaction events**

Inside `mount()`:

- Observe `document.visibilityState` through `visibilitychange`.
- Observe the pixel stage with `IntersectionObserver` when available.
- Use `setVisible(document.visibilityState === "visible" && isIntersecting)` as the animation gate.
- Make pointer move set `interactive=true`; pointer leave clears it after exactly 400ms and calls `scheduleVisibleTick()` if the stage remains visible.
- Make `destroy()` remove both visibility/intersection listeners and call `stopMotion()` before removing the canvas.

- [ ] **Step 5: Run Widget tests and syntax checks**

Run:

```bash
node scripts/widget-performance-harness.mjs
node --check scripts/widget-performance-harness.mjs
```

Expected: static, hidden, visible-throttled, interaction, and destroy assertions pass.

- [ ] **Step 6: Commit the Widget change**

```bash
git add agent-usage/widget/index.html scripts/widget-performance-harness.mjs
git commit -m "perf(widget): gate pixel animation by visibility"
```

## Task 3: Separate static menu-bar rendering from refresh glyph animation

**Files:**
- Create: `macos/BruceApp/Sources/BruceApp/MenuBarRefreshGlyphController.swift`
- Modify: `macos/BruceApp/Sources/BruceApp/MenuBarViews.swift:20-70`
- Modify: `macos/BruceApp/Sources/BruceApp/MenuBarStatusItemController.swift:29-207`
- Test: `macos/BruceApp/Tests/Harnesses/PerformancePolicyHarness/PerformancePolicyHarness.swift`

**Interfaces:**
- `MenuBarRefreshGlyphController.attach(to:)`, `setVisible(_:)`, `advance()`, and `detach()` are `@MainActor` AppKit operations.
- `MenuBarStatusItemController` owns one glyph controller and one `MenuBarRenderCoalescer`.
- `refreshLabelImage(on:)` renders a stable `MenuBarLabelView(model:)` without `refreshRotation`.
- `MenuBarStatusItemController` creates a `MenuBarRenderSnapshot` whose `summaryKey` is the current accessibility summary; refresh-state changes show/hide the glyph without invalidating the summary image.

- [ ] **Step 1: Add a failing coalescing regression test**

Extend the policy harness to prove that refreshing state alone does not request a summary render, while content changes do:

```swift
let before = MenuBarRenderSnapshot(summaryKey: "Bruce, 10 tokens", isRefreshing: false)
let during = MenuBarRenderSnapshot(summaryKey: "Bruce, 10 tokens", isRefreshing: true)
let after = MenuBarRenderSnapshot(summaryKey: "Bruce, 11 tokens", isRefreshing: true)

try expect(!MenuBarRenderPolicy.summaryNeedsRender(previous: before, current: during))
try expect(MenuBarRenderPolicy.summaryNeedsRender(previous: during, current: after))
```

Run the harness before implementation and verify the new assertion fails if the policy does not distinguish the keys.

- [ ] **Step 2: Implement the AppKit glyph controller**

Use an `NSImageView` attached to the existing `NSStatusBarButton`. The controller must keep the button's static image untouched and rotate only the glyph layer:

```swift
@MainActor
final class MenuBarRefreshGlyphController {
    private var imageView: NSImageView?
    private var rotation: CGFloat = 0

    func attach(to button: NSStatusBarButton) {
        let image = NSImage(
            systemSymbolName: "arrow.clockwise",
            accessibilityDescription: nil
        )
        image?.isTemplate = true
        let overlay = NSImageView(image: image)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.imageScaling = .scaleProportionallyUpOrDown
        overlay.wantsLayer = true
        button.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.widthAnchor.constraint(equalToConstant: 16),
            overlay.heightAnchor.constraint(equalToConstant: 16),
            overlay.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            overlay.centerYAnchor.constraint(equalTo: button.centerYAnchor)
        ])
        imageView = overlay
    }
    func setVisible(_ visible: Bool) { imageView?.isHidden = !visible }
    func advance() {
        rotation = (rotation + 30).truncatingRemainder(dividingBy: 360)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageView?.layer?.setAffineTransform(.init(rotationAngle: rotation * .pi / 180))
        CATransaction.commit()
    }
    func detach() { imageView?.removeFromSuperview(); imageView = nil }
}
```

Configure the overlay as a template `arrow.clockwise` image, disable implicit layout-driven animation, and preserve the existing accessibility label on the status button.

- [ ] **Step 3: Make the base SwiftUI label static**

Remove the `refreshRotation` input from `MenuBarLabelView` and its `MenuBarRefreshIcon` rotation path. Keep the same metric text, attention symbol, font, spacing, and accessibility summary. The base label always renders the brand icon; the AppKit glyph overlays it only during refresh.

- [ ] **Step 4: Coalesce summary renders in the controller**

Replace the current per-event `Task { refreshLabelImage() }` body with a single pending render task:

```swift
private func requestSummaryRender() {
    guard renderCoalescer.request() else { return }
    Task { @MainActor [weak self] in
        guard let self else { return }
        defer { renderCoalescer.consume() }
        refreshLabelImage()
    }
}
```

The `objectWillChange` subscription calls `requestSummaryRender()` and separately calls `synchronizeRefreshAnimation()`. `advanceRefreshAnimation()` must call only `glyphController.advance()`. It must not call `refreshLabelImage()`.

Use `MenuBarRenderPolicy.animationIntervalSeconds` for the timer interval, and invalidate the timer plus hide the glyph when refreshing ends or during teardown.

- [ ] **Step 5: Run Swift build and focused harnesses**

Run:

```bash
swift build --package-path macos/BruceApp
swift run --package-path macos/BruceApp PerformancePolicyHarness
swift run --package-path macos/BruceApp AppModelCacheHarness
swift run --package-path macos/BruceApp PanelViewModelHarness
```

Expected: the package builds, render-policy tests pass, menu-bar summary cache tests remain passing, and no artifact/view-model wording changes appear.

- [ ] **Step 6: Commit the menu-bar rendering change**

```bash
git add macos/BruceApp/Sources/BruceApp/MenuBarRefreshGlyphController.swift \
  macos/BruceApp/Sources/BruceApp/MenuBarViews.swift \
  macos/BruceApp/Sources/BruceApp/MenuBarStatusItemController.swift \
  macos/BruceApp/Tests/Harnesses/PerformancePolicyHarness/PerformancePolicyHarness.swift
git commit -m "perf(ui): render menu bar refresh glyph independently"
```

## Task 4: Perform the UI runtime acceptance profile

**Files:**
- Read: `scripts/build-test-app.sh`
- Read: `docs/superpowers/specs/2026-09-09-runtime-cpu-optimization-design.md`
- No source modification required.

**Interfaces:**
- Uses the built `dist/Bruce.app` and the Widget test harness from Task 2.
- Produces a local, non-committed profile record with process name, scenario, average CPU, CPU time, and render-loop observations.

- [ ] **Step 1: Build the test app**

Run:

```bash
zsh scripts/build-test-app.sh
```

Expected: `dist/Bruce.app` is produced and the script's existing signing checks pass.

- [ ] **Step 2: Verify static states before profiling**

Run:

```bash
node scripts/widget-performance-harness.mjs
swift run --package-path macos/BruceApp PerformancePolicyHarness
```

Expected: hidden/destroyed Widget states have zero pending callbacks and the menu-bar policy enforces the 8 fps ceiling.

- [ ] **Step 3: Profile four explicit scenarios**

Use Instruments Time Profiler and Activity Monitor for:

1. Bruce idle with the dashboard panel closed.
2. Bruce dashboard panel open.
3. Bruce during a synthetic refresh.
4. The Widget host process with the Widget hidden and visible.

Record whether hidden states have a sustained animation callback, whether menu-bar animation ticks invoke `ImageRenderer`, and the before/after CPU time. Do not use real credentials for this profile.

- [ ] **Step 4: Record the acceptance result**

Keep the profile outside Git or in the existing local benchmark output directory. Mark this plan's UI phase accepted only when hidden/invisible states have no continuous loop, visible animation is at most 8 fps, and the menu-bar animation path does not rasterize the complete label.
