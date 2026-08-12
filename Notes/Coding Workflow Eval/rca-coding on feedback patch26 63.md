---
updated: 2026-08-12
tags: [rca, coding-pod, eval, clinic]
---
# RCA — clinic COPA/DATA/RISK on `v1-20260720-feedback-63-patch26`

Full report (with methods and the withdrawn findings) lives in the repo:
`coding-ai-harness/clinic/experiments/20260720-feedback-iter-2-rca/reports/rca-copa-data-risk.md`.
This note is the tables. See [[taxonomy]] for what the columns mean.

**Setup.** 63 encounters, 3 fresh seed lanes, pin `81ca502e9d`. Feedback
`clinic-v1-20260720` judges the **2026-07-22 prod export**; the batch's
`qh_platform_sha` is null, so every finding is **unanchored** — "already fixed since the
export" and "different pipeline" are indistinguishable.

**Scope.** 20 errors are 3/3 on these axes; **only 11 sit on human-grade GT**. The other
9 are back-filled cells where GT was copied from the tool's own output, so an "error"
there means drift from the old export, not human disagreement.

## Case table

| case | axis | gt → pred | dir | disposition | mechanism | cause | evidence |
|---|---|---|---|---|---|---|---|
| 7 | copa | moderate → low | under | `system` | **candidate** — UNDER-SPECIFIED vs CONFLICT vs NOT-RETRIEVED, unresolved | C-1 | verifiable |
| 23 | copa | moderate → low | under | `system` | NOT-FOLLOWED / RULE-WRONG | C-1b | verifiable |
| 45 | risk | low → straightforward | under | `system` | NOT-RETRIEVED | C-4 | verifiable |
| 68 | data | low → moderate | over | `system` | locus TBD | C-5 | verifiable |
| 15 | risk | low → moderate | over | `system` | NOT-FOLLOWED *(weak)* | C-2 | partial |
| 18 | data | straightforward → moderate | over | `upstream-input` | — | C-3 | **reviewer-asserted** |
| 17 | data | moderate → straightforward | under | `upstream-input` | — | — | **reviewer-asserted** |
| 17 | risk | straightforward → low | over | `upstream-input` | — | — | **reviewer-asserted** |
| 57 | risk | moderate → high | over | `label-or-standard` | — | — | verifiable |
| 27 | data | straightforward → moderate | over | **unlocalized** | — | — | label, no reviewer reasoning |
| 67 | copa | moderate → low | under | **unlocalized** | — | — | label, no reviewer reasoning |

```
disposition            n        evidence class              n
system                 5        verifiable                  5
upstream-input         3        partial                     1
label-or-standard      1        reviewer-asserted           3
unlocalized            2        no reviewer reasoning       2
                      --                                   --
                      11                                   11
```

**`evidence` is not in the standard taxonomy** — added because the attribution tiers
(cited / narrowed / ablated) all describe evidence about the *model*. Three findings rest
on a reviewer statement about chart content the pipeline never received; those flip
disposition entirely if the reviewer is mistaken.

## Causes

| id | cause | axis | case | fix lane |
|---|---|---|---|---|
| C-1 | chronic-stability judgement on a symptom-worsening case | copa | 7 | prompt — pending mechanism |
| C-1b | wrong COPA pathway test — high-risk bar used for undiagnosed-new-problem | copa | 23 | prompt |
| C-2 | Rx management inferred from a bare medication list | risk | 15 | prompt |
| C-3 | this-visit vs prior-visit orders not distinguishable from the note | data | 18 | **extract** |
| C-4 | risk-bearing actions (x-ray, referral) never surfaced | risk | 45 | prompt — placement |
| C-5 | external test results counted as individual Cat-1 points | data | 68 | prompt — locus TBD |

## Before → after, and what forced each change

Net: **4 mechanisms wrong, 2 dispositions wrong, one group that was not a group, one row
silently dropped. 3 of 11 survived untouched.** Kept because the point is improving the
process, not just this batch.

