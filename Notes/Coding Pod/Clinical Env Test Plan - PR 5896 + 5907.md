---
updated: 2026-09-03
tags: [plan, coding-pod, clinical-env]
---
# Clinical Env Test Plan — PR #5896 + #5907

Follows [[Clinical Environment Test Runbook]]. Encounter rationale and the enable-abstention
appendix live in [[Clinical Env Test Plan - PR 5896 clinic V1.3]].

| PR | branch | Jira | what it changes |
| --- | --- | --- | --- |
| **#5896** | `feat/clinic-v13-h2h3inj-cv-consensus` | QHE-3555 | clinic V1.3 — H2+H3inj prompt, element/TIME-card voting, `consensus_or_corroborated` abstention |
| **#5907** | `feat/clinic-coding-llm-raw` | QHE-3012 | capture per-encounter LLM output / thinking / token usage in `result_json.llm_raw` |

## Decision: test them SEQUENTIALLY, 5896 first

Not on a combined branch. Three reasons, in order of weight:

1. **They conflict.** A trial merge produces **one 138-line conflict hunk** in
   `clinical_coding_v1_activities.py` — both PRs add code to the same region (5896 the voting
   helpers, 5907 the LLM-raw capture). Resolvable, but the resolution is code that exists in
   neither PR: a pass would not validate either PR as it will actually merge, and a failure
   could be the resolution's fault. 4 files overlap in total.
2. **#5907 needs a DB template re-seed; #5896 does not.** Keeping them separate keeps that
   change isolated to the round that needs it.
3. **Attribution.** `clinical` is timeshared — one bad round with two PRs on the pointer
   costs a second full cycle to work out which one did it.

Order matters: **5896 first**, because it needs no DB change. See the template-rollback
warning under Round 2.

## Shared test data — already generated

Same two encounters for both PRs, from `clinic-feedback-177-dos-match-20260730`. Files are in
`coding-ai-harness/clinic/experiments/pr5896-cctest/` (gitignored — they carry note text).

| encounter | GT `em` | V1.2 (stock) | V1.3 | exercises |
| --- | --- | --- | --- | --- |
| `962495324` | `99214` | 40% correct (2/5 draws) | **100%** (6/6) | the **prompt** hunks |
| `973014662` | `99215` | 40% correct (2/5 draws) | **83%** (5/6) | the **aggregator** (TIME-card vote) |

```
pr5896-cctest-1.csv .. -3.csv     ids  <enc>-pr5896-1 .. -3
pr5907-cctest-1.csv .. -3.csv     ids  <enc>-pr5907-1 .. -3
```
12 unique ids, verified no collisions — every round dodges the file-processor dedup. Both
rows are `is_new_patient=Established`, 49 columns, `consolidated_notes_json` populated.
(`PR5896-cc5896-base-*` / `-v13-*` also exist if a `develop` baseline round is wanted.)

⚠️ **The clinical input is not identical to the offline input.** `rcm-format-notes` reads the
note from `input_gcs_uri` → `consolidated_notes_json`; the harness fed the model
`full_clinic_assistant_context_blob` — ~30% more text (9,615 vs 6,769 chars on `962495324`).
So this is the same encounters through a **different note rendering**. If `962495324` does
not come back 3/3, that is not automatically a code defect. Conversely a clean 3/3 is
*stronger* evidence than the offline run, because it holds under the production input too.

⚠️ **Data-sensitivity gut-check** before uploading: client-feedback data into the `qhai-com`
tenant. Non-prod, but it is a judgement call, not a formality.

## Prerequisites — all verified 2026-09-03

| gate | status |
| --- | --- |
| verifier secrets in clinical | ✅ all 5 present — 3 Azure keys in configMap `env-config-ch88kc7f6k`, `AZURE_GPT_54_OPENAI_API_KEY` + `GOOGLE_GEMINI_API_KEY` in secret `qh-platform-secrets`, both mounted `envFrom` on `temporal-workers-high`/`-low` |
| VPN / cluster reach | ✅ needs VPN — `masterAuthorizedNetworks` is enabled; both endpoints time out without it |
| CSV schema | ✅ no gaps vs the dispatch allow-list (the 7 "missing" fields are runtime plumbing, and `mrn` is aliased by `pat_mrn_id`) |
| pointer branch | ✅ `deploy/clinical/cc_test` exists |
| CI | ✅ #5896 14/14 |

⚠️ `VERTEX_PROJECT` is absent in-cluster, but it is only the **fallback** Gemini path and
`GOOGLE_GEMINI_API_KEY` is present, so it is never read. Do not "fix" it — the cluster's
`GOOGLE_VERTEX_PROJECT` belongs to qh-presidio, not the coding verifiers.

## Round 0 — announce

`#clinical-env-timeshare`, before touching the pointer:
```
testing on clinical
- branch: deploy/clinical/cc_test  (PR #5896 then #5907, clinic coding)
- pods: temporal worker
```
Record the current tip as the rollback SHA:
```bash
git fetch origin && git rev-parse origin/deploy/clinical/cc_test   # SAVE
```

## Round 1 — PR #5896 (no DB change)

