---
updated: 2026-08-17
tags: [project, coding-pod, eval, auto-eval, llm-as-judge, calibration, ws-b0]
---
# WS-B0 — the judge calibration protocol, concretely

The first thing to build. Adapts [Kranti & Vajjala's](https://arxiv.org/abs/2607.12885)
two-stage protocol (see [[LLM as a judge SOTA]] §2) to our surface. Answers one question we
have never asked: **is a judge model competent on ED MDM at all?**

Feeds [[auto eval proposal]] WS-B; gates [[tier 4 criterion judging]].

## Why this first

It is the only step that is **cheap, runnable today, and capable of killing the programme.**
Three properties:

- **It needs no new labels** — it runs on `gt.csv` as it stands.
- **It needs no pipeline run.** This is the part that surprised me. C1/C2 uses the *GT* level
  and *synthetic perturbations* of it — never our prediction. So it measures the **judge**, in
  isolation, and is not confounded by our own output. All it needs is the note plus `gt.csv`.
- **A bad result is decisive.** If a judge accepts one-rung over-codes at a high rate, it
  cannot rank a review queue on the compliance question, and WS-C should not be built.

## The one design change from the paper

The paper has a single C1 (known-correct) and a single C2 (known-incorrect). **On an ordinal
axis that conflates two completely different questions**, so C2 must be **stratified by rung
distance**:

| condition | what the judge is shown | a competent judge should |
|---|---|---|
| **C1** | the **GT** level | accept ≈ 100% |
| **C2(+1)** | GT **one rung up** — the over-code direction | reject — **and this is the one that matters** |
| **C2(−1)** | GT one rung down — under-code | reject |
| **C2(±2+)** | GT two or more rungs away | reject ≈ 100%; failure here means incompetent, full stop |

This turns one number into a **detection curve over rung distance**, which is exactly what
[[LLM as a judge SOTA]] §3 says is in doubt: AutoRubric measured ordinal 3–5-level judging at
only **38–58% exact** agreement. C2(+1) tests that finding on *our* rubric and *our* data, and
its output is the operational sentence we actually need:

> "The judge detects a one-rung over-code X% of the time (95% CI …)."

`C2(±2+)` is the **sanity floor**. If a judge cannot reject a two-rung error it is not reading
the chart, and nothing downstream is worth running.

## What the judge is asked

Directional and one-sided, never "is this correct?" — matching the compliance asymmetry
already in `docs/EVALUATION.md`:

> Here is the ED documentation. Here is the RISK rubric. **Is there documented support for
> RISK = Moderate, or does the documentation only support a lower level?**
> Answer: `SUPPORTED` / `NOT_SUPPORTED` / `CANNOT_ASSESS`, with the decisive span.

Four rules, each load-bearing:

1. **One proposed level per call.** Never show two and ask which is better — that leaks the
   comparison and invites position bias.
2. **The judge never learns which condition it is in**, never sees GT, never sees our
   prediction. Randomize condition order across the run.
3. **`CANNOT_ASSESS` is first-class** (AutoRubric's finding) and is reported separately — it
   must not be silently folded into either accept or reject.
4. **Require a span.** A verdict with no pointer into the note is dropped — same rule the RCA
   skill enforces, and it is the mitigation for evaluator hallucination.

**Rubric text comes from the prod prompt** (`copa_prompt.py` / `data_prompt.py` /
`risk_prompt.py`), resolved through `core/prompt_source.py` so it is snapshotted and
fingerprinted. A judge graded against a paraphrased rubric measures the paraphrase.

## The data, verified on disk

`ed/dataset/washington-402/gt.csv`, n=402 rows:

| axis | labelled | GT distribution | note |
|---|---|---|---|
| `gt_professional_code` | **400** | 99284: 239 · 99285: 83 · 99283: 72 · 99282: 5 · 99291: 1 | **5.6× more power than the MDM axes** |
| `gt_data_level` | 72 | moderate 32 · high 14 · minimal 13 · low 11 · none 2 | full 5-rung spread |
| `gt_copa_level` | 71 | moderate 43 · low 14 · high 14 | **no `none`/`minimal` at all** |
| `gt_risk_level` | 71 | moderate 36 · low 23 · high 10 · minimal 2 | |

Three consequences that change the plan:

- **Start with `pro`, not the MDM levels.** 400 labelled rows is the difference between a
  usable interval and a shrug. Asking "is 99284 supported by this documentation?" is
  *verification of a given code*, not generation — so it stays on the safe side of the
  49.8%-CPT-exact-match finding. And it is the axis that actually bills.
- **Boundary cases must be handled explicitly.** A GT of `high` has no +1 rung; `none` has no
  −1. Those encounters drop out of that stratum — record the per-stratum n rather than
  silently rebalancing.
- **The tails are unusable.** `99291` (n=1) and `99282` (n=5) cannot support a stratum.
  State it; do not quietly pool them.

## Judge arms — cross-family is the point

ED's generator is `claude-sonnet-4-6`, so:

| arm | model | purpose |
|---|---|---|
| A | **GPT-5.4** (`AZURE_GPT_54_OPENAI_*`) | cross-family judge |
| B | **Gemini-2.5-pro** (`VERTEX_PROJECT` + ADC) | second cross-family judge, different provider |
| C | **Claude** (same family as generator) | **the self-preference measurement** |

Arm C is not a candidate judge — it is the instrument that *quantifies* the bias. The gap
between arm C and arms A/B on identical items is our own estimate of the self-preference
effect that [No Free Labels](https://arxiv.org/html/2503.05061v1) measures as an inflated
false-positive rate. We have never measured it on our surface, and clinic's design depends
on the answer.

Both verifier keys already exist and `ed/verifiers.py` already calls both providers, so the
data path and the PHI review for it are precedent, not new.

## Statistics

- **Accept rate per condition**, paired by encounter (the same encounter appears in C1 and
  every applicable C2 stratum), so use **McNemar / paired bootstrap**, not two independent
  proportions.
- **Calibration gap = accept(C1) − accept(C2ₛ)** per stratum s. This is the headline.
- **Bootstrap resamples encounters**, and a resampled encounter brings all its conditions —
  the invariant `scripts/metrics_selftest.py` already locks. Do not resample judge calls.
- **Report raw agreement + Cohen's κ + Gwet's AC1 + marginal prevalence together**, per
  [[LLM as a judge SOTA]] §8. With `copa` at 43/71 moderate, κ alone will be misleading.
- **Power, stated up front:** at n=71 a single accept rate has a 95% CI half-width of ~11.6pp
  (worst case, p=0.5); at n=400 it is ~4.9pp. Pairing tightens the *gap* estimate further.
  Compute the achieved MDE and put it in the artifact — `docs/EVALUATION.md` forbids a null
  without one, and this is the same defect.

## Kill switches — decide these before running

Written down first so the result cannot be rationalized afterwards:

| observation | conclusion |
|---|---|
| `accept(C2 ±2+)` is materially above 0 | judge is not reading the chart. **Stop.** No tier of WS-C is worth building on this judge |
| `accept(C1)` is low | the judge rejects *correct* codings — it will bury the queue in false flags; the rubric prompt is wrong before the judge is |
| `accept(C2 +1)` ≈ `accept(C1)` | judge cannot resolve one rung — **exactly AutoRubric's ordinal finding.** Level judging is dead; go to the binary criterion surface, which makes **C0** (the COPA/RISK schema completion) the critical path |
| `CANNOT_ASSESS` rate is high | either the rubric is not decidable from the note (an `upstream-input` finding, valuable on its own) or the prompt is unclear |
| arm C ≫ arms A/B | self-preference confirmed on our surface; **clinic must not use a Claude judge** |

Note that three of these five outcomes are *useful findings* rather than failures. That is
the property that makes this the right first step.

## Where the code goes

This is a **measurement**, so it is an experiment first and engine second (`CLAUDE.md`):

    ed/experiments/judge-calibration/
      plan.md            ← hand-written FIRST; non-default experiment, so no template
      calibrate.py       ← builds the C1/C2 item set, runs the arms, writes items.jsonl
      score.py           ← accept rates, paired bootstrap, κ/AC1/prevalence, MDE
      results/           ← local-only
      reports/judge-calibration-washington-402.md

It graduates into `core/autoeval/calibrate.py` only once it has run and the shape has stopped
moving. Two dependencies:

- **`core/judge.py` must land first** — it is on `origin/citation-eval-on-main`, unmerged
  (WS-A1). `StructuredLLMJudge` is already the right primitive: forced tool, temperature 0,
  and it raises on `stop_reason == max_tokens` instead of returning a partial `{}`. Cherry-pick
  it or land the branch; do not write a second one.
- **Route judge calls through `core.modelcache`** so a re-run replays instead of re-billing.
  The interface is there (`request_sha`, `put`/`get`, `run_signature`), and it stores the
  request bytes verbatim, which is also what makes a judge verdict auditable months later.

## Sketch

```python
# calibrate.py — the item set is the whole trick; everything else is plumbing.
LEVELS = ("none", "minimal", "low", "moderate", "high")   # ed/profile.py::_LEVELS

def items_for(enc_id: str, note: str, gt_level: str, axis: str):
    """One encounter -> up to 4 blinded items. Condition label is held OUT of the prompt."""
    i = LEVELS.index(gt_level)
    yield dict(enc=enc_id, axis=axis, shown=gt_level, cond="C1", rung_delta=0)
    for delta, cond in ((+1, "C2+1"), (-1, "C2-1"), (+2, "C2+2"), (-2, "C2-2")):
        j = i + delta
        if 0 <= j < len(LEVELS):                    # boundary: no synthetic rung invented
            yield dict(enc=enc_id, axis=axis, shown=LEVELS[j],
                       cond=cond, rung_delta=delta)

# shuffle across encounters AND conditions so the judge cannot infer the condition
# from call order or from the shown-level distribution.
```

The judge prompt carries only `note` + rubric + `shown` — **never** `cond`, `rung_delta`, the
GT, or our prediction.

## PHI

The prompt contains verbatim note text, so judge calls send PHI to Azure and Vertex. ED
already does this for its verifiers, so the path is precedent — but note two specifics:

- **`gt.csv` carries an `mrn` column.** The item builder must select `pat_enc_csn_id` and the
  level columns only; never pass the row through wholesale.
- `result_json` in a run dir carries `mrn`, `patient_name`, `patient_dob`. If the note is
  sourced from a run dir rather than `input.csv`, take `result_json["note"]` and nothing else.
- `items.jsonl` and all results are **local-only** — never committed, never synced. The
  rendered report is population-level, encounter ids at most.

## First move

Smoke-test on ~20 encounters × arm A × all conditions before the full set — the point is to
catch a broken prompt or auth path, not to save money. Then run `pro` (n=400) across all three
arms, because it has the power; the MDM axes follow and are read as suggestive at n≈71.
