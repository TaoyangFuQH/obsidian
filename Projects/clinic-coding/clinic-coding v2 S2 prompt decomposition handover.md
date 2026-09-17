# clinic-coding v2 S2 — prompt decomposition · HANDOVER

**Written 2026-09-17.** Companion to `clinic-coding v2 S2 prompt decomposition.md` (the spec).
No PHI: encounter ids only, no note text, no MRNs, no vitals.

---

## 1 · Read this first — the headline

**S2 (axis-major prompt decomposition) is behind the shipped V1.3 joint prompt on every
arm we have measured, on both datasets.** On a holdout none of the arms was tuned against:

| | em trail | sd |
|---|---|---|
| **V1.3 baseline** | **91.6%** | **0.00** |
| best S2 arm (`nodata`, `timefix`) | 90.5% | 1.05 / 2.79 |
| worst S2 arm (`riskcal` / E-A) | 87.4% | 2.11 |

**13 of 13 S2 arms below V1.3, spanning −1.1 to −4.2pp.** On the 177 (the tuning set) the
same comparison is −1.2pp; on the holdout it roughly doubles. V1.3 is also far more
*stable* — sd 0.00 vs S2's 0.00–2.79 — which is mechanically consistent: V1.3 votes 3×
over one joint prompt with ew/tc majority, while S2 runs five independent axis calls whose
errors are not voted out the same way.

**Implication for whoever picks this up.** The open question is no longer "which prompt
edit helps"; it is **"does axis-major decomposition beat the joint prompt at all?"** Every
edit measured (see §4) optimises *inside* S2. The best surviving one is worth +0.30pp
against a 2.5–4.2pp architectural deficit — an order of magnitude too small to matter.

Do not resume prompt-edit hunting without first deciding whether S2 is the right shape.

---

## 2 · Where everything lives

### Code — qh-platform

| | |
|---|---|
| worktree | `~/workspace/qh-platform/.worktrees/clinic-s2-decomp` |
| branch | `exp/clinic-s2-decomp` |
| PR | `Qualified-Health/qh-platform` **#6132** — 5 commits pushed |
| prompt shards | `packages/rcm/clinical_coding/clinical_coding/prompts/axes.py` |
| arm flags | `ArmSpec` in that file — every edit is a boolean, default = baseline |
| tests | `packages/rcm/clinical_coding/tests/test_prompts_axes.py` (+ `test_referral_minor_guard.py`) — **629 pass** |
| AMA/Mercy source | `prompts/knowledge_base.py`, `prompts/system_prompt.py` |
| deterministic logic | `clinical_coding/business_logic.py` — grid middle, series flip, time supersede |
| DAG | `dag/build_template_v2_axes.py` → `dag/template_v2_axes.json` |

### Experiments — coding-ai-harness

| | |
|---|---|
| repo | `~/workspace/coding-ai-harness` |
| plan (the running journal — **read this**) | `clinic/experiments/s2-promptdecomp/plan.md` |
| arm definitions | `clinic/experiments/s2-promptdecomp/make_patches.py` |
| run outputs | `clinic/experiments/s2-promptdecomp/results/<prefix>-<draw>/` |
| **published note** | Notion — *Clinic Coding v2 · S2 — prompt decomposition: build note* (§§1–14) |

### Scorers (all in `clinic/experiments/s2-promptdecomp/`)

| script | what it does |
|---|---|
| `compare_mean.py` | the 177: per-axis accuracy + match, **mean across draws** (not modal) |
| `compare_bench.py` | v1_benchmark: the full lineage vs V1.3 |
| `time_union.py` | `load()`, `em_from()` — the replay-gated em recomputation everything reuses |
| `make_patches.py` | materialises each arm's in-memory prompt patch |

### Baselines — get these right

| dataset | V1.3 baseline path |
|---|---|
| the 177 | `clinic/experiments/abst-ewtc-today-177/results/abst-ewtc-today-177-*` |
| v1_benchmark | `clinic/experiments/abst-ewtc-today-v1b/results/abst-ewtc-today-v1b-*` |

