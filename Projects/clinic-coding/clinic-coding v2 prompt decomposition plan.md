---
updated: 2026-09-08
tags: [project, coding-pod, clinic-coding, prompt, investigation]
---
# Clinic coding v2 — prompt decomposition plan

> **PHI-free.** No encounter ids, MRNs, note text or patient prose. CPT/HCPCS literals and
> dataset row counts only. Keep it that way.

> [!info] Investigation note
> What the clinic-coding LLM calls actually emit, which of those outputs the pipeline consumes,
> and how the ~86 k-char ambulatory prompt divides by topic. **Experiment designs live in their
> own notes** — stage 1 is
> [[clinic-coding v2 S1 prompt simplification - deterministic logic removal]].

---

## 1 · Baseline

| item | value |
|---|---|
| repo | `qh-platform` @ `bb25774943` (develop) |
| prompt version | `PROMPT_VERSION = "1.3"` |
| prompt size | 86,490 chars (assembled `AMBULATORY_SYSTEM_PROMPT`) |
| package tests | 494 pass, ~0.3 s |

Two commits landed 2026-09-08 mid-investigation; everything below is measured **after** them:

| PR | what changed | consequence |
|---|---|---|
| #5896 / QHE-3555 | prompt → V1.3 (additive COPA hunks; fence unchanged); COPA/Data/Risk voted **element-wise** across votes with a median-by-severity tie rule; **abstention ON by default**, new policy `consensus_or_corroborated` | masking is live in prod and reads `confidence`; GPT-5.4 + Gemini now actually run |
| #5907 | per-encounter `llm_raw` (output / thinking / tokens) into `result_json` | orientation only |

> [!warning] Line numbers in this note are hints
> The working tree fast-forwarded mid-investigation and every line number shifted. Anything
> actionable is keyed on a **grep anchor** in the S1 note, not on a line number.

---

## 2 · What the LLM calls output

All three arms — Claude Opus 4.6 (×3 votes), GPT-5.4, Gemini 2.5 Pro — receive the **same**
`AMBULATORY_SYSTEM_PROMPT` and the same `_USER_PROMPT_PREFIX + note`. The verifiers reuse the
Claude activity's own parser, aggregate and DPC by direct import, so parsing is identical code,
not a reimplementation.

| | Claude Opus 4.6 | GPT-5.4 (Azure) | Gemini 2.5 Pro |
|---|---|---|---|
| system prompt | same constant, `cache_control: ephemeral` | same constant | same constant |
| reasoning | thinking, budget 32 k | `effort: high` | `thinking_budget: 24576` |
| temperature | 1 (forced by thinking) | default | 0.0 |
| output cap | 12 k + 32 k = 44 k | 32 k | 32 k |
| prompt caching | yes | no | no |

Two asymmetries worth knowing: the verifier path applies **no** `max_clinical_notes_chars`
truncation (Claude truncates at 400 k), and sampling is not matched — so "QH disagrees with
Gemini" is partly a temperature artifact.

### 2.1 The fence contract — 11 keys

Each call returns a `---BEGIN AMBULATORY CODING OUTPUT---` text block plus a ` ```json ` fence
the prompt declares authoritative. Parsing is JSON-first, text-block regex as fallback.

| key | kind | consumed by |
|---|---|---|
| `em_code` | **code** | vote key + `if amb_code:` billable gate — **not the billed code** |
| `mdm` | **level** | E&M card complexity label, nothing else |
| `copa` | level + detail | **drives the billed code** (grid middle) |
| `data` | level + detail | **drives the billed code** |
| `risk` | level + detail | **drives the billed code** |
| `time` | facts | time-based code + prolonged units |
| `visit_classification` | judgment | routes which code families compute at all |
| `preventive_type` | judgment | AWV vs commercial preventive routing |
| `preventive_rationale` | prose | Preventive card |
| `awv_checklist_complete` | bool | AWV card attribute |
| `modifier_25_judgment` | judgment | Mod 25 Rule C gate |

`mdm.copa_level` / `data_level` / `risk_level` are read by **nothing** — the aggregate takes those
levels from `detail["copa"]["level"]` etc. Pure prompt overhead.

### 2.2 `em_code` is the only code any LLM emits

Every billed code is Python:

| billed code | derived from |
|---|---|
| office E/M 99202-99215 | grid middle of COPA/Data/Risk → est-series code → series flip |
| time-based E/M | AMA minute table on `time.total_minutes` (prompt no longer states the table) |
| preventive 99381-99397 | age + new/established lookup |
| AWV G0438 / G0439 | 3-tier sequencer — arpb claims → note keywords → HETS |
| prolonged G2212 / 99417 | payer + series minute thresholds, `1 + (min − T1)//15` |
| modifier 25 | Rule C: E/M **and** preventive present **and** `APPLY_MODIFIER_25` |

