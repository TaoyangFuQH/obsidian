---
updated: 2026-08-17
tags: [project, coding-pod, eval, auto-eval, llm-as-judge, calibration, ws-b0]
---
# WS-B0 — the judge calibration protocol, concretely

The first thing to build. Adapts [Kranti & Vajjala's](https://arxiv.org/abs/2607.12885)
two-stage protocol (see [[LLM as a judge SOTA]] §2) to our surface. Answers one question we
have never asked: **is a judge model competent on ED MDM at all?**

Feeds [[auto eval proposal]] WS-B; gates [[tier 4 criterion judging]].

## What this stage is for — and what it is NOT for

**It is a screening instrument for the judge *model*. It is not a tuning loop for the judge
*prompt*.** Getting this backwards is the main way the step gets ruined, so it is stated first.

Four goals, in order:

1. **Disqualify incompetent judges** before anything is spent on WS-C. This is the primary
   purpose. In the source paper this is exactly how the protocol is used — a judge that
   accepted ~60% of known-wrong answers was thereby ruled out for reference-free use on that
   task. Nothing was tuned; a model was rejected.
2. **Produce `q₀` and `q₁`** — the judge's specificity and sensitivity. These are not merely
   diagnostic: they are the **parameters of the reporting estimator**
   `θ̂ = (p̂ + q̂₀ − 1)/(q̂₀ + q̂₁ − 1)` ([[LLM as a judge SOTA]] §6). Without them no
   judge-derived number can be reported honestly. This stage is where that estimator gets its
   inputs.
3. **Localize the failure** — separate *judge incompetent* from *prompt broken* from *task not
   decidable from the note*. The `CANNOT_ASSESS` rate isolates the third, which is an
   `upstream-input` finding rather than a judge finding.
4. **Quantify self-preference** — the Claude arm against the cross-family arms, on
   **pass 1b** items (see § Judge arms; pass 1a measures leniency, not self-preference).

### Where prompt work legitimately enters, and where it becomes Goodhart

| | verdict |
|---|---|
| **Fixing a broken prompt** — `accept(C1)` is low, so the judge is rejecting *correct* codings; cause is likely a prompt bug (wrong rubric text, missing level definitions, ambiguous instruction) | **legitimate.** This is debugging an apparatus |
| **Tuning wording to maximize the C1−C2 gap** | **not legitimate.** Iterate against these 71 rows and they become in-sample; accept rates stop measuring judge competence and start measuring prompt fit to 71 charts — and those inflated `q₀`/`q₁` then feed the estimator and produce a confidently wrong number |

Same rule [[auto eval proposal]] §4 C-7 applies one level down (*gating detectors are frozen
and version-pinned; iteration detectors are separate*), applied here to the judge itself.

**So the protocol needs a dev/holdout split.** Iterate the prompt on a dev slice; measure the
*reported* calibration on a frozen holdout the prompt never saw. This is a third argument for
starting on `pro`: at n=400 a 100 dev / 300 holdout split is affordable. At n≈71 per MDM axis
neither half is — which is itself worth knowing, because **any prompt iteration on the MDM
axes burns the only labels we have.**

Freeze the judge prompt before touching the holdout, and version-pin it with the fingerprint
from `core/prompt_source.py`, so the calibration entry records which prompt it belongs to. **A
`calibration.json` whose prompt hash does not match the prompt in use is stale by
construction.**

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

Arm C is not a candidate judge — it is an instrument.

**⚠ But be precise about what it measures.** C1/C2 items are built from **GT levels**, not from
our pipeline's output, so comparing arm C against A/B on them measures **leniency**, not
self-preference. Self-preference is specifically *inflated credit for its own output*, and
measuring it needs items that **are** our predictions.

So Stage 1 has **two passes**, and the second is what the earlier drafts were missing:

| pass | items built from | measures |
|---|---|---|
| **1a** | GT + synthetic rung perturbations | **discrimination and leniency** — is the judge competent at all |
| **1b** | our pipeline's *own* predicted levels on the same encounters | **self-preference** — arm C's accept rate vs arms A/B on identical items |

Pass 1b is cheap (one item per encounter per arm, ~71×3 per axis) and it is the only one that
speaks to the [No Free Labels](https://arxiv.org/html/2503.05061v1) finding. We have never
measured it on our surface, and clinic's design depends on the answer.

Both verifier keys already exist and `ed/verifiers.py` already calls both providers, so the
data path and the PHI review for it are precedent, not new.

## Statistics

- **Accept rate per condition**, paired by encounter (the same encounter appears in C1 and
  every applicable C2 stratum), so use **McNemar / paired bootstrap**, not two independent
  proportions.
- **Calibration gap = accept(C1) − accept(C2ₛ)** per stratum s. **This is the headline, and a
  raw accept rate on its own is meaningless.** A judge that answers SUPPORTED to everything
  scores 100% on C1 and is worthless; it will also score ~100% on every C2 stratum. Read the
  columns *against each other*, never the C1 column alone. High C1 + high C2 = **lenient**,
  not good.
- **`q₀` is stratum-specific and must not be collapsed carelessly.** Specificity
  `q₀ = P(reject | wrong)` depends on *how* wrong the shown level is — it may be ~0.3 at one
  rung and ~0.95 at two. Either report `q₀` per rung distance, or compute a single `q₀`
  **weighted by how often our pipeline actually errs by one rung vs two**, read off the
  rung-distance distribution in the scoring output. Feeding one unweighted `q₀` into
  `θ̂ = (p̂ + q̂₀ − 1)/(q̂₀ + q̂₁ − 1)` misstates the correction.
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
| arm C ≫ arms A/B **on pass 1b** | self-preference confirmed on our surface; **clinic must not use a Claude judge** |
| the winning arm's gap is within ~12pp of a rival's | **at n≈71 that is noise, not a ranking.** Do not declare a winner — run both cross-family arms and use their agreement |

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

---

# The minimal end-to-end run, for ED

One encounter threaded through, so the shape is concrete. Two stages: **prove the judge works,
then use it.** Encounter `944069156` — GT `risk = moderate`, `copa = moderate`, `data = none`,
`pro = 99284`.

## Stage 1 — calibrate (labelled data only, no pipeline output needed)

For each of the 71 encounters with a `gt_risk_level`, nudge the GT level up and down. For
`944069156` (GT = moderate) that is four items:

| item | level shown | truth | judge should say |
|---|---|---|---|
| C1 | moderate | correct | SUPPORTED |
| C2+1 | high | wrong — over-code | NOT_SUPPORTED |
| C2−1 | low | wrong | NOT_SUPPORTED |
| C2−2 | minimal | very wrong | NOT_SUPPORTED |

(`C2+2` is out of range from moderate, so it is dropped — not invented.)

Each item is one blinded call: *note + RISK rubric + "is there documented support for
RISK = high?"* The judge never sees GT, our prediction, or which condition it is in.

**Measured item counts** across the three MDM axes, verified against `gt.csv`:

| axis | labelled | items | C1 | C2+1 | C2−1 | C2+2 | C2−2 |
|---|---|---|---|---|---|---|---|
| copa | 71 | 284 | 71 | 57 | 71 | 14 | 71 |
| data | 72 | 283 | 72 | 58 | 70 | 26 | 57 |
| risk | 71 | 297 | 71 | 61 | 71 | 25 | 69 |
| **total** | | **864** | | | | | |

864 items × 3 arms = **2,592 calls** for pass 1a. One afternoon.

Then read the accept rates — ⚠ **illustrative, not measured**:

| arm | C1 | C2+1 | C2−1 | C2−2 | **gap (C1 − C2+1)** |
|---|---|---|---|---|---|
| GPT-5.4 | 88% | 71% | 34% | 6% | 17pp |
| Gemini | 84% | 65% | 29% | 9% | 19pp |
| Claude | 93% | 86% | 51% | 12% | **7pp** |

**Read the gap, never the C1 column.** Claude has the *highest* C1 and is the *worst* judge
here — it accepts more of everything, which is leniency, not competence. And 17pp vs 19pp is
inside the ~12pp noise band at this n, so the honest conclusion is **"either cross-family arm,
not Claude"**, not "GPT-5.4 wins".

Three decisions come out, and none of them is a tuned prompt:

1. **Use a cross-family arm** (GPT-5.4 and/or Gemini), never Claude.
2. **Do not ask for levels.** C2+1 at 65–71% means a one-rung over-code slips through two times
   in three — AutoRubric's ordinal finding, reproduced on our data.
3. **Keep `q₁ ≈ 0.88` and `q₀` per rung distance** (≈0.29 at one rung, ≈0.94 at two) for the
   reporting estimator.

## Stage 2 — use the judge on the surface that survived

Levels are out, so drop to the **criterion booleans** — the layer AutoRubric measured at
κ 0.642. This runs on any encounter, labelled or not. For `944069156` our pipeline emitted,
among the 18:

    prescription_drug_management         = true
    controlled_substance_iv             = false
    life_or_function_threatening         = false
    behavioral_health_safety_assessment  = true

Ask the cross-family judge **one blinded call per criterion** — note + that single criterion's
definition, never our answer — then diff:

| criterion | ours | judge (blind) | |
|---|---|---|---|
| prescription_drug_management | true | true | agree |
| controlled_substance_iv | false | false | agree |
| life_or_function_threatening | false | false | agree |
| behavioral_health_safety_assessment | true | **false** | ← **conflict** |

That conflict is the output, and it has an **address**: encounter `944069156`, node
`ed-risk-questionnaire`, field `behavioral_health_safety_assessment`, plus the span the judge
did and did not find. That is something a prompt owner can act on — unlike "this encounter
looks wrong".

## Stage 3 — what ships

Rank all 402 encounters by **reliability-weighted** conflict count, hand a coder the top ~15%,
and state the operating point: *"flagged 60 encounters; judge sensitivity 0.88, specificity
0.29 at one rung on the held-out calibration set; lift over random ordering = X."*

## Why Stage 1 cannot be skipped

Without it, Stage 2 still runs and still emits a tidy conflict list — you simply cannot tell
whether a conflict is our error or the judge's. Stage 1 is what earns the sentence "GPT-5.4
disagreeing on this criterion means something", and it is what stops you building the
level-judge that the calibration proves cannot work.

Two caveats our own tier-4 measurement already established, which bound Stage 2:

- **Our booleans self-flip 10–18% across reruns** on some criteria
  (`behavioral_health_safety_assessment` at 18.0%), so part of any conflict is our own
  instability rather than an error. Rank on conflict *net of* self-flip rate.
- **15 of the 18 booleans do not feed the level computation at all.** So a criterion conflict
  buys a prompt address but **not** a corrected code — until **C0** (the COPA/RISK schema
  completion) lands. See [[tier 4 criterion judging]] § C.

---

# Computing the ranking weights

Referenced from Stage 3 above ("reliability-weighted conflict count"). This is how that weight
is actually calculated, and it includes one quantity that **cannot** be estimated without
labels — stated plainly rather than fudged.

## Functional form

A conflict is evidence, so weigh it as a **log likelihood ratio**. For criterion `c`:

    w(c) = log [ P(conflict | we are wrong) / P(conflict | we are right) ]
                        detection d_c              false alarm e_c

    encounter score = Σ w(c)  over the criteria that conflicted

That is a Naive-Bayes log-odds sum, and it is what the Dawid–Skene label model
([[auto eval proposal]] tier 6 / 6.1) reduces to once per-detector error rates are known.

## The denominator `e_c` — computable today, no labels

A spurious conflict can be manufactured by noise on **either** side, and both sides are
measurable without ground truth:

| term | what it is | source |
|---|---|---|
| `s_c` | **our** self-flip rate on criterion `c` across seeds | clinic `repro-seed{1,2,3}` already gives **K=9 on 63 encounters**; [[tier 4 criterion judging]] already measured **10.2%** and **18.0%** on two criteria |
| `j_c` | **judge** instability on `c` | arm A vs a repeat arm A call, and arm A vs arm B. Pure judge noise, needs no GT |

Assuming the two noise sources are independent:

    e_c = 1 − (1 − s_c)(1 − j_c)   ≈  s_c + j_c   for small values

Worked, using the two real measured `s_c` values:

| criterion | `s_c` | `j_c` (assumed) | `e_c` | relative weight `log(0.7 / e_c)` |
|---|---|---|---|---|
| a stable criterion | 0.02 | 0.05 | 0.069 | **2.31** |
| `behavioral_health_safety_assessment` | **0.18** | 0.10 | **0.262** | **0.98** |

A conflict on the stable criterion carries **~2.4× the evidence**. And read the second row
directly: **~26% of conflicts on that criterion are manufactured by noise alone.** That is the
concrete reason unweighted conflict counting ranks by instability rather than by error.

## The numerator `d_c` — the wall

`P(conflict | we are wrong)` is the judge's true detection rate on criterion `c`, and it
**cannot be estimated without criterion-level labels.** `gt.csv` labels *levels and codes*, not
the 18 booleans. Three options, increasing cost:

| option | what it gives | verdict |
|---|---|---|
| **Hold `d_c` constant** across criteria → `w(c) = −log(e_c) + const` | a purely noise-discounted ranking | **the honest v1.** Computable today, no labels, and it fixes the actual defect |
| **Borrow `q₁`** from the Stage-1 level calibration as a prior | per-criterion `d_c` under an assumption | cheap and weak — state the assumption, do not hide it |
| **Adjudicate a sample of conflicts** with a coder | a measured `d_c` | the real fix, and **far cheaper than labelling encounters** — a coder looks only at flagged criteria, not whole charts. ~50 adjudications per high-volume criterion |

Note the third row is the *cheap* label ask that [[auto eval proposal]] §3.1 asks for, arriving
by a different route: adjudicating conflicts is stratified label acquisition, concentrated
exactly where information is highest.

## Two corrections that are not optional

**Smoothing.** Six of eighteen criteria have base rates under 2.5% — ~10 positives in 402
encounters — so a raw per-criterion `s_c` or `j_c` is noise. Shrink toward the pooled rate
(empirical Bayes, or Laplace as a floor) and **print the per-criterion `n` beside the weight**,
same discipline as the prevalence-beside-κ rule in [[LLM as a judge SOTA]] §8.

**Independence is false.** Log-odds summing assumes criteria fail independently. They do not:
the groundedness and entailment checks co-fire by construction, and criteria within one axis
share a single note-reading step. Unmitigated, this over-counts precisely where several
criteria trip together — the failure [[auto eval proposal]] §3 tier 6.1 already names. Mitigate
by capping the per-axis contribution, or by grouping correlated criteria and counting the group
once.
