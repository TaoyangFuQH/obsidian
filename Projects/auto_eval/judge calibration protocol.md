---
updated: 2026-08-17
tags: [project, coding-pod, eval, auto-eval, llm-as-judge, calibration, ws-b0]
---
# Introduction

A coding agent emits structured, billable decisions — an ordinal level per axis, a code per
encounter — whose correctness is established by human annotation. Annotation is scarce and slow,
covering a small fraction of throughput, so most of what the agent produces is never measured:
no triage order on a run, no visibility into defect classes outside the annotated slice, and no
signal on a candidate change until review returns weeks later. The natural remedy is a second
model judging the agent's output, but judges applied naively fail hardest where they would help
most. They **over-credit the answer placed in front of them**, and their agreement with human
annotators collapses **precisely on the instances they would themselves get wrong**
(κ 0.78 → 0.14; [[LLM as a judge SOTA]] §2). Because judge and agent are drawn from overlapping
training distributions, judge blindness is *correlated* with agent blindness — so an uncalibrated
judge yields a fluent, plausible, unfalsifiable artifact.

Two properties of the task make judging workable anyway. First, a judge's competence is
**task-specific and directly measurable** against the annotations already in hand: show it cases
known to be correct and cases known to be incorrect, and see whether it can tell them apart.
Second, the coding task is **decomposable** — the guideline is a closed set of criteria — so the
judge can be asked a bounded verification question ("does this rubric hold for this
documentation?") rather than the generation question ("what is the right code?"), which is the
task language models are measurably poor at (CPT exact-match ≈ 50%; ordinal levels 38–58% exact,
versus κ 0.642 on binary predicates; [[LLM as a judge SOTA]] §3).

The method follows in three stages, then deploys:

| stage | what it does | produces |
|---|---|---|
| **1 · Judge calibration** | quiz candidate judges on annotated instances | `accept(corrects)`, `reject(incorrects)` per judge → **judge weights**; unfit judges eliminated |
| **2 · Judging with rubrics** | one call per rubric per surviving judge, blind to the agent's answer and to annotations | a **rubric result table** per instance, plus **rubric weights** |
| **3 · Aggregation** | combine judge weights × rubric weights × rubric results | judge-quality diagnostics · a **per-instance score** · **defect classes** |
| **Auto-eval** | apply the calibrated judges to un-annotated instances | score as an annotation proxy · defect classes, label-free |

**Input:** per-instance documentation; a human-annotated slice, used only for calibration and for
validating the score; a rubric set; optionally the agent's own per-rubric output. **Output:**
calibrated judge weights, a per-instance score usable for review triage, and a per-rubric conflict
table that localizes systematic defects to a **specific criterion** rather than to individual
instances.

Two scope notes. Stage 1 **eliminates rather than selects** — every judge clearing the threshold
carries forward, because agreement *between independent judges* is what distinguishes a genuine
defect from a single judge's blind spot. And the method **ranks and localizes; it does not measure
accuracy.** A judge-derived accuracy figure inherits the judge's own error profile in a known
direction, so headline accuracy continues to come from human annotation, or from
prediction-powered inference over a small annotated anchor sample.

> **Terminology.** *Rubric* and *criterion* are used interchangeably — a single bounded predicate
> over the documentation. *Instance* and *encounter* likewise. § 3 uses the ED vocabulary
> (criterion, encounter, axis) because that is where the measurements were taken.

Applied to both products in [[auto eval rollout plan]]. Feeds [[auto eval proposal]] WS-B; gates
[[tier 4 criterion judging]]. Stage 1 adapts
[Kranti & Vajjala's](https://arxiv.org/abs/2607.12885) calibration/sensitivity protocol.

> **Reading order.** § 1 is the method. § 2 is a worked example on one encounter, with no
> caveats — read that first if the method reads abstractly. § 3 is the reference layer:
> measured numbers, statistics, and the failure modes.

---

# The method in three stages

## Stage 1 · Judge calibration

Evaluate the **capability of a judge**. Show the candidate judges the documentation, the agent's
result, and — as the exam key the judge never sees — the human annotation. A good judge has a high
accept rate on cases the annotation says are **correct** and a high reject rate on cases it says
are **incorrect**. Combine the two into one score to rank and pick the top judges.

| arm | `accept(corrects)` | `reject(incorrects)` | `J = a + r − 1` |
|---|---|---|---|
| GPT-5.4 | 88% | 29% | 0.17 |
| Gemini | 84% | 35% | **0.19** |
| Claude | 93% | 14% | 0.07 |

**⚠ Use the sum, not a noisy-OR.** `w = 1 − (1−a)(1−r)` saturates and rewards a high accept rate,
so on these same numbers it ranks **Claude first** (0.940 vs 0.915 / 0.896) — the most *lenient*
judge, which is the one to discard. The sum has a name: **Youden's J** (informedness),
`J = a + r − 1`, which measures discrimination above chance, is 0 for a judge that answers
everything the same way, and whose positivity `J > 0` is *exactly* the validity condition
`q₀ + q₁ > 1` for the bias-corrected estimator downstream. Read the two columns against each
other; never the accept column alone.

## Stage 2 · Judging with rubrics

With a list of manually designed rubrics — e.g. `has_chronic_severe_exacerbation` for COPA — make
**one call per rubric per surviving judge**, per instance, asking only whether that rubric holds.
Keep each rubric definition simple and single-purpose, and **the judge never sees the agent's
answer or the annotation.** Per-rubric output may be boolean / ordinal / categorical / `ambiguous`.
Each rubric also needs a **weight** — uniform, manually assigned (including negative), or learned
by logistic regression against human labels.

| rubric | weight | Opus 5 | Gemini-3-Flash | GPT-5.4 |
|---|---|---|---|---|
| R1 | 10.0 | Yes | Yes | Yes |
| R2 | 8.0 | moderate (0.75) | low (0.50) | high (1.00) |
| R3 | −15.0 | No | No | **Yes** |

**Two notes on this table.** Reliability varies sharply by output type — boolean is best
(87% exact, κ 0.642), ordinal is weak on exact agreement (38–58%) though strong adjacent, so
**decompose toward boolean wherever the guideline permits.** And *learned* weights overfit at our
n: 18 rubrics need ~180 error events (~900 instances at a 20% error rate) and we have 62–71
annotated rows, six rubrics below 2.5% prevalence — so regularize with nested CV, restrict to
high-prevalence rubrics, or fall back to uniform.

## Stage 3 · Aggregation

From the Stage-1 calibration table and the Stage-2 rubric tables, three outputs:

1. **Judge quality** — inter-judge correlation and per-rubric agreement. Doubles as the estimate of
   each rubric's judge instability.
2. **A per-instance score** — judge weights × rubric weights × rubric results, ranked, for review
   triage; validated against the annotated slice as lift over random ordering.
3. **Defect classes** — the same table aggregated down the *rubric* axis. One rubric conflicting
   across 40 instances is **one faulty prompt**, not 40 faulty instances.

## Auto-eval

Once judges are built with human annotations, apply them to instances **without** annotations: the
score serves as a proxy for annotation for triage, and the rubric results detect defect classes.
Note the asymmetry — **defect classes and the score's *ordering* transfer label-free; any
quantitative claim (lift, catch rate) does not** and must be marked as carried over rather than
measured.

---

# 1 · The method, specified in full

## Stage 1 · Judge calibration

A stage to evaluate the **capability of a judge**. Show each candidate judge the documentation,
the agent's result and — as the exam key it never sees — the human annotation. A good judge has a
high accept rate on cases the annotation says are **correct**, and a high reject rate on cases the
annotation says are **incorrect**:

| arm | `accept(corrects)` | `reject(incorrects)` | `w = a + r` |
|---|---|---|---|
| GPT-5.4 | 88% | 29% | 1.17 |
| Gemini | 84% | 35% | **1.19** |
| Claude | 93% | 14% | 1.07 |

*(Illustrative, not measured.)*

### The judge weight: use the sum, not the noisy-OR

Two candidate combinations suggest themselves, and **they disagree about which judge to keep:**

| arm | `1 − (1−a)(1−r)` | `a + r` |
|---|---|---|
| GPT-5.4 | 0.915 | 1.17 |
| Gemini | 0.896 | **1.19** |
| Claude | **0.940** ← ranks 1st | 1.07 ← ranks last |

The noisy-OR form saturates and rewards a high accept rate, so it **crowns the most lenient
judge** — exactly the one to discard. Use the **sum**, which has a name:

    J  =  accept(corrects) + reject(incorrects) − 1        (Youden's J, "informedness")

`J` measures discrimination *above chance*. It is 0 for a judge that answers everything the same
way — which is the failure mode a raw accept rate cannot see. And it coincides with something
needed downstream: `J > 0` is exactly the validity condition `q₀ + q₁ > 1` for the bias-corrected
estimator `θ̂ = (p̂ + q̂₀ − 1)/(q̂₀ + q̂₁ − 1)` ([[LLM as a judge SOTA]] §6). **The same quantity
that ranks judges gates whether the correction downstream is even defined.**

Read the two columns *against each other*, never the accept column alone.

### Refinement: stratify `reject(incorrects)` by error distance

On an ordinal axis a single `reject(incorrects)` conflates two very different questions, so build
the "incorrect" cases by perturbing the annotation a **known distance** and report the reject rate
per distance:

| condition | shown to the judge | a competent judge should |
|---|---|---|
| **C1** | the annotated level | accept ≈100% → `accept(corrects)` |
| **C2(+1)** | one rung up — over-code | reject — **the one that matters** |
| **C2(−1)** | one rung down — under-code | reject |
| **C2(±2+)** | two or more rungs away | reject ≈100%; failure means incompetent, full stop |

This turns one number into a **detection curve**, which is what makes the result operational:
*"the judge detects a one-rung over-code X% of the time (95% CI …)."* Weight the aggregate
`reject(incorrects)` by how often the agent **actually** errs at each distance — measured at
**56 one-rung to 1 two-rung** (§ 3.5), so the one-rung stratum dominates. `C2(±2+)` is therefore
a **sanity floor on the judge**, not a measurement of anything operational.

### What this stage is for, and what it is NOT for

**It is a screening instrument for the judge *model*. It is not a tuning loop for the judge
*prompt*.** Getting this backwards is the main way the technique gets ruined.

| | verdict |
|---|---|
| **Fixing a broken prompt** — `accept(corrects)` is low, so the judge rejects *correct* codings; cause is likely a prompt bug (wrong rubric text, missing level definitions, ambiguous instruction) | **legitimate.** Debugging an apparatus |
| **Tuning wording to maximize `J`** | **not legitimate.** Iterate against ~71 annotated rows and they become in-sample; the rates stop measuring competence and start measuring prompt fit, and the inflated `q₀`/`q₁` then corrupt the estimator |

Same rule as [[auto eval proposal]] §4 C-7 (*gating detectors frozen and version-pinned;
iteration detectors separate*), applied to the judge itself. **So Stage 1 needs a dev/holdout
split:** iterate the prompt on a dev slice, measure the reported calibration on a frozen holdout
the prompt never saw. Affordable on ED `pro` (100 dev / 300 holdout); at n≈62–71 per MDM axis
neither half is — meaning **any prompt iteration there burns the only labels we have.** Freeze
the prompt before touching the holdout and version-pin it with the `core/prompt_source.py`
fingerprint. **A `calibration.json` whose prompt hash does not match the prompt in use is stale by
construction.**

Beyond ranking judges, the stage yields three more things: `q₀`/`q₁` for the estimator; a
**localization** of failure — *judge incompetent* vs *prompt broken* vs *task not decidable from
the documentation*, the third isolated by the `CANNOT_ASSESS` rate (an `upstream-input` finding,
not a judge finding); and the self-preference number below.

### What the judge is asked

Directional and one-sided, never "is this correct?" — matching the compliance asymmetry already in
`docs/EVALUATION.md`:

> Here is the documentation. Here is the RISK rubric. **Is there documented support for
> RISK = Moderate, or does the documentation only support a lower level?**
> Answer `SUPPORTED` / `NOT_SUPPORTED` / `CANNOT_ASSESS`, with the decisive span.

Four rules, each load-bearing:

1. **One proposed value per call.** Never show two and ask which is better — that leaks the
   comparison and invites position bias.
2. **The judge never learns which condition it is in**, never sees the annotation, never sees the
   agent's answer. Randomize condition order across the run.
3. **`CANNOT_ASSESS` is first-class** and reported separately — never folded into accept or
   reject.
4. **Require a span.** A verdict with no pointer into the documentation is dropped — the
   mitigation for evaluator hallucination.

**Rubric text comes from the prod prompt** (`copa_prompt.py` / `data_prompt.py` /
`risk_prompt.py`) via `core/prompt_source.py`, so it is snapshotted and fingerprinted. A judge
graded against a paraphrased rubric measures the paraphrase.

### Two passes: leniency vs self-preference

C1/C2 items are built from **annotations**, not from the agent's output — so comparing a
same-family arm against cross-family arms on them measures **leniency**, not self-preference.
Self-preference is specifically *inflated credit for its own output*:

| pass | items built from | measures |
|---|---|---|
| **1a** | annotation + synthetic perturbations | **discrimination and leniency** — is the judge competent at all |
| **1b** | the agent's *own* predicted values, same instances | **self-preference** — same-family accept rate vs cross-family on identical items |

Pass 1b is cheap (one item per instance per arm) and is the only one that speaks to the
[No Free Labels](https://arxiv.org/html/2503.05061v1) finding.

### Judge arms — cross-family is the point

ED's generator is `claude-sonnet-4-6`; clinic's is `claude-opus-4-6`. So:

| arm | model | purpose |
|---|---|---|
| A | **GPT-5.4** (`AZURE_GPT_54_OPENAI_*`) | cross-family judge |
| B | **Gemini-2.5-pro** (`VERTEX_PROJECT` + ADC) | second cross-family judge, different provider |
| C | **Claude** (same family as the agent) | **instrument**, not a candidate — measures self-preference on pass 1b |

Both verifier keys already exist and `ed/verifiers.py` already calls both providers, so the data
path and its PHI review are precedent, not new. **Clinic has no cross-family arm at all** and must
add one before Stage 1 can run there ([[auto eval rollout plan]]).

### Kill switches — decide these before running

| observation | conclusion |
|---|---|
| `reject(C2 ±2+)` materially below 100% | judge is not reading the documentation. **Stop** |
| `accept(corrects)` low | judge rejects *correct* codings — it will bury the queue in false flags; the rubric prompt is wrong before the judge is |
| `reject(C2 +1)` ≈ `1 − accept(corrects)`, i.e. `J ≈ 0` at one rung | judge cannot resolve one rung — AutoRubric's ordinal finding. **Level judging is dead**; go to the rubric surface, making **C0** (COPA/RISK schema completion) the critical path |
| `CANNOT_ASSESS` rate high | either the rubric is not decidable from the documentation (an `upstream-input` finding, valuable on its own) or the prompt is unclear |
| arm C ≫ arms A/B **on pass 1b** | self-preference confirmed; **clinic must not use a Claude judge** |
| top arm's `J` within ~12pp of a rival's | **at n≈71 that is noise, not a ranking.** Do not declare a winner — carry both |

Three of these six are *useful findings* rather than failures. That is what makes Stage 1 the
right first step.

### All survivors carry forward — Stage 1 eliminates, it does not select

Every arm clearing the kill switches runs in Stages 2 and 3. Three reasons:

1. **Stage 1 usually cannot distinguish the survivors.** At n≈71 a rate carries a ~11.6pp CI
   half-width, so `J = 1.17` vs `1.19` is noise. Declaring a winner is false precision.
2. **The cause-separation funnel requires ≥2 arms** (§ 3.2). Stripping "judge blind spot" means
   requiring a conflict be confirmed by two *independent* cross-family arms. With a single arm that
   stage cannot be performed at all: you lose the ability to say what a conflict *means*, not
   merely some accuracy.
3. **Diversity, not redundancy.** AutoRubric found same-model ensembles gave strong judges only
   κ +0.051 — but GPT-5.4 and Gemini differ in family, provider and training data, which is the
   case where ensembling buys something.

## Stage 2 · Judging with rubrics

With a set of **manually designed rubrics** — e.g. `has_chronic_severe_exacerbation` for COPA —
make **one call per rubric per surviving judge**, per instance, asking only whether that rubric
holds.

Four rules:

- **Keep each rubric definition simple and single-purpose.** Atomic evaluation prevents halo
  effects and criterion conflation, and it makes per-rubric reliability computable — so you learn
  *which* rubrics are unreliable instead of getting one uninterpretable number.
- **The judge never sees the agent's answer or the annotation.** Blinding is what prevents
  anchoring; skipping it is what makes reference-free judges generous.
- **Runs on any instance**, annotated or not. This is the step that generalizes beyond the
  annotated slice.
- **Choose the rubric surface explicitly.** Two exist for ED and they are not the same thing: the
  **18 `llm_raw` predicates** that drive the pipeline, versus `guideline_report`'s 61 facility +
  17 professional criteria, which are display-derived. Judging the latter may be judging a
  renderer. **Clinic's surface is not yet identified** ([[auto eval rollout plan]] 0.4).

### Rubric output types, and their reliability

Rubric results may be boolean, ordinal, categorical, or `ambiguous` — but the types are **not
equally trustworthy**, and this should drive rubric design:

| type | judge reliability (AutoRubric) | design implication |
|---|---|---|
| **boolean** (Yes/No) | **87% exact, κ 0.642** | **prefer this.** Decompose toward binary wherever the guideline permits |
| **ordinal** (3–5 levels) | 38–58% exact, but 85–93% adjacent, QWK 0.55–0.72 | usable for gross gaps, **not** for one-rung calls |
| **categorical** | asymmetric — 0.70 recall on one class vs 0.14 on another | measure per class; do not trust a single aggregate |
| **`ambiguous` / `CANNOT_ASSESS`** | — | **first-class output**, reported separately, never folded into Yes or No |

### Rubric weights

Each rubric needs a weight, and there are three options in increasing ambition:

| option | how | when |
|---|---|---|
| **uniform** | every rubric weight 1 | **honest default.** Never wrong, just uninformative |
| **manual** | domain owner assigns, including **negative** weights for rubrics whose truth should *reduce* the score | good where the guideline states relative importance; negative weights also counteract judge leniency |
| **learned** | logistic regression of rubric results against human annotations | best in principle — **but see the caveat** |

**⚠ The learned option overfits at our n.** Fitting 18 rubric coefficients needs roughly 10 events
per predictor — ~180 error events, i.e. ~900 instances at a 20% error rate. We have **62–71**
annotated rows per axis, and **six rubrics have base rates under 2.5%**. So learned weights require
L1/L2 regularization with nested cross-validation, or restriction to the handful of high-prevalence
rubrics, and **uniform weights are the correct fallback** rather than an unregularized fit.

A separate, label-free weighting is available and complements all three: discount each rubric by
its **noise floor** `e_c` — how often a conflict on it arises from the agent's own instability or
the judge's, rather than from an error. See § 3.3; it needs no annotations at all.

### The rubric result table

One per instance. This is Stage 2's output:

| rubric | weight | Opus 5 | Gemini-3-Flash | GPT-5.4 |
|---|---|---|---|---|
| R1 | 10.0 | Yes | Yes | Yes |
| R2 | 8.0 | moderate (0.75) | low (0.50) | high (1.00) |
| R3 | −15.0 | No | No | **Yes** |

Rows where judges disagree with each other measure **judge instability** (`j_c`, § 3.3). Rows
where the judges agree with each other but disagree with the **agent** are the candidate defects.

## Stage 3 · Aggregation

Given the Stage-1 calibration table and the Stage-2 rubric tables, three outputs follow.

### (1) Judge quality

Inter-judge correlation and per-rubric agreement — raw agreement, Cohen's κ, Gwet's AC1 and the
marginal prevalence **together** ([[LLM as a judge SOTA]] §8); quadratic-weighted κ for ordinals.
Two uses: it validates the Stage-1 ranking out-of-sample, and the arm-vs-arm disagreement rate on
a rubric **is** the estimate of that rubric's judge instability `j_c`.

### (2) A per-instance score, for review triage

Combine judge weights × rubric weights × rubric results into one score per instance, then rank.
The principled form is a **log-odds sum** over the conflicts that fired (§ 3.3), which handles
multiple judges by construction: two arms conflicting on the same rubric contributes roughly twice
the evidence of one. Validate the ranking against the annotated slice as **lift over random
ordering** (§ 3.4) — and state its MDE, because at small n a modest lift is invisible.

The ranked queue is what a coder receives; **it also collects the annotations** that upgrade the
weights (§ Stage 3 artifacts below).

### (3) Defect classes

Aggregate the same table down the **rubric** axis instead of the instance axis. One rubric
conflicting across 40 instances is **one faulty prompt**, not 40 faulty instances — worth more than
any individual chart, and it enters the existing RCA → `causes.json` → changelog path. The test for
"class, not noise" is a one-sided binomial against that rubric's noise floor `e_c`, plus a
direction-asymmetry check (§ 3.4).

**This is usually the higher-value output**, and it is the one that survives the move to
un-annotated data intact.

### The four artifacts

| artifact | unit | ids | audience |
|---|---|---|---|
| `findings.json` | (instance, rubric, judge) conflict | yes | machine; feeds the rest |
| `queue.csv` | instance, ranked | yes | **the coder** |
| `calibration.json` | (judge × axis × rubric) | no | provenance; **gates the other three** |
| `autoeval-<dataset>.md` | population | **no** | product + research; shareable |

Same ids-split discipline as `docs/EVALUATION.md`: per-instance artifacts stay internal, the
population artifact can leave the room.

**The queue is also the label-collection instrument.** A row reading "instance X, score 3.2" wastes
the coder's time — they would re-read the whole chart. Every row carries localized evidence plus a
verdict slot:

    enc_id, rank, score, axis, our_value, direction,
    rubrics_conflicted,       # e.g. behavioral_health_safety_assessment
    our_span,                 # what the agent cited
    judge_span,               # what the judge found, or NONE
    arms_confirming,          # "2 of 2"  <- the judge-noise strip
    coder_verdict,            # [ ours | judge | ambiguous ]   <- THEY fill this in
    coder_note

`coder_verdict` closes the loop: it is the adjudication sample that estimates `d_c` (§ 3.3) and
supplies the ambiguity rate for the cause funnel (§ 3.2). Design the queue without it and the
review is paid for twice.

**Choosing the flag budget `k`:** capacity-bound for v1 (`k = coder_hours / minutes_per_review`),
with the precision curve plotted so a reader can see where it crosses the base error rate;
conformal risk control later ([[auto eval proposal]] 6.2).

## Auto-eval — applying the calibrated judges to un-annotated data

The purpose of the whole method: Stages 1–3 consume annotations; the calibrated result runs where
there are none. What transfers is **not uniform**, and conflating the categories is how auto-eval
becomes fiction.

| | on an un-annotated set |
|---|---|
| judge selection (surviving arms) | transfers, subject to shift |
| **`q₀` / `q₁`**, judge weights | transfers **by assumption** — not re-measurable |
| **`e_c`** (per-rubric noise floor) | **re-measurable directly** — built from agent self-flip and judge instability, neither needing annotations |
| **per-instance score (ordering)** | ✅ fully — needs only `e_c` |
| **defect classes** (binomial vs `e_c`) | ✅ **fully label-free — the strongest transfer in the method** |
| **lift / catch rate** | ❌ **not measurable** — both terms need annotations |
| accuracy | ❌ never, by design |

The asymmetry to internalize: **defect-class discovery survives the move almost intact; every
quantitative claim about the queue does not.** *"Rubric X conflicts on 40 charts, above its noise
floor"* is defensible. *"This queue catches 60% of errors"* is a transferred assumption wearing a
number's clothing.

**The named failure mode is distribution shift.** Calibration was measured on one customer's
documentation; on a new slice the templates, habits and case mix differ, so both the base error
rate and the judge's competence move. The literature names it: the bias-corrected estimator "fails
under realistic shifts where test and calibration distributions have different true accuracy
rates", and PPI requires the two sets be i.i.d. ([[LLM as a judge SOTA]] §6).

**Four sentinels detect broken transfer, all label-free:**

| # | sentinel | reads as |
|---|---|---|
| 1 | **input-adequacy shift** — length distribution, template artifacts, null channels ([[auto eval plan]] tier 0) | if the input distribution moved, transfer is suspect before anything else is examined |
| 2 | **`CANNOT_ASSESS` rate** vs calibration | a jump means the judge is out of its depth here |
| 3 | **arm–arm agreement** vs calibration | a collapse means the judges are guessing |
| 4 | **`e_c` recomputed** on the slice | if it moved, **recompute the weights** rather than transferring them |

**For an actual number, add an anchor sample.** Annotate **30–50 instances** of the slice and use
PPI: a small annotated sample plus the large judged set gives an **unbiased** population estimate
regardless of the judge's error profile, and at ρ≈0.6 those 50 behave like ~78
([[LLM as a judge SOTA]] §6). This is the only honest route from a judge to a reported figure on
new data.

**What an un-annotated run may report:**

> Ranked 850 instances; flagged the top 128. **Ordering and class findings are computed on this
> slice; the lift figure (2.9×) is carried over from `washington-402` calibration and is not
> measured here.** Judge `CANNOT_ASSESS` 4.1% vs 3.8% at calibration; arm agreement 0.81 vs 0.84 —
> both within tolerance, so transfer is plausible. Three rubric classes exceed their noise floor.

The same report stating "lift 2.9×" bare, as though measured, is not defensible. And the
frozen-detector rule applies here specifically: a detector used on un-annotated data is
**version-pinned** and re-validated whenever the judge prompt, the agent prompt, or the provider
snapshot changes ([[auto eval proposal]] §4 C-7, C-10).

---

# 2 · Minimal run example

One encounter, three stages, no caveats. **The goal:** find which of our 402 ED encounters are
probably coded wrong, without a human labelling them all.

## Stage 1 — test the judge

**Is the judge any good?** We have 71 encounters where an auditor already told us the answer. Use
them as an exam.

Encounter `944069156`. The auditor says **RISK = moderate**. Ask the judge four questions:

| we tell the judge | truth | correct answer |
|---|---|---|
| "RISK is moderate" | right | YES, supported |
| "RISK is high" | wrong | NO |
| "RISK is low" | wrong | NO |
| "RISK is minimal" | wrong | NO |

The judge sees only the chart and the question — not the auditor's answer.

Do this for all 71 encounters × 3 axes = **864 questions**, through 3 candidate judges.

**Then grade them.** Say GPT-5.4 gets 88% right on the true answers ✅ — but accepts the wrong
"RISK is high" **71% of the time** ❌.

**Stage 1 decides:** which judges are fit to use — *all* that pass, not just the best one — and
**whether asking about levels works at all**. Here it does not: a wrong level goes through 71% of
the time, so we stop asking about levels.

## Stage 2 — run the judge

**Where does the judge disagree with us?** Levels failed, so ask about something smaller: the
**individual checkboxes** our pipeline fills in. For `944069156` our pipeline said:

    prescription_drug_management         = YES
    controlled_substance_iv             = NO
    life_or_function_threatening        = NO
    behavioral_health_safety_assessment = YES

Ask the judge about each separately — *"does this chart show behavioral health safety
assessment? Quote the line."* It never sees our answer.

| checkbox | us | judge | |
|---|---|---|---|
| prescription_drug_management | YES | YES | ✅ same |
| controlled_substance_iv | NO | NO | ✅ same |
| life_or_function_threatening | NO | NO | ✅ same |
| behavioral_health_safety_assessment | YES | **NO** | ⚠️ **disagree** |

**That disagreement is the output** — specifically: encounter `944069156`, the
`behavioral_health_safety_assessment` checkbox, and the line the judge could not find. Now run it
across all 402.

## Stage 3 — ship it

**What does a human receive?** Two things.

**1 · A ranked list, for a coder.** Sort all 402 by disagreement count; give the coder the top 60.
Each row says where to look:

| enc | disagreements | checkbox | judge could not find |
|---|---|---|---|
| 944069156 | 1 | behavioral_health_safety_assessment | (the line we cited) |
| 944071243 | 3 | … | … |

The coder writes one word per row: **we were right** / **judge was right** / **genuinely
unclear**.

**2 · A summary, for the team.** Two things fall out:

- **Did the ranking work?** We know the true answer for 400 encounters, so we can check. If 25 of
  the top 60 are genuinely wrong, that is 42% — versus 14% picking at random. **The list is 3×
  better than random.** That number is the whole justification for the tool.
- **Is one checkbox broken?** Group by checkbox instead of encounter. If
  `behavioral_health_safety_assessment` disagrees on 40 charts, that is not 40 bad charts —
  **that is one bad prompt.** Fix it once and all 40 improve. Usually worth more than the queue.

## Recap

| stage | what you do | what you get |
|---|---|---|
| **1** | Quiz the judges on 71 encounters where you know the answer | Which judges are fit to use, and which questions they can handle |
| **2** | Ask the judge about each checkbox on all 402 encounters | Specific disagreements, each pinned to a field |
| **3** | Rank them, hand the top 60 to a coder | A review queue + proof it beats random + a list of broken prompts |

**The rule holding it together: Stage 1 comes first.** Without it, Stage 2 still produces a tidy
list of disagreements — you just cannot tell whether the judge or your pipeline is wrong.

---

# 3 · Details

## 3.1 · The data, verified on disk

`ed/dataset/washington-402/gt.csv`, 402 rows:

| axis | labelled | GT distribution | note |
|---|---|---|---|
| `gt_professional_code` | **400** | 99284: 239 · 99285: 83 · 99283: 72 · 99282: 5 · 99291: 1 | **5.6× more power than the MDM axes** |
| `gt_data_level` | 72 | moderate 32 · high 14 · minimal 13 · low 11 · none 2 | full 5-rung spread |
| `gt_copa_level` | 71 | moderate 43 · low 14 · high 14 | **no `none`/`minimal` at all** |
| `gt_risk_level` | 71 | moderate 36 · low 23 · high 10 · minimal 2 | |

Three consequences:

- **Start with `pro`, not the MDM levels.** 400 rows is the difference between a usable interval
  and a shrug. "Is 99284 supported by this documentation?" is *verification of a given code*, not
  generation — so it stays on the safe side of the 49.8%-CPT-exact-match finding. And it is the
  axis that actually bills.
- **Boundary cases are explicit.** A GT of `high` has no +1 rung; `none` has no −1. Those
  encounters drop out of that stratum — record per-stratum `n`, never silently rebalance.
- **The tails are unusable.** `99291` (n=1) and `99282` (n=5) cannot support a stratum.

**Measured item counts** for pass 1a, verified against `gt.csv`:

| axis | labelled | items | C1 | C2+1 | C2−1 | C2+2 | C2−2 |
|---|---|---|---|---|---|---|---|
| copa | 71 | 284 | 71 | 57 | 71 | 14 | 71 |
| data | 72 | 283 | 72 | 58 | 70 | 26 | 57 |
| risk | 71 | 297 | 71 | 61 | 71 | 25 | 69 |
| **total** | | **864** | | | | | |

864 items × 3 arms = **2,592 calls**. One afternoon.

## 3.2 · Statistics

- **Accept rate per condition**, paired by encounter (the same encounter appears in C1 and every
  applicable C2 stratum) → **McNemar / paired bootstrap**, not two independent proportions.
- **Calibration gap = accept(C1) − accept(C2ₛ)** per stratum. **This is the headline, and a raw
  accept rate alone is meaningless.** A judge answering SUPPORTED to everything scores 100% on C1
  *and* ~100% on every C2 stratum. Read the columns against each other. High C1 + high C2 =
  **lenient**, not good.
- **`q₀` is stratum-specific.** Specificity `P(reject | wrong)` depends on how wrong the shown
  level is. Weight it by how often the pipeline actually errs by one rung vs two — which § 3.5
  measures as **56:1**, so use the one-rung number almost exclusively. Feeding a blended `q₀`
  into `θ̂` overstates the judge.
- **Bootstrap resamples encounters**, and a resampled encounter brings all its conditions — the
  invariant `scripts/metrics_selftest.py` locks. Never resample judge calls.
- **Report raw agreement + Cohen's κ + Gwet's AC1 + marginal prevalence together**
  ([[LLM as a judge SOTA]] §8). With `copa` at 43/71 moderate, κ alone misleads. Use
  quadratic-weighted κ for ordinals.
- **Power, up front:** at n=71 a single accept rate has a 95% CI half-width of ~11.6pp (worst
  case); at n=400, ~4.9pp. Pairing tightens the *gap*. Put the achieved MDE in the artifact —
  `docs/EVALUATION.md` forbids a null without one.

### Separating the three causes — a funnel, not a per-encounter verdict

A conflict can mean (1) we are wrong, (2) the label is genuinely ambiguous, or (3) the judge has
a blind spot. **Not separable for a single encounter.** They are separable as a funnel, and each
stage's attrition rate is itself the measurement:

| stage | strips | mechanism |
|---|---|---|
| all flagged conflicts | — | |
| → confirmed by **≥2 cross-family arms** | **(3) judge blind spot** | a conflict only arm A raises is likelier arm-specific noise. **The single-arm vs multi-arm ratio is the judge-noise estimate** |
| → **two coders agree with each other** | **(2) label ambiguity** | coder–coder disagreement on flagged items *is* the ambiguity rate. Route to `label-or-standard` — a first-class result ([[auto eval plan]] tier 5) |
| → coders agree the pipeline is wrong | — | remainder is **(1) our error** → `system` disposition, the denominator lift is computed against |

Human adjudication is paid only on the flagged head, never the population.

## 3.3 · Computing the ranking weights

A conflict is evidence, so weigh it as a **log likelihood ratio**. For criterion `c`:

    w(c) = log [ P(conflict | we are wrong) / P(conflict | we are right) ]
                        detection d_c              false alarm e_c

    encounter score = Σ w(c)  over the criteria that conflicted

A Naive-Bayes log-odds sum — what the Dawid–Skene label model
([[auto eval proposal]] 6.1) reduces to once per-detector error rates are known.

### The denominator `e_c` — computable today, no labels

A spurious conflict can be manufactured by noise on **either** side, and both are measurable
without ground truth:

| term | what it is | source |
|---|---|---|
| `s_c` | **our** self-flip rate on `c` across seeds | clinic `repro-seed{1,2,3}` gives **K=9 on 63 encounters**; [[tier 4 criterion judging]] measured **10.2%** and **18.0%** on two criteria |
| `j_c` | **judge** instability on `c` | arm A vs a repeat arm A call, and arm A vs arm B. Pure judge noise, no GT |

    e_c = 1 − (1 − s_c)(1 − j_c)   ≈  s_c + j_c   for small values

Worked, using the two real measured `s_c`:

| criterion | `s_c` | `j_c` (assumed) | `e_c` | weight `log(0.7 / e_c)` |
|---|---|---|---|---|
| a stable criterion | 0.02 | 0.05 | 0.069 | **2.31** |
| `behavioral_health_safety_assessment` | **0.18** | 0.10 | **0.262** | **0.98** |

A conflict on the stable criterion carries **~2.4× the evidence**. And read the second row
directly: **~26% of conflicts there are manufactured by noise alone.** That is the concrete reason
unweighted conflict counting ranks by instability rather than error.

### The numerator `d_c` — the wall

`P(conflict | we are wrong)` **cannot be estimated without criterion-level labels**, and
`gt.csv` labels *levels and codes*, not the 18 booleans. Three options:

| option | gives | verdict |
|---|---|---|
| **Hold `d_c` constant** → `w(c) = −log(e_c) + const` | a purely noise-discounted ranking | **the honest v1.** Computable today, no labels, fixes the actual defect |
| **Borrow `q₁`** from the Stage-1 level calibration as a prior | per-criterion `d_c` under an assumption | cheap and weak — state the assumption |
| **Adjudicate a sample of conflicts** (the `coder_verdict` column) | a measured `d_c` | the real fix, and **far cheaper than labelling encounters** — a coder reads one criterion and one span, not a whole chart. ~50 per high-volume criterion |

The third is the cheap label ask [[auto eval proposal]] §3.1 wants, arriving by a different
route: adjudicating conflicts *is* stratified label acquisition, concentrated where information
is highest.

### Two corrections that are not optional

**Smoothing.** Six of eighteen criteria have base rates under 2.5% — ~10 positives in 402
encounters — so a raw per-criterion `s_c` or `j_c` is noise. Shrink toward the pooled rate
(empirical Bayes, or Laplace as a floor) and **print per-criterion `n` beside every weight**.

**Independence is false.** Log-odds summing assumes criteria fail independently. They do not —
groundedness and entailment co-fire by construction, and criteria within one axis share a single
note-reading step. Unmitigated this over-counts exactly where several criteria trip together
([[auto eval proposal]] 6.1). Cap the per-axis contribution, or group correlated criteria and
count the group once.

## 3.4 · Lift and class discovery

### Base rates, measured

On `washington-402-baseline/run1` against `gt.csv`:

| axis | paired | wrong | **base error rate** | max achievable lift @top-15% |
|---|---|---|---|---|
| `pro` | 400 | 57 | **14.2%** | 6.67× |
| `copa` | 71 | 15 | 21.1% | 4.73× |
| `data` | 72 | 17 | 23.6% | 4.24× |
| `risk` | 71 | 14 | 19.7% | 5.07× |

### Lift

    lift@k = precision@k / base_error_rate

On `pro`, top-15% = 60 encounters; 25 genuinely wrong → precision 41.7%, lift **2.9×**. Report
the **whole curve** (precision *and* recall, k = 5…100%) plus rank AUC, never a single k. The
shippable sentence is the recall end: *"flag the top 15%, catch X% of all errors."*

**MDE, which decides where lift is measurable at all:**

| axis | top-15% n | precision CI half-width | verdict |
|---|---|---|---|
| `pro` | 60 | ~12.6pp | must clear ~25% observed precision to exclude the 14.2% base → **detectable lift starts ≈2×** |
| copa / data / risk | 11 | ~29.6pp | **not measurable at any usable k** |

So lift is computed on `pro`; MDM axes are suggestive only. Third independent route to the same
conclusion as § 3.1 and [[auto eval proposal]] §3.1.

### Class discovery — aggregating down the criterion axis

Group by *criterion* and compute `n_asserted`, `n_conflicts`, conflict rate, direction, and `e_c`.

**The test for "class, not noise" is a one-sided binomial against `e_c`** — the second payoff from
§ 3.3, since `e_c` doubles as the null hypothesis:

> `behavioral_health_safety_assessment`: asserted true on 180, judge disagrees on 62 → **34.4%
> observed vs a 26.2% noise floor**, n=180, one-sided p ≈ 0.01. Real — but only ~8pp above its
> own noise, so say so.

A criterion with `e_c` = 6.9% conflicting at 30% is overwhelming by comparison. That is a prompt
bug.

**Direction is the signature.** Systematically one-directional (we assert true, judge says false,
almost always) = prompt bug. Bidirectional scatter around `e_c` = instability. Compute the
asymmetry; do not eyeball it.

**Then cluster the spans** for the mechanism — 40 conflicts where the judge finds no span at all,
or where every conflict cites the same template line, is a *cause*.

**Why this is the cheap end:** adjudicating a **class** is O(1) human work for O(40) encounters —
one read of the criterion definition plus five examples settles whether it is our bug or the judge
misreading the rubric. Promotion is the existing door
([[auto eval proposal]] § Contract): a `causes.json` entry with `locus` = that criterion's prompt
text, `targets` = the conflicting ids, and **`controls`** = encounters asserting the same criterion
where the judge agreed, so a fix that breaks them is caught at eval.

## 3.5 · The rung-distance finding: 56 of 57 errors are one rung

Measured on `pro`, n=400 on-ladder:

| rung distance | n |
|---|---|
| −1 (under-code) | 20 |
| 0 (correct) | 343 |
| +1 (over-code) | **36** |
| +2 | **1** |

Over-coding 9.2% vs under-coding 5.0% — a **1.85× skew toward over-coding**, which is the
compliance direction and a required report section.

Two consequences:

- **The weighted `q₀` is ~98% the one-rung number** (56:1). Use the C2+1 specificity almost
  exclusively; blending in the flattering two-rung figure overstates the judge.
- **There is no "at least it catches the big errors" fallback** — big errors do not exist here
  (1 in 400). So `C2±2` is a sanity floor on the judge only, and **one-rung detection is the
  entire game.**

## 3.6 · The report's six required sections

Population-level, no ids.

1. **Calibration** — the Stage-1 table per (judge model × axis), with judge prompt hash and
   provider model versions.
2. **Operating point** — `k`, precision@k, recall@k, lift, with CIs, **plus the achieved MDE**
   ("lift below ~2× is invisible at this n").
3. **Compliance direction** — over 9.2% / under 5.0%, and whether the queue over-samples the
   over-coding direction as intended.
4. **Class table** — per criterion: `n_asserted`, conflict rate, `e_c`, one-sided p, direction
   asymmetry.
5. **The funnel** — flagged → multi-arm confirmed → coder-agreed → confirmed as our error, with
   attrition at each stage.
6. **What was not covered** — `CANNOT_ASSESS` rate, axes excluded for insufficient labels, any
   top-N truncation. **No silent caps:** a report omitting its coverage reads as complete when it
   is not.

### What v1 may and may not claim

| | |
|---|---|
| **may** | *"here is a ranked queue; on `pro` it achieves lift L (95% CI …) against a measured 14.2% base error rate"* |
| **may not** | any accuracy number for the pipeline · any lift claim on copa/data/risk (n=11 at top-15%, ±29.6pp) · any per-criterion precision before `coder_verdict` data exists |

**Staleness rule:** a queue whose `calibration.json` prompt hash does not match the judge prompt
in use is **void**. And these run dirs carry **no `manifest.json`**, so the qh-platform SHA is
unrecorded — [[auto eval proposal]] item A5, which must be fixed before any of this is citable.

## 3.7 · Where the code goes

A measurement, so an experiment first and engine second (`CLAUDE.md`):

    ed/experiments/judge-calibration/
      plan.md            <- hand-written FIRST; non-default experiment, no template
      calibrate.py       <- builds the C1/C2 item set, runs the arms, writes items.jsonl
      score.py           <- accept rates, paired bootstrap, kappa/AC1/prevalence, MDE
      results/           <- local-only
      reports/judge-calibration-washington-402.md

It graduates into `core/autoeval/calibrate.py` once it has run and the shape stops moving. Two
dependencies:

- **`core/judge.py` must land first** — on `origin/citation-eval-on-main`, unmerged
  ([[auto eval proposal]] WS-A1). `StructuredLLMJudge` is already the right primitive: forced
  tool, temperature 0, raises on `stop_reason == max_tokens` instead of returning a partial `{}`.
  Do not write a second one.
- **Route judge calls through `core.modelcache`** so a re-run replays instead of re-billing
  (`request_sha`, `put`/`get`, `run_signature`). It stores request bytes verbatim, which is also
  what makes a verdict auditable months later.

### Item-builder sketch

```python
# The item set is the whole trick; everything else is plumbing.
LEVELS = ("none", "minimal", "low", "moderate", "high")   # ed/profile.py::_LEVELS

def items_for(enc_id: str, gt_level: str, axis: str):
    """One encounter -> up to 5 blinded items. Condition label is held OUT of the prompt."""
    i = LEVELS.index(gt_level)
    yield dict(enc=enc_id, axis=axis, shown=gt_level, cond="C1", rung_delta=0)
    for delta, cond in ((+1, "C2+1"), (-1, "C2-1"), (+2, "C2+2"), (-2, "C2-2")):
        j = i + delta
        if 0 <= j < len(LEVELS):          # boundary: no synthetic rung invented
            yield dict(enc=enc_id, axis=axis, shown=LEVELS[j],
                       cond=cond, rung_delta=delta)

# Shuffle across encounters AND conditions so the judge cannot infer the condition
# from call order or from the shown-level distribution.
```

The judge prompt carries only the note + rubric + `shown` — **never** `cond`, `rung_delta`, the
GT, or our prediction.

## 3.8 · PHI

Judge prompts contain verbatim note text, so calls send PHI to Azure and Vertex. ED already does
this for its verifiers, so the path is precedent — but note:

- **`gt.csv` carries an `mrn` column.** The item builder selects `pat_enc_csn_id` and the level
  columns only; never pass a row through wholesale.
- `result_json` carries `mrn`, `patient_name`, `patient_dob`. If the note comes from a run dir,
  take `result_json["note"]` and nothing else.
- `items.jsonl`, `findings.json`, `queue.csv` and all results are **local-only** — never
  committed, never synced. The rendered report is population-level, encounter ids at most.

## 3.9 · First move

Smoke-test ~20 encounters × arm A × all conditions before the full set — to catch a broken prompt
or auth path, not to save money. Then run `pro` (n=400) across all three arms, because it has the
power; the MDM axes follow and are read as suggestive at n≈71.
