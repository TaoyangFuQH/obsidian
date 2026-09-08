---
updated: 2026-09-08
tags: [project, coding-pod, clinic-coding, prompt, experiment, handoff, S1]
---
# Clinic coding v2 · S1 — prompt simplification: deterministic-logic removal

> **PHI-free.** No encounter ids, MRNs, note text or patient prose. CPT/HCPCS literals and
> dataset row counts only. Keep it that way.

> [!info] This is the runnable spec
> Stop asking the LLM for the three outputs the pipeline re-derives deterministically:
> **`mdm` level · `em_code` · Patient Status (new/established)**.
> Evidence, measurements and the full prompt anatomy live in
> [[clinic-coding v2 prompt decomposition plan]] — read §Findings there if you want the *why*.

---

## 0 · Baseline & prerequisites

| item | value |
|---|---|
| repo | `qh-platform` @ `bb25774943` (develop) |
| prompt version | `PROMPT_VERSION = "1.3"` |
| prompt size | 86,490 chars |
| package tests | 494 pass, ~0.3 s |
| prompt file | `packages/rcm/clinical_coding/clinical_coding/prompts/system_prompt.py` |

Two commits landed 2026-09-08 that this spec assumes:

| PR | what changed | why it matters |
|---|---|---|
| #5896 / QHE-3555 | prompt → V1.3; COPA/Data/Risk now voted **element-wise** across votes; **abstention ON by default**, policy `consensus_or_corroborated` | masking is live in prod and reads `confidence`, which S1 perturbs |
| #5907 | per-encounter `llm_raw` in `result_json` | no interaction; orientation only |

**Before editing:**

```bash
cd /Users/taoyangfu/workspace/qh-platform
git rev-parse --short HEAD                       # expect bb25774943, else re-verify anchors
git switch -c <branch> develop
cd packages/rcm/clinical_coding && .venv/bin/python -m pytest tests -q
```

> [!warning] Line numbers drift — use the grep anchors
> The tree fast-forwarded mid-investigation and every line number shifted. Every edit below leads
> with a **grep anchor** verified to match exactly one line; the line number is a hint only.

---

## 1 · Goal, scope, and why it is one change

**Hypothesis.** Being asked for a code first anchors the model's COPA/Data/Risk reads (backward
rationalisation). Remove the code request and the levels stand on their own — the auditor E&M
match should hold or improve. Same rationale as QHE-2854 for time coding.

**Scope.** Remove `mdm` level, `em_code`, and Patient Status — **together, as one change.**

> [!important] Do not split this experiment
> Patient status only reaches a *parsed* output through the code series (99202-05 vs 99212-15).
> COPA/Data/Risk are series-independent; `time` reports minutes only. So once `em_code` is gone,
> patient status is genuinely inert — and `mdm` was already inert.
>
> Remove patient status **alone**, while `em_code` is still the vote key, and the model must guess
> the series → votes fragment → `confidence` drops → abstention is **live by default** keyed on
> `confidence == HIGH` → the prod mask rate moves for the wrong reason.

> [!danger] `em_code` is load-bearing — accepted, but not free
> It is (a) the ensemble **vote key** and (b) the **"no separately-billable E/M" gate**.
> Removing it *requires* replacements **C1**, **C3** and **C4** in §4. Skip C1 and **every
> encounter parses to empty fields, silently.**

---

## 2 · Budget removed

| item | chars | % of prompt |
|---|---:|---:|
| `mdm` emission — fence key + `MDM:` line + 2-of-3 block | 671 | 0.78 % |
| Patient Status — block 6 + AMA New/Established + output line | 2,764 | 3.20 % |
| `em_code` emission | 141 | 0.16 % |
| **total** | **~3,576** | **~4.1 %** |

Expected post-edit size: **~82,914 chars**.

> [!note] Not a cost win
> The system prompt is `cache_control: ephemeral`, so all 3 votes read it at cache-read price, and
> output saving is ~35 tokens/vote against a 12 k answer cap + 32 k thinking budget. The eval run
> to validate costs orders of magnitude more than this saves. Judge S1 on **accuracy**, not tokens.

---

## 3 · Order of work

