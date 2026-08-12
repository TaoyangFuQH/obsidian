---
updated: 2026-08-12
tags: [rca, coding-pod, eval, clinic]
---
# RCA — clinic COPA/DATA/RISK on `v1-20260720-feedback-63-patch26`

Repo report: `coding-ai-harness/clinic/experiments/20260720-feedback-iter-2-rca/reports/rca-copa-data-risk.md`.
See [[taxonomy]] for what the columns mean.

> **Third pass, and the authoritative one.** The first two passes re-categorised cases on
> every revisit, which is itself the finding. This pass ran a fixed six-check sequence per
> case — GT provenance → what the reviewer actually said → input presence in `request.user`
> → rule presence via `core.prompt_index` over the *assembled* prompt → engagement via
> **thinking traces**, not rationales → did any enumerated trigger actually fire — and only
> then walked the tree. **9 of 11 rows changed.** Earlier tables in this note are superseded.

**Setup.** 63 encounters, 3 fresh seed lanes, pin `81ca502e9d`. Feedback
`clinic-v1-20260720` judges the **2026-07-22 prod export**; `qh_platform_sha` is null, so
every finding is unanchored. 20 errors are 3/3 on these axes; **11 sit on human-grade GT**.
Attribution is **`cited`** on all 11 — nothing was re-run, so nothing here is causal.

## Re-adjudicated case table

All 11 rows. `after` = disposition · mechanism · locus. Attribution is **cited** on all 11 — nothing was re-run, so no row is `ablated`.

