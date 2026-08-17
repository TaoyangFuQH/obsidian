---
updated: 2026-08-13
tags: [project, coding-pod, eval, auto-eval, roadmap]
---
# LLM auto-eval — roadmap

Sequenced by **dependency**, not by calendar: staffing is unknown, so cost is in engineer-days
and model calls. Phases 0–2 need no model spend at all. Every phase has a **gate** — a condition
that, if it fails, stops the phase rather than degrading it silently.

The layer above this is [[auto eval proposal]] (goals, workstreams, concerns); the literature is
[[LLM as a judge SOTA]]; measured defect classes are [[lane A findings]]; design reasoning is
[[LLM as judge]]. Still in the repo under `coding-ai-harness/features/llm-auto-eval/`:
[[auto eval plan]] (the six tiers, the rationale) · [[tier 3 metamorphic]] (tier 3, finished, with its own
V1/V2/V3 line) · [[tier 4 criterion judging]] · `grounding/` (four research + code dossiers, one
measured feasibility scan).

> **⚠ Read against [[LLM as a judge SOTA]] before acting on Phase 4.** Two findings there
> change it: ordinal 3–5-level judging is only 38–58% exact (so a *level* judge cannot
> adjudicate the one-rung disagreements that matter), and same-model ensembles add almost
> nothing for strong judges (κ +0.051), which reframes clinic's three Opus votes as a
> stability instrument rather than a correctness one.

## Provenance markers

Asked for, so it is marked throughout:

| marker | meaning |
|---|---|
| **[you]** | from the original four-bullet sketch |
| **[claude]** | added suggestion |
| **[res]** | forced by the research (named prior art, or a documented failure mode) |
| **[meas]** | forced or killed by a measurement over real run dirs |
| **[crit]** | forced by an adversarial critique pass |

## The thesis, and the line

Auto-eval **ranks a review queue, finds defect classes, and gates**. It is not an accuracy
measurement — a judge-derived accuracy is biased by the judge's own error profile, and in the
reference-free setting the bias direction is known (judges over-credit the answer shown to them).
Headline accuracy comes from human labels, or from PPI. **[res]**

Two independent lines of evidence now say the same thing from different directions: tier 3
(metamorphic) is structurally blind to *stable* errors, and the tier-4 research verdict is that
criterion-level judging works "as a localization and ranking instrument on a closed rubric, but
not as an accuracy measurement on this surface." Both tiers rank and localize. Neither measures.
**[res]**

---

## Phase 0 — zero-call foundations

**Cost: 0 model calls.** Everything here reads run dirs that already exist.

> ### ⚠ Measured result, 2026-08-13: Lane A's deterministic half yielded **zero** fixable defects
>
> Ten detectors run over **465 encounters** (ED `washington-402` n=402 + clinic
> `v1-20260720-feedback-63-patch26` n=63), then reviewed with the domain owner. Outcome:
>
> | | |
> |---|---|
> | confirmed defects worth a fix | **0** |
> | real but inconsequential | 1 — count-vs-list (item 0.9); code prefers the list |
> | documentation inconsistency, harmless to billing | 1 — CC gate: prompt says MDM=High, `business_logic.py` checks COPA=High |
> | design work items produced | 1 — the COPA/RISK schema gap (Phase 1.5) |
> | detectors that fired but were **the check misreading a rule** | **6 of 10** |
>
> **This corrects a claim made earlier in this roadmap's own drafting:** that Lane A would pay for
> itself before any labelling happened. On this evidence it does not. The deterministic surface
> looks clean, and the payoff is more likely in **lanes B and C** — judge/dissent-flagged suspects
> and `upstream-input` findings — than in lane A.
>
> **Two readings, not yet distinguishable:** either the pipeline genuinely has no deterministic
> self-contradictions worth fixing, or the detector set was too shallow. The 6-of-10 misread rate
> argues for the first.
>
> **The caveat that keeps Lane A alive: only its *deterministic* half has been tested.**
> Metamorphic violations are Lane A too — if paraphrasing a note moves the billed code, that is a
> defect needing no label — and **none of that has been run.** That is what Phase 3's ~10k calls
> buy, and it is the open question, not a settled one.
>
> **Citation groundedness (ex-"ED-2") was reviewed and dismissed** as a product issue: it is a real
> spec violation (`output_format_prompt.py` demands "exact verbatim quote from the note" ×8) with a
> measurable display effect (244/1,356 met criteria render with no chip; 31% of failures are
> stitched quotes anchored to the wrong fragment), but it **does not affect label quality** —
> accuracy against GT is indistinguishable with and without an unresolvable citation
> (copa 88% vs 74%, data 78% vs 76%, risk 79% vs 85%, cells of 13–58 rows). Retained **not** as a
> defect but as a **hard constraint on Phases 3–4**: ~47% of non-verbatim spans fail even the
> production resolver's fuzzy tiers, so every span-deletion and span-entailment test inherits that
> ceiling.