Both are `prompt_sha1 6dc23d59…`, git `cb8ea1a5914a`, worktree `ewtc-today`, `dirty: false`.
V1.3 is a **prompt *and* a code state** — the `ewtc-today` worktree carries the `ew`/`tc`
majority-voting changes. A "V1.3" run from main is not V1.3.

> **Trap:** `clinic/experiments/v1_benchmark-fresh` *looks* like a stock baseline (no
> patches) and is **not** V1.3 — different prompt (`3e951ede…`, 85,732 chars vs 86,490),
> nine days earlier, different checkout. I nearly used it. Always check `prompt_sha1` in
> `manifest.json`.

---

## 3 · Datasets

| name | rows | em-scorable | axis GT? |
|---|---|---|---|
| `clinic-feedback-177-dos-match-20260730` | 177 | **164** | **yes** — copa/data/risk/mdm |
| `v1_benchmark` | 139 | **95** | **no** — em/mod25/prev/visit_class only |

Consequences:

- **The 177 is the only dataset where per-axis accuracy is measurable.** R-B v2's headline
  result (RISK +3.85pp) **cannot be checked on v1_benchmark at all.**
- On v1_benchmark **1 encounter = 1.05pp.** Most arm-to-arm gaps there are 1–3 encounters.
- The metric is **em trail** (trailing digit), never em exact — the series (new vs
  established) is silver-driven and no prompt can reach it.

---

## 4 · What has been tried — do not repeat these

### Rejected on the 177

| edit | result | why |
|---|---|---|
| **C6** counting-pathway tally | −0.2pp | mechanism ran backwards: self-inconsistency 4 → 6, tally field missing on 9 encounters, demoted encounters from richer pathways |
| **T-OFF** drop `risk_test_tier` | −1.5pp, 0 fixes / 2.2 breaks | the rule is directionally right and miscalibrated; without it the model grades the *workup*, overshooting Low → Moderate |
| **R-B v3** (N1 + N2 narrowing) | +0.2 vs v2's +0.4 | N1 contradicted `Conditional Rx counts as Moderate`; N2's gate was fitted to ~4 encounters |
| **R-B v4** (N2 only) | identical to v3 | N1 was never the cause — the model infers "not placed" unaided |
| **E-A** (`risk_symmetric_scan`) | neutral; **−4.2pp on holdout** | identical fix/break sets to rf2 on the 177; worst arm on v1_benchmark |
| **G1** combiner-side referral guard | withdrawn | violates axis independence; 50% of its gain overrode a RISK call adjudicated *correct*; and it fires **0/95** on the holdout |
| **R-A, R-C, D-A, R-D** | −0.6 / −5.3 / −0.8 / dead | R-C touches 42–46 encounters to fix 3; R-D contradicts `Continuing an existing prescription drug = Moderate` |

### Kept

**R-B v2** (`risk_referral_floor`, arm `s2-refloor2`) — rewrites both Mercy referral lines
to floor a *placed* referral at Low.

- RISK vs GT **+3.85pp** on the 177 (k=6, 85.04% vs copafix 81.20%), five of six draws at
  84.6 — the only replicated per-axis gain in the whole effort
- em trail **+0.30pp** isolated (k=6, 2.0 SEM) — real but marginal
- Costs two 99212 encounters (`956629786`, `958484336`); five attempts across four
  mechanisms failed to recover them without losing more

### The closed search space on RISK

Five mechanisms, each shut for a specific reason: problem-severity (RISK classifies
problems differently from COPA), conditional-referral (contradicts the shard),
continuing-referral (contradicts the shard), cross-axis (violates independence),
subtractive (every withdrawable addition is negative, neutral, or self-defeating).

