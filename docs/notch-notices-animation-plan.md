# Notch notices & notifications: animation plan (inspired by Atoll)

Source: https://github.com/Ebullioscopic/Atoll (cloned to `/tmp/Atoll` for inspection).
Method: `layers-interaction-flow` breadboarding + `ponytail/full` minimalism
(reuse SwiftUI native animation + existing queue/store, no new dependencies).

**License guardrail (important):** Atoll is GPL-3.0; we are MIT (Atoll targets
macOS 15 per `DynamicIsland.xcodeproj/project.pbxproj`; we target macOS 14 per
`Package.swift`). This plan reimplements *patterns and timing values* with native
SwiftUI — it copies no Atoll code, and every token below is gated on macOS 14
API availability (see §6).

**Review provenance:** doubt-driven cycles 1–3 folded in (30 + 24 + 20 findings;
cycle 3 found one noise item — reviewer's claim that single-arg
`.interactiveSpring(dampingFraction:)` doesn't exist is wrong; Atoll compiles it
at `ContentView.swift:700,1147,1150` — and is otherwise fully applied). Cycle 3
closed: collapse-completion mechanics, state-owner isolation/fields, per-site
Reduce Motion table, queue-math edge cases, producer reality per table row,
keyboard/AX mechanics, P0b split, per-phase exit criteria. This is the final
doubt cycle per the 3-cycle bound.

## 1. What Atoll gives us (inventory)

**State machine** (`DynamicIslandViewCoordinator.swift`, `DynamicIslandViewModel.swift`):
- `NotchState` closed/open; tabbed open views; two transient layers over the closed notch:
  - **Sneak peek** — small auto-hiding banner. 15 content types; per-type durations
    (default 1.5s, timer 10s, reminder configurable, caps-lock infinite/persistent).
    Two styles: `standard` (centered strip under the notch) and `inline`
    (content split into left/right "wings" beside the notch).
  - **Expanding view** — larger takeover for battery/downloads/music/timer,
    ~3s auto-hide (macOS 14, safe).
- Tab switch: directional asymmetric `move+opacity` (forward = insert trailing/remove
  leading, backward mirrored), `.smooth(0.3)` (macOS 14, safe).
- Closed-notch live swap: asymmetric insertion `opacity+scale(0.965)` with
  `spring(0.34, 0.88)` / removal `opacity+scale(0.92)` with `.smooth(0.22)`
  (macOS 14, safe).
- Consecutive transient swaps: Atoll uses `.blurReplace` +
  `.interactiveSpring(dampingFraction: 1.2)` (`ContentView.swift:700,1147,1150`) —
  the spring form is fine but `blurReplace` is **macOS 15+ only, excluded**. Our
  substitute: `.opacity.combined(with: .scale)` +
  `.interactiveSpring(dampingFraction: 1.2)` (macOS 14, safe).
- Value changes: `.contentTransition(.numericText())` (macOS 14, safe).
  `.contentTransition(.interpolate)` and `.contentTransition(.symbolEffect)` are
  **macOS 15+ only, excluded**; for SF-symbol swaps use `.opacity` content
  transitions and `Image.symbolEffect(.bounce, value:)` / `.pulse` (macOS 14,
  must-confirm exact effect availability in proof) instead.
- Shared-element continuity: Atoll's `albumArt` id spans open↔closed as a hero
  element (closed `MusicLiveActivity` branch shares id+namespace with open-only
  `NotchHomeView`); only the capsule/pill ids are intra-hierarchy.
  **Rejected for us unconditionally**: our compact row and expanded details render
  simultaneously, so shared ids would be visible duplicates (undefined behavior).
- Window/frame: Atoll resizes synchronously only on its open path
  (`ensureWindowSize(animated:false, force:true)`); in-flight dynamic resizes use
  `animated:true`. Our discipline stays stricter: sync `setFrame` always, animate
  content only (see §6 for the collapse-ordering rule this forces).