1. Branch off `develop`; confirm baseline (§0).
2. Apply the **code** changes (§4) **first** — they are what make the prompt edits safe.
3. Apply the **prompt** edits (§5).
4. Bump `PROMPT_VERSION` → `1.4` with a changelog line (§6).
5. Run §7; compare against §8.

---

## 4 · Code changes — mandatory checklist

- [ ] **C1 · Re-anchor the fence detector.**
      `temporal-workers/app/activities/clinical_coding/clinical_coding_v1_activities.py`
      `:142` (`re.findall(r"\{[^{}]*?em_code[^{}]*?\}"…)`) and `:150`
      (`"em_code" in obj or "ambulatory_em_code" in obj`) **locate** the JSON object by `em_code`.
      Re-anchor on `visit_classification` (always present).
      ⚠ **Miss this and every encounter parses to empty fields with no error.**
- [ ] **C2 · Delete the dead text-block fallbacks.** Same file, `:186`
      (`AMBULATORY E/M CODE:`) and `:188` (`Final Code:`); `_norm_code` becomes unreferenced.
- [ ] **C3 · New ensemble vote key.** Replace `Counter` over `amb_code` with each vote's **own
      derived MDM code** — grid middle of that vote's COPA/Data/Risk → established-series code.
      Votes on the thing that actually gets billed. Post-#5896 the *levels* are already voted
      element-wise, so this changes only the key.
- [ ] **C4 · New billable gate.** `business_logic.py:854` `if amb_code:` →
      `if "separately_billable_em" in coding.model_fields_set and coding.separately_billable_em:`
      Must **suppress on absence, not default true**: today a total fence-parse failure yields no
      E&M card (visible, safe); a `True` default would emit a Straightforward 99212 as a confident
      answer. Reuse the `model_fields_set` idiom in `_attributability_stated`.
      The aggregate must therefore **omit** the key when no vote asserted it.
- [ ] **C5 · Majority-vote `separately_billable_em`** across votes in the aggregate.
- [ ] **C6 · Fix the E&M card label.** `transform_v1.py:591`
      `label = _MDM_LABEL.get(_title(coding.mdm_level), "")` → read a new `dpc.mdm_level` (expose
      the grid middle already computed at `business_logic.py:864`). Without this the label falls
      back to `"Straightforward"` beside a level-5 code — reproduced today:
      `{'code': '99215', 'label': 'Straightforward', 'is_used': True}`.
- [ ] **C7 · Promote helpers.** `_mdm_grid_middle` / `_mdm_code_from_level` → public; the aggregate
      becomes a second legitimate consumer.
- [ ] **C8 · Repoint gold `AI_Ambulatory_Code`** to the derived pre-flip MDM code. **Third**
      semantic shift for that column (v0 = final billed → v1 = raw model vote → derived) —
      document it in `databricks_writeback.py`; dashboards spanning the boundary will drift.
- [ ] **C9 · Tests.** ~170 references across 12 files (45 `test_transform_v1.py`,
      41 `test_business_logic.py`, 29 `test_clinical_coding_v1_activities.py`), mostly
      `AmbulatoryCoding(ambulatory_em_code=…)` constructor args. New cases required:
      absent-flag suppression · explicit-`false` suppression · derived vote key · vote-key tie ·
      label-follows-DPC.

---

## 5 · Prompt edits

All anchors verified to match **exactly one line** at `bb25774943`.
File is `system_prompt.py` unless stated.

### 5.1 `mdm` level

| # | grep anchor | line | action |
|:--:|---|---:|---|
| M1 | `"mdm": \{"level"` | 571 | delete line — fence example |
| M2 | `^- "mdm": the four levels` | 585 | delete line — spec bullet |
| M3 | `^MDM: \[Straightforward` | 540 | delete line — output block |
| M4 | `Middle=\[level\]` | 541 | delete line — sorted-middle line |
| M5 | `^\*\*4\. MDM Level` | 230 | delete block through the blank line before `**5. Time-Based` |

`mdm.copa_level` / `data_level` / `risk_level` have **zero readers** — the aggregate takes levels
from `detail["copa"]["level"]` etc. Deleting the whole object costs nothing.

