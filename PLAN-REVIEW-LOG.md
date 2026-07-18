# Plan Review Log: Notchpad — notch-anchored recording surface

Act 1 (grill-with-docs) complete — plan locked, CONTEXT.md gained "Notchpad" term. MAX_ROUNDS=5.

## Round 1 — Codex (thread 019f7429-3262-7772-8429-2970f94d9ce8)

VERDICT: REVISE. 16 findings (full text preserved below, abridged headers):
1. Mid-recording handoff impossible — HUDController retains no presentation state.
2. Routing omits real entry points (`show(text:)`, `showTranslationRecovery`).
3. No model for transient flash over an active recording.
4. Flash auto-hide timer becomes a cross-surface race.
5. `safeAreaInsets.top > 0` ≠ built-in notch; no `CGDisplayIsBuiltin`/auxiliary validation; `screens.first` unstable.
6. 200pt fallback width violates hardware-honest rule.
7. Rectangular status-level panel can cover housing/menu extras.
8. "Not draggable" contradicts content reuse — `HUDDragSurface` calls `performDrag` in every mode.
9. `RecordingPanelState` is a state struct, not a reusable view (real UI = private `panelRow`).
10. `notchpadEnabled` missing from Backup Bundle mirrored schema (exportableKeys/SettingsPatch/tests).
11. Live-toggle behavior undefined (no settings subscription in HUDController).
12. Fullscreen claim stronger than `.fullScreenAuxiliary` guarantees.
13. Test exclusion too broad — repo already does headless AppKit panel policy tests.
14. No observability for a hardware-only path developed from clamshell.
15. Two panels unnecessary — one reconfigurable HUDPanel with a SurfaceStyle is simpler and kills lifecycle hazards.
16. `.panelFinish` mislabeled as callback; parity untested (real closures: Done/Raw/Cancel/Lock/language/output/template).

### Claude's response

ALL 16 accepted. Plan rewritten: single-panel SurfaceStyle architecture (15) absorbed 1/3/4's hazards into a retained base+overlay presentation model with generation-tokened timers and synchronous re-present on reroute; unified `present(mode:lifetime:)` covers all five entry points (2); NotchGeometry resolver with CGDisplayIsBuiltin + auxiliary-gap validation and NO width fallback (5,6); interactive content below the menu-bar strip with noninteractive connector (7); drag surface confined to floating wrapper + explicit panelRow extraction (8,9); Backup Bundle mirrored-schema integration (10); `$notchpadEnabled` subscription reroutes live (11); fullscreen demoted to hardware acceptance gate (12); headless policy-test suite per FloatingPanelPolicyTests precedent (13); structured routing logs (14); parity spelled out as concrete closures with exactly-once tests (16). Nothing rejected.

## Round 2 — Codex (thread 019f7429-3262-7772-8429-2970f94d9ce8)

VERDICT: REVISE. 3 remaining findings:
1. Goal/out-of-scope denied the deliberate restore-base floating-HUD correction.
2. Persistent base replacements vs active overlays underspecified (new recording / Processing… could stay under a flash).
3. Connector must not be removed on every flash expiry — only when leaving notch visibility.

### Claude's response

ALL 3 accepted. Goal + Out of Scope exempt restore-base correction; Approach step 4 spells overlay cancellation rules (same-recording `showRecordingPanel` keeps overlay; all other persistent bases cancel); step 6 connector lifecycle = `controllerVisible && surfaceStyle == .notch`.

## Round 2 — Codex (same thread)

VERDICT: REVISE. 10 findings:
1. `show(text:)` is persistent today — contradicted overlay classification.
2. Terminal flashes (e.g. "Cancelled") must clear/replace base, not restore stale recording panel.
3. Per-tick base re-presents must not cancel an active overlay.
4. Hit-test nil ≠ click-through to menu extras in a status-level window.
5. Floating HUD ALREADY has canJoinAllSpaces/fullScreenAuxiliary/stationary — "notch adds" wrong; fallback must preserve policy byte-for-byte.
6. Parity list omitted translation-recovery callbacks (onRetryTranslation/onInsertSourceText) + onPillClick.
7. Refactor omitted existing activeSpaceDidChangeNotification observer.
8. "Sane gap" insufficient — need finite/order/alignment/bounds invariants + pure resolver with captured isBuiltIn.
9. "Every routing decision" logging floods (1s ticks, preview renders) — log transitions only.
10. Toggle copy/Launcher subtitle understate scope.

