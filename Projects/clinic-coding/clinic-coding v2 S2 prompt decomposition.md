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
> preventive/AWV/Mod-25 cluster. Each axis call still emits **its own level**; Python assembles
> the billed code. *Moving level derivation into Python is deliberately **not** in S2* — that is
> [[clinic-coding v2 S3 prompt deterministic logic decomposition]].
>
> Analysis and prompt anatomy: [[clinic-coding v2 prompt decomposition plan]].
> Prior stage + measured results: [[clinic-coding v2 S1 prompt simplification - deterministic logic removal]].

> [!danger] READ THIS FIRST — S2 is not greenfield
> A six-call per-axis decomposition **already exists, was measured on two datasets, and reached a
> ship candidate**: `coding-ai-harness/clinic/experiments/clinic-prompt-decomposition`
> (~26.7k lines, as of 2026-08-04). Calls: `visit` · `copa` · `data` · `time` · `risk` ·
> `separability`. Ship arm `7e-clean`.
>
> **Reading order: `STATUS.md` → `SUPERSEDED.md` → only then `plan.md`.** `plan.md` is a
> chronological log whose confidently-stated numbers were later overturned in 19 indexed places;
> `SUPERSEDED.md` is that index. Do not quote a `plan.md` number without checking it.
>
> Their measured verdict, verbatim: *"We can say V2 does not break anything. We cannot say it is
> better. The durable output of this work is the diagnostics, not the accuracy."* Zero of the 66
> ship-candidate comparisons were statistically significant on either dataset.
>
> **S2's real contribution is therefore their open item E-6 — productionisation (DAG, node UUIDs,
> verifier split, `parity_replay`), which their status lists as "not started"** — plus a
> re-measurement on the 177 set with #5896's native element-wise voting. See §10 and §14.

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
| prior experiment | `~/workspace/coding-ai-harness/clinic/experiments/clinic-prompt-decomposition` |

> [!warning] Three things to know before starting
> - **S1 has NOT landed.** Its arms were in-memory `--patches`; the on-disk prompt is untouched
>   V1.3. Land S1 first (§10) — `rm-newpt` measured Δ+0.0 on the holdout, so the Patient Status
>   block should come out regardless, and its removal means no axis prompt carries series
>   reasoning.
> - **Abstention is live again.** #6089 restored `abstention_enabled: true` /
>   `abstention_policy: consensus_or_corroborated`, so GPT-5.4 + Gemini verifiers run and the gate
>   can mask. Any change to `confidence` moves prod masking.
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
COPA, DATA, RISK, TIME — each emitting its own level or facts, with the deterministic layer
computing the grid middle, the series flip, the time supersede and the prolonged add-on.

**The question is sufficiency, not size.** Each axis prompt must label its axis *alone*, with no
sight of the other two. §5 is what makes that true; §9 is how it gets proven.

> [!danger] S1 already measured the risk, and it is a lower bound
> S1's `rm-mdm` arm deleted only the **two-of-three arithmetic block** and degraded
> `risk` **−2.9 (3.2 SE)** and `mdm` **−2.8 (2.4 SE)** on the 177 set — while *improving* holdout
> `em exact` +1.7. S2 removes the joint framing **permanently and completely**, so treat that
> regression as the floor of what decomposition can cost, not the ceiling.
>
> The mechanism matters: only **2 lines / 163 chars** of the whole prompt are explicit cross-axis
> boundary rules (§4.5), so S1's damage was **not** shared rule text going missing. It was the
> *arithmetic scaffolding*. §5.4 is the proposed replacement, and it is this lane's central
> untested hypothesis — **partly refuted already for RISK** (see §5).

---

## 2 · The transpose is nearly free — but prompt size is not the cost

The rubric and grid are **level-major** and merely need transposing to **axis-major**:

| joint structure | today | sliced per axis | net |
|---|---:|---|---:|
| AMA per-level rubric (`#### <Level> MDM` ×4) | 3,871 | COPA 852 · DATA 1,837 · RISK 1,046 | **−136** |
| Mercy MDM Complexity Grid table | 2,382 | COPA 725 · DATA 761 · RISK 948 | +52 |
| Few-shot calibration | 5,265 | **do not slice** — see §2.1 | 0 |

Each `#### Moderate MDM` block is literally `- **COPA**: … / - **Data**: … / - **Risk**: …`, so
the transpose is a re-grouping of text that already exists, not new authoring.
`prompt_axes.mdm_column()` in the prior experiment already implements the grid-column slice.

~1,450 chars of MDM-integration text disappear (§4.6) because Python owns that arithmetic.

> [!bug] The cost model in the first draft of this note was wrong
> An earlier version budgeted **system-prompt bytes** and claimed −7% input. Measured on the
> prior experiment's six calls: **2.62× per vote, cached** ($0.191 → $0.501); input 1.86×,
> output 2.37×. And the driver is neither duplication nor prompt size:
>
> - duplicated prompt bytes bill at cache-read rates → **≈$0.007/vote**
> - the extra **output** tokens → **≈$0.228/vote — 34× more**
> - **the note is re-sent uncached to every call** — never counted in the byte budget
> - COPA's output alone is **7,112 tokens, more than V1's entire vote**
>
> **The lever is output size and call count, not prompt bytes.** Treat §3 as a
> prompt-composition reference only, never as a cost estimate.

### 2.1 Do not slice the few-shots

Measured in the prior experiment and **reverted**: per-axis few-shots (`5d` vs `5c`) cost
**em −1.7 · copa −1.6 · risk −3.3 · mdm −1.6**, inflated problem objects 242 → 416 (+72%), and
gained nothing on any axis. Separately, when the KD2 whole-encounter examples fell out by
accident, *restoring* them **broke 4 em codes and fixed 0**.

**Spec:** the whole-encounter few-shot block is carried **intact by exactly one call**. Their
design put it on Call `time`; dropping it there was also reverted (cost `903664602` its 99215).
Which call carries it in our five is **open decision D-4** (§12); default = the COPA prompt,
since the examples are COPA-boundary calibration and QHE-3555 tuned them.

---

## 3 · Per-axis prompt composition (bytes only — not a cost model)

Few-shots intact on the COPA prompt (D-4 default):

| axis | axis rules | rubric | grid | few-shot | FAQ | framing | fence | **total** |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| COPA | 15,903 | 852 | 725 | 5,265 | 837 | 1,273 | ~350 | **25,205** |
| DATA | 12,506 | 1,837 | 761 | — | 585 | 1,273 | ~350 | **17,312** |
| RISK | 5,951 | 1,046 | 948 | — | — | 1,273 | ~350 | **9,568** |
| TIME | 4,913 | — | — | — | — | 1,273 | ~350 | **6,536** |
| | | | | | | | | **58,621** |

Plus the preventive/AWV/Mod-25 cluster (~22k) → ~80.6k across 5 prompts. **This says nothing
about cost** — see the §2 callout.

TIME needs no rubric, grid or few-shot: post-QHE-2854 it emits facts only
(`documented` / `total_minutes` / `attributable_to_em` / `source_quote`). Lowest-risk cut.

---

## 4 · The axis-major transpose, specified per block

All anchors verified unique at `cb8ea1a591`. `sp` = `prompts/system_prompt.py`,
`kb` = `prompts/knowledge_base.py`.

> [!important] Both structural assertions are hard gates on every arm
> Port these from `prompt_axes.py` before composing anything — each caught a real shipped bug:
> - **`unrouted_sections(arm)`** — asserts `SECTION_ANCHORS == routed ∪ DELETED_SECTIONS`.
>   Every section is routed to a call or explicitly declared deleted; **there is no third state.**
>   When a catch-all call was dissolved, 1,621 chars of Mercy exemplars fell out **with no error
>   anywhere.** The tables below have exactly this hole without the assertion.
> - **`dangling_field_references(arm)`** — every backticked `x.y` field reference in a shard must
>   resolve against that shard's schema. Caught `time.used` being *ordered* while absent from
>   `TIME_SCHEMA` — shipping in the very arm that had logged the same bug as "fixed".