| case | axis | gt → pred  | before                        | after                                | what forced the change                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| ---- | ---- | ---------- | ----------------------------- | ------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 18   | data | sf → mod   | C-3 · `system` · NOT-FOLLOWED | C-3 · **`upstream-input`**           | Three checks. (1) The narrative's `Excluded:` field is **populated with prior-visit and copy-forward items** — the model cited and applied L123-124, so NOT-FOLLOWED is falsified by its own output. (2) The cited note line describes the labs as ordered, present tense, in the plan, with no temporal qualifier — it positively reads as a this-visit order. (3) Full `input.csv` column dump: notes, problem list, medications, empty `procedures_at_encounter` — **no orders/labs/results column exists**; lab terms appear only inside note prose. Signal never arrived, and the note pointed the other way |
| 27   | data | sf → mod   | C-3 · `system` · NOT-FOLLOWED | **unlocalized**                      | Read `detail.data.cat1.items[]` rather than assuming the group's story applied: the cited item is described as ordered **today**, explicitly this-visit, so the prior-visit cause never applied here. Reviewer's free text discusses COPA and Rx and **never mentions data** — a GT label with no reasoning behind it                                                                                                                                                                                                                                                                                             |
| 68   | data | low → mod  | C-3 · `system` · NOT-FOLLOWED | **C-5** · `system`                   | `detail.data.level_rationale` counts **9 external-specialty results as 9 separate Cat-1 points** plus 1 ordered test. Aggregation / external-vs-internal question, no prior-visit element. Reviewer's text is about time-based coding, corroborating nothing here. Different rule, different edit ⇒ different cause                                                                                                                                                                                                                                                                                               |
| 7    | copa | mod → low  | C-1 · NOT-FOLLOWED            | C-1 · **candidate — 4 live `(locus, mechanism)` pairs:**<br>① `L75 § STABLE CHRONIC` · **UNDER-SPECIFIED**<br>② `L75 § STABLE CHRONIC` · **CONFLICT**<br>③ `L68 § COPA stability` · **NOT-RETRIEVED**<br>④ — · **NOT-A-PROMPT-ERROR** (`label-or-standard`) | **Why it moved off NOT-FOLLOWED.** (1) Grepped the prompt: the worsening evidence **is** present, so not an input gap. (2) Tested L75's four triggers against the note — **none fires**: no new agent, no new workup for the chronic, the worsening is patient-reported **symptoms** while (c) requires an *objective* sign, and the note states the baseline is regular. The model did not fail to retrieve the list; it applied it and found nothing to trigger on. **L75's (a)–(d) has no symptom clause, though L68 and L70 both do** — three sections, inconsistent criteria.<br><br>**Why it cannot settle yet.** `diagnosis.md`: *"Q3 usually cannot be answered from one encounter… the tiebreaker is cross-encounter."* Four options, four different edits:<br>① *means* the trigger list is simply silent on symptom worsening → **fix: add a symptom clause to (a)–(d)**<br>② *means* `"when ANY of these appear"` reads as the closed operative test, so L75 implies symptoms do **not** destabilise while L68/L70 say they do → **fix: reconcile L68/L70/L75 into one test**<br>③ *means* L68 already covers symptoms and the model never reached it → **fix: placement / salience, not wording**<br>④ *means* the model was right — episode resolved, medication helped, baseline documented regular — and GT is the outlier → **fix the eval, not the pipeline**<br><br>**What decides it:** L75 applied correctly on many other chronics and wrong only here → ①/②; applied inconsistently across many → ①; L68 never cited anywhere in the batch → ③; reviewers routinely disagreeing with the model's "stable" calls → ④. Cross-encounter tiebreak running |
| 23   | copa | mod → low  | C-1 · NOT-FOLLOWED            | **C-1b** · NOT-FOLLOWED / RULE-WRONG | `copa_rationale` applies the **high-risk** test (absence of urgency / threat-to-life language) to a problem the reviewer classifies as an *undiagnosed new problem with uncertain prognosis* — a different pathway with a different test. Unlike case 7 it engaged; it engaged the wrong rule. Grouping keys on `(locus, mechanism)`, so it cannot share a group with 7                                                                                                                                                                                                                                           |
| 17   | risk | sf → low   | C-4 · NOT-RETRIEVED           | **`upstream-input`**                 | Inherited iter-1's finding and applied it to the *risk* axis without re-checking. Grepped the prompt: **no orders section exists** and none of the specific labs the reviewer names are present. NOT-RETRIEVED asserts the model failed to surface something it had — it did not have it. Same absent labs drive this encounter's data axis, so both dispositions now match                                                                                                                                                                                                                                       |
| 15   | risk | low → mod  | C-2 · NOT-FOLLOWED            | C-2 · NOT-FOLLOWED *(weak)*          | Grepped to test whether the model **fabricated** the verb its rationale relies on, since L203's guard excludes a bare medication list with no continue/refill decision. The word "continue" **occurs 5× in the payload**, so *invented the trigger* cannot be distinguished from *found it on another drug and mis-attributed it*. Mechanism survives; the evidence does not support stating it firmly                                                                                                                                                                                                            |
| 45   | risk | low → sf   | C-4 · NOT-RETRIEVED           | **unchanged**                        | Ran the same input-presence check that flipped case 17, expecting the same result — it came back the other way: the x-ray and surgical-referral terms are **all present** in the prompt, and the risk rationale enumerates only dietary/hydration advice. Signal available, never surfaced ⇒ confirmed rather than assumed. **The one row where the check defended the original call**                                                                                                                                                                                                                            |
| 17   | data | mod → sf   | `upstream-input`              | **unchanged**                        | Already an input gap on iter-1's independent finding of zero order records; re-confirmed by the same prompt grep                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| 57   | risk | mod → high | `label-or-standard`           | **unchanged**                        | The model graded an ER-escalation decision as High, which is AMA's *"decision regarding hospitalization"* exemplar, and the reviewer's own comment agrees total MDM is High while GT records Moderate. Disagreement is with the label                                                                                                                                                                                                                                                                                                                                                                             |
| 67   | copa | mod → low  | *absent from the table*       | **unlocalized**                      | Caught by counting — 10 rows against 11 errors. Reproduces a 3/3 COPA error, but the reviewer's text is entirely about new-vs-established and never addresses COPA. With no cause assigned it fell out of a cause-organised table                                                                                                                                                                                                                                                                                                                                                                                 |

