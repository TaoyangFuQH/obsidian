> **Corrections applied before the design was written (Tao/Claude verification pass, 2026-08-13).**
> Four things in the brief and two in the grounding packet are wrong, and each changes a design decision.
>
> 1. **Fact 5 is inverted.** `ed/verifiers.py::_codes_from_pro` does discard 47 of 52 PRO fields
>    (`ed/verifiers.py:129-141`) — but that module has **zero importers** and never ran: the harness
>    registers the **prod** activity (`ed/profile.py:78`, `activity_classes=(…, EdVerifierScoringActivity, …)`).
>    Prod stores the raw PRO text **before** parsing, deliberately
>    (`ed_verifier_scoring_activity.py:264-275`, "a parse failure must not discard the captured call"),
>    and it lands at `result_json.llm_raw['ed-verifier-scoring'].pro.gpt54.output`. Nothing is discarded
>    except by `ed/gate.py:37`, which reads only `pro_votes`. **Call 1 is a field read, not a call.** ✅
> 2. **The blindness question is settled, against the module docstring.** `ed_verifier_scoring_activity.py:4`
>    says the verifier "reus[es] QH's DATA + RISK questionnaire answers". That line is **stale**. Each
>    verifier runs its own `_data()`/`_risk()` (`:226-241`) and `build_combined_pass2_content(row_data,
>    data_qa, risk_qa)` at `:245` is called with **its own** answers; the activity-level `data_qa`/`risk_qa`
>    args are dead (`:517-523` TODO, `:543-544` "IGNORED"). ✅ *The `aggregation_code` agent flagged this as
>    UNMEASURED and cited the stale docstring; `verifier_reuse` read the code. `verifier_reuse` is right.*
> 3. **The recommended calibration lanes are a patched prompt.** `process_supervision` named test215 sigs
>    `712be4b28285` / `988e5132270f` (prompt_fp `5d06c9f8f9a1`) as the paired lanes. `5d06c9f8f9a1` is a
>    **prompt-tuning variant**. The stock PRO system prompt is `7e9ba993bb26` — every `patches: null`
>    manifest carries it (`ed/experiments/qhe-5228-verifier-json/results/fulldag-test215-fixed/manifest.json`
>    → `prompt_sha1.pro = 7e9ba993bb264bd9…`). Baseline lanes are named in § D-1. ✅
> 4. **"Half the cross-family disagreement is judge noise" understates it, and misattributes it.**
>    `judge_reliability` measured only the *judge's* self-disagreement. Measuring **both** sides on the same
>    corpus at the same prompt: on the three COPA criteria the **generator** is the noisier rater —
>    QH self-flip 18.9 / 9.9 / 8.2% vs GPT-5.4 7.1 / 2.2 / 0.3% ✅. So the noise floor is larger than
>    reported *and* mostly ours. § E's estimator subtracts both.
> 5. **`guideline_report` is settled as a renderer** — all three code agents concur and I confirmed the
>    anchors (`report_builder.py:136` static 61-item `_FACILITY_CHECKLIST`, `:601-620` `criteria_met =
>    _find_matching_factor(...)` then `if level > facility_level: is_met = False`, `:647` synthetic
>    citations, `transform.py:106` called on the `run_two_stage_calculations` output) ✅. Answer to the
>    brief's UNMEASURED question 2(b): **negative, not independent.**
> 6. **The unjudgeable set is 2 criteria, not 1.** On the corpus that actually has cross-family vectors
>    (test215 + dev93) `risk_emergency_procedure_performed` is 0.0% in **both** raters, alongside
>    `risk_physical_restraints_used` ✅. wa402's 0.2% for the former does not transfer.
>
> **And one finding that reframes the tier, § C.** Flipping **all 12 RISK booleans** through the real
> `run_two_stage_calculations` changes a billed output on **0/402** encounters; flipping **all 3 COPA
> booleans**, likewise **0/402** ✅. Fifteen of the eighteen criteria are causally disconnected from the
> bill. There is no aggregation to keep deterministic for them.

---
updated: 2026-08-13
tags: [project, coding-pod, eval, auto-eval, tier-4, judge]
---
# Tier 4 — Decomposed criterion judging (final)

Tier 4 of [[auto eval plan]], scheduled as Phase 4 of [[auto eval roadmap]]. **⚠ Read [[LLM as a judge SOTA]] §3 first** — ordinal 3-5-level judging is only 38-58% exact, so a *level* judge cannot adjudicate the one-rung disagreements that matter; the binary criterion surface is the reliable one (κ 0.642).

**Everything marked ✅ I measured today** over `ed/experiments/qhe-5228-verifier-json/results/{fulldag-test215-fixed,fulldag-dev93-fixed}`, `ed/dataset/{qh-0731-test-set-215,qh-0731-dev-set-93}/cache/`, `ed/experiments/washington-402-baseline/results/run1`, and the qh-platform checkout. Scripts: scratchpad `t4_{count,lanes,paired,noise,theta,ev,fac,calib,abl}.py`. ⚠ = grounding-agent-measured, not re-run. UNMEASURED means UNMEASURED, with the measurement named.

**Corpus discipline, stated once.** The brief's prevalence table is **washington-402**. washington-402 has **no verifier cache** (only `claude-sonnet-4-6`, `claude-sonnet-5`) ✅. Every cross-family number in this document is **qh-0731-test-set-215** or **qh-0731-dev-set-93**. `docs/EVALUATION.md`'s no-pooling rule applies: a test215 agreement rate may not be quoted against a wa402 prevalence, and the two 0731 sets may not be averaged.

---

## A. What this tier claims, and the precondition

Tier 3 constructs a counterfactual. Tier 4 does something weaker and cheaper: it asks a **second, differently-trained reader of the same bytes** the same 18 yes/no questions, and reports where the two readers differ **in excess of what each reader disagrees with itself**. It is a localizer and a ranker.

