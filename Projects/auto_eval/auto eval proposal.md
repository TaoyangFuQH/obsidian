---
updated: 2026-08-17
tags: [project, coding-pod, eval, auto-eval, llm-as-judge, proposal]
---
# Proposal — LLM-as-a-judge auto-eval for ED + clinic coding

Consolidated, decision-ready. The layer above the design docs — what we are trying to buy,
the three things worth building, and the concerns that bound all of it. Literature behind it:
[[LLM as a judge SOTA]]. Design reasoning: [[LLM as judge]].

**Supersedes nothing.** The detail is all in this folder now: [[auto eval plan]] (the six
tiers and their rationale) · [[auto eval roadmap]] (phasing, gates, and the graveyard of
measured-dead ideas) · [[lane A findings]] (measured defect classes) ·
[[tier 3 metamorphic]] · [[tier 4 criterion judging]] · [[LLM as a judge SOTA]].
Only `grounding/` (four research + code dossiers) is still in the repo at
`coding-ai-harness/features/llm-auto-eval/`, **which is neither tracked nor synced.**

Written 2026-08-17. Two inputs are new since the earlier docs: **the 2026 LLM-as-judge
methodology literature** (the earlier `grounding/` covered faithfulness and metamorphic
testing, not judge methodology), and **the discovery that a general judge primitive already
exists in this repo on an unmerged branch**.

> **Read [[LLM as a judge SOTA]] alongside this.** It maps each finding to its consequence
> for our surface, and it carries two corrections to what is written below: the
> ordinal-vs-binary judge reliability split (which makes a *level* judge unable to adjudicate
> a one-rung disagreement — see §3 WS-C), and a softening of the "AC1 not κ" rule in WS-B3.
> It also adds one workstream item this document does not have: **WS-B0**, the
> calibration/sensitivity protocol — now specced concretely in
> [[judge calibration protocol]], and runnable today on the labels we already own.

---

## 0 · The two products, as they bear on judge design

Both run prod code in-process through the shared harness (repo `README.md`). What matters
here is not the DAG shape but **where the LLM has sole authority**, because that is the only
place a judge can add information.

| | **ED** | **clinic** |
|---|---|---|
| DAG (scoring core) | 2 questionnaires in parallel (DATA, RISK) → 2 scorers in parallel (PRO w/ extended thinking, FAC) → deterministic `ed-calculate-codes` | `clinic-extract` **×3** (extended thinking) → majority aggregate → `clinic-postprocess` (preventive/AWV, Mod-25, E/M series-flip) |
| billed model | `claude-sonnet-4-6` (all four calls) | `claude-opus-4-6` (all three votes) |
| scored axes | `pro`, `fac` (ordinal code ladders) · `copa`, `data`, `risk` (ordinal `none/minimal/low/moderate/high`) | `em`, `prev`, `mod25` · `copa`, `data`, `risk`, `mdm` |
| encounter id | `pat_enc_csn_id` | `pat_enc_csn_id` |
| **cross-family signal today** | **yes, and mostly discarded** — `ed/verifiers.py` runs GPT-5.4 + Gemini through their own questionnaires *and their own PRO call*; `ed/gate.py` consumes only the PRO vote, `_codes_from_pro` drops every criterion boolean | **none** — the 3 votes are the *same model*, so the "ensemble" measures sampling noise, not correctness |
| abstention gate | registered, **off** by default | landed in prod; not yet registered in `clinic/profile.py` |
| citation surface | `citations[].cited_text`, spec'd verbatim | ~23 `source_quote` fields/encounter, spec'd verbatim |

**The one structural fact that drives everything below.** The chain
`criterion booleans → axis level → MDM median → CPT code` is deterministic at every step
**except the one step where the LLM has sole authority**:

| axis | boolean → level | complete? |
|---|---|---|
| **DATA** | arithmetic in `business_logic.py`, and it **overrides** the LLM's declared level | **yes** |
| COPA | prose only; High reachable via pathways (a)/(b) that map to **no** boolean | no |
| RISK | prose only; High reachable via pathways (a)–(f) that map to **no** boolean | no |

Measured consequence: identical boolean vectors map to *different* declared levels — copa 4
of 8 vectors, data 6/9, risk 9/33. **A judge that emits criterion booleans therefore cannot
reconstruct a level today.** This is not a judge problem and no prompt fixes it; it is a
schema gap in `qh-platform`. It is the highest-leverage item in the whole programme and it
is a prerequisite, not a parallel track.