### Claude's response

ALL 10 accepted. PLAN.md patched: `show(text:)` reclassified persistent base (1); flash split into terminal (default, clears base) vs restore-base (in-recording warnings only) lifetimes (2); base-update-under-overlay defined as distinct transition (3); interactive window fully below the menu-bar strip, optional fusion via separate ignoresMouseEvents connector window — the only sanctioned second window (4); complete per-style policy, floating preserved byte-for-byte, notch changes only level/position/chrome/drag (5); parity enumerates translation-recovery + onPillClick closures (6); activeSpaceDidChangeNotification observer explicitly retained (7); resolver made pure with captured inputs + finite/order/alignment/bounds invariants + adversarial geometry tests (8); logging change-triggered only (9); toggle copy "Show FreeTalker in the notch" + Launcher subtitle covers all HUD presentations (10). Nothing rejected.

## Round 3 — Codex (same thread)

VERDICT: REVISE. 6 findings:
1. restore-base cannot be inferred — the two in-recording warning `hud.flash` call sites must explicitly select it; "call sites untouched" claim contradicted.
2. Reroute + timer invalidation underspecified — flash could become permanent.
3. `hide()` not atomic — later screen/Space/toggle events could resurrect hidden content.
4. Connector window lacks lifecycle/Space policy coupling.
5. restore-base silently changes floating-HUD semantics vs. stated no-regression scope.
6. `onPillClick` (text mode) vs `PanelCallbacks.onLock` (recording) conflated; hardware checklist missing interaction items.

### Claude's response

ALL 6 accepted. PLAN.md patched: two AppCoordinator warning call sites explicitly pass `restoreBase`, claim narrowed to "untouched except these two" (1); reroute does NOT invalidate the overlay timer — single panel stays the target, generation stays valid, expiry on schedule (2, simplest option); `hide()` defined atomic — clears base/overlay/expiry/generation/connector, marks invisible, routing events no-op while hidden (3); connector made child lifecycle resource of notch style, atomic with every panel transition, policy-tested (4); restore-base acknowledged as deliberate cross-surface behavior correction with on/off regression tests (5); onPillClick vs onLock enumerated as distinct wiring, hardware gate gains menu-extra clicks/connector click-through/focus retention/insertion-target items (6). Nothing rejected.

## Round 4 — Codex (same thread; first reply truncated to preamble, retried once on-thread)

VERDICT: REVISE. 3 findings:
1. Goal/Out-of-scope still promise "exactly today's floating HUD" while step 4 deliberately corrects warning-flash behavior on both surfaces.
2. Overlay vs persistent replacement underspecified — `show(text:)` cancels flashes today; restore-base overlay could obscure "Processing…"/new recording.
3. Connector removal "on every transition incl. flash expiry" wrong — restore-base expiry leaves panel visible; churn.

### Claude's response

ALL 3 accepted. PLAN.md patched: goal + Out of Scope now carve out the restore-base correction as the sole, deliberate, regression-tested floating-behavior exception (1); under-overlay updates narrowed to same-recording showRecordingPanel only — all other persistent replacements cancel overlay/deadline/generation and present immediately (2); connector existence reduced to invariant `controllerVisible && surface == .notch` — untouched by flash expiry (3). Nothing rejected.

## Round 5 — Codex (same thread) — CAP REACHED

VERDICT: REVISE. "All other prior findings are resolved." 2 findings:
1. Flash audit incomplete — Voice Edit busy notice ("Finish the current recording first", AppCoordinator.swift:548) also reachable mid-recording as terminal flash; classify the full reachable set, not just two watchdog calls.
2. `expire(generation)` semantics undefined (stale no-op / restore-base restores latest base / terminal clears + marks hidden).

### Claude's response

BOTH accepted, folded into PLAN.md (flash-audit-and-classify step; expire(generation) defined as explicit transition). MAX_ROUNDS=5 reached without formal APPROVED — convergence 16→10→6→3→2, round 5 confirmed all prior findings resolved, and both remaining findings were accepted verbatim. Claude's position: no open disagreement exists; plan is converged in substance. Handed to Bruno for sign-off per skill deadlock rule.