| case | axis | gt → pred | before | after | reasoning |
|---|---|---|---|---|---|
| 7 | copa | moderate → low | `system` · **candidate**, 4 live pairs (L75·UNDER-SPECIFIED / L75·CONFLICT / L68·NOT-RETRIEVED / NOT-A-PROMPT-ERROR); two passes earlier NOT-FOLLOWED, then NOT-RETRIEVED | **label-or-standard · NOT-A-PROMPT-ERROR** · `input.csv:gt_copa_level` (prompt address examined and cleared: `system_prompt.py:AMBULATORY_SYSTEM_PROMPT § HOW TO CODE THIS ENCOUNTER`, STABLE CHRONIC (a)–(d)) | CHECK 5 kills both prior mechanisms with one artifact: the vote-1 thinking trace reads "IBS is stable … despite a brief diarrhea episode mentioned in the history" and "IBS shows no exacerbation" (verified present in `repro-seed1/nodes/enc_898193119.json`), so the rule was both surfaced and applied. CHECK 6 then fires zero of the seven enumerated triggers — no worsening token, no adverse objective value, no new agent, no new workup — while the A/P affirmatively says "Stable … Reports regular BM". The cross-encounter control settles Q3: cases 12/21/70 run the identical rule at the identical address and all reach Moderate because each reviewer basis hits a trigger verbatim. |
| 23 | copa | moderate → low | `system` · **GAP** (leading; UNDER-SPECIFIED and label-or-standard still live); earlier NOT-FOLLOWED, then NOT-FOLLOWED / RULE-WRONG | **system · RULE-WRONG** · `knowledge_base.py:AMA_2023_KNOWLEDGE § Problem Definitions` — the V1.18 STRICT READING gate (L107-123, gating the definition at L105) | The GAP is falsified mechanically: `prompt_index --find "undiagnosed new problem with uncertain prognosis"` returns 4 hits, 3 of them in `knowledge_base.py`, and `--find "STRICT READING"` resolves to § Problem Definitions @66381 — the rule was declared missing because only `system_prompt.py` was grepped. CHECK 5 shows vote 2 reaching the reviewer's answer ("So I'm settling on Moderate COPA for this case") and then reversing on the gate's urgency criterion. CHECK 6 fires 0 of 4 exception triggers (order is "Future", no progression statement, no referral, no hospitalization), so the gate keys on documented-urgency language while AMA L105 and the gate's own worked examples key on the intrinsic morbidity of the suspected condition. |
| 67 | copa | moderate → low | **absent from the cause table** on the first pass; **unlocalized** on the second | **label-or-standard · NOT-A-PROMPT-ERROR** · `input.csv:gt_copa_level` (origin cell: client sheet "Reviewer COPA" = Moderate) | CHECK 1 confirms `copa=reviewer`, so the label is human rather than backfill drift — but CHECK 2 finds the reviewer's entire written finding is new-vs-established ("Should be established"), with a blank Reviewer Notes cell. CHECK 6 fires none of the five Moderate pathways: the documented direction is improvement throughout, GERD has an HPI status but no plan entry (excluded by the floor clause by name), vitals are normal, the abrasion is superficial. Decisive: the reviewer's own "All ICD-10 Codes" cell holds six acute/self-limited/aftercare codes and zero chronic codes, so their Moderate cannot be reconstructed from any pathway — it back-derives from the 99214 they asserted. |
| 17 | data | moderate → straightforward | `upstream-input`, on the basis "case 17's labs are not in the payload at all" (inherited from iter-1) | **upstream-input · NOT-A-PROMPT-ERROR** · `input.csv:consolidated_notes` — basis corrected | The precedent is factually wrong and I verified it: `request.user` contains "Labs ordered this AM to assess current status. Still in process" at offset 12135, and all three votes carry that exact string as a `cat1` `source_quote`. What is absent is the *enumeration* — the lab tab's three named tests — and the input row has no orders column in its 47-column schema. CHECK 6 caps the in-payload total at 2 Cat-1 points (Low), one level short of the reviewer's 3, so the disposition holds while the fix requirement changes from "add an orders field so labs appear" to "carry the ordered tests individually". |
| 18 | data | straightforward → moderate | C-3 · `system` · NOT-FOLLOWED, then re-called **`upstream-input`** | **system · UNDER-SPECIFIED** · `system_prompt.py:AMBULATORY_SYSTEM_PROMPT § STEP B — Element-level rules` | CHECK 3 closes upstream-input: the payload carries a structured "Orders Placed This Encounter" block listing only three medication reorders, and a scan of all 63 payloads shows that block *does* enumerate labs in 5 of the 11 encounters that have it — so its silence is an in-payload signal, not missing data. CHECK 6 kills NOT-FOLLOWED: STEP B's prior-visit clause is scoped to reviewed *results* and the note says "No results found", while the copy-forward clause needs same-wording/date/label and the A/P sentence is undated. All three thinking traces name the discrepancy and override it ("documented in the plan rather than in a separate orders section … so I should count them"); at enc 963638826 sibling votes split on the identical criterion, which is the Q3 signature of under-specification. |
| 27 | data | straightforward → moderate | C-3 · `system` · NOT-FOLLOWED, then **unlocalized** | **label-or-standard · NOT-A-PROMPT-ERROR** · `input.csv:gt_data_level` | The check both prior passes skipped is the second half of CHECK 1: `system_data_level == gt_data_level == straightforward` in the 2026-07-22 export (verified), and `errors.json` records the data row as `correct-asserted` with empty evidence — the reviewer *agreed* with the tool on data, so there was never a human disagreement to root-cause; `pred=moderate` exists only in the pinned repro. CHECK 6 then shows the GT is unreachable: Straightforward requires 0 Cat-1 points and the note carries three quoted same-day orders ("Check urine for protein today" etc.), each with its own `source_quote`. Even a hostile merge into one draw yields ≥1 point. |
| 68 | data | low → moderate | C-3 · `system` · NOT-FOLLOWED, then **C-5** · `system` · locus TBD | **upstream-input · NOT-A-PROMPT-ERROR** · `input.csv:consolidated_notes` (no order-provenance feed anywhere in the 48-column schema) | The discriminating fact — which provider ordered each reviewed lab, and when — returns 0 hits for `ordered by` / `Ordering Provider` / `Order Date` / `previously ordered` in `request.user`, has no column in `input.csv`, and appears in 0 of 760 cached payloads dataset-wide, so "locus TBD" was unresolvable because there is no prompt address to find. CHECK 5 kills NOT-FOLLOWED: the STEP B prior-visit rule is retrieved unprompted by all three votes and vote 3 actually enforces it, excluding CBC, lipid panel and potassium. CHECK 6 fires no trigger — the note attributes the workup to hematology and cardiology, pointing away from same-clinic prior ordering. |
| 15 | risk | low → moderate | C-2 · `system` · NOT-FOLLOWED ***(weak)*** | **system · NOT-FOLLOWED** · `system_prompt.py:AMBULATORY_SYSTEM_PROMPT § CRITICAL RISK RULES` → Continuing Rx rule clause (c) (source L217-221), reinforced by § Example 6 (L380-383) | The "weak" qualifier is retracted because CHECK 4 found the specific conjunct the earlier grep missed: `--find "not merely a med-list reconciliation pass"` @23096 and `--find "NO refill order placed"` @39489 — Example 6 scores the literal surface form "stable on \<drug\>" with no refill as *no* management action. CHECK 6 shows clause (c) is the single failing conjunct for both pantoprazole and rizatriptan ("Medications at Encounter: Not available"; Relevant Orders are labs only), and applying the rule correctly returns the GT. CHECK 5 shows conscious override, not non-retrieval — one vote asks "whether there's an explicit decision documented or just a status statement" and answers "implicit continuation", a term the prompt never uses. Secondary defect verified: the twice-referenced "RISK-MEDS-OVER guard below" (@21563, @22385) is never defined anywhere in the 87,274-char prompt. |
| 17 | risk | straightforward → low | C-4 · `system` · NOT-RETRIEVED, then re-called **`upstream-input`** | **system · UNDER-SPECIFIED** · `knowledge_base.py:MERCY_EM_GUIDE_KNOWLEDGE § MDM Complexity Grid` — Risk column (L198-199, @75754), unreconciled with `knowledge_base.py:AMA_2023_KNOWLEDGE § Risk of Complications` (@72502) | The upstream-input call transplanted the *data* axis's missing lab tab onto the *risk* axis; the risk claim rests entirely on "Labs ordered this AM", which is verbatim in `request.user` and quoted by all three votes. CHECK 5 kills NOT-RETRIEVED: vote 3's thinking says "lab ordering itself carries minimal risk of morbidity since it's just a blood draw" and vote 2 cites the AMA "initiate or forego further testing" clause by name. CHECK 6 fires none of the four Low exemplars, and the Straightforward rung ships with zero examples — cross-encounter, test-ordering is graded Minimal 12× across 5 encounters and Low 11× across 6 under the identical prompt. |
| 45 | risk | low → straightforward | C-4 · `system` · NOT-RETRIEVED — and explicitly *re-confirmed* by an input-presence check on the second pass | **system · UNDER-SPECIFIED** · `system_prompt.py:AMBULATORY_SYSTEM_PROMPT § CRITICAL RISK RULES` @21361, specifically "Routine referrals (PCP, specialist, urgent care) = Minimal or Low risk" @22479 | The second pass ran CHECK 3 (signal present) and stopped, treating that as confirmation of NOT-RETRIEVED — but CHECK 5 shows all three thinking traces argue the discriminators explicitly ("Ordering diagnostic tests like an x-ray does introduce some risk … Low might be more appropriate"; two grade the surgeon referral by name). CHECK 6 shows the only rule that fires is a sentence that returns *both* answers, verified verbatim at @22479. Cross-encounter, identical routine referrals are graded Low 13× and Minimal 15×, with one encounter splitting Low/Low/Minimal internally. |
| 57 | risk | moderate → high | **`label-or-standard`** (unchanged across two passes) | **system · CONFLICT** · `system_prompt.py:AMBULATORY_SYSTEM_PROMPT § CRITICAL RISK RULES → ER/URGENT REFERRAL RISK` (L210-213) vs `knowledge_base.py:AMA_2023_KNOWLEDGE § High MDM` (L73) / `MERCY_EM_GUIDE_KNOWLEDGE § MDM Complexity Grid` (L201) / § 3. RISK ladder High line | label-or-standard requires the reviewer to have diverged from the pipeline's standard; CHECK 4 shows the pipeline had already adopted it — I verified "HIGH = Provider states patient needs DIRECT ADMISSION through ER, or condition is immediately dangerous" sits verbatim in the assembled prompt, labelled "per Mercy coding practice", word-for-word the reviewer's rule. CHECK 6 shows the same four-line block fires a High trigger and a Moderate trigger simultaneously — "immediately dangerous" fires, and the note matches the Moderate tier's own phrase ("Discussed need for urgent evaluation") — while the payload has 0 occurrences of admit/admission/inpatient/observation. Two further sections independently route the same action to High, so no single clause deletion fixes it. Q3 is a **CANDIDATE**: this boundary is exercised exactly once in the 63-case batch. |

