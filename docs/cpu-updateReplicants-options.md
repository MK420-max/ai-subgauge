# macOS 27 update storm investigation

Baseline: branch `macos26-support`, commit `3004a15`. No release or host app replacement is part of this change.

## Evidence and root cause

A supplied sample file records macOS 27.0.1, app 2.0.2 (202). Lines 24–32 show 2,456 main-thread samples, 1,257 in `closure #1 in closure #1 in AIUsageMenuBarController.update()`, including 319 in `QuotaMenuImage.bitmapImage`. Lines 4,102 onward show delayed `_updateReplicants`; lines 9,315–9,317 show 389 worker samples in `MenuEngine.refresh`, including 181 in scanner AX reads. Sample counts measure time, not invocation counts.

The closure defined inside `update()` is the button's `effectiveAppearance` KVO callback. At **baseline** `mac/Sources/TidyBar/AIUsageMenuBar.swift:219–224`, every callback enqueues a main-actor task, clears `lastRenderKey`, then calls `update()`. Clearing the key forces a new bitmap and button image assignment even when the effective appearance name and quota inputs are identical. The sampled closure identifies this callback as the dominant update source. Repeated AppKit appearance notifications therefore defeat the cache and sustain image/replicant work. The exact internal AppKit operation emitting each KVO callback is not identified by the asynchronous sample.

Baseline lines 228–239 already compute and compare the render key **before** calling `bitmapImage`. The failure is unconditional invalidation in the appearance callback. Moving bitmap code alone would leave this loop intact.

## Every update source

| Source | Baseline behavior | Current behavior |
| --- | --- | --- |
| Button `effectiveAppearance` | Every KVO notification clears the pixel cache and starts a task | Compare appearance names before scheduling; retain pixel cache; real name changes are already part of the render key |
| `running.$active` → `store.runningProviders` | Assigns on every publication | `removeDuplicates` plus equality guard before store assignment; `RunningAIStore.poll()` already guards equal sets (`RunningProcesses.swift:135–137`) |
| `store.$runningProviders` | One task per publication, including equal sets | `removeDuplicates`, then one pending update |
| `store.$snapshots` | One task per publication, including equal arrays | `removeDuplicates`, then one pending update; metadata changes still refresh tooltip/panel |
| `UserDefaults.didChangeNotification` | Every defaults write starts an update task | Compare effective display preferences first; unrelated writes and refresh-interval-only changes do not schedule menu updates |
| 30-second tooltip/staleness timer | Direct update task | Coalesced request; one-second timer tolerance |
| Menu selection/reset/always-show actions | Direct update plus defaults notification | Coalesced request; notification joins the same pending update |
| Startup | Immediate update plus publisher initial emissions | Immediate first render; initial publisher requests collapse and cannot regenerate equal pixels |

`AIUsageMenuBarUpdates` holds at most one pending 25 ms task. It reads the latest store values when it runs. Stop cancels pending work and resets the key. Its image gate returns before executing the renderer for an equal key, and stores a new key before rendering. `image` is assigned only for changed pixel inputs; existing equality guards on `length`, tint and tooltip remain. Autosave name, visibility and button configuration are assigned only when creating the status item.

## Defaults and persistence audit

The audit covers `UserDefaults`, `.set(...forKey:)`, `removeObject(forKey:)`, `@AppStorage`, `autosaveName`, preferred-position keys, and the refresh/scanner/shim path under `mac/Sources`.

