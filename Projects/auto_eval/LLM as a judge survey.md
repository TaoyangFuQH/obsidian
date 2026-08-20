---
source: https://app.notion.com/p/Survey-of-LLM-as-a-Judge-3c01358f13e180e1aa59e60908063b7a
updated: 2026-08-17
tags: [reference, llm-eval, auto-eval, llm-as-a-judge]
---
# Survey of LLM-as-a-Judge

*Date: 2026-08-17 · Source: [Notion — Coding Reports / AI/ML Team](https://app.notion.com/p/Survey-of-LLM-as-a-Judge-3c01358f13e180e1aa59e60908063b7a)*

# 1. Introduction

LLM-as-a-judge means auto-evaluating a target agent's output with an LLM, i.e., the judge, rather than a human. Given a data instance and the agent's result, the judge is asked to (1) score quality, as one aggregated score, or as a score per rubric criterion; and (2) name the defect or failure class. Those two outputs feed three things: (1) a ranked review queue a coder or an RCA can start at, (2) a defect class pre-localized to a node, field and span; and (3) a population accuracy number.

However, the 2024–2026 surveys conclude: *"merely employing LLM-as-a-Judge does not ensure accurate evaluations"* ([survey](https://arxiv.org/html/2411.15594v6)) because a judge is reliable exactly where it already knows the answer ([No Free Labels](https://arxiv.org/html/2503.05061v1)). Judges also over-credit whatever answer is placed in front of them, and once a reference becomes visible their verdicts flip overwhelmingly ([Kranti & Vajjala](https://arxiv.org/abs/2607.12885)). The judge is a proxy, but not a substitute, for human annotations. For example, some researches reported, a judge-to-truth correlation ρ≈0.6, [prediction-powered inference](https://arxiv.org/html/2605.31278) turns 100 human labels into ≈157 effective ones.

To build judges, we involve a small set of human annotations to calibrate LLMs as judges in three stages, and after that, we are able apply the judges for auto-evaluation.

## Stage 1. Judge Calibration

It is a stage to evaluate the capability of a judge. Show the judges, the agent outputs and human annotations, and then the judges return accept / reject / ambiguous for each agent output, to form an **instance × output × judge** matrix. Ideally, a good judge would have high accept rate with the agent on correct cases `accept(corrects)`, high reject rate on incorrect cases `reject(incorrects)`, and low ambiguous rate among corrects and incorrects. Then, based on the instance × output × judge matrix, to select or weigh judges. For example, select judges based on the rates, e.g., `w = 1 - (1 - accept(corrects))(1 - reject(incorrects))` or `w = accept(corrects) + reject(incorrects) - 1` as shown below; or select judges based on the correlations between judges.

| judges | accept(corrects) | reject(incorrects) | accept(corrects) + reject(incorrects) - 1 |
|---|---|---|---|
| GPT-5.4 | 88% | 29% | 0.17 |
| Gemini | 84% | 35% | *0.19 |
| Claude | 93% | 14% | 0.07 |

## Stage 2. Judging with Rubrics

With a list of manual-designed rubrics / criteria, e.g., *has_chronic_severe_exacerbation for COPA,* for each data instance, one call per rubric, per surviving judges to ask whether this rubric holds or not, where the option could be booleans / ordinal / categorical / ambiguous. The output is an **instance × rubric × judge matrix**. The note is that keeps single rubric definition simple, and the judge never sees agent answer or human annotations. We also need to weigh each rubric, by such as uniform weight, manual defined, or learned correlation coefficients by logistic regression to fit human labels. For example, for an instance, the **rubric × judge matrix** is like:

| *Rubrics | *Weight | Opus 5 | Gemini-3-Flash | GPT-5.4 |
|---|---|---|---|---|
| R1 | 10.0 | Yes | Yes | Yes |
| R2 | 8.0 | moderate (0.75) | low (0.50) | high (1.00) |
| R3 | -15.0 | No | No | Yes |

## Stage 3. Aggregation

Based on the judge calibration matrix (an **instance × output × judge** matrix) and the rubric matrix (a **instance × rubric × judge matrix**), we can (1) evaluate the quality of judges, e.g., correlations of judges with human annotations; (2) generate a final score of each data instances among human annotations for further reviews; (3) the rubrics results help to detect defect classes. For example, given a the rubric matrix from a judge as shown below,

- **Along the rows (→)** = one score per instance → sort → the **review queue**.
- **Down the columns (↓)** = one conflict rate per criterion → **defect classes**.

| Instance \ Rubric | R1 prescription | R2 controlled_sub | R3 behavioral_health | R4 life_threat | row total |
|---|---|---|---|---|---|
| enc A | ✅ | ✅ | ⚠️ | ✅ | 1 |
| enc B | ✅ | ⚠️ | ⚠️ | ✅ | 2 |
| enc C | ✅ | ✅ | ⚠️ | ✅ | 1 |
| enc D | ✅ | ✅ | ✅ | ✅ | 0 |
| … | | | | | |
| column conflict rate | 0.5% | 4% | **34%** | 1% | |

When you see a conflict, it can be three different things:

1. **Agent is wrong** (genuinely needs fixing)
2. **The label itself is ambiguous** (two human experts would give different answers)
3. **The judge has a blind spot** (agent is right; the judge misread)

**By aggregating** the rubrics matrix over judges, which is the most important point in Stage 3, we can detect the defect classes.

- For the instances, few judges fire conflicts → more likely are noises → judge blind spot
- For the instances, majority judges fire conflicts → 2nd human review
	- disagree → label ambiguous
	- agree → agent is wrong

## Auto-Eval

Once we have built judges with human annotations, we can apply judges to auto-evaluate data instances without human annotations, i.e., a final score as a proxy for human annotations; and rubrics results to detect defect classes.

In the following, we will introduce related works in Section 2, list biases which make judges failed in Section 3.

# 2. Related Works

The following are the SOTA of LLM-as-a-judge and each one aims to design different approaches among the three stages.

## 2.1. Calibration–Sensitivity Protocol ([Kranti & Vajjala 2026](https://arxiv.org/abs/2607.12885))

**Stage 1. Calibration**

- The authors stratify **synthetic incorrect cases** by perturbation severity, e.g., moderate → minimal (-2), low (-1) and high (+1). Why? The strata are not equally hard, and they are not equally common. Catching moderate → minimal is easy; catching moderate → high is the hard case. Moreover, the real incorrect cases from human annotations would be hard cases.
- **Abstention** is a third outcome beside accept and reject. A high abstention rate localizes the failure *upstream*.
- **Eliminate judges, do not rank.** Why? Elimination needs only a coarse comparison while ranking needs to resolve small differences between two judges that both passed, which it does not. The authors proposed six kill switches:
	1. Accepting far-off answers at a material rate means the judge is not reading the input at all, so stop, since nothing downstream is worth building
	2. A low accept rate on correct answers means it will bury the queue in false flags, and the rubric text is suspect before the judge is
	3. Accept on one-step-wrong ≈ accept on correct means it cannot resolve one step, so ordinal judging is retired in favour of binary criteria
	4. A high abstention rate means the rubric is not decidable or the prompt is unclear
	5. A same-family arm well above the cross-family arms on pass 1b confirms self-preference and bans that family as judge for that agent.
	6. A leader within ~12pp of a rival is not a ranking.
- **Select** surviving judges for **decorrelation**, not only for score. Then, combining survivors needs no new mechanism, but the mode differs by output. Each (judge, rubric) conflict is another detector with its own instability, so the instance score is a log-odds sum over those pairs and two arms conflicting on the same rubric contributes about twice the evidence by construction. The class table takes the AND across arms, because a false class sends someone to rewrite a prompt for nothing; the queue takes the weighted sum, because a hard AND discards single-arm conflicts that are often real. Arm disagreement is not a problem to resolve — it is the instability measurement.

**Stage 2. Rubrics**

- Each cell in the **instance × rubric × judge matrix** is a **conflict tuple**, i.e., judge verdict diffed against the agent's value. For example, for a judge, the **instance × rubric** matrix is like (⚠️ = conflict):

| Instance \ Rubric | R1 prescription | R2 controlled_sub | R3 behavioral_health | R4 life_threat | row total |
|---|---|---|---|---|---|
| enc A | ✅ | ✅ | ⚠️ | ✅ | 1 |
| enc B | ✅ | ⚠️ | ⚠️ | ✅ | 2 |
| enc C | ✅ | ✅ | ⚠️ | ✅ | 1 |
| enc D | ✅ | ✅ | ✅ | ✅ | 0 |
| … | | | | | |
| column conflict rate | 0.5% | 4% | **34%** | 1% | |

- For rubric weights they add a fourth options:

| scheme | formula | needs | what it actually estimates |
|---|---|---|---|
| **Uniform** | `w(c) = 1` | nothing | nothing — the score is just a conflict count |
| **Manual** | `w(c) =` a number you assign (your +10 / +8 / −15) | expert time | how much the criterion *matters* clinically/financially |
| **Learned (logistic regression)** | fit `P(agent wrong on instance i) = σ(β₀ + Σ_c β_c · x_ic)`, then `w(c) = β_c`, where `x_ic = 1` if criterion c conflicted on instance i | **outcome-level** human labels | which rubric conflicts *predict* a wrong final answer |
| **Log-likelihood ratio** | `w(c) = log(d_c / e_c)`, where `e_c = 1 − (1 − s_c)(1 − j_c)` and v1 holds `d_c` constant → `w(c) = −log(e_c) + const` | **nothing** (`s_c` from re-runs, `j_c` from repeat/cross-arm calls) | how much to *believe* a conflict on this criterion |

**Stage 3. Aggregation**

A defect class detection funnel: and **how much falls out at each stage is itself a measurement** (numbers below are illustrative):

| stage | remaining | what this stage strips out | what the attrition rate means |
|---|---|---|---|
| all flagged conflicts | 200 | — | — |
| → confirmed by **≥2 cross-family arms** | 120 | **(3) judge blind spot** | 80 "only one arm said so" conflicts dropped → **80/200 is the estimate of judge noise** |
| → **the two reviewers agree with each other** | 90 | **(2) label ambiguity** | 30 "the two reviewers themselves disagreed" conflicts dropped → **30/120 is the label-ambiguity rate**, which is a valuable finding in its own right (what needs fixing is the labelling standard, not the prompt) |
| → reviewers agree that we were wrong | 70 | — | These 70 are the only ones that are **(1) our error**, and they are the numerator for computing lift |

## 2.2. [AutoRubric 2026](https://arxiv.org/html/2603.00077v2)

The authors unify scattered rubric-based judging techniques, i.e., ensemble judging, bias mitigation, few-shot calibration, into one framework with opinionated defaults, and, the part that matters here, **measure judge reliability as a function of criterion type**. It is the reference implementation of Stage 2 and it is very nearly absent at Stage 1: its judge never sees the agent's answer as something to accept or reject, so the two Stage-1 rates are not computable from its outputs at all. Validated on RiceChem (1,240 chemistry responses, 27 binary criteria), ResearcherBench (65 research questions, 931 weighted binary criteria, 5,586 criterion judgments) and CHARM-100 (100 chatbot conversations, 1 binary + 4 ordinal + 1 nominal criterion). It is the exact complement of [Kranti & Vajjala](https://arxiv.org/abs/2607.12885): that protocol supplies the Stage-1 gate AutoRubric lacks, and AutoRubric supplies the per-criterion layer the protocol is deployed on.

**Stage 1. Calibration: absent**

AutoRubric picks top judges, runs all of them and votes, i.e., no judge selection or calibration.

**Stage 2. Rubrics**

- To define a good rubric, "behavioral anchors" over "evaluative adjectives": "The response cites at least three peer-reviewed sources" is behavioral, "The response demonstrates excellent research" is evaluative.

| framework | AutoRubric | how the value is set |
|---|---|---|
| booleans | `binary` | 1 if MET, 0 if UNMET |
| ordinal | `ordinal` (3–5 levels recommended) | the selected option's explicit numeric value |
| categorical | `nominal` | same, from an unordered option set |
| ambiguous | `CANNOT_ASSESS` | **four configurable strategies** — SKIP (drop from numerator *and* denominator), ZERO, PARTIAL (a configured fraction), FAIL |

- **The response schema is deliberately narrow**: `rubric_status` plus a mandatory `reason` (1–2 sentences citing evidence), and an optional self-reported `confidence`. No score, no severity. Every number is computed deterministically downstream, which is what makes a disputed score decompose into one criterion, one verdict and one justification string.

```json
{
  "rubric_status": "MET" | "UNMET" | "CANNOT_ASSESS",
  "reason": "1–2 sentences citing evidence",
  "confidence": 0.0
}
```

- **Negative rubric**: "active errors or mistakes. **MET means the submission advocates the problematic thing**; UNMET means it does not."
- **Rubric output option shuffling** for ordinal and nominal rubrics, e.g., low · high · none · moderate · minimal.
- **Verdict-balanced few-shot sampling**: for each rubric prompt, add balanced examples with expected results over options.
- **On weights, AutoRubric** specifies only that weights exist, may be negative, and that negative ones leave the denominator for normalization, but does not discuss how to determine weights.

**Stage 3. Aggregation**

- **Generate a score of each instance**
	- **Voting** per rubric among judges to generate instance × rubric table; and then **scoring** each instance by `score = clamp( Σ vᵢ·wᵢ / Σ_{wᵢ>0} wᵢ , 0, 1 )`, where `vᵢ` is the voting result of rubric i and `wᵢ` is the weight of rubric i. Negative weights are excluded from the denominator so a perfect submission scores exactly 1.0, and clamping prevents penalties from pushing a score below 0.
	- Voting strategy among judges:
		- (a) majority's tie-break fallback is random selection.
		- (b) unanimous + SKIP compose into a silent failure.

| strategy | rule | risk |
|---|---|---|
| majority | most common verdict wins; **ties resolved by random selection** | see above |
| weighted | weighted by judge weight, threshold >50% of weight | *The authors did not discuss where is the judge weight from. |
| unanimous | all judges must agree; **any dissent → `CANNOT_ASSESS`** | see above |
| any-vote | a single judge suffices | over-sensitive |

- Reliability of rubrics for judge quality evaluation
	- To generate a reliability table of rubrics, the authors proposed to have human labels for each \<instance, rubric\> pair. Given the voted table over judges, i.e., a instance × rubric table, and corresponding human labels,

| metric | the question it answers | if it's bad |
|---|---|---|
| **κ** | is the judge doing anything, or just answering the majority class? | drop the criterion |
| **QWK** | when it's wrong, is it wrong by a little or a lot? | wrong by a lot = it isn't reading the source at all |
| **EMD** | is the error a **shift** or a **scatter**? | shift = recalibrate (cheap); scatter = change model (expensive) |
| **Spearman ρ** | can it at least get the **order** right? | ρ good but κ bad → keep it for the queue only |
| **ICC** | does the variance come from the item itself, or from **who rated it**? | from the rater = the criterion is too subjective |

## 2.3. No Free Labels ([Krumdick et al. 2025](https://arxiv.org/html/2503.05061v1))

It is almost purely Stage 1, and has one holistic verdict per instance, no rubrics, no weights. Its contribution to this framework is not a technique but a **demonstration that the Stage-1 table as drawn is under-specified**: the two rates are not a property of a judge, they are a property of a *(judge × what the judge is shown × whether the judge could have answered the instance itself)* cell, and collapsing those axes to one row per arm both hides the failure and inverts the ranking.

**Stage 1. calibration — the paper is essentially only this stage**

- The judge sees the instance and the agent's result, and returns Correct / Incorrect against a human consensus label. The authors test five approaches of judges
	- none: only instance and agent's result ← baseline
	- self: none + judge's result as reference ← the approach this research would like to prove wrong. Judge's result does not help and even worse to let the judge tend to stick with its result.
	- human: none + human golden result as reference
	- wrong: none + a synthetic wrong result as reference ← worst approach
	- random: none + a random result as reference

| arm (reference) | overall | judge answered correctly | judge answered incorrectly |
|---|---|---|---|
| GPT-4o (none) | 0.47 | 0.51 | 0.28 |
| GPT-4o (self) | 0.64 | 0.78 | **0.14** |
| GPT-4o (human) | 0.85 | 0.86 | **0.80** |
| GPT-4o (random) | 0.50 | | |
| GPT-4o (wrong) | 0.21 | | |
| Llama 3.3 70B (human) | **0.87** | 0.91 | 0.80 |

- A short conclusion: a judge model is liable to work well as long as the model can **either** answer the question itself **or** is provided a correct reference.

**Stage 2. judging with rubrics — absent**

**Stage 3. aggregation — absent**

**Auto-Eval — the title is the finding**

- **The human annotation cost moves; it does not go to zero.** Because verified-LLM references match hand-written gold (0.61 vs 0.69), the expensive step can shift from *authoring* references to *verifying* them — a real cost reduction.

# 3. The Bias Taxonomy

Nine ways the judge produces a wrong verdict. Consolidated from [the survey](https://arxiv.org/html/2411.15594v6) and AutoRubric's ablations.

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

The survey's own honest note: for self-enhancement bias it does **not** offer a validated mitigation. Cross-family judging is a structural workaround, not a fix.

Two robustness findings worth carrying: **prompt sensitivity** (minor wording changes shift grading strictness and score distributions) and **fragility of rule-based token extraction** — the second is why forced-tool structured output is the right call, and `core/judge.py` already fails loudly on `stop_reason == max_tokens` rather than returning a partial `{}`.

## 4. Selective Judging with a Human-Agreement Guarantee

[Trust or Escalate (ICLR 2025)](https://arxiv.org/html/2407.18370) turns "how accurate is the judge?" into a *different and answerable* question: "on what fraction of cases can the judge match a human, with a guarantee?" It provides

```plain text
P(judge agrees with human | judge chose to evaluate x)  ≥  1 − α,   w.p. ≥ 1 − δ
```

- **Guarantee (target).** We fix a target agreement rate 1 − α, say 90%, and require the judge's accepted decisions to meet it.
- **Selective evaluation (mechanism).** The judge only evaluates instances where its confidence score exceeds a threshold λ; everything below λ is abstained on and deferred.

Two things worth making explicit, since the bullets currently leave them implicit:

- λ isn't chosen freely — it's calibrated so the agreement rate on the accepted set is ≥ 1 − α. α is the knob you set; λ is derived from it.
- The cost is coverage: raising λ buys agreement and loses volume. So the pair to report is (1 − α, coverage at the calibrated λ), not either alone.

For example, as the below, if the guarantee is 90%, the maximal λ is 0.60 and the coverage is 56%.

| confidence threshold λ | coverage | agreement rate A(λ) |
|---|---|---|
| 0.99 | 22% | 0.97 |
| 0.80 | 40% | 0.94 |
| **0.60** | **56%** | **0.905** |
| 0.50 | 65% | 0.88 |
| 0.40 | 75% | 0.85 |
| 0.00 | 100% | 0.78 |

**Issue 1. Where is Confidence from?**

- Confidence comes from **Simulated Annotators**: for an instance, prompt the judge N times (N=5) with K-shot examples (K=5) drawn from *different* human annotators, and take the max agreement ratio across simulations. Confidence is low when simulated annotators disagree with each other.

**Issue 2. The true confidence v.s. coverage v.s. agreement rate table is unknown.**

- We only have a small human labeled set. For example, we draw 500 human-labelled encounters and walk λ downward from 0.999, computing an exact binomial upper bound at each step:

| λ tested | of 500, cleared threshold | of those, disagreed | point-estimate agreement | 90% upper bound on disagreement | verdict |
|---|---|---|---|---|---|
| 0.99 | 108 | 3 | 97.2% | 6.08% | ✅ pass (≤ 10%) |
| 0.80 | 205 | 12 | 94.1% | 8.55% | ✅ pass |
| 0.60 | 274 | 25 | **90.9%** | **11.77%** | ❌ fail — stop |

- Look at the λ=0.60 row: **the point estimate is 90.9%, which looks like it clears the target.** But 274 instances only pin the upper bound down to 11.77%, which does not clear 10%. So the procedure refuses it. We ship **λ̂ = 0.80**.
- **How to calculate the upper bound on disagreement:**
	- The whole guarantee rests on this one step, so it is worth spelling out. Take an illustrative calibration row: at some candidate threshold λ, 274 of the 500 calibration instances clear it and 25 of those disagree with the human. The point estimate is 25/274 = **9.1% disagreement, i.e. 90.9% agreement — which looks like a pass against a 90% target.** It is not treated as one. The procedure instead asks:

	> How bad would the true disagreement rate have to be before "we only saw 25" becomes a fluke we can dismiss?

	- For any candidate truth `p`, the probability of seeing 25 or fewer disagreements in 274 draws is the binomial CDF — `P(X ≤ 25) = Σ(i=0..25) C(274,i) · p^i · (1−p)^(274−i)`:

| if the truth were p | P(≤ 25 disagreements in 274) | verdict |
|---|---|---|
| 9.12% (= the point estimate) | 55.4% | entirely consistent |
| 10% | 36.0% | consistent |
| **11.77%** | **10.0%** ← lands exactly on δ | **the edge of consistent** |
| 13% | 3.0% | strained |
| 14% | 0.96% | dismiss |
| 16% | 0.07% | dismiss |

- **11.77% is the worst truth the evidence cannot rule out**, and that, not the 9.1% observed, is what gets compared to α. 11.77% > 10%, so this λ fails and the walk stops at a tighter threshold. Certification runs against the worst world still consistent with your data, which is precisely why it yields a guarantee rather than a hope. **Computing it.** The CDF is strictly decreasing in `p` (a worse truth makes "only 25" less likely), so the root is unique and bisection lands it in ~20 iterations. Closed form, same answer: `p_upper = BetaInv(1−δ; k+1, n−k)`, i.e. `scipy.stats.beta.ppf(0.9, 26, 249)`. The one case that solves algebraically is **k = 0**, where the sum collapses to a single term: `(1−p)^n = δ ⟹ p_upper = 1 − δ^(1/n)`.
