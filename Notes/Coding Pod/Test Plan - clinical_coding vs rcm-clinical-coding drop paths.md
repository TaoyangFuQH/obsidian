---
created: 2026-09-15
tags: [coding-pod, clinic-coding, clinical-env, test-plan]
---

# Test plan — do the two clinical drop paths produce the same result?

Compare the legacy and new composer drop folders in the clinical env:

```
gs://qhai-com-clinical-composer-data-files/clinical_coding/        # legacy — 47 CSVs, last 2026-09-12
gs://qhai-com-clinical-composer-data-files/rcm-clinical-coding/    # new    — 20 CSVs, last 2026-09-15
```

Both are in active use. Someone already probed this on 2026-09-07: `cc-old-path-test.csv`
and `cc-new-path-test.csv` were uploaded **2 seconds apart** — worth finding out what that
concluded before re-running it.

## The design problem, stated first

**"Same result" cannot mean byte-identical.** The clinic pipeline runs 3 extract votes at
`temperature: 1` with sampled thinking, so the *same encounter on the same path twice*
already differs — in the staging captures the three votes produced 3,554 / 3,329 / 3,001
output tokens for one encounter, and vote-level `amb_code` can differ even when the final
billed code agrees.

So a naive "drop into both paths, diff the output" test cannot distinguish **a real path
difference** from **ordinary sampling noise**. Any difference it finds is uninterpretable.

**Therefore: run replicates on each path and use within-path variation as the noise floor.**

| | |
|---|---|
| between-path difference ≈ within-path difference | paths are equivalent |
| between-path difference ≫ within-path difference | the paths genuinely differ |

## Step 0 — resolve what the two paths actually route to (do this first)

This determines what the test can prove, and may make it unnecessary.

The file-processor resolves a composer by `workflow_folder`
(`GET /composer_metadata/search?workflow_folder=<folder>`), so:

```sql
SELECT id, workflow_code, workflow_folder, org_id,
       temporal_config->>'abstention_enabled' AS abst,
       temporal_config->>'abstention_policy'  AS policy,
       temporal_config->>'llm_model'          AS model,
       COALESCE(is_deleted,false) AS deleted, updated_at
  FROM workflows.composer_metadata
 WHERE workflow_folder IN ('clinical_coding','rcm-clinical-coding');
```

And the DAG behind each:

```sql
SELECT c.workflow_folder, t.id AS template_id, t.name,
       t.version_major||'.'||t.version_minor AS ver,
       jsonb_array_length(t.dag_nodes) AS nodes, m.status
  FROM workflows.composer_metadata c
  JOIN workflows.dag_template_mappings m ON m.composer_metadata_id = c.id
  JOIN workflows.dag_templates        t ON t.id = m.dag_template_id
 WHERE c.workflow_folder IN ('clinical_coding','rcm-clinical-coding')
   AND m.status='active';
```

Three possible outcomes, each changing the test:

- **One composer, both folders** → the paths are aliases. Config and DAG are provably
  identical, so there is nothing to compare statistically. Downgrade to a **plumbing
  check**: one encounter per path, confirm both ingest and complete. Stop there.
- **Two composers, identical `temporal_config` + same active template** → behaviour should
  match; run the full design below to confirm empirically.
- **Two composers that differ** (abstention flag, policy, model, DAG version) → you have
  your answer without running anything, and the diff *is* the finding. Record it and stop.

DB access: customer cluster `qh-clinical-customer-qhai` (**VPN required** — the API server
is a private IP), `kubectl -n qh port-forward svc/mvp-cloudsqlproxy`, creds from the
`mvp-db` secret, `psql -w`.

## Step 1 — encounters

Use **`962495324`** and **`973014662`** from the 177 set. Reasons:

- both have auditor GT on the em axis — **99214** and **99215**
- both already have **verified reference results** from the staging run on 2026-09-04
  (`962495324` → 99214 `AUTO_ACCEPTED`, qh/gpt/gemini = 99214/99213/99214; `973014662` → 99215
  `AUTO_ACCEPTED`), so each path can be checked against a known-good answer, not just
  against each other