### 5.2 Patient Status (new/established)

| # | file | grep anchor | line | action |
|:--:|---|---|---:|---|
| P1 | `system_prompt.py` | `^\*\*6\. Patient Status` | 270 | delete block through the blank line before `**7. Visit Classification` |
| P2 | `system_prompt.py` | `^Patient Status: \[New` | 520 | delete line |
| P3 | `system_prompt.py` | `^Encounter Type: \[In-person` | 521 | delete line — unparsed, same family |
| P4 | `knowledge_base.py` | `^### New and Established Patients` | 187 | delete section |

**Why it is safe:**

| check | result |
|---|---|
| readers of `AmbulatoryCoding.patient_status` | **none** — grep returns the declaration only |
| what the DPC actually uses | silver `is_new_patient`, unconditionally, via `_flip_series` |
| does the model still get the data? | yes — the real context blob header carries `Patient Status: Established` |

> [!warning] Rescue three rules before deleting P1 — blocking
> These exist **only** in that block and are implemented nowhere:
> - **Telehealth exception** — "Virtual Care / PC 365 / Telehealth patients are coded as
>   ESTABLISHED regardless of the field". No `telehealth` / `virtual` handling in `business_logic`;
>   `_flip_series` trusts silver unconditionally, so it is **already inert in the billed code.**
> - the **newborn** rule, and the **hospital-follow-up** (different-specialty) rule
> - "if you suspect the Patient Status field is wrong, flag it" — nothing consumes the flag
>
> **Action:** confirm with RCM whether the telehealth exception should be **implemented** in
> `_flip_series` before the text is deleted. Raise "the billed code ignores it today" as its own
> finding — do not bury it in this PR.

### 5.3 `em_code`

| # | grep anchor | line | action |
|:--:|---|---:|---|
| E1 | `"em_code": "99214"` | 565 | replace with `  "separately_billable_em": true,` |
| E2 | `^- "em_code": the E/M code` | 579 | replace with the bullet below |
| E3 | `^AMBULATORY E/M CODE: \[code\]` | 518 | delete line |
| E4 | `^Final Code: \[code\]` | 545 | delete line |

Replacement spec bullet for **E2**:

```text
- "separately_billable_em": true when the problem-oriented work at this encounter is a
  significant, separately identifiable E/M service that should be billed on its own; false
  when there is problem-oriented content but it is NOT separately billable (e.g. Mercy Rule B
  pediatric WCC, or preventive-visit work that is part of the preventive code). Always state
  it explicitly — never omit it. Do NOT state a CPT code anywhere in your output; the code is
  derived from your COPA/Data/Risk levels.
```

---

## 6 · Version bump

`prompts/__init__.py` → `PROMPT_VERSION = "1.4"`, plus a changelog line in the file's existing
style (it says explicitly that a bare bump tells a reader nothing):

```text
#   V1.4 - S1 (prompt simplification): removed every LLM-emitted code/level the pipeline
#          re-derives — em_code (+ AMBULATORY E/M CODE / Final Code lines), the mdm fence
#          object (+ MDM: line and the two-of-three block), and the Patient Status block
#          (+ AMA New/Established). Added separately_billable_em to carry the former
#          em_code="NONE" opt-out. -3,576 chars.
```

---

## 7 · How to run

### 7.1 Unit tests

```bash
cd packages/rcm/clinical_coding && .venv/bin/python -m pytest tests -q
```

### 7.2 Eval — harness (real spend)

A prompt change invalidates the model-I/O cache signature, so `--seed 0` will **not** replay: this
goes live on Opus, 3 votes × extended thinking, per encounter. Cost gotchas in
[[coding-ai-harness-synthetic-prolonged]].

```bash
# from ~/workspace/coding-ai-harness — NEVER pipe `source env.sh` (subshell loses exports)
export QH_PLATFORM_ROOT=<path-to-feature-worktree>
source scripts/env.sh
uv pip install -e "$QH_PLATFORM_ROOT/packages/rcm/clinical_coding"
$PY -m core.harness --profile clinic --dataset v1_benchmark --out-dir <out> --seed 0 --concurrency 4
```