| # | item | provenance | notes |
|---|---|---|---|
| 0.1 | **Input-adequacy scan** — note length percentiles, truncation, placeholder-only sections, null channels, missing discriminating column, near-duplicate inputs | **[you]** bullet 1, demoted from "judge" to deterministic **[claude]** | Disposition `upstream-input` → routes to `ITERATION.md` stage 1. The one bucket where a judge is *futile*: when the signal was never in the note, no verifier or ensemble can catch it |
| 0.2 | **Citation groundedness, whitespace-normalized** | **[you]** bullet 4 · **[meas]** | **Must** normalize: exact matching gives 46.9% grounded, whitespace-normalized gives 70.0% — a naive check has a **~23-point false-positive rate**. Residual **29.8% ungrounded**, of which 66% are long spans with no clause found verbatim. Facility citations are at `values[].items[].citations` (879 / 292 encounters), not one level up (36 / 12) |
| 0.3 | **Output-format failures** — `stop_reason == max_tokens`, `llm_raw[node].error`, `risk_level == "UNDETERMINED"` | **[you]** bullet 3 ("output format") | Base rate on wa402 is **0/402** **[meas]** — a regression guard, not a mining tool. Build it, don't headline it |
| 0.4 | **Readout correctness fixes** | **[meas]** | `result_json` levels are **lowercase**; `_LEVEL_TO_NUM` is Title-case → `KeyError` on line one. `llm_raw[...].output` is a JSON **string**. Critical-care fields live in `llm_raw`, not `result_json`. `gt_data_level` contains `none`, so rung distance ∈ {0..4} once GT enters |
| 0.5 | **Three prompt-vs-code findings, free** | **[crit]** | (a) critical-care gate 1: prompt says MDM=High and "COPA-High alone is NOT sufficient", `business_logic.py:252` implements `copa_level == "High"` — 6 encounters would bill 99291 on a Moderate-MDM chart. (b) facility rationale-regex rescue: `facility_level` is pre-rescue, `fac_code` post-rescue, so their **disagreement is the detector**; armed in 400/402, fired 0/402. (c) clinic `determine_awv_code_v125` keyword-scans `llm_thinking` — a temperature-1 free-text channel selecting a billed HCPCS |
| 0.6 | **Standing prompt-vs-code diff** | **[claude]** | Live instance already known: clinic prompt carries "MERCY RULE D", `apply_v1_post_processing` applies Rule C only |
| 0.9 | **Count-vs-list self-consistency** (ex-"ED-3") — the model asserts `tests_ordered_count=N` beside a list of length M | **[meas]** | Fires **1/402** (`944640641`: count 2, list 3). **No consequence**: `_calculate_data_points_from_two_stage` prefers `len(list)` and only falls back to the count, so points are unaffected and the count field is vestigial back-compat. Ship as a **regression guard**, not a mining tool — it would catch the day someone reverses that preference. Same tier as 0.3 |
| 0.7 | **Findings schema** — mirror `core.dump_errors` rows minus GT, plus `{detector, tier, score, evidence, changes_output}`; disposition prior from the existing closed set | **[claude]** | `core.autoeval` *is* `dump_errors` without `gt.csv`. **No second taxonomy** |
| 0.8 | **Fix the evidence base** — no `manifest.json` on any `washington-402-baseline` run dir; `run_signature` records the model **alias** | **[crit]** | Every number in this roadmap rests on unmanifested runs. A provider snapshot rotation is currently indistinguishable from a real finding |

