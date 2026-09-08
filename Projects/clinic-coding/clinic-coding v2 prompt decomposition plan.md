---
updated: 2026-09-08
tags: [project, coding-pod, clinic-coding, prompt, experiment, plan, handoff]
---
# Clinic coding v2 — prompt decomposition plan

> **PHI-free.** No encounter ids, MRNs, note text or patient prose. CPT/HCPCS literals and
> dataset row counts only. Keep it that way.

> [!info] Handoff note
> Written to be executed by a fresh session. §1 is the investigation (why); §2-§4 are the
> runnable spec (what to do). If you are here to run the experiment, start at **§2 Start here**.

---

## §1 · Investigation

### 1.1 Baseline (pin this first)

| item | value |
|---|---|
| repo | `qh-platform` @ `bb25774943` (develop) |
| prompt version | `PROMPT_VERSION = "1.3"` |
| prompt size | 86,490 chars (assembled `AMBULATORY_SYSTEM_PROMPT`) |
| package tests | 494 pass, ~0.3 s |

Two commits landed 2026-09-08 that this plan is written against:

| PR | what changed | why it matters here |
|---|---|---|
| #5896 / QHE-3555 | prompt → V1.3 (additive COPA hunks, fence unchanged); COPA/Data/Risk now voted **element-wise** across votes; **abstention ON by default**, policy `consensus_or_corroborated` | masking is live in prod and reads `confidence`, which Exp 1 perturbs |
| #5907 | per-encounter `llm_raw` captured into `result_json` | no interaction; noted for orientation |

> [!warning] Line numbers drift
> The working tree fast-forwarded mid-investigation and every line number shifted. All edits in
> §3 lead with a **grep anchor**; line numbers are hints only. Re-verify before editing.

### 1.2 What the LLM calls output

All three arms — Claude Opus 4.6 (×3 votes), GPT-5.4, Gemini 2.5 Pro — get the **same**
`AMBULATORY_SYSTEM_PROMPT` and the same `_USER_PROMPT_PREFIX + note`. Each returns a
`---BEGIN AMBULATORY CODING OUTPUT---` text block plus a ` ```json ` fence declared
authoritative. Parsing is JSON-first, text-block regex as fallback.

**Fence contract — 11 keys:**

| key | kind | consumed by | Exp 1 |
|---|---|---|:--:|
| `em_code` | **code** | vote key + billable gate | **cut** |
| `mdm` | **level** | E&M card label only | **cut** |
| `copa` | level + detail | **drives billed code** | keep |
| `data` | level + detail | **drives billed code** | keep |
| `risk` | level + detail | **drives billed code** | keep |
| `time` | facts | time code + prolonged units | keep |
| `visit_classification` | judgment | routes which code families compute | keep |
| `preventive_type` | judgment | AWV vs commercial routing | keep |
| `preventive_rationale` | prose | Preventive card | keep |
| `awv_checklist_complete` | bool | AWV card attribute | keep |
| `modifier_25_judgment` | judgment | Mod 25 Rule C gate | keep |

**`em_code` is the only CPT/HCPCS code any LLM emits.** Every billed code is Python:

| billed code | derived from |
|---|---|
| office E/M 99202-99215 | grid middle of COPA/Data/Risk → est-series code → series flip |
| time-based E/M | AMA minute table on `time.total_minutes` |
| preventive 99381-99397 | age + new/established lookup |
| AWV G0438 / G0439 | 3-tier sequencer (arpb → note keywords → HETS) |
| prolonged G2212 / 99417 | payer+series minute thresholds |
| modifier 25 | Rule C: E/M **and** preventive present **and** `APPLY_MODIFIER_25` |

**Verified live** (real DPC + transform; established, 55 y, commercial):

| signal | value |
|---|---|
| vote `em_code` | 99213 |
| **billed** `em_code` | **99214** ← grid middle, not the vote |
| gold `AI_Ambulatory_Code` | 99213 (raw vote, kept) |
| gold `AI_EM_Code_Final` | 99214 |

The model's code number never becomes the billed code.

### 1.3 Prompt budget by topic

Method: split into paragraph/header blocks, attribute each to one topic (blocks inherit their
enclosing section), fence spec attributed per key. 99.5 % attributed; residual = blank lines.

| topic | chars | % | nature |
|---|---:|---:|---|
| COPA | 17,359 | 20.1 % | judgment input |
| DATA | 13,886 | 16.1 % | judgment input |
| MDM | 13,073 | 15.1 % | **mixed — see 1.4** |
| PREVENTIVE | 11,290 | 13.1 % | judgment input |
| MOD25 | 7,176 | 8.3 % | Rule D output discarded |
| RISK | 6,260 | 7.2 % | judgment input |
| TIME | 5,610 | 6.5 % | judgment input |
| PATIENT_STATUS | 2,756 | 3.2 % | **output unused** |
| VISIT_CLASS | 2,106 | 2.4 % | judgment input |
| framing | 1,980 | 2.3 % | — |
| AWV | 1,729 | 2.0 % | judgment input |
| Mercy FAQ | 1,603 | 1.9 % | judgment input |
| fence scaffolding | 613 | 0.7 % | — |
| AMA generic | 399 | 0.5 % | — |
| **EM_CODE** | **141** | **0.2 %** | **output partly used** |
| output scaffolding | 89 | 0.1 % | — |

### 1.4 The "MDM 15.1 %" is mostly judgment input, not code emission

| part of the MDM bucket | chars | % | verdict |
|---|---:|---:|:--:|
| AMA per-level rubric (`#### SF/Low/Moderate/High MDM`) | 3,871 | 4.48 % | **KEEP** |
| Mercy MDM Complexity Grid table + Mercy examples | 4,004 | 4.63 % | **KEEP** |
| Few-shot calibration (Ex 1, 1b, 2, 3, 4 + how-to-use) | 3,697 | 4.27 % | **KEEP** |
| `4. MDM Level (Two-of-Three Rule)` block | 333 | 0.39 % | cut |
| `MDM: [level]` output line | 138 | 0.16 % | cut |

