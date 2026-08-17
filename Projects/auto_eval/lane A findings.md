---
updated: 2026-08-13
tags: [project, coding-pod, eval, auto-eval, findings, phi-encounter-ids]
---
# Lane A findings — defects needing no human label

> **Contains encounter ids** (30 of them) — permitted per the harness repo's `CLAUDE.md`
> ("encounter ids are fine and may be cited"), and no note text, MRNs or vitals prose.
> Checked before this note was moved into the vault. Keep it that way: the citation table
> below deliberately says *"Text withheld."* rather than quoting spans.

Feeds [[auto eval roadmap]] Phase 0 and the Lane-A verdict in [[auto eval proposal]] §1.

> ## ⚠ REVISED 2026-08-13 after review — 1 of 5 classes survived
>
> Reviewed with the domain owner; four of the five claimed classes are **NOT defects**. Verdicts
> and the reason each died are below. The surviving class is **ED-2 (citation groundedness)**.
>
> | class | verdict | why |
> |---|---|---|
> | **ED-2** citation groundedness | **CONFIRMED** | `prompts/output_format_prompt.py` requires "**exact verbatim quote from the note**" in 8 places — a non-substring `cited_text` violates the stated contract by definition |
> | ED-1 critical-care gate | **DEAD** | 99291 is a **time-based** code (critically ill + ≥30 min). CPT's MDM two-of-three governs 99282–99285, **not** 99291. Billing 99291 at MDM=Moderate is not an over-code, so "2 of 3 CC bills are over-codes" was **wrong**. Residual is a prompt/code doc inconsistency whose only risk is *under*-documentation — which needs GT, so not lane A at all |
> | ED-3 count/list arithmetic | **REAL BUT INCONSEQUENTIAL** | `_calculate_data_points_from_two_stage` **prefers the list length**: `len(data_tests_ordered) if data_tests_ordered else data_tests_ordered_count`. The code uses 3, not 2. The count is vestigial back-compat. My "load-bearing" claim was backwards |
> | ED-6 RISK=High, 12 booleans False | **DEAD** | `risk_prompt.py` reaches High via pathways (a)–(f) — ICH concern, focal deficit, altered consciousness, mechanism, worsening neuro, anticoagulant+trauma+CT — **none of which maps to any of the 12 booleans** |
> | CL-1 / CL-1b clinic time | **DEAD** | `transform_v1.py:508` **hardcodes** `"criteria_met": True` as a **front-end styling flag** ("makes this a decision-based criteria row on the FE"), not a semantic assertion. And the real risk is already handled: `_usable_time_code` requires usable **and** attributable time, with `level=""` so the FE **hides the chip** (QEU-299 / QEU-303) |
>
> **Corrected meta-result: the false-lead rate on hand-built *deterministic* checks was ~80%, not
> the ~30% first reported.** No judge, no sampling noise — just checks misreading a rule. All four
> deaths came from reading the prompt, the CPT rule, or the transform. **None** would have been
> found by running on more encounters.
>
> **What survives conceptually, and matters more than any of the above:** three of the four deaths
> share one cause — **the criterion booleans are a lossy decomposition of the coding rules.** COPA
> reaches High via pathways mapping to no boolean; RISK via six such pathways; and identical
> boolean vectors map to different declared levels (copa 4 of 8, data 6/9, risk 9/33). One systemic
> property, not three quirks, and it is the load-bearing input to the tier-4 surface decision.
>
> The per-instance enumerations below are left intact as the measurement record. Read every class
> other than ED-2 as "the detector fired", **not** "the pipeline is wrong."

Measured 2026-08-13. **ED:** `ed/experiments/washington-402-baseline/results/run1` (n=402, dataset
`washington-402`). **Clinic:** `clinic/experiments/repro-tool-codes/results/run1` (n=63, dataset
`v1-20260720-feedback-63-patch26`, id-verified 63/63 against `input.csv`).

Lane A = the output contradicts itself, or contradicts the spec, on inspection. No ground truth,
no judge, no adjudication. Encounter ids only; no note text.

⚠ Both run dirs lack `manifest.json`, so the qh-platform revision is unrecorded. Re-confirm under
a manifested run before filing.

---

## ED — confirmed

### A1 · Critical-care gate: prompt and code implement different rules
**2 encounters billed 99291 on a Moderate-MDM chart.**

| | |
|---|---|
| code | `business_logic.py::check_critical_care` → `gate1 = copa_level == "High"`, and the docstring restates it: "Gate 1 — COPA level is High" |
| prompt | `prompts/critical_care_prompt.py:10-12` → "Gate 1: MDM = High … at least two of COPA/DATA/RISK are High. **A COPA-High alone is NOT sufficient if the overall MDM is not High**" |

The code implements exactly what the prompt calls insufficient.

- Code-gate-1 population (COPA=High ∧ vital-organ impairment): **39 / 402**
- Of those, MDM ≠ High → prompt/code diverge: **6** — `944167712` `944376884` `944624102` `944647046` `944768788` `946082827`
- **Actually billed 99291 anyway: 2**
  - `944376884` — COPA High / DATA Moderate / RISK Moderate, 37 min, pro=fac=99291
  - `946082827` — COPA High / DATA Low / RISK Moderate, 37 min, pro=fac=99291

