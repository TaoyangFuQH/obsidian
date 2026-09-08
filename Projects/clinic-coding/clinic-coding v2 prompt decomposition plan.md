---
updated: 2026-09-08
tags: [project, coding-pod, clinic-coding, prompt, experiment, plan]
---
# Clinic coding v2 — prompt decomposition plan

> PHI-free. No encounter ids, MRNs, note text or patient prose. Dataset row counts and
> CPT/HCPCS code literals only.
[[clinical-coding-v1]]
Investigation of the [[clinical-coding-v1]] LLM contract, and the plan for decomposing the
ambulatory prompt by removing instructions whose outputs the pipeline discards.

**Baseline pinned:** `qh-platform` @ `bb25774943` (develop), `PROMPT_VERSION = "1.3"`,
assembled `AMBULATORY_SYSTEM_PROMPT` = **86,490 chars**.
Two commits landed 2026-09-08 that this plan is written against:
- **#5896 / QHE-3555 (V1.3)** — additive COPA hunks (fence unchanged); COPA/Data/Risk now voted
  **element-wise** across all 3 votes (median-by-severity tie rule) instead of winner-take-all;
  **abstention enabled by default** on new policy `consensus_or_corroborated`.
- **#5907** — per-encounter `llm_raw` (output/thinking/tokens) captured into `result_json`.

---

## 1. What the LLM calls actually output

All three arms — Claude Opus 4.6 (×3 votes), GPT-5.4, Gemini 2.5 Pro — receive the **same**
`AMBULATORY_SYSTEM_PROMPT` and the same `_USER_PROMPT_PREFIX + note`. Each returns a
human-readable `---BEGIN AMBULATORY CODING OUTPUT---` block plus a ```json fence that the
prompt declares authoritative. Parser is JSON-first, text-block regex as fallback.

### The fence contract (11 keys)

| key | kind | consumed by |
|---|---|---|
| `em_code` | **CODE** (99202-99215 / "NONE") | vote key + `if amb_code:` billable gate — **not the billed code** |
| `visit_classification` | judgment | DPC router: which code families compute at all |
| `preventive_type` | judgment | AWV vs commercial preventive routing |
| `preventive_rationale` | prose | Preventive card |
| `awv_checklist_complete` | bool | AWV card attribute |
| `modifier_25_judgment` | judgment | Mod 25 Rule C gate |
| `mdm` | **LEVEL** | **only** the E&M card complexity label |
| `copa` / `data` / `risk` | levels + structured detail | **drives the billed code** (grid middle) |
| `time` | facts (documented / minutes / attributable) | time-based code + prolonged units |

**The only CPT/HCPCS code any LLM emits is `em_code`.** Every other billed code is Python:

| billed code | derived from |
|---|---|
| Office E/M 99202-99215 | `_mdm_grid_middle(copa,data,risk)` → `_MDM_LEVEL_TO_EST_CODE` → `_flip_series` |
| time-based E/M | AMA minute table on `time.total_minutes` (prompt no longer states the table) |
| preventive 99381-99397 | `determine_preventive_code(age, is_new)` |
| AWV G0438/G0439 | `determine_awv_code_v125` 3-tier sequencer |
| prolonged G2212/99417 | payer+series minute thresholds, `1 + (min-T1)//15` |
| modifier 25 | Rule C: E/M **and** preventive present **and** `APPLY_MODIFIER_25` |

**Verified empirically** (real DPC + transform, established/55y/commercial): a vote emitting
`em_code=99213` with COPA/Data/Risk all Moderate bills **99214**. `AI_Ambulatory_Code`=99213 is
kept in gold; `AI_EM_Code_Final`=99214. The model's code number never becomes the billed code.

### Percentage of prompt by topic

Method: split into paragraph/header blocks, attribute each to a topic (blocks inherit their
enclosing section), fence spec attributed per key. 99.5% attributed; residual = blank lines.

| topic | chars | % | nature |
|---|---:|---:|---|
| COPA (rules + AMA problem-type defs) | 17,359 | 20.1% | judgment input |
| DATA (Cat 1/2/3, STEP A-D, thresholds) | 13,886 | 16.1% | judgment input |
| MDM (rubric + grid table + calibration + 2-of-3) | 13,073 | 15.1% | **mostly judgment input** — see below |
| PREVENTIVE (type routing, Rules A/B, WCC) | 11,290 | 13.1% | judgment input |
| MOD25 (Rules C + D, AMA KD4) | 7,176 | 8.3% | Rule D output discarded |
| RISK | 6,260 | 7.2% | judgment input |
| TIME | 5,610 | 6.5% | judgment input |
| PATIENT_STATUS (new vs established) | 2,756 | 3.2% | **output unused** |
| VISIT_CLASS | 2,106 | 2.4% | judgment input |
| framing / priority hierarchy | 1,980 | 2.3% | — |
| AWV | 1,729 | 2.0% | judgment input |
| Mercy FAQ | 1,603 | 1.9% | judgment input |
| fence scaffolding | 613 | 0.7% | — |
| AMA generic | 399 | 0.5% | — |
| **EM_CODE (code emission)** | **141** | **0.16%** | **output partly used** |
| output scaffolding | 89 | 0.1% | — |