The rubric blocks *are* the COPA/Data/Risk definitions — e.g. `#### Low MDM` reads
"COPA: Low (any one of): 2+ self-limited or minor problems; 1 stable chronic illness; …", and the
Mercy grid's columns are Level / COPA / Data / Risk. The few-shot block is what QHE-3555 tuned to
reach 95 % auditor match.

**Only 471 chars (0.55 %) of this bucket duplicates deterministic logic.** The other 11,572 chars
(13.4 %) produce the levels that logic consumes.

### 1.5 Cost reality — do not justify this on tokens

| factor | value |
|---|---|
| all code-emission instructions | 0.4 – 1.0 % of prompt |
| input cost | system prompt is `cache_control: ephemeral` → 3 votes read at cache-read price |
| output cost | ~35 tokens/vote saved, against 12 k answer cap + 32 k thinking budget |
| eval cost to validate | orders of magnitude more than this ever saves |

Justify Exp 1 on **accuracy** (anchoring) and **contract hygiene**. Not cost.

---

## §2 · Start here

**Goal of Exp 1.** Stop asking the LLM for codes it does not own, and test whether removing the
code request improves or holds the auditor E&M match. Hypothesis: being asked for a code first
anchors the COPA/Data/Risk reads (backward rationalisation). Same rationale as QHE-2854 for time.

**Scope.** Remove `mdm` level, `Patient Status`, `em_code` — **as one change**.

> [!important] Do not split this experiment
> Patient status only reaches a *parsed* output through the code series (99202-05 vs 99212-15).
> COPA/Data/Risk are series-independent and `time` reports minutes only. So once `em_code` is
> gone, patient status is genuinely inert — and `mdm` was already inert.
> Remove patient status **alone**, while `em_code` is still the vote key, and the model must guess
> the series → votes fragment → `confidence` drops → and abstention is **live by default** keyed
> on `confidence == HIGH`, so the prod mask rate moves for the wrong reason.

