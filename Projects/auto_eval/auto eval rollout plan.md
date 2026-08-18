---
updated: 2026-08-17
tags: [project, coding-pod, eval, auto-eval, llm-as-judge, plan]
---
# Rollout plan — judge-calibrated auto-eval for ED + clinic

Applies [[judge calibration protocol]] to both products. Sequenced by **what the data on disk
already allows**, not by calendar. Every phase has a gate that stops it rather than letting it
degrade silently.

## The two asymmetries that drive the sequence

Verified on disk, 2026-08-17. ED and clinic are **complementary, not sequential** — each is the
better site for a different half of Stage 1.

| | **ED** | **clinic** |
|---|---|---|
| best-labelled axis | **`pro` — 400/402** | **MDM levels — 62/63** |
| MDM level labels | 71 / 72 / 71 of 402 = **18%** | **62 of 63 = 98%** |
| …so the labelled slice is | a **non-random subset** — selection bias unknown | effectively **complete** — no selection bias |
| cross-family judge output already cached | ✅ `qh-0731-dev-set-93` (**gpt-5.4** 7,684 + **gemini-2.5-pro** 774 entries), `qh-0731-test-set-215` (gpt-5.4) | ❌ **none** — both caches are Claude |
| cross-family verifier in prod | ✅ `ed/verifiers.py` (GPT-5.4 + Gemini) | ❌ none |
| self-flip rate (`s_c`) measurable today | needs a multi-seed run | ✅ `repro-seed{1,2,3}` = **K=9 on 63** |
| criterion surface identified | ✅ 18 `llm_raw` booleans | ❌ **not yet — must be chosen** |

**Consequences.**

1. **ED gives a free Stage-1 pilot.** `qh-0731-dev-set-93` has 91 `pro` labels *and* both
   cross-family arms already in the model cache. A Stage-1 exam on `pro` there costs **zero new
   generator calls** — only judge calls.
2. **Clinic gives the clean MDM calibration.** 62 near-complete labels beat ED's 71 *selected*
   ones for calibration, because a labelled subset chosen by auditors may be enriched for errors,
   which biases both `q₀/q₁` and lift. Despite the smaller n, clinic is the better MDM site.
3. **Clinic must add a cross-family arm before Stage 1 can run at all** — it has no non-Claude
   judge, and a Claude judge over a Claude-Opus generator is self-preference by construction.

---

## Phase 0 — prerequisites

Nothing below runs without these. All are small.

| # | item | product | why it blocks |
|---|---|---|---|
| 0.1 | **Land `core/judge.py`** from `origin/citation-eval-on-main` (unmerged) | both | the judge primitive; writing a second one forks the seam ([[auto eval proposal]] WS-A1) |
| 0.2 | **Manifest the run dirs** — no `manifest.json` on `washington-402-baseline` | both | every number rests on unmanifested runs; a provider snapshot rotation is indistinguishable from a finding |
| 0.3 | **Check ED's MDM label selection** — compare the 71 labelled encounters against the 331 unlabelled on note length, disposition, acuity mix | ED | decides whether ED MDM lift is interpretable at all. **If enriched, ED MDM lift is void and clinic carries that axis** |
| 0.4 | **Choose clinic's criterion surface** — the `llm_raw` predicate set, not `guideline_report` (display-derived; judging it may be judging a renderer) | clinic | Stage 2 has no target without it |
| 0.5 | **Register clinic's abstention nodes** in `clinic/profile.py` | clinic | current-prod clinic DAG fails with "missing activities" until then |
| 0.6 | **Recover `abstention-rerun`'s verifier output** if it survives | clinic | would be a *free* cross-family arm on `v1_benchmark`; if gone, 1.3 pays for it |

**Gate:** 0.3 is the one that can redirect the plan. Run it first — it is a dataframe comparison,
no model calls.

---

## Phase 1 — Stage 1, the free pilot (ED `pro`)

**Site:** `qh-0731-dev-set-93`, axis `pro`, n=91 labels, both cross-family arms cached.
**Cost:** judge calls only; no generator calls.

| # | item |
|---|---|
| 1.1 | Build the C1/C2 item set over the `pro` ladder (99282→99285); rung-stratified, boundary-safe |
| 1.2 | Run pass **1a** (GT ± perturbation) on arms A (gpt-5.4) + B (gemini) + C (claude, as the leniency instrument) |
| 1.3 | Run pass **1b** (items = our own predictions) → the self-preference number |
| 1.4 | Report accept rates **as gaps**, per rung distance; κ + AC1 + raw agreement + prevalence; achieved MDE |

**Gates, in order:**

- `accept(C2 ±2+)` materially > 0 → **stop.** The judge is not reading the chart.
- `accept(C2 +1)` ≈ `accept(C1)` → **level/code judging is dead.** Skip to the criterion surface,
  and **C0 (COPA/RISK schema completion) becomes the critical path** ([[auto eval proposal]]).
- arm C ≫ A/B on pass 1b → self-preference confirmed → **clinic may never use a Claude judge.**

**Why this first:** it is the cheapest possible answer to "is any judge competent on ED coding",
and all three gate outcomes are informative. n=91 gives a ~10pp CI half-width — enough to see a
gap collapse, not enough to rank arms.

---

