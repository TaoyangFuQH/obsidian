---
updated: 2026-08-17
tags: [reference, coding-pod, eval, auto-eval, llm-as-judge]
---
# SOTA — LLM-as-a-judge, and what each finding does to our design

Companion to [[LLM as judge]], which is the durable copy of the *design* reasoning; this note
is the literature behind it. The proposal it feeds is [[auto eval proposal]].

The earlier `grounding/` dossiers covered *faithfulness*
(ERASER comprehensiveness/sufficiency, CoT-faithfulness) and *metamorphic testing*; neither
covered judge methodology itself. This is that gap, read against our surface: a **closed
rubric**, **5-rung ordinal axes**, **~71 labelled rows per axis**, and **cross-family
verifiers already running in ED**.

Every section ends with **⇒ ours** — the specific consequence. Findings that contradict
something we previously wrote are marked **⚠**.

---

## 1 · The frame the field has converged on

The 2024–2026 surveys land in the same place: *"merely employing LLM-as-a-Judge does not
ensure accurate evaluations."* A judge is an **instrument that must be calibrated against
the thing it claims to measure**, and the research question is not "which judge is best" but
"how do you build a *reliable* judge system." The survey formalizes this as a distinction
between a raw judge `ℰ ← 𝒫_LLM(x ⊕ 𝒞)` and a reliability-enhanced judge
`ℛ ← f_R(𝒫_LLM, x, 𝒞)` — where `f_R` is the systematic constraint layer (consistency
checks, robustness, human alignment) wrapped *around* the model call.

Almost everything below is a candidate `f_R`. The mistake the literature keeps documenting
is shipping `ℰ` and calling it `ℛ`.

**⇒ ours.** `core/judge.py` (on `origin/citation-eval-on-main`) is `ℰ` — a forced-tool call
at temperature 0. That is the right primitive and we should not rebuild it. Everything this
feature adds is `f_R`.

## 2 · Reference dependence — the deepest result, and the one that bounds us

This is the single most important body of evidence for a reference-free design, and it is
worse than my earlier one-line summary implied.

**⚠ Correction to what I said earlier.** I wrote "adding a reference flips up to 85% of
verdicts." That 0.85 figure is the *extreme* of the range, and it comes from **Telugu** — a
low-resource language where the judge does not know the domain. For English and Arabic the
NR→RV flip rates were **0.09–0.18**. The honest statement is: **the flip rate scales with
how well the judge knows the domain**, from ~10% (judge is competent) to ~85% (judge is
not). That framing matters more than the headline, because it tells you which end of the
range applies to you.