**Budget removed:**

| item | chars | % of prompt |
|---|---:|---:|
| `mdm` emission (fence key + `MDM:` line + 2-of-3 block) | 671 | 0.78 % |
| Patient Status (block 6 + AMA New/Established + output line) | 2,764 | 3.20 % |
| `em_code` emission | 141 | 0.16 % |
| **total** | **~3,576** | **~4.1 %** |

**Order of work:**

1. Branch off `develop`, re-pin the baseline (§1.1), confirm 494 tests pass.
2. Apply the **code** changes in §3.4 first — they are what make the prompt edits safe.
3. Apply the **prompt** edits in §3.1 – §3.3.
4. Bump `PROMPT_VERSION` → `1.4` with a changelog line (§3.5).
5. Run §4. Compare against §5 acceptance criteria.

> [!danger] `em_code` is load-bearing — accepted, but not free
> It is (a) the ensemble **vote key** and (b) the **"no separately-billable E/M" gate**. Removing
> it *requires* the two replacements in §3.4. Skipping either silently breaks the pipeline:
> without the parser re-anchor, **every encounter parses to empty fields.**

---

## §3 · The changes

### 3.1 Remove the `mdm` level

File: `packages/rcm/clinical_coding/clinical_coding/prompts/system_prompt.py`

| # | grep anchor | line hint | action |
|:--:|---|---:|---|
| M1 | `"mdm": {"level"` | 571 | delete the whole line (fence example) |
| M2 | `- "mdm": the four levels` | 585 | delete the whole line (spec bullet) |
| M3 | `^MDM: \[Straightforward` | 540 | delete the whole line (output block) |
| M4 | `Middle=\[level\]` | 541 | delete the whole line (sorted-middle line) |
| M5 | `\*\*4\. MDM Level` | 230-234 | delete the block through the blank line before `**5. Time-Based` |

`mdm.copa_level` / `data_level` / `risk_level` have **zero readers** — the aggregate takes levels
from `detail["copa"]["level"]` etc. Deleting the whole object costs nothing.

