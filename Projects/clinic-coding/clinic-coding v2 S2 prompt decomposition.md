---
updated: 2026-09-10
tags: [project, coding-pod, clinic-coding, prompt, experiment, handoff, S2]
---
# Clinic coding v2 · S2 — prompt decomposition: one prompt per code

> **PHI-free.** No encounter ids, MRNs, note text or patient prose. Prompt rule text, CPT
> literals, character counts and dataset row counts only. Keep it that way.

> [!info] This is the runnable spec
> Split the single 86,490-char ambulatory prompt into **one prompt per code**, with the four
> MDM/time axes each getting their own call: **COPA · DATA · RISK · TIME**, plus the existing
> preventive/AWV/Mod-25 cluster. Python assembles the billed code from the axis levels.
> Analysis and prompt anatomy: [[clinic-coding v2 prompt decomposition plan]].
> Prior stage (and its measured results): [[clinic-coding v2 S1 prompt simplification - deterministic logic removal]].

---

## 0 · Baseline & prerequisites

| item | value |
|---|---|
| repo | `qh-platform` @ `cb8ea1a591` (develop) |
| prompt version | `PROMPT_VERSION = "1.3"` |
| prompt size | 86,490 chars |
| prompt source | `packages/rcm/clinical_coding/clinical_coding/prompts/system_prompt.py` |
| knowledge base | `packages/rcm/clinical_coding/clinical_coding/prompts/knowledge_base.py` |
| package tests | 494 pass, ~0.3 s |

> [!warning] Three things to know before starting
> - **S1 has NOT landed.** Its arms were in-memory `--patches`; the on-disk prompt is untouched
>   V1.3. Land S1 first (§10) — `rm-newpt` is measured at Δ+0.0 on the holdout, so the Patient
>   Status block should come out regardless, and its removal means no axis prompt has to carry
>   series reasoning.
> - **Abstention is live again.** #6089 reverted the drift and restored
>   `abstention_enabled: true` / `abstention_policy: consensus_or_corroborated`, so GPT-5.4 +
>   Gemini verifiers run and the gate can mask. Any change to `confidence` moves prod masking.
> - **Line numbers drift.** Every block in §4 leads with a **grep anchor**, verified to match
>   exactly one line at `cb8ea1a591`. Line numbers are hints. Re-verify before editing.

```bash
cd /Users/taoyangfu/workspace/qh-platform
git rev-parse --short HEAD                       # expect cb8ea1a591, else re-verify anchors
cd packages/rcm/clinical_coding && .venv/bin/python -m pytest tests -q
```

---

## 1 · Goal and the question that decides it

**Goal.** One prompt per code. For the office E/M code that means one prompt per *axis* —
COPA, DATA, RISK, TIME — each producing its own level or facts, with the deterministic layer
computing the grid middle, the series flip, the time supersede and the prolonged add-on.

**The question is sufficiency, not size.** Each axis prompt must be able to label its axis
*alone*, with no sight of the other two. Everything in §5 exists to make that true, and §9 is
how it gets proven.

> [!danger] S1 already measured the risk, and it is a lower bound
> S1's `rm-mdm` arm deleted only the **two-of-three arithmetic block** and degraded
> `risk` **−2.9 (3.2 SE)** and `mdm` **−2.8 (2.4 SE)** on the 177 set — while *improving* holdout
> `em exact` +1.7. S2 removes the joint framing **permanently and completely**, so treat that
> regression as the floor of what decomposition can cost, not the ceiling.
>
> The mechanism matters: only **2 lines / 163 chars** of the whole prompt are explicit cross-axis
> boundary rules (§4.5), so S1's damage was **not** shared rule text going missing. It was the
> *arithmetic scaffolding* — being asked to compute the middle appears to make the model grade
> each axis more carefully. §5.4 is the proposed replacement for that pressure, and it is the
> untested hypothesis this whole lane exists to evaluate.

---

## 2 · Why it is close to size-neutral

The three structures that look like they would have to be triplicated all slice cleanly, because
the rubric and grid are **level-major** and merely need transposing to **axis-major**:

| joint structure | today | sliced per axis | net |
|---|---:|---|---:|
| AMA per-level rubric (`#### <Level> MDM` ×4) | 3,871 | COPA 852 · DATA 1,837 · RISK 1,046 | **−136** |
| Mercy MDM Complexity Grid table | 2,382 | COPA 725 · DATA 761 · RISK 948 | +52 |
| Few-shot calibration | 5,265 | COPA 3,449 · DATA 2,722 · RISK 3,080 | +3,986 |