### 4.1 COPA prompt — 25,205 chars

| file | grep anchor | line | chars | action |
|---|---|---:|---:|---|
| sp | `^\*\*1\. COPA` | 49 | 198 | copy verbatim |
| sp | `^CRITICAL COPA RULES` | 53 | 7,778 | copy verbatim (incl. the V1.3 hunks) |
| kb | `^### Number and Complexity of Problems Addressed` | 77 | 1,519 | copy verbatim |
| kb | `^#### Problem Definitions` | 85 | 6,606 | copy verbatim |
| kb | `^#### Straightforward MDM` … `^#### High MDM` | 34–65 | 852 | **transpose** — only the `- **COPA**:` bullet + sub-bullets from each of the 4 level blocks → one four-rung COPA ladder |
| kb | `^### MDM Complexity Grid` | 196 | 725 | **slice** — column 2 (COPA), level label re-attached. See `prompt_axes.mdm_column()` |
| sp | `^## FEW-SHOT EXAMPLES` … `^### How to use these examples` | 341–401 | 5,265 | **copy INTACT** (D-4 carrier) — do not slice per axis |
| kb | `^### Mercy FAQ` | 228 | 837 | **slice** — 2 Qs: "referring a patient … count as a problem addressed" + "complicated vs uncomplicated condition" |

### 4.2 DATA prompt — 17,312 chars

| file | grep anchor | line | chars | action |
|---|---|---:|---:|---|
| sp | `^\*\*2\. DATA` | 93 | 258 | copy verbatim |
| sp | `^### STEP A —` | 96 | 2,355 | copy verbatim |
| sp | `^### STEP B —` | 123 | 3,947 | copy verbatim |
| sp | `^### STEP C —` | 151 | 1,362 | copy verbatim |
| sp | `^### STEP D —` | 165 | 1,432 | copy verbatim |
| sp | `^### Required output for Data line` | 189 | 569 | copy, re-point at the DATA fence |
| kb | `^### Amount and/or Complexity of Data` | 137 | 2,583 | copy verbatim |
| kb | `#### … MDM` ×4 | 34–65 | 1,837 | **transpose** — `- **Data**:` bullet + Cat 1/2/3 sub-bullets per level → one four-rung DATA ladder |
| kb | `^### MDM Complexity Grid` | 196 | 761 | **slice** — column 3 (Data) |
| kb | `^### Mercy FAQ` | 228 | 585 | **slice** — 2 Qs: "clinical laboratory panel … multiple tests" + "x-ray I ordered and interpreted myself … independent interpretation" |

### 4.3 RISK prompt — 9,568 chars

| file | grep anchor | line | chars | action |
|---|---|---:|---:|---|
| sp | `^\*\*3\. RISK` | 200 | 2,418 | copy verbatim |
| sp | `^CRITICAL RISK RULES` | 212 | 2,165 | copy verbatim |
| kb | `^### Risk of Complications and/or Morbidity` | 159 | 1,368 | copy verbatim |
| kb | `#### … MDM` ×4 | 34–65 | 1,046 | **transpose** — the `- **Risk**:` line per level → one four-rung RISK ladder |
| kb | `^### MDM Complexity Grid` | 196 | 948 | **slice** — column 4 (Risk) |
| — | **new sentence** | — | ~120 | **ADD `7b-testtier`'s tier sentence** — see below |