**Anchoring audit (new, and it bounds every CHECK 4 above).** The dataset cache holds **two materially different assembled prompts**: 84,704 chars on seed lanes 1/2/3 (the dataset-build lane) and 87,274 chars on lanes S001–S003 (the reproduction lanes; `repro-seed1` = 1001/1002/1003). They differ in exactly five places — the STABLE CHRONIC (a)–(d) trigger list, the A/P-heading characterisation rule, the OTC Low rule, the Moderate Rx verb list, and the "ALWAYS scan" line. Cases **23, 17-data, 18, 27, 57** confirmed CHECK 4 against the stale 84,704 lane (`sig 503d7d9baff1`), which the reproduced votes never saw. I diffed every load-bearing span across both variants: all are byte-identical except the (a)–(d) list, which only case 7 depends on and which case 7 anchored correctly — so **no conclusion in the table flips**, but five rows are cited to the wrong bytes and case 15's finding sits one line from a span that does differ.

### Reconciled tally — 11 rows in, 11 rows dispositioned

**By disposition**

| disposition | n | cases |
|---|---|---|
| `system` | **6** | 23 (copa), 18 (data), 15 (risk), 17 (risk), 45 (risk), 57 (risk) |
| `upstream-input` | **2** | 17 (data), 68 (data) |
| `label-or-standard` | **3** | 7 (copa), 67 (copa), 27 (data) |
| `not-reproducible` | **0** | — every row reproduces 3/3 or 9/9 |
| **total** | **11** | |