**Root cause, worth knowing:** `risk.level == max(actions)` on **1000/1000**
draw-encounters, and that contract is S2-only. R-B v2's floor makes one *action* Low and
the contract propagates it with perfect fidelity — so every attempt to narrow the floor
had nothing to bite on.

---

## 5 · Methodology you must adopt — five traps that cost real time

### 5.1 Read the assembled shard before proposing an edit

Three edits (C3, C4, N1) were proposed from counting output frequencies and **all three
were refuted by the prompt text**. C4's target encounter is *named verbatim* in an existing
exclusion. Dump the shard first:

```
python3 -c "import json;print(json.load(open('clinic/experiments/s2-promptdecomp/patches/s2-refloor2.json'))['axis_risk'])"
```

### 5.2 Isolate the edited axis

`arm_em − baseline_em` confounds the edit with **resampling of the other three axes**.
COPA alone swings **5.4pp** across draws of a byte-identical prompt. Verified the axes
*are* independent (only the changed axis drops below its self-agreement band), so the
confound is pure resampling.

**Estimator:** hold the baseline's other axes fixed, swap in the arm's changed axis,
average over all (baseline draw × arm draw) pairs. This revised R-B v2 from +0.6 → +0.4pp
and made T-OFF's negative clearer.

### 5.3 Never quote a single draw

Five numbers evaporated this way: C6 (+0.61 → −0.2), rf3 (+1.6 → +0.2), G1 (+1.02 → fires
0/95), rbo (+0.8 → +0.4), and the copafix→clockfix / timefull→timefix "withdrawal gains"
(both ~1 sd with overlapping ranges). **Always print per-draw values and the sd.**

### 5.4 The mechanical bound only works for level rules

Applying a rule to recorded output predicts a **level rule** (maps a stated fact to a
level) well — R-B v2 came in at fixes 2 / breaks 2 against a predicted 2.3 / 2.0. It does
**not** predict an edit that adds a *reasoning step* or output field. Three such
projections were wrong (C6, v3, v4). **If the edit asks the model to decide something new,
state the mechanism and run it — do not quote a number.**

### 5.5 Hold out *encounters*, not just draws

G1 looked validated on draws e/f — new **samples** of the same 164 encounters. It fires
**0/95** on new encounters. Sampling hold-outs do not test generalisation.

---

## 6 · Open items

### Needs an SME — this is the real blocker

1. **5 DATA label contradictions** — `972818816`, `975302949`, `974619327`, `974379104`,
   `847387443`: `gt_data_level` and `gt_em_code` cannot both be satisfied.
2. **Cat-1 counting on ordered tests** — 21 of 28 DATA errors are over-credit with
   AMA-textbook arithmetic. 0 of 28 involve cat2/cat3.
3. **Continuing-Rx risk** — 42+ encounters hinge on it; the model follows the prompt's own
   stated rule and GT disagrees on 5. No discriminator exists in the model's output.
4. **Suspect GT labels** — `970415534` (discontinue one antidepressant, start another →
   labelled straightforward), `963686310` (OTC recommendation → labelled moderate, AMA
   lists OTC as Low), `963755508`, `958484336`.

**DATA is where the remaining headroom is, and it is a labels problem, not a prompt
problem.** rf2's DATA oracle term is **−2.6pp** — forcing GT DATA makes em trail *worse*,
and worse than it did on copafix (−1.2pp).

### Engineering debt

- **`clinic/experiments/s2-promptdecomp/` is entirely untracked.** The plan and ~15
  analysis scripts exist on one machine. `CLAUDE.md` says `.py`/`.md`/`.sh` under
  `*/experiments/` should be committed. **Do this first.**
- **Worktree has uncommitted changes** beyond PR #6132: `axes.py` (C6, R-B v2/v3/v4 flags),
  `business_logic.py` (G1 — withdrawn, default-off), `build_template_v2_axes.py`,
  `template_v2_axes.json`, the activity, and `test_referral_minor_guard.py`.
  Only **R-B v2** is worth proposing; the rest are recorded negatives.