- one is a `both-models-confirm` accept and the other exercises the MDM/time path where the
  extract `amb_code` (99214) differs from the final billed code (99215) — so the comparison
  covers more than one code route

Source CSV: `clinic/experiments/pr5896-cctest/pr5896-cctest-1.csv` (2 rows, 49 cols, real
note content). Re-suffix per drop with the runbook's `resuffix()` pattern, asserting only
column 0 changes.

## Step 2 — the matrix

**2 encounters × 2 paths × 2 replicates = 8 workflows.** One CSV per cell, unique suffix:

| file | drop into | suffix |
|---|---|---|
| `pathcmp-old-r1.csv` | `clinical_coding/` | `-old-r1` |
| `pathcmp-old-r2.csv` | `clinical_coding/` | `-old-r2` |
| `pathcmp-new-r1.csv` | `rcm-clinical-coding/` | `-new-r1` |
| `pathcmp-new-r2.csv` | `rcm-clinical-coding/` | `-new-r2` |

The replicates are the whole point — without them there is no noise floor.

**Drop all four within a few minutes of each other.** Same code, same model endpoints, same
time window; it keeps conditions matched and avoids a deploy landing mid-test. Record the
worker image tag **before and after** (a `release` push auto-deploys clinical and would
invalidate the comparison):

```bash
kubectl --context gke_qh-clinical_us-central1_qh-clinical-platform -n qh \
  get deploy temporal-workers-high -o jsonpath='{.spec.template.spec.containers[0].image}'
```

## Step 3 — compare

Pull per encounter-run, non-PHI fields only:

```sql
SELECT external_id,
       result_json->>'ai_professional_code'       AS em,
       result_json->>'copa_level', result_json->>'data_level',
       result_json->>'risk_level', result_json->>'mdm_level',
       result_json->'abstention'->>'policy'       AS policy,
       result_json->'abstention'->>'verdict'      AS verdict,
       result_json->'abstention'->>'confidence'   AS confidence,
       result_json->'abstention'->'em_votes'      AS em_votes,
       (result_json ? 'llm_raw')                  AS llm_raw
  FROM workflows.workflow_run
 WHERE external_id LIKE '%-old-r_' OR external_id LIKE '%-new-r_'
 ORDER BY external_id;
```

⚠️ Match **exact ids**, or exclude `rt-%` — a retry job re-runs dropped encounters under an
`rt-` prefix, and a `LIKE '%-<tag>'` filter silently matches those too (it produced a false
positive in the staging round).

### Verdict rule

| field | expectation |
|---|---|
| `em` | **must match across all 4 runs** and equal GT (99214 / 99215). A single mismatch on one path only is the headline finding. |
| `policy`, `verdict`, `confidence` | must match; a difference here means different config, not sampling |
| `llm_raw` present | must match; differs only if the DAG templates differ |
| copa/data/risk/mdm | compare between-path vs within-path. Differences *within* a path are the noise floor. |
| `em_votes` | per-vote disagreement is expected sampling noise — do not read into it |

**Conclusion is only "paths differ" if a between-path difference exceeds what the
within-path replicates show.** Otherwise: equivalent.

## Known hazard on this env

Clinical has a **cross-tenant task-routing defect** — activities are dispatched across all
tenant clusters on a shared queue, and workers outside `qhai-com` can't resolve its private
proxy. Measured 2026-09-03: p(good draw) **15.8%**, and DAG nodes get **no re-dispatch**, so
11 of 12 encounters failed. Staging ran the identical encounters cleanly.

**Check whether this is fixed before running.** If it is not, expect most of the 8 to die at
`rcm-submit-dag` or the input node with `[Errno -2] Name or service not known`, and the test
is not runnable as designed. A failure of that kind says nothing about the drop paths.

## Status / log

- **2026-09-15** — plan written. Step 0 not yet run (VPN was off). Nothing fed.