**By mechanism** (within `system`, plus the non-system rows' terminal branch)

| mechanism | n | cases |
|---|---|---|
| UNDER-SPECIFIED | 3 | 18, 17-risk, 45 |
| RULE-WRONG | 1 | 23 |
| NOT-FOLLOWED | 1 | 15 |
| CONFLICT | 1 | 57 — **candidate**, boundary exercised once in the batch |
| GAP | **0** | the one prior GAP (case 23) is falsified |
| NOT-RETRIEVED | **0** | both prior NOT-RETRIEVED calls (7, 45) are falsified by thinking traces |
| NOT-A-PROMPT-ERROR | 5 | 7, 67, 27 (label) + 17-data, 68 (input) |
| **total** | **11** | |

**By evidence class**

| evidence class | n | cases |
|---|---|---|
| verifiable (signal is in our data) | **9** | 7, 23, 67, 18, 27, 15, 17-risk, 45, 57 |
| reviewer-asserted (chart content we never received) | **2** | 17-data, 68 |
| none | **0** | — |
| **total** | **11** | |

**By attribution** — `cited` 11 · `narrowed` 0 · `ablated` **0**. Nothing was re-run, so no finding in this batch establishes causation.

**Movement vs the prior passes** — 9 of 11 rows changed disposition or mechanism. Two held: case 17-data (disposition held, basis corrected — the precedent it rested on is false) and case 15 (held and upgraded from "NOT-FOLLOWED *(weak)*" to confirmed, locus sharpened from a generic line to Continuing Rx clause (c) + Example 6). Net direction: **`system` fell from 7 rows to 6, but its membership turned over almost completely** — 7, 27, 68 and 17-data left it while 57 entered it, and inside it every surviving mechanism changed.

**Unlocalized: 0.** Both prior unlocalized rows (27, 67) now carry a disposition. "The reviewer gave no reasoning" is an observation about CHECK 2, not a disposition — CHECK 6 is what converts it into one.

## Anchoring audit — bounds every rule-presence check above

The dataset cache holds **two materially different assembled prompts**: **84,704 chars** on
seed lanes 1/2/3 (the *dataset-build* lane) and **87,274 chars** on lanes S001–S003 (the
*reproduction* lanes; `repro-seed1` = 1001/1002/1003). They differ in five places — the
STABLE CHRONIC (a)–(d) trigger list, the A/P-heading rule, the OTC Low rule, the Moderate Rx
verb list, and the "ALWAYS scan" line.

Cases **23, 17-data, 18, 27, 57** were confirmed against the **stale** lane, which the
reproduced votes never saw. Every load-bearing span was diffed across both variants and all
are byte-identical except the (a)–(d) list — which only case 7 depends on, and which case 7
anchored correctly. **No conclusion flips**, but five rows are cited to the wrong bytes.

**Root enabler — a documented join that cannot work.** `reproduction.md` § 4 states that
`manifest.json:prompt_sha1[<key>]` and `run.json:prompt_fp` are "both sha1 of the same
prompt text". Measured on this batch they are `3e951ede…` vs `2c93596f…` / `5958c36e…` —
they hash different serialisations, so the prescribed manual join never succeeds and there
was no mechanical way to select the right lane. Use instead: **`run_seed S` → cache sigs
whose `run.json:seed ∈ {S001, S002, S003}`**, or read `prompts_snapshot/<key>_system.txt`.

**A standing precedent is false.** iter-1's "case 17's labs are not in the payload at all"
is wrong — the sentence is at `request.user` offset 12135 and all three votes quote it. What
is missing is the *enumeration* of the three named tests. As written the precedent justifies
the wrong fix, and it had propagated into two rows of the previous pass.


## Why the earlier categorisations were wrong

Grouped by the root cause of the *analytical* error. Nothing here indicts the taxonomy — every miss was already covered by a rule in `diagnosis.md` that simply was not run.

### 1 · Q2 answered from the rationale, never from the thinking trace — **7 of 11 rows**
*Cases 7, 15, 18, 23, 45, 68, and 17-risk.*

**Assumed:** that `<axis>_rationale` is a faithful summary of what the model considered, so a rule missing from it was never retrieved.

**Reality:** the rationale is a one-to-two-line justification of the *answer*; the deliberation lives in `thinking`, and it routinely contains the opposite of what the rationale implies. Case 7's rationale asserts "IBS is stable"; its thinking says "IBS shows no exacerbation" — the model *named the category* the reviewer invoked and rejected it. Case 23's vote 2 wrote "So I'm settling on Moderate COPA for this case" — the reviewer's exact answer — before reversing on the gate. Case 68's vote 3 did not merely retrieve the prior-visit rule, it enforced it and excluded three labs. Case 45 is the worst instance because the second pass *ran a check* (input presence), got a green light, and treated that as confirmation of NOT-RETRIEVED without ever opening the trace.

**Check that catches it:** CHECK 5 in its full form — all four artifacts (`<axis>_rationale`, `narrative` "Excluded:", `detail.<axis>[].source_quote`, `thinking`) for **all three votes**, with a NOT-RETRIEVED claim required to state the grep term and the zero hit count in `thinking`.

### 2 · The prompt was addressed by source file and line, never by assembled-prompt offset in the lane the run actually used — **6 rows, 1 outright false GAP**
*Case 23 (the GAP); cases 7, 15, 45, 57 addressed as `L75` / `L203` / `L68`; cases 23, 17-data, 18, 27, 57 confirmed against the stale prompt variant.*

**Assumed:** that `system_prompt.py` is the prompt, that a source line number is an address, and that any cache entry for the encounter shows what the model saw.

**Reality:** three failures of one assumption. (a) The assembled prompt spans `system_prompt.py` **and** `knowledge_base.py`; case 23's "undiagnosed new problem with uncertain prognosis" returns 4 hits, 3 of them in `knowledge_base.py`, fully defined with a V1.18 STRICT READING gate — declared a GAP because one file was grepped. (b) Source line numbers cannot be checked against the bytes the model saw and do not survive the splice. (c) The cache holds two assembled prompts differing in five substantive rules, and the lane whose sig sorts first (`seed=1`) is the *dataset-build* lane, not the reproduction lane — five rows confirmed their governing rule against a prompt the reproduced votes never received. The enabler is a documented join that does not work: `reproduction.md` § 4 says `manifest.json:prompt_sha1` and `run.json:prompt_fp` are "both sha1 of the same prompt text", but I measured them as `3e951ede…` vs `2c93596f…` / `5958c36e…` — they hash different serialisations, so the manual join can never succeed and there was no mechanical way to pick the right sig.

**Check that catches it:** CHECK 4 run as written — `core.prompt_index --find` over the assembled prompt, several phrasings, every searched phrase listed — plus a lane rule (`run_seed S → cache seeds S001/S002/S003`) so "confirm against `request.system` in the same cache file" names a determinate file.

### 3 · Grouped by symptom, then transplanted one member's evidence — **7 rows passed through a symptom group**
*C-3 = "data, over" (18, 27, 68); C-4 = "risk, under" (45, 17-risk); C-1 = "copa, under" (7, 23).*

**Assumed:** that (axis, direction) is a proxy for cause, so one member's investigated mechanism describes the rest.

**Reality:** C-3 was withdrawn in the prior report, but the residue survived — cases 27 and 68 carried the group's `system` shape into the next pass and only now resolve to label-or-standard and upstream-input respectively, i.e. three members, three dispositions. C-4 is the purer instance: case 17's risk axis inherited case 45's NOT-RETRIEVED story *and* case 17's own data-axis upstream-input story, neither of which survives contact with its trace. `diagnosis.md` already states the test — "if two errors share the tag but need different edits, it is not the grouping key" — and it was applied only after the group had already shaped three write-ups.

**Check that catches it:** every member points at its own intermediate, with its own quote, *before* the group exists.

### 4 · Input adequacy asserted in both directions without reading `request.user` — **4 rows**
*Cases 17-data, 17-risk, 18, 68.*

**Assumed, first pass:** that inputs were adequate, so a wrong output means a `system` fault. **Assumed, second pass:** the mirror image — that a plausible story about a missing Epic tab means the signal is absent.

**Reality:** the second assumption is the more damaging because it *looks* like the fix for the first. Case 17's labs are in the payload at offset 12135 and quoted by all three votes; only the enumeration is missing. Case 18's "Orders Placed This Encounter" block is present and lists only medication reorders — and the same block enumerates labs in 5 sibling encounters, so its silence is a usable signal. The distinctions never drawn: *signal absent* vs *enumeration absent*; *field absent* vs *field present and empty*; and which **axis** an absent input actually bites (case 17's missing lab tab constrains data, where GT needs three named tests, and not risk, whose whole claim is one sentence that is present).

**Check that catches it:** CHECK 3 as a two-sided gate — grep `request.user`, record hit or miss *with the offset*, and let a present signal close `upstream-input` as firmly as an absent one closes `system`.

### 5 · No test of whether the rule ever fires, so the reviewer's label was treated as a fact to be explained — **4 rows**
*Cases 7, 27, 67 (all now label-or-standard) and case 23's NOT-FOLLOWED.*

**Assumed:** that a GT/pred mismatch means something in the pipeline must be wrong, and the job is to find it.

**Reality:** three of eleven rows are labels the AMA pathways cannot reproduce. Case 7 fires 0 of 7 enumerated triggers. Case 67 fires 0 of 5 Moderate pathways and the reviewer's own ICD list contains no chronic code. Case 27's GT *agrees* with the tool in the export and requires 0 Cat-1 points against three quoted same-day orders. Without a negative test the analysis had no way to conclude "the model applied the rule and correctly found nothing", so case 7 spent three passes producing a four-way candidate for an error that is not a prompt error at all.

**Check that catches it:** CHECK 6 — enumerate the governing rule's triggers, mark each fired/not-fired against the note, and treat zero-fired as routing to NOT-A-PROMPT-ERROR rather than as a puzzle.

### 6 · Hedged with a slash, a "(weak)", or a "TBD" instead of choosing — **4 rows**
*Case 23 "NOT-FOLLOWED / RULE-WRONG"; case 7 "candidate — 4 live pairs"; case 15 "NOT-FOLLOWED (weak)"; case 68 "locus TBD".*

**Assumed:** that a hedge is the honest output when evidence is thin, and that it can be resolved later.

**Reality:** a hedge is a *stable state* — nothing forces it to resolve, so it survives passes. Case 7's candidate persisted through two cycles because the cross-encounter query `diagnosis.md` prescribes for Q3 was named as "tiebreak in progress" and never run; running it (cases 12/21/70) takes minutes and settles the row. Case 68's "locus TBD" was not thin evidence but a category error — there *is* no prompt locus, because the fact is in no input. Each hedge also hid a different missing check, so the hedge is a symptom of causes 1–5 rather than an independent failure.

**Check that catches it:** one branch per row; if the evidence genuinely does not choose, the row is `candidate` **plus the named artifact that would settle it**, and a candidate may not survive the grouping pass.

### 7 · Ledger not reconciled by count — **1 row lost, 9 collapsed into an aggregate**
*Case 67.*

**Assumed:** that a report organised by cause covers every error, because every error has a cause.

**Reality:** case 67 has no cause, so it appeared in no cause block and vanished; it was recovered only by counting the table (10 rows against 11 analysed errors) — exactly the failure `reproduction.md` § 3a describes. The related soft version: the prior ledger reads "20 = 11 analysed + 9 excluded", which balances arithmetically while the 9 backfill rows were never dispositioned individually — and CHECK 1 shows provenance is **per axis, not per row** (case 17 carries three different provenances in one row), so a block exclusion can hide a reviewer-sourced axis.

**Check that catches it:** assert `rows_in == rows_dispositioned` mechanically, one row per (encounter, axis), with excluded rows enumerated rather than summarised.

### 8 · A prior cycle's finding inherited, then hardened into the method — **2 rows, plus the method itself**
*Cases 17-data and 17-risk.*

**Assumed:** that iter-1's finding for an encounter holds for this pin, and for every axis of that encounter.

**Reality:** the prior report already confessed this once ("I had inherited iter-1's finding … and applied it to the *risk* axis without re-checking"), and the correction went the wrong way — it propagated the inherited claim to a second axis instead of retesting it. The claim then got promoted into the checklist itself as a worked precedent ("case 17's labs are not in the payload at all"), and it is **false**: the labs sentence is at offset 12135 and all three votes quote it. A wrong finding embedded in the method is worse than a wrong finding in a report, because every later case inherits it silently — and it would have justified the wrong fix ("add an orders field so labs appear" when labs already appear).

**Check that catches it:** a carried-forward finding is a **candidate**, re-verified against this pin's artifacts before use — and no precedent enters the method text without a re-verification date.

## How to improve `rca-coding`

Ordered by expected yield. Every item makes a rule that already exists in `diagnosis.md` or `reproduction.md` **mechanical** — none adds a category.

### 1 · Make Q2 an artifact checklist, not a judgement — `references/diagnosis.md` § Mechanism
Replace "Did the model engage with it? (evidenced from the thinking trace)" with a required read of four fields **per vote**: `output.<axis>_rationale`, `output.narrative` (the `Excluded:` line), `output.detail.<axis>[].source_quote`, `output.thinking`. Add the hard rule: **a NOT-RETRIEVED claim must quote the search term and its zero hit count in `thinking`; a rationale-only read is not an answer to Q2.** Note in-line that clinic runs three votes and they disagree — one vote enforcing a rule the other two ignore is itself the finding (case 68).
*Prevents miss 1 — 7 of 11 rows, the single largest driver.*

### 2 · Fix the broken cache join and make lane selection mechanical — `references/reproduction.md` § 4
The ⧗ note currently says `manifest.json:prompt_sha1[<key>]` and `run.json:prompt_fp` "are both sha1 of the same prompt text". They are not — measured on this batch, `3e951ede…` vs `2c93596f…`/`5958c36e…`; they hash different serialisations and the join can never succeed. Replace with the seed-lane rule: **`run_seed S` → cache sigs whose `run.json:seed ∈ {S001, S002, S003}`; seeds 1/2/3 are the dataset-build lane and are *not* what your reproduction saw.** Add the warning that one dataset can hold several materially different assembled prompts (here 84,704 vs 87,274 chars, differing in five substantive rules) and that `prompts_snapshot/<key>_system.txt` is the authoritative text for a run.
*Prevents miss 2c — 5 of 11 rows confirmed against the wrong bytes.*

### 3 · Ban source-line addresses; require an assembled-prompt offset confirmed in the payload — `references/diagnosis.md` § Stage 2 + `references/dag-clinic.md` § Addressing
A locus is `<module>.py:CONSTANT § heading` **plus** the offset from `core.prompt_index --find`, **plus** confirmation that the phrase is in `request.system` of the lane from item 2. Add two cautions to `dag-clinic.md`: the assembled prompt spans `system_prompt.py` *and* `knowledge_base.py` (so a `system_prompt.py` grep is never a GAP proof), and `prompt_index`'s heading parse is itself unreliable — the CRITICAL RISK RULES block prints under `§ Required output for Data line`, so quote the heading from the bytes, not from the tool.
*Prevents miss 2a and 2b — the false GAP on case 23 and the `L75`/`L203` addresses on cases 7, 15, 45, 57.*

### 4 · Add the trigger test as a mandatory step before NOT-FOLLOWED, GAP or any `system` call — `references/diagnosis.md` § Mechanism (new step between Q2 and Q3)
"If the governing rule enumerates triggers, list each one and mark it fired / not-fired against the note text, quoting the note span or recording a zero token count. **If none fire, the model did not fail to follow the rule — it applied the rule and found nothing.** You are at NOT-A-PROMPT-ERROR; fall back to the input, the deterministic code, or the label." This is the missing negative test that lets an RCA conclude the reviewer is wrong.
*Prevents miss 5 — cases 7, 27, 67 and case 23's NOT-FOLLOWED.*

### 5 · Put GT provenance ahead of everything, per axis — `references/diagnosis.md` § Disposition
New first gate: read `gt_level_source` **for the axis under analysis** (`copa=…;data=…;risk=…`). `backfill-from-tool` ⇒ the "error" is drift from the tool's own export, not human disagreement — disposition it as such and stop. Add the second half that was skipped three times: **compare `gt_<axis>_level` against `system_<axis>_level` in the export and check `errors.json:axis_status`; if they agree and the row reads `correct-asserted`, the reviewer affirmed the tool and there was never a disagreement** (case 27). State that provenance is per axis, not per row — case 17 carries three different provenances in one row.
*Prevents miss 5 and miss 7's soft version; would have closed case 27 in one step instead of three passes.*

### 6 · Make input presence a two-sided gate with recorded offsets — `references/diagnosis.md` § Disposition
Amend the existing input-presence advice to: "Before **either** a `system` or an `upstream-input` call, grep `request.user` for the discriminating signal and record hit-or-miss **with the offset**. Present ⇒ `upstream-input` is closed. Absent ⇒ `upstream-input`, and name the axis it bites — an input gap constrains the axis whose threshold needs the missing detail, not every axis of the encounter." Add the three distinctions this batch turned on: signal absent vs *enumeration* absent (case 17); field absent vs field **present and empty** (case 18 — a structured block that exists and is silent is evidence); and a cross-encounter check that the field ever carries the signal at all (case 68 — 0 of 760 payloads).
*Prevents miss 4 — 4 rows, and both directions of it.*

### 7 · No slashes, no "(weak)", no "TBD" — `SKILL.md` § Hard stops and `references/reporting.md`
Add: "A mechanism cell contains exactly one branch. `candidate` is permitted **only** with the named live options *and* the single artifact that would settle it. **A candidate may not survive the grouping pass** — Q3's cross-encounter query is mandatory there, not optional, and the report states the query and its result." Make the cross-encounter query concrete for clinic: other encounters whose reviewer basis hits the same rule, and whether the rule was applied consistently (→ RULE-WRONG or NOT-FOLLOWED) or inconsistently (→ UNDER-SPECIFIED).
*Prevents miss 6 — 4 rows, including the case-7 candidate that survived two cycles because "tiebreak in progress" was never run.*

### 8 · Turn the ledger into an assertion — `references/reproduction.md` § 3a
Require the disposition to be written back per (encounter, axis) into `errors.json` (or a sidecar) and `rows_in == rows_dispositioned` asserted by a script whose output is pasted into the report. **Excluded blocks get one row each, not one aggregate line** — "9 backfill rows excluded" balances arithmetically while hiding that provenance is per axis. A `validate_rca.py`-style script already exists in the experiment dir; promote that pattern into `scripts/`.
*Prevents miss 7 — case 67, recovered only by hand-counting the table.*

### 9 · A carried-forward finding is a candidate, and precedents in the method carry a verification date — `SKILL.md` § Hard stops
Strengthen the existing bullet: "Any claim quoted from a previous cycle is a **candidate** until re-verified against this pin's artifacts, and it is re-verified **per axis**. A precedent may not be embedded in checklist text without the date and artifact it was last verified against." Then act on it here: the standing precedent "case 17's labs are not in the payload at all" is **false** — the labs sentence is at `request.user` offset 12135 and all three votes quote it — and should be corrected wherever it is cited, because as written it justifies the wrong fix.
*Prevents miss 8 — 2 rows plus contamination of the method itself.*

### 10 · Build the group member-first — `references/diagnosis.md` § Grouping
Add a precondition to the existing rule: "A group exists only once **each** member independently points at its own intermediate with its own quote. Membership by (axis, direction) is forbidden; the key is (locus offset, mechanism)." Enforce it through `causes.json` by requiring a per-member evidence line — a member with no quote of its own cannot be listed in `targets`.
*Prevents miss 3 — C-3 and C-4, 7 rows touched.*

### 11 · Document the clinic aggregator as a localization hazard — `references/dag-clinic.md` § Design intent
Verified in `clinical_coding_v1_activities.py`: `clinic-ensemble-aggregate` picks `winner = next(r for r in results if r['amb_code'] == winning_code)` — the **first** vote carrying the majority E/M code — then lifts *every* axis (`copa_level`, `data_level`, `risk_level`, `mdm_level`) off that single vote. **There is no per-axis vote**, so a 2-1 axis majority can be discarded by a vote that won on the code. Case 17-risk shows the effect: 5 of 9 votes across three seeds carried the GT answer while the pipeline printed the wrong one every time. Any per-axis finding on clinic must state whether the axis majority and the emitted value agree.
*Prevents a whole class of mis-localization: an axis error attributed to the prompt when the vote distribution already contained the right answer.*

### 12 · Formalise evidence provenance as an orthogonal field — `references/diagnosis.md` § Attribution strength
The prior report invented `reviewer-asserted` ad hoc because cited / narrowed / ablated all describe evidence about the **model**. Make it a named second dimension: **verifiable** (the signal is in our data) | **reviewer-asserted** (a claim about chart content we never received) | **none**. On this batch it is 9 / 2 / 0, and the two reviewer-asserted rows (17-data, 68) are exactly the two whose disposition flips if the reviewer is mistaken — the fact a reader most needs, and one the current tiers cannot express.
*Prevents a `cited` finding reading like an `ablated` one, and makes the adjudication queue self-identifying.*

## Open

1. **Carry the ordered tests individually into the extract** (case 17) and **add order
   provenance — who ordered each reviewed lab, and when** (case 68: 0 hits in 760 payloads,
   no column in the 48-column schema). These are the only two true input gaps.
2. **`RISK-MEDS-OVER guard`** is referenced twice in the prompt (@21563, @22385) and
   **never defined** anywhere in 87,274 chars. Dangling cross-reference.
3. **Case 57's CONFLICT is a candidate** — the boundary is exercised exactly once in 63
   encounters. Needs more instances before it is a finding.
4. Identify the 2026-07-22 prod revision to anchor the batch.
5. Adjudicate cases 7, 27, 67 with a second coder — all three now read
   `label-or-standard`, which is a claim about the reviewer and deserves a second opinion.

## Related

[[taxonomy]] · [[Coding Pod]] · [[Evaluation - Tuning Process]] · [[Prompt Tuning Runbook]]