**Verified live** — real DPC + transform, established / 55 y / commercial, a vote whose COPA,
Data and Risk are all Moderate:

| signal | value |
|---|---|
| vote `em_code` | 99213 |
| **billed** `em_code` | **99214** ← grid middle, not the vote |
| `result_json.mdm_level` | `level 4` ← from `dpc.mdm_code` |
| gold `AI_Ambulatory_Code` | 99213 — raw vote, kept |
| gold `AI_EM_Code_Final` | 99214 |

The model's code number never becomes the billed code. In `apply_v1_post_processing` it is read
**only** as a truthiness gate (`if amb_code:` = "is there a separately billable E/M at all").

### 2.3 Where `em_code`'s value does matter

| # | use | note |
|:--:|---|---|
| 1 | ensemble majority vote → `confidence` | HIGH / MEDIUM / LOW; feeds the live abstention gate |
| 2 | winner selection | the winning vote supplies `visit_class`, `preventive_type`, rationales and the COPA/Data/Risk **detail** that *is* billed off |
| 3 | gold `AI_Ambulatory_Code` | also in `HASH_FIELDS`, so a drifting raw vote writes a new gold row even when the billed code is unchanged |
| 4 | abstention comparison | verifiers return post-DPC `em_code`; only the E/M is compared |

So a vote can name 99213, lose the arithmetic to its own reported levels, and still be billed
99214 — while *selecting* which levels get used.

### 2.4 `mdm` is used in exactly one place

`coding.mdm_level` has a single live consumer: `transform_v1.py:591`,
`label = _MDM_LABEL.get(_title(coding.mdm_level), "")` — the complexity **label** on the E&M card.

Because the code comes from the grid and the label from the model's self-report, they can
disagree on the same card. Both states reproduce:

| scenario | rendered `mdm_code` slot |
|---|---|
| model said `mdm.level = "Low"`, grid middle of its own levels = Moderate | `{'code': '99214', 'label': 'Low complexity'}` |
| fence omitted `mdm` and the text-block `MDM:` regex missed → default | `{'code': '99215', 'label': 'Straightforward'}` |

No test covers label-vs-code agreement. There is also a stale comment in
`clinical_coding_v1_activities.py:830` asserting `transform_v1` recomputes `mdm_level` — it does
not, which is how this corner stayed forgotten.

### 2.5 `visit_classification` — what it is for

The **router**: it decides which code families compute at all.

| value | preventive / AWV step | E/M step |
|---|:--:|:--:|
| `PREVENTIVE_ONLY` | ✓ | — |
| `PROBLEM_ORIENTED_ONLY` | — | ✓ |
| `PREVENTIVE_AND_PROBLEM_ORIENTED` | ✓ | ✓ |

Mod 25 then falls out of both being present. It also selects which `guideline_report` cards
render, gates the aggregate's "preventive-only, no E/M code" branch, and lands in gold
`AI_Visit_Classification` (and `HASH_FIELDS`). Default on missing/unparseable is
`PROBLEM_ORIENTED_ONLY`. Unlike COPA/Data/Risk it is still winner-take-all, not element-wise voted.

**It cannot absorb `em_code`'s gate role.** `visit_classification` says *"a problem-oriented
component exists"*; `em_code = "NONE"` says *"that component is not separately billable"* — the
Mercy Rule A/B case (pediatric WCC, preventive visit with trivial problem work).

