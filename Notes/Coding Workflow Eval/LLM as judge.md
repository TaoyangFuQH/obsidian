---
updated: 2026-08-12
tags: [reference, coding-pod, eval, auto-eval]
---
# LLM auto-eval — detecting coding errors without ground truth

Companion to [[rca-coding logic]], which reads the same problem from the taxonomy side.
That note asks *"if we automate the RCA judge, how does the taxonomy constrain it?"*. This
one asks the prior question: **with no `gt.csv` at all, what can we actually detect?**

Design lives in the repo at `coding-ai-harness/features/llm-auto-eval/plan.md` (local-only
— `features/` is not tracked, so this note is the durable copy of the reasoning).

## Why bother — the label wall

`core.dump_errors` answers "which encounters got what wrong" **only where `gt.csv` says
so**. Everything we own is label-bound: ~1,609 ED GT rows across 6 datasets, 63–117 clinic
rows, 3 feedback batches total. Every new customer slice and every candidate arm on
unlabelled data is unmeasured. Three costs:

1. **No triage** — a 402-encounter run has no ordering; RCA starts wherever someone looks.
2. **No coverage** — defect classes that live off the labelled slice are invisible until a
   customer finds them. Already happened once: 19 of 93 ED encounters carried MDM labels
   and the whole batch was read as if they did.
3. **No pre-flight** — a candidate ships onto unlabelled data with zero signal until
   feedback returns weeks later.

## The line that must not be crossed

Auto-eval is for **ranking a queue, finding defect classes, and gating**. It is *not* a
replacement for `gt.csv` as the accuracy measurement. A judge-derived accuracy is biased by
the judge's own error profile, and in the reference-free setting the bias has a known
direction: judges **over-credit the answer they are shown**. Headline accuracy still comes
from human labels, or from PPI (tier 6). Cross this line and the two-artifact contract in
`docs/EVALUATION.md` degenerates into a model grading its own homework.

## Verdict on the naive four-bucket design

| proposed detector | verdict |
|---|---|
| upstream-input missing data | **Keep, demote to deterministic.** No judge needed — a scan of `input.csv` + the assembled model input. Also the one bucket where a judge is *futile*: when the signal was never in the note, no verifier, gate or ensemble can ever catch it. Routes to `ITERATION.md` stage 1. |
| tool LLM coding uncertainty | **Keep — we already pay for it.** ED records `abstention.pro_votes` (QH + GPT-5.4 + Gemini); clinic runs a 3-vote `clinic-extract` ensemble. Dissent is on disk, unmined, for every run already made. |
| directly judge which labels are wrong | **The weak link. Demote to last.** This is the holistic reference-free judge, run by the generator's own family. Blinded, cross-family, decomposed and calibrated, or not at all. |
| decisive-context + conflict detection | **Best idea, under-exploited.** Verification beats generation *for decomposable tasks* — the documented precondition. Coding qualifies: ~40 criterion booleans with citations per encounter in `guideline_report`. |

## Six tiers, cheapest first

Same one-sided logic as the reproduction gate: proving something is fine is cheap,
suspecting it earns the expensive tier.

### Tier 0 — input adequacy · no model call
Resolved-note length below the dataset's 5th percentile; truncation (mid-sentence cut);
EHR template artifacts as a section's *only* content; null order/med summaries; the
discriminating column missing for the axis being judged; near-duplicate inputs.
Disposition `upstream-input`. Reuses `core.dataset.check_note_content`.

### Tier 1 — self-consistency invariants · no model call
The output already contradicts itself in machine-checkable ways. Each localizes on its own:

1. **Prompt-vs-code divergence prod already computes and throws away.**
   `run_two_stage_calculations` re-derives DATA points from the LLM's own sub-entity
   counts, compares to the LLM's declared `data_level`, logs
   `"DATA level mismatch — LLM: %s, computed: %s"`, then uses the computed value. An
   exact, free detector of the LLM misapplying the DATA table, going to a log nobody
   reads.