Each `#### Moderate MDM` block is literally `- **COPA**: … / - **Data**: … / - **Risk**: …`, so
the transpose is a re-grouping of text that already exists — not new authoring. Only the
few-shot sets cost real duplication: each example's `**Chart:**` line (2,384 total) has to appear
in all three axis prompts, while its `**MDM = 2/3 …**` line (782) is dropped outright.

~1,450 chars of MDM-integration text disappear entirely (two-of-three block, `MDM:` output line,
the `mdm` fence key + spec bullet, the joint `MDM =` example lines) because Python owns that
arithmetic. That offsets most of the duplication.

---

## 3 · Per-axis prompt budgets

| axis | axis rules | rubric | grid | few-shot | FAQ | framing | fence | **total** | % of today |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| COPA | 15,903 | 852 | 725 | 3,449 | 837 | 1,273 | ~350 | **23,389** | 27.0% |
| DATA | 12,506 | 1,837 | 761 | 2,722 | 585 | 1,273 | ~350 | **20,034** | 23.2% |
| RISK | 5,951 | 1,046 | 948 | 3,080 | — | 1,273 | ~350 | **12,648** | 14.6% |
| TIME | 4,913 | — | — | — | — | 1,273 | ~350 | **6,536** | 7.6% |
| | | | | | | | | **62,607** | **0.72×** |

Plus the preventive/AWV/Mod-25 cluster (~22k, unchanged) → **~84.6k across 5 prompts** against
today's 86.5k single prompt. Roughly flat.

TIME needs no rubric, grid or few-shot slice: post-QHE-2854 it emits facts only
(`documented` / `total_minutes` / `attributable_to_em` / `source_quote`). Lowest-risk cut.

---

## 4 · The axis-major transpose, specified per block

All anchors verified unique at `cb8ea1a591`. `sp` = `prompts/system_prompt.py`,
`kb` = `prompts/knowledge_base.py`.

### 4.1 COPA prompt — 23,389 chars

| file | grep anchor | line | chars | action |
|---|---|---:|---:|---|
| sp | `^\*\*1\. COPA` | 49 | 198 | copy verbatim |
| sp | `^CRITICAL COPA RULES` | 53 | 7,778 | copy verbatim (incl. the V1.3 hunks) |
| kb | `^### Number and Complexity of Problems Addressed` | 77 | 1,519 | copy verbatim |
| kb | `^#### Problem Definitions` | 85 | 6,606 | copy verbatim |
| kb | `^#### Straightforward MDM` … `^#### High MDM` | 34–65 | 852 | **transpose** — take only the `- **COPA**:` bullet + its sub-bullets from each of the 4 level blocks; emit as one four-rung COPA ladder |
| kb | `^### MDM Complexity Grid` | 196 | 725 | **slice** — column 2 (COPA) of each level row, with the level label re-attached |
| sp | `^## FEW-SHOT EXAMPLES` … `^### How to use these examples` | 341–401 | 3,449 | **slice** — keep `### Example …` title + `**Chart:**` + `**COPA reasoning:**`; drop `**Data:**`, `**Risk:**`, `**MDM = …**` |
| kb | `^### Mercy FAQ` | 228 | 837 | **slice** — 2 Qs: "referring a patient … count as a problem addressed" + "complicated vs uncomplicated condition" |

### 4.2 DATA prompt — 20,034 chars

| file | grep anchor | line | chars | action |
|---|---|---:|---:|---|
| sp | `^\*\*2\. DATA` | 93 | 258 | copy verbatim |
| sp | `^### STEP A —` | 96 | 2,355 | copy verbatim |
| sp | `^### STEP B —` | 123 | 3,947 | copy verbatim |
| sp | `^### STEP C —` | 151 | 1,362 | copy verbatim |
| sp | `^### STEP D —` | 165 | 1,432 | copy verbatim |
| sp | `^### Required output for Data line` | 189 | 569 | copy, re-point at the DATA fence |
| kb | `^### Amount and/or Complexity of Data` | 137 | 2,583 | copy verbatim |
| kb | `#### … MDM` ×4 | 34–65 | 1,837 | **transpose** — the `- **Data**:` bullet + Category 1/2/3 sub-bullets from each level → one four-rung DATA ladder |
| kb | `^### MDM Complexity Grid` | 196 | 761 | **slice** — column 3 (Data) |
| sp | few-shot span | 341–401 | 2,722 | **slice** — title + `**Chart:**` + `**Data:**` only |
| kb | `^### Mercy FAQ` | 228 | 585 | **slice** — 2 Qs: "clinical laboratory panel … multiple tests" + "x-ray I ordered and interpreted myself … independent interpretation" |