Node intermediates (incl. the DPC output) → `<out>/nodes/enc_*.json`; `result_json` → `<out>/enc_*.json`.

`v1_benchmark` lives in the harness's **gitignored** `clinic/dataset/` PHI store (singular — the plural
`clinic/datasets/` does not resolve by bare name and gets wiped by branch checkouts). Do not move or
rename a dataset: the model-I/O cache signature includes its name, so renaming forces a fresh live run.

### 7.3 Measure three things, not one

| # | metric | baseline | why it moves |
|:--:|---|---|---|
| 1 | E&M auditor match | **95 %** (QHE-3555 back-test) | the headline hypothesis |
| 2 | confidence distribution vs SLO | ≥ 90 % HIGH | vote key changed → moves by construction |
| 3 | abstention coverage / accepted accuracy | 94.4 % / 95.5 % (`consensus_or_corroborated`) · 78.6 % / 94.6 % (`unanimous`) | masking is **ON in prod** and reads `confidence` |

Metric 3 is the sleeper, and the reason the three removals must land as one measured change
together with the vote-key replacement rather than as an incremental trim.

---

## 8 · Acceptance criteria

| # | criterion |
|:--:|---|
| 1 | 494+ package tests green; C9 cases present |
| 2 | E&M auditor match on `v1_benchmark` **≥ 95 %** — no regression vs QHE-3555 |
| 3 | HIGH-confidence rate **≥ 90 %** (PRD SLO) |
| 4 | abstention coverage / accuracy no worse than 94.4 % / 95.5 % |
| 5 | no encounter parses to empty fields — C1 sanity: grep `<out>/nodes/` for blank `copa_level` |
| 6 | E&M card label matches its code on every encounter (C6) |
| 7 | prompt ≈ **82,914 chars**; `PROMPT_VERSION == "1.4"` |

**Rollback:** revert the branch. The prompt is a single constant and the DAG template is untouched
— no seed or migration to undo.

---

## 9 · Do NOT touch in S1

| item | size | why |
|---|---:|---|
| AMA per-level rubric (`#### SF/Low/Moderate/High MDM`) | 4.48 % | *is* the COPA/Data/Risk definitions |
| Mercy MDM Complexity Grid + examples | 4.63 % | same rubric, table form |
| Few-shot MDM calibration (Ex 1, 1b, 2, 3, 4) | 4.27 % | this is what QHE-3555 tuned to 95 % |
| COPA / DATA / RISK / TIME rule sections | ~50 % | the model's judgment inputs |
| **MERCY RULE D** | 3.08 % | **not dead** — disabled feature, fires on ~13 % of real encounters. See the investigation note |

---

## 10 · Open decisions — do not resolve silently

> [!question] D1 — cut the 2-of-3 arithmetic block (M5)?
> Python owns it, but stating it forces the model to notice when its own levels don't support its
> grade. **Recommend cutting in S1** — it exists only to produce a code we are deleting. If level
> quality regresses, restoring M5 alone is the first thing to try.

> [!question] D2 — leave the few-shot examples code-labelled?
> Titles read "99214, NOT 99213" and bodies say "Established". **Recommend leaving them intact**:
> they teach COPA/Data/Risk boundaries and the code reads as a label. Rewriting risks the QHE-3555
> calibration. Revisit only if the model starts emitting codes despite E2.

> [!question] D3 — run the gold pre-check first?
> A single SQL query quantifies the anchoring hypothesis with **no prompt change and no eval spend**
> (see the investigation note §Open questions). Rare disagreement ⇒ removal is low-risk. Common ⇒
> the check is catching real model inconsistency and S1 is deleting a safety net. Cheap; worth it.

---

## 11 · Related

- [[clinic-coding v2 prompt decomposition plan]] — investigation, evidence, prompt anatomy
- [[clinical-coding-v1]] · [[clinical-coding-v2]]
- [[coding-ai-harness-synthetic-prolonged]] — harness run mechanics, cache and cost gotchas
  *(Claude memory file, not a vault note — key points inlined in this note)*
- [[clinic-coding-note-extract-prod-gap]] *(Claude memory)* — upstream silver gap; bounds any accuracy measurement