### ⚠ The "MDM" 15.1% is NOT code emission — decomposed

| part | chars | % | verdict |
|---|---:|---:|---|
| AMA per-level rubric (`#### SF/Low/Moderate/High MDM`) | 3,871 | 4.48% | **KEEP** — this *is* the COPA/Data/Risk rubric |
| Mercy MDM Complexity Grid table + Mercy examples | 4,004 | 4.63% | **KEEP** — same rubric, `\| Level \| COPA \| Data \| Risk \|` |
| Few-shot calibration (Ex 1, 1b, 2, 3, 4 + how-to-use) | 3,697 | 4.27% | **KEEP** — this is what QHE-3555 tuned to 95% |
| `4. MDM Level (Two-of-Three Rule)` | 333 | 0.39% | removable (Python duplicates) |
| `MDM: [level]` output line | 138 | 0.16% | removable |

Only **471 chars (0.55%)** of the MDM bucket duplicates the deterministic logic. The other
11,572 chars (13.4%) **produces the levels the deterministic logic consumes.**

### Cost reality

Removing all code-emission instructions = **~0.4-1.0% of the prompt**. The system prompt is
`cache_control: ephemeral`, so all 3 votes read it at cache-read pricing; output saving is
~35 tokens/vote against a 12k answer cap + 32k thinking budget. **Token savings are noise —
one eval run costs orders of magnitude more than this ever saves.** Justify Exp 1 on accuracy
and contract hygiene, not cost.

---

## 2. Experiment 1 — remove the unused LLM-generated codes

**Hypothesis.** Asking the model for a code it then has to justify anchors its COPA/Data/Risk
reads (backward rationalisation). Removing the code request lets the levels stand on their own
and should hold or improve the auditor E&M match. Same rationale as QHE-2854 for time coding.

**Scope:** `mdm` level, `Patient Status`, `em_code`. Removed **together**, not separately.

**Why bundling is the coherent unit:** patient status only matters to a *parsed* output via the
code series (99202-05 vs 99212-15). COPA/Data/Risk are series-independent; `time` reports minutes
only. So once `em_code` is gone, patient status is genuinely inert — and `mdm` was already inert.
Removing patient status *alone*, while `em_code` is still the vote key, would force the model to
guess the series → votes fragment → `confidence` drops → and abstention is **live by default**
keyed on `confidence == HIGH`, so prod mask rate moves. **Do not split this experiment.**

### Total removed

| item | chars | % |
|---|---:|---:|
| `mdm` emission (fence key + `MDM:` line + 2-of-3 block) | 671 | 0.78% |
| Patient Status (block 6 + AMA New/Established + output line) | 2,764 | 3.20% |
| `em_code` emission | 141 | 0.16% |
| **total** | **~3,576** | **~4.1%** |

### Known non-trivial cost: `em_code` is load-bearing

Flagged and accepted — but the experiment is **not runnable** without these two replacements:

1. **Ensemble vote key.** `Counter(votes)` on `amb_code` produces `winning_code` **and** the
   HIGH/MEDIUM/LOW `confidence` the live abstention gate reads. Replacement: each vote's **own
   derived MDM code** (`mdm_grid_middle(vote.copa, vote.data, vote.risk)` → est-series code).
   Strictly better — votes on the thing that gets billed. Post-#5896 the levels are already voted
   element-wise, so this only changes the *key*, not the level plumbing.
2. **The "no separately-billable E/M" gate.** `em_code = "NONE"` is the model's explicit opt-out
   (Mercy Rule A/B: a problem-oriented component exists but is not separately billable).
   `visit_classification` **cannot** express this. Replacement: new fence bool
   `separately_billable_em`, and it must **suppress on absence, not default true** — today a total
   fence-parse failure yields no E/M card (visible, safe); a `True` default would emit a
   Straightforward 99212 as a confident answer. Use the `model_fields_set` idiom already in
   `business_logic._attributability_stated`.

---

## 3. Proposed prompt changes

All line numbers @ `bb25774943`, `clinical_coding/prompts/system_prompt.py` unless noted.

### 3a. `mdm` level — remove