### 4.3 RISK prompt — 12,648 chars

| file | grep anchor | line | chars | action |
|---|---|---:|---:|---|
| sp | `^\*\*3\. RISK` | 200 | 2,418 | copy verbatim |
| sp | `^CRITICAL RISK RULES` | 212 | 2,165 | copy verbatim |
| kb | `^### Risk of Complications and/or Morbidity` | 159 | 1,368 | copy verbatim |
| kb | `#### … MDM` ×4 | 34–65 | 1,046 | **transpose** — the `- **Risk**:` line from each level → one four-rung RISK ladder |
| kb | `^### MDM Complexity Grid` | 196 | 948 | **slice** — column 4 (Risk) |
| sp | few-shot span | 341–401 | 3,080 | **slice** — title + `**Chart:**` + `**Risk:**` only |

### 4.4 TIME prompt — 6,536 chars

| file | grep anchor | line | chars | action |
|---|---|---:|---:|---|
| sp | `^\*\*5\. Time-Based` | 235 | 252 | copy verbatim |
| sp | `^DO NOT use time-based coding` | 240 | 509 | copy verbatim |
| sp | `^\*\*WHOSE TIME COUNTS` | 248 | 427 | copy verbatim |
| sp | `^\*\*WHAT TIME COUNTS` | 253 | 918 | copy verbatim |
| sp | `^\*\*RULE FOR MIXED PREVENTIVE` | 260 | 1,014 | copy verbatim |
| kb | `^### Time-Based Code Selection` | 169 | 1,020 | copy verbatim |
| kb | `^### Time-Based Billing` | 243 | 773 | ⚠️ **strip before copying** — see below |

> [!bug] The KD2 time section still contains the minute→code tables QHE-2854 claims to have cut
> `### Time-Based Billing (Office/Outpatient)` carries, verbatim:
> `New Patients: 99202=15min, 99203=30min, 99204=45min, 99205=60min`, the established
> equivalent, **and** the prolonged thresholds (`G2212` at 89/69 min, `99417` at 75/55 min).
> QHE-2854's changelog says it "cut the two AMA minute-to-code tables" and `business_logic.py`
> states "the prompt no longer states the table" — both are wrong about this block.
>
> The TIME prompt must be **facts only**: keep the "Time includes / does NOT include" lists,
> **delete every minute→code mapping and every prolonged threshold.** Python owns both
> (`time_based_code_from_minutes_and_new_patient`, `_PROLONGED_FIRST_UNIT_THRESHOLD`). Leaving
> them in re-anchors the model on a code it is no longer asked to produce.

### 4.5 Shared into every axis prompt — 1,273 + 163 chars

| file | grep anchor | line | chars | note |
|---|---|---:|---:|---|
| sp | `^## INSTRUCTIONS` | 32 | 361 | copy into all |
| sp | `^## CODING PRIORITY HIERARCHY` | 39 | 912 | copy into all, **trimmed** of code-selection language |
| sp | `^- A prescription elevates RISK, not COPA` | 56 | 93 | **duplicate into COPA and RISK** |
| sp | `order elevates RISK, not COPA` | 82 | 70 | **duplicate into COPA and RISK** |

Those last two are the *only* explicit cross-axis boundary rules in the entire prompt. They are
what stops COPA from absorbing a Risk signal once it can no longer see the Risk verdict, and they
cost 163 chars to duplicate. **Do not assign them to one axis.**

### 4.6 Dropped entirely — ~1,450 chars

| file | grep anchor | line | chars | why |
|---|---|---:|---:|---|
| sp | `^\*\*4\. MDM Level` | 230 | 333 | Python: `_mdm_grid_middle` |
| sp | `^MDM: \[Straightforward` | — | 138 | no joint output block any more |
| sp | `Middle=\[level\]` | — | 95 | ditto |
| sp | `"mdm": \{"level"` | — | 105 | fence key, zero readers |
| sp | `^- "mdm": the four levels` | — | 95 | fence spec bullet |
| sp | few-shot `^\*\*MDM = ` lines | — | 782 | the joint verdict line in each example |

`mdm.copa_level` / `data_level` / `risk_level` have **zero readers** — the aggregate takes levels
from `detail["copa"]["level"]` etc. Dropping the whole object costs nothing.

---

## 5 · The sufficiency contract

Each axis prompt must satisfy all five. 1–3 are mechanical; **4 and 5 are the new work.**

- [ ] **S5.1 · Complete axis-major ladder.** All four rungs — AMA rubric bullet + Mercy grid
      column — so the axis has a self-contained scale rather than one rung of a joint table.