## The pattern in the corrections

Every revision moved **away** from `system`, and every one came from a challenge rather
than from my own checking. Three checks did all the work:

- **read the structured output** — `Excluded:`, `detail.*.items[]`, `level_rationale`
  record whether a rule was engaged. Falsified NOT-FOLLOWED on 18, 27, 68.
- **grep the assembled prompt** for the discriminating signal — flipped 17-risk, weakened
  15, and **confirmed** 45. A check that only ever overturns is a check being used to
  rationalise; 45 is the evidence it is sound.
- **count the ledger** — 10 rows vs 11 errors surfaced 67.

The ordering fix for the skill: **input-presence check → "did any rule actually fire?" →
locus → only then the mechanism tree.** The tree is elaborate and inviting, so it pulls
you into classifying *how* the prompt failed before establishing *that* it did. This
ordering would have caught four of the five.

## Open

1. **Does silver have an orders column `build_dataset` is not selecting?** One read-only
   query. No order or result records reach the pipeline at all, so every Cat-1 order point
   is inferred from note prose. Independent of any single case, and the most actionable
   item in the cycle. Same shape as the `zc_note_type.NAME` gap — see
   [[clinic-coding-note-extract-prod-gap]].
2. **Case 7 mechanism** — cross-encounter tiebreak running.
3. **Adjudicate case 18** with the coder: were those labs ordered that day? Decides
   `upstream-input` vs `label-or-standard`.
4. **Localize 27 and 67.**
5. **Identify the 2026-07-22 prod revision** to anchor the batch.

## Withdrawn

- **"Null note timestamps make prior-visit data undecidable."** 99.3% of note timestamps
  are the `1900-01-01` sentinel (upstream, present in `input.csv`), but it is **not**
  causing these errors: all notes in a prompt belong to the current encounter, the model
  never references the sentinel in 760 cached responses, and the single-note case still
  over-counts. A data-quality defect worth fixing at source; not a cause.
- **"C-3 covers 3 encounters."** Grouped by axis + direction, which is a symptom. The
  three need three different edits.

## Related

[[taxonomy]] · [[Coding Pod]] · [[Evaluation - Tuning Process]] · [[Prompt Tuning Runbook]]
