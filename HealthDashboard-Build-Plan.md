# HealthDashboard — Gated Build Plan

From concept to buildable. A phased roadmap that honors the strict methodology: reconnaissance → architecture sign-off → implementation → incremental layer tests → integration → validation. No code before architecture decisions are confirmed. Additive-only changes to existing consumers. Named tunable constants for all weights and thresholds. Scoring lives in engines and is never re-derived downstream. Compute-once / display-many for bridge metrics; raw data stays in extractors.

---

> **⚠️ Reconstruction note (2026-08-20)**
>
> This file was originally authored on 2026-07-06 but was written to a chat-session sandbox and presented as a download — it was never committed to the repo and never lived on disk at `/Users/markcalabrese/Projects/HealthDashboard/`. Discovered 2026-08-20 when a documentation edit found no file to target; git history and stashes confirmed it was never tracked.
>
> This version is a faithful reconstruction brought current to 2026-08-20, not a byte-for-byte restore of the original. The architecture arc, phase structure, sequencing rule, and parked-item ledger are recovered with high confidence (preserved verbatim in the governing-guide memory entry and this session's history). Per-phase implementation-step bullets and exit-gate wording are reconstructed to intent and should be spot-checked against your recollection. **Commit this file so it can never silently vanish again**, and from here the recon-before-edit step for this document must confirm it is on disk before assuming an anchor exists.

---

## Status (as of 2026-11-16)

- **Purpose:** daily readiness (core) plus a longevity layer limited to what Apple Health doesn't know.
- **Strategic decision (2026-11-16):** Apple's iOS 27.3 Health app ships a Longevity tab with Health Age (inputs: VO2 max, RHR, sleep, HRV; labs A1c/LDL; Quest lab booking). HD will **not** replicate it. Sources: apple.com/newsroom/2026/09/apple-advances-health-and-fitness-capabilities-using-apple-intelligence/ and 9to5mac iOS 27.3 beta coverage (verified 2026-11-16 via Apple Newsroom (Sept 2026) and 9to5Mac iOS 27.3 beta coverage).
- **SDK check (2026-11-16):** only Xcode 27.2 / iOS 27.2 SDK is installed (`xcodebuild -showsdks`); **no iOS 27.3 SDK**, nothing downloaded. In the 27.2 SDK `HealthKit.tbd` exports `_HKFeatureIdentifierHealthAge` (line 8194) and `_HKFeatureAvailabilityContextReadiness` (line 8112), but neither the public `Headers/` nor the `HealthKit.swiftmodule` mention HealthAge, Longevity or Readiness — i.e. feature-availability plumbing, not a public data API. Availability annotations: none found. A public Health Age read API in 27.3 is **not verified** (see L4).
- **Hold on `evaluate()`:** discharged 8/26 (see Archive → "✅ RESOLVED (2026-08-26)"). Gating is per-item exit gates, plus the methodology invariants below.
- **Where things stand:**
  - `main` is `1c65bb3` (2026-10-25). `readiness-gate-hold-messaging` is merged (`f9dc7c7` is an ancestor of `main`). No pull requests were ever opened on HD.
  - Driver-aware gate fix: **DONE** (`709309b`, 2026-08-20). Dashboard routing bug (efficiency detractor → composite tile): **DONE** (`5c134ec`, 2026-08-20).
  - Composite driver swap: RETIRED (`ae396bc`). Dead HRV buffer: removed (`cd6e76d`).
  - Branch `readiness-display-context` (8 commits, pushed 2026-11-16, unmerged): sleep tile/row target parity, night-context tag store + warm-room toggle, dated pain/sick expiry, `persistManual` log-write suppression, query D diagnostic, plan specs.
  - 2026-11-16 audit: HD `main` builds, 255 tests pass; Watch scheme builds. EP tip (`feat/in-app-guide`) 1119 tests, 29 skipped, 10 failures across 9 tests, all listed in `Tests/known_failures.txt`.

### Methodology invariants (do not drift)

- No code before architecture sign-off. Each phase has explicit exit gates.
- **Recon before implementation:** read source files, locate anchors, confirm structure before authoring any prompt or diff. For this file specifically: confirm it is on disk first.
- Scoring logic lives in engines, never re-derived downstream. Messaging strings derive from the same computed values shown in the UI.
- Additive-only changes to existing consumers when extending data models.
- Named tunable constants for all weights and thresholds.
- Compute-once / display-many for bridge metrics; raw data stays in extractors.
- Observability before fixes — root cause confirmed via diagnostic reads before any code is written.
- Tests go red first to confirm aim before fixes are applied.

### Shipped since 2026-08-01 (HD `main`)

Recorded 2026-11-16 from `git log main --since=2026-08-01`; several were not in the plan before.

- 2026-08-20 `fe1ba3a` — Add gated build plan (reconstructed 2026-08-20)
- 2026-08-20 `8096fc2` — Remove split/reeval tests that leaked into the messaging test file
- 2026-08-20 `709309b` — Skip confirmation hold on load-origin yellows; add verdict-log dump (driver-aware gate fix)
- 2026-08-20 `5c134ec` — Add .sleepEfficiency metric case; repoint efficiency tile routes (routing bug fix)
- 2026-08-26 `e0caba0` — Flag zero-variance axes as degraded in sleep composite validator
- 2026-08-26 `ae396bc` — Build plan: retire sleep composite driver swap, park as display
- 2026-08-27 `cd6e76d` — Remove dead HRV buffer; keep the −1 clamp (no behavior change)
- 2026-08-27 `b60af39` — Close mechanical-load double-write as resolved-by-restore (superseded by EP ba1c2fb — see Track R, load inputs)
- 2026-09-07 `9fd10da` — Widget reads a written verdict projection instead of recomputing
- 2026-09-29 `3db3cbe` — Hold exception: behavior-neutral engine edits (expose rawRecoveryTruth, fix Release build)
- 2026-09-29 `e352166` — Add .redLoad presentation state for load-caused red
- 2026-10-03 `29a3317` — Card: yellow with green recovery shows load framing (.yellowLoadMinorDrivers)
- 2026-10-03 `2f16e48` — Merge load-origin card fixes (.redLoad, .yellowLoadMinorDrivers) and Release build fix
- 2026-10-05 `86a8080` — Persistence: weekly summary evaluations no longer write the verdict log
- 2026-10-05 `76ace11` — Live: skip verdict-log persistence when onAppear evaluates stale history
- 2026-10-05 `0cf8fc8` — Card: re-evaluate for display when the store has newer data (refreshIfStale)
- 2026-10-25 `db9ef95` — Weekly: make build's reference date injectable (characterization tests)
- 2026-10-25 `1b2c32d` — Weekly: add Training Load and Strength Load rows (completed days vs same days last week)
- 2026-10-25 `022670a` — Engine (hold exception): expose canPushKeyLiftWithoutLoad
- 2026-10-25 `1c65bb3` — Card: explain load-blocked no-push (.greenNoPushLoad)

---

## Track R — Readiness

Core product. Items R0–R4 below are the 11/16 recon specs (formerly C1–C4 plus the per-signal-scores prerequisite). Text is preserved from the previous plan with the C-labels renamed to R-labels: **C3 → R1, C4 → R2, C1 → R3, C2 → R4**. Order is priority order.

- **R0 (prerequisite):** per-signal scores in `DailyVerdictRecord` (additive, decode-safe). See "Cross-cutting" below.
- **R1** temp corroboration · **R2** score-path gate · **R3** fixed sleep need (permanent design) · **R4** HRV smallest worthwhile change (resolve SDNN vs rMSSD first).
- **Data collection (now):** toggle the warm-room tag nightly while the heat is on (Reality check → "Warm room / heat on (last night)"); tags are stored in `SharedStore` (`NightContextTag`) with no scoring effect yet.

### 🌡️ Readiness signal weighting (from 11/16 recon)

Status: OPEN — Phase 8, gated by per-item exit gates. Every item below edits `ReadinessEngine.evaluate()`; spec only, nothing implemented. Upstream/orthogonal pieces already landed on `readiness-display-context` (sleep tile/row target parity, night-context tag store + warm-room toggle, dated pain/sick expiry, `persistManual` log-write suppression, query D diagnostic `SharedStore.dumpSubThresholdYellows()`).

Background:
- The 11/16 yellow came from wrist temp scoring −3 (|Δ| > 0.7, `ReadinessEngine.swift:214`, no corroboration) plus HRV −1 and sleep −1 fillers, via the score path (`recoveryScore ≤ −4`, line 407) — not the cluster path (`clusterCount` was ~1).
- The temp cause was environmental (heated room). RHR −0.2 and RR −0.8 scored 0; nothing else corroborated.
- One heavily weighted, uncorroborated signal plus two sub-threshold fillers reached yellow. Intended outcome for that night: green + a temp watch flag.

Order is priority order. Each item ships alone, tests red first, with `ReadinessParityGolden.swift` regenerated per item (see Cross-cutting).

**R1 — Temp corroboration (FIRST)**
- Prerequisite: per-signal scores on `DailyVerdictRecord` (see Cross-cutting) land first, so R1's effect is measured, not inferred.
- Named constants: `tempWatchMagnitudeC = 0.7`, `tempSustainDays = 3`.
- Temp score and `tempUp03` count toward `recoveryScore` / `clusterCount` only if (|Δ| ≥ `tempWatchMagnitudeC` AND streak ≥ `tempSustainDays`) OR `rhrUp3` OR `rrUp10`. Otherwise emit a "Wrist Temp ↑ (watch)" flag only, score 0.
- Streak is computed from `history`, not the verdict log (the log is capped at 30 days and is written as a side effect of `evaluate()`).
- Keep the rolling 28-day median baseline (environment and season shift it).
- Decision required: does the watch flag still block `canPushKeyLift` (line 515)? Default: no.
- Later phase: `NightContextTag.warmRoom` downgrades temp to watch-only.
- Also fix: `wristTempDeltaC` holds absolute °C (`HealthKitManager.swift:472`). Rename it or correct the comment at `SharedHealthSnapshot.swift:91` (and the lines above it, which describe it as a deviation near 0).
- Exit gate: 11/16-style inputs (temp +1.3, RHR/RR near baseline) produce no temp score and a watch flag; temp with RHR or RR corroboration, or sustained ≥ 3 days at ≥ 0.7, still scores.

**R2 — Score-path gate**
- A signal's score contributes to `recoveryScore` only if its own cluster flag is true; otherwise it contributes 0 and is surfaced as a minor driver.
- Remove `forceYellow` (`clusterCount ≥ 2`, line 388) if line 407 subsumes it.
- Expected 11/16 outcome with R1 + R2: green + temp watch.
- Validate with query D (`SharedStore.dumpSubThresholdYellows()`) before and after over the 30-day log: `scoreOnly` and `zeroFlag` should fall to ~0.
- Exit gate: no yellow reachable from signals that each sit below their own flag threshold; parity goldens regenerated and reviewed line by line.

**R3 — Fixed sleep need**
- Permanent design: the composite driver swap is RETIRED (8/26), so the fixed sleep target is not interim.
- `ReadinessTuning.sleepNeedHours = 7.5` replaces `max(7.0, sleepBase ?? 7.0)` at line 102.
- Decision required: does the +1 recovery-night promotion (line 180) use `sleepBase` or the constant? One sleep reference per signal.
- Re-baseline `sleepShort1` (line 334) and the −1/−2/−3 score bands (lines 174-177) against the new target.
- Rationale: the sleep composite carries no next-day signal (partial r ≈ +0.06); the tile and row already read `sleepDelta` (vs target), so the target should be a stated need, not a rolling median.
- Exit gate: tile, row and verdict all derive from the one target; no "vs avg" wording remains.

**R4 — HRV smallest worthwhile change (LAST)**
- Prerequisite: resolve what the HRV series is. HealthKit HRV is SDNN (sparse spot readings), not rMSSD — confirm what `hrvMS` ingests, and document what the "HRV (Sleep) — verified sleep window" tile computes.
- Then: `hrvSWCMultiplier = 0.5`; score only when |Δ ln(HRV)| > `hrvSWCMultiplier` × rolling SD of ln(HRV) over the baseline slice, with a named minimum-sample-count constant below which the legacy % bands apply.
- Delete the dead −2/−3 branches (line 144 clamps all negatives to −1).
- Exit gate: HRV series identity documented; SWC threshold reproduces the intended 11/16 outcome (−6.8% on a ~23.6 ms baseline does not score unless it clears 0.5 × SD).

**Cross-cutting**
- **Prerequisite for R1:** add per-signal scores to `DailyVerdictRecord` (additive, decode-safe like `rawRecoveryTruth`) so before/after can be measured instead of inferred. Written inside `evaluate()`, so it ships under the same per-item exit gates, and R1 does not start until it has landed.
- Parity goldens (`ReadinessParityGolden.swift`) will need regeneration — regenerate per item, not once at the end.
- History note: the RHR cluster threshold moved 4.0 → 3.0 bpm in `206637e` (2026-07-04); the log key stays `rhrUp4`. Pre-2026-07-04 `rhrUp4` flags used the 4.0 threshold — account for it when reading the log.
- Data collection now: toggle the warm-room tag nightly while the heat is on (Reality check → "Warm room / heat on (last night)").

### Load & recovery inputs (formerly Phase 4/6) — state as of 2026-11-16

- **TRIMP max HR: DONE.** Pinned at 170 bpm (`HealthKitManager.swift:22`, `confirmedMaxHR`), used at `:349`; `observedPeakHR` is a DEBUG comparison only (`:348`, `:372`).
- **mechanicalLoad double-write: FIXED in EP `ba1c2fb` (2026-07-27)** — "App Group becomes idempotent projection of SessionHistory; kill += doubling". Write path: `SessionView.swift:2495` → `MechanicalLoadProjector.projectDay` (`MechanicalLoadProjector.swift:10-21`) re-sums all `SessionHistory` rows for the day → `MechanicalLoadSharedStore.set` replaces (never adds) the `mechanicalLoad.YYYY-MM-DD` value. Idempotent per day (recompute from SessionHistory), not per session UUID; residual risk: duplicate SessionHistory rows for one session. This **corrects** the 2026-08-27 note (`b60af39`) that the doubling was "structurally impossible" / a restore artifact: an `+=` doubling bug existed and was fixed before that note.
- **mechanicalLoad durability: PARTIAL.** EP rebuilds the App Group projection on restore (`BackupSnapshotImporter.swift:330-332` `projectAll`; `MechanicalLoadRecoveryMigration`, `91f3420`, 2026-07-27; `PersistedKeyRegistry.swift:75` `.rebuiltOnImport`). **Open item:** verify that `SessionHistory` itself is covered by EP's backups. HD only reads the value (`MechanicalLoadReader.swift`).
- **Duplicate-workout guard:** a generic guard exists (`HealthKitManager.swift:1043-1061`: same activity type, start and duration each within 90 s). No treadmill-specific guard. Decide whether treadmill needs more; default: no.
- **Step 4a frequency probe:** closed as not reproducible (`b60af39`); no probe code exists.
- **Widget projection (Phase 6 first consumer):** shipped (`9fd10da`); original text in Archive.

---

## Track L — Longevity (additive only)

Rule kept from the original vision: independent markers; **no HD fusion / healthspan score**. HD shows what Apple Health doesn't know and does not replicate Apple's Longevity tab or Health Age.

### L1 — VO2max calibration (FIRST)

Purpose: validate the input that feeds Apple's Health Age. Branches: `feature/vo2max-capture` (`a3812c4`) and `test/vo2max-on-main` (`bdcf44a`, `a3812c4` plus merges of `main`); both pushed 2026-11-16, unmerged. `test/vo2max-on-main` supersedes `feature/vo2max-capture` (same capture commit plus merges of `main`); work and merge from it. Sequence:

1. Push (done 2026-11-16).
2. One real strap-paired capture with stored HR verified against what the Watch showed.
3. Edit-window fix: re-check on device; `test/vo2max-on-main` may already seed correctly (`CardioCalibrationLogView.swift:357–358` seeds the pickers from `p.date` and `durationSeconds`). Unresolved: `:309` reseeds provenance from `orig.hrResolvedInterval`, and `:305` derives the stored duration from the resolved interval, so the end time may still be resolved-window-anchored.
4. 6–10 points in a rolling 90-day window, intensity spread across 60–85% of max HR.
5. Trend tile showing calibrated VO2max beside Apple's VO2 max estimate.

Exit gate: step 2 verified; the stored points (key `cardioCalibrationPoints`, `CardioCalibrationStore.swift:16`) inspected — no debug dump exists on the branch, so one is needed or the points must be read in-app.

**Original Phase 7 text (preserved):**

#### Phase 7 — VO2max estimator (parallel track — capture slice complete)

VO2max = the bridge keystone between readiness and longevity. Capture-first slice is code-complete (`feature/vo2max-capture`): `CardioCalibrationPoint` model, ACSM metabolic conversion, App Group persistence via `CardioCalibrationStore`, SwiftUI logging screen with workout-anchored HR resolution, delete/edit CRUD, optional provenance fields (`hrSampleCount`, `hrSourceName`, `hrResolvedInterval`, `workoutUUID`). Nothing wired to dashboard or verdict yet by design.

Capture protocol: steady-state segments 5–8 min at 60–85% max HR (≈102–145 bpm), 6–10 points in a rolling 90-day window, intensity spread across the submaximal range weighted over raw point count; each recorded as a strap-paired Apple Workout so HR lands in HealthKit.

Exit gate before push/PR: one real strap-paired capture with stored HR verified against the Watch. Queued: edit-window display-anchor fix.

### L2 — Strength

EP e1RM trend as a longevity marker (Apple doesn't see lifting). Source of truth is EP; HD reads a projection (same pattern as `mechanicalLoad`). Scope not yet specified.

### L3 — DXA body composition

Surface the existing DXA code (`DXAScan` and body-measurement stores in `SharedHealthSnapshot.swift`, `BodyMetricDetailView`) as a marker.

### L4 — Apple Health Age

Display it as Apple's number **if** HealthKit exposes it. **Status: not verified / default not applicable.** Only the iOS 27.2 SDK is installed; it exposes no public Health Age API (symbols only in `HealthKit.tbd`, no header or swiftinterface declaration). Re-check when an iOS 27.3 SDK is available; do not build against private symbols.

27.2 SDK exports HKFeatureIdentifierHealthAge (feature-availability family, not a data type). Expect at most an availability/status check, not the Health Age value.

---

## Ops

### Backup

- **HD:** all local-only branches pushed 2026-11-16: `readiness-display-context` (re-pushed 2026-11-16 through `aa4268c`), `feature/vo2max-capture` (`a3812c4`), `test/vo2max-on-main` (`bdcf44a`), `diagnostic/verdict-write-trace-rebased` (`adf22b6`).
- **EP:** pushed `feat/in-app-guide` (`106b1a8`), `feat/analytics`, `chore/warning-cleanup-OLD-armed`, `fix/next-meso-copy`, `fix/onboarding-1.2.3`. All other local EP branches are ancestors of `feat/in-app-guide`, so their commits are on the remote via the tip. EP `origin/main` is still `6df1c71` (2026-08-22), 372 commits behind the tip.
- **Stashes:** patch-exported, still not dropped, local files only (not pushed): `~/Projects/stash-backups/HD-stash0-2026-08-20.patch`, `HD-stash1-2026-05-07.patch`, `EP-stash0-2026-02-21.patch`.

### Pending merges

- `readiness-display-context` → `main`. Remaining device checks: (a) pain/sick set on day N reads default on day N+1; (b) a manual edit before the morning HealthKit fetch does not overwrite today's verdict-log slot with yesterday's verdict. Tile 'vs target' and warm-room toggle persistence: verified 11/16.
- EP `feat/in-app-guide` → `main`, after the known-failures check (9 failing tests, all listed in `Tests/known_failures.txt`; `ReorderTests.test_J4…` is the flaky one).

### Decisions

- `diagnostic/verdict-write-trace`: merge or park. Local was rebased but origin still holds the pre-rebase history; the rebased copy is `origin/diagnostic/verdict-write-trace-rebased`. Some content looks duplicated on `main` (e.g. weekly no-write `df303d9` vs `86a8080`) — not verified.
- The two HD stashes and the EP stash: patch-exported; apply or drop.
- The main HD folder (`~/Projects/HealthDashboard`) is on `diagnostic/verdict-write-trace` with an uncommitted `project.pbxproj` reorder; it should sit on `main`.

### Branch cleanup (from the 2026-11-16 audit)

- **Safe to delete (merged):** HD `origin/readiness-gate-hold-messaging`; EP `fix/planmemory-inprogress` (local and remote) and `origin/feat/coach-first-mvp`.
- **Needs merge:** HD `readiness-display-context`, `feature/vo2max-capture` / `test/vo2max-on-main`; EP `feat/in-app-guide` (contains 59 other local branches — delete those only after it lands in `main`).
- **Needs decision:** HD `diagnostic/verdict-write-trace` (+ its `-rebased` copy), both HD stashes, the EP stash; EP `chore/warning-cleanup-OLD-armed` and `fix/next-meso-copy` (not contained in the tip).

---

## Archive

Preserved history. Nothing here is deleted; headings are demoted one level. Superseded sections are listed with a one-line reason.

### Archive index

- **Phases 1, 2, 3, 5** — RETIRED 11/16: superseded by Apple Health Longevity/clinical records. Revival trigger: a non-Apple data source needs dedup/provenance, or a marker Apple doesn't cover needs a trusted store.
- **Phase 8 items "store cutover" and "status-into-verdict wiring"** — retired with Phases 1 and 2, which they depend on.
- **The organizing constraint: protect the validation hold** — discharged 8/26; the hold no longer applies.
- **Current state (2026-08-20)** — validation closure is evidence (kept); gate fix and routing bug are DONE; branch ledger is out of date.
- **Parallelization map** — describes the hold-era sequencing; no longer relevant.
- **Phase 0, Phase 4, Phase 6** — complete; current state of the load inputs is in Track R.
- **Phase 8 framing and the composite sections** (swap retired, rework agenda, 8/26 RESOLVED note) — composite is parked as display; decision made 8/26.
- **Parked items / open-question ledger** — superseded by Ops and the Status section.

### The organizing constraint: protect the validation hold *(superseded: hold discharged 8/26)*

The plan was sequenced around one fact: the sleep composite was on hold pending n ≥ 15 matured sleep→readiness pairs, and `ReadinessEngine.evaluate()` output must not change while that validation runs. Almost everything below is upstream of, or orthogonal to, the readiness verdict, so it builds in parallel with the hold. Only the final phase touches the verdict, and it is explicitly gated behind validation closure.

**Status as of 2026-08-20:** the hold has **CLOSED**. Validation reached n = 22 matured pairs (see Current State). The hold did its job — and returned a null result that contraindicates the Phase 8 composite driver swap. The organizing constraint is therefore satisfied; the gate now governs a rework decision, not a wait for data.

### Current state (2026-08-20) *(superseded: see Status; validation closure kept as evidence)*

#### Validation closure — composite driver swap CONTRAINDICATED

- Matured pairs: n = 22 (newest closed pair 2026-08-06 → 08-07). The n ≥ 15 condition is met.
- Raw composite(D) vs readiness(D+1): r = −0.00
- **Partial, controlling for load(D) — the real test: r = +0.06 (~zero)**
- Recovery-stripped composite(D) vs recovery(D+1): r = −0.02
- Per-axis: Architecture +0.21 · Duration −0.07 · Efficiency −0.35 (WRONG SIGN) · Fragmentation −0.12 · Consistency +0.20
- Significance floor at n = 22 (df = 20): |r| > ~0.42 for p < .05 two-tailed. Nothing clears it.
- **Verdict:** the sleep composite, as built, does not predict next-day readiness in this data. Phase 8 composite driver swap is on hold pending a rework decision (see Phase 8) *[Superseded by the 8/26 RESOLVED note: swap RETIRED, no rework pending]*. The validation gate did exactly what it was built to do — it stopped a non-predictive driver from being wired in.

#### Readiness confirmation-hold fix (driver-aware gate) — code-complete, pending commit

- **Problem:** a workout flips readiness to yellow (load-driven, TRIMP crossing the −4 total cutoff), and the one-day confirmation hold then keeps the card yellow the next day even when raw recovery signals are green. Confirmed against the verdict log (08-07 yellow at recovery = −2 → load-origin; 08-08 raw green, load = 0, held yellow by the gate).
- **Load has no overnight memory** — verified structurally: the load term is same-day and thresholded on TRIMP, and `forceYellow`/`forceRed` are computed before `loadMod` is assembled into `total`, so they are provably load-free. This is a pure display-gate artifact, not load persistence.
- **Fix (write-time, additive):** new `rawRecoveryTruth: ReadinessStatus` field on `DailyVerdictRecord` (the load-stripped verdict, computed in `evaluate()` via a shared `verdictFor(_:)` helper so scoring is not re-derived). Gate skips the one-day hold only when yesterday's yellow was load-origin (`yesterday.rawTruth != .green && yesterday.rawRecoveryTruth == .green`); recovery-driven yellows preserve the hold; absent-yesterday still holds.
- Decode-safe for pre-schema records (absent key → `rawTruth`, disabling the skip for old days = conservative).
- **Tests:** two new regressions (`testLoadOriginYellowSkipsHoldShowsGreen`, `testRecoveryOriginYellowKeepsHold`) plus the two existing cold-start gate tests all pass. 134 tests green, 0 failures.
- **Note:** this edits `evaluate()`, which was under the hold — now permissible because the n ≥ 15 gate has closed. It is also the validation-safe corner of `evaluate()` (writes only displayed `truth`, which `SleepCompositeValidator` does not read).
- **Open decision:** branch placement — stack on `readiness-gate-hold-messaging` (thematic, but inherits that branch's dirty-tree/unopened-PR situation) vs. its own `feature/load-origin-gate-skip` off `main` (clean, independent; recommended).

*[Closed 11/16 audit: DONE — `709309b` (2026-08-20), merged to `main`. Branch placement question moot.]*

#### Dashboard routing bug — sleep-efficiency detractor → composite tile (presentation fix pending)

- The "lower sleep efficiency than your norm" detractor fires correctly off `sleepEffScore` (raw asleep/inBed vs 28-day median, threshold −0.04). But tapping it routes on label `"Sleep Efficiency"` → `.sleepEff`, whose title is `"Sleep Quality"` — the composite tile, which shows composite score vs composite baseline (e.g. 90 vs 79) and never surfaces the efficiency axis.
- By construction the two efficiencies diverge (engine = asleep/inBed; composite = SPT-trimmed), so on couch-sleep nights the tile the detractor lands on is most likely to look fine — the app appears to contradict itself.
- Not a mis-fire and not a scoring bug — a routing/labeling defect. Fix is presentation-only (efficiency-first content on the tile, optionally the composite sub-axis breakdown). Decoupled from — and must not wait for — the efficiency scoring questions in Phase 8's rework agenda.

*[Closed 11/16 audit: DONE — `5c134ec` (2026-08-20), merged to `main`.]*

#### Branch / work ledger

- `main` @ `206637e` — sleep-composite work committed; pre-existing uncommitted WIP in tree (`ContentView`, `MetricDetailView`, `WeeklySummaryView`, untracked `WeeklySummaryTests`). OLD-WIP stash intact/untouched.
- `readiness-gate-hold-messaging` @ `f9dc7c7` — `action`-from-`rawTruth` decouple + count==0 ternary fix + gate-hold-aware messaging sourced in engine. Pushed, PR intentionally unopened. Caveat: 132-green was measured in a dirty tree; `git stash -u` + clean re-run before opening the PR.
- `feature/vo2max-capture` @ `a3812c4` — VO2max capture slice code-complete, unpushed. Gate before push/PR: one real strap-paired capture with stored HR verified against what the Watch showed. Queued: edit-window display-anchor fix (pickers reseed from marked start rather than `hrResolvedInterval`).
- Driver-aware gate fix — code-complete, awaiting branch decision + commit.

*[Superseded 11/16 audit: `main` is `1c65bb3`; `readiness-gate-hold-messaging` (`f9dc7c7`) is merged into `main`; no PRs were ever opened; `feature/vo2max-capture` is now pushed. See Status and Ops.]*

### Parallelization map *(superseded: hold-era sequencing)*

**Ran DURING the hold** (safe — no change to the readiness verdict): Phase 0 (recon) · Phase 1 (ingestion + trusted store, shadow-read only) · Phase 2 (status semantics — compute, don't wire) · Phase 3 (longevity evaluators + scheduler) · Phase 4 (load & recovery engine — additive) · Phase 5 (clinical / FHIR) · Phase 6 (projection / sync contract) · Phase 7 (VO2max estimator)

**Waits for validation to CLOSE** (the gated cutover — verdict may now change): Phase 8 (validation closure, composite driver swap, store cutover, status-into-verdict wiring, dead HRV buffer fix). *[Validation has closed; composite driver swap RETIRED and dead HRV buffer fix RESOLVED (`cd6e76d`) — see the 8/26 RESOLVED note.]*

The Phase 1 quality guard is not merely parallel-safe — it actively cleans the validation set by quarantining corrupt nights (deep+REM == 0, or unspecified > 20%) before they enter the matured pairs.

### Phase 0 — Reconnaissance & pre-build hygiene *(complete)*

No code. Establish the ground truth every downstream decision inherits: enumerate current writers to each metric, confirm device UUIDs, map existing extractors vs. engines, and document where raw data currently lives. Exit gate: a written inventory of sources, identity, and current consumers of each metric.

### Phase 1 — Ingestion layer + trusted store (shadow-read only) *(RETIRED 11/16)*

*RETIRED 11/16: superseded by Apple Health Longevity/clinical records. Revival trigger: a non-Apple data source needs dedup/provenance, or a marker Apple doesn't cover needs a trusted store. No code exists on `main` (11/16 audit).*

Build the five-stage pipeline as a shadow read — no consumer cutover, verdict untouched.

1. **Admission** — device-UUID whitelist; sole-writer enforcement per metric.
2. **Quality guard** — quarantine corrupt nights (deep+REM == 0, or unspecified > 20%). Highest-ROI rule; also cleans the validation set.
3. **Normalization** — HRV two-axis never merged; `ln(rMSSD)`; LOINC coding.
4. **Dedup** — one trusted source per metric.
5. **Store** — the trusted store, written but not yet read by consumers.

**Architecture sign-off (first real gate):** the canonical record shape + the three per-source identity keys — HealthKit = replace; clinical = identifier + type + source; EP mechanicalLoad = additive accumulator. Everything downstream inherits this.

Exit gate: shadow store populated and reconciled against live extractors; zero consumer behavior change.

### Phase 2 — Status semantics (compute the objects; do not wire to verdict) *(RETIRED 11/16)*

*RETIRED 11/16: superseded by Apple Health Longevity/clinical records. Revival trigger: as for Phase 1. No code exists on `main`.*

Status = tuple { state, confidence, horizon } — state is direction-aware polarity, confidence is trust-tier, horizon is the validity window. Temporal-integrity rule: a flag moves only when truth could actually change — dense metrics via confirmation + hysteresis; sparse metrics via assay-lock (refuse-to-trend). Compute and persist these objects; do not feed them into the verdict yet.

Exit gate: status tuples computed and inspectable for every metric; verdict output byte-identical to pre-Phase-2.

### Phase 3 — Longevity evaluators + scheduler (fully orthogonal) *(RETIRED 11/16)*

*RETIRED 11/16: superseded by Apple's Longevity tab. Revival trigger: as for Phase 1. No code exists on `main`; its "independent markers, no fusion score" rule is kept in Track L.*

Independent longevity marker panel. No healthspan fusion score — longevity markers are evaluated independently, never blended into a single number and never merged with the readiness fusion. Scheduler emits interval pips for periodic markers.

Exit gate: longevity panel renders from its own evaluators; no coupling to readiness.

### Phase 4 — Load & Recovery engine (additive; surfaces its own flag) *(complete; corrections in Track R)*

Load and recovery signals as additive contributors. TRIMP is wired into the readiness load term; `mechanicalLoad` (EP → HD via App Group UserDefaults) is read but pending scoring decision.

**Step 4a — mechanicalLoad frequency probe.** Instrument how often the EP write fires per session. This is also the vehicle for confirming/resolving the double-write bug: diagnosed as whole-session double-counting (clean 2× ratio; identical values on three consecutive Sundays). The discriminating trigger (universal per-session double-write vs. Sunday-specific re-trigger) was unconfirmed when a data restore wiped App Group history. Prescribed fix: idempotent day-key accumulation guarded by session UUID.

**RESOLVED-BY-RESTORE / NOT REPRODUCIBLE (2026-08-27).** EP write-path recon: calculateMechanicalLoad is computed ONCE and the same value feeds both the session display and the App Group write (a REPLACE, not additive). Display and write cannot diverge in current code, so a 2x stored-vs-displayed is structurally impossible. The computation is a clean single flat pass over working sets — no warmup/per-side/nested double-count. The July 2x was a legacy/restore artifact, cleared when the restore wiped the App Group history. NO code fix applied or needed — the prior prescribed fix (idempotent += guard by session UUID) is SUPERSEDED: the write is not additive, so there is nothing to guard. Confirmation pending: one live-session measurement (compare EP displayed figure to stored raw for that date) to convert code-analysis to empirical close. Until then: not-reproducible-in-code, confirm-with-one-session.

*[Corrected 11/16 audit: the double-write was real and was FIXED in EP `ba1c2fb` (2026-07-27) — the write is now an idempotent projection from SessionHistory. The "structurally impossible" conclusion above is superseded. See Track R, load inputs.]*

Known debt — **durability gap:** App Group UserDefaults is the sole copy of mechanical-load history; no rehydration path survives a restore or reinstall.

*[Corrected 11/16 audit: EP rebuilds the projection on restore (`BackupSnapshotImporter` `projectAll`, `MechanicalLoadRecoveryMigration` `91f3420`). Open: verify SessionHistory backup coverage.]*

Exit gate: probe confirms write frequency; double-write trigger identified; idempotent fix specified.

### Phase 5 — Clinical / FHIR ingestion *(RETIRED 11/16)*

*RETIRED 11/16: superseded by Apple Health clinical records (labs A1c/LDL, Quest booking). Revival trigger: as for Phase 1. No code exists on `main`.*

Read provider-synced labs via `HKClinicalRecord` (Clinical Health Records entitlement, read-only). Provider reference range stored separately from the optimal band — never conflated. FHIR-formatted results feed the longevity tier as its primary supply line.

Exit gate: clinical records ingested read-only into the longevity panel; reference-range vs. optimal-band separation verified.

### Phase 6 — Projection / sync contract *(complete)*

Governs what crosses to Watch/widget: horizon-filtered eligibility, provenance-stripped payloads, three explicitly tagged signal kinds — status flag / display value / scheduler pip. The horizon field doubles as refresh policy. Payload invariant to longevity platform size — adding markers must not grow the sync payload.

Exit gate: projection contract enforced; Watch payload size invariant to longevity additions.

#### Widget projection — first Phase 6 consumer (2026-08-27)

The widget no longer recomputes the verdict. It reads a written WidgetProjection
(truth, flagCount, RHR/HRV/sleep + trimmed sparkline series, updatedAt) from a single
App Group key; the app writes it on every recompute (foreground backfill, manual edit,
and background HealthKit delivery — the last now computes evaluate() in the main-app
process where it previously computed nothing). This is the Phase 6 contract's first
consumer: provenance-stripped, single-key, compute-once/display-many across the process
boundary. Widget is a dumb mirror — nil projection renders a neutral placeholder, never
a guessed verdict.

Closed a cross-process hazard in the process: the widget had been re-running
ReadinessEngine.evaluate() in its own process, which (a) diverged from the app's verdict
on screen and (b) wrote the shared verdict-log gate key from a second, uncoordinated
process on a single-digit-minute cadence — racing the exact state the load-origin gate
fix reads. Any gate-log anomaly observed BEFORE this build could have been the widget
racing, not the gate logic. appendVerdictLog is now structurally main-app-only (bundle-id
guard) so this class of race cannot recur through another door. Verified on-device:
widget mirrors app.

### Phase 8 — Validation closure & cutover (OPEN — hold discharged 8/26; per-item exit gates) *(framing superseded 11/16; see Status and Track R)*

Originally: on n ≥ 15 closure, swap the composite driver, cut the store over, wire status into the verdict, and fix the dead HRV buffer. The n ≥ 15 gate has closed — but with a null validation result, so the composite driver swap is contraindicated. The remaining Phase 8 items (store cutover, status-into-verdict wiring, dead HRV buffer fix — **RESOLVED, `cd6e76d`**) are unblocked in principle but should not assume a working composite. *[Superseded by the 8/26 RESOLVED note: the swap is RETIRED and the hold is discharged; the items below are open under per-item exit gates.]*

**Remaining gated items:** *[Superseded by the 8/26 RESOLVED note — open under per-item exit gates, not a hold.]*

- **Store cutover** — consumers read the trusted store instead of live extractors.
- **Status-into-verdict wiring** — Phase 2 status tuples feed the verdict.
- **Dead HRV buffer fix** — the HRV buffer is unreachable behind a −1 floor clamp that precedes the buffer guard; fires every run. Confirmed via debug dumps. **RESOLVED (2026-08-27, `cd6e76d`)** — dead buffer removed, −1 clamp kept as the floor (no behavior change); verified again in the 11/16 recon (no buffer variable remains).

*[Superseded 11/16: "store cutover" and "status-into-verdict wiring" retired with Phases 1 and 2; "dead HRV buffer fix" RESOLVED (`cd6e76d`).]*

#### ⛔ Composite driver swap: RETIRED (2026-08-26 — see resolution note below)

Status: RETIRED — not deferred. The sleep composite does NOT predict next-day
readiness in the validation data (three-run replication, partial r=+0.06). The
driver swap will not be wired. See ✅ RESOLVED (2026-08-26) below.

Evidence (SleepCompositeValidator run, 2026-08-08):
- Matured pairs: n=22 (newest closed pair 2026-08-06→08-07). n≥15 hold
  condition is MET — the hold completed its purpose and returned a verdict.
- Raw composite(D) vs readiness(D+1):            r = -0.00
- **Partial, controlling load(D) (the real test): r = +0.06  ← ~zero**
- Recovery-stripped composite(D) vs recovery(D+1): r = -0.02
- Per-axis:
    Architecture   r = +0.21
    Duration       r = -0.07
    Efficiency     r = -0.35   ← WRONG SIGN
    Fragmentation  r = -0.12
    Consistency    r = +0.20

Significance floor at n=22 (df=20): |r| > ~0.42 for p<.05 two-tailed.
Nothing — composite or any single axis — clears it.

Interpretation:
- Efficiency's negative sign is the suspected load confound: hard sessions
  compress sleep into a "high-efficiency" night while load independently
  tanks next-day readiness. The partial-r controlling for load is the guard
  against exactly this, and it lands at ~0.
- Architecture (+0.21) and Consistency (+0.20) lean the correct direction
  but are underpowered — promising leads for a rework, not usable drivers now.
- This is "contraindicated on current evidence," not "disproven." A small
  true effect could hide at this n. But nothing here justifies wiring the
  composite in as a ReadinessEngine driver.

Decision required (separate session): rework the composite (drop Efficiency
as scored, rebuild around Architecture/Consistency, re-validate) vs. park it.
Do NOT let any downstream Phase 8 step assume a working composite until this
is resolved. [Superseded by the 8/26 RESOLVED note: resolved as "park as display" —
the composite never enters the verdict, so no step may assume one.]

#### 🔬 Composite rework agenda — efficiency operationalization + driver status (2026-08-08) (CLOSED 8/26 — see RESOLVED note)

[Superseded by the 8/26 RESOLVED note: no rework session is pending; Q1/Q2 are CLOSED.]

Two scientific questions to resolve DURING the composite rework session, both
surfaced by a dashboard-routing bug but properly belonging to the scoring
decision, not to be answered reactively:

Q1 — Which efficiency operationalization is correct?
- Two efficiencies currently coexist:
    · ReadinessEngine sleepEffScore: raw asleep/inBed vs 28-day median,
      fires a readiness detractor at delta < -0.04.
    · SleepQualityEngine composite efficiency axis: SPT-trimmed.
- SPT-trimmed is the more valid CONSTRUCT: clinical/PSG efficiency is defined
  against the sleep period (onset→final waking), not gross time in bed. The
  raw asleep/inBed ratio is contaminated by in-bed-not-attempting-sleep time
  (couch-sleep nights), which the SPT change was made to remove.
- By construction the two DIVERGE on couch-sleep nights: engine sees low
  efficiency, composite does not. Currently the readiness verdict runs off the
  inferior (raw) operationalization.
- Decision: if efficiency stays a scored signal at all, it should use the
  SPT-trimmed operationalization, not raw asleep/inBed.

Q2 — Should efficiency drive the readiness verdict at all?
- Validation (2026-08-08, n=22): the composite as a whole did not predict
  next-day readiness (partial r=+0.06 controlling for load), and the efficiency
  axis specifically came in WRONG-SIGNED at r=-0.35 — consistent with the load
  confound (hard sessions compress sleep into a "high-efficiency" night while
  load independently tanks next-day readiness).
- The engine's own code comment already concedes the raw signal is "useful but
  noisy… a supporting signal unless the drop is clearly large."
- Stricter (more scientifically correct) read: efficiency has NOT earned a place
  as a readiness DRIVER. Demote it to descriptive information in the sleep detail
  view ("efficiency was low last night") rather than a detractor that implies a
  next-day training recommendation.
- Conservative (ship-now) read: keep it as the intended supporting signal; the
  -0.04 threshold fires only on large drops, so false-alarm risk is low. Fix the
  presentation, leave the scoring alone.
- This is an evaluate()-adjacent scoring change → belongs to the rework decision,
  NOT to be made off a single dashboard complaint. Parked here deliberately.
  [Superseded by the 8/26 RESOLVED note: the rework decision was made — composite
  parked as display, so this scoring change is moot.]

Note: the dashboard-routing bug that surfaced these (efficiency detractor routes
to the composite "Sleep Quality" tile, which shows composite score vs composite
baseline and hides the efficiency axis) is being fixed SEPARATELY as a pure
presentation fix — it does not depend on and must not wait for Q1/Q2.

#### ✅ RESOLVED (2026-08-26): Composite driver swap RETIRED — park as display

Decision: the sleep composite will NOT drive the readiness verdict. The Phase 8
driver swap is RETIRED (not deferred). The composite is kept as a descriptive
display metric only (the "Sleep Quality" tile). ReadinessEngine.evaluate() will
not consume the composite.

Evidence — three independent validation runs, partial-r controlling for load(D):
- 2026-08-08 (run 1): partial r = +0.06
- 2026-08-08 (run 2, degraded — Consistency dropped): partial r = +0.06
- 2026-08-26 (decision-grade, all axes available, honest validator): partial r = +0.06
Replicated null at n=22 across three windows. |r| floor for significance at n=22
(df=20) is ~0.42; +0.06 is indistinguishable from zero. The composite does not
predict next-day readiness for this subject at achievable sample sizes.

Per-axis, clean run (2026-08-26):
- Architecture:  r = +0.26  ← lone positive, but does NOT clear the 0.42 floor
- Duration:      r = +0.05  (noise)
- Efficiency:    r = +0.09  (noise; last run's -0.35 was the load confound, now washed)
- Fragmentation: r = -0.06  (noise)
- Consistency:   inert — see below
Four of five axes carry no signal; the one that leans positive (Architecture) is
underpowered, not validated.

Why not rework around Architecture-only: at n=22 Architecture's +0.26 does not clear
significance. Building a single-axis Architecture driver now would be fitting noise
that happens to lean positive across three windows — the overfitting trap. If ever
revisited, the honest path is: collect many more matured pairs, THEN re-test
Architecture alone. Not a wiring task now.

Consistency finding (do NOT "fix"): Consistency scored zero-variance (constant 100)
across all 22 pairs → r=n/a. Root cause is NOT a data gap — it's that this subject's
14-night midpoint SD stays under 20 minutes every window (genuinely regular sleep).
The score→bucket mapping (SD<20min → 100) correctly pinned it. Unclamping the mapping
to make it "vary" would convert an honest no-signal into a spurious small correlation
on near-constant data — worse, not better. Consistency is inert for THIS subject
because the behavior it measures doesn't vary, not because the axis is broken. Leave
the bucket as-is for validation; refine only for display if desired, never to
manufacture a validation signal.

Validator instrument note: today's run initially printed ✅ DECISION-GRADE despite
Consistency being zero-variance — the availability-only check couldn't see an
available-but-constant axis. Fixed 2026-08-26: an axis available on ≥80% of pairs but
returning r=n/a from zero variance now flags the run degraded and names the cause
(ZERO VARIANCE vs INSUFFICIENT). The instrument is now trustworthy for the eventual
Architecture re-test, if ever run.

Consequences:
- Phase 8 driver swap: RETIRED. Phase 8 now = store cutover + status-into-verdict
  wiring + dead HRV buffer fix (**RESOLVED, `cd6e76d`**). None depend on the composite.
- The "🔬 Composite rework agenda" (Q1 efficiency operationalization, Q2 efficiency-as-
  driver) is CLOSED: no composite axis drives the verdict, so the operationalization
  and driver questions are moot. The sleep-efficiency detractor remains a ReadinessEngine
  signal on its own terms (unchanged); the composite simply never enters the verdict.
- The validation hold on ReadinessEngine.evaluate() that gated all of this is now
  fully discharged — its purpose (decide the driver swap) is complete.

### Parked items / open-question ledger *(superseded: see Ops)*

- **Sleep composite rework decision** — null validation result; decide rework (drop Efficiency as scored, rebuild around Architecture/Consistency, re-validate) vs. park, before any downstream step assumes a working composite. **RESOLVED 8/26** — parked as display; composite will not drive the verdict; driver swap RETIRED. See the ✅ RESOLVED (2026-08-26) note in Phase 8.
- **Efficiency operationalization (Q1) + efficiency-as-driver (Q2)** — resolve inside the composite rework session. **CLOSED** — no composite axis drives the verdict, so both are moot (see "Consequences" in the 8/26 RESOLVED note). The sleep-efficiency detractor remains a ReadinessEngine signal on its own terms.
- **Driver-aware gate fix** — commit + branch placement decision.
- **Dashboard routing bug** — presentation-only fix; independent of the scoring questions.
- **VO2max** — real-capture HR check → push + PR; edit-window display-anchor fix.
- **mechanicalLoad** — Step 4a frequency probe; double-write idempotent fix; durability/rehydration debt.
- **Dead HRV buffer fix** — Phase 8. **RESOLVED (2026-08-27, `cd6e76d`)** — buffer removed, −1 clamp kept; no behavior change.
- **Post-restore data degradation (cross-cutting):** restored history is lossy/laggy for derived scalars (mechanical-load history wiped; sleep window-bounds/axis availability degraded for days after a restore). Any validation/scoring run on a post-restore window is suspect until the window clears. Validator now flags degraded runs; no general rehydration guarantee exists. Same disease as the mechanicalLoad durability gap.
- **Phase 1 architecture sign-off** — canonical record shape + 3 identity keys; first brick of the trusted-store arc.
- **`readiness-gate-hold-messaging` PR** — `git stash -u` + clean re-run, then open.

*[Status of each item as of 11/16 is in Status, Track R/L and Ops. Composite rework items are CLOSED/RESOLVED 8/26; VO2max is Track L1; mechanicalLoad double-write is FIXED (`ba1c2fb`); dead HRV buffer RESOLVED (`cd6e76d`); the `readiness-gate-hold-messaging` PR item is moot (merged, no PR).]*