| line | action |
|---|---|
| 571 | **delete** `  "mdm": {"level": "Moderate", "copa_level": …, "data_level": …, "risk_level": …},` |
| 585 | **delete** `- "mdm": the four levels (Straightforward \| Low \| Moderate \| High), identical to your MDM line.` |
| 540 | **delete** `MDM: [Straightforward/Low/Moderate/High]` |
| 541 | **delete** `  COPA=[level], Data=[level], Risk=[level] → Sorted: … → Middle=[level] → [code]` |
| 230-234 | **delete** the `**4. MDM Level (Two-of-Three Rule):**` block (333 ch) |

Note: `mdm.copa_level` / `data_level` / `risk_level` have **zero readers** (grep) — the aggregate
takes levels from `detail["copa"]["level"]` etc. Deleting the whole object costs nothing.

**Decision D1 — keep or cut the 2-of-3 arithmetic?** Python owns it, but stating it forces the
model to notice when its own levels don't support its grade. Recommend **cutting it in Exp 1**
(it only exists to produce a code we're deleting) and treating a level-quality regression as the
signal to restore it.

**Companion logic change (required):** `transform_v1.py:591`
`label = _MDM_LABEL.get(_title(coding.mdm_level))` → read a new `dpc.mdm_level` (expose the grid
middle `business_logic.py` already computes at :864). Without this the label falls back to
`"Straightforward"` next to a level-5 code — reproduced today:
`{'code': '99215', 'label': 'Straightforward', 'is_used': True}`.

### 3b. Patient Status — remove

| location | action |
|---|---|
| 270-279 | **delete** the `**6. Patient Status:**` block (2,251 ch) |
| 520 | **delete** `Patient Status: [New/Established]` |
| 521 | **delete** `Encounter Type: [In-person/Telehealth]` (unparsed, same family) |
| `knowledge_base.py:187` | **delete** `### New and Established Patients` (441 ch) |

Safe because: `AmbulatoryCoding.patient_status` is declared and **read by nothing** (grep returns
the declaration only), and `_flip_series` uses silver `is_new_patient` unconditionally. The model
also keeps the *data* regardless — the real `full_clinic_assistant_context_blob` header carries
`Patient Status: Established` (verified in harness `clinic-feedback-200-20260730`).

**⚠ Rescue before deleting — three business rules that exist ONLY here:**
- *"Telehealth exception: Virtual Care / PC 365 / Telehealth patients are coded as ESTABLISHED
  regardless of the field"* — **no** `telehealth`/`virtual` handling anywhere in `business_logic`.
  Since `_flip_series` trusts silver unconditionally this is **already inert in the billed code.**
- the newborn rule, and the hospital-follow-up (different-specialty) rule
- *"if you suspect the Patient Status field is wrong, flag it"* — nothing consumes the flag

Action: confirm with RCM whether the telehealth exception should be **implemented** in
`_flip_series` before the text is deleted. That today's billed code ignores it is a finding in
its own right.

### 3c. `em_code` — remove

| line | action |
|---|---|
| 565 | **replace** `  "em_code": "99214",` → `  "separately_billable_em": true,` |
| 579 | **replace** the `- "em_code": …` bullet → see wording below |
| 518 | **delete** `AMBULATORY E/M CODE: [code]` |
| 545 | **delete** `Final Code: [code]` |

Proposed replacement spec bullet for :579:

> `- "separately_billable_em": true when the problem-oriented work at this encounter is a`
> `  significant, separately identifiable E/M service that should be billed on its own; false`
> `  when there is problem-oriented content but it is NOT separately billable (e.g. Mercy Rule B`
> `  pediatric WCC, or preventive-visit work that is part of the preventive code). Omit nothing —`
> `  always state it explicitly. Do NOT state a CPT code anywhere in your output; the code is`
> `  derived from your COPA/Data/Risk levels.`

**Companion logic changes (required):**
1. `clinical_coding_v1_activities.py:142` + `:150` — the fence is **located** by `em_code`
   (`\{[^{}]*?em_code[^{}]*?\}` and `"em_code" in obj`). **Re-anchor on `visit_classification`.**
   Miss this and the parser silently falls through to the text-block regexes and returns empty
   fields for every encounter.
2. Delete the `AMBULATORY E/M CODE:` / `Final Code:` text-block fallbacks (`:186`, `:188`) and
   `_norm_code` (becomes dead).
3. Aggregate: vote key → per-vote derived MDM code; majority-vote `separately_billable_em`; omit
   the key entirely when no vote asserted it.
4. DPC `business_logic.py:854`: `if amb_code:` →
   `if "separately_billable_em" in coding.model_fields_set and coding.separately_billable_em:`
5. Promote `_mdm_grid_middle` / `_mdm_code_from_level` to public (aggregate becomes a 2nd consumer).
6. Gold `AI_Ambulatory_Code`: repoint to the derived pre-flip MDM code. **Third** semantic shift
   for that column (v0 = final billed → v1 = raw model vote → now derived) — document it.

**Decision D2 — few-shot examples.** Titles are code-labelled ("99214, NOT 99213") and bodies say
"Established". Recommend **leaving them intact**: they teach COPA/Data/Risk boundaries and the code
is illustrative. Rewriting them risks the QHE-3555 calibration. Revisit only if the model starts
emitting codes despite the instruction.

---

## 4. Measurement plan

Prompt change ⇒ harness model-I/O cache invalidated ⇒ **full live Opus run** (3 votes ×
extended thinking) on `v1_benchmark`. Real spend; see [[coding-ai-harness-synthetic-prolonged]]
for run mechanics (`QH_PLATFORM_ROOT` → feature worktree, `--profile clinic`).

Measure **three** things, not one:
1. **E&M auditor match** — bar is 95% (just set by QHE-3555 back-test).
2. **Confidence distribution** vs the PRD SLO (≥90% HIGH) — the vote key changed, so this moves
   by construction.
3. **Abstention coverage / accepted-accuracy** under the live `consensus_or_corroborated` default
   (`unanimous` baseline was 78.6% / 94.6%; new policy 94.4% / 95.5% on the v1_benchmark holdout).
   Masking is **on in prod now**, so a confidence shift changes what coders see.

Sleeper risk: #3. It is the reason the three removals must land as one measured change with the
vote-key replacement, rather than as an incremental prompt trim.

---

## 5. Deliberately NOT in Exp 1

- **The MDM rubric / grid table / few-shot calibration (13.4%)** — these are the model's *inputs*,
  not redundant outputs. Cutting them would remove the reasoning, and would directly undo QHE-3555.
- **`em_code` as a canary (alternative to removal).** Before/instead of deleting it, quantify how
  often the model's stated code disagrees with the grid on its own levels — answerable **today**
  from gold with no prompt change:
  ```sql
  SELECT AI_Ambulatory_Code, EM_MDM_CODE_WITH_MODIFIER, COUNT(*)
  FROM <gold> WHERE AI_EM_Code_Final IS NOT NULL GROUP BY 1,2 ORDER BY 3 DESC
  ```
  Rare disagreement ⇒ the self-consistency check isn't earning its keep ⇒ removal is low-risk.
  Common ⇒ it is catching real model inconsistency and we are deleting a safety net.

### Open item — MERCY RULE D (2,667 ch, 3.1%) — do NOT delete yet

Initially flagged as the best cut; **that was wrong.** Rule D (Mod 25 on E/M + procedure/vaccine/
POC test, lines 453-487) is discarded by the DPC (Rule C only, QEU-301), and the code comment
claims `procedures_at_encounter` "is not yet populated in the silver table". Measured against real
harness data:

| dataset | rows | `procedures_at_encounter` non-empty | contains a Rule D trigger |
|---|---:|---:|---:|
| `clinic-feedback-200-20260730` | 199 | 170 | **26 (13%)** |
| `v1_benchmark` | 139 | 0 | 0 |

The field **is** populated in the July-2026 extract (mostly `3074F`/`3078F` Cat-II measure codes
and `G2211`, correctly not triggers — but 26 real triggers). It is empty in `v1_benchmark`, which
is very likely the origin of the "not populated" belief, and means **the eval set cannot observe
Rule D at all.**

So Rule D is a **disabled feature**, not dead weight: on ~1 in 8 real encounters the model answers
the right AMA question and the pipeline throws the answer away (gold shows
`AI_Modifier_25_Judgment = APPLY_MODIFIER_25` with `AI_Modifier_25_Applied = NULL`).
**Question for RCM, not a prompt edit:** should Mod 25 apply on E/M + procedure? If yes, this is
missed modifier revenue and the fix belongs in the DPC. If no, delete the text and the trigger
list. QEU-301's *display* concern (Mod 25 shown without a paired preventive misleads coders) is
addressable via `mod25_trigger` without discarding the judgment.

---

## 6. Related

- [[clinical-coding-v1]] · [[clinical-coding-v2]]
- [[qhe-2896-payer-field]] — prolonged-service add-on; note gold writeback **omits**
  `prolonged_code`/`prolonged_units` entirely (FE-only today)
- [[clinic-coding-note-extract-prod-gap]] — upstream silver note-extract gap; unrelated to the
  prompt but bounds any accuracy measurement
- [[coding-ai-harness-synthetic-prolonged]] — harness run/cache mechanics and cost gotchas