**Gate: none.** Phase 0 cannot fail; it can only be skipped, and skipping it means later phases
compute on mis-read fields.

---

## Phase 1 — dissent mining

**Cost: ~0 new calls** for what is on disk; the extension depends on Phase 4's recoverability finding.

| # | item | provenance | notes |
|---|---|---|---|
| 1.1 | **ED vote entropy** from `abstention.pro_votes` (QH / GPT-5.4 / Gemini) | **[you]** bullet 2 | `ed/gate.py` consumes these as a *binary* gate; the same votes give a graded score, and the gate is a threshold on it |
| 1.2 | **Clinic vote dissent** — `repro-seed{1,2,3}` carry per-vote traces = **K=9 on 63 encounters, already paid for** | **[crit]** | Use block permutation by run: within-run votes are not exchangeable with cross-run votes |
| 1.3 | **Exact semantic entropy** over a 4–5 rung ordinal | **[claude]** + **[res]** | The label set *is* the set of semantic equivalence classes, so entropy is exact — no clustering, no probes. The expensive part of that literature is free here |
| 1.4 | Extend verifier agreement from PRO-only to COPA/DATA/RISK | **[claude]** | Verifiers already compute all three and the gate discards them. **Blocked on 4.0** |

**Gate: correlated errors.** Three models with overlapping training agree on the same wrong
answer and unanimity reads as confidence. Tier 2 is a *ranking* signal; it never becomes an
accuracy claim. **[res]**

---

## Phase 1.5 — complete the COPA/RISK criterion schemas  ← **highest leverage item in the roadmap**

Born from the ex-"ED-6" false lead (RISK=High with all 12 booleans False, which turned out not to
be a contradiction). **[meas]** The chain `booleans → axis level → MDM median → CPT code` is
deterministic everywhere **except the one step where the LLM has sole authority**:

| axis | boolean → level rule | where it lives | complete? |
|---|---|---|---|
| **DATA** | arithmetic: Cat A 2 pts/item (cap 6); historian +3, interpretation +6, QHP +6; Minimal 0–2 · Low 3–5 · Moderate 6–11 · High 12+ | `business_logic.py`, implemented — and it **overrides** the LLM's declared level | **yes** |
| COPA | prose only; High reachable via pathways (a)/(b) that map to **no** boolean | `copa_prompt.py` | no |
| RISK | prose only; High reachable via pathways (a)–(f) that map to **no** boolean | `risk_prompt.py` | no |

**The work:** add one structured field per prompt pathway (COPA (a)/(b); RISK ICH-concern, focal
deficit, altered consciousness, mechanism, worsening neuro, anticoagulant+trauma+CT), so the
declared level becomes *derivable from the model's own extractions* rather than asserted.

**Why it is the highest-leverage item:**
1. **DATA is the existence proof** — the pattern already works on one axis, and it is the only axis
   where code can catch the model.
2. It creates **two new deterministic checks where there are currently zero**, on the two axes
   carrying the most billing risk.
3. **It unblocks Phase 4.** Criterion judging cannot reconstruct a level today *because* the schema
   is lossy (identical boolean vectors → different levels: copa 4 of 8, data 6/9, risk 9/33). Fix
   the schema and the judge's booleans can run through the real aggregation — the original premise.
4. It retires a whole class of false leads: 3 of the 4 lane-A retractions traced to this one
   property.