Clinic adds one product-specific rule worth naming: the billed level is
**higher-of(MDM, time)** under AMA, and clinic's `input.csv` carries **no time column** — the
note is the only possible source, and only 15/63 notes on the feedback set mention time at
all. Any clinic judge that reasons about the billed level has to know this or it will
confidently mis-adjudicate.

## 1 · What already exists — read before building anything

Three separate bodies of work. Two of them constrain the design; one of them is code we
should not write twice.

**(a) The measured Lane-A result — the deterministic surface is clean.** Ten
deterministic detectors over **465 encounters** (ED `washington-402` n=402 + clinic
`v1-20260720-feedback-63-patch26` n=63), reviewed with the domain owner:

| outcome | count |
|---|---|
| confirmed defects worth a fix | **0** |
| real but inconsequential | 1 (count-vs-list; code prefers the list) |
| doc inconsistency, harmless to billing | 1 (CC gate: prompt says MDM=High, code checks COPA=High) |
| detectors that fired but were **the check misreading a rule** | **6 of 10** |

This retracts an earlier claim in our own roadmap that the deterministic lane would pay for
itself first. It did not. Two readings remain undistinguished — the pipeline genuinely has
no deterministic self-contradictions worth fixing, or the detector set was too shallow — and
the 6-of-10 misread rate argues for the first. **The ~60–80% false-lead rate on hand-built
checks, where there is no judge and no sampling noise, is the strongest single argument that
calibration is not optional.** Every one of those six was killed by reading the prompt or
the AMA rule the check claimed to encode; none would have been caught by running on more
encounters.

Citation groundedness was separately reviewed and **dismissed as a defect**: it is a real
spec violation (`output_format_prompt.py` demands "exact verbatim quote from the note" ×8;
29.8% ungrounded whitespace-normalized) but accuracy against GT is indistinguishable with
and without an unresolvable citation. It survives only as a **ceiling on span-based judging**
— ~47% of non-verbatim spans fail even prod's fuzzy resolver, so every span-deletion and
span-entailment test inherits that ceiling.

**(b) `core/judge.py` already exists** — on `origin/citation-eval-on-main`, unmerged, by a
teammate. `StructuredLLMJudge` is a rubric-agnostic forced-tool Anthropic call at
temperature 0 with a `max_tokens`-truncation guard, plus `core/citation/` (a two-axis
Support+Redundancy judge, a `core/metric_registry.py` seam, one-row-per-case frames, and a
prompt-hash cache key). It was built for a `tavr` profile but is explicitly
workflow-agnostic. **We should not write a second judge primitive.** Whether to land that
branch on `main` first is a coordination call, not a technical one — flagged in §4.

**(c) The label inventory, which is the binding constraint.** `gt.csv` on `washington-402`
is **~82% blank** on the level columns: **71 / 72 / 71** labelled rows for copa / data /
risk. Six of the eighteen criterion booleans have base rates under 2.5%; one
(`physical_restraints_used`) is never true in 402 encounters. See §3.1 for what that
supports, which is close to nothing.

## 2 · Goals

Stated as what we buy, in descending order of how defensible each is on today's evidence.
The ordering is the proposal's main claim.

| # | goal | what it needs to be true | defensible today? |
|---|---|---|---|
| **G1** | **Rank a review queue.** Order any run — labelled or not — so a coder or an RCA starts at the most-likely-wrong encounter | only *rank* correlation with error, reported as lift over random ordering | **yes**, once calibrated on the labels we have |
| **G2** | **Find defect classes worth an RCA.** Surface a *mechanism*, pre-localized to a node + field + span, that human labels have not covered | precision on the flagged head only | **yes** — and this is what `skills/rca-coding` consumes |
| **G3** | **Pre-flight a candidate on unlabelled data.** Some signal before feedback returns weeks later | a stable, version-pinned detector and a stated MDE | **partly** — needs G1 calibrated first |
| **G4** | **Population accuracy on unlabelled data.** An honest number in a report | PPI plus a human-labelled sample | **only with the label investment** (§3.1) |
| **G5** | **Gate.** Feed abstention so low-confidence encounters route to review | prospective silent-mode validation; compliance sign-off | **no** — out of scope for v1 |