> [!tip] Port the one intervention that actually beat V1 on `risk`
> Add, in AMA's voice: *"per AMA an ordered test is scored under Data, not Risk … for Risk it is
> Minimal on its own."* Measured: `test_ordered` graded Low went **163 → 0** (fb63) and
> **407 → 0** (bench); fb63 **risk +3.3 / mdm +1.6**, 2 fixes 0 breaks, 0 billed moves;
> **the first arm in the whole experiment to beat V1 on `risk`** (88.5 vs 86.9).
>
> Two caveats on the record: it is **not surgical** — it also moved a routine referral
> Low→Minimal — and it states a clinical position to the model in AMA's voice, which their
> **SME-2** exists to ratify. Flag it for the SME rather than shipping it silently.

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
> `New Patients: 99202=15min, 99203=30min, 99204=45min, 99205=60min`, the established equivalent,
> **and** the prolonged thresholds (`G2212` at 89/69 min, `99417` at 75/55 min). QHE-2854's
> changelog says it "cut the two AMA minute-to-code tables" and `business_logic.py` states "the
> prompt no longer states the table" — both are wrong about this block.
>
> The TIME prompt must be **facts only**: keep the "Time includes / does NOT include" lists,
> **delete every minute→code mapping and every prolonged threshold.** Python owns both
> (`time_based_code_from_minutes_and_new_patient`, `_PROLONGED_FIRST_UNIT_THRESHOLD`).
>
> ⚠️ **But do not over-generalise this.** See §7 — deleting text Python "owns" has broken a fact
> the deterministic tail consumes, three times.

### 4.5 Shared into every axis prompt — 1,273 + 163 chars

| file | grep anchor | line | chars | note |
|---|---|---:|---:|---|
| sp | `^## INSTRUCTIONS` | 32 | 361 | copy into all |
| sp | `^## CODING PRIORITY HIERARCHY` | 39 | 912 | copy into all, **trimmed** of code-selection language |
| sp | `^- A prescription elevates RISK, not COPA` | 56 | 93 | **duplicate into COPA and RISK** |
| sp | `order elevates RISK, not COPA` | 82 | 70 | **duplicate into COPA and RISK** |

Those last two are the *only* explicit cross-axis boundary rules in the entire prompt. They are
what stops COPA absorbing a Risk signal once it can no longer see the Risk verdict, and they cost
163 chars to duplicate. **Do not assign them to one axis.**

**Per-call scope preamble.** Reuse the prior experiment's `SCOPES` wording — *"You are NOT
choosing a code … deterministic post-processing picks every code"* — **minus** its
items-not-levels clause, which belongs to S3. Their `visit` scope's `em_billable` framing
("a documentation question, not a complexity question") is directly reusable for the preventive
cluster.

### 4.6 Dropped entirely — ~1,450 chars

| file | grep anchor | line | chars | why |
|---|---|---:|---:|---|
| sp | `^\*\*4\. MDM Level` | 230 | 333 | Python: `_mdm_grid_middle` |
| sp | `^MDM: \[Straightforward` | 540 | 138 | no joint output block any more |
| sp | `Middle=\[level\]` | 541 | 95 | ditto |
| sp | `"mdm": \{"level"` | 571 | 105 | fence key, zero readers |
| sp | `^- "mdm": the four levels` | 585 | 95 | fence spec bullet |
| sp | few-shot `^\*\*MDM = ` lines | 6 hits | 782 | the joint verdict line in each example |

`mdm.copa_level` / `data_level` / `risk_level` have **zero readers** — the aggregate takes levels
from `detail["copa"]["level"]` etc. Dropping the whole object costs nothing.

---

## 5 · The sufficiency contract

- [ ] **S5.1 · Complete axis-major ladder.** All four rungs — AMA rubric bullet + Mercy grid
      column — so the axis has a self-contained scale, not one rung of a joint table.
- [ ] **S5.2 · Boundary rules duplicated.** The 163 chars from §4.5 present in every axis they
      constrain.
- [ ] **S5.3 · Few-shots intact on one carrier call** (§2.1). **Do not** build per-axis few-shot
      sets — measured loss on every axis.
- [ ] **S5.4 · A within-axis discriminative check** — require the prompt to name which rung of
      its own ladder fired and why the rungs above and below do not. The proposed replacement for
      the two-of-three scaffolding.
      ⚠️ **Already partly refuted.** For **RISK** the closest measured analogue
      (`7a-riskselect`, a model-emitted selection flag) is a **no-op by construction**:
      `max(flagged) == max(all)` on **0 of 602 fences**, because a maximum is invariant to
      everything below it. It may still hold for **COPA** (a count with floors) and **DATA**
      (a point total), where which items count changes the answer. Do not spend an arm on the
      RISK variant.