- **`harness/s2-run-path` is not pushed** — it carries `--dag-template`, `_AXIS_CALLS` and
  the effort cache key. Without it the S2 arms cannot be launched.
- **Evaluation artifacts missing.** `docs/EVALUATION.md` requires two per
  candidate-vs-baseline evaluation (eval report + changelog from `causes.json`). After ~20
  arms, neither exists.
- **G1 parity replay never run.** It changes `apply_v1_post_processing`, so
  `scripts/parity_replay.py` would differ on touched encounters by construction. Moot while
  G1 stays withdrawn.

---

## 7 · How to run things

```bash
cd ~/workspace/coding-ai-harness
source scripts/env.sh                      # exports $PY, QH_PLATFORM_ROOT, secrets
export QH_PLATFORM_ROOT=$HOME/workspace/qh-platform/.worktrees/clinic-s2-decomp
QH_PLATFORM_ROOT=$QH_PLATFORM_ROOT PYTHONPATH=. $PY clinic/experiments/s2-promptdecomp/make_patches.py
clinic/experiments/s2-promptdecomp/run_arm.sh <arm> <dataset> <rows> <prefix> a b c
```

**Concurrency: `RC=96 PC=16`, and always start `rate_supervisor.sh` alongside.** They ship
as a pair. At 96 the failure mode is a draw that *crawls* or wedges — encounters enter the
DAG and do not come out, with **zero connection errors**, while the model cache keeps
ticking so both liveness watchdogs read it as alive. The rate supervisor measures
throughput instead and kills it; the driver's repair loop then resumes from the files
already paid for. **3 kills across 42 draws in the big sweep, all recovered.**

Never run two `core.harness` against the same out-dir, and check `pgrep -f core.harness`
before starting anything.

### Scoring

```bash
PYTHONPATH=. $PY clinic/experiments/s2-promptdecomp/compare_mean.py      # the 177
PYTHONPATH=. $PY clinic/experiments/s2-promptdecomp/compare_bench.py     # v1_benchmark
```

> **Always filter partial draws.** `time_union.load()` does **not**. An in-flight draw with
> 20 files silently shrinks every intersection to 20 encounters. `compare_bench.py` guards
> this; ad-hoc scripts must too. This bug was caught once mid-analysis and would have been
> invisible in the output.

### Run outputs are local-only and unbacked

`clinic/experiments/s2-promptdecomp/.ns/` is **225,128 cache files / 11 GB** of per-draw
namespaces. `sync_data.sh` pushes only `clinic/dataset` and `ed/dataset` — per `CLAUDE.md`
experiment namespaces are deliberately *not* synced, because each draw starts from an empty
cache. So the ~60 draws behind every number in the Notion note **exist on one machine and
regenerate only by re-running** (the 39-draw holdout sweep took ~15 h).

---

## 8 · If I were continuing

1. **Commit the untracked experiment code** — highest value, lowest effort, and it is
   currently one disk failure from gone.
2. **Answer the architectural question.** V1.3 at 91.6% (sd 0.00) vs every S2 arm at
   87.4–90.5% is the only large, replicated effect in this work. Either find why
   decomposition loses ~2.5pp — my leading hypothesis is the loss of cross-axis voting,
   since V1.3 majority-votes 3× over one prompt while S2's five axis calls each vote alone
   — or stop investing in S2.
3. **Do not resume RISK edits.** §4's search space is closed, and `abst-ewtc-today-v1b`
   shows the deficit is not where the edits are.
4. **Take the three SME questions to a coder.** DATA is the only axis with real headroom
   and its oracle is *negative*, which means the labels need adjudicating before any
   DATA prompt work is meaningful.
5. **Re-baseline any new comparison on both datasets.** Three edit families (C1/C2 COPA,
   the TIME series, E-A) read neutral-or-positive on the 177 and negative on the holdout.
   The 177 alone is not sufficient evidence.