qh-platform change (schema + prompts) ⇒ `.worktrees/` branch, not a patch. **Prerequisite for
Phase 4.** Cost: engineer-days, no model calls to specify; a re-run to validate.

## Phase 2 — the calibration harness  ← **the real gate on everything below**

**Cost: 0 model calls; ~2–4 engineer-days.** Nothing LLM-based ships before this exists.

| # | item | provenance |
|---|---|---|
| 2.1 | Per-detector PR curve, lift over random ordering, queue AUC, against the labelled slice | **[claude]** |
| 2.2 | **Hold one dataset out entirely** — a detector tuned and validated on `qh-0731-dev-set-93` is worth nothing | **[claude]** |
| 2.3 | Compute what CI the labels actually support **before** trusting any of it | **[meas]** |
| 2.4 | Agreement statistic that survives class imbalance (Gwet AC1 / Krippendorff, **not** kappa) | **[res]** |

**The uncomfortable number:** `gt.csv` on washington-402 is **~82% blank** on the level columns —
**71 / 72 / 71** labelled rows for copa / data / risk. **[meas]** Six of the eighteen criterion
booleans have base rates under 2.5%, and one (`physical_restraints_used`) is **never true in
402 encounters**. A per-criterion PR curve at those prevalences over 71 rows supports almost
nothing.

**Gate — and it may redirect the whole programme:** if 71 rows per axis cannot support a usable
interval, the correct next action is **acquire more labels**, not build more detectors. Reference
-free judges must be calibrated against reference-aware evaluation on a sample first **[res]**;
an uncalibrated detector cascade is a pile of unfalsifiable opinions.

---

## Phase 3 — tier 3, metamorphic testing

Full design and cut line in [[tier 3 metamorphic]]. **~10k calls, ~12–20 h serialized, one
MR-week.** **[crit]**

| step | item | provenance |
|---|---|---|
| 3.0 | Precondition scan + strata over existing runs; our own span matcher | **[meas]** |
| 3.1 | Plumbing: per-encounter override index, `--freeze-note`, `--perturb`, spec-sha guard — ~25 lines, `core/` only, **no qh-platform change** | **[crit]** |
| 3.2 | Estimator: θ̂ with the **K(K−1)** within-arm term, exact permutation, `mean_ci` beside `_resamples`, `mr_selftest.py` | **[crit]** |
| 3.3 | **NULL-1** — frozen-note identity, two *distinct fresh* lanes, n=100, ~2,400 calls | **[crit]** |
| 3.4 | **RULE-1-EKG** — expectation is a theorem about the DATA point caps *and* a prompt clause forbidding the note channel | **[res]** + **[crit]** |
| 3.5 | **ATTRIB-1** — redact the attestation marker, `independent_interpretation` must go False, n=208 | **[crit]** |
| 3.6 | **INV-1** (section reorder), n≈342 — **conditional** on 3.3's null | **[you]** bullet 4 → **[meas]** |

**Gate: NULL-1.** Stop if θ̄ ≠ 0 — a frozen-note arm inside a materialized cache lane is a
*replay*, within-arm disagreement is 0, and the estimator fabricates a +2.6 to +4.5pp effect.
Assert `cache_hit == false` on every draw. **[crit]**

**The likeliest outcome is not an MR violation.** `rcm-format-notes` reproduces a byte-identical
formatted note in **23/402 (5.7%)** re-runs, and on exactly those 23 the scorer's output is
byte-identical with **zero axis movement** **[meas]**. If NULL-1's frozen-note null lands well
below the 5–9% full-DAG figure, the dominant source of ED instability is a note formatter nobody
is looking at, and the fix is caching it — a **product** change, not prompt work. That would make
`features/ed-format-notes-cache/` a candidate product fix rather than an eval convenience.

---

## Phase 4 — tier 4, criterion judging  · **PROVISIONAL**