---

## 3 · Prompt budget by topic

Method: split into paragraph/header blocks, attribute each to one topic (blocks inherit their
enclosing section), fence spec attributed per key. 99.5 % attributed; residual = blank lines.

| topic | chars | % | nature |
|---|---:|---:|---|
| COPA | 17,359 | 20.1 % | judgment input |
| DATA | 13,886 | 16.1 % | judgment input |
| MDM | 13,073 | 15.1 % | **mixed — see §4** |
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

---

## 4 · The "MDM 15.1 %" is mostly judgment input

This bucket name misleads: it is **not** code emission.

| part of the bucket | chars | % | verdict |
|---|---:|---:|:--:|
| AMA per-level rubric (`#### SF/Low/Moderate/High MDM`) | 3,871 | 4.48 % | **KEEP** |
| Mercy MDM Complexity Grid table + Mercy examples | 4,004 | 4.63 % | **KEEP** |
| Few-shot calibration (Ex 1, 1b, 2, 3, 4 + how-to-use) | 3,697 | 4.27 % | **KEEP** |
| `4. MDM Level (Two-of-Three Rule)` block | 333 | 0.39 % | removable |
| `MDM: [level]` output line | 138 | 0.16 % | removable |

The rubric blocks *are* the COPA/Data/Risk definitions — `#### Low MDM` reads "COPA: Low (any one
of): 2+ self-limited or minor problems; 1 stable chronic illness; …", and the Mercy grid's columns
are Level / COPA / Data / Risk. The few-shot block is the Mercy biller calibration QHE-3555 tuned
to reach 95 % auditor match.

**Only 471 chars (0.55 %) of this bucket duplicates deterministic logic.** The other 11,572 chars
(13.4 %) *produce the levels* that logic consumes. Deleting them removes the model's inputs, not
its redundant outputs — and would directly undo QHE-3555.

---

## 5 · Findings — what is actually removable

| candidate | size | status | verdict |
|---|---:|:--:|---|
| `mdm` fence key + `MDM:` line + 2-of-3 block | 0.78 % | unused | **remove** — needs the card-label fix |
| Patient Status block + AMA New/Established | 3.20 % | output unused | **remove** — rescue 3 undocumented rules first |
| `em_code` emission | 0.16 % | **partly used** | **removable with replacements** — vote key + billable gate |
| MERCY RULE D | 3.08 % | output discarded, but **fires on real data** | **escalate, do not delete** — see §6 |
| MDM rubric / grid / calibration | 13.4 % | judgment input | **keep** |
| COPA / DATA / RISK / TIME rules | ~50 % | judgment input | **keep** |

→ Stage 1 acts on the first three: [[clinic-coding v2 S1 prompt simplification - deterministic logic removal]].

### 5.1 Cost is not a reason

| factor | value |
|---|---|
| all code-emission instructions | 0.4 – 1.0 % of prompt |
| input cost | system prompt is `cache_control: ephemeral` → 3 votes read at cache-read price |
| output cost | ~35 tokens/vote saved, against a 12 k answer cap + 32 k thinking budget |
| eval cost to validate | orders of magnitude more than the saving |

Justify any removal on **accuracy** (anchoring) and **contract hygiene**.

---

## 6 · MERCY RULE D — recorded correction

Initially flagged as the best cut. **That was wrong**; recorded here so it is not re-derived.

Rule D (Modifier 25 on E/M + procedure / vaccine / POC test, ~2,667 chars) is discarded by the DPC
— `apply_v1_post_processing` applies Mod 25 under **Rule C only** (QEU-301). The code comment
justifying that says `procedures_at_encounter` "is not yet populated in the silver table".
Measured against real harness data:

| dataset | rows | field non-empty | contains a Rule D trigger |
|---|---:|---:|---:|
| `clinic-feedback-200-20260730` | 199 | 170 | **26 (13 %)** |
| `v1_benchmark` | 139 | 0 | 0 |

The field **is** populated in the July-2026 extract, and the context blob carries it under exactly
the header the prompt names. Most values are `3074F` / `3078F` Cat-II measure codes and `G2211`
(correctly not triggers) — but 26 are real triggers. It is empty in `v1_benchmark`, which is very
likely the origin of the "not populated" belief, and means **the eval set cannot observe Rule D.**