- [ ] **S5.2 · Boundary rules duplicated.** The 163 chars from §4.5 present in every axis they
      constrain.
- [ ] **S5.3 · Own few-shot set.** Chart + that axis's verdict only, `MDM =` line stripped.
- [ ] **S5.4 · A within-axis discriminative check — the replacement for the two-of-three
      scaffolding.** Require the prompt to name **which rung of its own ladder fired, and why the
      rung above and the rung below do not.** This restores consistency pressure without
      reintroducing the other axes. **Untested — this is the lane's central hypothesis.** If an
      axis fails §9, this is the first thing to strengthen.
- [ ] **S5.5 · An explicit "insufficient documentation" value.** See §7 — without it a failed
      axis silently down-codes.

---

## 6 · What is already built

| piece | status |
|---|---|
| grid middle → code → series flip → time supersede → prolonged | **done** — `apply_v1_post_processing` derives the billed E/M from the three component levels today. Feed it three independently-produced levels and it works unchanged. |
| per-element majority voting | **done** — #5896's `_majority_level(votes, elem, default)` already votes COPA/DATA/RISK **independently** with a median-by-severity tie rule. Written for a joint call but axis-major by construction. |
| time-card voting | **done** — `_majority_time_card` votes the fact triple as a coherent unit. |
| plumbing | **to do** — the aggregate takes one list of joint votes; it needs per-axis vote lists. Same algorithm, new wiring. |

The deterministic side needs **no new logic** for this change. That is the single strongest
argument for the approach.

---

## 7 · New failure mode introduced by decomposition

> [!danger] A failed axis call silently down-codes the encounter
> `_majority_level` falls back to **`"Straightforward"` — the lowest rung** — when no vote reports
> a level. #5896 added a log warning for it, nothing more. Today one joint call failing loses the
> whole encounter *visibly*. With four independent calls, one failed axis produces a plausible,
> complete, **under-coded** result while the other three look healthy.
>
> S5.5 is the fix: an explicit "insufficient documentation" value per axis, surfaced rather than
> defaulted. Wire it to the abstention gate, not to the lowest rung.

---

## 8 · Proposed DAG and vote allocation

```
input → rcm-format/split/upload-notes
  ├─→ clinic-copa-extract  ×3  (~23k)  → copa level + problems + citations
  ├─→ clinic-data-extract  ×3  (~20k)  → data level + cat1/2/3 point tree
  ├─→ clinic-risk-extract  ×3  (~13k)  → risk level + actions
  ├─→ clinic-time-extract  ×1  (~7k)   → documented / minutes / attributable
  └─→ clinic-prev-extract  ×3  (~22k)  → preventive_type + AWV + mod25 + rationale
            ↓  per-axis element-wise majority (reuse _majority_level / _majority_time_card)
      clinic-mdm-assemble   — NO LLM: grid middle → code → series flip → time supersede → prolonged
            ↓
      clinic-postprocess → clinic-abstention-gate → transform-clinical-coding-v1
```

| dimension | today | after (flat 3 votes) |
|---|---|---|
| heavy LLM calls / encounter | 3 | 13 |
| input chars / encounter | 259,470 | ~241,000 (**−7%**) |
| prompt cache entries | 1 | 5 |
| vote keys | 1 (`em_code`, serves everything) | 4 axis levels + preventive type |

**Vote budget becomes allocatable by measured difficulty** — a joint call cannot do this. DATA
sits at 70.7% and is the weakest axis by ~10 points; TIME is fact extraction. Run DATA at 5 votes
and TIME at 1 if the numbers say so. Free knob, worth using.

---

## 9 · Sufficiency test — the acceptance criterion

The 177 set carries **per-element GT**, so every axis prompt can be validated *in isolation*
against the S1 `base` arm (10 draws, the fresh comparator):

| axis | joint-prompt baseline | ship gate |
|---|---:|---|
| COPA | 89.2 | solo ≥ 89.2 |
| DATA | **70.7** | solo ≥ 70.7 |
| RISK | 80.8 | solo ≥ 80.8 |
| mdm (derived from the three) | 85.3 | solo ≥ 85.3 |
| em exact · 177 | 83.8 | ≥ 83.8 |
| em exact · v1_benchmark (holdout) | 89.5 | ≥ 89.5 |

Plus the S1 integrity checks, which carry over unchanged: `n` identical to `base` per axis/draw,
zero `"ok": false` stubs, and a **blank-level count** equal to base's (the silent-failure canary,
now four times as important — see §7).

