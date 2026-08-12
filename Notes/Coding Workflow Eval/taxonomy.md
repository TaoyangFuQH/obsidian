---
updated: 2026-08-12
tags: [reference, coding-pod, eval]
---
# RCA failure taxonomy — and what breaks when you automate it

Source of truth: `coding-ai-harness/skills/rca-coding/references/diagnosis.md`. This note
is the durable summary plus the concerns that matter for building an **LLM auto-judge**
on top of it — the taxonomy already answers most of what such a judge would be asked to
produce, and the parts it deliberately refuses to answer are the parts a judge will get
wrong.

## The shape: four independent dimensions

Recorded per **(encounter, axis)** error. Kept independent on purpose — collapsing them is
how a symptom ends up wearing a cause label.

| dimension | answers | shape |
|---|---|---|
| Disposition | does this error enter RCA at all? | closed set, pick one |
| Locus | *where* did the bad value come from? | an **address**, not a category |
| Mechanism | *how* did the prompt fail? (LLM loci only) | one of 7 tree branches |
| Attribution | how much do you actually know? | cited / narrowed / ablated |

## 1 · Disposition (closed set)

Exactly one per row, and the count reconciles against `errors.json` — a row with no
disposition is the one failure mode the list cannot show you.

- **`system`** — wrong value from adequate input. The only one that continues to
  localization.
- **`upstream-input`** — the pipeline was right *given what it received*. A garbled column,
  or a note that never carried the discriminating signal. → fix the extract.
- **`label-or-standard`** — the reviewer diverged from the pipeline's AMA-first standard, or
  the label is wrong. → fix the eval, not the pipeline.
- **`not-reproducible`** — 0/3 or 1–2/3. Record which; they are different findings.

`upstream-input` is the highest-value call and the one an automated judge is least likely
to make: **when the signal isn't in the note, no verifier, gate or ensemble can ever catch
the error.** A judge that can't reach this verdict will keep proposing prompt fixes for
data problems.

## 2 · Locus — an address, not a category

| locus kind | address format |
|---|---|
| prompt text | `<prompt module>.py:CONSTANT § heading` |
| deterministic code | `<module>.py::<function>` (+ branch or table) |
| input field | `input.csv:<column>` |

A node id alone is too coarse: two errors in one node needing different edits must not
collide. Two stages — walk the DAG for the first node whose output is wrong *given correct
inputs* (deterministic nodes are exactly verifiable by recomputation; LLM nodes are where
you stop), then address the part of the prompt. `core/prompt_index.py` turns a character
offset into that address, and is the existing answer to "visualize context ↔ prompt
matching".

## 3 · Mechanism — the prompt decision tree

Decided **by evidence, not plausibility**. Every branch needs something quoted from the
prompt or the thinking trace.

```
Q1: Is there prompt text governing this situation?
│
├─ NO  → GAP                  fix: add a rule
│
└─ YES → Q2: Did the model engage with it?
         ├─ never mentioned   → NOT-RETRIEVED    fix: placement, emphasis, ordering
         ├─ cited then        → NOT-FOLLOWED     fix: restate, few-shot, constrain output
         │  did otherwise
         └─ cited and applied → Q3: Was the rule right here?
                                ├─ rule wrong         → RULE-WRONG
                                ├─ underdetermines    → UNDER-SPECIFIED
                                ├─ another section    → CONFLICT
                                │  says the opposite
                                └─ right + applied    → NOT-A-PROMPT-ERROR
```

- **NOT-RETRIEVED vs NOT-FOLLOWED is salience vs compliance.** On a ~1,100-line prompt, a
  rule the model never surfaced needs *moving*, not restating. The thinking trace decides
  this for free.
- **Mechanism is never itself a finding.** "NOT-FOLLOWED" is not one; *"the Mod-25
  significance guard in `§ MERCY RULE C` is cited and then overridden by the
  preventive-pairing example"* is.

## 4 · Attribution strength

Three **different claims**, not degrees of one confidence:

- **cited** — the thinking names the rule. Cheap, often precise, but a self-report: which
  rule it *cited*, not what *caused* the output.
- **narrowed** — node → assembled parts → section. Certain as an address, silent on cause.
  Says where, never why.
- **ablated** — section removed/altered, encounters re-run with everything else held, the
  error class flipped. **The only tier that establishes causation.**

> Most findings will be cited or narrowed, and that is fine. What is not fine is a cited
> finding written up as though it were ablated.

## The cause is deliberately NOT in the taxonomy

There is no error-type enum, and this is load-bearing:

> Any fixed enum over "the prompt is wrong" is incomplete by construction, and the bucket
> that absorbs the overflow ends up being a symptom wearing a cause label.

The test for whether a tag earns its place: **if two errors share the tag but need
different edits, it is not the grouping key.** Three COPA over-codings from three prompt
sections are three causes with three edits, not one type.

Grouping keys on **(locus address, mechanism)**, matched against a persistent registry with
stable IDs (`C-007`) rather than re-clustered per batch — that is what lets the next cycle
answer *"did C-007 recur after the fix shipped?"*. Ordered by frequency, then attribution
strength, then actionability.

---

# Concerns for an LLM auto-judge

Four ways the taxonomy constrains the design. Each one breaks the judge if ignored.

**1 · The judge may emit categories but not causes.** Output `(locus address, mechanism)` —
both closed — plus free-text cause. A judge that emits a *cause category* re-introduces the
enum the taxonomy exists to avoid.

**2 · `GAP` is the verdict an LLM will over-produce.** Q1's "no" asserts a negative over a
large document, and a false GAP compounds: add a rule, two sections now cover it, next
cycle the error lands in `CONFLICT`. The judge must be *forced* to record terms searched
and sections read — `prompt_index --find` makes that mechanical and checkable rather than
a claim.

**3 · Single-pass judging will systematically mislabel.** NOT-FOLLOWED and UNDER-SPECIFIED
are indistinguishable from one encounter; the tiebreaker is cross-encounter (same rule
right on 20 others → not-followed; inconsistent across many → under-specified). Two passes,
mirroring the skill: per-encounter *candidate*, then a grouping pass that settles Q3.

**4 · A judge can never exceed `cited`.** Only a counterfactual harness run reaches
`ablated`. Cap the judge's attribution field at `cited` in the schema so a confident judge
can never masquerade as an ablation.

## Other design notes

- **Use a different model family from the labeler.** Clinic labels with `claude-opus-4-6`;
  judge with GPT-5.4 or Gemini (both already wired — `clinic-verifier-scoring` uses them).
  Same-family judging has correlated blind spots: it will agree with the reasoning that
  produced the error.
- **Judge only the 3/3 deterministic errors.** Non-reproducing rows produce confident
  stories about sampling noise. The skill is explicit that only 3/3 earns a root cause.
- **Calibrate before trusting.** The auditor workbook's `Primary Error Pattern` column is a
  human-authored 8-category taxonomy on ~24 rows — a gold set for judge-vs-human agreement.
  Build the human-reasoning summarizer first, calibrate, *then* let the judge steer.
- **`core/error_report.py` deliberately left this manual**: *"reading the model's own
  rationale on its worst misses and writing de-identified findings is your job… Do not skip
  it or fake it with generic boilerplate."* Automating it is reasonable, but that objection
  should be answered rather than ignored.

## Related

- [[Coding Pod]] · [[Prompt Tuning Runbook]] · [[Evaluation - Tuning Process]]
- Repo: `skills/rca-coding/references/{diagnosis,reproduction,reporting,interventions}.md`,
  `docs/ITERATION.md`, `docs/EVALUATION.md`, `core/prompt_index.py`