So Rule D is a **disabled feature**, not dead weight: on ~1 in 8 real encounters the model answers
the right AMA question and the pipeline throws the answer away. Gold carries
`AI_Modifier_25_Judgment = APPLY_MODIFIER_25` alongside `AI_Modifier_25_Applied = NULL`.

**Question for RCM, not a prompt edit:** should Modifier 25 apply on E/M + procedure? If yes, this
is missed modifier revenue and the fix belongs in the DPC. If no, delete the text and the trigger
list. QEU-301's *display* concern — Mod 25 shown without a paired preventive misleads coders — is
addressable via `mod25_trigger` without discarding the judgment.

---

## 7 · Adjacent defects found during the read

Out of scope for prompt work; logged so they are not lost.

| finding | where | detail |
|---|---|---|
| Gold writeback omits `prolonged_code` / `prolonged_units` | `databricks_writeback.GOLD_COLUMNS` | QHE-2896 is FE-only; also absent from `HASH_FIELDS`, so a prolonged-only change hashes as unchanged and is skipped |
| `primary_dx_icd10` / `primary_dx_name` always NULL | same | reads v0 column names; v1 silver uses `physician_primary_dx_icd10_code` |
| Criteria card level ≠ summary level | `transform_v1._copa_criteria` | post-#5896 the section reads the *winner's* `d.level` while summary + billed code use the element-wise majority. Reproduced: summary `moderate`, criteria `Low`, billed 99214 |
| Missing `is_new_patient` silently means "established" | `business_logic` | no unknown branch; a blank or `"null"` value bills est-series codes and est prolonged thresholds for a new patient. Untested |
| AWV Tier 2 is a keyword scan over model prose | `determine_awv_code_v125` | no negation handling; `"established medicare patient"` is phrasing that appears in E/M *series* reasoning. Prompt never asks for an initial-vs-subsequent field |
| `temporal_config` model params are decorative | `dag/temporal_config_v1.json` | `llm_model` / `thinking_budget` / `max_tokens` / `ensemble_votes` are not passed via `arg_keys`; the activity hard-codes them |

---

## 8 · Open questions

### 8.1 Quantify the anchoring hypothesis — no prompt change, no eval spend

How often does the model's stated code disagree with the grid on its **own** levels? Answerable
today from gold:

```sql
SELECT AI_Ambulatory_Code, EM_MDM_CODE_WITH_MODIFIER, COUNT(*)
FROM <gold>
WHERE AI_EM_Code_Final IS NOT NULL
GROUP BY 1, 2
ORDER BY 3 DESC
```

| outcome | reading |
|---|---|
| disagreement **rare** | the self-consistency check is not earning its keep → removing `em_code` is low-risk |
| disagreement **common** | it is catching real model inconsistency → removal deletes a safety net |

No Databricks access locally; needs someone with creds.

### 8.2 Should the telehealth-established exception be implemented?

It exists only in the prompt's Patient Status block and is inert in the billed code, because
`_flip_series` trusts silver `is_new_patient` unconditionally. Same for the newborn and
hospital-follow-up rules. Needs an RCM answer before that text is deleted.

---

## 9 · Related

- [[clinic-coding v2 S1 prompt simplification - deterministic logic removal]] — stage-1 experiment spec
- [[clinic-coding v2 S2 prompt decomposition]] — stage-2 spec: one prompt per code (COPA · DATA · RISK · TIME)
- [[clinical-coding-v1]] · [[clinical-coding-v2]]
- [[qhe-2896-payer-field]] *(Claude memory)* — prolonged-service add-on; see the gold-writeback gap in §7
- [[clinic-coding-note-extract-prod-gap]] *(Claude memory)* — upstream silver note-extract gap; bounds any accuracy
  measurement, unrelated to the prompt
- [[coding-ai-harness-synthetic-prolonged]] — harness run mechanics, cache and cost gotchas
  *(Claude memory file, not a vault note — key points inlined in this note)*
