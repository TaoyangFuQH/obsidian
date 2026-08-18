---
updated: 2026-08-18
tags: [project, eval, auto-eval, llm-as-judge, survey, framework]
---
# Fitting the calibration/sensitivity protocol into the 3-stage framework

**The work.** [Kranti & Vajjala 2026](https://arxiv.org/abs/2607.12885)'s
calibration → sensitivity protocol, as instantiated for medical-coding agents in
[[judge calibration protocol]], with [AutoRubric](https://arxiv.org/html/2603.00077v2)
supplying the rubric layer and [No Free Labels](https://arxiv.org/html/2503.05061v1) the
self-preference mechanism ([[LLM as a judge SOTA]] §2–3).

**Why it is the right anchor for the framework.** It is the only line of work in the survey
that treats *judge fitness* as a measurement with its own experimental design, and it is
already organized as calibrate → judge → aggregate. The mapping is close to 1:1 — which
makes the residue interesting: everything it does that the framework has no slot for is a
concrete amendment, not a stylistic difference.

---

## 0 · Notation

| framework | this work | note |
|---|---|---|
| judge, arm | arm — A cross-family, B cross-family/other provider, C same-family-as-agent | family relatedness is a design variable, not a label |
| data instance | encounter | |
| agent result | pipeline's predicted level / code | |
| human annotation | auditor ground truth (`gt.csv`) | labels the **outcome**, not the rubrics |
| rubric `R_i` | criterion — 18 booleans that drive the agent, or an ordinal level | |
| `accept(corrects)` | `accept(C1)` = sensitivity `q₁` | |
| `reject(incorrects)` | `reject(C2)` = specificity `q₀` | stratified, see §1.2 |
| judge weight `w` | calibration gap `accept(C1) − accept(C2)` | used as a screen, not a rank |
| rubric weight | log-likelihood-ratio `w(c) = log(d_c / e_c)` | |
| final score | `Σ w(c)` over the rubrics that conflicted | |
| defect class | criterion class: conflict rate vs its own noise floor `e_c` | |

---

## 1 · Stage 1 — Judge Calibration

The framework's Stage 1 is this work's Stage 1 exactly: show a judge known-correct and
known-incorrect answers, record two rates, use them to decide which judges proceed. Five
things it adds.

### 1.1 · Where the "incorrects" come from — two passes, two different estimands

The framework says *show the judges the agent results and human annotations*. That is only
one of two item sources here, and it is the weaker one:

| pass | items built from | measures | needs |
|---|---|---|---|
| **1a** | human label + **synthetic perturbation** of it | discrimination and leniency — is the judge competent at all | labels only |
| **1b** | the **agent's own** predictions on the same instances | **self-preference** — same-family accept rate vs cross-family on identical items | labels + agent output |

Pass 1a is the framework's missing piece. Because items are counterfactuals built off the
label, the item set is balanced by construction and independent of agent quality — there is
no coverage hole where the agent happens to be right, and `q₀`/`q₁` do not drift when the
agent improves. Pass 1b is the only thing that speaks to self-preference, and it is cheap
(one item per instance per arm).

**Framework amendment:** Stage 1's inputs are *(human labels, perturbation operator)* and
*optionally* agent results — not agent results as the primary source.

### 1.2 · `reject(incorrects)` is a mixture, and its weights belong to the agent

A single reject rate silently averages over *how wrong* the shown answer was. On an ordinal
answer space the work stratifies by rung distance:

| condition | shown | a competent judge should |
|---|---|---|
| C1 | the label | accept ≈100% |
| **C2(+1)** | one rung up (over-code) | reject — **the one that matters** |
| C2(−1) | one rung down | reject |
| C2(±2+) | two or more rungs away | reject ≈100%; failure ⇒ incompetent, full stop |

The measured error profile of the agent was **56 one-rung errors to 1 two-rung error**. So a
blended reject rate is ~98% determined by the one-rung stratum, and any two-rung mass in it
is flattery. C2(±2+) is a *sanity floor on the judge*, not an operational number.

**Framework amendment:** `reject(incorrects)` is a **vector over perturbation severity**,
reported per stratum with per-stratum `n`, and collapsed to a scalar only by weighting with
the agent's empirical error distribution. Boundary instances (top rung has no +1) drop out of
a stratum rather than being rebalanced.

### 1.3 · Abstention is a third column, not a fold

`CANNOT_ASSESS` is first-class and reported separately, never folded into accept or reject.
Two reasons: a judge that abstains often otherwise reads as a good rejecter, and a high
abstention rate localizes the failure elsewhere — *the task is not decidable from the input*,
which is an **upstream-input finding**, not a judge finding. The framework's Stage 1 table has
two columns that do not partition the outcome space.

**Framework amendment:** three columns — `accept` / `reject` / `abstain` — summing to 1 per
condition. Also: a verdict with no citation span is **dropped**, and the drop rate reported
(hallucination mitigation), which makes a fourth denominator explicit.

### 1.4 · The two rate-combining formulas are not interchangeable — and one is degenerate

Both candidates in the framework are monotone in each rate, so both look reasonable. On the
framework's own example table they **invert the ranking**:

| arm | `accept(C1)` | `reject(C2)` | `a + r` | rank | `1 − (1−a)(1−r)` | rank |
|---|---|---|---|---|---|---|
| GPT-5.4 | 88% | 29% | 1.17 | 2 | **0.915** | 2 |
| Gemini | 84% | 35% | **1.19** | **1** | 0.896 | 3 |
| Claude (same family as agent) | 93% | 14% | 1.07 | 3 | **0.940** | **1** |

The multiplicative form is a **noisy-OR**: `1 − (1−a)(1−r) = a + r − ar`. Subtracting `ar`
penalizes a judge that is good at *both* — for a fixed sum, it ranks the **most lopsided**
judge highest. Its failure case is total: a judge that answers SUPPORTED to everything scores
`a = 1`, `r = 0`, and `w = 1.0` — the ceiling. Here it promotes the same-family arm that this
work disqualifies outright.

The additive form is fine, and is not new: `a + r − 1` is **Youden's J**, identical in
ordering to this work's headline statistic, the **calibration gap** `accept(C1) − accept(C2)`,
and to `2·balanced_accuracy − 1`. It scores the yes-machine at 0 — the chance floor — by
construction.

**Framework amendment:** drop the multiplicative form. Use the gap / Youden's J, name it as
such, and state the rule it encodes: *a raw accept rate alone is meaningless; high accept +
high accept-on-wrong is **lenient**, not good.*

### 1.5 · Eliminate, do not rank; and calibration is per (judge × task axis)

The framework says *rank and pick top judges*. This work refuses to, for three reasons:

1. **The gap estimate cannot separate the survivors.** At n≈71 a single accept rate carries a
   ±11.6pp 95% CI (±4.9pp at n=400). A 17-vs-19pp gap difference is noise; picking a winner is
   false precision. The rule is pre-registered: *if the leader's gap is within ~12pp of a
   rival's, declare no winner.*
2. **Stage 3 needs ≥2 independent arms** to separate a real disagreement from arm-specific
   noise (§3.3). With one arm, that stage cannot be performed at all.
3. **Diversity, not redundancy** — same-model ensembles bought only κ +0.051 (AutoRubric);
   different family *and* provider is the case where ensembling pays.

Selection is therefore by **pre-registered kill switches**, written before the run so the
result cannot be rationalized afterwards — and three of the six kill switches are *useful
findings* rather than failures (abstention high ⇒ input problem; same-family ≫ cross-family on
pass 1b ⇒ self-preference confirmed, ban that family for that agent; accept(C2+1) ≈ accept(C1)
⇒ this rubric *type* is undecidable, change Stage 2's surface).

Separately: the calibration table is indexed by **(judge model × task axis × rubric)**, not by
judge. In the instantiated data one axis has 400 labels and three have ~71 — the same judge is
gradeable on one and not the others.

**Framework amendments:** (a) Stage 1 emits a *survivor set* plus kill-switch dispositions, not
a top-k; (b) every cell carries a CI and the achieved MDE; (c) the arm axis gains **family /
provider metadata**, because the same-family arm is retained as an **instrument** (it measures
self-preference) while being ineligible as a candidate — a "pick top judges" rule deletes
exactly the row you need.

### 1.6 · The two rates are estimator parameters, not just a ranking key

`q₀`/`q₁` are consumed downstream by the prevalence-corrected estimator
`θ̂ = (p̂ + q̂₀ − 1)/(q̂₀ + q̂₁ − 1)` (Rogan–Gladen; [[LLM as a judge SOTA]] §6). Nothing
judge-derived is reportable without them. That has two consequences the framework has no rule
for:

- **A dev/holdout split is mandatory.** Tuning the judge prompt against the labelled rows makes
  those rows in-sample; the accept rates stop measuring competence and start measuring prompt
  fit, and the inflated `q₀`/`q₁` then corrupt the estimator. Fixing a demonstrably broken judge
  prompt is legitimate apparatus debugging; maximizing the gap is Goodhart. The line is drawn by
  splitting, not by intent.
- **The judge prompt is frozen and fingerprinted.** A calibration record whose prompt hash does
  not match the prompt in use is **void by construction**, as is one whose provider model
  snapshot moved. Rubric text is pulled from the *production* prompt, never paraphrased — a
  judge graded against a paraphrase measures the paraphrase.

---

## 2 · Stage 2 — Judging with Rubrics

The framework's Stage 2 is this work's Stage 2 with almost no translation: one blinded call per
rubric per surviving judge; the judge sees the input plus that single rubric definition and
never the agent's answer or the human label; atomic evaluation to prevent halo effects and to
make per-rubric reliability computable. Additions:

### 2.1 · The Stage-2 cell is a *conflict*, not a verdict

The framework's rubric table holds judge verdicts. This work diffs each verdict against the
agent's value and emits **(instance, rubric, arm, agent value, judge verdict, direction,
agent's cited span, judge's span or NONE)**. The output is "a disagreement with an address" —
not "this instance looks wrong", which is unactionable and cannot be aggregated into a class.

**Framework amendment:** the cell is a tuple, and the **span is required** — it is what makes
Stage 3's mechanism clustering (§3.3) possible and what makes a verdict auditable later.

### 2.2 · The rubric set must be the one that *drives* the agent

Two candidate rubric surfaces existed: the 18 booleans the pipeline actually consumes, and 78
display-derived report criteria. Judging the latter is judging a renderer.

**Framework amendment:** a rubric is admissible only if it is causally upstream of the agent
output being evaluated.

### 2.3 · Stage 1 chooses the rubric *type* — a feedback edge the framework lacks

The framework's rubric list is fixed a priori. Here a Stage-1 kill switch rewrites it: if the
judge cannot resolve one rung (`accept(C2+1) ≈ accept(C1)`), **ordinal judging is dead** and
Stage 2 drops to the binary criterion surface — the layer AutoRubric measured at κ 0.642 versus
QWK ~0.55–0.72 for ordinals, against its own finding that 3–5-level ordinal judging runs at only
38–58% exact.

**Framework amendment:** draw the arrow Stage 1 → Stage 2, and add the constraint in §5.1
below (calibration item type must match deployed rubric type).

### 2.4 · A fourth weighting scheme — and it is the only label-free one

The framework offers uniform / manual / logistic regression on human labels. This work adds a
log-likelihood-ratio weight, since a conflict is evidence:

    w(c) = log [ P(conflict | agent wrong) / P(conflict | agent right) ] = log(d_c / e_c)
    score(instance) = Σ w(c) over conflicting rubrics          # Naive-Bayes log-odds

The denominator is the useful half. A spurious conflict can be manufactured by noise on either
side, and **both are measurable with no labels at all**:

| term | what | source |
|---|---|---|
| `s_c` | the **agent's** self-flip rate on rubric `c` across seeds | repeat runs; two measured criteria came in at 10.2% and 18.0% |
| `j_c` | the **judge's** instability on `c` | arm A vs repeat arm A, and arm A vs arm B |

    e_c = 1 − (1 − s_c)(1 − j_c) ≈ s_c + j_c

Worked on the real numbers: a stable rubric (`s_c`=.02, `j_c`=.05) gives `e_c`=.069 and weight
2.31; the unstable one (`s_c`=.18, `j_c`=.10) gives `e_c`=.262 and weight 0.98. A conflict on
the stable rubric carries **~2.4× the evidence**, and **~26% of conflicts on the unstable one
are manufactured by noise alone.** That is the concrete reason unweighted rubric counting ranks
by instability rather than by error.

The numerator `d_c` is the wall: `P(conflict | agent wrong)` needs **rubric-level** labels, and
human annotation exists at the outcome level. Three options, and the honest v1 is the first:

| option | gives | verdict |
|---|---|---|
| hold `d_c` constant ⇒ `w(c) = −log e_c + const` | a purely noise-discounted ranking | **v1** — computable today, fixes the actual defect |
| borrow `q₁` from Stage 1 as a prior | per-rubric `d_c` under an assumption | cheap, weak; state the assumption |
| adjudicate a sample of conflicts | a *measured* `d_c` | the real fix, and cheaper than labelling instances — a reviewer reads one rubric and one span, not the whole input (~50 per high-volume rubric) |

**Framework amendment:** add LLR weighting, and record on the framework's weight column
*which quantity the weight estimates and what it costs in labels*. Note also that the
framework's example weights (+10, +8, **−15**) presuppose a fitted model — i.e. the
label-hungry option — and that fitting 18 rubric coefficients against ~71 labelled instances
is unidentifiable without heavy regularization. Two corrections are not optional either way:
**shrink** low-base-rate rubrics toward the pooled rate and print per-rubric `n` beside every
weight (6 of 18 rubrics sat under 2.5% base rate); and treat **independence as false** —
rubrics inside one axis share a single input-reading step and co-fire, so cap the per-axis
contribution or group correlated rubrics and count the group once.

---

## 3 · Stage 3 — Aggregation

All three of the framework's Stage-3 outputs are present, and the work ranks them in the
opposite order of how they are usually pitched.

| framework output | this work | |
|---|---|---|
| (1) judge quality, correlations | arm–arm agreement; per-rubric judge instability `j_c`; raw agreement + Cohen's κ + Gwet's AC1 + marginal prevalence reported **together**, quadratic-weighted κ for ordinals | κ alone misleads at skewed prevalence |
| (2) final score per instance | reliability-weighted log-odds sum ⇒ **ranked review queue** | "helps a reviewer once, per instance" |
| (3) defect classes | aggregate down the **rubric** axis | *worth more* — one rubric conflicting on 40 instances is **one bad prompt**; fix once, all 40 improve |

### 3.1 · Class discovery needs a null, and `e_c` already is one

The test for *class, not noise* is a **one-sided binomial against `e_c`** — the second payoff
from §2.4. Worked example: asserted on 180 instances, judge disagrees on 62 ⇒ 34.4% observed
against a 26.2% noise floor, p ≈ 0.01. Real, but only ~8pp above its own noise, and the report
must say so. A rubric with `e_c` = 6.9% conflicting at 30% is overwhelming by comparison.

**Direction is the signature**: systematically one-directional (agent asserts true, judge says
false, nearly always) ⇒ prompt bug; bidirectional scatter around `e_c` ⇒ instability. Compute
the asymmetry, do not eyeball it. Then **cluster the spans** for the mechanism — 40 conflicts
where the judge finds no span at all, or where every conflict cites the same template line, is
a *cause*.

**Why class discovery outranks the queue:** adjudicating a class is O(1) human work covering
O(40) instances — one read of the rubric definition plus five examples settles whether it is the
agent's bug or the judge misreading the rubric.

### 3.2 · A per-instance score is a ranking, not a proxy verdict

The framework's output (2) reads as *a final score per instance standing in for the human
annotation*. This work is explicit that a conflict on a single instance **cannot** be attributed:
it can mean (1) the agent is wrong, (2) the label is genuinely ambiguous, or (3) the judge has a
blind spot. Those are separable only in aggregate, as a **funnel whose attrition rate at each
stage is itself the measurement**:

| stage | strips | the mechanism, and the by-product |
|---|---|---|
| all flagged conflicts | — | |
| → confirmed by **≥2 cross-family arms** | (3) judge blind spot | the single-arm vs multi-arm ratio **is** the judge-noise estimate |
| → **two humans agree with each other** | (2) label ambiguity | reviewer–reviewer disagreement on flagged items **is** the ambiguity rate — a first-class finding, routed to `label-or-standard` |
| → humans agree the agent is wrong | — | remainder is agent error, the denominator lift is computed against |

Human adjudication is paid only on the flagged head, never the population.

**The aggregation mode differs by output**, and the framework should say which it means:
**AND across arms** for the class table (precision matters — a false class sends someone to
rewrite a prompt for nothing), **weighted sum** for the queue (recall matters — a hard AND
discards single-arm conflicts that are often real). Judge quality enters the instance score not
as a multiplier on `w`, but through `j_c` and through the arm-confirmation requirement. Caveat,
the same as for rubrics: arms are **not independent** — both are LLMs reading the same input and
sharing blind spots — so two agreeing arms are worth *less* than 2×. The correlation is
measurable; discount it or cap the multi-arm contribution (Dawid–Skene with dependence).

### 3.3 · The queue is also the label-collection instrument

Every queue row carries localized evidence plus a slot the human fills in:
`ours | judge | ambiguous`, with a free-text note. That verdict column **is** the adjudication
sample that estimates `d_c` — the quantity §2.4 shows is otherwise unmeasurable — and it
supplies the funnel's last two stages. Design the queue without it and the review is paid for
twice.

**Framework amendment:** Stage 3 → Stage 2 (weights) and Stage 3 → Stage 1 (labels) are
**feedback edges**. The framework is currently feed-forward; this work closes both loops, and
the closure is what makes the label economics work.

### 3.4 · Reporting discipline the framework should inherit

- **Operating point, not a score column**: a flag budget `k` (capacity-bound for v1), and
  `lift@k = precision@k / base_error_rate` reported as the **whole curve** (precision *and*
  recall, k = 5…100%) plus rank AUC — never a single k. The shippable sentence is the recall
  end: *"flag the top 15%, catch X% of all errors."*
- **MDE up front**, because it decides where the claim is even possible: on the 400-label axis,
  top-15% = 60 instances, precision CI ±12.6pp, so **detectable lift starts ≈2×**; on the
  ~71-label axes top-15% = 11 instances, ±29.6pp — *not measurable at any usable k*. Same-shaped
  conclusion as the power analysis in Stage 1, reached independently.
- **Pairing**: the same instance appears in C1 and every applicable C2 stratum ⇒ McNemar /
  paired bootstrap, not two independent proportions. **Resample instances, not judge calls** —
  a resampled instance brings all its conditions.
- **A "what was not covered" section**: abstention rate, axes excluded for insufficient labels,
  any top-N truncation. No silent caps — a report omitting its coverage reads as complete.
- **A may / may not table.** May: *"here is a ranked queue; on this axis it achieves lift L
  (95% CI …) against a measured 14.2% base error rate."* May not: any accuracy number for the
  agent; any lift claim on the low-label axes; any per-rubric precision before adjudication data
  exists.

---

## 4 · Auto-Eval — applying the calibrated judges to unlabelled data

The framework's Auto-Eval is this work's *deployment* of Stages 1–3 (explicitly **not** a fourth
stage). Its contribution is a **transfer taxonomy**, and the asymmetry in it is the single most
useful thing to carry into the framework:

| | on an unlabelled set |
|---|---|
| judge selection (the survivor set) | transfers, subject to shift |
| **`q₀` / `q₁`** | transfers **by assumption** — not re-measurable without labels |
| **`e_c`** (per-rubric noise floor) | **re-measurable directly** — `s_c` and `j_c` need no labels |
| ranked queue **ordering** | ✅ fully — needs only `e_c` |
| **class discovery** (binomial vs `e_c`) | ✅ **fully label-free — the strongest transfer in the method** |
| lift / catch rate | ❌ **not measurable** — `precision@k` and the base error rate both need labels |
| accuracy | ❌ never, by design |

**Class discovery survives the move almost intact; every quantitative claim about the queue does
not.** *"Rubric X conflicts on 40 instances, well above its noise floor"* is defensible on a new
slice. *"This queue catches 60% of errors"* is a transferred assumption wearing a number's
clothing.

**The named failure mode is distribution shift**, and it is not hypothetical: the
bias-corrected estimator "fails under realistic shifts where test and calibration distributions
have different true accuracy rates", and PPI requires the labelled and unlabelled sets be i.i.d.
([[LLM as a judge SOTA]] §6). So the framework needs **transfer sentinels** — all four
computable without labels:

| # | sentinel | reads as |
|---|---|---|
| 1 | input-adequacy shift (length distribution, template artifacts, null channels) | if the input distribution moved, transfer is suspect before anything else is examined |
| 2 | **abstention rate** vs the calibration set | a jump means the judge is out of its depth here |
| 3 | **arm–arm agreement** vs the calibration set | a collapse means the judges are guessing |
| 4 | **`e_c` recomputed** on the new slice | if it moved, **recompute the weights** rather than transferring them |

2 and 3 are the useful pair — both are proxies for *the judge no longer knows what it is doing
here*.

**And the upgrade path out of "proxy for human annotation":** label **30–50 instances** of the
new slice and use prediction-powered inference. A small human-labelled sample plus the large
judged set gives an **unbiased** population estimate regardless of the judge's error profile; at
ρ≈0.6 those 50 labels behave like ~78. This is the only honest route from a judge to a *reported
figure* on new data, and it is cheap enough to be routine per slice.

**Framework amendment:** replace *"a final score as a proxy for human annotations"* with a
three-way split — **ordering** (transfers), **classes** (transfer, label-free), **numbers**
(require an anchor sample) — plus the sentinel block and a version-pinning rule: a detector used
on unlabelled data is frozen and re-validated whenever the judge prompt, the agent prompt, or the
provider snapshot changes.

---

## 5 · What does not fit

Ordered by how much the framework has to change.

### 5.1 · Calibration item type ≠ deployed rubric type — a gap in both

Stage 1's items are **verification-mode**: the judge is shown a candidate answer and asked
whether the input supports it. Stage 2's calls are **elicitation-mode**: the judge is shown only
a rubric definition and produces a value, which is then diffed. These are different exposure
conditions, and the whole point of the source paper's *sensitivity* stage is that exposure to a
reference/candidate answer changes verdicts materially (flip rates 0.09–0.18 where the judge
knows the domain, up to ~0.85 where it does not; agreement with humans moved 0.11–0.88 → 0.81–0.97
between conditions). So `q₀`/`q₁` measured under verification are being carried into elicitation.
The framework, which has one calibration table and one rubric table, cannot even express the
mismatch.

**This is the item I would fix first.** Minimal fix: the framework carries an **exposure
condition** on every judge call, and states the constraint *calibration is valid only for the
(rubric type, exposure condition) it was measured in* — so switching Stage 2's surface (§2.3)
invalidates the Stage-1 numbers and requires re-calibration on rubric-level items.

### 5.2 · The sensitivity stage itself has no slot

The source protocol's second stage — verdicts under no-reference / reference-visible /
reference-plus-compare-instruction, measuring flip rate *and direction* — is not a judge-ranking
input and not a rubric result. This work resolves it by **fixing** the condition (blinded by
construction) rather than measuring it, which is a defensible design choice but discards the
measurement. The framework has neither the measurement nor a place to record which choice was
made.

**Fix:** either a Stage 1.5 (sensitivity) or, at minimum, a mandatory declared field —
*reference exposure: none / visible / compare* — attached to the calibration table, since the
strongest external result in the survey (No Free Labels: κ 0.78 → 0.14 on items the judge itself
got wrong; a weaker judge with human references beating a stronger judge with synthetic ones) is
a statement *about this axis*.

### 5.3 · Synthetic-perturbation calibration needs a metric on the answer space

C2(±k) presumes "one rung wrong" is definable. That holds for ordinal levels and for a code
ladder; it does not for free-text, sets, or unordered categoricals — where the framework will
also want Stage 1, and where the only available incorrects are the agent's actual errors (pass
1b) with all the coverage and drift problems that implies.

**Fix:** make the **perturbation operator** an explicit, typed component of Stage 1 —
`rung±k` for ordinals, label-swap for categoricals, targeted corruption for free-text — and
record that a scalar `reject(incorrects)` is only comparable across judges evaluated under the
*same* operator.

### 5.4 · Judge-level `w` and rubric-level weight are different objects; Stage 3 conflates them

The framework's Stage 3 says the final score comes from "the judge calibration table and the
rubric results" without specifying how `w` enters. In this work it does **not** enter as a
multiplier: judge fitness is a **gate** (kill switches) plus estimator parameters (`q₀`/`q₁`)
plus a noise term (`j_c`), while rubric weight is an **evidence LLR**. Multiplying a
gap-derived `w` into a rubric score would double-count `j_c` and has no probabilistic reading.

**Fix:** state in the framework that Stage 1's output is a *gate + parameters*, and that judge
quality reaches the instance score only via `j_c` and the arm-confirmation rule.

### 5.5 · The framework's fourth output class is missing: "not the judge, not the agent — the input"

A high abstention rate, or a rubric that is simply not decidable from the available input, is
neither a judge-quality result nor a defect class of the agent. It is an upstream-input finding,
and here it is one of the three *valuable* Stage-1 outcomes.

**Fix:** Stage 3 gets a fourth output — **input-adequacy findings** — fed by the abstention
column and by the span-drop rate.

### 5.6 · Non-independence breaks both aggregation formulas as written

`w = a + r` treats the two rates as if a judge's competence were one-dimensional; the log-odds
sum assumes rubrics fail independently; multi-arm confirmation assumes arms fail independently.
All three are false, and the last two are measurably false here.

**Fix:** carry the dependence structure as a first-class part of the aggregation spec (group
correlated rubrics, cap per-axis and multi-arm contributions, or fit Dawid–Skene with
dependence), rather than as a caveat.

### 5.7 · Cross-cutting requirements with no stage to live in

Provenance and staleness (judge-prompt hash, provider snapshot pin, agent-code SHA; *calibration
whose hash does not match the prompt in use is void*), the dev/holdout split, pre-registered kill
switches, and the ids-in / ids-out artifact split (per-instance artifacts internal, population
artifact shareable) are not stages. They are validity conditions on the whole framework, and
without them a framework diagram describes something unreproducible.

**Fix:** a short **Validity conditions** block alongside the three stages rather than inside any
one of them.

### 5.8 · Genuinely out of scope for a survey framework

Domain/deployment constraints that shape this instantiation but do not generalize: PHI routing to
specific providers, the mandate to not reason about model-call cost, cache-replay so a re-run does
not re-bill, and the local-only-vs-committed data policy. Worth one sentence acknowledging that a
judge pipeline has a data-governance surface; not worth a framework slot.

---

## 6 · Summary of implied amendments

| # | amendment | stage | cost |
|---|---|---|---|
| 1 | Drop the multiplicative `w`; use the calibration gap / Youden's J | 1 | none — arithmetic |
| 2 | Add the **exposure condition** field + the "calibration is valid only for its (rubric type, exposure)" constraint | 1→2 | none — a constraint |
| 3 | Abstention as a third column; span required, drop rate reported | 1, 2 | none |
| 4 | `reject(incorrects)` as a vector over perturbation severity, weighted by the agent's error profile | 1 | more items |
| 5 | Survivor set + pre-registered kill switches + CI/MDE, instead of top-k | 1 | none |
| 6 | Keep the same-family arm as an **instrument** (self-preference), add family/provider metadata | 1 | one pass |
| 7 | `q₀`/`q₁` as estimator parameters ⇒ dev/holdout split + prompt fingerprinting | 1 | halves usable labels |
| 8 | Typed perturbation operator (generalizes C2 beyond ordinals) | 1 | design |
| 9 | LLR rubric weights with label-free `e_c = 1 − (1−s_c)(1−j_c)`; shrinkage; dependence caps | 2 | repeat runs |
| 10 | Stage-2 cell = conflict tuple with spans, against a causally-upstream rubric set | 2 | none |
| 11 | Cause-attribution **funnel** replacing per-instance attribution | 3 | 2 arms + double review |
| 12 | Class discovery via one-sided binomial against `e_c`, with direction asymmetry + span clustering | 3 | none |
| 13 | Feedback edges 3→2 (weights) and 3→1 (labels) via the reviewer-verdict column | 3 | none — queue design |
| 14 | Operating point + full lift curve + MDE + "not covered" section | 3 | none |
| 15 | Auto-Eval transfer taxonomy + 4 label-free sentinels + PPI anchor sample | Auto-Eval | 30–50 labels/slice |
| 16 | A **Validity conditions** block (provenance, freezing, artifact ids split) | cross-cutting | none |
