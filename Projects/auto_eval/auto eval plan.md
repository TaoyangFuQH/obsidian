---
updated: 2026-08-12
tags: [project, coding-pod, eval, auto-eval, plan]
---
# feature: llm-auto-eval — reference-free error detection for ED + clinic coding

The six-tier design and its rationale. Above this: [[auto eval proposal]] (goals, workstreams, concerns) and [[auto eval roadmap]] (phasing, gates, graveyard). Tier detail: [[tier 3 metamorphic]], [[tier 4 criterion judging]]. Literature: [[LLM as a judge SOTA]]. Measured defects: [[lane A findings]].

Sibling of `skills/rca-coding`, which needs a labelled feedback batch. This one needs
**no GT**: it reads an encounter's input plus our own recorded output/reasoning and emits
a ranked, dispositioned list of *suspect* (encounter, axis) rows.

## Goal

`core.dump_errors` answers "which encounters got what wrong" **only where `gt.csv` says
so**. Every dataset we own is label-bound: 1,609 ED GT rows and 63–117 clinic rows across
6 datasets, 3 feedback batches total. Everything else we run — every new customer slice,
every candidate arm on unlabelled data — is unmeasured. Three concrete costs:

1. **No triage.** A 402-encounter run has no ordering; RCA starts wherever someone looks.
2. **No coverage.** Defect classes that only appear off the labelled slice are invisible
   until a customer finds them. `diagnosis.md` already records this failure once (19 of 93
   ED encounters carried MDM labels; 74 were being read as if they did).
3. **No pre-flight.** We ship a candidate onto unlabelled data with no signal at all
   until feedback comes back weeks later.

**What this feature is for:** ranking a review queue, finding defect *classes* worth an
RCA, and gating. Plus — with a small labelled sample — unbiased population estimates.