2. **Rule replay on the axes with no recompute.** COPA and RISK are accepted from the LLM
   directly. Re-implement the prompt's decision table over the LLM's *own* booleans and
   compare to its declared level. This is the split the naive design wants: booleans right
   + level wrong → aggregation, address is the rule table; booleans wrong vs the note →
   extraction, address is the criterion text. **One detector, two distinct loci.**
3. **Citation groundedness.** Every `citations[].cited_text` must be a verbatim substring
   of the *assembled* input (rebuild it, or read the request out of `core/modelcache.py`,
   which stores request bytes content-addressed). Spot-checked one live ED encounter:
   **2 of 9 cited spans were not substrings** — one a stitched paraphrase presented as a
   quote. Clinic's ~23 `source_quote` fields are schema-defined as verbatim substrings —
   same check, bigger surface.
4. **Evidence/claim polarity.** Boolean `true` + empty `evidence[k]` = unsupported claim;
   `false` + non-empty evidence = contradiction.
5. **Internal arithmetic.** `tests_ordered_count` vs `len(tests_ordered)`, ditto external
   notes and prior tests reviewed.
6. **Output-format failures.** `stop_reason == "max_tokens"` (truncated structured
   output), `llm_raw[node].error != null`, and the `risk_level == "UNDETERMINED"` sentinel
   prod sets on a null risk level. Cheap, currently uncounted.
7. **Cross-node override.** Pass 2 (`ed-pro-scoring`) receives the pass-1 DATA/RISK
   questionnaire text. Where its booleans contradict pass 1's answers, pass 2 overrode
   pass 1 — locus is the pro prompt, and it is invisible from the final code.
8. **Standing prompt-vs-code diff, no encounter needed.** Live instance: the clinic system
   prompt carries "MERCY RULE D" while `apply_v1_post_processing` applies Rule C only.
   Enumerate the rules the prompt states, enumerate what the code implements, diff.

Tier 1 has a property no LLM tier has: **it is right about the inconsistency by
construction.** It can still be wrong about whether the inconsistency changed the final
code — so every row carries `changes_output: bool` from replaying the deterministic tail.

### Tier 2 — dissent mining · no new model calls
Per axis: the vote distribution and its normalized entropy. ED's `pro_votes` (currently
consumed only as a binary gate in `ed/gate.py`); clinic's three votes (`--save-node-results`
already persists them); and across K seeded runs.

> For a 4–5 rung ordinal, **the label set *is* the set of semantic equivalence classes**, so
> entropy over that distribution is semantic entropy computed *exactly* — no clustering, no
> sampling approximation, no probes. The expensive part of that literature is free here
> because the output space is tiny. Worth saying out loud in any write-up.

Cheap extensions: the verifiers already return COPA/DATA/RISK and the gate discards them
(PRO-only); clinic has no cross-family verifier at all.

**Failure mode to write down:** correlated errors. Three models with overlapping training
agree on the same wrong answer and unanimity reads as confidence. Tier 2 is a *ranking*
signal, never an accuracy claim.

### Tier 3 — metamorphic testing · new calls, no judge
The strongest reference-free idea, absent from the naive design. Perturb the input in a way
whose correct effect is known a priori; check the output moves as required. No GT, no
judge, and the result is **causal rather than a self-report**.

- **Invariance** — paraphrase, reorder sections, change name/DOB/provider, strip template
  noise → the level **must not move**. Any move is a defect, full stop.
- **Directional monotonicity** — delete the span the model itself called decisive → the
  level must drop or it must cite different support. Add a documented qualifying element →
  must not drop.
- **Sufficiency** — feed *only* the cited spans. Same level → citations are sufficient.
  Different → it was using uncited context and the citation set isn't the real basis.

This is what turns "decisive context" from a claim into a test, and it is the input-level
analogue of prompt ablation — the only tier below that establishes causation.
**Templated perturbations first**: a generated paraphrase that silently changes clinical
meaning turns an invariance test into a false positive, and there is no GT to catch it.

