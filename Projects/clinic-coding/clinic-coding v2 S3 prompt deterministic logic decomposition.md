---
updated: 2026-09-10
tags: [project, coding-pod, clinic-coding, prompt, experiment, handoff, S3]
---
# Clinic coding v2 · S3 — deterministic-logic decomposition: items, not levels

> **PHI-free.** No encounter ids, MRNs, note text or patient prose. Prompt rule text, CPT
> literals, character counts and dataset row counts only. Keep it that way.

> [!info] What S3 is
> Stop asking the model for **levels**. Each axis call reports **items** — the problems addressed,
> the citable data elements and their AMA category, the management actions and each one's risk,
> the documented time facts — and **Python derives the level** from the item list.
>
> This is the third of your three stages: *"extract the deterministic logic from the prompt into
> deterministic logic code."* It presupposes [[clinic-coding v2 S2 prompt decomposition]] (one
> prompt per code) and, once landed, **dissolves most of S2 §4** — the axis-major rubric ladder
> moves out of the prompts and into Python.

> [!danger] The engine already exists and was already measured
> `coding-ai-harness/clinic/experiments/clinic-prompt-decomposition` built exactly this, and its
> six calls **already emit items and derive levels**. `derive.py` is the working implementation.
> **Reading order: `STATUS.md` → `SUPERSEDED.md` → `plan.md`.**
>
> S3 is therefore not a design task. It is: (a) decide whether to adopt their derivation
> semantics as-is, (b) re-measure on the 177 set, (c) ratify the clinical positions their enums
> and derivations take implicitly (§6).

---

## 1 · The contract change

| | S2 (levels) | S3 (items) |
|---|---|---|
| COPA call emits | `copa.level` + `problems[]` | `problems[]` only — name, `ama_category`, status, `source_quote` |
| DATA call emits | `data.level` + `total_points` + cat trees | `cat1_items[]` / `cat2_items[]` / `cat3_items[]` + `independent_historian` |
| RISK call emits | `risk.level` + `actions[]` | `actions[]` only — description, `kind`, `risk_level`, `source_quote` |
| TIME call emits | facts | facts (unchanged — already item-shaped) |
| level comes from | the model | **Python** |
| prompt carries | the four-rung ladder per axis | **no ladder at all** |

The prior experiment's `SCOPES` text is directly reusable, and this is the clause S2 deliberately
omitted:

> *"SCOPE OF THIS CALL: report the problems addressed and what is documented about each — the
> COPA element's facts. You are NOT stating a COPA level, counting problems, scoring Data or Risk,
> or choosing a code. **The level is computed from the list you return.**"*

---

## 2 · What moves from prompt to Python

| axis | prompt loses | Python gains | `derive.py` |
|---|---|---|---|
| COPA | the four-rung ladder + grid column (1,577 ch) | max over the AMA pathways the actively-managed problems satisfy, both Mercy floors | `copa_level_from_problems(problems, clinical_assessment_performed)` |
| DATA | the ladder + grid column + STEP-D thresholds (2,598 + 1,432 ch) | Cat-1 one point per item, Cat-2/Cat-3 one *line* each, historian counted once per encounter | `data_level_from_items(cat1, cat2, cat3, independent_historian)` |
| RISK | the ladder + grid column (1,994 ch) | max over `actions[].risk_level` | `risk_level_from_actions(actions, ...)` |
| MDM | already dropped in S2 | median of the three | `mdm_level_from_elements(...)` |
| code | — | level → code → series flip → time supersede | `em_code_from_mdm`, `time_based_code`, `final_em_code` |

Roughly **7,600 chars** of ladder and threshold text leave the prompts. Per S2 §2, **do not read
that as a cost saving** — cost is output tokens and note re-send, not prompt bytes.

---

## 3 · What derivation actually buys — and what it does not