```bash
git branch -f deploy/clinical/cc_test origin/feat/clinic-v13-h2h3inj-cv-consensus
git push origin deploy/clinical/cc_test --force-with-lease
gh workflow run "Deploy Temporal Worker" --ref deploy/clinical/cc_test
gh run watch <run-id> --exit-status
kubectl -n qh rollout status deploy/temporal-workers-high
kubectl -n qh rollout status deploy/temporal-workers-low
```
`Deploy Temporal Worker` only — the diff is `packages/rcm/clinical_coding/**` +
`temporal-workers/**`, both in that workflow's `on.push.paths`, and nothing else matches.
Confirm the image tag embeds the Actions run id before feeding.

Feed `pr5896-cctest-1.csv`, then `-2`, then `-3` (one at a time; ~3–4 min drop→dispatch lag).

**Pass conditions**

| encounter | expected | pass |
| --- | --- | --- |
| `962495324` | `99214` with `copa_level=moderate` | **3/3** |
| `973014662` | `99215` with `time_level` populated | **≥2/3** |

Abstention will read `SKIPPED` — that is correct and expected. The composer config still has
`abstention_enabled=false` and the DB value overrides the code default. To exercise the gate,
follow the appendix in the 5896 plan; treat it as a separate round, not part of this one.

## Round 2 — PR #5907

```bash
git branch -f deploy/clinical/cc_test origin/feat/clinic-coding-llm-raw
git push origin deploy/clinical/cc_test --force-with-lease
gh workflow run "Deploy Temporal Worker" --ref deploy/clinical/cc_test
```
Same single deploy action; same roll verification.

### DB: re-seed the DAG template — required for the full feature

The DAG is fetched from the DB (`_fetch_active_dag_nodes` by `workflow_code`), **not** from
`template_v1.json`. #5907 adds a `clinic-verifier-scoring → transform` edge and a
`verifier_raw` arg key to the terminal node, so without a re-seed that half is inert.

Per #5907's own description it degrades gracefully: *"an unseeded template leaves
verifier_raw as None and the extract records still populate."* So there are two valid tests:

- **2a (no DB change)** — verify `result_json.llm_raw` carries the **extract** records
  (output / thinking / token usage), with `verifier_raw` absent or null.
- **2b (with re-seed)** — run the v1 seed so the template carries the new edge, then verify
  the **verifier's** raw record also lands.

⚠️ **Re-seed only while #5907's code is deployed, and restore the template before rolling the
pointer back.** The terminal node's `arg_keys` resolve positionally, so a template carrying
`verifier_raw` against code that does not accept it risks an unexpected-argument failure on
`transform-clinical-coding-v1`. The seed is idempotent (it no-ops when the DAG matches), so
restoring = re-running it with the pre-#5907 `template_v1.json`.

Feed `pr5907-cctest-1.csv` .. `-3.csv`.

**Pass conditions**
```sql
SELECT external_id,
       result_json -> 'llm_raw' IS NOT NULL           AS has_llm_raw,
       jsonb_array_length(result_json #> '{llm_raw,extract}') AS n_extract_records,
       result_json #> '{llm_raw,verifier}'            AS verifier_raw
  FROM workflows.workflow_run
 WHERE external_id LIKE '%-pr5907-%' ORDER BY external_id;
```
- `llm_raw` present on all 6 runs
- **3** extract records per encounter (one per ensemble vote), each with non-empty output and
  non-zero token counts
- `verifier_raw` null in 2a; populated in 2b
- ⚠️ the E/M codes should match Round 1's, since #5907 is observability only. **A code change
  between rounds means #5907 is not side-effect-free** — that is the regression this round is
  really for.

## Verify (both rounds)

UI: [clinical-chat.qualifiedhealthai.com](https://clinical-chat.qualifiedhealthai.com/).
Field-level:
```sql
SELECT external_id,
       (result_json IS NOT NULL) AS done,
       result_json -> 'ai_professional_code' AS em_code,
       result_json -> 'copa_level'  AS copa,
       result_json -> 'time_level'  AS time_level,
       result_json -> 'abstention'  AS abstention
  FROM workflows.workflow_run
 WHERE external_id LIKE '%-pr589%' OR external_id LIKE '%-pr5907-%'
 ORDER BY external_id;
```
Use `result_json IS NOT NULL` for done-ness; `inputs.state=SUCCESS` only means *dispatched*.

## Cleanup

1. Restore the DAG template if Round 2b re-seeded it.
2. Restore `temporal_config` if the abstention round changed it.
3. `git branch -f deploy/clinical/cc_test <rollback-SHA> && git push --force-with-lease`
4. Post to `#clinical-env-timeshare` that the pointer is free.

## Gotchas carried from the runbook + this session

- Every new commit on either PR = full re-point → re-dispatch → re-verify-roll.
- A green deploy Action ≠ rolled pods. Always `kubectl rollout status`.
- **kubectl context drifts to `qh-staging`** — check `kubectl config current-context` contains
  `qh-clinical` before believing any cluster output. Default gcloud project here is
  `qh-development`, so always pass `--project qh-clinical`.
- Fresh id suffix per round or the feed silently no-ops.
- `wc -l` undercounts these CSVs — note fields contain embedded newlines.
- Drop bucket is `.../composer-data-files/clinical_coding/`, **not**
  `...-composer-clinical-coding-datafiles` (that holds output artifacts).
- If an abstention round shows high `NEEDS_REVIEW`, check `gpt_error`/`gemini_error` first —
  a failed verifier is indistinguishable from a policy abstention in the coverage number.

## Log

_(append per round: PR, suffix, pointer SHA, Actions run id, image tag, result per encounter)_