- Corner-radius morphing is **not transferable as stated**: Atoll morphs top+bottom
  radii with shadow padding outside the clip. Our mask is a single `.rect` clip with
  bottom radii only (10→24). Scope: animate bottom-corner radius 10→24 on the
  existing clip; top radius and shadow padding explicitly out of scope. Whether
  `UnevenRoundedRectangle` radii animate on macOS 14 is must-confirm-in-proof;
  fallback is crossfading containers.
- Atoll disables implicit `notchState` animation on its root container
  (`.animation(nil, value:)` in `ContentView.swift`); no lock-screen-specific
  `.none` close exists.

**Micro-interactions:** press-scale buttons (`spring(0.3, 0.3)` → 0.9, macOS 14
safe); segmented progress with spring wave + glow stagger on change; marquee text
*only* when text overflows its frame; 0.8s pulse for live states (transient-only,
see §9 energy rule); trim-path "hello" draw-on for first launch. Not adopted:
cursor-tracked 3D parallax, looping `.mov` icons (energy/scope), and haptics —
`sensoryFeedback` compiles on macOS 14 but is a no-op on Mac hardware (no Taptic
Engine); no sound substitute unless explicitly requested later.

## 2. What we have today

- `Sources/CodexBar/NotchUsageView.swift`: compact row (≤3 provider chips + unread
  badge), yellow notification banner row, expanded USAGE/ALERTS panel.
  **Deliberately zero animation** ("respects Reduce Motion, hit region = visible bounds").
- `Sources/CodexBar/NotchNotifications.swift`: agent-event queue — 10s active window,
  strict FIFO pending (cap 50), retained list (cap 50), unread count; file-tailed
  from Notchly hooks (claude/codex/cursor × completed/failed/waiting/access_request).
  Events carry no severity: `notification(from:)` parses `type`, uses it only for
  the fallback title, then discards it. (P0b-i replaces FIFO pending with
  severity-lane-ordered pending; §2 FIFO describes today, not the target.)
- `Sources/CodexBar/NotchUsageController.swift` + `Sources/CodexBar/NotchGeometry.swift`:
  borderless panel (`.fullScreenAuxiliary` — already shows over fullscreen),
  sync `setFrame`, hover expand 220ms / collapse 400ms, Escape dismiss via
  `cancelOperation` (requires key), menu-tracking guard. Every render replaces
  `NSHostingView.rootView` with a brand-new view (destroys view identity, `@State`,
  and in-flight transitions) — see §6 P0a. Concurrency: `Task.sleep`+cancel is the
  file's precedent; package enables StrictConcurrency.
- Other notice channels: `AppNotifications` (OS banners: quota depleted/restored,
  Codex reset-credit expiry, login failures), centered click-through
  `QuotaWarningAlertOverlayController` (4.5s; owns the repo's Reduce Motion +
  appear-animation precedent: `@Environment(\.accessibilityReduceMotion)` +
  `appeared` `@State` + `spring(0.4, 0.8)` — note each show builds a FRESH
  hosting view, so its `@State` resets per show), menu-bar incident badges + icon
  overlays, inline refresh-failure labels. Login failures surface as modal
  `NSAlert` (`presentLoginAlert`), NOT as events — see §4 table note.

## 3. Job stories

1. **Agent glance** — "When my agent completes/fails/waits, I want to notice it
   within seconds without losing focus, so I can look now or later."
2. **Quota guard** — "When quota depletes/warns or credits near expiry, I want an
   unmissable-but-dismissible signal with a path to details."
3. **Catch-up** — "When I return, retained alerts + unread count show me what I
   missed; nothing vanishes silently."

## 4. Proposed presentation tiers