**The precondition is task-decomposability, and our surface satisfies it on 6 of 18 criteria — not on the surface as a whole.** The verification-asymmetry result is explicitly conditional: gains concentrate on logical/structured tasks and *vanish on factual-recall tasks*, "because verifying an answer requires essentially the same knowledge as solving it" ([When Does Verification Pay Off?](https://arxiv.org/html/2512.02304v2)). Our 18 booleans split cleanly along that line, and the measured excess-over-noise **reproduces the split exactly** (§ B table, θ̂ column): every criterion with θ̂ ≥ 3pp is judgement-laden or attribution/section-gated (`data_prompt.py:74-90`, `risk_prompt.py:410-425`, `copa_prompt.py:45-58`); every near-pure document-recall criterion (`prescription_drug_management`, `parenteral_medications_administered`, `iv_fluids_administered`, `controlled_substance_iv`, `nebulizer_treatments_repeated`) has θ̂ ≤ 1.8pp and four of them have a CI touching 0 ✅. That is a pre-registered literature prediction confirmed on our corpus, and it is the strongest single result in this design: **the blind extractor agrees with us on the criteria where agreement is uninformative, and disagrees where no rater is reliable.**

Ceilings the report must state, so a disagreement rate is never read as an error rate:

| bound | value | source |
|---|---|---|
| rubric grader vs physicians, closest published clinical analogue | macro-F1 **0.709**, against physicians agreeing with each other **0.569–0.730** | [HealthBench](https://arxiv.org/html/2505.08775v1) |
| grounded-entailment judging (= call 2) | **74–75%** balanced accuracy at the top (GPT-4 75.3, Claude-3-Opus 74.1, MiniCheck-FT5 74.7 at 400× less cost) | [MiniCheck / LLM-AggreFact](https://aclanthology.org/2024.emnlp-main.499/) |
| attribution evaluation, fine-tuned | ~**80%** macro-F1 | [AttributionBench](https://arxiv.org/abs/2402.15089) |
| human CPT coder agreement | κ **0.458** | [PMC12599997](https://pmc.ncbi.nlm.nih.gov/articles/PMC12599997/) |
| LLM judge vs exhaustive human review, production agent | ~**18%** pattern recall; 50% of confirmed defects in dimensions the rubric could not name | [Catching One in Five](https://arxiv.org/pdf/2606.10315) |

**What a criterion disagreement CAN conclude.** (i) That two model families read the same documentation differently on a named criterion, with an effect size in excess of both models' own instability and a bootstrap CI. (ii) A **prompt address** — the criterion's clause in `copa_prompt.py` / `data_prompt.py` / `risk_prompt.py` — which is what `skills/rca-coding` needs and what a level-level disagreement does not give. (iii) A **direction**: our-true/judge-false vs the reverse, which is the compliance axis (§ E).

**What it CANNOT conclude.** (i) Which rater is right — the per-criterion decision threshold differs by family by up to 8× ⚠ (`copa.life_or_function_threatening` TRUE at QH 8.4% / GPT-5.4 2.4% / Gemini 25.3%, `judge_reliability`), and I measure Gemini's own self-flip on that criterion at **10.2%** and on `behavioral_health_safety_assessment` at **18.0%** ✅ — so part of what reads as a threshold is instability. (ii) That the **level** is wrong: 15 of 18 booleans do not enter the level computation at all (§ C). (iii) That anything is **missing** — decompose-then-verify "cannot measure missing information … it only verifies the information that is present" ([Decomposition Dilemmas](https://arxiv.org/html/2411.02400v1)); RISK Low and Minimal have **no booleans at all** and ⚠ 90/402 wa402 encounters carry a RISK rung with zero structured boolean (tier-3 § D-6). (iv) An **accuracy number**. [[auto eval plan]]'s "NOT for replacing `gt.csv`" line survives intact, now for three independent reasons: judge bias, the ceilings above, and criterion ambiguity.

---

## B. The surface decision

**Judge surface (a): `result_json.llm_raw['ed-pro-scoring'].pro.qh.output`** — an embedded JSON *string*; parse it. 18 booleans + `copa_problem_count` + three DATA count/list pairs + `risk_disposition` + three declared levels + the evidence strings. **Surface (b) `result_json.guideline_report` is UI-only and is deleted from the design.**

Why (b) is dead, with the code: `transform.py:106` calls `build_guideline_report(calc, note_text=…, data_qa, risk_qa)` where `calc` **is** the `run_two_stage_calculations` output — so (b) carries no information not in (a) plus two static tables. The 61 facility rows are a hardcoded constant, `report_builder.py:136` `_FACILITY_CHECKLIST` ("ACEP 2023, never changes"); `criteria_met` is `_find_matching_factor(item_title, facility_determining_factors)` — substring/keyword match against the model's free text (`report_builder.py:601-606`, matcher at `:1074-1109`) — then hard-gated `if level > facility_level: is_met = False` (`:618-620`), demoted by a `RECONSIDERED` regex (`:653-665`), with citations **synthesised** from evidence text when the model supplied none (`:647`) ✅. Measured consequences ⚠ (`aggregation_code`, `judge_reliability` concurring): 61.0 rows and 1.664 met per encounter = **2.73%** prevalence, so an agreement statistic over (b) is ~97% by construction with degenerate κ; the level guard suppresses a keyword-matched criterion on 68/402; 24/402 display zero met criteria at the billed level; 11 displayed met criteria exist only because a regex found "= yes" in prose. **A tier-4 "criterion vs criterion" conflict found in (b) is a matcher artifact, not a model inconsistency.**

Two free tier-1 findings fall out of (b) and are handed back: the fuzzy factor matcher can silently drop a met criterion, and `guideline_report` citations are not evidence of grounding.

**Facility, separately.** The model emits its own `facility_criteria_met` dict (per-level lists of checklist titles) which `business_logic.py:657` passes through unused and the renderer never reads; ⚠ 1,771 items on wa402 vs 669 displayed. That is the real model-authored facility criterion surface and it supports a **deterministic** replay (§ C). It has **no cross-family counterpart at any price**: `ProOnlyResponseModel` hides all 7 `facility_*` fields via `SkipJsonSchema` (`ed_verifier_scoring_activity.py:81-95`) and `fac_code` is forced `None` (`:311`), so `abstention.fac_votes.{gpt54,gemini}` is always null.

### The judgeable-criterion table

Prevalence = QH / GPT-5.4 on **test215, n=210 paired** ✅ (5 of 215 PRO bodies unparseable — the QHE-5228 class). wa402 column is the brief's, for contrast only — **never pool**. θ̂ = cross-family disagreement minus ½(QH within-arm + judge within-arm), per encounter then averaged, 2000-resample bootstrap over **encounters**; QH 4 baseline lanes × GPT-5.4 3 baseline lanes, prompt_fp `7e9ba993bb26`, n=201 common ✅. `dir` = signed cross-pair asymmetry, pp, positive = QH credits and the judge does not. `→tail` = does flipping this field change any billed output through the real aggregator ✅.

| criterion | axis | test215 QH/GPT | wa402 | kind | evidence field | →tail | noise QH/GPT | **θ̂ pp [95%]** | dir | verdict |
|---|---|---|---|---|---|---|---|---|---|---|
| `life_or_function_threatening` | copa | 14.8 / 3.8 | 13.2 | judgement + explicit-differential text gate (`copa_prompt.py:45-58`) | none (axis only) | **no** | 9.88 / 2.16 | **6.63 [3.85, 9.78]** | **+11.5** | **scored** |
| `has_new_problem_uncertain_prognosis` | copa | 43.8 / 43.3 | 50.7 | judgement (prognosis) | none | **no** | **18.89** / 7.05 | **5.90 [3.62, 8.39]** | +0.8 | **scored, low-consensus** |
| `has_chronic_severe_exacerbation` | copa | 9.5 / 1.4 | 10.2 | judgement (5 stability indicators, `copa_prompt.py:682-696`) | none | **no** | 8.21 / 0.33 | **4.69 [2.59, 7.26]** | **+9.0** | **scored** |
| `independent_interpretation` | data | 47.1 / 39.5 | 51.7 | rule: attribution + section gate (`data_prompt.py:74-90`) | `data_interpretation_evidence` | **yes** (+6 pts) | 2.67 / 3.07 | **4.79 [2.11, 7.86]** | **+6.5** | **scored, primary** |
| `evaluation_for_surgical_emergency` | risk | 10.5 / 6.7 | 8.2 | judgement (differential + workup) | `risk_evidence[k]` | no | 3.55 / 3.32 | **3.55 [1.41, 6.19]** | +3.5 | **scored** |
| `independent_historian` | data | 21.9 / 19.5 | 23.4 | rule (age<3 automatic) + judgement | `data_historian_evidence` | **yes** (+3 pts) | 1.69 / 4.89 | **2.99 [1.33, 4.89]** | +3.9 | **scored** |
| `iv_fluids_administered` | risk | 24.3 / 23.8 | 20.4 | recall — **fused two-rung boolean** (`risk_prompt.py:400-407`) | `risk_evidence[k]` | no | 1.39 / 1.00 | 1.76 [0.33, 3.50] | −0.2 | **guard** (representational gap) |
| `prescription_drug_management` | risk | 73.3 / 70.5 | 69.2 | recall + carve-out rule (`risk_prompt.py:553-560, 585-612`) | `risk_evidence[k]` | no | 1.58 / 0.58 | 1.03 [0.08, 2.39] | +1.9 | **guard** |
| `behavioral_health_safety_assessment` | risk | 3.3 / 2.9 | 2.5 | rule/recall | `risk_evidence[k]` | no | 0.20 / 0.25 | 0.75 [0.00, 1.99] | +1.0 | **guard** |
| `external_qhp_discussion` | data | 4.3 / 5.7 | 7.5 | rule (attribution) | `data_qhp_evidence` | **yes** (+6 pts) | 0.88 / 0.58 | 0.56 [−0.17, 1.71] | −0.9 | **guard** |
| `parenteral_medications_administered` | risk | 40.0 / 42.4 | 32.6 | recall | `risk_evidence[k]` | no | 1.63 / 1.99 | 0.30 [−0.12, 0.88] | −0.1 | **guard** |
| `drug_therapy_intensive_monitoring` | risk | 0.5 / 0.0 | 0.7 | recall, rare | `risk_evidence[k]` | no | 0.45 / 0.00 | 0.30 [0.00, 0.90] | +0.5 | **guard** |
| `nebulizer_treatments_repeated` | risk | 1.0 / 1.0 | 1.0 | recall, rare | `risk_evidence[k]` | no | 0.30 / 0.00 | 0.15 [0.00, 0.45] | +0.3 | **guard** |
| `social_determinants_limiting_treatment` | risk | 1.0 / 1.4 | 2.5 | section-gated rule (`risk_prompt.py:410-425`) | `risk_evidence[k]` | no | 0.30 / 1.24 | 0.03 [−0.15, 0.25] | −0.2 | **guard** |
| `controlled_substance_iv` | risk | 10.0 / 10.0 | 8.5 | recall | `risk_evidence[k]` | no | 0.25 / 0.00 | 0.00 [0.00, 0.00] | +0.1 | **guard** (perfect agreement, Po=1.000) |
| `moderate_sedation` | risk | 0.5 / 0.5 | 0.7 | recall, rare | `risk_evidence[k]` | no | 0.00 / 0.00 | 0.00 | 0.0 | **guard** |
| `emergency_procedure_performed` | risk | **0.0 / 0.0** | 0.2 | recall, rare | `risk_evidence[k]` | no | 0.00 / 0.00 | 0.00 | 0.0 | **UNJUDGEABLE** (p=0 both raters) ✅ |
| `physical_restraints_used` | risk | **0.0 / 0.0** | 0.0 | recall, rare | `risk_evidence[k]` | no | 0.00 / 0.00 | 0.00 | 0.0 | **UNJUDGEABLE** (p=0 both raters) |
| — *declared* `copa_level` | copa | — | — | declared | `copa_rationale` | **yes** | 10.03 / 9.62 | **9.50 [6.12, 13.25]** | **+12.7** | **scored (axis)** |
| — *declared* `data_level` | data | — | — | recomputed | — | (overwritten) | 4.54 / 6.80 | **8.38 [4.83, 12.06]** | +5.9 | **scored (axis)** |
| — *declared* `risk_level` | risk | — | — | declared | `risk_determining_factor` | **yes** | 5.90 / 5.06 | **6.46 [3.56, 9.73]** | **+10.7** | **scored (axis)** |

**Six scored criteria, ten frozen guards, two unjudgeable.** Guards emit findings and **no rate**. `emergency_procedure_performed` and `physical_restraints_used` are dropped from the reliability table entirely — κ is undefined there (Pe=1) and Rogan–Gladen degenerates at zero apparent prevalence ([Catching One in Five](https://arxiv.org/pdf/2606.10315)).

**Encounters needed for 40 union-positives** (either rater true), at test215 rates ✅ — publish this so nobody re-derives it from wa402: prescription 55 · has_new_problem 74 · independent_interpretation 84 · parenteral 92 · iv_fluids 156 · historian 168 · life_or_function 263 · surgical_emergency 336 · controlled_substance_iv 400 · chronic_severe 420 · external_qhp 646 · behavioral_health 1,201 · SDOH 2,100 · nebulizer 4,200 · moderate_sedation 8,400 · drug_therapy 8,400 · the last two **infeasible at any n**. Concordant with `judge_reliability`'s independent arithmetic to within rounding. Largest single ED dataset: 402 rows, of which the cross-family-covered ones number 215.

---

## C. The aggregation problem, and its resolution

Measured fact 3 is confirmed in the code and **worse than stated: three of four billed axes are accepted as declared, not two.** `business_logic.py:497` is literally `copa_level = model.copa_level`; `:519` is `risk_level = model.risk_level`; `:500-516` re-derives DATA only, logs `"DATA level mismatch — LLM: %s, computed: %s"` and then uses the computed value (`:515` "Python arithmetic wins for correctness"); `facility_level` is the LLM's declared int plus a `Facility Level = N` regex rescue from free text (`:563-585`) ✅ — a third channel no criterion judge can address.

**And the consequence the brief draws is the wrong one.** The brief says a boolean-only judge cannot reconstruct the level, so tier 4 must depend on tier 1's rule replay for 2 of 3 axes. The measurement that kills that framing ✅:

| ablation through the real `run_two_stage_calculations`, wa402 n=402 | billed outputs changed |
|---|---|
| flip **all 12 RISK booleans** | **0 / 402** |
| flip **all 3 COPA booleans** | **0 / 402** |

**Fifteen of eighteen criteria are pass-through fields.** They are copied into the output dict and consumed by nothing. There is no aggregation to keep deterministic for them, so "criteria → level, deterministically" is not merely imprecise on COPA and RISK — it is undefined. The only criteria wired to arithmetic are the **3 DATA booleans** (+6 / +3 / +6 points) and the **3 DATA count/list pairs**, which is the local instance of the process-advantage argument: score the steps whose flip changes the outcome, not the steps that are merely present ([PAV, Setlur et al.](https://arxiv.org/abs/2410.08146)).

Per axis, and price each:

| axis | criteria → level | resolution | price |
|---|---|---|---|
| **DATA** | **deterministic and exact.** Prod's `_calculate_data_points_from_two_stage` → `calculate_data_level` **is** the rule replay. ⚠ booleans + the 3 counts give 116 distinct vectors, **0/402 in an ambiguous cell** (`judge_reliability`); modal-reconstruction accuracy **1.000** (`process_supervision`) | judge emits 3 booleans + 3 count lists; call the prod function by import | **0.** No tier-1 dependency, no new code beyond the reader |
| **RISK** | **not reconstructible; a one-sided floor only.** ⚠ 12 booleans reach modal accuracy 0.925, +disposition 0.933 (`process_supervision`) — but ⚠ 75.9% of encounters sit in a cell mapping to >1 level and 72.6% still do with disposition added (`judge_reliability`), and ⚠ pair-level disagreement given *every* structured field is 1.4% (`aggregation_code`). ~13 High rungs exist, 6 map to no field at all (`risk_prompt.py:334, 342, 349, 354, 360, 373`); Low has 17 rungs and zero booleans | **floor detector** (`lft`-style: any High boolean ⇒ level ≥ High). ⚠ yield 13/402 below-floor, 96/402 above-floor-unadjudicable | ~40 lines in `ed/autoeval.py`. **This is the only tier-1 dependency in the tier, and it is one axis and one direction** |
| **COPA** | **not reconstructible at any price.** ⚠ 12 cells / 68 encounters have **every one of 26 structured fields identical and a different declared `copa_level`**, and 35.3% of structurally-identical pairs disagree (`aggregation_code`). The rungs turn on an unemitted problem taxonomy ("two or more stable chronic illnesses", `copa_prompt.py:509`; the five stability indicators, `:682-696`) | **abandon the criterion→level readout.** Report COPA at the criterion level, and take the level from the judge's own declared `copa_level` — which is a **blinded second opinion (tier 5), labelled as such**, not a decomposed aggregation | 0 — it is already on disk (below) |
| **FACILITY** | **fully implementable and currently unchecked.** `facility_prompt.py:70-71`: "the highest level where ANY single item is YES is the facility level", and the model emits `facility.criteria_met` per level | two-line replay: `facility_level == max{N : criteria_met[N] ≠ ∅}`. ✅ **348 match / 54 mismatch (13.4%)** (declared 4/replay 3: 18 · 4/5: 16 · 5/4: 16 · 3/2: 3 · 2/3: 1), and **39/402 declare a level whose own list is empty** | tier-1, ~15 lines, zero calls, **highest measured yield of any deterministic detector in the programme.** No cross-family arm exists (§ B) |

**The resolution prod already ships.** The verifier emits the **full** `ProOnlyResponseModel` (52 PRO fields; `ed/verifiers.py:108-115` for the shape) and prod runs the real `run_two_stage_calculations` over it, writing per-axis levels to `result_json.abstention.level_votes` (`ed_abstention_gate_activity.py:55-62`) — which `ed/gate.py:37` ignores. ⚠ `verifier_reuse` replayed the recorded raw text through prod's own parser and reproduced the recorded vote (PRO code **and** all three levels) on **308/308** encounters, zero mismatches, zero model calls. So:

> **Tier 4's aggregation problem is already solved, by having the judge emit the pipeline's own schema rather than a narrower one. The correct contract is "the judge's output schema is `ProOnlyResponseModel`, full stop" — inventing a boolean-only judge schema is a self-inflicted cost that re-creates the tier-1 dependency.**

The honest restatement of the tier's contribution: **criterion booleans buy a prompt address; they do not buy the level.** The level comparison is free and is tier 5's object arriving early.

---

## D. The three calls, re-specced

### D-1 · Call 1 — blind extraction. **This is a data-recovery problem, not a call.**

The sketch's blinded cross-family extractor exists in prod, is paid for, is parsed, and is on disk. Inventory ✅ (my count, both recovery paths):

| dataset | GPT-5.4 PRO vectors | Gemini-2.5-pro PRO vectors | gt axis labels (copa/data/risk) |
|---|---|---|---|
| `qh-0731-test-set-215` | **215 / 215** | 0 | **44 / 43 / 44** |
| `qh-0731-dev-set-93` | **93 / 93** | **85 / 93** | **19 / 19 / 19** |
| `washington-402` | 2 (run-dir only, `results/smoke2`) | 0 | 71 / 70 / 71 ⚠ |
| feedback-290 · general-165 · stability-135 · gen-stab-223 | 0 | 0 | 61/61/61 · 0 · 0 · 0 ⚠ |

**308 distinct encounters** with the full 18-boolean cross-family vector, durable in the GCS-synced dataset cache; 85 of them three-family. Two washington-402 encounters exist only in a run dir that is backed up nowhere.

**Lane hygiene — mandatory, and the brief's grounding got it wrong (correction 3).** `prompt_fp` is per **call**, not per node: baseline `pro = 7e9ba993bb26`, `data = b5f822868fa4`, `risk = 046d886021` ✅ (from `fulldag-test215-fixed/manifest.json:prompt_sha1`). Use these lanes and nothing else:

| role | dataset | model | sigs (seed) |
|---|---|---|---|
| judge, 3 lanes | test215 | `gpt-5.4` | `64ea2b5d85ea` (1002) · `f36fc0fbec7b` (2002) · `6b60eb1fd535` (3002) |
| generator, 4 lanes | test215 | `claude-sonnet-4-6` | `012579b7d81f` (1004) · `5c765904e41d` (2004) · `7130704bb005` (3004) · `e8ecefd17623` (4) |
| third family, 3 lanes | dev93 | `gemini-2.5-pro` | `51f0c331f9a1` · `aa305964dcc1` · `f43467960956` (T=0) |

Three traps in the cache, all ✅: **88 gpt-5.4 sig dirs contain zero PRO vectors** — they are the `reasoning.effort: low` questionnaire lanes (PRO runs `high`, `ed_verifier_scoring_activity.py:252-256`), so a naive scan silently halves coverage. **Entries exceed encounters within a lane** (test215 baseline seed 1002 = 277 entries for 215 encounters) because the verifier's PRO request embeds *its own* questionnaire draw, so a re-run at the same seed writes a new content-addressed entry — extra judge draws per encounter, free, and the reason § E's within-arm term is estimable at all. **The other ~40 prompt_fps are prompt-tuning variants**; pooling them mixes prompt variants into the "cross-family disagreement".

| what is shown | what must NOT be shown | family | schema | bias exposure |
|---|---|---|---|---|
| the post-`rcm-format-notes` `note_text` from `rcm-split-notes` (`d7a3f1e2`) — ✅ **byte-identical to what QH's pass 2 sees**, both nodes take `note_text` from the same node in `dag/template.json`; plus the verifier's **own** DATA/RISK questionnaire answers; plus the shared `PRO_SYSTEM_PROMPT` criterion text | QH's booleans, levels, rationale, thinking, code, and QH's questionnaire answers — all verified absent (correction 2) | GPT-5.4 (Azure Responses, `reasoning.effort: high`); Gemini-2.5-pro (T=0, `thinking_budget: 24576`) | `ProOnlyResponseModel` — already exactly this | **prompt-shared, not prompt-independent.** `ed/profile.py:69-75` patches `PRO/DATA/RISK_SYSTEM_PROMPT` in **both** the ED module and the verifier module by design, so the judge inherits our criterion definitions. It can detect model-execution error; it **structurally cannot detect prompt-specification error** |

**Do NOT build against `ed/verifiers.py`.** It is dead code (zero importers ✅) and `make_row_data` sets `original_ai_input_content` from the **raw** `consolidated_notes`, while the scorer reads the formatted note (+161 lines median; raw note a substring in 1/402 — `grounding/data-feasibility.md` § 0). Every criterion disagreement measured through it would be confounded by an input difference, invisibly. Go through `result_json.llm_raw['ed-verifier-scoring']` or the dataset cache, and **assert the judge's note bytes equal the generator's** before emitting a finding.

**The prompt-shared limitation is what forces two arms, not one.** An "as-written" arm (our criterion text, cross-family model — measures *application*) and a "from-source" arm (the ACEP/CMS clause text with no QH phrasing — measures whether our phrasing is the defect). Their disagreement is the only route to a prompt-text defect and the only defense against inheriting the generator's misreading — the correlated-blindness mode the [HealthBench critique](https://pmc.ncbi.nlm.nih.gov/articles/PMC12547120/) names. The as-written arm is free (on disk); the from-source arm is new and is V3.

**The one purchase worth making.** washington-402 has the most axis labels (71/70/71 ⚠) and no verifier cache. The cheap route is calling the prod `_gpt54_verifier(row_data)` directly with `note_text` from run1's cached formatted note: ⚠ **1,206 GPT-5.4 calls, ~24.8M in / 3.3M out** (`verifier_reuse`), which roughly doubles the labelled calibration base. Do **not** use the full-DAG route: ⚠ wa402's Claude cache is stale (signatures match, `request_sha` does not) and both manifests are `dirty: true`, so it re-pays ~21M Claude input tokens for no added signal.

### D-2 · Call 2 — entailment. **Feasible on the 15 criteria that carry no signal, infeasible on the 3 that do.**

Per-criterion evidence fields, from `ed_coding/data_model.py` ✅: DATA has three (`:345-347` `data_historian_evidence`, `data_interpretation_evidence`, `data_qhp_evidence`); RISK has a 12-key dict (`:395` `risk_evidence`); facility has per-criterion evidence **and** citations (`:417-420`); **COPA has none** — only `copa_citations` (`:328`), `copa_highest_qualifying_problem` and `copa_rationale`, i.e. axis-level objects at 5.29 citations/encounter ✅.

> **The three criteria with the largest θ̂ (all COPA: 6.63, 5.90, 4.69pp) are exactly the three with no per-criterion span to entail.** Call 2 as sketched covers `controlled_substance_iv` (θ̂ = 0.00) and cannot cover `life_or_function_threatening`. This is the sharpest structural constraint in the tier and it is not fixable by prompting the judge.

| shown | not shown | family | schema | bias |
|---|---|---|---|---|
| the criterion's clause text; the **resolved** span; the assembled input | our boolean, our level, our rationale, the blind extractor's answer | not the generator's family; prefer a cheap specialist — MiniCheck-FT5 reaches 74.7% balanced accuracy at **400× less cost** ($0.24 vs $107 on 13k) ([LLM-AggreFact](https://aclanthology.org/2024.emnlp-main.499/)) | `{criterion, verdict ∈ {entailed, not-entailed, indeterminate}, confidence, decisive_clause}` | **scoring-bias / reference-answer anchoring** ([taxonomy](https://arxiv.org/html/2506.22316v1)). Showing the judge our boolean is an unmeasured intervention on our task; the nearest measurement is that adding answer information flips up to **85%** of a judge's decisions ([Kranti & Vajjala](https://arxiv.org/abs/2607.12885)) — and note the direction: that paper finds reference-**free** is the too-generous condition, so giving the judge our *criterion text* is right and giving it our *boolean* is a different, unmeasured thing |

Rules. (1) **Never pool call 1 and call 2** — separate detector ids, separate `calibration.json` entries. (2) **Run the free anchoring experiment first**: the 308 blind vectors exist, so one call-2 pass over the same encounters measures *our* anchoring size directly (share of criteria where the judge's blind boolean differs from its shown-our-answer boolean, split by the direction of our claim). Publish that number before either detector is trusted. (3) **Send only tier-1-exact spans.** ⚠ The resolver drops 35.0% of the model's 6,059 spans and truncates 3.4% to an 80-char prefix (tier-3 § D-4), and ✅ `interpretation_evidence` is a whitespace-normalized substring of the note in **0/208** — it is model-authored prose that *embeds* fragments. Budget an element→span step or the entailment judge is scoring a paraphrase. (4) **Do not decompose below the criterion.** Atomic-fact splitting is measured as cost-negative — 2–4× inference, no consistent gain ([MiniCheck](https://aclanthology.org/2024.emnlp-main.499/)) — and over-decomposition is a named error class ([Decomposition Dilemmas](https://arxiv.org/html/2411.02400v1)). Our decomposition is fixed and human-authored, which immunizes us against generated-decomposition drift; say so as an advantage.

### D-3 · Call 3 — conflict enumeration. **Two of the three conflict types are not calls.**

| conflict type | what it actually is | expected yield |
|---|---|---|
| (i) our cited span vs the input | **tier 1's citation groundedness.** Not a call. Shares its object with call 2 — one dependency cluster (§ E) | ⚠ 29.8% of 6,059 spans ungrounded after whitespace normalization, 1,192 with no clause found anywhere (`grounding/data-feasibility.md` § 3) — and that figure is measured against a *reconstruction*, not the cache request bytes (UNMEASURED, tier-3 § G) |
| (ii) our criterion vs the blind extractor's | a **deterministic function of call 1**. Not a call, and **not an independent vote** in any label model | the θ̂ table |
| (iii) criterion vs criterion inside our own output | a **deterministic rule set** in `ed/autoeval.py`. Enumerated below | mostly near-zero — see the numbers, and do not build on the zeros |

Type (iii), each with a stated yield rather than an assertion:

| internal-conflict rule | measured yield | verdict |
|---|---|---|
| criterion true with empty evidence string | ✅ **0/589** wa402; and **0** on test215/dev93 for the four RISK criteria with the most firings (157/0, 85/0, 52/0, 23/0) | regression guard, no mining value. Reproduced on a second corpus |
| DATA declared vs recomputed | ⚠ 402/402 identical wa402, 709/709 across three datasets | regression guard. **Prod already overwrites it** |
| `prescription_drug_management: true` with RISK ∈ {Low, Minimal} | ⚠ 5/402, **all five legitimate** — they cite the prompt's own "Rule 2A Critical Exception" carve-out (`risk_prompt.py:553-560`) | **not a defect class.** Would have been 5/5 false positives |
| declared level with **no** representable supporting criterion | ⚠ RISK 90/402 (Low/Minimal have no booleans at all) · COPA-High 32/89 · facility 39/402 | **tier-1 findings, and the decomposition-recall denominator** (§ E) |
| facility declared level ≠ max non-empty `criteria_met` | ✅ **54/402 (13.4%)** | build this first |
| COPA/RISK one-sided boolean floor violation | ⚠ 14/402 · 13/402 | build; precision UNMEASURED (*measurement: adjudicate the 27 rows, or join to the labelled slice*) |
| `risk_level == "UNDETERMINED"` sentinel | ⚠ **unreachable** — the field validator raises first (`data_model.py:448-471`); only `tests/test_business_logic.py:626` reaches it | **delete from [[auto eval plan]] tier-1 item 6** |

**The missing fourth conflict type, and it is the one the literature says matters most.** Give blind extraction an explicit free-text slot: *"a qualifying element is documented that is not on this list."* Its firing rate is the 0-claim-rate analogue and must be reported beside precision as **decomposition recall** ([Decomposition Dilemmas](https://arxiv.org/html/2411.02400v1); [DeCE](https://arxiv.org/html/2509.16093)). Without it, tier 4 is structurally silent on the entire RISK Low/Minimal distribution and that silence will be read as agreement.

---

## E. The error model

### E-1 · The statistic. Excess over noise, per criterion, or nothing.

Reuse tier 3's estimator verbatim, including its correction — the within-arm term is over the **K(K−1) ordered distinct pairs**, not K², or the estimator manufactures violations:

```
per encounter e, criterion k:
  d_k(e)  = mean over the K_QH × K_J cross-arm pairs of 1(b_QH ≠ b_J)
  w^A_k(e)= mean over K_A(K_A−1) ordered distinct within-QH pairs
  w^B_k(e)= same, within-judge
  c_k(e)  = d_k(e) − ½(w^A_k(e) + w^B_k(e))            ← the per-encounter signal
θ̂_k = mean over encounters of c_k(e);  95% CI = percentile bootstrap resampling ENCOUNTERS
```

Same units caveat as tier 3: **θ̂ is not a violation rate**, it is half a squared L2 distance between the two raters' per-encounter label distributions. Publish θ̂, the affected-encounter fraction, and the signed off-diagonal separately. Where only one draw exists on a side (a single run dir), substitute the **population** noise floor from the § B table as the offset and mark the row as offset-imputed — never omit the offset.

**Refuse to emit a finding on any criterion whose θ̂ CI contains 0.** On the measured table that removes 6 criteria outright (`external_qhp`, `parenteral`, `SDOH`, `controlled_substance_iv`, `moderate_sedation`, and the two p=0) and demotes four more to ≤1pp.

### E-2 · The agreement statistic. AC1, never κ — demonstrated on our own data.

κ collapses on our surface exactly as the paradox predicts ✅ (test215, n=210): **undefined** on 2 criteria (Pe=1, p=0 in both raters); **0.000** on `drug_therapy_intensive_monitoring` at Po=0.995; **0.242** on `has_chronic_severe_exacerbation` where AC1 = 0.910 at Po=0.919; **0.318** on `life_or_function_threatening` where AC1 = 0.857 at Po=0.881. Gwet's AC1 is defined and tight on all 18 (0.411–1.000). A κ dashboard would report "poor reliability" precisely where the raters are near-perfectly aligned, inverting the priority list. Report **AC1 primary, with raw Po, BOTH marginal prevalences, the signed 2×2, and `n_positive`**; report κ only where its bootstrap CI half-width < 0.25; never apply Landis–Koch bands to AC1 ([Reichenheim comparison](https://www.sciencedirect.com/science/article/pii/S2215016123002108); [Wongpakaran](https://pmc.ncbi.nlm.nih.gov/articles/PMC3643869/)). For judge *quality* against human labels, use **balanced accuracy = macro-recall = (Youden's J + 1)/2** plus AUPRC and the confusion matrix — accuracy/F1/κ are prevalence-dependent and every symmetric statistic is FP↔FN invariant, which a one-sided over-coding detector must not be ([Balanced Accuracy](https://arxiv.org/abs/2512.08121)). **No macro-average across criteria with different base rates.**

### E-3 · Direction is the headline, and it is free.

✅ test215, n=210: **164** criterion disagreements, mean **0.781** per encounter, **117 (71.3%)** QH-true/judge-false. Axis level: QH codes strictly higher on **13.3% / 10.5% / 12.4%** (copa/data/risk) vs judge-higher on **2.4% / 4.3% / 0.5%** — a 2.4× to 25× asymmetry, |Δ| ≥ 2 rungs on 0.0 / 5.2 / 1.0%. dev93, n=91: 68 disagreements, 61.8% QH-true, axis 14.3/8.8/7.7 vs 3.3/2.2/2.2. Four criteria carry almost all of it, and after noise correction three survive strongly (`life_or_function` +11.5pp, `chronic_severe` +9.0, `independent_interpretation` +6.5) while `has_new_problem` is **directionally symmetric (+0.8pp)** despite being the largest raw contributor — i.e. its disagreement is two-sided noise on the least-consensual criterion, not one-sided over-credit. A symmetric agreement coefficient discards the half of the signal that matters; emit `n10` and `n01` per criterion always.

### E-4 · Error propagation is FWER, not decay — and the direction is the compliance direction.

COPA, RISK and the facility checklist are **max ("ANY of") rules**, so one false-positive criterion promotes the rung. At per-criterion FP rate *e* over the 12 RISK booleans, the share of encounters with ≥1 spurious promotion is 1−(1−e)¹² = **11.4% at e=1%, 46% at e=5%**; perfect 18-vector reproduction is (1−e)¹⁸ = 70/40/15% at e = 2/5/10% ⚠. The false positives land entirely inside the over-coding direction the product exists to police, so the detector's noise looks exactly like its signal. Errors do not compound uniformly because only a sparse key subset determines the outcome ([Beyond Exponential Decay](https://arxiv.org/html/2505.24187v1)) — and § C's ablation is the extreme local instance: **15 of 18 booleans have advantage exactly zero.**

Mitigation is structural, not a better prompt: **AND-gate.** A judged criterion may fire a rung-change finding only when (a) a deterministic signal co-fires — tier 1's verbatim span match, or the facility/floor replay — **and** (b) the judge did not abstain **and** (c) θ̂_k's CI excludes 0. Publish the expected false-promotion count at the measured FP rate as part of the operating point. Score at the rung, never at the vector.

### E-5 · Abstention must live outside the pipeline schema.

`data_model.py:38-51` `_coerce_bool` maps `None` / `""` / `"null"` / unrecognized → **False for all 18 booleans**, so a judge's "cannot tell from this documentation" becomes a confident False and every abstention is recorded as a disagreement with a criterion we set true. ⚠ At least one DATA boolean is literally `None` in wa402 run1, which is why the brief counts 9 raw DATA vectors and `process_supervision` counts 8 coerced. Carry the verdict as a **three-state field** (`met` / `not-met` / `indeterminate`) plus a confidence, outside the pipeline schema, and project to bool only at the aggregation boundary — recording the projection. Note also ⚠ that `llm_raw['ed-pro-scoring'].pro.<model>.output` is `result.model_dump_json()`, i.e. **post-coercion** (`ed_coding_v1_activities.py:406`), so on the QH side absent and false are already indistinguishable and no "the model didn't emit this criterion" detector is buildable from that artifact.

### E-6 · The three calls are not three detectors, and tier 4 is not independent of tier 2.

Declare the dependency graph in code:

```
call 1 (blind vectors)  ──derived──►  conflict type (ii)      # NOT a vote
call 2 (span entailment) ──cluster──  tier-1 groundedness     # same object
call 1 (level_votes)     ══SAME══     tier-2 ED dissent signal
```

The last line is the one nobody has written down: **on ED, tier 2's dissent signal and tier 4's blind extraction are the same measurement at two resolutions.** `abstention.level_votes` (tier 2) and the criterion vectors (tier 4) come from the *same three verifier calls*. They are not two independent detectors and must never be summed as such. [[auto eval plan]] tier 2's "cheap extension — extend the verifier comparison from PRO-only to COPA/DATA/RISK" is a one-line field read that is **already done** by prod and is tier 4's axis row.

Feeding these into a Dawid–Skene label model as conditionally-independent votes double-counts the shared signal exactly where they co-fire ([weak supervision](https://ai.stanford.edu/blog/weak-supervision/); [structure learning](https://arxiv.org/html/2402.01867v1)). And do not promise a label-model lift: a 9-judge panel yields only **2.18 effective independent votes** (Kish; 24.2% independence ratio, mean pairwise error correlation 0.391, a 22.0pp Condorcet gap), DS closes ≤11% of that gap even with oracle labels and **lost to plain majority vote on one dataset**, cross-family diversity is worth only ~0.05 of decorrelation, and one-judge-per-family made n_eff *worse* (1.93) ([Nine Judges, Two Effective Votes](https://arxiv.org/html/2605.29800v1)). **This partly contradicts the verification-asymmetry case for cross-family judging, and the resolution is scope:** cross-family is right for the *single* blind extractor (where the measured gain is per-criterion and one-directional) and wrong as a *bias fix via panel voting*. Cap the panel at 2–3, report Kish n_eff and mean pairwise error correlation as first-class outputs, and **never gate on unanimity** — ⚠ on dev93 COPA, cells where all three families agreed on every criterion carried a GT error rate of 0.571 [0.250, 0.842] against a 0.316 base (n=7; `judge_reliability`). n=7 forbids the claim "unanimity is bad"; it is enough to forbid gating on it.

### E-7 · The per-(encounter, axis) suspicion score

```
S(e, axis) = Σ_{k ∈ scored(axis)}  θ̂_k · c_k(e) · 1[co-fire] · 1[¬indeterminate]     # criterion term
A(e, axis) = |rung(qh) − rung(judge)| − noise_offset(axis)                            # axis term
```

Weighting the criterion term by the **population** θ̂_k automatically zeroes the ten guard criteria without a second threshold. Report `S` and `A` as **two ranked columns and a Borda combination** — do **not** fit a mixing coefficient, because there are no labels to fit it on (§ G). Signed variants of both are reported separately for the over-code lane. Every row carries: axis, criterion, `n_positive`, θ̂_k with CI, the noise offset and whether it was imputed, the judge model + decode + prompt_fp, the note-byte-equality assertion, and the disposition prior from `diagnosis.md`'s closed set. **A finding with no pointer to an intermediate is not emitted** ([[auto eval plan]] contract).

**Route low-consensus criteria out of the prompt-fix lane.** `copa.has_new_problem_uncertain_prognosis` is the modal COPA criterion, ⚠ three-way Fleiss 0.325 with 49.4% unanimity and the lowest pairwise AC1 of any criterion in any pair (0.203 GPT vs Gemini), ✅ the highest self-flip of any criterion in any rater (QH **18.9%**), and it sits on the axis with the highest GT error rate (0.455). Prompt work aimed at it optimizes against a target no rater can hit. It belongs in `label-or-standard` and tier 5's `ambiguous`, and tier-4 performance must be reported **separately on high- and low-consensus criteria** ([perspectivist modeling](https://arxiv.org/html/2601.09065)).

---

## F. What it costs and what it yields

| element | calls / encounter | corpus available today | expected yield |
|---|---|---|---|
| call 1 — read GPT-5.4 criterion vectors + `level_votes` | **0** | 308 encounters (215 + 93), 3 judge lanes on test215 | **measured: the θ̂ table.** 6 scored criteria with CI excluding 0 and θ̂ 3.0–6.6pp; 3 axis rows at 6.5–9.5pp |
| call 1 — third family (Gemini) | **0** | 85 encounters, 3 lanes, dev93 | Gemini is the **noisiest** rater ✅ (copa `has_new_problem` self-flip **27.5%**, `behavioral_health` **18.0%**, LEVEL.risk **19.2%** at T=0). Treat as a diversity probe, not a vote |
| call 1 — extend to washington-402 | **3** (verifier-only) = ⚠ 1,206 calls, ~24.8M in | — | roughly doubles the labelled calibration base (63 → ~134 rows/axis, unpooled) |
| call 2 — entailment, DATA + RISK criteria with evidence | **1–2** (batch by encounter) | 15 of 18 criteria; **not COPA** | **UNMEASURED.** *Measurement: the free anchoring pass — blind boolean vs shown-our-answer boolean on the same 308 encounters — then per-criterion precision against ~40 coder-adjudicated positives per scored criterion* |
| call 2 — COPA | infeasible per-criterion | — | no per-criterion span exists ✅ |
| call 3 — conflict enumeration | **0** (all deterministic) | all run dirs | facility replay ✅ 54/402 · floor detectors ⚠ 14 + 13/402 · declared-level-with-no-supporting-criterion ⚠ 90 + 32 + 39 · **zero-yield guards: empty-evidence 0/589 ✅, DATA recompute 402/402 ⚠, `UNDETERMINED` unreachable ⚠, prescription-with-Low 5/5 false positives ⚠** |
| from-source arm (ACEP/CMS clause text, no QH phrasing) | 1 | — | **UNMEASURED.** *Measurement: as-written vs from-source disagreement rate on the 6 scored criteria, n=200; the only route to a prompt-text defect* |

**Verifier gain, not aggregate agreement, is the reportable quality metric**: gain = Precision(QH, verifier) − Accuracy(QH), which predicts rejection-sampling improvement better than raw verifier accuracy ([When Does Verification Pay Off?](https://arxiv.org/html/2512.02304v2)). Computable today per criterion on the 44 + 19 labelled rows — and at that n it will not resolve (§ G).

**Detector precision against the labels that exist — do not quote an operating point from this** ✅:

| axis | dataset | n labelled | base err | `level_votes` disagree (free) | any criterion disagrees | scored-criteria-only |
|---|---|---|---|---|---|---|
| copa | test215 | 44 | 0.455 | 9 fires, prec 0.667 [0.354, 0.879], lift 1.47 | 15 fires, prec 0.667 [0.417, 0.848], lift 1.47 | identical to previous column |
| copa | dev93 | 19 | 0.316 | 5 fires, prec 0.400, lift 1.27 | 6 fires, prec **0.000** [0.000, 0.390], lift **0.00** | 0.000 |
| data | test215 | 42 | 0.214 | 7 fires, prec 0.143, lift 0.67 | 9 fires, prec 0.222, lift 1.04 | 0.222 |
| risk | test215 | 44 | 0.227 | 10 fires, prec 0.400, lift 1.76 | 5 fires, prec 0.600, lift 2.64 | 3 fires, prec 0.667, lift 2.93 |
| risk | dev93 | 19 | 0.211 | 3 fires, prec 0.667, lift 3.17 | 3 fires, prec 0.333, lift 1.58 | 1 fire, prec 1.000 |

The same COPA detector reads lift 1.47 on one dataset and 0.00 on the other, and the no-pooling rule forbids averaging them. **The free axis-level detector is not distinguishably worse at ranking than the expensive criterion detector**, and the θ̂-restriction to scored criteria changes nothing except on RISK where it trims 5 fires to 3. Independently reproduced from `judge_reliability`'s numbers ✅. Honest statement: **lift is somewhere in 0–3 and we cannot resolve it. Tier 4's contribution is localization; build the free reader first and treat criterion decomposition as an RCA instrument until the label budget exists to separate the two.**

---

## G. Calibration, and the V1 cut line

### The GT reality, corrected

[[auto eval plan]] says "1,609 labelled ED rows are enough to calibrate every tier below". **That is true for a PRO-code detector and false by an order of magnitude for tier 4.** ⚠ Across all seven ED datasets: 1,448 gt rows, 1,441 with a PRO code, but only **195 COPA / 191 DATA / 195 RISK** axis-level labels (`judge_reliability`), largest single-dataset slice 71 (wa402). ✅ My count on the two datasets that have judge vectors: test215 **44 / 43 / 44**, dev93 **19 / 19 / 19** — so the intersection of "has a cross-family criterion vector" and "has a human axis label" is **63 rows per axis, across two datasets that may not be pooled**. And there are **zero human criterion-level labels anywhere in the repo**: nobody has ever adjudicated "was `prescription_drug_management` true for this encounter".

**MDE, stated before any number is quoted.** Precision estimation needs ⚠ 43 / 97 / 385 *firing* rows for a ±0.15 / ±0.10 / ±0.05 half-width at p=0.5. At the measured 12–36% firing rate that is **260–600 labelled encounters per axis on one dataset**, against a current maximum of 71. Tier 4 therefore ships as a **ranking instrument with an explicitly unmeasured operating point**, and **label acquisition — not more judge calls — is the gating deliverable.**

**Tier the human-label plan; do not promise per-criterion calibration for all 18.** Individually calibrate the 6 criteria reachable at n ≤ 200 encounters (§ B table: prescription 55, has_new_problem 74, independent_interpretation 84, parenteral 92, iv_fluids 156, historian 168); pool the rare RISK criteria into one shared-operating-point stratum; drop the two at p=0. Sample rare positives off the judge's own flag by **stratified importance sampling** (documented ~10× annotation efficiency, [ECCV 2024](https://arxiv.org/html/2406.07320v1)) rather than at random. Pilot at ~10 labels per class; ~200 calibration labels for a 95% CI shorter than 0.1; asymmetric allocation m̃₀ ≈ (1/p̃ − 1)·√κ·m̃₁ with κ = (1−q̂₀)/(1−q̂₁) for rare positives ([How to Correctly Report LLM-as-a-Judge Evaluations](https://arxiv.org/html/2511.21140v4)). The reference point that stops anyone promising more: HealthBench's grader meta-evaluation used 60,896 physician grades over 34 criteria — **1,791 grades per criterion**.

**Population numbers.** Rogan–Gladen θ̂ = (p̂ + q̂₀ − 1)/(q̂₀ + q̂₁ − 1) is the defensible estimator because it survives calibration/test distribution shift where PPI does not — with two hard preconditions, not footnotes: it **collapses at zero apparent prevalence** (our two p=0 criteria) and can have **higher MSE than the naive estimate** if applied blindly. For PPI: use **cross-fit**, report λ\* and the estimated pseudo/gold correlation with every interval, and declare per-criterion PPI **unavailable** below ~20 labelled positives — single-sample PPI++ without splitting undercovers (87% at nominal 95%, n=20, ρ=0.81) and improvement requires ρ > (n−2)^(−1/2) ([No Free Lunch](https://arxiv.org/html/2505.20178); [PPI++](https://arxiv.org/html/2311.01453v2)). At axis level n=63 the threshold is ρ > 0.128, which the detector clears; per criterion it does not. Express the output as an operating point with a stated abstention cost via conformal risk control ([SCOPE](https://arxiv.org/html/2602.13110v2)), and set expectations with the shape of that trade: a state-of-the-art conformal filter needed **>80% abstention** to hold a 5% error rate on a balanced task ([Conformal Risk Control](https://arxiv.org/pdf/2606.29054)). Keep the existing invariant — the bootstrap resamples **encounters**, and a resampled encounter brings all its seeds and all its judge draws (`scripts/metrics_selftest.py`).

### The cut line

**V1 — build now. Zero model calls, and it is most of the tier.**

| step | what | calls | gate |
|---|---|---|---|
| **0** | `ed/autoeval_criteria.py`: read `llm_raw['ed-verifier-scoring'].pro.<model>.output` + `llm_raw['ed-pro-scoring'].pro.qh.output` + `abstention.level_votes`; **import prod's parser** (`_parse_pro_only_response`, `_codes_from_pro`, `ProOnlyResponseModel`) rather than regexing; handle both output shapes (**GPT-5.4 free-text is nested, Vertex-schema Gemini is flat** — getting this wrong reports Gemini as 0 encounters when it is 85 ✅); assert note-byte equality; three-state verdicts | **0** | ships the per-criterion table on 308 encounters on day one |
| **1** | θ̂ with the K(K−1) within-arm term, AC1 + Po + both marginals + signed 2×2 + `n_positive`, encounter bootstrap in `core/mr_stats.py` (already tier 3's home); lane filter to a single `(prompt_fp, decode, seed)` set, defaulting to the § D-1 baseline sigs | **0** | **stop if the selftest fails**: replicate each arm's lane set 3× → θ̄ unchanged, CI not narrower |
| **2** | the deterministic conflict set in `ed/autoeval.py`: facility replay (54/402), COPA/RISK floors, declared-level-with-no-supporting-criterion, plus the four zero-yield guards wired as regression guards with no rate | **0** | the facility replay is the highest-yield detector in the programme and nothing in prod checks it |
| **3** | `calibration.json` entries with `n_positive`, θ̂ CIs, the noise offsets, and the explicit statement that the operating point is unmeasured; report split into high- and low-consensus criteria | **0** | a findings file whose detectors have no calibration entry is a draft ([[auto eval plan]] contract) |

**V2 — needs a purchase or a coder.** Extend cross-family vectors to washington-402 (⚠ 1,206 verifier-only calls; do **not** use the full-DAG route) · the free **anchoring** experiment (call 2 on the 308 already-blind encounters, one call/encounter) · call 2 proper on the 15 criteria with evidence fields, tier-1-exact spans only · the human criterion-label pass on the 6 scored criteria with stratified importance sampling · the "qualifying element not on this list" slot and its decomposition-recall rate · Gemini as a diversity probe with n_eff reported.

**V3 — needs a prod change or is near-unexercisable.** The **from-source** judge arm (ACEP/CMS clause text) · facility cross-family (un-hide the 7 `facility_*` fields in `ProOnlyResponseModel`, or add a verifier FAC call — `.worktrees/` branch) · widening `_codes_from_pro` in both the harness copy and `ed_verifier_scoring_activity.py:117-146` plus a per-axis/per-criterion `ed/gate.py` (a few lines, and **the eval needs none of it**) · **clinic entirely**: `clinic_verifier_scoring_activity.py` returns `{em_code, amb_code, error}` (`:65-69`) with **zero** `raw_record`/`llm_repro`/`verifier_raw` occurrences ✅, and `clinic-verifier-scoring` is in neither `llm_tools` nor `replay_tools` (`clinic/profile.py:157-158`) so its calls are never cached — and adding it to `llm_tools` naively **renumbers the cache seed slots and orphans every cached `clinic-extract` entry** (`core/dag_runner.py:128-145` documents exactly this), so it must use the append-after-max lane.

**Why the line falls there.** V1 has no unmeasured dependency at all: the criterion vectors, both noise floors, and the per-criterion θ̂ with CIs are already measured (this document's tables), and every V1 detector is deterministic or a field read. Everything that needs a coder's adjudication, a new prompt, or a prod change is V2/V3 by construction. V1's own most valuable output is probably not a finding but a re-scoping: **six criteria carry the entire cross-family signal, fifteen of eighteen booleans cannot move the bill, and the axis-level comparison that costs one dict lookup ranks about as well as the criterion decomposition.**

### Two contract amendments, inherited and extended

Extend tier 3's prohibition **verbatim**: a tier-4 criterion metric may never appear in a prompt, a `--patches` rationale, or a candidate-selection criterion. The mechanism is concrete here: 71.3% of disagreements are QH-true/judge-false ✅, so the cheapest way to quiet the detector is to make the generator more conservative on four criteria — a coding-accuracy change that suppresses the compliance signal the detector exists to raise. Criterion-level scores are directly optimizable and ⚠ ~40% of checklist items are measured as alignment-*negative* ([EMNLP 2025](https://aclanthology.org/2025.emnlp-main.538/)). Gating detectors frozen and version-pinned separately from iteration detectors; any prompt change motivated by tier 4 validated on human-labelled regression data first.

And extend the `calibration.json` key from tier 3's **(product, node, model, detector, detector version)** to **(product, node, model, detector, detector version, judge model, judge decode, judge prompt_fp)**. The verifier's `reasoning.effort: high` and the `7e9ba993bb26` PRO prompt are both part of the operating point, and the per-family prevalence spread (⚠ up to 8× on `copa.life_or_function_threatening`) proves an operating point will not transfer between judges.

**PHI.** The recovered criterion vectors are structured booleans and are not PHI; the `evidence` strings, `citations[].cited_text` and the `thinking` traces **are** — verbatim note substrings, and `enc_*.json` carries `result_json.mrn`. `findings.json` is local-only, never committed, never synced. Encounter ids are fine. The rendered report is population-level. Nothing in this tier writes to GCS.

---

## H. Honest limits

- **The judge is model-blind but prompt-shared, so it cannot see a prompt-specification defect.** It imports the same `PRO/DATA/RISK_SYSTEM_PROMPT` objects, and `ed/profile.py:69-75` propagates `--patches` to it deliberately. A criterion our prompt defines wrongly is defined wrongly for all three families — the correlated-blindness mode, and the reason the from-source arm is the only route to a prompt-text finding. Maximum construct validity, minimum error independence: paraphrasing the criterion instead would mean we are no longer judging *our* criterion, and a disagreement would stop being a prompt address.
- **Cross-family disagreement is not an error rate and has no direction of truth without a human anchor.** Each family carries its own per-criterion threshold — ⚠ up to 8× prevalence spread on the compliance-relevant COPA criteria, and GPT-5.4 vs Gemini (neither is us) disagree 19–0 in one direction on `life_or_function_threatening` over 85 encounters. "Cross-family" swaps one unknown threshold for another on exactly the criteria where it matters. Compounding it: the entailment sub-call tops out near 75% balanced accuracy, and human CPT coders agree at κ 0.458.
- **Fifteen of eighteen criteria are causally disconnected from the bill** ✅, and the three that are not are DATA's — the axis prod already recomputes and the one with the lowest cross-family axis asymmetry. So the criteria whose flip changes the output are the criteria least worth judging, and the criteria carrying the signal are the ones whose relationship to the bill runs through a level the model simply declares. Tier 4 localizes; it does not audit the arithmetic, because for those criteria there is none.
- **The tier is structurally precision-only and blind on the majority of the RISK distribution.** Decompose-then-verify cannot see an omission. RISK Low and Minimal have no booleans; ⚠ 90/402 encounters carry a RISK rung with no structured boolean, 32/89 COPA=High have neither High flag, 39/402 declare a facility level with an empty criteria list. Without the free-text "element not on this list" slot, silence on those rows reads as agreement — and the production analogue measured ~18% recall with half of confirmed defects in dimensions the rubric could not name.
- **The corpus with the signal and the corpus with the labels are nearly disjoint, and the operating point is unmeasured.** 308 encounters have cross-family vectors; 63 rows per axis have both a vector and a human label; zero criterion-level human labels exist anywhere. The same detector reads lift 1.47 and 0.00 on the two datasets, and pooling them is forbidden. Ship the ranking, publish the θ̂ table with its CIs, and refuse to publish a precision figure until the label pass lands.