**What it is explicitly NOT for: replacing `gt.csv` as the accuracy measurement.** A
judge-derived accuracy number is biased by the judge's own error profile, and in the
reference-free setting the bias has a known direction — judges over-credit the answer
they are shown ([Kranti & Vajjala 2026](https://arxiv.org/abs/2607.12885)). Any headline
accuracy still comes from human labels, or from PPI (§ Approach, tier 6). This line is
load-bearing: cross it and `docs/EVALUATION.md`'s two-artifact contract collapses into a
model grading its own homework.

### Where the proposed design holds, and where it breaks

The originating sketch had four buckets. Verdict on each:

| proposed | verdict |
|---|---|
| upstream-input missing data | **Keep, and demote to deterministic.** Needs no judge at all — it is a scan of `input.csv` + the assembled model input. Also the one bucket where a judge is *futile*: per `diagnosis.md`, when the signal was never in the note, "no verifier, gate or ensemble can ever catch the error". So it must run first and route to `ITERATION.md` stage 1, not to a prompt fix. |
| tool LLM coding uncertainty | **Keep, and note we already pay for it.** ED already runs GPT-5.4 + Gemini verifiers and records `result_json.abstention.pro_votes`; clinic already runs a 3-vote `clinic-extract` ensemble. Dissent is on disk, unmined, for every run. Start here — it costs zero new calls. |
| directly judge which labels are incorrect | **This is the weak link. Demote it to last.** It is exactly the holistic reference-free judge the literature says is too generous, and worse, it would be run by the same model family that produced the output — self-preference bias makes the detector blind precisely where the generator is wrong. It also asks the model to self-correct without external feedback, which [Huang et al. (ICLR 2024)](https://arxiv.org/abs/2310.01798) show does not work and often degrades. Keep it, but blinded, cross-family, decomposed, and calibrated — see tiers 4–5. |
| decisive-context extraction + conflict detection | **The best idea in the sketch, and under-exploited.** Verification beats generation *for decomposable tasks* — that is the documented precondition, and coding is decomposable: ~40 criterion booleans per encounter with citations, already in `guideline_report`. Judge the criteria, not the code, and aggregation stays deterministic. Extend it from a self-report into a *tested* claim by deleting the decisive span and re-running (tier 3). |

Three things the sketch was missing entirely, in priority order:

- **Validation against the labels we already have.** A detector with unmeasured
  precision/recall is not an eval. 1,609 labelled ED rows are enough to calibrate every
  tier below and hold a slice back. Non-negotiable: `docs/EVALUATION.md` already forbids
  a null without an MDE; a detector without a PR curve is the same defect.
- **Free deterministic detectors.** A large share of what the sketch wants a judge for is
  a `!=` between two numbers we already compute. Details in tier 1 — including one where
  prod **computes the disagreement, logs a warning, and throws it away.**
- **An aggregation rule and an operating point.** N detectors need combining without GT,
  and "here are some issues" is not actionable. Output is a ranked queue with a stated
  flag budget and a catch rate.

## Approach

Six tiers, cheapest first, each one a filter on the next — the same one-sided logic as
`PLAN.md`'s adaptive gate (proving something is fine is cheap; suspecting it earns the
expensive tier). A row's score is the combination of tiers that fired.

New code: `core/autoeval/` (profile-agnostic engine), `ed/autoeval.py` +
`clinic/autoeval.py` (per-product invariants and rule replays), `core/autoeval_report.py`
(rendering). Per-product knowledge goes in the product module, never in `core/`.

### Tier 0 — input adequacy (deterministic, no model call)

Runs on `input.csv` and on the **assembled** model input, not just `note`. Signals:
resolved-note length below the 5th percentile of the dataset; note truncation (no
terminal punctuation, mid-sentence cut); EHR template artifacts as the *only* content in
a section (`"RADIOLOGY: No orders to display"`, `"LAB: No data to display"` — both
observed in `washington-402/run1`); null `order_summary` /
`consolidated_administered_med_summary`; missing discriminating column for the axis being
judged; near-duplicate inputs across encounters.

Reuses `core.dataset.check_note_content`, which already catches the empty-note case.
Output disposition: `upstream-input`. Routes to stage 1.

### Tier 1 — self-consistency invariants (deterministic, no model call)

The output already contradicts itself in machine-checkable ways. Each of these is a hard
inconsistency, not a probabilistic hint, and each *localizes on its own*:

1. **Prompt-vs-code divergence, already computed and discarded.**
   `business_logic.run_two_stage_calculations` re-derives DATA points from the LLM's own
   sub-entity counts, compares to the LLM's declared `data_level`, logs
   `"DATA level mismatch — LLM: %s, computed: %s"`, and then uses the computed value.
   That warning is a free, exact detector of the LLM misapplying the DATA table — and it
   goes to a log nobody reads. Recompute it from `llm_raw` and emit it as a finding.
2. **Rule replay on the axes with no recompute.** COPA and RISK are accepted from the LLM
   directly. Re-implement the prompt's decision table over the LLM's *own* booleans and
   compare to its declared `level`. This is the split the sketch's bullet 3 actually
   needs: booleans right + level wrong → aggregation/arithmetic, address is the prompt's
   rule table; booleans wrong vs the note → extraction, address is the criterion text.
   One detector, two distinct loci.
3. **Citation groundedness.** Every `citations[].cited_text` must be a verbatim substring
   of the assembled input. Must be checked against the *reconstructed* content
   (`build_data_content` / `build_risk_content` re-append orders and meds), or against
   the request stored in the model cache — `core/modelcache.py` keeps `request` verbatim
   and content-addressed, so the exact bytes sent are always recoverable. In the one
   encounter inspected while writing this, 2 of 9 cited spans were not substrings of
   `note`; at least one is a stitched paraphrase presented as a quote. Clinic's
   ~23 `source_quote` fields per encounter are schema-defined as verbatim substrings —
   same check, larger surface.
4. **Evidence/claim polarity.** A criterion boolean `true` with an empty `evidence[k]`
   string is an unsupported claim; `false` with non-empty evidence is a contradiction.
5. **Internal arithmetic.** `tests_ordered_count` vs `len(tests_ordered)`, and the same
   for external notes and prior tests reviewed.
6. **Output-format failures.** `stop_reason == "max_tokens"` (truncated structured
   output), `llm_raw[node].error != null`, and the `risk_level == "UNDETERMINED"`
   sentinel that prod sets on a null risk level. Disposition: `system`, locus is the
   node, mechanism is not a prompt mechanism — these are the sketch's "output format"
   errors and they are cheap and currently uncounted.
7. **Cross-node override.** Pass 2 (`ed-pro-scoring`) receives the pass-1 DATA/RISK
   questionnaire text. Where its booleans contradict the questionnaire's answers, pass 2
   overrode pass 1 — locus is the pro prompt, and it is invisible from the final code.
8. **Standing prompt-vs-code diff, no encounter needed.** The rca-coding skill already
   names the live instance: the clinic system prompt carries "MERCY RULE D" while
   `apply_v1_post_processing` applies Rule C only. Automate it: enumerate the rules the
   prompt states, enumerate what the deterministic code implements, diff. A whole error
   class before any encounter is read.

Tier 1 has a property no LLM tier has: **it is right about the inconsistency by
construction.** It can be wrong about whether the inconsistency changed the final code —
so every tier-1 finding carries a `changes_output: bool` from replaying the deterministic
tail (`ITERATION.md` § "Fast inner loop").

### Tier 2 — dissent mining (no new model calls)

Read what is already recorded. Per axis, per encounter: the vote distribution and its
normalized entropy.

- **ED:** `abstention.pro_votes` → QH / GPT-5.4 / Gemini. Currently consumed only as the
  binary gate (`ed/gate.py`). The same votes give a graded score, and the gate is a
  threshold on it.
- **Clinic:** the three `clinic-extract` votes. `--save-node-results` (already
  implemented) persists them; `<out-dir>/nodes/` already exists on the iter-2 RCA runs.
- **Across seeds:** K seeded runs → per-axis label distribution. For a 4–5 rung ordinal,
  the label set *is* the set of semantic equivalence classes, so entropy over that
  distribution is [semantic entropy](https://www.nature.com/articles/s41586-024-07421-0)
  computed exactly — no clustering, no sampling approximation, no probes. The expensive
  part of that literature is free here because the output space is tiny. Worth stating in
  any write-up: the method transfers to closed-label coding at a fraction of its cost.

Cheap extensions worth doing, both no-GT: extend the verifier comparison from PRO-only to
COPA/DATA/RISK (the verifiers already produce them — `ed/verifiers.py` returns all three
and the gate discards them), and add a cross-family verifier to clinic, which has none.

Tier 2's failure mode is the one to write down: correlated errors. Three models trained
on overlapping data agree on the same wrong answer, and unanimity reads as confidence.
So tier 2 is a *ranking* signal and never an accuracy claim.

### Tier 3 — metamorphic testing (new calls, no judge)

The strongest reference-free idea absent from the sketch: perturb the input in a way
whose correct effect is known a priori, and check the output moves as required. No GT, no
judge, and the result is causal rather than a self-report.

- **Invariance.** Paraphrase the note; reorder sections; change name/DOB/provider; strip
  template-noise lines. The level **must not move.** Any move is a defect, full stop.
- **Directional monotonicity.** Delete the span the model itself called decisive → the
  level must drop, or the model must cite different support. Add a documented qualifying
  element → the level must not drop. Remove the whole order summary → DATA must not stay
  high.
- **Sufficiency.** Feed *only* the cited spans. If the same level comes back, the
  citations are sufficient; if it changes, the model was using uncited context and the
  citation set is not the real basis for the decision.

This is what turns the sketch's bullet 4 from a claim into a test. It is also the input
-level analogue of `interventions.md`'s prompt ablation — the only tier below that
establishes causation rather than correlation. Budget it as a targeted tier on rows the
cheap tiers already flagged, not a sweep.

### Tier 4 — decomposed criterion judging (blinded, cross-family)

Judge the ~40 criterion booleans, not the code. Three separate calls, and the separation
is the whole design:

1. **Blind extraction.** A different model family, shown the input and the criterion
   list, *never shown our answer*: which criteria does this documentation support, and
   what is the decisive span for each? Blinding is what prevents anchoring — this is the
   step the sketch's "directly judge" formulation skips, and skipping it is what makes
   reference-free judges generous.
2. **Entailment.** For each of *our* criteria set true, does the cited span entail it?
   For each set false, does the input contradict that?
3. **Conflict enumeration** — the sketch's last bullet, made concrete. Three conflict
   types, kept distinct because they route differently: our cited span vs the input
   (groundedness, already tier 1); our criterion vs the blind extractor's (candidate
   error); one criterion vs another within our own output (internal inconsistency, e.g.
   `prescription_drug_management: true` with `disposition: "discharge"` and no
   documented prescription).

Aggregation stays deterministic — run the real `run_two_stage_calculations` over the
judge's booleans. So a tier-4 disagreement arrives pre-localized to a criterion, which is
a prompt address, not a category.

Directional prompting, not symmetric. Never "is this correct?" — always the rung boundary
being tested: "is there documented support for RISK=Moderate, or does the documentation
only support Low?" The compliance question is one-sided (over-coding on the billed axis)
and `docs/EVALUATION.md` already treats direction as the point; the detector should
inherit that asymmetry.

### Tier 5 — blinded independent re-code + adjudication (most expensive, last)

What the sketch's bullet 3 should become. A cross-family model codes the encounter from
scratch, blind to our output. Disagreements only go to a third adjudicator that sees both
rationales with **arm order randomized** and arm identity hidden. Two rules: never the
same model+prompt as the generator, and the adjudicator's output is
`ours | theirs | ambiguous` — with `ambiguous` a first-class verdict.

`ambiguous` is not a hedge. Cases a blinded panel cannot resolve are the label-ambiguity
population, and separating them out is worth having on its own: it is the same population
that poisons GT-based eval, and `diagnosis.md`'s `label-or-standard` disposition is
exactly where they belong.

### Tier 6 — aggregation, calibration, and the operating point

**Combining detectors without GT.** Detector votes per (encounter, axis) → a
Dawid–Skene-style label model, which estimates each detector's confusion matrix from
agreement structure alone. Where the labelled slice exists, prefer supervised stacking
and use the label model only as the unlabelled-data extrapolation. Model detector
dependence explicitly: tier 1's citation check and tier 4's entailment check are *not*
independent, and pretending they are inflates confidence exactly where they co-fire.

**Calibration is the gate on shipping any of this.** Against the labelled slice, per
tier and for the combination: precision, recall, lift over random ordering, and the
ranked queue's AUC. Reference-free judges have to be calibrated against reference-aware
evaluation on a sample before being trusted unsupervised — that is the explicit
recommendation of the 2026 no-reference study, and we have the sample. Hold out one
dataset entirely; a detector tuned on `qh-0731-dev-set-93` and validated on the same is
worth nothing.

**Operating point, not a score dump.** Conformal risk control turns the combined score
into a statement of the form "flag the top k%, catch ≥X% of the errors, 90% confidence",
with finite-sample validity. That is the form the review queue needs, and it makes the
cost trade explicit: a false flag costs coder review minutes; a missed over-code is a
compliance exposure. State which one the threshold is tuned against.

**Population estimates via PPI.** Where an unbiased number on unlabelled data is wanted,
prediction-powered inference combines the small human-labelled sample with the large
auto-judged set and is unbiased *regardless of the judge's error profile* — the labelled
sample measures the judge's systematic error and corrects it. This is the only honest
route from a judge to a number in a report, and it is what tier 6 emits when asked for
one. Reported CIs must respect the existing invariant: the bootstrap resamples
**encounters**, and a resampled encounter brings all its seeds
(`scripts/metrics_selftest.py` locks this).

### Two failure modes to design against from the start

**Goodhart.** Fix prompts against detector-flagged errors and the detector stops being a
measurement of anything. Rule: detectors used for *gating* are frozen and version-pinned;
detectors used for *iteration* are separate; and any prompt change motivated by auto-eval
is validated on human-labelled regression data before it ships. `docs/EVALUATION.md`'s
"never pool datasets" rule generalizes here — in-sample-to-the-detector is a new way to
be in-sample.

**Correlated blindness.** Every LLM tier shares the generator's blind spots to some
degree. This bounds what the feature can ever claim, and it is the reason tiers 0–3 come
first: they are the only ones whose evidence is independent of any model's judgement.

## Contract

- **`<run-dir>/autoeval/findings.json`** — one row per (encounter, axis, detector) that
  fired. Deliberately the **same row shape `core.dump_errors` emits**, minus the GT
  columns and plus `{detector, tier, score, evidence, changes_output}`. `core.autoeval`
  is `core.dump_errors` without `gt.csv`; anything reading one reads the other.
- **Every row carries a disposition prior** from `diagnosis.md`'s closed set
  (`system` | `upstream-input` | `label-or-standard` | `not-reproducible`) — a *prior*,
  because only a human-confirmed disposition enters an RCA. No new taxonomy: a second
  error vocabulary next to the existing one is the thing to avoid.
- **A finding with no pointer to an intermediate is not emitted.** Same rule the RCA
  skill enforces ("a cause asserted without pointing at an intermediate is not a
  finding") — every row cites the node, the field, and the span.
- **`causes.json`-compatible promotion.** A confirmed auto-eval finding writes the same
  registry entry an RCA finding does (`skills/rca-coding/SKILL.md`), so it enters
  `ITERATION.md` stage 3 through the existing door and reaches the changelog at stage 4.
- **Calibration is part of the artifact.** `autoeval/calibration.json` records, per
  detector version, the labelled dataset it was measured on, its PR curve, and the held
  out set. A findings file whose detectors have no calibration entry is a draft.
- **PHI.** `findings.json` and any perturbed-note intermediate carry verbatim note text —
  local-only, never committed, never synced (`CLAUDE.md`: run outputs are the line).
  Encounter ids are fine. The rendered report is population-level and cites ids only.
- **Determinism.** Tiers 0–1 are pure functions of a run dir; tiers 3–5 go through
  `core.modelcache` so a re-run replays instead of re-billing.

## How to use

```bash
source scripts/env.sh

# tiers 0-2 — no model calls, runs on any existing run dir
$PY -m core.autoeval scan --profile ed --run-dir <run-dir> \
    --dataset washington-402 --out <run-dir>/autoeval/findings.json

# tiers 0-2 across seeds — adds the dissent/entropy signal
$PY -m core.autoeval scan --profile clinic --run-dirs <r1> <r2> <r3> \
    --dataset v1_benchmark --out <run-dir>/autoeval/findings.json

# tiers 3-5 — targeted at what the cheap tiers flagged
$PY -m core.autoeval judge --profile ed --run-dir <run-dir> \
    --findings <run-dir>/autoeval/findings.json --tier 4 --judge-model gpt-5.4 \
    --top-k 60

# calibrate against the labels we already have, holding one dataset out
$PY -m core.autoeval calibrate --profile ed \
    --labelled qh-0731-dev-set-93 general-test-165 --holdout qh-0731-test-set-215 \
    --out <run-dir>/autoeval/calibration.json

# the queue + the report
$PY -m core.autoeval queue --findings <...> --calibration <...> --budget 0.15
$PY -m core.autoeval_report --findings <...> --calibration <...> \
    --out <product>/experiments/<slug>/reports/autoeval-<dataset>.md
```

## Status / log

- 2026-08-12: plan written. Grounding done against `skills/rca-coding` (dispositions,
  locus, mechanism tree, attribution tiers — reused verbatim, no new taxonomy),
  `core/dump_errors.py` (row shape to mirror), `ed/gate.py` + `ed/verifiers.py` (dissent
  already recorded, PRO-only), `core/modelcache.py` (request bytes recoverable),
  `features/save-node-results` (per-vote labels already persistable), and one live run
  (`ed/experiments/washington-402-baseline/results/run1`) for the signal inventory.
  Confirmed on that run: `confidence.pro_code` self-report, per-criterion booleans with
  `evidence` strings, `citations[].cited_text`, `thinking`, `stop_reason`, and 2 of 9
  cited spans not substrings of `note`.
- **Build order proposed:** tier 1 detectors 1+3+6 first (highest value per line,
  zero marginal cost, and detector 1 recovers a signal prod already computes and
  discards) → tier 2 dissent mining over existing runs → calibrate on the labelled
  slice **before** building any LLM tier, because the calibration number decides whether
  tiers 4–5 are worth building at all.
- Open: whether tier 3's perturbations are generated (a model paraphrases) or
  templated (deterministic section shuffles / line deletions). Templated first — a
  generated perturbation that silently changes clinical meaning turns an invariance test
  into a false positive, and there is no GT to catch it.