| Tier | Form | Atoll source | Used for |
|---|---|---|---|
| T0 Closed live activity | Icon + `numericText` % swaps in compact row; static pending marker for unresolved states, IF age-out wins §8.5 (pulse only while its T1/T2 is on screen); if persist wins, the T0 marker persists and the persist class is exempt from dwell caps | closed swap transition | Usage % changes, `waiting`/`access_request` pending marker |
| T1 Sneak peek | Centered banner, auto-hide, per-type duration; `opacity+scale` swaps between consecutive items; marquee long titles | sneak peek standard (+inline wings as option) | `completed`/`failed` (10s keep), quota restored, credit-expiry nudge |
| T2 Expanding notice | Taller takeover + actions (Details / Dismiss), longer dwell; clickable without activation (existing `acceptsFirstMouse` precedent); never activates another app, becomes key only via explicit click or the §5 menu item | expanding view | Quota depleted, `access_request`, login failure (once P3 builds its producer) |
| T3 Expanded tabs | USAGE / ALERTS with directional tab transitions; retained list; badge pop | tab switch | Catch-up, details, history |

**Severity routing table (P0b-i exit artifact — literal, not aspirational):**

| Event | Lane | Tier | Shape (SF symbol) | Label |
|---|---|---|---|---|
| agent `completed` | info | T1 | `checkmark.circle` | "Done" |
| agent `waiting` | warning | T1 (+T0 marker) | `ellipsis.circle` | "Waiting" |
| agent `failed` | warning | T1 | `exclamationmark.triangle` | "Failed" |
| agent `access_request` | critical | T2 | `questionmark.circle` | "Needs approval" |
| quota depleted | critical | T2 | `exclamationmark.octagon` | "Limit reached" |
| quota threshold warning (`QuotaWarningEvent`) | warning | T1 | `gauge.with.dots.needle.50percent` | "Running low" |
| predictive pace warning (`PredictivePaceWarningEvent`) | warning | T1 | `gauge.with.dots.needle.50percent` | "Running low" |
| quota restored | info | T1 | `checkmark.circle` | "Restored" |
| credit expiry | warning | T1 | `hourglass` | "Expiring" |
| login failure | critical | T2 | `person.crop.circle.badge.xmark` | "Sign-in failed" |

Table notes: "quota warning" is split — threshold warnings route to T1; predictive
pace routes to T1 as well (overnight default — same lane as threshold warnings;
confirm in morning). The login-failure row requires a NEW producer
(today a modal `NSAlert`, not an event) — it is EXCLUDED from the P0b-i exit
artifact and its producer construction is explicit P3 scope.

**Queue policy (new, small):** severity lanes info < warning < critical.
Tier durations: T1 base 10s (keeps the current contract), T2 base 15s.
Floors: no T1 reshow shorter than 5s, no T2 reshow shorter than 10s.
- Fairness: after 2 consecutive *fresh* critical shows, show the oldest pending
  info/warning next (fairness selection scans lanes; pending is lane-ordered, see
  below). Consecutive counts fresh shows only (reshows excluded); any info/warning
  show resets to 0; queue-empty reset is mechanical: the counter resets to 0 inside
  `advance()` when it finds `pending` empty after retaining active (P0b-ii unit-test
  case). While the counter is at the bound AND an info/warning is pending, new
  criticals queue instead of preempting, so the owed item is actually served
  next. Max 4 preemptions per sliding 60s window.
- Caps: a banner shows only if under BOTH the fairness cap and the frequency cap
  (max 3 banners/min/provider, tracked via per-provider sliding-window timestamps —
  new queue state). Single overflow path: overflowed items skip the banner and go
  to retained (merged per the coalescing rule) + unread++; when both caps trip,
  attribute to the first-tripped cap for telemetry. P0b-ii logs cap-trip counts
  per provider (debug log, existing `CodexBarLog` pattern) for tuning.
- Preemption math: store `remaining: TimeInterval` on preempt as
  `activeUntil − now` (clamped to ≥1s); reshow duration = max(remaining, tier
  floor); repeated preempts reuse the stored value, never recompute; total dwell
  across preemptions capped at 2× the tier base (T1 20s, T2 30s) — if §8.5 persist
  wins, the persist class is exempt from floors and the 2× cap.