**The line, and it is load-bearing.** Auto-eval **never replaces `gt.csv` as the accuracy
measurement.** A judge-derived accuracy is biased by the judge's own error profile, and in
the reference-free setting the bias direction is *known*: judges over-credit the answer they
are shown, and supplying a reference flips up to **85%** of verdicts
([Kranti & Vajjala 2026](https://arxiv.org/abs/2607.12885)). Cross this line and
`docs/EVALUATION.md`'s two-artifact contract collapses into a model grading its own
homework. Headline accuracy comes from human labels, or from PPI (G4).

Two independent lines of evidence already say the same thing from different directions: the
metamorphic tier is structurally blind to *stable* errors, and the criterion-judging research
verdict was that it works "as a localization and ranking instrument on a closed rubric, but
not as an accuracy measurement on this surface." **Both rank and localize. Neither measures.**

## 3 · Approaches

Three workstreams. A and B can run in parallel; C is gated on both. The sequencing is the
recommendation — the tier taxonomy in [[auto eval plan]] stays as the design detail.

### WS-A · Recover what is already on disk — zero new model calls

Highest value per engineer-day in the programme, and it needs no labels and no judge.

| # | item | why |
|---|---|---|
| A1 | **Land one judge primitive.** Decide on `origin/citation-eval-on-main` → `main` (`core/judge.py` + `core/metric_registry.py`), or explicitly fork the decision | otherwise WS-C writes a second `StructuredLLMJudge` and the repo grows two judge seams |
| A2 | **Is the discarded ED verifier criterion detail recoverable from the model cache?** `ed/verifiers.py` already makes the cross-family blind-extraction call; `_codes_from_pro` returns five codes and drops every boolean | **decides whether the whole judge tier is free or paid.** `core/modelcache.py` keeps `request` and response verbatim and content-addressed, so if the questionnaire responses were cached, cross-family criterion comparison costs zero new calls |
| A3 | **Dissent → a graded score,** not a binary gate. ED `abstention.pro_votes` entropy; clinic's 3 votes plus the `repro-seed{1,2,3}` traces (**K=9 on 63 encounters, already paid for**) | `core/scoring.py` already computes vote agreement, unanimity and `agree_gt_corr` — this is an extension, not a build. Over a 4–5 rung ordinal the label set *is* the set of semantic equivalence classes, so semantic entropy is **exact**: no clustering, no probes, none of that literature's cost |
| A4 | **Add a cross-family verifier arm to clinic.** One GPT-5.4 or Gemini pass | clinic's only redundancy is 3 same-model votes. One cross-family arm is a larger information gain than any judge-prompt refinement, and ED's arm is the existence proof |
| A5 | **Fix the evidence base.** No `manifest.json` on any `washington-402-baseline` run dir; `run_signature` records the model **alias** | every number in §1 rests on unmanifested runs, so a provider snapshot rotation is currently indistinguishable from a real finding |

Use block permutation by run for A3 — within-run votes are not exchangeable with cross-run
votes. And A3's failure mode is the one to write down: **three models with overlapping
training data agree on the same wrong answer, and unanimity reads as confidence.** Dissent
is a ranking signal, never an accuracy claim.

### WS-B · The calibration harness — the real gate on everything LLM-based

Nothing judge-based ships before this exists. This is the SOTA-mandated step and it is
where the programme most likely gets redirected.

| # | item |
|---|---|
| B1 | **Measure what the labels support** *before* trusting anything: per-detector PR curve, lift over random ordering, queue AUC, and the MDE per axis and per criterion |
| B2 | **Hold one dataset out entirely.** A detector tuned and validated on `qh-0731-dev-set-93` is worth nothing |
| B3 | **Agreement statistics that survive class imbalance** — Gwet AC1 / Krippendorff, **not** Cohen's κ |
| B4 | **The bias-corrected estimator, not the raw judge rate** (§3.2) |
| B5 | **Stratified label acquisition** — spend new labels where they buy the most (§3.1) |

#### 3.1 · The uncomfortable arithmetic, and the label ask

At n=71 labelled rows per axis, a 95% CI on a proportion has a half-width of **~11.6pp** at
p=0.5 and **~9.3pp** at p=0.8. For a per-criterion PR curve, a criterion with a 2.5% base
rate contributes **~1.8 positives** in 71 rows. Six of eighteen criteria are at or below
that. Precision and recall are not estimable there at any confidence worth reporting.

So the honest reading of the SOTA guidance — *reference-free judges must be calibrated
against reference-aware evaluation on a sample first* — is that **we do not currently have
the sample.** The correct next action if B1 confirms this is **acquire labels, not build
more detectors.** An uncalibrated detector cascade is a pile of unfalsifiable opinions, and
we already know the hand-built false-lead rate is 60–80%.

The label ask should be **stratified, not random**, and this is where WS-A pays for WS-B:
label where the pipeline and the cross-family arm *disagree*, plus a random control stratum
to keep the estimator honest. Disagreement strata carry far more information per label than
uniform sampling, and A2/A3 identify them for free.

#### 3.2 · How a judge number is allowed to become a report number

Two mechanisms, both from the 2026 literature, both requiring a labelled sample:

- **Bias-corrected point estimate.** Report
  `θ̂ = (p̂ + q̂₀ − 1) / (q̂₀ + q̂₁ − 1)`, where `p̂` is the raw judge rate and `q̂₀`, `q̂₁`
  are the judge's specificity and sensitivity estimated on the calibration set, with an
  adjusted Wald CI that carries **both** test-set and calibration uncertainty. Valid only
  when `q̂₀ + q̂₁ > 1`. Naive reporting is *directionally* biased — it overestimates when
  true performance is low and underestimates when it is high — which is exactly the regime
  we would be reporting in. ([Recommendations for reporting](https://arxiv.org/html/2511.21140v4))
- **PPI** for population estimates: unbiased *regardless* of the judge's error profile,
  because the labelled sample measures the judge's systematic error and corrects it. Each
  additional judged example reduces variance without adding bias. Note the documented
  caveats: PPI degrades under calibration/test distribution shift, and on some benchmarks
  today's judges do not beat human-only variance.

Both must respect the existing invariant: **the bootstrap resamples encounters**, and a
resampled encounter brings all its seeds (locked by `scripts/metrics_selftest.py`).

### WS-C · The judge itself — decomposed, blinded, cross-family

Gated on A2 (is it free?) and B1 (can it be calibrated?).

**The design principle, and it is what the SOTA supports.** Never ask the judge "is this
code correct?" That requires the judge to know CPT, and LLMs are poor direct medical coders
— GPT-4's CPT exact-match rate is **49.8%**
([NEJM AI](https://ai.nejm.org/doi/full/10.1056/AIdbp2300040)). Ask instead "does this
documentation support criterion X?" — a reading-comprehension question against a stated
rubric, which is the task judges are actually good at, and which keeps aggregation in
deterministic code. Analytic (decomposed) rubrics beat holistic ones; this is the consensus
of the 2026 rubric literature and the reason the "directly judge which codes are wrong"
formulation is demoted to last.

| # | item | note |
|---|---|---|
| C0 | **Complete the COPA/RISK criterion schemas** — one structured field per prompt pathway (COPA (a)/(b); RISK ICH-concern, focal deficit, altered consciousness, mechanism, worsening neuro, anticoagulant+trauma+CT) | **prerequisite.** Without it the judge's booleans cannot run through the real aggregation, which was the entire premise. DATA is the existence proof that the pattern works. qh-platform change ⇒ `.worktrees/` branch, not a patch |
| C1 | **Choose the criterion surface, explicitly** | Two exist and they are not the same thing: **18** `llm_raw` booleans that drive the pipeline, vs `guideline_report`'s 61 facility + 17 professional criteria, which are display-derived. Judging the latter may be judging a renderer. (The "~40 criteria" figure in earlier drafts was wrong — it was the display surface.) |
| C2 | **Blind cross-family extraction.** A different model family sees the input and the criterion list and **never sees our answer**: which criteria does this documentation support, and what is the decisive span | blinding is what prevents anchoring, and skipping it is precisely what makes reference-free judges generous |
| C3 | **Entailment + conflict enumeration.** For each criterion we set true, does the cited span entail it; for each false, does the input contradict it. Three conflict types kept distinct because they route differently: span-vs-input (groundedness), ours-vs-blind-extractor (candidate error), criterion-vs-criterion within our own output (internal inconsistency) | aggregation stays deterministic — run the real `run_two_stage_calculations` over the judge's booleans, once C0 makes that possible |
| C4 | **Adjudication only on conflicts.** Arm order randomized, arm identity hidden, verdict is `ours \| theirs \| ambiguous` | `ambiguous` is a **first-class outcome**, not a hedge: it is the label-ambiguity population, the same one that poisons GT-based eval, and it belongs in `label-or-standard` |
| C5 | **Exclude criteria two qualified coders would routinely disagree on** | those cannot be judge-evaluated without a human adjudication standard, and including them manufactures noise |

**Prompting is directional, not symmetric.** Never "is this correct?" — always the rung
boundary being tested: *"is there documented support for RISK=Moderate, or does the
documentation only support Low?"* The compliance question is one-sided (over-coding on the
billed axis) and `docs/EVALUATION.md` already treats direction as the point; the judge should
inherit that asymmetry. Mitigate position bias by swapping and averaging.

### The metamorphic lane — designed, unrun, and worth reframing

[[tier 3 metamorphic]] is a finished design (~10k calls, ~12–20h serialized). It is the only
lane whose evidence is **independent of any model's judgement**, which is why it is worth
keeping. But its expected yield should be stated honestly: `rcm-format-notes` reproduces a
byte-identical formatted note in only **23/402 (5.7%)** re-runs, and on exactly those 23 the
scorer's output is byte-identical with **zero axis movement**. The likeliest outcome is
therefore not a metamorphic-relation violation but the finding that **the dominant source of
ED instability is a note formatter nobody is looking at** — a product fix (cache it), not
prompt work. That is a real and valuable result; it just isn't a judge result.

Sequence it after WS-A, and keep its stop condition: **NULL-1 first.** A frozen-note arm
inside a materialized cache lane is a *replay* — within-arm disagreement is 0 and the
estimator fabricates a +2.6 to +4.5pp effect. Assert `cache_hit == false` on every draw.

## 4 · Concerns

Ordered by how likely each is to sink the programme.

**C-1 · Labels are the binding constraint, not judges.** 71 rows per axis; six of eighteen
criteria below 2.5% base rate. Everything in WS-C is unfalsifiable until this is fixed. If
B1 confirms it, **the correct decision is to stop building detectors and go acquire labels**
— and that is a staffing/coder-time ask, not an engineering one. This is the concern to
resolve first because it changes what the rest of the programme even is.

**C-2 · Correlated blindness and self-preference.** Every LLM tier shares the generator's
blind spots to some degree, and the healthcare judge literature names shared-family bias as
a primary failure: when generator and evaluator come from the same family they share
training distributions and mask correlated errors. Clinic is the acute case — a Claude judge
over a Claude-Opus generator, with three same-model votes as its only redundancy. **Mitigation
is structural, not prompt-level:** cross-family judge (A4), blinding (C2), and an explicit
bound on what any LLM tier may claim.

**C-3 · Reference-free generosity.** Judges over-credit the answer shown to them, and
supplying a reference flips up to 85% of verdicts. This is *why* C2's blinding exists and
why G4 requires PPI rather than a raw judge rate.

**C-4 · The lossy boolean schema.** Until C0 lands, a criterion judge cannot reconstruct a
level, so any level-level readout from WS-C is unfounded. Three of the four Lane-A
retractions traced to this one property. Treat any pre-C0 level claim as a bug.

**C-5 · Judge competence on the domain.** The judge must not be asked to do the thing LLMs
are measured to be bad at (49.8% CPT exact match). The healthcare scoping review adds
concrete failure modes to design against: surface-level conflation (rewarding fluent,
well-organized, wrong answers), shallow clinical reasoning (chronic vs new diagnoses,
misread terminology), **evaluator hallucination** (fabricating flaws in the candidate), and
prompt sensitivity (wording changes shift grading strictness). Every one of those is a
plausible source of a false finding on our surface.

**C-6 · Human adjudication cost is the hidden line item.** Our own hand-built deterministic
checks had a 60–80% false-lead rate, all caught by a human reading the prompt or the AMA
rule. A judge's findings will need the same discipline. **Budget domain-owner review time
as part of the feature, not as an afterthought** — an unreviewed findings file is a draft.

**C-7 · Goodhart.** Fix prompts against detector-flagged errors and the detector stops
measuring anything. Rules: **gating detectors are frozen and version-pinned**; iteration
detectors are separate; any auto-eval-motivated prompt change is validated on human-labelled
regression data before it ships. `docs/EVALUATION.md`'s "never pool datasets" generalizes —
in-sample-to-the-detector is a new way to be in-sample.

**C-8 · PHI and the data path.** Judge calls send verbatim note text to a model provider.
ED already does this for its verifiers, so the precedent and the key handling exist; a clinic
judge is a **new** PHI path and should be named as such. Findings files and any perturbed-note
intermediate carry note text → local-only, never committed, never synced. Encounter ids are
fine. Rendered reports stay population-level. And note `features/` is neither tracked nor
synced, so anything here worth keeping moves to `core/`/`docs/`/a `CLAUDE.md`.

**C-9 · Duplicated judge infrastructure.** `origin/citation-eval-on-main` is unmerged and
already contains the judge primitive, a metric-registry seam and a prompt-hash cache key.
Resolve A1 before WS-C starts. Coordination question for whoever owns that branch.

**C-10 · Drift.** The healthcare literature is explicit that judges need version tracking,
audit logs, drift monitoring and periodic re-validation as guidelines and prompts change —
and E/M guidance itself moves annually. A judge with a `calibration.json` older than the
prompt it judges is out of date, and the artifact contract should enforce that.

## 5 · Recommendation

1. **Do WS-A now.** Zero model calls, no labels needed, and A2 decides the cost of
   everything downstream. A5 first, since it validates the rest of the evidence base.
2. **Do WS-B in parallel, and treat B1 as a go/no-go.** If 71 rows per axis cannot support
   a usable interval — the likely outcome — the deliverable of this feature changes from
   "a judge" to **"a stratified label-acquisition plan plus the harness to spend those
   labels well."** That is a better outcome than a judge nobody can falsify.
3. **Land C0 (the COPA/RISK schema completion) regardless of the judge decision.** It
   creates two deterministic checks on the two axes carrying the most billing risk, where
   there are currently zero; it retires a whole class of false leads; and it unblocks WS-C.
   It is the highest-leverage item in the programme and it is not judge work.
4. **Build WS-C only after A2 and B1 report.** Then, in order: C1 (surface choice) → C2
   (blind cross-family extraction) → C3 → C4.
5. **Ship G1 and G2 as the v1 product** — a ranked review queue with a stated flag budget
   and a measured catch rate, plus defect classes that enter `ITERATION.md` stage 3 through
   the existing `causes.json` door. Not an accuracy number.

**Artifact contract** (unchanged from [[auto eval plan]], restated because it is what makes this
auditable): `<run-dir>/autoeval/findings.json` mirrors `core.dump_errors` rows minus the GT
columns, plus `{detector, tier, score, evidence, changes_output}`; every row carries a
disposition prior from the existing closed set (`system` | `upstream-input` |
`label-or-standard` | `not-reproducible`) — **no second taxonomy**; a finding with no
pointer to an intermediate is not emitted; and
`autoeval/calibration.json` records per detector version the dataset it was measured on, its
PR curve and its held-out set. **A findings file whose detectors have no calibration entry
is a draft.**

## Sources

- [LLM Judges Can Be Too Generous When There Is No Reference Answer](https://arxiv.org/abs/2607.12885)
- [LLM-as-a-Judge in Healthcare: A Scoping Analysis of Applications, Methods, and Human Alignment](https://arxiv.org/html/2605.25273)
- [How to Correctly Report LLM-as-a-Judge Evaluations](https://arxiv.org/html/2511.21140v4)
- [A Survey on LLM-as-a-Judge](https://arxiv.org/html/2411.15594v6)
- [Autorubric: Unifying Rubric-based LLM Evaluation](https://arxiv.org/html/2603.00077v2)
- [Large Language Models Are Poor Medical Coders (NEJM AI)](https://ai.nejm.org/doi/full/10.1056/AIdbp2300040)
- [Evaluating clinical AI summaries with large language models as judges (npj Digital Medicine)](https://www.nature.com/articles/s41746-025-02005-2)
- [Statistically Reliable LLM-Based Ranking Evaluation via Prediction-Powered Inference](https://arxiv.org/abs/2606.05308)
- [Adaptive Prediction-Powered AutoEval with Reliability and Efficiency Guarantees](https://arxiv.org/html/2505.18659)
- [No Free Labels: Limitations of LLM-as-a-Judge Without Human Grounding](https://arxiv.org/html/2503.05061v1)