| Writer | Trigger / feedback relevance |
| --- | --- |
| `AIUsageMenuBar.swift` preferred position | Seeds `NSStatusItem Preferred Position <bundle>.ai-usage` only when absent. Not a repeated explicit write. AppKit can persist its own position/visibility defaults after status-item changes; those values are excluded from display preference comparison. |
| `App.swift` status-item autosave names | Main item created once; group/spacer items rebuilt only when their configuration signature changes. Expansion image subscription already uses `removeDuplicates`. |
| `Widgets.swift` autosave names/render | Names assigned on widget creation. Widgets update on configuration/data changes or a 15-second timer; they do assign equal titles/images, but have no subscription back from quota updates/defaults notifications. Their defaults traffic is now ignored by the quota observer. |
| `SubscriptionPreferences.swift` | Explicit user reorder/hide writes. Color/refresh and quota display/percentage/placement are written by `@AppStorage` in settings/popover/arc views. Compare normalized order, hidden set, effective booleans, placement and interval. |
| `RunningProcesses.swift`, quota menu actions | Explicit selection override writes/removal and `AlwaysShowAll` toggle. Both values are included in the display snapshot. |
| `MenuEngine.swift` bookmark writes | User file grant writes a bookmark; `refresh()` → `markMovability()` → `grantedURL()` can refresh a stale bookmark. Added `fresh != bookmark` guard before persisting. Fresh/stale bookmark values are excluded from quota preferences. |
| `MenuEngine.swift` backup path | Written after a requested layout change, not by ordinary scanning. Excluded from quota preferences. |
| `SettingsStore` (`Models.swift`) | Persists `settings.json` when `config` changes. `refresh()` does not assign `config`. This is file persistence, not UserDefaults. |
| `MenuEngine` diagnostics | Collection and access diagnostics write files and already compare state/data before writing. They do not publish quota snapshots or change status-item image/length. |
| `ThemeController` | Previously every defaults notification reapplied theme and assigned the application icon. Now filter by effective theme before main-queue delivery, dedupe effective appearance names, and assign the icon only when light/dark actually changes. Removes another defaults-to-AppKit invalidation path. |
| `ProviderLoginConsent.swift`, `ClaudeWebConnection.swift` | Explicit consent and remembered web-profile flags. Excluded from quota presentation comparison. |
| `AppMigration.swift`, `App.swift` startup flag | Migration markers and `hasOpenedSettings`; startup/user paths only. Excluded. |
| Settings language/theme `@AppStorage` | Theme is included. Language is resolved at launch (`Localization.swift`), so a live quota update cannot apply a new language. |

`AIUsageStore.start()` previously reacted to every defaults notification with `objectWillChange` and a refresh-scheduling check. It now observes the same filtered preference state, including the effective refresh interval, so autosave/bookmark writes cannot repeatedly invalidate subscribed SwiftUI views.

## MenuEngine and own frames

`MenuEngine.swift:130–141` schedules scans for workspace changes/startup and every five seconds. `refresh()` has a `scanning` guard before worker dispatch. It publishes accessibility, busy state, items, status and active-menu state, then applies visibility; those publications do not feed `AIUsageMenuBarController.update()`.

`currentOwnStatusFrames()` reads the status-item frames. `refresh()` copies them into `scanner.ownStatusFrames` for hosted-window identification. `MenuScanner` excludes the current process before self AX reads. Neither operation mutates NSStatusItem properties. `applyVisibility()` compares desired/applied bundle sets before invoking the collection shim. No self-triggered scan loop or repeated app status-item setter was found in this path. Retain scan timing and collection behavior; the supplied worker sample does not establish a refresh storm.

## Verification and remaining device check

Regression tests use offscreen views and synthetic snapshots/defaults: equal and reentrant keys never invoke the renderer; repeated same-name appearance KVO is ignored; real appearance changes propagate; 200 requests collapse and read the latest input; reset cancels/restarts correctly; autosave/bookmark writes and repeated equal preferences are filtered; every relevant preference still propagates; interval-only changes do not request a menu redraw.

Full suite result: **376 tests in 19 suites, zero failures, eight pre-existing opt-in skips**, completed in 29.280 seconds. All five new regression tests passed. The existing refresh-preference rescheduling test also passed. Output: `mac/.build/cpu-full-tests.log` (ignored build output).

Run from `mac`:

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/test-build/ModuleCache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/test-build/ModuleCache" \
swift test --disable-sandbox --scratch-path "$PWD/.build/test-build"
```

The original command was attempted first. This environment requires module caches under the scratch path and `--disable-sandbox` because the outer sandbox blocks the default user cache and nested `sandbox-exec`. These adjustments do not disable the outer filesystem restrictions.

CPU improvement on macOS 27 remains a device acceptance check: sample the changed build after startup and after quota/theme/percentage changes, with and without collection enabled. Verify the appearance callback/render frames disappear from steady-state hot stacks and ordinary scans remain periodic.

No large redesign is needed for the identified feedback path. If a fresh sample still shows `_updateReplicants` dominating with stable inputs and no app image assignments, options for a separate measured change are: (1) isolate macOS 27 collection replication with collection disabled, then adjust shim activation only if implicated; (2) replace the quota button image with a fixed-size view only if repeated system snapshots remain expensive. Both change broader behavior and are deferred pending that evidence.