- Coalescing: only identical provider+type+title. `count: Int = 1` on the model,
  `title ×N` in the banner, single retained entry preserving N. Check order in
  `enqueue`: identical-to-active merges FIRST (before caps), so a storm against
  the live banner bumps its count and never overflows; overflow-to-retained
  merges into an identical retained entry (bumping N) before appending.
  Different titles/messages queue as distinct items.
- Unread: a preempted item increments unread at most once per enqueue — on first
  expiry/retention only; reshow after preemption never double-counts. Preempted
  items reinsert into pending in severity-lane order (criticals ahead of warnings
  ahead of infos, FIFO within lane) — pending is a lane-ordered structure from
  P0b-i on, selected by lane scan, not head-take. Items evicted from pending
  (cap 50) increment unread once on eviction — nothing vanishes silently.
- While expanded: never preempt — freeze the active countdown, queue arrivals to
  pending, badge++ immediately, resume the frozen countdown on collapse (Atoll
  suppression-token pattern). Freeze extends wall-clock dwell: cap total frozen
  time at 60s, after which the item retains + unread++ even if still expanded;
  freeze-cap retention clears `active`/`activeUntil` and stashes nothing — the item
  is fully dead (no reshow, no second unread++); collapse starts the next pending
  item fresh. P0b-ii amends the "complete ten-second window" doc comment to state
  the freeze exception. Arrivals while expanded enqueue + badge++ via badge-only
  update — they must not touch the expiry task or re-render the banner.

## 5. Breadboard

```
Compact notch (closed)
- hover 220ms → Expanded panel (usage tab keeps selection)
- click provider chip → Expanded panel (that provider)
- click unread badge → Expanded panel (alerts tab; read-marking on dwell, see below)
- transient event arrives → Sneak peek banner
- critical event arrives → Expanding notice
- [ ≤3 chips w/ icon + numericText %, static pending marker, unread badge ]

Sneak peek banner (transient, auto-hide per type)
- click → Expanded panel (alerts tab, item highlighted)
- next event → same place, opacity+scale swap
- hover → expands panel per existing 220ms path; expansion freezes countdown
  (no separate hover-hold: holding the banner IS expanding, so no race)
- timeout → Compact notch (+ unread, at-most-once rule)
- [ icon w/ symbolEffect(.bounce/.pulse, value:), title, marquee message,
  T-minus progress hairline ]

Expanding notice (transient, larger, actions)
- Details → Expanded panel (alerts tab) | Dismiss/Esc/timeout → Compact notch
- buttons work without activation via acceptsFirstMouse; panel becomes key only
  via explicit click or the Show-Alerts menu item (no programmatic focus moves)
- [ severity icon-shape + text label per §4 table, title, message, 1–2 buttons,
  progress hairline ]

Expanded panel — Usage tab
- provider menu → same place (directional swap of detail) | ALERTS segment → Alerts tab
- gear → Settings (collapse) | chevron/Esc/hover-out 400ms → Compact notch
- [ header, provider detail w/ animated ProgressViews, reset times, failure labels ]

Expanded panel — Alerts tab
- USAGE segment → Usage tab | click item → inline expand (message + timestamp + provider)
- entering ALERTS starts a cancellable 1s Task; on fire, badge clears only if
  expanded && showingNotifications && panel ordered front; cancel on tab
  leave/collapse; P2 deletes the immediate markUnreadRead() in openNotifications
- Clear read → same place (list collapses w/ opacity+scale removal)
- [ retained list newest-first, empty state ]
- keyboard: new "Show Alerts" item in a new status-menu Notch section
  (MenuDescriptor; key-equivalent conflict check against the existing menu tree
  in P2; no global hotkey — RegisterEventHotKey/Carbon or a new dependency
  violates the no-new-deps rule). The menu item is keyboard-reachable AND orders +
  makes-key the panel — this is the non-click key path that breaks the FKA
  circularity. T2 buttons then FKA-operable; D/Esc act only once keyed; Esc on an
  unkeyed banner is a no-op; P2 extends cancelOperation so Esc dismisses a visible
  T2/banner first, then collapses.

OS notification fallback — testable trigger table:
post OS banner iff notch disabled OR no notch geometry OR screen locked
(locks observed via DistributedNotificationCenter com.apple.screenIsLocked /
...screenIsUnlocked, named explicitly). Fullscreen trigger DELETED: the panel is
already .fullScreenAuxiliary and shows over fullscreen. "While away" =
screen-locked only, never idle.
```