> [!warning] It buys auditability. It does **not** buy stability.
> The prior experiment's own correction (`SUPERSEDED.md` S16): *"Deriving a level from items fixes
> cross-seed noise — **it does not.** Derived `data.level` has **identical** stability to emitted
> (54/63 both). The instability lives in **item extraction**, not the arithmetic. Deriving
> relocates the noise; what it buys is auditability."*
>
> So do not justify S3 with a noise or accuracy argument. Justify it with:
> - **auditability** — every level traces to a citable item list a coder can inspect
> - **one source of truth** — the AMA thresholds stop existing in both the prompt and Python
> - **contradiction elimination** — a prompt cannot order an answer the schema forbids if the
>   prompt no longer states the arithmetic
> - **testability** — the derivation is pure Python with unit tests, not model behaviour

---

## 4 · Rollups already have known defects — inherit them knowingly

> [!danger] `max()` on RISK: validated on the wrong distribution
> `max(actions[].risk_level)` reproduced V1's emitted level on **185/185** scorable fences with a
> perfectly diagonal confusion matrix — then the dedicated RISK call emitted **2.9× more actions**
> (2.73 → 8.03/fence on fb63; 2.88 → 8.21 on bench — the same +5.3 on two unrelated datasets, so
> it is a property of the prompt, not the chart mix) and the tier mix inverted to **51% Minimal**.
>
> `max()` has **no significance filter**, so the level is set by whichever single item drew the
> highest tier: **23 of 60 risk levels rest on one action**, and 4 of 6 `risk=Low` encounters rest
> solely on a `test_ordered`. Risk's within-arm 3-way disagreement rose **6.5% → 11.3%** and
> propagated (mdm 9.5 → 14.5, em 8.1 → 12.9).
>
> **Do not "fix" it in the rollup.** Replacing `max()` with second-highest costs em
> **−20.3pp fb63 / −10.5pp bench**. `max()` is load-bearing. And a model-emitted selection flag
> is a no-op by construction — `max(flagged) == max(all)` on **0 of 602 fences**. The fix is
> upstream: a **tier sentence** in the prompt (S2 §4.3) and/or removing `test_ordered` from the
> action kinds.

Other derivation decisions already taken, each with a rationale in `derive.py`'s docstrings:

| decision | note |
|---|---|
| historian counted once, excluded from the Cat-1 count | resolves the C10 contradiction (`sp:95` "tracked SEPARATELY" vs `sp:580` "1 point each") in favour of `sp:95`. Reading both encodings took derivation from 147/186 → 153/186 |
| 1 Cat-1 point with no historian/Cat-2/Cat-3 → Straightforward | conflict **R1**; confirmed correct — forcing `→ Low` costs data **−14.7pp**, and V2's SF matches GT on 10 of 11 in-hole encounters. 0 billed codes moved |
| `copa_level_from_problems` returns `None` on empty `problems` | a visit with no problem addressed has no COPA; flooring to Straightforward would fabricate an MDM element on a visit that bills no E/M |
| Mercy Low floor (any clinical assessment ⇒ COPA ≥ Low) | conflict **R2**; contradicts AMA `kb:35`. Kept as the operative Mercy rule; measured a near no-op (2/189 fences) |

---

## 5 · Prerequisites

- [ ] **S2 landed** — one prompt per code, both structural assertions green
- [ ] **The off-scale scoring encoding settled** (S2 §9 blocker) — `score()` and `score_ci()`
      disagree about a blank; 21.1% of ED element values are off-scale. Nothing here is measurable
      until this is fixed
- [ ] **177 `gt_level_source` split established** — element gates reported separately for
      reviewer-written vs backfilled cells
- [ ] **Both structural assertions ported as tests** — `unrouted_sections`,
      `dangling_field_references`. S3 removes ladder text from prompts, which is exactly the
      re-partition those assertions guard
- [ ] **S2 §7 hazard 2 internalised** — *"code owns the arithmetic ≠ the prompt text is inert."*
      Deleting ladder text Python now owns has broken a **fact the tail consumes**, three times.
      Every deletion checked against what the deterministic tail reads

---

## 6 · Clinical positions taken implicitly — ratify before shipping