- [ ] **S5.5 · An explicit "insufficient documentation" value.** See §7.

---

## 6 · What is already built — reuse, do not rebuild

| piece | where | status |
|---|---|---|
| grid middle → code → series flip → time supersede → prolonged | `business_logic.apply_v1_post_processing` | **done** — feed it three independently-produced levels and it works unchanged |
| per-element majority voting | #5896 `_majority_level` | **done** — votes COPA/DATA/RISK independently, median-by-severity tie rule; axis-major by construction |
| time-card voting | #5896 `_majority_time_card` | **done** — votes the fact triple as a unit |
| grid column slice | `prompt_axes.mdm_column()` | **done** in the prior experiment |
| the two structural assertions | `prompt_axes.unrouted_sections` / `dangling_field_references` | **done** — port as tests (§4) |
| level derivation from items | `derive.py` — `risk_level_from_actions`, `mdm_level_from_elements`, `em_code_from_mdm`, `time_based_code` | **done, but it is S3's engine** — not used in S2 |
| plumbing: per-axis vote lists | — | **to do** — the aggregate takes one joint vote list |

The deterministic side needs **no new logic** for S2.

> [!warning] Voting's accuracy rationale is dead — keep it for other reasons
> Element-wise voting is structurally the right aggregation, but it does **not** buy accuracy:
> cross-arm element churn is 22 encounters, 22 voted; on 2-1 contested axes the majority matches
> GT **29/60 vs the minority's 27/60**, and on reviewer-written GT the majority is **15/38 vs
> 19/38**. Ensembling overall buys **≈0.19pp**. It survives on **determinism, auditability and
> payload consistency**. Do not justify an arm with it.

---

## 7 · Failure modes to design against

> [!danger] 1 · A failed axis call silently down-codes the encounter
> `_majority_level` falls back to **`"Straightforward"` — the lowest rung** — when no vote reports
> a level; #5896 added a log warning, nothing more. Today one joint call failing loses the whole
> encounter *visibly*. With five independent calls, one failed axis produces a plausible,
> complete, **under-coded** result while the others look healthy. S5.5 is the fix: an explicit
> value, wired to the abstention gate, never to the lowest rung.

> [!danger] 2 · "Code owns the arithmetic" ≠ "the prompt text is inert" — this has bitten 3 times
> The prior experiment's #1 durable lesson. Deleting text Python supposedly owned broke
> `time.attributable_to_em` — a **fact the deterministic tail consumes**, not an arithmetic
> restatement. Every deletion in §4.4 and §4.6 must be checked against *what the tail reads*,
> not against *who owns the formula*. Treat this as a standing hazard, not a one-off.

> [!danger] 3 · A rule validated on one distribution breaks on another
> `max(actions)` reproduced V1 on 185/185 fences — then the dedicated RISK call emitted **2.9×
> more actions** and it became an over-coder, with 23 of 60 risk levels resting on a single
> action. **Re-validate every rollup against the distribution the decomposed calls actually
> produce**, not against V1's. And do not "fix" it in the rollup: replacing `max()` with
> second-highest costs em **−20.3pp** on fb63.

---

## 8 · Proposed DAG — this is E-6, the actual gap

Their status lists productionisation as *"not started"*: DAG, node UUIDs, verifier split,
`parity_replay`.