[Kranti & Vajjala 2026](https://arxiv.org/abs/2607.12885) — three languages, two datasets,
four generators, three judges — ran a **two-stage protocol** worth copying wholesale:

| stage | what it does |
|---|---|
| **Calibration** | Show the judge known-**correct** answers (C1) and known-**incorrect** answers (C2). A competent judge accepts ~100% of C1 and ~0% of C2. The **calibration gap (C1 − C2)** is the judge's competence on *this* task |
| **Sensitivity** | Compare verdicts under **NR** (no reference), **RV** (reference visible), **RC** (reference + explicit compare instruction). Measure flip rate and direction |

Results: in Telugu one judge accepted **incorrect answers ~60% of the time**. Flips were
overwhelmingly CORRECT→INCORRECT — i.e. the judge *withdrawing credit it should never have
given*. Agreement with human annotators (n=400, inter-annotator κ 0.96–0.99) went from
**0.11–0.88 (NR)** to **0.81–0.97 (RV)**. Notably, RV→RC flips were only 0.01–0.24: **merely
seeing the reference does most of the work**; instructing the judge to compare adds little.

[No Free Labels](https://arxiv.org/html/2503.05061v1) supplies the mechanism, and this is the
finding to internalize:

> GPT-4o's pairwise agreement dropped from **κ 0.78 → 0.14** on the questions *it answered
> incorrectly*, when using self-generated references.

**The judge is reliable exactly where it already knows the answer, and near-random where it
does not.** Weaker judges sat at κ ~0.17–0.25 on hard items. With human gold references
GPT-4o reached 0.85 pairwise agreement; without, 0.47. And the ordering result:

> A **weaker** judge with **high-quality references** beats a **stronger** judge with
> **synthetic** references.

Self-preference is measured as an asymmetry: false-positive rates (wrong marked correct) are
significantly higher when a model judges its own output, and this worsens without references.
Supplying *wrong* references inverts it into high false negatives.

**⇒ ours, and this is the load-bearing consequence.** Our judge's blind spot is *correlated
with our pipeline's blind spot*, and the correlation is strongest on exactly the encounters
we care about. A judge that does not know whether this chart supports RISK=Moderate is
near-random there — and that is precisely the population where our pipeline is also
uncertain. Three concrete consequences:

1. **Run the calibration stage before building anything.** We can do it *today* on the ~71
   labelled rows per axis: feed the judge known-correct and known-incorrect codings and
   measure the C1/C2 gap. This is far cheaper than a PR curve and answers "is this judge
   competent on ED MDM at all?" — a question we have never asked.
2. **Prefer criterion-level questions**, where the "reference" is the documentation itself
   and sits *in the prompt*. Criterion entailment is closer to the RV regime than the NR
   regime. Asking "is this code right?" is pure NR.
3. **Clinic is the acute risk** — Claude-Opus judged by Claude is self-preference by
   construction.

## 3 · Rubric decomposition — and the one result that most changes our design

[AutoRubric](https://arxiv.org/html/2603.00077v2) is the most directly transferable paper in
this set, because it measures judge reliability **as a function of criterion type**, and our
axes are a specific type.

| criterion type | exact agreement | adjacent | κ |
|---|---|---|---|
| **binary** (MET / UNMET) | **87%** | — | **κ = 0.642** |
| **ordinal, 3–5 levels** | **38–58%** | **85–93%** | **QWK 0.549–0.719** |
| nominal | asymmetric — 0.70 recall detecting brevity vs **0.14** detecting verbosity | | |

**⇒ ours, and this is the headline.** `copa` / `data` / `risk` are **5-rung ordinals**
(`none/minimal/low/moderate/high`). This is the ordinal row. A judge asked for the *level*
gets it exactly right **38–58%** of the time — but lands adjacent **85–93%** of the time.
Read against our own metric set, which already carries QWK and MAE for ordinal axes
(`docs/METRICS.md`), that is a precise statement of what a level-judge can and cannot do:

- **It cannot adjudicate a one-rung disagreement** — the most common and most commercially
  important case, since one rung is one CPT code.
- **It can flag a two-rung gap** as almost certainly real.
- **The binary criterion booleans are the reliable surface** (κ 0.642 vs QWK ~0.55–0.72 on a
  task where chance agreement is much higher). This is independent confirmation, from
  measurement rather than from principle, that [[auto eval proposal]] §3 WS-C is pointed at the right
  layer — and it raises the stakes on **C0** (completing the COPA/RISK schemas), because
  binary criteria are only useful if they determine the level.

Four more AutoRubric results, each with a direct consequence:

**Atomic evaluation, one call per criterion.** Prevents halo effects and criterion
conflation, and — the part that matters for us — makes **per-criterion κ** computable, so you
can find out *which* criteria are unreliable rather than getting one uninterpretable number.
Disagreements concentrated in **subjective constructs (27.9%)** vs **factual ones (14–15%)**.
⇒ ours: this is the empirical basis for [[auto eval proposal]] C5 (exclude criteria two coders would
routinely disagree on) — and it gives us the statistic to *identify* them instead of guessing.

**Same-model ensembles are nearly worthless for strong judges.** Full mitigation stack lifted
Gemini-3-Flash by **κ +0.051**; weak models gained up to **26 points**. ⇒ ours: **clinic's
three same-model Opus votes are close to zero information about correctness.** They measure
sampling noise. This is the strongest external argument for WS-A4 (add one cross-family arm to
clinic) and it reframes the existing "3-vote ensemble" — it is a stability instrument, not a
correctness instrument.

**Few-shot calibration with verdict-balanced sampling was the single most impactful
mitigation** — 77.2% → 80.0%, and removing it cost −15.0pp on the weakest model. Balanced
verdicts matter because otherwise the judge infers a base-rate prior from the examples. ⇒
ours: with six of eighteen criteria under a 2.5% base rate, an unbalanced few-shot set would
teach the judge to always answer "false". Verdict-balanced sampling is mandatory, not an
optimization.

**`CANNOT_ASSESS` as a native verdict**, with configurable handling (SKIP / ZERO / PARTIAL /
FAIL). ⇒ ours: exactly our `ambiguous` first-class verdict, and it must be plumbed from the
tool schema through aggregation, not collapsed at the end.

**Negative criterion weights** counteract documented leniency bias. ⇒ ours: aligns with the
one-sided compliance framing — over-coding on the billed axis is the asymmetric risk.

And the finding that most supports our goal ordering:

> *"Judges agree on which questions are hard more consistently than on which system is
> best"* — pooled criterion-level inter-judge κ = 0.53.

**⇒ ours.** Judges are better at identifying *hard cases* than at *scoring*. That is
G1 (queue ranking) and G2 (defect classes) over G4 (accuracy), stated as a measurement rather
than as our caution.

## 4 · The bias taxonomy, and what actually mitigates each

Consolidated from [the survey](https://arxiv.org/html/2411.15594v6) and AutoRubric's
ablations. The right-hand column is what we would actually do.

| bias | mechanism | mitigation | applies to us? |
|---|---|---|---|
| **Position** | verdict tracks presentation order | swap and average; deterministic per-eval option shuffling; mark conflicts as tie | **yes** — C4 adjudication sees two arms |
| **Self-enhancement** | model prefers its own output | cross-family judge; blinding | **yes, acutely in clinic** |
| **Verbosity / length** | longer = better | multi-source averaging; offset-bias data | mild — our outputs are structured |
| **Concreteness** | specific-sounding claims over-credited | offset-bias training data | **yes** — our `evidence` strings are quotes, and 29.8% are not verbatim |
| **Reference dependency** | verdict swings on reference presence | reference-drop paradigm | **yes** — §2 |
| **Format** | schema/style preference | forced tool schema (we already do this) | handled |
| **Calibration drift** | judge strictness moves over time / versions | version pinning; periodic re-validation | **yes** — provider snapshots rotate |
| **Leniency** | default to crediting | negative weights; directional prompting | **yes** |
| **Evaluator hallucination** | judge fabricates flaws in the candidate | require a span pointer per finding | **yes** — and we already have this rule |

The survey's own honest note: for self-enhancement bias it does **not** offer a validated
mitigation. Cross-family judging is a structural workaround, not a fix.

Two robustness findings worth carrying: **prompt sensitivity** (minor wording changes shift
grading strictness and score distributions) and **fragility of rule-based token extraction**
— the second is why forced-tool structured output is the right call, and `core/judge.py`
already fails loudly on `stop_reason == max_tokens` rather than returning a partial `{}`.

## 5 · Selective judging with a provable human-agreement guarantee

This is the frame I would actually adopt, and it is the piece missing from every version of
our plan so far.

[Trust or Escalate (ICLR 2025)](https://arxiv.org/html/2407.18370) turns "how accurate is the
judge?" into a *different and answerable* question: **"on what fraction of cases can the
judge match a human, with a guarantee?"** It provides

    P(judge agrees with human | judge chose to evaluate x)  ≥  1 − α,   w.p. ≥ 1 − δ

**How.** Confidence comes from **Simulated Annotators**: prompt the judge N times (N=5) with
K-shot examples (K=5) drawn from *different* human annotators, and take the max agreement
ratio across simulations. Confidence is low when simulated annotators disagree with each
other. This cut expected calibration error **~50%** versus predictive probability, and works
on models as small as Mistral-7B. Thresholds are then calibrated by **fixed-sequence testing**
on a calibration set (they used |D_cal| = 500, δ = 0.1) with exact binomial upper bounds —
tested from λ=0.999 downward until the bound clears α.

**The cascade.** Cheapest judge first; escalate only on low confidence; each stage's threshold
calibrated on the instances prior stages abstained on, with a union bound preserving the
overall guarantee.

**The numbers, which are the point:**

| setting | method | coverage | guarantee held |
|---|---|---|---|
| TL;DR, target 90% agreement | cascaded selective | **55.7%** | **90.8%** |
| TL;DR, target 90% | GPT-4, no abstention | 100% | **0%** |
| ChatArena, target 85% | cascaded selective | 63.2% | 91% |
| ChatArena, target 85% | GPT-4 point-estimate calibration | 60.9% | 54.4% |

Read that first pair carefully: **GPT-4 judging everything met the 90% agreement target zero
percent of the time.** The cascade met it 90.8% of the time by declining to judge 44% of
cases. Cost fell 40% versus GPT-4-without-abstention; with weaker cascades, to 12.6%.

**⇒ ours.** This is the honest shape of auto-eval for a compliance product, and it maps onto
machinery we already have:

- The **abstention gate** already exists in both products (ED registered-but-off; clinic
  landed in prod). Prod already believes in "decline rather than answer badly." Selective
  judging is the same idea applied to the *evaluator*.
- The output is exactly the operating point [[auto eval proposal]] asks for — "flag the top k%, catch
  ≥X%, 90% confidence" — but with a *human-agreement* guarantee rather than an error-rate
  guarantee, which is the more defensible claim when the alternative to the judge is a coder.
- Simulated Annotators needs **multiple human annotators per instance**. We have single-labeler
  `gt.csv`, plus reviewer `feedback/*.csv` on a separate axis. **Naming this as a gap is
  itself a result:** the cheap confidence estimator in the literature assumes annotator
  diversity we have not collected, and our 3-vote / cross-family dissent (WS-A3) is the
  closest substitute we own.
- 500 calibration instances vs our 71 per axis. Same wall as [[auto eval proposal]] §3.1, reached from
  a different direction — which is corroboration, not coincidence.

Adjacent work worth a look if we pursue this: margin-adaptive confidence ranking, conformal
Elo for calibrated rankings, and deferral-specialization for judge cascades.

## 6 · Getting from a judge to a number, honestly

Two complementary mechanisms. Both need labels; neither needs the judge to be *good*.

**(a) Bias correction for a single rate.**
[How to Correctly Report LLM-as-a-Judge Evaluations](https://arxiv.org/html/2511.21140v4):

    θ̂ = (p̂ + q̂₀ − 1) / (q̂₀ + q̂₁ − 1)

`p̂` = raw judge rate; `q̂₀`, `q̂₁` = judge specificity and sensitivity from a human-labelled
calibration set. Report an adjusted Wald CI carrying **both** test-set and calibration
uncertainty. Valid only when `q̂₀ + q̂₁ > 1`.

The failure it fixes is *directional*: naive reporting **overestimates when true performance
is low and underestimates when it is high** — whenever the judge is imperfect. Two caveats
the authors state plainly: the method degrades under calibration/test distribution shift, and
on Chatbot Arena today's judges **fail to beat human-only variance**, so the statistical
advantage is not automatic.

**(b) PPI for population estimates.**
[GLIDE](https://arxiv.org/html/2605.31278) gives the practical recipe. PPI++ for a mean:

    θ̂ = (1/n)Σ Yᵢ  +  λ[ (1/N)Σ f(Xⱼ)  −  (1/n)Σ f(Xᵢ) ]

Human-labelled mean, corrected by the judge's mean difference between unlabelled and labelled
data. `λ` is closed-form and variance-minimizing, so **PPI++ never does worse than
human-only**. Gains scale with judge–truth correlation ρ:

| ρ | effective sample size from 500 labels |
|---|---|
| 0.1 | ~500 (no gain) |
| 0.5 | moderate |
| 0.9 | ~1,100 (**2.2×**) |

Their worked case: 568 items, n=100 human labels, judge bias **+13pp**, ρ≈0.59 → stratified
PPI++ gave **20% narrower intervals**, ≈157 effective labels from 100. Human effort multiplied
**1.57×** — *not* by trusting a biased judge, but by debiasing it.

Practical rules: **≥50 labelled per stratum** for CLT estimators, below that use bootstrap
Predict-Then-Debias; stratification bought 20% width on five domains; requires i.i.d. labelled
and unlabelled sets (no covariate or label shift) and a judge not trained on the eval data.
Coverage is distribution-free — *"a worse proxy yields wider intervals, not invalid ones"* —
but valid intervals on the wrong metric are still uninformative.

The sentence to carry into any planning conversation:

> **"Better proxies are not a substitute for human annotation; they are a multiplier on it."**

**⇒ ours.** This kills the hope that a good judge removes the label ask. At ρ≈0.6 — plausible
for us — 100 labels behave like ~157. That is a real gain and worth having, but it means the
label budget is set by the CI we need, and the judge only shrinks it ~1.5×. It also gives the
stratification design directly: **stratify by dissent** (WS-A3), which both concentrates
information and satisfies the ≥50-per-stratum rule better than uniform sampling.

## 7 · The domain: what is known about LLMs and medical coding specifically

Three separate findings, and they cut in different directions.

**Direct code assignment is weak.**
[NEJM AI](https://ai.nejm.org/doi/full/10.1056/AIdbp2300040): GPT-4 exact-match — ICD-9-CM
45.9%, ICD-10-CM 33.9%, **CPT 49.8%**. Conclusion: *"not appropriate for use on medical coding
tasks without additional research."* Corroborated by
[PMC12599997](https://pmc.ncbi.nlm.nih.gov/articles/PMC12599997/): on 958 MIMIC-IV admissions
/ 8,576 ICD-10 codes, a vanilla LLM got **17.95%** average recall; their generation-then-
retrieval method (GAVS) got **20.63%** (p<.001). Both are low in absolute terms. Documented
failure modes: **hallucinating codes not in the ontology**, and **diffuse predictions** (15,572
unique subcategories vs 11,254 when constrained). Their fix is architectural — generate
granular entities, then map each to the ontology by vector search, so *every* output code is
ontology-valid by construction.

**⇒ ours.** Never ask the judge for a code. Our pipeline already has the right shape here —
deterministic `ed-calculate-codes` from extracted criteria — and the literature says that
constraint is exactly what makes it work. A judge asked "should this have been 99284?" is
being asked the 49.8% question.

**Judging clinical *text* against criteria works well.**
[npj Digital Medicine](https://www.nature.com/articles/s41746-025-02005-2) on EHR multi-document
summaries: GPT-o3-mini reached **ICC 0.818 (95% CI 0.772–0.854)**, median score difference **0**
from human raters, in 22 seconds per evaluation.

**⇒ ours.** The gap between 49.8% (assign a code) and ICC 0.818 (assess text against stated
criteria) *is* the design. Stay on the right side of it.

**The healthcare-wide picture, and its governance asks.**
[LLM-as-a-Judge in Healthcare: a scoping analysis](https://arxiv.org/html/2605.25273), 134
studies:

| statistic | range | median |
|---|---|---|
| raw agreement (13 studies) | 0.66–0.96 | 0.83 |
| Cohen's κ (10 studies) | 0.59–0.88 | — |
| Pearson/Spearman (13 studies) | 0.40–0.94 | 0.69 |

Ensembles cluster at the high end; subjective multi-dimensional tasks at the low end. Even
*within* a model family, κ swung from 0.88 (medical image quality) to much lower on
behavioral-health assessment — **task, not model, dominates.** Named failure modes: shared-family
bias, surface-level conflation (fluency and organization mistaken for accuracy), shallow
clinical reasoning (chronic vs new diagnoses, misread terminology), **evaluator hallucination**
(fabricating flaws in the candidate), prompt sensitivity.

Recommendations, all of which are governance rather than modelling: **triage over autonomy**
("evaluation co-pilots… routing uncertain or high-stakes cases to human experts"),
risk-stratified architecture, continuous re-validation as guidelines change, audit logs and
version tracking, and **prospective silent-mode validation before deployment influences
decisions**.

**⇒ ours.** Three of these are already repo policy in different words (version pinning,
frozen gating detectors, human-confirmed dispositions). Two are not: **silent-mode prospective
validation** and **re-validation on guideline change** — and E/M guidance moves annually, so
a `calibration.json` older than the prompt it judges is stale by construction. That belongs in
the artifact contract.

## 8 · Agreement statistics — and a refinement of what I wrote earlier

**⚠ Refinement.** [[auto eval proposal]] §3 WS-B3 says "Gwet AC1 / Krippendorff, **not** Cohen's κ."
That is too strong. The literature is real but two-sided:

- The **kappa paradox** is real: with a dominant class, expected chance agreement `Pe` becomes
  large and κ collapses toward zero (or negative) despite 95%+ raw agreement. At 5% prevalence,
  raters who always answer "exclude" agree ~90% by construction.
- **AC1 is paradox-resistant** — it tracks observed agreement and is largely insensitive to
  prevalence, which is why several methodological reviews now recommend it as a default for
  screening reliability.
- But [AC1 is not a strict substitute for κ](https://pmc.ncbi.nlm.nih.gov/articles/PMC10205778/):
  they answer different questions, and AC1's insensitivity to prevalence is a modelling choice,
  not a correction of an error.

The defensible recommendation is **report all four: raw percent agreement, Cohen's κ, Gwet's
AC1, and the marginal prevalence** — never κ alone, and never AC1 alone.

**⇒ ours.** This matters concretely: six of eighteen criterion booleans have base rates under
2.5%, and one is never true in 402 encounters. That is the paradox regime exactly. Any
per-criterion reliability table we publish must carry prevalence beside the coefficient, or a
reader cannot tell a reliable criterion from an unbalanced one. For ordinal axes use
**quadratic-weighted κ** (AutoRubric's choice, and consistent with the QWK already in
`docs/METRICS.md`).

---

## 9 · Net effect on the proposal

| # | finding | consequence |
|---|---|---|
| 1 | Ordinal 3–5 level judging: 38–58% exact, 85–93% adjacent | **A level-judge cannot adjudicate a one-rung disagreement** — the commercially important case. Judge binary criteria (κ 0.642), which raises the priority of C0 |
| 2 | Judge κ 0.78 → 0.14 on items it gets wrong | Judge blindness is correlated with pipeline blindness. Bounds every LLM tier; not fixable by prompting |
| 3 | Same-model ensembles ≈ no gain for strong judges (κ +0.051) | **Clinic's 3 Opus votes are a stability instrument, not a correctness one.** Cross-family arm (A4) promoted |
| 4 | Judges agree on *which items are hard* (κ 0.53) more than on scores | G1/G2 (rank, localize) confirmed by measurement, not just by caution |
| 5 | Selective judging: 55.7% coverage at a *guaranteed* 90% human agreement; GPT-4-everything met it 0% of the time | **Adopt the selective frame.** "Judge where we can guarantee agreement, abstain elsewhere" — and it mirrors the abstention gate already in prod |
| 6 | Simulated Annotators needs multiple annotators per instance | We have single-labeler GT. Real gap; our dissent signal is the closest substitute |
| 7 | PPI at ρ≈0.6 turns 100 labels into ~157 | The judge is a ~1.5× multiplier on labels, not a replacement. Stratify by dissent |
| 8 | Calibration/sensitivity two-stage protocol (C1/C2 gap) | **Runnable today on 71 rows.** Cheapest possible answer to "is this judge competent on ED MDM at all?" — a question we have never asked |
| 9 | CPT exact match 49.8%; ICD recall ~20% | Never ask the judge for a code. Our deterministic `ed-calculate-codes` is the architecture the literature recommends |
| 10 | Clinical-text-against-criteria judging: ICC 0.818 | The safe side of the line. Criterion entailment, not code assignment |
| 11 | Verdict-balanced few-shot is the single biggest lever (−15pp when removed) | Mandatory given 6/18 criteria under 2.5% base rate |
| 12 | Kappa paradox at low prevalence | Report raw agreement + κ + AC1 + prevalence together; QWK for ordinals |

**The one addition to [[auto eval proposal]] I would make on the strength of this:** insert a
**WS-B0 — the calibration/sensitivity protocol (§2)** ahead of everything else in WS-B. It
costs a few hundred judge calls on already-labelled encounters, needs no new labels, and its
C1/C2 gap is a genuine kill switch: a judge that accepts known-wrong ED codings at a
material rate cannot rank a queue either, and we would know that before writing any of WS-C.

## Sources

**Judge methodology** ·
[A Survey on LLM-as-a-Judge](https://arxiv.org/html/2411.15594v6) ·
[Autorubric](https://arxiv.org/html/2603.00077v2) ·
[Trust or Escalate (ICLR 2025)](https://arxiv.org/html/2407.18370) ·
[Margin-Adaptive Confidence Ranking](https://arxiv.org/pdf/2605.15416) ·
[Conformal Elo Estimation](https://arxiv.org/html/2606.13221v2) ·
[Share the Judge, Learn the Deferral](https://arxiv.org/html/2607.27984v1)

**Reference dependence** ·
[LLM Judges Can Be Too Generous When There Is No Reference Answer](https://arxiv.org/abs/2607.12885) ·
[No Free Labels](https://arxiv.org/html/2503.05061v1)

**Statistics** ·
[How to Correctly Report LLM-as-a-Judge Evaluations](https://arxiv.org/html/2511.21140v4) ·
[GLIDE / PPI in practice](https://arxiv.org/html/2605.31278) ·
[Statistically Reliable Ranking via PPI](https://arxiv.org/abs/2606.05308) ·
[Adaptive Prediction-Powered AutoEval](https://arxiv.org/html/2505.18659) ·
[Kappa paradox](https://pmc.ncbi.nlm.nih.gov/articles/PMC5712640/) ·
[Kappa vs AC1](https://link.springer.com/article/10.1186/1471-2288-13-61) ·
[AC1 is not a substitute for kappa](https://pmc.ncbi.nlm.nih.gov/articles/PMC10205778/)

**Domain** ·
[LLM-as-a-Judge in Healthcare: scoping analysis](https://arxiv.org/html/2605.25273) ·
[LLMs Are Poor Medical Coders (NEJM AI)](https://ai.nejm.org/doi/full/10.1056/AIdbp2300040) ·
[Guideline-based planning + automated coding (GARAG/GAVS)](https://pmc.ncbi.nlm.nih.gov/articles/PMC12599997/) ·
[Clinical AI summaries with LLM judges (npj Digital Medicine)](https://www.nature.com/articles/s41746-025-02005-2) ·
[CPTCoder (ACL 2026 demo)](https://aclanthology.org/2026.acl-demo.60.pdf)