The prior experiment flagged these as *"new positions nobody signed off on"*. S3 makes them
load-bearing, so they need an SME ruling, not a code review.

| id | position | why it matters |
|---|---|---|
| **SME-2** | `test_ordered` as a Low-tier RISK action kind at all | AMA treats a test order as a **Data** element (`kb:139`); Risk is the risk of the *management selected*. A closed `kind` enum lets a Cat-1 order double-count. 55 occurrences on fb63 vs ~9 in V1; it decides the level on 4 encounters, **two of them wrongly** |
| — | enum-closed `ama_category` changing COPA classification | one encounter moves Low→Moderate purely because the dedicated COPA call assigns `Undiagnosed new problem`. Not a rule, not a floor — **a vocabulary change with a billing consequence** |
| **SME-1** | R3, the 2+ stable-chronic documentation floor | **largest attributable source of billed regression** — 4 of 5 bench em regressions. No AMA basis; the wording is ours |
| **SME-3** | R1, 1 Cat-1 point → Straightforward | already confirmed correct (+14.7pp on DATA, 0 billed movement) |
| **SME-4** | "unique test" definition for the DATA call | 10 error rows, inherited from V1 |
| — | `monitoring_or_followup` tier | **empirically moot** — the model scores it Minimal 92–93% of the time, so capping it changes nothing. Still an unsigned position |

---

## 7 · Acceptance criteria

- [ ] **Parity first:** derived levels reproduce S2's emitted levels within the cross-seed noise
      floor on both datasets, per axis. A derivation that changes levels is a *behaviour* change
      and must be measured as one, not shipped as a refactor
- [ ] Element gates from S2 §9, **split by `gt_level_source`**, no regression on reviewer-written
      cells
- [ ] `unrouted_sections(arm) == ()` and `dangling_field_references(arm) == {}` **on the arm's own
      base, in absolute terms**
- [ ] Every rollup **re-validated against the distribution the decomposed calls actually produce**
      — not against V1's. This is the `max()` lesson (§4) and it is the single most likely way S3
      goes wrong
- [ ] `n` identical to base per axis/draw; zero `"ok": false` stubs; blank-level count equal to
      base's
- [ ] Every arm compared against the **absolute base**, never only the rung below

---

## 8 · Explicitly out of scope

| item | why |
|---|---|
| justifying S3 on noise reduction or accuracy | measured: derivation relocates noise, it does not remove it (§3) |
| replacing `max()` in the RISK rollup | costs em −20.3pp fb63 (§4) |
| a model-emitted selection/`level_determining` field | no-op on 0 of 602 fences |
| per-axis few-shot sets | measured loss on all four axes (S2 §2.1) |
| prompt-byte budgeting | cost is output tokens + note re-send (S2 §2) |

---

## 9 · Related

- [[clinic-coding v2 S2 prompt decomposition]] — prerequisite: one prompt per code
- [[clinic-coding v2 S1 prompt simplification - deterministic logic removal]] — measured results for `rm-mdm` / `rm-newpt`
- [[clinic-coding v2 prompt decomposition plan]] — investigation and prompt anatomy
- [[clinical-coding-v1]] · [[clinical-coding-v2]]

**Prior experiment, the parts S3 depends on** —
`coding-ai-harness/clinic/experiments/clinic-prompt-decomposition`:

| file | what |
|---|---|
| `derive.py` | **the engine** — `copa_level_from_problems`, `data_level_from_items`, `risk_level_from_actions`, `mdm_level_from_elements`, `em_code_from_mdm`, `time_based_code`, `final_em_code`, `em_billable_with_postcondition` |
| `schema_axes.py` · `schema_output.py` | the per-call schemas and `partition()` |
| `prompt_axes.py` | six-call composition · `SCOPES` · both structural assertions · `mdm_column()` |
| `test_derive.py` (808 lines) | the derivation test suite |
| `stage0/` | the pre-build disagreement audit — three incompatible encodings of the historian fact |
| `SUPERSEDED.md` S5, S16, S18 | the `max()` scoping bug · derivation ≠ stability · the selection-field no-op |
