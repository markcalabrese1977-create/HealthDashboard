# HealthDashboard — Gated Build Plan

From concept to buildable. A phased roadmap that honors the strict methodology: reconnaissance → architecture sign-off → implementation → incremental layer tests → integration → validation. No code before architecture decisions are confirmed. Additive-only changes to existing consumers. Named tunable constants for all weights and thresholds. Scoring lives in engines and is never re-derived downstream. Compute-once / display-many for bridge metrics; raw data stays in extractors.

---

> **⚠️ Reconstruction note (2026-08-20)**
>
> This file was originally authored on 2026-07-06 but was written to a chat-session sandbox and presented as a download — it was never committed to the repo and never lived on disk at `/Users/markcalabrese/Projects/HealthDashboard/`. Discovered 2026-08-20 when a documentation edit found no file to target; git history and stashes confirmed it was never tracked.
>
> This version is a faithful reconstruction brought current to 2026-08-20, not a byte-for-byte restore of the original. The architecture arc, phase structure, sequencing rule, and parked-item ledger are recovered with high confidence (preserved verbatim in the governing-guide memory entry and this session's history). Per-phase implementation-step bullets and exit-gate wording are reconstructed to intent and should be spot-checked against your recollection. **Commit this file so it can never silently vanish again**, and from here the recon-before-edit step for this document must confirm it is on disk before assuming an anchor exists.

---

## The organizing constraint: protect the validation hold

The plan was sequenced around one fact: the sleep composite was on hold pending n ≥ 15 matured sleep→readiness pairs, and `ReadinessEngine.evaluate()` output must not change while that validation runs. Almost everything below is upstream of, or orthogonal to, the readiness verdict, so it builds in parallel with the hold. Only the final phase touches the verdict, and it is explicitly gated behind validation closure.

**Status as of 2026-08-20:** the hold has **CLOSED**. Validation reached n = 22 matured pairs (see Current State). The hold did its job — and returned a null result that contraindicates the Phase 8 composite driver swap. The organizing constraint is therefore satisfied; the gate now governs a rework decision, not a wait for data.

---

## Current state (2026-08-20)

### Validation closure — composite driver swap CONTRAINDICATED

- Matured pairs: n = 22 (newest closed pair 2026-08-06 → 08-07). The n ≥ 15 condition is met.
- Raw composite(D) vs readiness(D+1): r = −0.00
- **Partial, controlling for load(D) — the real test: r = +0.06 (~zero)**
- Recovery-stripped composite(D) vs recovery(D+1): r = −0.02
- Per-axis: Architecture +0.21 · Duration −0.07 · Efficiency −0.35 (WRONG SIGN) · Fragmentation −0.12 · Consistency +0.20
- Significance floor at n = 22 (df = 20): |r| > ~0.42 for p < .05 two-tailed. Nothing clears it.
- **Verdict:** the sleep composite, as built, does not predict next-day readiness in this data. Phase 8 composite driver swap is on hold pending a rework decision (see Phase 8). The validation gate did exactly what it was built to do — it stopped a non-predictive driver from being wired in.

### Readiness confirmation-hold fix (driver-aware gate) — code-complete, pending commit

- **Problem:** a workout flips readiness to yellow (load-driven, TRIMP crossing the −4 total cutoff), and the one-day confirmation hold then keeps the card yellow the next day even when raw recovery signals are green. Confirmed against the verdict log (08-07 yellow at recovery = −2 → load-origin; 08-08 raw green, load = 0, held yellow by the gate).
- **Load has no overnight memory** — verified structurally: the load term is same-day and thresholded on TRIMP, and `forceYellow`/`forceRed` are computed before `loadMod` is assembled into `total`, so they are provably load-free. This is a pure display-gate artifact, not load persistence.
- **Fix (write-time, additive):** new `rawRecoveryTruth: ReadinessStatus` field on `DailyVerdictRecord` (the load-stripped verdict, computed in `evaluate()` via a shared `verdictFor(_:)` helper so scoring is not re-derived). Gate skips the one-day hold only when yesterday's yellow was load-origin (`yesterday.rawTruth != .green && yesterday.rawRecoveryTruth == .green`); recovery-driven yellows preserve the hold; absent-yesterday still holds.
- Decode-safe for pre-schema records (absent key → `rawTruth`, disabling the skip for old days = conservative).
- **Tests:** two new regressions (`testLoadOriginYellowSkipsHoldShowsGreen`, `testRecoveryOriginYellowKeepsHold`) plus the two existing cold-start gate tests all pass. 134 tests green, 0 failures.
- **Note:** this edits `evaluate()`, which was under the hold — now permissible because the n ≥ 15 gate has closed. It is also the validation-safe corner of `evaluate()` (writes only displayed `truth`, which `SleepCompositeValidator` does not read).
- **Open decision:** branch placement — stack on `readiness-gate-hold-messaging` (thematic, but inherits that branch's dirty-tree/unopened-PR situation) vs. its own `feature/load-origin-gate-skip` off `main` (clean, independent; recommended).

### Dashboard routing bug — sleep-efficiency detractor → composite tile (presentation fix pending)

- The "lower sleep efficiency than your norm" detractor fires correctly off `sleepEffScore` (raw asleep/inBed vs 28-day median, threshold −0.04). But tapping it routes on label `"Sleep Efficiency"` → `.sleepEff`, whose title is `"Sleep Quality"` — the composite tile, which shows composite score vs composite baseline (e.g. 90 vs 79) and never surfaces the efficiency axis.
- By construction the two efficiencies diverge (engine = asleep/inBed; composite = SPT-trimmed), so on couch-sleep nights the tile the detractor lands on is most likely to look fine — the app appears to contradict itself.
- Not a mis-fire and not a scoring bug — a routing/labeling defect. Fix is presentation-only (efficiency-first content on the tile, optionally the composite sub-axis breakdown). Decoupled from — and must not wait for — the efficiency scoring questions in Phase 8's rework agenda.

### Branch / work ledger

- `main` @ `206637e` — sleep-composite work committed; pre-existing uncommitted WIP in tree (`ContentView`, `MetricDetailView`, `WeeklySummaryView`, untracked `WeeklySummaryTests`). OLD-WIP stash intact/untouched.
- `readiness-gate-hold-messaging` @ `f9dc7c7` — `action`-from-`rawTruth` decouple + count==0 ternary fix + gate-hold-aware messaging sourced in engine. Pushed, PR intentionally unopened. Caveat: 132-green was measured in a dirty tree; `git stash -u` + clean re-run before opening the PR.
- `feature/vo2max-capture` @ `a3812c4` — VO2max capture slice code-complete, unpushed. Gate before push/PR: one real strap-paired capture with stored HR verified against what the Watch showed. Queued: edit-window display-anchor fix (pickers reseed from marked start rather than `hrResolvedInterval`).
- Driver-aware gate fix — code-complete, awaiting branch decision + commit.

---

## Parallelization map

**Ran DURING the hold** (safe — no change to the readiness verdict): Phase 0 (recon) · Phase 1 (ingestion + trusted store, shadow-read only) · Phase 2 (status semantics — compute, don't wire) · Phase 3 (longevity evaluators + scheduler) · Phase 4 (load & recovery engine — additive) · Phase 5 (clinical / FHIR) · Phase 6 (projection / sync contract) · Phase 7 (VO2max estimator)

**Waits for validation to CLOSE** (the gated cutover — verdict may now change): Phase 8 (validation closure, composite driver swap, store cutover, status-into-verdict wiring, dead HRV buffer fix).

The Phase 1 quality guard is not merely parallel-safe — it actively cleans the validation set by quarantining corrupt nights (deep+REM == 0, or unspecified > 20%) before they enter the matured pairs.

---

## Phase 0 — Reconnaissance & pre-build hygiene

No code. Establish the ground truth every downstream decision inherits: enumerate current writers to each metric, confirm device UUIDs, map existing extractors vs. engines, and document where raw data currently lives. Exit gate: a written inventory of sources, identity, and current consumers of each metric.

---

## Phase 1 — Ingestion layer + trusted store (shadow-read only)

Build the five-stage pipeline as a shadow read — no consumer cutover, verdict untouched.

1. **Admission** — device-UUID whitelist; sole-writer enforcement per metric.
2. **Quality guard** — quarantine corrupt nights (deep+REM == 0, or unspecified > 20%). Highest-ROI rule; also cleans the validation set.
3. **Normalization** — HRV two-axis never merged; `ln(rMSSD)`; LOINC coding.
4. **Dedup** — one trusted source per metric.
5. **Store** — the trusted store, written but not yet read by consumers.

**Architecture sign-off (first real gate):** the canonical record shape + the three per-source identity keys — HealthKit = replace; clinical = identifier + type + source; EP mechanicalLoad = additive accumulator. Everything downstream inherits this.

Exit gate: shadow store populated and reconciled against live extractors; zero consumer behavior change.

---

## Phase 2 — Status semantics (compute the objects; do not wire to verdict)

Status = tuple { state, confidence, horizon } — state is direction-aware polarity, confidence is trust-tier, horizon is the validity window. Temporal-integrity rule: a flag moves only when truth could actually change — dense metrics via confirmation + hysteresis; sparse metrics via assay-lock (refuse-to-trend). Compute and persist these objects; do not feed them into the verdict yet.

Exit gate: status tuples computed and inspectable for every metric; verdict output byte-identical to pre-Phase-2.

---

## Phase 3 — Longevity evaluators + scheduler (fully orthogonal)

Independent longevity marker panel. No healthspan fusion score — longevity markers are evaluated independently, never blended into a single number and never merged with the readiness fusion. Scheduler emits interval pips for periodic markers.

Exit gate: longevity panel renders from its own evaluators; no coupling to readiness.

---

## Phase 4 — Load & Recovery engine (additive; surfaces its own flag)

Load and recovery signals as additive contributors. TRIMP is wired into the readiness load term; `mechanicalLoad` (EP → HD via App Group UserDefaults) is read but pending scoring decision.

**Step 4a — mechanicalLoad frequency probe.** Instrument how often the EP write fires per session. This is also the vehicle for confirming/resolving the double-write bug: diagnosed as whole-session double-counting (clean 2× ratio; identical values on three consecutive Sundays). The discriminating trigger (universal per-session double-write vs. Sunday-specific re-trigger) was unconfirmed when a data restore wiped App Group history. Prescribed fix: idempotent day-key accumulation guarded by session UUID.

**RESOLVED-BY-RESTORE / NOT REPRODUCIBLE (2026-08-27).** EP write-path recon: calculateMechanicalLoad is computed ONCE and the same value feeds both the session display and the App Group write (a REPLACE, not additive). Display and write cannot diverge in current code, so a 2x stored-vs-displayed is structurally impossible. The computation is a clean single flat pass over working sets — no warmup/per-side/nested double-count. The July 2x was a legacy/restore artifact, cleared when the restore wiped the App Group history. NO code fix applied or needed — the prior prescribed fix (idempotent += guard by session UUID) is SUPERSEDED: the write is not additive, so there is nothing to guard. Confirmation pending: one live-session measurement (compare EP displayed figure to stored raw for that date) to convert code-analysis to empirical close. Until then: not-reproducible-in-code, confirm-with-one-session.

Known debt — **durability gap:** App Group UserDefaults is the sole copy of mechanical-load history; no rehydration path survives a restore or reinstall.

Exit gate: probe confirms write frequency; double-write trigger identified; idempotent fix specified.

---

## Phase 5 — Clinical / FHIR ingestion

Read provider-synced labs via `HKClinicalRecord` (Clinical Health Records entitlement, read-only). Provider reference range stored separately from the optimal band — never conflated. FHIR-formatted results feed the longevity tier as its primary supply line.

Exit gate: clinical records ingested read-only into the longevity panel; reference-range vs. optimal-band separation verified.

---

## Phase 6 — Projection / sync contract

Governs what crosses to Watch/widget: horizon-filtered eligibility, provenance-stripped payloads, three explicitly tagged signal kinds — status flag / display value / scheduler pip. The horizon field doubles as refresh policy. Payload invariant to longevity platform size — adding markers must not grow the sync payload.

Exit gate: projection contract enforced; Watch payload size invariant to longevity additions.

---

## Phase 7 — VO2max estimator (parallel track — capture slice complete)

VO2max = the bridge keystone between readiness and longevity. Capture-first slice is code-complete (`feature/vo2max-capture`): `CardioCalibrationPoint` model, ACSM metabolic conversion, App Group persistence via `CardioCalibrationStore`, SwiftUI logging screen with workout-anchored HR resolution, delete/edit CRUD, optional provenance fields (`hrSampleCount`, `hrSourceName`, `hrResolvedInterval`, `workoutUUID`). Nothing wired to dashboard or verdict yet by design.

Capture protocol: steady-state segments 5–8 min at 60–85% max HR (≈102–145 bpm), 6–10 points in a rolling 90-day window, intensity spread across the submaximal range weighted over raw point count; each recorded as a strap-paired Apple Workout so HR lands in HealthKit.

Exit gate before push/PR: one real strap-paired capture with stored HR verified against the Watch. Queued: edit-window display-anchor fix.

---

## Phase 8 — Validation closure & cutover (GATED — now in rework-decision state)

Originally: on n ≥ 15 closure, swap the composite driver, cut the store over, wire status into the verdict, and fix the dead HRV buffer. The n ≥ 15 gate has closed — but with a null validation result, so the composite driver swap is contraindicated. The remaining Phase 8 items (store cutover, status-into-verdict wiring, dead HRV buffer fix) are unblocked in principle but should not assume a working composite.

**Remaining gated items:**

- **Store cutover** — consumers read the trusted store instead of live extractors.
- **Status-into-verdict wiring** — Phase 2 status tuples feed the verdict.
- **Dead HRV buffer fix** — the HRV buffer is unreachable behind a −1 floor clamp that precedes the buffer guard; fires every run. Confirmed via debug dumps.

### ⛔ Composite driver swap: RETIRED (2026-08-26 — see resolution note below)

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
is resolved.

### 🔬 Composite rework agenda — efficiency operationalization + driver status (2026-08-08)

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

Note: the dashboard-routing bug that surfaced these (efficiency detractor routes
to the composite "Sleep Quality" tile, which shows composite score vs composite
baseline and hides the efficiency axis) is being fixed SEPARATELY as a pure
presentation fix — it does not depend on and must not wait for Q1/Q2.

### ✅ RESOLVED (2026-08-26): Composite driver swap RETIRED — park as display

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
  wiring + dead HRV buffer fix. None depend on the composite.
- The "🔬 Composite rework agenda" (Q1 efficiency operationalization, Q2 efficiency-as-
  driver) is CLOSED: no composite axis drives the verdict, so the operationalization
  and driver questions are moot. The sleep-efficiency detractor remains a ReadinessEngine
  signal on its own terms (unchanged); the composite simply never enters the verdict.
- The validation hold on ReadinessEngine.evaluate() that gated all of this is now
  fully discharged — its purpose (decide the driver swap) is complete.

---

## Parked items / open-question ledger

- **Sleep composite rework decision** — null validation result; decide rework (drop Efficiency as scored, rebuild around Architecture/Consistency, re-validate) vs. park, before any downstream step assumes a working composite.
- **Efficiency operationalization (Q1) + efficiency-as-driver (Q2)** — resolve inside the composite rework session.
- **Driver-aware gate fix** — commit + branch placement decision.
- **Dashboard routing bug** — presentation-only fix; independent of the scoring questions.
- **VO2max** — real-capture HR check → push + PR; edit-window display-anchor fix.
- **mechanicalLoad** — Step 4a frequency probe; double-write idempotent fix; durability/rehydration debt.
- **Dead HRV buffer fix** — Phase 8.
- **Post-restore data degradation (cross-cutting):** restored history is lossy/laggy for derived scalars (mechanical-load history wiped; sleep window-bounds/axis availability degraded for days after a restore). Any validation/scoring run on a post-restore window is suspect until the window clears. Validator now flags degraded runs; no general rehydration guarantee exists. Same disease as the mechanicalLoad durability gap.
- **Phase 1 architecture sign-off** — canonical record shape + 3 identity keys; first brick of the trusted-store arc.
- **`readiness-gate-hold-messaging` PR** — `git stash -u` + clean re-run, then open.

---

## Methodology invariants (do not drift)

- No code before architecture sign-off. Each phase has explicit exit gates.
- **Recon before implementation:** read source files, locate anchors, confirm structure before authoring any prompt or diff. For this file specifically: confirm it is on disk first.
- Scoring logic lives in engines, never re-derived downstream. Messaging strings derive from the same computed values shown in the UI.
- Additive-only changes to existing consumers when extending data models.
- Named tunable constants for all weights and thresholds.
- Compute-once / display-many for bridge metrics; raw data stays in extractors.
- Observability before fixes — root cause confirmed via diagnostic reads before any code is written.
- Tests go red first to confirm aim before fixes are applied.