```
input → rcm-format/split/upload-notes
  ├─→ clinic-copa-extract  ×3  (~25k)  → copa level + problems + citations
  ├─→ clinic-data-extract  ×3  (~17k)  → data level + cat1/2/3 point tree
  ├─→ clinic-risk-extract  ×3  (~10k)  → risk level + actions
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
| **measured cost / vote** | $0.191 | **≈$0.501 (2.62×)** — output-driven, see §2 |
| prompt cache entries | 1 | 5 |
| note payload | sent once | **re-sent uncached per call** — the real input cost |
| vote keys | 1 (`em_code`) | 4 axis levels + preventive type |

Per-axis vote counts are a **cost** knob, not an accuracy one (§6). Reducing TIME to 1 vote is
justified by it being fact extraction, not by any measured accuracy story.

---

## 9 · Acceptance criteria

> [!danger] Blocker — settle the off-scale scoring encoding before any of these gates mean anything
> `core/scoring.py`'s two paths invent different placements for an off-scale/blank prediction and
> **disagree**: `score()` puts it at ordinal 0 (maximally under-coded), `score_ci()` at
> `len(ordinal)` (above the top). **3,408 of 16,152 ED element values are off-scale — 21.1%,
> across 70 of 87 ED run dirs.** On one arm copa bias reads −1.043 one way and +0.814 the other.
> A corrected 25–40% of four "significant" clinic findings evaporated.
>
> *"This will make any future abstention improvement read as over-coding."* It is also a
> **candidate explanation for S1's frozen `prev 18.6%`** across all 26 draws. Fix is proposed,
> not applied (`Axis.off_scale`, default `"rank"`).

**Element gates must be split by GT provenance.** The prior experiment found feedback-63's answer
key is **61% self-graded** (`backfill-from-tool`): on the 69 reviewer-written cells V2 beat V1 by
**7pp**, on the 112 backfilled cells it **lost 3pp**, and V1's own replay disagrees with the
backfilled key on **8/112**. A single blended number hides the sign.

- [ ] **Prerequisite:** establish the 177 set's `gt_level_source` split before setting gates.
- [ ] Report every element axis **twice** — reviewer-written and backfilled — never blended.

| axis | S1 `base` (10 draws, blended) | gate |
|---|---:|---|
| COPA | 89.2 | ≥ baseline on reviewer-written cells; report backfilled |
| DATA | **70.7** | same |
| RISK | 80.8 | same |
| mdm (derived) | 85.3 | same |
| em exact · 177 | 83.8 | ≥ 83.8 |
| em exact · v1_benchmark | 89.5 | ≥ 89.5 |

Structural and integrity gates, all hard:

- [ ] `unrouted_sections(arm) == ()` and `dangling_field_references(arm) == {}` — **on the arm's
      own base, in absolute terms**
- [ ] `n` identical to `base` per axis/draw; zero `"ok": false` stubs
- [ ] blank-level count equal to base's — the silent-failure canary, now five times as important
- [ ] **every arm compared against the absolute base, never only against the rung below.** This
      failed twice in the prior experiment and named the wrong ship candidate both times:
      *"a ladder that only compares a rung to the rung below it never asks whether the base was
      clean in absolute terms."*

```bash
# from ~/workspace/coding-ai-harness — NEVER pipe `source env.sh` (subshell loses exports)
export QH_PLATFORM_ROOT=<path-to-feature-worktree>
source scripts/env.sh
PYTHONPATH=. $PY clinic/experiments/copa-under-177/score177.py <arm-slugs>   # per-element
PYTHONPATH=. $PY clinic/experiments/s1-detlogic/score_v1b.py  <arm-slugs>    # holdout em
```

---

## 10 · Staging — continuation, not greenfield

**Land S1 first.** Measured, prompt-only, and `rm-newpt` costs nothing on the holdout.

| stage | work |
|---|---|
| **P0** | Read `STATUS.md` + `SUPERSEDED.md`. Port the two structural assertions as tests. Settle the off-scale scoring encoding (§9 blocker). Establish the 177 `gt_level_source` split. |
| **P1** | **Reproduce `7e-clean` on the 177 set** with #5896's native element-wise voting instead of offline `vote.py`. This is the only way to know whether their fb63/bench result transfers to our GT. |
| **P2** | **E-6 productionisation** — DAG (§8), node UUIDs, verifier split, `parity_replay`. Their status: *"not started."* **S2's actual contribution.** |
| **P3** | Only if P1 shows an axis short of its gate: per-axis prompt work, in the order TIME → DATA → RISK → COPA (TIME is fact-only and forces the §4.4 table strip; DATA is the most isolated axis and the weakest at 70.7; COPA last — largest, and carries the QHE-3555 calibration). |

---

## 11 · Do NOT do in S2

| item | why |
|---|---|
| slice the few-shots per axis | measured loss on all four axes (§2.1) |
| budget or justify anything from prompt bytes | cost is output tokens + note re-send, 34× the byte lever (§2) |
| justify an arm with per-axis voting accuracy | rationale measured dead (§6) |
| spend an arm on a RISK selection/discrimination field | no-op on 0 of 602 fences (§5 S5.4) |
| replace `max()` in the RISK rollup | costs em −20.3pp fb63; the fix is upstream (tier sentence, §4.3) |
| move level derivation into Python | that is **S3** — [[clinic-coding v2 S3 prompt deterministic logic decomposition]] |
| name a ship candidate from rung-vs-rung comparison | did this twice, wrong twice (§9) |
| touch the preventive/AWV/Mod-25 cluster's metric | `prev` is not being measured at all (D-2) |
| delete MERCY RULE D | not dead — fires on ~13% of real encounters; escalate to RCM |
| rewrite few-shot **content** | QHE-3555 tuned it to 95%; the examples *are* the calibration |

---

## 12 · Open decisions

> [!question] D-1 · Is S5.4 the right replacement for the two-of-three pressure?
> Already refuted for RISK. Test on COPA and DATA only, and try strengthening it before
> concluding decomposition does not work.

> [!question] D-2 · Does the preventive axis metric work at all?
> `prev` reads **18.6% on every S1 arm and every one of 26 draws, to the decimal.** Possibly the
> §9 off-scale encoding defect. Diagnose before the preventive cluster becomes its own call.

> [!question] D-3 · Per-axis confidence → abstention mapping
> The gate reads one `confidence` and gates only E/M. With four axis confidences, decide: minimum,
> assembled E/M, or per-axis. Abstention is **live in prod** (#6089).

> [!question] D-4 · Which call carries the intact few-shot block?
> Default the COPA prompt. Their design used the `time` call and dropping it there was reverted.
> One arm decides it.

### Inherited from the prior experiment — these outrank anything in S2

| id | item |
|---|---|
| **P-1** | `gcloud auth login --no-launch-browser` then `scripts/sync_data.sh push` — **~13.5k cache entries exist on one machine**, pending since 08-01. **The only item with real data-loss risk.** |
| **P-2** | Ship / no-ship on `7e-clean`: +3.4 em on flagged charts, −1.0 on ordinary ones. A product call, not a metrics one. |
| **E-3** | `is_new_patient` silver flag vs the CPT 3-year rule — **>half of fb63's em errors, unreachable from prompts.** Corroborates S1's `rm-newpt` Δ+0.0: the largest em error source is a data defect no prompt work can touch. |
| **E-7** | Write the qh-platform SHA + dirty flag into `pipeline.py`'s `summary.json`. Without it, establishing which deterministic tail a run dir used needs a replay-and-diff sweep — which is how a whole pre-AWV bench ladder went unnoticed. |
| **SME-1** | R3, the 2+ stable-chronic documentation floor — largest attributable source of billed regression (4 of 5 bench em regressions). No AMA basis; the wording is ours. |
| **SME-2** | `test_ordered` as a Risk element at all — AMA puts a test order under Data. Now stated to the model in AMA's voice (§4.3), so this is more urgent, not less. |

---

## 13 · Related

- [[clinic-coding v2 prompt decomposition plan]] — investigation: prompt anatomy, per-code budgets, coupling
- [[clinic-coding v2 S1 prompt simplification - deterministic logic removal]] — prior stage + measured results
- [[clinic-coding v2 S3 prompt deterministic logic decomposition]] — next stage: items-not-levels, rubric → Python
- [[clinical-coding-v1]] · [[clinical-coding-v2]]

**Prior experiment file map** — `coding-ai-harness/clinic/experiments/clinic-prompt-decomposition`:

| file | what |
|---|---|
| `README.md` | architecture, how to run, module index |
| `STATUS.md` | current snapshot — **read first** |
| `SUPERSEDED.md` | S1–S19, claims later work overturned — **read second** |
| `plan.md` | full chronological log, 20 inline supersession callouts — **read last** |
| `reports/v1-vs-v2-metrics.md` | canonical metrics, corrected scoring |
| `results/INDEX.md` | 40+ run dirs with a naming decoder |
| `prompt_axes.py` | the six-call composition + both structural assertions + `mdm_column()` |
| `derive.py` | level derivation from items (S3's engine) |
| `analysis/` | `rca-v2` error taxonomy C-101…C-114 · `conflict-attribution` · `prompt-coverage` · `prompt-structure` · `stage7-shipbranch` |

**ED coding** is the in-repo precedent for axis-major prompt *modules*:
`packages/rcm/ed_coding/ed_coding/prompts/` has `copa_prompt.py` (88,849), `risk_prompt.py`
(72,756), `data_prompt.py` (13,557), plus `DATA_QUESTIONNAIRE_SYSTEM_PROMPT` (6,965) and
`RISK_QUESTIONNAIRE_SYSTEM_PROMPT` (6,327) as **separate LLM calls** injected into the scoring
call via `build_combined_pass2_content`. Note ED kept COPA/DATA/RISK together in its
190,509-char `PRO_SYSTEM_PROMPT` — it split *fact extraction* from *grading*, not the axes from
each other.

---

## 14 · Superseded — corrections to earlier drafts of this note

Adopting the prior experiment's practice: nothing above is deleted silently; every claim this note
got wrong is recorded here with its evidence.

| # | as originally written | correction | evidence |
|---|---|---|---|
| **T1** | §2/§3/§8 budgeted system-prompt bytes; "sum of the 4 axis prompts 0.72× today", "input chars −7%" | **Wrong variable.** Measured 2.62×/vote cached; input 1.86×, output 2.37×. Prompt bytes bill at cache-read (≈$0.007/vote) vs extra output ≈$0.228/vote (34×), and the note is re-sent uncached to every call | prior `SUPERSEDED.md` §B row 1 · `analysis/prompt-structure/report.md` §2 |
| **T2** | §4.1–4.3 sliced the few-shot block per axis; S5.3 made per-axis few-shot sets a sufficiency requirement | **Measured loss.** `5d` vs `5c`: em −1.7 · copa −1.6 · risk −3.3 · mdm −1.6, problem objects +72%, no gain. Restoring accidentally-dropped KD2 examples broke 4 em codes, fixed 0 | prior W7 revert · `STATUS.md` §2 rows 6–7 |
| **T3** | §6 presented element-wise voting as a decomposition win | Structurally right, **accuracy rationale dead**: majority 29/60 vs minority 27/60 on contested axes; 15/38 vs 19/38 on reviewer GT; ensemble ≈0.19pp | prior `SUPERSEDED.md` S2 |
| **T4** | S5.4's within-axis discriminative check presented as untested for all axes | **Refuted for RISK**: `max(flagged) == max(all)` on 0 of 602 fences — a selection field on a max-rollup is a no-op by construction. Still open for COPA/DATA | prior `7a-riskselect` REVERT · `SUPERSEDED.md` S18 |
| **T5** | §10 staged D1→D2→D3 as greenfield axis work | S2 is the **productionisation** of an experiment that already ran to a ship candidate. Restaged as P0–P3 | prior `STATUS.md` §4 E-6 |
| **T6** | §4.2 gave DATA the Mercy FAQ referral question (839 ch) and COPA only the complicated/uncomplicated question (583 ch) | Swapped — "does referring count as a **problem addressed**" is COPA vocabulary. COPA 837 / DATA 585; totals unchanged | the FAQ text itself |