Flow: Compact →(event)→ Sneak peek →(click)→ Expanded panel;
Compact →(critical)→ Expanding notice →(Details)→ Expanded panel;
Sneak peek →(timeout)→ Compact; Expanding notice →(dismiss/timeout)→ Compact;
Compact →(hover/click)→ Expanded panel; Expanded panel →(collapse)→ Compact.

**States per place:** empty (no providers → "Set up usage", no retained → existing
empty text); loading (static skeleton, no shimmer unless its transient is showing);
failure (keep orange triangle + "showing last available data"); Reduce Motion (all
springs → instant/opacity-only via `@Environment(\.accessibilityReduceMotion)`,
marquee off, durations unchanged); screen-locked/no-notch (OS-notification fallback
per trigger table, no panel). Severity is never color-only: every level uses its
§4 table row (icon shape + text label); any pulse is redundant with a static shape.

## 6. Motion tokens (new `NotchAnimation.swift`, ~60 lines)

All tokens macOS 14. macOS-15-only APIs (`blurReplace`, `.interpolate`,
`.contentTransition(.symbolEffect)`) are excluded, not gated — gating would fork
every transition for zero user benefit on our deployment target.
- `open = spring(response: 0.42, dampingFraction: 1.0)`,
  `close = spring(response: 0.45, dampingFraction: 1.0, blendDuration: 0)`
  (mirrors Atoll's default-ON modern-close path),
  `content = .smooth`, `swap = asymmetric insertion opacity+scale(0.965)/
  spring(0.34,0.88), removal opacity+scale(0.92)/smooth(0.22)`,
  `consecutive = opacity+scale + interactiveSpring(dampingFraction: 1.2)`,
  `tab(forward) = directional move+opacity/smooth(0.3)`,
  `closeDuration` = explicit settle-allowance token for the 0.45-response close
  spring (derivation rule: measured-or-estimated settle time, NOT the response
  value — an overdamped 0.45-response spring settles in ~0.6–0.9s; P1a confirms
  the constant in proof). Both the close animation and the collapse-completion
  scheduler consume `closeDuration` — single source of truth.
  No `hover` token: hover here is a debounced task resolving to a plain Bool with
  a menu-tracking cancel — there is no live binding to attach `.bouncy` to, and
  adding one is scope without benefit.
- **State owner (P0a):** `@MainActor @Observable final class NotchPanelState`
  (MainActor required under the package's StrictConcurrency) held by the controller
  and passed ONCE as the stable root's init param. Complete field list — every
  value-typed input migrates, or identity still dies: `presentation`,
  `geometry`, `expanded`, `notifications`, `showingNotifications`
  (`NotchUsageView`'s init signature changes accordingly, plus the
  `NotchUsageNativeProof` view). Closures stay as controller methods referenced at
  root creation. Renders mutate state properties inside `withAnimation`; stable
  subviews read via `@Bindable`/direct property reads (macOS 14 tracking
  contract). Identity is preserved across renders without `rootView` replacement
  (`setFrame` alone never reset `@State`/`@Namespace` — replacement did).
- **Frame/transition ordering is asymmetric** (ships in P1a with the first removal
  transition — P0a keeps today's instant sync collapse with zero behavior change).
  Expand path: sync `setFrame` FIRST, then animate insertion inside the already-large
  panel. Collapse path: run the removal transition inside the OLD (large) frame
  FIRST, then `setFrame` on completion. Completion mechanism: controller-owned
  cancellable `Task.sleep(closeDuration)` (repo precedent — NOT GCD `asyncAfter`,
  which returns Void and cannot cancel) with a generation token; cancel triggers:
  re-expand, new banner arrival, geometry change; the frame is recomputed from
  current state at fire time (never captured). Open/close springs are content-only.
- **Animation precedence:** values driven by `withAnimation` get
  `.animation(nil, value:)` guards on the receiving subviews;
  `.animation(_:value:)` is used ONLY where no explicit transaction exists.
  (Mirrors the purpose of Atoll's `.animation(nil, value:)` root guard.)
- Reduce Motion: views read `@Environment(\.accessibilityReduceMotion)` and pass a
  `reduceMotion: Bool` into token selectors (a tokens module cannot host
  `@Environment` itself). The overlay's `reduceMotion || appeared` precedent needs
  lifetime adaptation: under a stable root a single flag latches after the first
  show, so appear flags are per-subsite AND reset per item (`.id(activeID)` or
  `onChange`-of-id reset). Per-site mapping (verify nil-override behavior in
  proof; use the explicit form where in doubt):
  `withAnimation` sites → `withAnimation(nil)`; `.animation(_:value:)` sites →
  `.animation(nil, value:)`; `.transition` sites → conditional `.transition(.identity)`;
  appear sites → skip animation, render final state; `.numericText` → instant
  (no isolated transaction under RM); T-minus hairline → static proportional
  (fraction = remaining/total) or hidden; corner radius → instant (no collapse
  delay exists under RM, so no mask/frame mismatch).
- Corner radius: animate bottom-corner radius 10→24 on the existing `.rect` clip
  only; top radius and shadow padding out of scope.
- Keep controller discipline: sync `setFrame` + animate content only (with the
  collapse-ordering rule above); keep 220/400ms hover delays; keep
  Escape/menu-tracking behavior.

## 7. Phased build (ponytail order: biggest win, smallest diff first)

1. **P0a — Stable root + tokens + gate + tests. Zero behavior change.**
   `NotchPanelState` + single-root refactor (no `rootView` replacement; view +
   proof-view init changes), `NotchAnimation.swift` with `reduceMotion`-Bool
   selectors. Verification split: UNIT (token selectors incl. nil-mapping,
   state transitions, scheduler behind an injected clock seam — name it
   `Clock`/`Sleeper` protocol with a test double) vs MUST-BE-PROOF-VERIFIED via
   `--notch-proof` (root-identity preservation across renders, no `rootView`
   replacement, collapse still instant-sync). Exit: full existing suite green
   plus new unit tests; proof shows today's exact behavior.
2. **P0b-i — Severity plumbing (unblocked).** `type` field + parser mapping + §4
   routing table (minus login-failure row) as exit artifact; lane-ordered pending
   + lane-scan selection. Tests: mapping table cases, lane ordering/selection.
3. **P0b-ii — Dwell math (blocked on §8.5).** Preempt/demote API with stored
   `remaining`, fairness + frequency caps, mechanical counter-reset
   (unit-test case), controller expiry-task surgery (cancel on expand + stash
   `frozenRemaining`; on collapse `activeUntil = now + frozenRemaining` and
   reschedule; `advance()` no-ops while expanded; arrivals while expanded do
   badge-only updates), 60s freeze cap, eviction unread++, cap-trip debug logging,
   doc-comment amendment. Tests: preemption math, reshow/floor/2×-cap cases,
   at-most-once traces, freeze-cap death (no reshow, no second unread++).
4. **P1a — Banner core + collapse completion.** T1 sneak-peek swaps, T-minus
   hairline, T0 closed swaps, badge pop, collapse-completion scheduling
   (first removal transition — this is why scheduling lives here, not P0a).
   Verification: unit (swap-key selection, hairline fraction, badge-count
   derivation) + proof-app (swap/ordering/cancellation behavior) + manual-only:
   perceived smoothness of the close spring.
5. **P1b — Banner richness.** Marquee (with overflow gating), `numericText`,
   static pending marker. Verification: unit (overflow predicate, count
   formatting, marker visibility predicate) + proof-app (marquee runs only when
   overflowing; static otherwise) + manual-only: marquee pacing.
6. **P2 — T2 expanding notice + T3 tab transitions (requires §8.3; T2 dwell also
   hostage to §8.5).** Critical lane with Details/Dismiss, directional
   USAGE↔ALERTS transitions, retained-list insert/remove motion, dwell
   read-marking (deletes immediate `markUnreadRead`), "Show Alerts" status-menu
   section + conflict check, `cancelOperation` Esc-first-dismisses-T2 extension,
   AX announcement element, keyboard path. Verification: unit (dwell-timer
   state machine incl. cancel paths, tab-direction derivation) + proof-app
   (direction correctness both ways, Esc ordering) + manual-only: VoiceOver
   announcementBehavior, FKA traversal.
7. **P3 — Channel consolidation.** Route quota-depleted/threshold-warning/restored
   and credit-expiry into T1/T2 per the §5 trigger table; single-channel rule
   (suppress the OS post when T1/T2 shows — no double-notify); predictive-pace
   routing decision; login-failure producer construction (new event source from
   today's modal-alert call sites). Keep OS banners as fallback.
8. **P4 — Polish, only if asked.** Segmented-wave threshold crossing, first-run
   choreography, swipe gestures. Default: skip (ponytail). `matchedGeometry`,
   parallax, haptics, and `.mov` icons are rejected, not deferred.

## 8. Open decisions

1. Inline wings vs centered banner for T1? (Recommend centered first; wings later.)
2. ~~Does T2 steal any focus?~~ Resolved: never activates another app; panel
   becomes key only via explicit click or the Show-Alerts menu item (required for
   D/Esc); focus never moves programmatically.
3. ~~Retire centered overlay or keep for critical?~~ Resolved (overnight default —
   confirm in morning): KEEP for critical. Additive and reversible: P2 leaves
   the overlay untouched; P3 keeps overlay-for-critical plus OS banners as
   fallback while suppressing the OS post when T1/T2 shows.
4. ~~Per-provider mute / quiet hours for agent events?~~ Resolved: deferred.
   Ship P0b-ii without mute; revisit if banner volume demands it.
5. ~~Should `waiting`/`access_request` persist visibly until resolved, or age out like the rest?~~
   Resolved: age out like the rest. All types share the 10s window, floors, and
   2× total-dwell cap; no persist class exists.

## 9. Risks

- GPL: reimplement, don't copy — enforce in review.
- Hit-region vs animation: sync frame + animate content only, with §6
  collapse-ordering. Transient cost acknowledged: during P1a's removal window the
  large hit region outlives mouse-out by up to `closeDuration` — accepted,
  bounded, and absent under Reduce Motion (no collapse delay there).
- Energy/perf: hard rule — marquee, pulse, shimmer, and progress hairlines run
  ONLY while their transient (T1/T2) is on screen; T0/closed state is statically
  rendered. (The panel is always frontmost, so "cap to visible windows" alone
  would be vacuous.) Audit with existing energy probes.
- Multi-display/screen-locked/menu-bar-hidden: trigger table in §5; test on non-notch display.
- Accessibility: T1/T2 announce via the 3-arg
  `NSAccessibility.post(element:notification:userInfo:)` with
  `.announcementRequested` + `NSAccessibilityNotificationUserInfoKey.announcement`
  on a dedicated announcement-only second SwiftUI `accessibilityElement`; the
  visual banner subtree gets `accessibilityHidden(true)`.
  Leading-edge throttle, max 1 announcement per 5s; burst titles beyond the first
  are dropped from speech but preserved in the retained ALERTS tab (catch-up
  intact). Keyboard path per §5 (menu item + click/menu-to-key + FKA). Severity
  always icon-shape + text label per §4, never color-only.