Critical-care time is documented in only 3/402 encounters, so **2 of the 3 critical-care bills in
this run would not exist under the prompt's stated rule.**

Disposition `system` · locus `business_logic.py::check_critical_care` (gate1 branch) · fix class:
one-line gate change, or correct the prompt — but the divergence is real either way. qh-platform
change ⇒ `.worktrees/` branch.

### A2 · Citations that are not quotes
**100 spans ≥120 chars with no clause found verbatim** in `note + order_summary + med_summary +
raw consolidated_notes`, whitespace-normalized and case-folded, across **83 / 402 (20.6%)**
encounters. Text withheld.

| span chars | encounter | axis | declared level |
|---|---|---|---|
| 418 | `944288759` | risk | Moderate |
| 378 | `948536058` | copa | Moderate |
| 248 | `944772322` | copa | Moderate |
| 248 | `944702885` | copa | High |
| 235 | `946926617` | copa | Moderate |

A quote that is not a quote is a defect whatever the final code was. **Must be checked
whitespace-normalized** — exact matching reports 46.9% grounded vs 70.0% normalized, a ~23-point
false-positive rate.

### A3 · Internal arithmetic contradiction
`944640641` — `tests_ordered_count = 2` but `len(tests_ordered) = 3`. Load-bearing: DATA points
are re-derived from the count, so the discrepancy can move the DATA level. 1 / 402.

## ED — checks that fired but were wrong (mine, not the pipeline's)

- **COPA=High with all 3 COPA booleans False** (`944527652` `947184317` `947309002`). *Not* a
  contradiction: `copa_prompt.py:45` reaches High via "(a) condition CONFIRMED / working diagnosis"
  or "(b) named acute high-morbidity differential + workup ordered", and **neither pathway maps to
  any of the three booleans**. Reclassified: evidence the boolean schema is a **lossy decomposition
  of the rules** — the same root cause as identical boolean vectors mapping to different levels
  (copa 4 of 8 vectors, data 6/9, risk 9/33). Routes to the tier-4 surface design, not to a fix.
- **RISK=High with all 12 booleans False** (`948425276` `948723186`). **Candidate**, not confirmed.
  `risk_prompt.py` says "at least ONE of these must be present" for High, but I did not prove the
  12 booleans exhaust the High criteria list. *Check that decides it: map the prompt's High list
  onto the boolean schema.*
- **Facility rationale-vs-code rescue inconsistency: 0 / 402.** **Output-format failures
  (`stop_reason`, node error, `UNDETERMINED`): 0 / 402.** Regression guards, not mining tools.

---

## Clinic (patch26) — confirmed

### B1 · "Documented Total Time" is asserted met on every encounter
`criteria_met` for that criterion is **True in 62 / 62** encounters where it appears — it never
varies. Meanwhile:

| criterion met | `time_level` populated | note mentions time | n |
|---|---|---|---|
| ✓ | — | — | **43** |
| ✓ | — | ✓ | 12 |
| ✓ | ✓ | — | 4 |
| ✓ | ✓ | ✓ | 3 |

- Met but the pipeline's own `time_level` is **empty: 55 / 62**
- …and the note contains **no time reference at all: 43** — e.g. `829185341` `831379796`
  `897497054` `897731440` `898193119` `934570475` `934746775` `946275559`
- `time_level` is populated in only **7 / 62**

Clinic's `input.csv` has **no time column** (columns are enc/patient/department/payer/dx/notes), so
the note is the only possible source, and only **15 / 63** notes mention time at all.

Why it matters: time can set the billed level *by itself* under the AMA higher-of rule — confirmed
live below (B2), including one encounter at MDM level 2 / time level 5 → 99215. A guideline report
that tells a coder "Documented Total Time ✓" on all 62 charts, with no citation and with the
pipeline's own time field empty on 55 of them, is an audit exposure.

Locus: the `guideline_report` transform, most likely — 62/62 constancy points to a renderer or
derivation bug rather than a per-encounter model assertion. *One look at the transform settles
which, and that decides whether the fix is a prompt or a renderer.*

## Clinic — clean negatives (worth having)

- **Modifier-25 pairing: 0 contradictions.** All 12 modifier-25 encounters carry a preventive+E/M
  pair; no pair is missing the modifier.
- **Two-of-three median vs `mdm_level`: 0 / 63 mismatches.**
- **Higher-of(MDM, time) vs billed E/M level: 0 / 63 mismatches.** My first pass reported 5 —
  `948585353` `963638826` `963951904` `964768492` `965015825` — because it ignored `time_level`.
  All five are MDM 4 (one MDM 2) with time level 5 → 99215, which is correct under the AMA rule.
  My error, not the pipeline's.

---

## The meta-result

Ten candidate detectors: **4 confirmed** Lane A defect classes, **3 clean negatives**, **3 fired
but were my checks being wrong** (COPA pathway, clinic time-vs-code, clinic higher-of).

A ~30% false-lead rate on hand-built *deterministic* checks — where there is no judge and no
sampling noise, only a misread rule — is the argument that the calibration phase is not optional
even for Lane A. Every one of the three was caught by reading the prompt or the AMA rule the check
claimed to encode. None would have been caught by running it on more encounters.