Design in flight (workflow `wf_0278723c-515`, 1 of 4 grounding agents returned). Rows below are
what the measurements already fix, regardless of what the workflow concludes.

| # | item | status |
|---|---|---|
| 4.0 | **Is the discarded verifier criterion detail recoverable from disk?** `ed/verifiers.py` runs GPT-5.4 + Gemini through their own questionnaires and own PRO call — the blind-extraction call **already exists in prod** — but `_codes_from_pro` returns five codes and discards every criterion boolean | **being quantified.** If recoverable: cross-family criterion comparison is near-free and this is the cheapest win in the programme. If zero encounters: the tier goes from free to paid **[claude]** |
| 4.1 | **Resolve the aggregation gap** | **Required, no longer optional.** `run_two_stage_calculations` accepts `copa_level` and `risk_level` **as declared** and re-derives DATA only. And identical boolean vectors map to different declared levels — copa 4 of 8 vectors ambiguous (one maps to all four levels), data 6/9, risk 9/33 **[meas]**. So a judge emitting booleans **cannot** reconstruct the level; either it emits the full field set, or COPA/RISK need the prompt's rule table as code — which makes tier 4 **depend on tier 1**, not sit beside it |
| 4.2 | **Choose the criterion surface** | Two exist and they are not the same thing: 18 `llm_raw` booleans (drive the pipeline) vs `guideline_report`'s **61 facility + 17 professional** criteria per encounter (display-derived) **[meas]**. Judging the latter may be judging a renderer |
| 4.3 | Blind extraction · entailment · conflict enumeration | **[you]** bullet 4, re-specced. Blinding is what prevents anchoring; skipping it is what makes reference-free judges generous **[res]** |
| 4.4 | Exclude criteria two qualified coders would routinely disagree on | **[crit]** pending — those cannot be judge-evaluated without a human adjudication standard |

**Gate: Phase 2.** No criterion judge ships without a PR curve. Second gate: 4.1 must be resolved
before any level-level readout is believed.

---

## Phase 5 — tier 5, blinded re-code + adjudication

Last and most expensive. Cross-family model codes from scratch, blind; disagreements go to a third
adjudicator with **arm order randomized and identity hidden**; verdict is
`ours | theirs | ambiguous`. **[you]** bullet 3, re-specced **[res]**.

`ambiguous` is a first-class outcome, not a hedge: it is the label-ambiguity population, the same
one that poisons GT-based eval, and it belongs in `label-or-standard`. **[claude]**

**Gate:** only worth building if Phase 2 shows tier-4 criterion judging calibrates. If a
decomposed judge cannot be calibrated, a holistic one certainly cannot. **[res]**

---

## Phase 6 — aggregation, operating point, population numbers

| # | item | provenance |
|---|---|---|
| 6.1 | Dawid–Skene-style label model over detector votes; **model dependence explicitly** — the groundedness check and the entailment check are not independent, and pretending otherwise inflates confidence exactly where they co-fire | **[claude]** + **[res]** |
| 6.2 | Conformal risk control → "flag top k%, catch ≥X% of errors, 90% confidence", finite-sample valid | **[res]** |
| 6.3 | **PPI** for any population number — unbiased regardless of the judge's error profile; the labelled sample measures the judge's systematic error and corrects it | **[res]** |
| 6.4 | Bootstrap resamples **encounters**, not encounter-seed rows (locked by `scripts/metrics_selftest.py`) | existing invariant |

---

## Cross-cutting discipline

**Goodhart.** Gating detectors are frozen and version-pinned; iteration detectors are separate;
any auto-eval-motivated prompt change is validated on human labels before it ships.
"Never pool datasets" generalizes — in-sample-to-the-detector is a new way to be in-sample. **[claude]**

**Correlated blindness.** Every LLM tier shares the generator's blind spots. This is why Phases
0–3 come first: they are the only ones whose evidence is independent of any model's judgement. **[claude]**

