---
updated: 2026-08-17
tags: [project, coding-pod, eval, auto-eval, llm-as-judge, calibration, ws-b0]
---
# Introduction

[[LLM as a judge SOTA]] §2

A reference-free judge over-credits the answer it is shown and is near-random precisely where it does not know the answer. This technique closes that gap without pretending to replace ground truth: it uses a cross-family LLM as a judge to disagree with our pipeline, but **calibrates the judge against the labels we already have first.

**Goal:** rank a review queue and surface defect *classes* — not produce an accuracy number. **Input:** a dataset's `input.csv` (the note), its `gt.csv` (for calibration only), and optionally a run dir for the pipeline's own per-criterion output. **Output:** a ranked review queue with a measured lift over random ordering, a per-criterion class table identifying broken prompts, and a `calibration.json` recording which judge on which axis was validated and how well.

Feeds [[auto eval proposal]] WS-B; gates [[tier 4 criterion judging]]. Literature:
[[LLM as a judge SOTA]]. Adapted from
[Kranti & Vajjala's](https://arxiv.org/abs/2607.12885) two-stage protocol.

> **Reading order.** § 1 is the method. § 2 is a worked example on one encounter, with no
> caveats — read that first if the method reads abstractly. § 3 is the reference layer:
> measured numbers, statistics, and the failure modes.

---

# 1 · The method

Three stages, and the ordering is the whole technique:

| stage | question | data needed |
|---|---|---|
| **1 · Calibrate** | Is the judge any good, and at *what*? | labelled rows only |
| **2 · Judge** | Where does the judge disagree with us? | any encounter, labelled or not |
| **3 · Aggregate** | What does a human receive? | stage-2 conflicts |

**The one rule: Stage 1 comes first.** Without it Stage 2 still emits a tidy list of
disagreements — you simply cannot tell whether the judge or the pipeline is the one that is
wrong.

## Stage 1 — calibrate the judge

### What this stage is for, and what it is NOT for

**It is a screening instrument for the judge *model*. It is not a tuning loop for the judge
*prompt*.** Getting this backwards is the main way the technique gets ruined. Four goals:

1. **Disqualify incompetent judges** before anything is spent on Stage 2. Note the verb:
   Stage 1 **eliminates**, it does not pick a single winner (§ Which arms carry forward). In the source paper
   this is exactly how the protocol is used — a judge that accepted ~60% of known-wrong answers
   was ruled out. Nothing was tuned; a model was rejected.
2. **Produce `q₀` and `q₁`** (specificity and sensitivity). These are not merely diagnostic —
   they are the parameters of the reporting estimator
   `θ̂ = (p̂ + q̂₀ − 1)/(q̂₀ + q̂₁ − 1)` ([[LLM as a judge SOTA]] §6). Without them no
   judge-derived number can be reported honestly.
3. **Localize the failure** — separate *judge incompetent* from *prompt broken* from *task not
   decidable from the note*. The `CANNOT_ASSESS` rate isolates the third, which is an
   `upstream-input` finding rather than a judge finding.
4. **Quantify self-preference** — the same-family arm against the cross-family arms (pass 1b).

### Where prompt work legitimately enters, and where it becomes Goodhart

| | verdict |
|---|---|
| **Fixing a broken prompt** — `accept(C1)` is low, so the judge rejects *correct* codings; cause is likely a prompt bug (wrong rubric text, missing level definitions, ambiguous instruction) | **legitimate.** Debugging an apparatus |
| **Tuning wording to maximize the C1−C2 gap** | **not legitimate.** Iterate against these 71 rows and they become in-sample; accept rates stop measuring competence and start measuring prompt fit to 71 charts — and the inflated `q₀`/`q₁` then corrupt the estimator |

Same rule as [[auto eval proposal]] §4 C-7 (*gating detectors are frozen and version-pinned;
iteration detectors are separate*), applied to the judge itself. **So Stage 1 needs a dev/holdout
split:** iterate the prompt on a dev slice, measure the *reported* calibration on a frozen
holdout the prompt never saw. Affordable on `pro` (100 dev / 300 holdout); at n≈71 per MDM axis
neither half is — meaning **any prompt iteration on the MDM axes burns the only labels we have.**

Freeze the judge prompt before touching the holdout and version-pin it with the fingerprint from
`core/prompt_source.py`. **A `calibration.json` whose prompt hash does not match the prompt in
use is stale by construction.**

### The one design change from the paper

The paper has a single C1 (known-correct) and single C2 (known-incorrect). On an ordinal axis
that conflates two different questions, so **C2 is stratified by rung distance**:

| condition | shown to the judge | a competent judge should |
|---|---|---|
| **C1** | the **GT** level | accept ≈100% |
| **C2(+1)** | GT **one rung up** — over-code | reject — **this is the one that matters** |
| **C2(−1)** | GT one rung down — under-code | reject |
| **C2(±2+)** | GT two or more rungs away | reject ≈100%; failure means incompetent, full stop |

This turns one number into a **detection curve over rung distance**, testing on our own rubric
and data what [[LLM as a judge SOTA]] §3 puts in doubt (AutoRubric measured ordinal 3–5-level
judging at only **38–58% exact**). Its output is the operational sentence we need:

> "The judge detects a one-rung over-code X% of the time (95% CI …)."

`C2(±2+)` is the **sanity floor** — but see § 3.5: two-rung errors barely exist in practice, so
it validates the judge rather than measuring anything operational.

### What the judge is asked

Directional and one-sided, never "is this correct?" — matching the compliance asymmetry already
in `docs/EVALUATION.md`:

> Here is the ED documentation. Here is the RISK rubric. **Is there documented support for
> RISK = Moderate, or does the documentation only support a lower level?**
> Answer `SUPPORTED` / `NOT_SUPPORTED` / `CANNOT_ASSESS`, with the decisive span.

Four rules, each load-bearing:

1. **One proposed level per call.** Never show two and ask which is better — that leaks the
   comparison and invites position bias.
2. **The judge never learns which condition it is in**, never sees GT, never sees our
   prediction. Randomize condition order across the run.
3. **`CANNOT_ASSESS` is first-class** and reported separately — never folded into accept or
   reject.
4. **Require a span.** A verdict with no pointer into the note is dropped — the mitigation for
   evaluator hallucination.

**Rubric text comes from the prod prompt** (`copa_prompt.py` / `data_prompt.py` /
`risk_prompt.py`) via `core/prompt_source.py`, so it is snapshotted and fingerprinted. A judge
graded against a paraphrased rubric measures the paraphrase.

### Two passes, and what each actually measures

C1/C2 items are built from **GT levels**, not from our output — so comparing a same-family arm
against cross-family arms on them measures **leniency**, not self-preference. Self-preference is
specifically *inflated credit for its own output*:

| pass | items built from | measures |
|---|---|---|
| **1a** | GT + synthetic rung perturbations | **discrimination and leniency** — is the judge competent at all |
| **1b** | our pipeline's *own* predicted levels, same encounters | **self-preference** — same-family accept rate vs cross-family on identical items |

Pass 1b is cheap (one item per encounter per arm) and is the only one that speaks to the
[No Free Labels](https://arxiv.org/html/2503.05061v1) finding.

### Judge arms — cross-family is the point

ED's generator is `claude-sonnet-4-6`, so:

| arm | model | purpose |
|---|---|---|
| A | **GPT-5.4** (`AZURE_GPT_54_OPENAI_*`) | cross-family judge |
| B | **Gemini-2.5-pro** (`VERTEX_PROJECT` + ADC) | second cross-family judge, different provider |
| C | **Claude** (same family as generator) | **instrument**, not a candidate — measures self-preference on pass 1b |

Both verifier keys already exist and `ed/verifiers.py` already calls both providers, so the data
path and its PHI review are precedent, not new.

### Kill switches — decide these before running

Written down first so the result cannot be rationalized afterwards:

| observation | conclusion |
|---|---|
| `accept(C2 ±2+)` materially above 0 | judge is not reading the chart. **Stop.** Nothing downstream is worth building |
| `accept(C1)` low | judge rejects *correct* codings — it will bury the queue in false flags; the rubric prompt is wrong before the judge is |
| `accept(C2 +1)` ≈ `accept(C1)` | judge cannot resolve one rung — AutoRubric's ordinal finding. **Level judging is dead**; go to the binary criterion surface, making **C0** (COPA/RISK schema completion) the critical path |
| `CANNOT_ASSESS` rate high | either the rubric is not decidable from the note (an `upstream-input` finding, valuable on its own) or the prompt is unclear |
| arm C ≫ arms A/B **on pass 1b** | self-preference confirmed; **clinic must not use a Claude judge** |
| winning arm's gap within ~12pp of a rival's | **at n≈71 that is noise, not a ranking.** Do not declare a winner — run both cross-family arms and use their agreement |

Three of these six are *useful findings* rather than failures. That is the property that makes
Stage 1 the right first step.

### Which arms carry forward — all survivors, not one winner

**Stage 1 eliminates; it does not select.** Every arm that clears the kill switches runs in
Stages 2 and 3. Three reasons:

1. **Stage 1 usually cannot distinguish the survivors.** At n≈71 a gap estimate carries a
   ~11.6pp CI half-width, so a 17pp-vs-19pp difference between two cross-family arms is noise.
   Declaring a winner is false precision — the last kill-switch row says exactly this.
2. **The cause-separation funnel requires ≥2 arms** (§ 3.2). Stripping "judge blind spot" means
   requiring a conflict be confirmed by two *independent* cross-family arms. With a single arm
   that stage cannot be performed at all: there is no way to separate arm-specific noise from a
   real disagreement, so you lose the ability to say what a conflict *means* — not merely some
   accuracy.
3. **Diversity, not redundancy.** AutoRubric found same-model ensembles gave strong judges only
   κ +0.051. But GPT-5.4 and Gemini differ in family, provider and training data, which is the
   case where ensembling actually buys something.

**How they combine — no new mechanism.** § 3.3 already treats each conflict as evidence weighted
`w = log(d_c / e_c)`; an arm is just another detector with its own instability `j_c`:

    encounter score = Σ over (arm, criterion) conflicts of w(arm, c)

Two arms conflicting on the same criterion contributes ~twice the log-odds of one, by
construction. And arm *disagreement* is not a problem to resolve — it is data: the arm-A-vs-arm-B
disagreement rate on a criterion **is** the estimate of `j_c` for that criterion.

**The mode differs by output:**

| output | mode | why |
|---|---|---|
| **class table** (§ 3.4) | require **both** arms (AND) | precision matters — a false class sends someone to rewrite a prompt for nothing |
| **queue ranking** (§ 3.3) | **weighted sum**; agreement raises the score | recall matters — a hard AND discards single-arm conflicts that are often real |

**Caveat, the same one as for criteria:** arms are not independent — both are LLMs reading the
same note and sharing blind spots — so two agreeing arms are worth *less* than 2× one arm. The
correlation is measurable (arm-A/arm-B agreement on criteria where our pipeline is stable), so
either estimate and discount it, or cap the multi-arm contribution. This is the
Dawid–Skene-with-dependence item in [[auto eval proposal]] 6.1.

## Stage 2 — judge, on the surface that survived

Stage 1 decides the surface. If level judging fails its kill switch, drop to the **criterion
booleans** — the layer AutoRubric measured at κ 0.642 versus QWK ~0.55–0.72 for ordinals.

- **One blinded call per criterion, per surviving arm.** Note + that single criterion's
  definition. The judge never sees our answer. Atomic evaluation prevents halo effects and makes per-criterion reliability
  computable.
- **Diff against our output** per (encounter, criterion, arm).
- **The output is a conflict with an address** — encounter, node, field, plus the span the judge
  did and did not find. Not "this encounter looks wrong", which is unactionable.
- **Runs on any encounter**, labelled or not. This is the step that generalizes beyond `gt.csv`.

**Choosing the criterion surface, explicitly:** two exist and they are not the same thing — the
**18 `llm_raw` booleans** that drive the pipeline, versus `guideline_report`'s 61 facility + 17
professional criteria, which are display-derived. Judging the latter may be judging a renderer.

## Stage 3 — aggregate and ship

The findings table is one row per **(encounter, criterion, arm)**. It aggregates two ways, and
**the second is worth more**:

| aggregate down… | you get | value |
|---|---|---|
| the **encounter** axis | a ranked review queue | helps a coder once, per chart |
| the **criterion** axis | a defect **class** | one criterion conflicting on 40 charts is **one bad prompt** — fix once, all 40 improve |

Ranking must use **reliability-weighted** conflicts, not raw counts (§ 3.3). Class discovery
tests each criterion's conflict rate against its own noise floor (§ 3.4).

### The four artifacts

| artifact | unit | ids | audience |
|---|---|---|---|
| `findings.json` | (encounter, criterion, arm) conflict | yes | machine; feeds the rest |
| `queue.csv` | encounter, ranked | yes | **the coder** |
| `calibration.json` | (judge model × axis × criterion) | no | provenance; **gates the other three** |
| `autoeval-<dataset>.md` | population | **no** | product + research; shareable |

Same ids-split discipline as `docs/EVALUATION.md`: per-encounter artifacts stay internal, the
population artifact can leave the room.

### The queue is also the label-collection instrument

A row reading "encounter `944069156`, score 3.2" wastes the coder's time — they would re-read the
whole chart. Every row carries localized evidence plus a slot for the verdict:

    enc_id, rank, score, axis, our_value, direction,
    criteria_conflicted,      # e.g. behavioral_health_safety_assessment
    our_span,                 # what we cited
    judge_span,               # what the judge found, or NONE
    arms_confirming,          # "2 of 2"  <- the judge-noise strip
    coder_verdict,            # [ ours | judge | ambiguous ]   <- THEY fill this in
    coder_note

**`coder_verdict` closes the loop.** It is the adjudication sample that estimates `d_c` — the
quantity § 3.3 shows is otherwise unmeasurable. A coder working the queue produces it as a
by-product. Design the queue without it and the review is paid for twice. It also supplies the
funnel's last two stages (§ 3.2): `ambiguous` verdicts are the label-ambiguity population, and
coder-vs-coder disagreement on double-reviewed rows is the ambiguity *rate*.

### Choosing the flag budget `k`

| approach | rule | when |
|---|---|---|
| **capacity-bound** | `k = coder_hours / minutes_per_review` | **v1.** It is what actually constrains us |
| precision floor | stop where precision@k falls to the base error rate | diagnostic — beyond it you are doing random review |
| conformal risk control | pick `k` s.t. recall ≥ X at 90% confidence, finite-sample valid | later ([[auto eval proposal]] 6.2) |

Ship capacity-bound, and **plot where the precision curve crosses the base rate** so a reader can
judge whether the budget is well chosen.

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