## Phase 2 — Stage 1, proper

Two independent runs, in parallel. Neither depends on the other.

### 2A · ED `pro` at full power

**Site:** `washington-402`, n=400 labels, base error rate **14.2%** (measured). No cross-family
cache here → judge calls are fresh.

- Dev/holdout split **100 / 300** — affordable only on this axis. Freeze the judge prompt before
  touching the holdout; version-pin with the `core/prompt_source.py` fingerprint.
- Weight `q₀` by the measured rung distribution: **56 of 57 errors are one rung**, so use the
  one-rung specificity almost exclusively.
- Report the over/under split (**9.2% over vs 5.0% under**) — the compliance direction.

### 2B · Clinic MDM levels, the clean site

**Site:** `v1-20260720-feedback-63-patch26`, 62 labels each on copa/data/risk/mdm.

- **Prerequisite: add a cross-family arm** (0.6 or a fresh GPT-5.4/Gemini run). This is the single
  highest-value clinic item in the plan — it is the only way to get a judge at all, and it doubles
  as the correctness signal clinic currently lacks entirely (its three votes are same-model, worth
  ~κ +0.05 by AutoRubric's measurement).
- No dev/holdout split is affordable at n=62. **So do not iterate the judge prompt here** — port
  the prompt frozen from 2A and treat 2B as pure holdout. Stated as a constraint, not a gap.
- Clinic-specific rubric fact the judge must be given: the billed level is **higher-of(MDM, time)**
  under AMA, and `input.csv` has **no time column**.

**Gate for both:** no PR curve, no ship. A detector without calibration is a draft
([[auto eval proposal]] §3 WS-B).

---

## Phase 3 — Stages 2 and 3

Runs only on the surface Phase 1/2 certified. Both products, same code.

| # | item | product |
|---|---|---|
| 3.1 | Measure `s_c` (self-flip) per criterion — clinic free from `repro-seed{1,2,3}` (K=9); ED needs one multi-seed run | both |
| 3.2 | Measure `j_c` (judge instability) — repeat-call + arm-vs-arm | both |
| 3.3 | Compute `e_c = 1−(1−s_c)(1−j_c)`, smoothed toward the pooled rate; **print per-criterion n** | both |
| 3.4 | Stage 2: one blinded call per criterion **per surviving arm** | both |
| 3.5 | Stage 3 queue: log-odds ranking, `w(c) = −log(e_c)` with `d_c` held constant (**honest v1**) | both |
| 3.6 | Stage 3 classes: one-sided binomial vs `e_c`, plus direction asymmetry | both |
| 3.7 | Queue schema **including `coder_verdict`** — the column that harvests `d_c` as a by-product | both |
| 3.8 | Measure lift on the labelled slice: ED `pro` (detectable ≥≈2×); clinic MDM if 0.3/n permits | both |

**Gate:** lift indistinguishable from 1× → the ranking is not earning its keep; ship class
discovery only, which needs no lift claim.

---

## Phase 4 — transfer to unlabelled data

The point of the exercise. Per new slice:

1. Recompute **`e_c`** on the slice (label-free) — do not transfer it.
2. Run the **four sentinels**: input-adequacy shift, `CANNOT_ASSESS` rate, arm–arm agreement, `e_c`
   drift. If 2 or 3 move materially against calibration, **transfer has broken** — say so instead
   of shipping the number.
3. Ship **ordering + class findings as measured**; carry lift over **explicitly labelled as
   transferred, not measured.**
4. For any population number: **30–50 anchor labels on that slice + PPI.**

---

## Sequencing summary

```
0.3 (ED label selection check)  ──► decides whether ED MDM is usable at all
0.1 (land core/judge.py)        ──► unblocks everything
        │
        ├─► Phase 1  ED pro pilot, dev-set-93, cached arms, ~free
        │       └─ gate: is any judge competent? which surface survives?
        │
        ├─► Phase 2A ED pro @ n=400          ┐ parallel, independent
        └─► Phase 2B clinic MDM @ n=62       ┘ (2B needs a cross-family arm first)
                    │
                    └─► Phase 3  Stages 2+3 on the certified surface, both products
                            │
                            └─► Phase 4  unlabelled slices, per customer
```

## What each product ends up with

| | ED | clinic |
|---|---|---|
| calibrated axis | `pro` (n=400, lift measurable ≥2×) | MDM levels (n=62, lift likely not measurable) |
| queue | yes, lift-backed | yes, ordering only |
| class discovery | yes | yes — **and this is clinic's main return**, since it is label-free and clinic's labels cannot support lift |
| biggest single unlock | recovering the discarded verifier criterion detail | **adding one cross-family arm** |

## Risks

- **0.3 comes back "enriched"** → ED MDM lift is void; clinic carries that axis alone at n=62.
- **Clinic criterion surface turns out to be display-derived only** (0.4) → clinic Stage 2 has no
  valid target, and the fix is a `qh-platform` schema change, not prompt work.
- **Level judging fails Phase 1's gate** → the critical path becomes **C0**, the COPA/RISK schema
  completion, which is a `qh-platform` change in a `.worktrees/` branch and not judge work at all.
- **Goodhart** → gating detectors frozen and version-pinned; any auto-eval-motivated prompt change
  validated on human labels before it ships.