> [!question] Decision D1 — keep the 2-of-3 arithmetic (M5)?
> Python owns it, but stating it forces the model to notice when its own levels don't support its
> grade. **Recommend cutting in Exp 1** (it exists only to produce a code we're deleting). If
> level quality regresses, restoring M5 alone is the first thing to try.

### 3.2 Remove Patient Status

| # | file | grep anchor | line hint | action |
|:--:|---|---|---:|---|
| P1 | `system_prompt.py` | `\*\*6\. Patient Status` | 270-279 | delete the block through the blank line before `**7. Visit Classification` |
| P2 | `system_prompt.py` | `^Patient Status: \[New` | 520 | delete the line |
| P3 | `system_prompt.py` | `^Encounter Type: \[In-person` | 521 | delete the line (unparsed, same family) |
| P4 | `prompts/knowledge_base.py` | `### New and Established Patients` | 187 | delete the section |

**Why safe:**

| check | result |
|---|---|
| readers of `AmbulatoryCoding.patient_status` | **none** — grep returns the declaration only |
| what the DPC actually uses | silver `is_new_patient`, unconditionally, via `_flip_series` |
| does the model still get the data? | yes — the real context blob header carries `Patient Status: Established` (verified in harness `clinic-feedback-200-20260730`) |

> [!warning] Rescue three rules before deleting P1
> These exist **only** in that block and are implemented nowhere:
> - **Telehealth exception** — "Virtual Care / PC 365 / Telehealth patients are coded as
>   ESTABLISHED regardless of the field". No `telehealth`/`virtual` handling in `business_logic`.
>   Since `_flip_series` trusts silver unconditionally, this is **already inert in the billed code.**
> - the **newborn** rule, and the **hospital-follow-up** (different-specialty) rule
> - "if you suspect the Patient Status field is wrong, flag it" — nothing consumes the flag
>
> Action: confirm with RCM whether the telehealth exception should be **implemented** in
> `_flip_series` before the text is deleted. That the billed code ignores it today is a finding in
> its own right — raise it separately, do not bury it in this PR.

### 3.3 Remove `em_code`

| # | grep anchor | line hint | action |
|:--:|---|---:|---|
| E1 | `"em_code": "99214"` | 565 | replace with `  "separately_billable_em": true,` |
| E2 | `- "em_code": the E/M code` | 579 | replace with the bullet below |
| E3 | `^AMBULATORY E/M CODE: \[code\]` | 518 | delete the line |
| E4 | `^Final Code: \[code\]` | 545 | delete the line |

Proposed replacement spec bullet (E2):

```text
- "separately_billable_em": true when the problem-oriented work at this encounter is a
  significant, separately identifiable E/M service that should be billed on its own; false
  when there is problem-oriented content but it is NOT separately billable (e.g. Mercy Rule B
  pediatric WCC, or preventive-visit work that is part of the preventive code). Always state
  it explicitly — never omit it. Do NOT state a CPT code anywhere in your output; the code is
  derived from your COPA/Data/Risk levels.
```

### 3.4 Companion code changes — mandatory

Tick these off; the prompt edits are unsafe without them.

- [ ] **C1 · Re-anchor the fence detector.** `clinical_coding_v1_activities.py` `:142`
      (`re.findall(r"\{[^{}]*?em_code[^{}]*?\}"…)`) and `:150` (`"em_code" in obj or …`) **locate**
      the JSON object by `em_code`. Re-anchor on `visit_classification` (always present).
      **Miss this and every encounter parses to empty fields, silently.**
- [ ] **C2 · Delete the dead text-block fallbacks.** Same file `:186` (`AMBULATORY E/M CODE:`) and
      `:188` (`Final Code:`), plus `_norm_code` (becomes unreferenced).
- [ ] **C3 · New ensemble vote key.** Replace `Counter` over `amb_code` with each vote's **own
      derived MDM code**: grid middle of that vote's COPA/Data/Risk → est-series code. Votes on
      the thing that actually gets billed. Post-#5896 the *levels* are already voted element-wise,
      so this changes only the key.
- [ ] **C4 · New billable gate.** `business_logic.py:854` `if amb_code:` →
      `if "separately_billable_em" in coding.model_fields_set and coding.separately_billable_em:`
      Must **suppress on absence, not default true** — today a total fence-parse failure yields no
      E&M card (visible, safe failure); a `True` default would emit a Straightforward 99212 as a
      confident answer. Reuse the `model_fields_set` idiom in `_attributability_stated`.
      The aggregate must therefore **omit** the key when no vote asserted it.
- [ ] **C5 · Majority-vote `separately_billable_em`** across votes in the aggregate.
- [ ] **C6 · Fix the E&M card label.** `transform_v1.py:591`
      `label = _MDM_LABEL.get(_title(coding.mdm_level), "")` → read a new `dpc.mdm_level` (expose
      the grid middle already computed at `business_logic.py:864`). Without this the label falls
      back to `"Straightforward"` beside a level-5 code — reproduced today:
      `{'code': '99215', 'label': 'Straightforward', 'is_used': True}`.
- [ ] **C7 · Promote helpers.** `_mdm_grid_middle` / `_mdm_code_from_level` → public; the aggregate
      becomes a second legitimate consumer.
- [ ] **C8 · Repoint gold `AI_Ambulatory_Code`** to the derived pre-flip MDM code. This is the
      **third** semantic shift for that column (v0 = final billed → v1 = raw model vote → derived).
      Document it in `databricks_writeback.py` — dashboards spanning the boundary will drift.
- [ ] **C9 · Tests.** ~170 references across 12 files (45 `test_transform_v1.py`,
      41 `test_business_logic.py`, 29 `test_clinical_coding_v1_activities.py`), mostly
      `AmbulatoryCoding(ambulatory_em_code=…)` constructor args. New cases needed:
      absent-flag suppression, explicit-`false` suppression, derived vote key, vote-key tie,
      label-follows-DPC.

### 3.5 Version bump

`prompts/__init__.py` → `PROMPT_VERSION = "1.4"`, and add a changelog line in the existing style
saying *what* changed (a bare bump tells a reader nothing — the file says so explicitly):

```text
#   V1.4 - Exp 1 (prompt decomposition): removed every LLM-emitted code/level the pipeline
#          re-derives — em_code (+ AMBULATORY E/M CODE / Final Code lines), the mdm fence
#          object (+ MDM: line and the two-of-three block), and the Patient Status block
#          (+ AMA New/Established). Added separately_billable_em to carry the former
#          em_code="NONE" opt-out. -3,576 chars.
```

---

## §4 · How to run

### 4.1 Unit tests

```bash
cd packages/rcm/clinical_coding && .venv/bin/python -m pytest tests -q
```

### 4.2 Eval — harness (real spend)

A prompt change invalidates the model-I/O cache signature, so `--seed 0` will **not** replay:
this goes live on Opus, 3 votes × extended thinking, per encounter. See
[[coding-ai-harness-synthetic-prolonged]] for the cost gotchas.

```bash
# from ~/workspace/coding-ai-harness — NEVER pipe `source env.sh` (subshell loses exports)
export QH_PLATFORM_ROOT=<path-to-feature-worktree>
source scripts/env.sh
uv pip install -e "$QH_PLATFORM_ROOT/packages/rcm/clinical_coding"
$PY -m core.harness --profile clinic --dataset v1_benchmark --out-dir <out> --seed 0 --concurrency 4
```

Per-encounter node intermediates (incl. the DPC output) land in `<out>/nodes/enc_*.json`;
`result_json` in `<out>/enc_*.json`.

### 4.3 Measure three things, not one

| # | metric | baseline | why it moves |
|:--:|---|---|---|
| 1 | E&M auditor match | **95 %** (QHE-3555 back-test) | the headline hypothesis |
| 2 | confidence distribution vs SLO | ≥ 90 % HIGH | vote key changed → moves by construction |
| 3 | abstention coverage / accepted accuracy | 94.4 % / 95.5 % (`consensus_or_corroborated`); 78.6 % / 94.6 % (`unanimous`) | masking is **ON in prod** and reads `confidence` |

Metric 3 is the sleeper. It is the reason the three removals must land as one measured change
together with the vote-key replacement, not as an incremental prompt trim.

---

## §5 · Acceptance criteria

| # | criterion |
|:--:|---|
| 1 | 494+ package tests green; new cases in C9 present |
| 2 | E&M auditor match on `v1_benchmark` **≥ 95 %** (no regression vs QHE-3555) |
| 3 | HIGH-confidence rate **≥ 90 %** (PRD SLO) |
| 4 | abstention coverage/accuracy no worse than 94.4 % / 95.5 % |
| 5 | no encounter parses to empty fields (C1 sanity: grep `<out>/nodes/` for blank `copa_level`) |
| 6 | E&M card label matches its code on every encounter (C6) |
| 7 | prompt is 86,490 − ~3,576 ≈ **82,914 chars**; `PROMPT_VERSION == "1.4"` |

**Rollback:** revert the branch. The prompt is a single constant and the DAG/template is untouched,
so there is no seed or migration to undo.

---

## §6 · Do NOT touch in Exp 1

| item | size | why |
|---|---:|---|
| AMA per-level rubric | 4.48 % | *is* the COPA/Data/Risk definitions |
| Mercy MDM Complexity Grid + examples | 4.63 % | same rubric, table form |
| Few-shot MDM calibration | 4.27 % | this is what QHE-3555 tuned to 95 % |
| COPA / DATA / RISK / TIME rule sections | ~50 % | the model's judgment inputs |
| **MERCY RULE D** | 3.08 % | not dead — see §7.2 |

> [!question] Decision D2 — the few-shot examples
> Titles are code-labelled ("99214, NOT 99213") and bodies say "Established". **Recommend leaving
> them intact**: they teach COPA/Data/Risk boundaries and the code reads as a label. Rewriting them
> risks the QHE-3555 calibration. Revisit only if the model starts emitting codes despite E2.

---

## §7 · Open items

### 7.1 Cheap pre-check for the anchoring hypothesis (no prompt change)

Quantify how often the model's stated code disagrees with the grid on its own levels — answerable
**today** from gold:

```sql
SELECT AI_Ambulatory_Code, EM_MDM_CODE_WITH_MODIFIER, COUNT(*)
FROM <gold>
WHERE AI_EM_Code_Final IS NOT NULL
GROUP BY 1, 2
ORDER BY 3 DESC
```

| outcome | reading |
|---|---|
| disagreement **rare** | the self-consistency check is not earning its keep → removal is low-risk |
| disagreement **common** | it is catching real model inconsistency → we are deleting a safety net |

Worth running before spending the eval. No Databricks access locally; needs someone with creds.

### 7.2 MERCY RULE D — do not delete, escalate

Initially flagged as the best cut. **That was wrong**, and the correction is recorded here so it
isn't re-derived. Rule D (Mod 25 on E/M + procedure/vaccine/POC test) is discarded by the DPC
(Rule C only, QEU-301), and the code comment claims `procedures_at_encounter` "is not yet
populated in the silver table". Measured against real harness data:

| dataset | rows | field non-empty | contains a Rule D trigger |
|---|---:|---:|---:|
| `clinic-feedback-200-20260730` | 199 | 170 | **26 (13 %)** |
| `v1_benchmark` | 139 | 0 | 0 |

The field **is** populated in the July-2026 extract (mostly `3074F`/`3078F` Cat-II measure codes
and `G2211`, correctly not triggers — but 26 real ones). It is empty in `v1_benchmark`, which is
very likely the origin of the "not populated" belief — and means **the eval set cannot observe
Rule D at all.**

So Rule D is a **disabled feature**, not dead weight: on ~1 in 8 real encounters the model answers
the right AMA question and the pipeline throws the answer away (gold carries
`AI_Modifier_25_Judgment = APPLY_MODIFIER_25` alongside `AI_Modifier_25_Applied = NULL`).

**Question for RCM, not a prompt edit:** should Modifier 25 apply on E/M + procedure? If yes this
is missed modifier revenue and the fix belongs in the DPC. If no, delete the text and the trigger
list. QEU-301's *display* concern (Mod 25 shown without a paired preventive misleads coders) is
addressable via `mod25_trigger` without discarding the judgment.

### 7.3 Adjacent defects found during the read (not Exp 1 scope)

| finding | where | note |
|---|---|---|
| Gold writeback omits `prolonged_code` / `prolonged_units` | `databricks_writeback.py` `GOLD_COLUMNS` | QHE-2896 is FE-only; also absent from `HASH_FIELDS`, so a prolonged-only change hashes as unchanged |
| `primary_dx_icd10` / `primary_dx_name` always NULL | same | reads v0 column names; v1 silver uses `physician_primary_dx_icd10_code` |
| Criteria card level ≠ summary level | `transform_v1._copa_criteria` | post-#5896 the section reads the *winner's* `d.level` while summary + billed code use the element-wise majority. Reproduced: summary `moderate`, criteria `Low`, billed 99214 |
| Missing `is_new_patient` silently means "established" | `business_logic` | no unknown branch; a blank value bills est-series codes and est prolonged thresholds for a new patient. Untested |

---

## §8 · Related

- [[clinical-coding-v1]] · [[clinical-coding-v2]]
- [[qhe-2896-payer-field]] — prolonged-service add-on; see the gold-writeback gap in §7.3
- [[clinic-coding-note-extract-prod-gap]] — upstream silver note-extract gap; bounds any accuracy
  measurement, unrelated to the prompt
- [[coding-ai-harness-synthetic-prolonged]] — harness run mechanics, cache and cost gotchas