**This is what decomposition buys.** S1's `risk`/`mdm` regression could not be attributed to a
cause because a joint prompt cannot tell you which axis took the damage. Here every axis has its
own number, its own baseline and its own fix.

Scorers, unchanged from S1:

```bash
# from ~/workspace/coding-ai-harness — NEVER pipe `source env.sh` (subshell loses exports)
export QH_PLATFORM_ROOT=<path-to-feature-worktree>
source scripts/env.sh
PYTHONPATH=. $PY clinic/experiments/copa-under-177/score177.py <arm-slugs>   # per-element
PYTHONPATH=. $PY clinic/experiments/s1-detlogic/score_v1b.py  <arm-slugs>    # holdout em
```

A prompt change invalidates the model-I/O cache signature, so `--seed 0` will not replay: each
arm runs live on Opus. Cost gotchas: [[coding-ai-harness-synthetic-prolonged]] *(Claude memory,
not a vault note)*.

---

## 10 · Staging

**Land S1 first.** Measured, prompt-only, and `rm-newpt` costs nothing on the holdout (Δ+0.0).
Its removal also means no axis prompt has to carry series reasoning.

| stage | cut | why this order |
|---|---|---|
| **D1** | **TIME** | no rubric/grid/few-shot to slice; already fact-only; ~7k; and it forces the §4.4 minute-table strip, which is a bug fix either way |
| **D2** | **DATA** | most isolated axis (its coupling row is ~all zeros), weakest accuracy (70.7) so most upside, and ED's `data_prompt.py` questionnaire is a ready template |
| **D3** | **RISK**, then **COPA** | COPA last: largest axis, carries the QHE-3555 calibration, and its few-shot slice is the one most likely to lose something |

Each stage is one arm against the S1 `base` on **both** datasets, scored per-axis on the 177 set.
An axis that fails §9 gets fixed in its own prompt — the point of the exercise.

---

## 11 · Do NOT do in S2

| item | why |
|---|---|
| split COPA/DATA/RISK **grading** without S5.4 | S1 showed removing the joint arithmetic alone costs risk −2.9 / mdm −2.8. Decomposition removes strictly more. The within-axis discriminative check is not optional. |
| touch the preventive/AWV/Mod-25 cluster | separate seam, separate stage; and its metric is broken (§12) |
| rewrite the few-shot **content** | slice it, do not re-author it. QHE-3555 tuned this to 95% and the examples are the calibration. |
| delete MERCY RULE D | not dead — fires on ~13% of real encounters, its verdict is discarded by the DPC. Escalate to RCM, do not cut. See the analysis note. |
| ship on the 177 set alone | v1_benchmark is the holdout and carries essentially all the new-patient signal |

---

## 12 · Open items

> [!question] D-1 · Is S5.4 the right replacement for the two-of-three pressure?
> The whole lane rests on it. If D2/D3 show an axis below its gate, try strengthening the
> within-axis discriminative requirement **before** concluding decomposition does not work.

> [!question] D-2 · Does the preventive axis metric work at all?
> `prev` reads **18.6% on every S1 arm and every one of 26 draws, to the decimal.** A metric that
> never moves measures nothing — almost certainly a GT-coverage or denominator artifact. Diagnose
> before the preventive cluster becomes its own call, or its D-stage results are unreadable.

> [!question] D-3 · Per-axis confidence → abstention mapping
> The gate reads one `confidence` and gates only E/M. With four axis confidences, decide whether
> it gates on the minimum, on the assembled E/M, or per-axis. Abstention is **live in prod**
> (#6089), so this changes what coders see.

---

## 13 · Related

- [[clinic-coding v2 prompt decomposition plan]] — investigation: prompt anatomy, per-code budgets, coupling
- [[clinic-coding v2 S1 prompt simplification - deterministic logic removal]] — prior stage + measured results
- [[clinical-coding-v1]] · [[clinical-coding-v2]]
- ED coding is the in-repo precedent for axis-major prompt modules:
  `packages/rcm/ed_coding/ed_coding/prompts/` has `copa_prompt.py` (88,849), `risk_prompt.py`
  (72,756), `data_prompt.py` (13,557) plus `DATA_QUESTIONNAIRE_SYSTEM_PROMPT` (6,965) and
  `RISK_QUESTIONNAIRE_SYSTEM_PROMPT` (6,327) as **separate LLM calls** whose answers are injected
  into the scoring call via `build_combined_pass2_content`. Note ED kept COPA/DATA/RISK together
  in its 190,509-char `PRO_SYSTEM_PROMPT` — it split *fact extraction* from *grading*, not the
  axes from each other. S2 goes further than ED has validated.