### Tier 4 — decomposed criterion judging · blinded, cross-family
Judge the ~40 booleans, not the code. Three separate calls; the separation *is* the design:

1. **Blind extraction** — different family, shown the input and criterion list, **never
   shown our answer**: which criteria does this documentation support, decisive span for
   each? Blinding is what prevents anchoring, and skipping it is what makes reference-free
   judges generous.
2. **Entailment** — for each criterion we set true, does the cited span entail it? For each
   false, does the input contradict that?
3. **Conflict enumeration** — three types, kept distinct because they route differently:
   our span vs the input (groundedness, tier 1) · our criterion vs the blind extractor's
   (candidate error) · criterion vs criterion inside our own output (e.g.
   `prescription_drug_management: true` with `disposition: discharge` and nothing
   prescribed).

Aggregation stays deterministic — run the real `run_two_stage_calculations` over the
judge's booleans. So a disagreement arrives **pre-localized to a criterion**, which is a
prompt address, not a category.

**Directional prompting, never symmetric.** Not "is this correct?" but the rung boundary
being tested: *"is there documented support for RISK=Moderate, or does the documentation
only support Low?"* The compliance question is one-sided (over-coding on the billed axis);
the detector should inherit that asymmetry.

### Tier 5 — blinded re-code + adjudication · most expensive, last
A cross-family model codes from scratch, blind to our output. Disagreements only go to a
third adjudicator that sees both rationales with **arm order randomized and identity
hidden**. Verdict is `ours | theirs | ambiguous`.

`ambiguous` is not a hedge — it is the label-ambiguity population, the same one that
poisons GT-based eval, and it belongs in the `label-or-standard` disposition.