**PHI.** Findings files and perturbed-note intermediates carry verbatim note text → local-only,
never committed, never synced. Encounter ids are fine. **`features/` is not tracked and not
synced**, so anything here worth keeping moves to `core/`/`docs/`/a `CLAUDE.md`.

---

## The graveyard — measured dead, do not rebuild

Recorded so the next reader does not re-propose them. Six of these were **my** suggestions.

| item | why it died |
|---|---|
| **Lane A pays for itself before any labelling** — my claim | **0 fixable defects on 465 encounters** [meas]. The deterministic surface is clean; the payoff is in lanes B/C. Lane A's metamorphic half is still untested and remains the open question |
| **Citation groundedness as a defect / queue-ranking signal** | Real spec violation, but **no label-quality signal**: accuracy vs GT indistinguishable with and without an unresolvable citation [meas]. Dismissed as a product issue by the domain owner; survives only as a **ceiling on Phases 3–4** (~47% of non-verbatim spans fail even the fuzzy resolver) |
| **Critical-care gate as an over-code finding** | **99291 is time-based** (critically ill + ≥30 min); CPT's MDM two-of-three governs 99282–99285, not 99291. "2 of 3 CC bills are over-codes" was wrong. Residual is a docs inconsistency only |
| **RISK=High with all 12 booleans False as a contradiction** | `risk_prompt.py` reaches High via pathways (a)–(f) mapping to **no** boolean [meas]. Became Phase 1.5 |
| **Clinic "Documented Total Time" as an audit exposure** | `transform_v1.py:508` **hardcodes** `criteria_met: True` as an FE styling flag; `level=""` already hides the chip when time is not usable/attributable (QEU-299/303) |
| **DATA declared-vs-recomputed detector** — I called it "highest value per line" | **402/402 identical [meas].** Prod logs the mismatch and discards it; the warning never fires. Regression guard only |
| **Criterion-true-with-empty-evidence** | **0/589 [meas]** |
| **Template-noise stripping as a negative control** — my advice, and wrong | **331/6,059 cited spans (5.46%) *are* placeholder lines; 186/402 (46.3%) encounters cite one as evidence [meas].** They are *negative* evidence for a low rung, so stripping them *should* move the level. As a stop-the-line control it would have failed a working apparatus |
| **"~40 criterion booleans"** | It is **18** [meas]; the 40-ish figure was `guideline_report`, a different and display-derived surface |
| **"Aggregation stays deterministic"** | False twice: COPA/RISK levels are accepted as declared, and identical boolean vectors map to different levels [meas] |
| **Delete-the-MAR MR** | `consolidated_administered_med_summary` is the literal string `"null"` in **402/402** rows [meas] — an identity perturbation |
| **Row-metadata swap MR** | `arrival_dept_name` has exactly one distinct value; `adt_arrival_time` is date-only [meas] |
| **Keep-only-citations sufficiency test** | Cited spans are a median **3.4%** of note characters [meas] — a 96.6% deletion measures OOD-ness, not sufficiency. Keep the comprehensiveness direction, which perturbs 3.4% |
| **Critical-care attestation MR** | Would have certified billing 99291 on 6 Moderate-MDM charts [crit]. Became a free prompt-vs-code finding instead (0.5a) |

## Named unmeasured quantities

Each blocks something specific. Listed so they can be attacked directly.

1. **The frozen-note null** — blocks tier 3's interpretability. NULL-1, 800–2,400 calls.
2. **Verifier criterion detail recoverability** — decides whether tier 4 is free or paid. In flight.
3. **Paraphrase-infidelity rate** — blocks INV-2. Cross-family paraphraser + coder audit of 50.
4. **Whether L0 movement with L1 held carries elevated GT error** — checkable only on ~71 labelled
   rows per axis, target subset in the teens. State the MDE or drop the gate.
5. **Citation groundedness against the cache request bytes** — the 29.8% figure is measured
   against a *reconstruction* of the model input, not the input itself.