### Tier 6 — aggregation, calibration, operating point
- **Combine without GT** — Dawid–Skene-style label model over detector votes (estimates
  each detector's confusion matrix from agreement structure alone). Where labels exist,
  prefer supervised stacking and use the label model only for unlabelled extrapolation.
  **Model dependence explicitly**: tier 1's citation check and tier 4's entailment check
  are not independent, and pretending otherwise inflates confidence exactly where they
  co-fire.
- **Calibration gates shipping.** Per tier and combined, against the labelled slice:
  precision, recall, lift over random ordering, queue AUC. **Hold one dataset out
  entirely** — tuned and validated on `qh-0731-dev-set-93` is worth nothing. Reference-free
  judges need reference-aware calibration on a sample first; we have the sample.
- **Operating point, not a score dump.** Conformal risk control → *"flag the top k%, catch
  ≥X% of errors, 90% confidence"*, finite-sample valid. Makes the cost trade explicit: a
  false flag costs coder minutes, a missed over-code is compliance exposure. Say which one
  the threshold is tuned against.
- **PPI for population numbers.** Prediction-powered inference combines the small labelled
  sample with the large auto-judged set and is unbiased **regardless of the judge's error
  profile** — the labelled sample measures the judge's systematic error and corrects it.
  The only honest route from a judge to a number in a report. CIs must still resample
  **encounters**, not encounter-seed rows (locked by `scripts/metrics_selftest.py`).

## Two failure modes to design against from day one

**Goodhart.** Fix prompts against detector-flagged errors and the detector stops measuring
anything. Gating detectors frozen and version-pinned; iteration detectors separate; any
auto-eval-motivated prompt change validated on human labels before it ships.
"Never pool datasets" generalizes — in-sample-to-the-detector is a new way to be in-sample.

**Correlated blindness.** Every LLM tier shares the generator's blind spots to some degree.
This bounds what the feature can ever claim, and it is *the* reason tiers 0–3 come first:
they are the only ones whose evidence is independent of any model's judgement.

## Contract highlights

- Findings mirror **`core.dump_errors`' row shape** minus GT, plus
  `{detector, tier, score, evidence, changes_output}`. `core.autoeval` is `dump_errors`
  without `gt.csv`; whatever reads one reads the other.
- Every row carries a **disposition prior** from the existing closed set
  (`system` | `upstream-input` | `label-or-standard` | `not-reproducible`) — a *prior*,
  since only a human-confirmed disposition enters an RCA. **No second taxonomy.**
- A finding with no pointer to an intermediate is not emitted (same rule the RCA skill
  enforces).
- Confirmed findings promote into `causes.json` unchanged, so they enter stage 3 through
  the existing door and reach the changelog at stage 4.
- `calibration.json` is part of the artifact. Findings whose detectors have no calibration
  entry are a draft.
- **PHI**: findings + perturbed-note intermediates carry verbatim note text → local-only,
  never committed, never synced. Encounter ids are fine.

## Build order

1. Tier 1 detectors **1 + 3 + 6** — highest value per line, zero marginal cost, and #1
   recovers a signal prod already computes and discards.
2. Tier 2 dissent mining over runs that already exist.
3. **Calibrate on the labelled slice before building any LLM tier** — that number decides
   whether tiers 4–5 are worth building at all.

## Research grounding

- [LLM Judges Can Be Too Generous When There Is No Reference Answer](https://arxiv.org/abs/2607.12885) — the over-crediting result, and the calibrate-with-references-first recommendation.
- [Large Language Models Cannot Self-Correct Reasoning Yet](https://arxiv.org/abs/2310.01798) (ICLR 2024) — intrinsic self-correction doesn't work without external feedback; gains in prior work came from oracle labels.
- [When Can LLMs Actually Correct Their Own Mistakes?](https://direct.mit.edu/tacl/article/doi/10.1162/tacl_a_00713/125177/When-Can-LLMs-Actually-Correct-Their-Own-Mistakes) (TACL) — verification beats generation *only for decomposable responses*. This is the precondition tier 4 relies on.
- [Detecting hallucinations using semantic entropy](https://www.nature.com/articles/s41586-024-07421-0) (Nature) — the tier 2 basis; note the closed-label simplification above.
- [Statistically Reliable LLM-Based Ranking Evaluation via PPI](https://arxiv.org/abs/2606.05308) · [Stratified PPI for Hybrid Evaluation](https://arxiv.org/html/2406.04291v1) (NeurIPS 2024) — unbiased population estimates from a small gold set + a large judged set.
- [Conformal Selective Prediction with General Risk Control](https://arxiv.org/html/2603.24704v1) · [Cost-aware deferral for clinical triage](https://www.nature.com/articles/s41598-026-40637-w) — the operating point.
- [Language Models in the Loop: Prompting into Weak Supervision](https://dl.acm.org/doi/10.1145/3617130) — Dawid–Skene / label-model aggregation of noisy detectors.
- [LLM-assisted Clinical Coding Audit](https://www.medrxiv.org/content/medrxiv/early/2026/02/12/2025.08.24.25334321.full.pdf) · [ICDAGENT](https://aclanthology.org/2026.acl-long.643.pdf) · [CPTCoder](https://aclanthology.org/2026.acl-demo.60.pdf) (ACL 2026) — closest prior art in coding specifically; ICDAGENT's finding that a *critical agent* improves accuracy is the tier-4/5 argument.
- [LLMs-as-Judges survey](https://github.com/CSHaitao/Awesome-LLMs-as-Judges) — general bias inventory (self-preference, position, verbosity).

## Related

- [[rca-coding logic]] — the taxonomy this reuses, and the auto-judge concerns from that angle
- [[Coding Pod]] · [[Prompt Tuning Runbook]] · [[Evaluation - Tuning Process]]
- Repo: `features/llm-auto-eval/plan.md`, `core/dump_errors.py`, `ed/gate.py`,
  `ed/verifiers.py`, `core/modelcache.py`, `docs/EVALUATION.md`, `docs/ITERATION.md`
