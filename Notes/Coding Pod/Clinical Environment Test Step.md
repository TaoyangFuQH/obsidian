---
tags: [runbook, coding-pod]
---
# Test a PR on the `clinical` Environment

Reference: [How to Test a PR on the Clinical Environment](https://app.notion.com/p/3a61358f13e181f8b956c75ca9c6b2c9)

`clinical` is a **non-production** QH environment (GCP project `qh-clinical`, tenant
`qhai-com`) that runs the real production-shaped pipeline. Safe to read/write — use it to
validate a PR against a realistic path **before or without** merging to `develop`/`release`.
Unlike `release` → `staging` (push-triggered, see [[Cherry-pick Steps]]), `clinical` deploys
off a **pointer branch** (`deploy/clinical/<name>`) that you move manually and dispatch by
hand — no PR or merge required.

**`clinical` is a shared, timeshared resource** — coordinate with the team before/while
using it (see Step 1 below), since your deploy pointer and test data can collide with
someone else's in-flight test.

## When to use

You have a PR in flight (approved or not) and want to validate it end-to-end — real
pipeline, real dispatch/Temporal/DB — before it's anywhere near `develop`/`release`.

Environment coordinates: Temporal namespace `qh-platform-clinical.qyfc8` · MVP DB
`qh_mvp_db` (schema `workflows`) · worker cluster `qh-clinical-platform` (ns `qh`,
deployments `temporal-workers-high`/`-low`).

---

## Part 1 — Deploy the PR to clinical

1. **Announce the test in Slack — `#clinical-env-timeshare`.** Post before you start
   deploying, so nobody else's in-flight test collides with yours:
   ```
   testing on clinical
   - branch: deploy/clinical/<pointer>
   - pods: temporal worker
   ```

2. **Move the pointer branch to your PR branch.** Record the current tip first (rollback
   point), then force-move it — this is git-only, no UI equivalent:
   ```bash
   git fetch origin
   git rev-parse origin/deploy/clinical/<pointer>        # save — rollback SHA
   git branch -f deploy/clinical/<pointer> origin/<pr-branch>
   git push origin deploy/clinical/<pointer> --force-with-lease
   ```

3. **Dispatch ONLY the deploy Action(s) your diff touches** — match changed paths against
   each workflow's `on.push.paths` (e.g. anything under `packages/rcm/clinical_coding/**`
   → `Deploy Temporal Worker` only). Don't blanket-deploy.
   ```bash
   gh workflow run "<exact deploy workflow name>" --ref deploy/clinical/<pointer>
   gh run list --workflow "<exact deploy workflow name>" --branch deploy/clinical/<pointer> --limit 3
   gh run watch <run-id> --exit-status
   ```

4. **Confirm the roll actually landed** — a green Action only means the image built and the
   GitOps repo(s) (`qh-platform` + `qh-customer`) got the tag bump, **not** that pods rolled.
   New pods can sit `Pending`/`ContainerCreating` 1–3 min while the autoscaler adds a node.
   ```bash
   gcloud container clusters get-credentials qh-clinical-platform \
     --region us-central1 --project qh-clinical --internal-ip
   kubectl -n qh get deploy temporal-workers-high temporal-workers-low \
     -o jsonpath='{range .items[*]}{.metadata.name}{" -> "}{.spec.template.spec.containers[0].image}{"\n"}{end}'
   kubectl -n qh rollout status deploy/temporal-workers-high
   kubectl -n qh rollout status deploy/temporal-workers-low
   ```
   Confirm the image tag embeds your Actions run id, and both report "successfully rolled
   out" before feeding any test data.

**Every new code push to the PR branch = repeat steps 2–4** (re-point → re-dispatch →
re-verify roll) before re-testing.

---

## Part 2 — DB / config (skip if pure code)

Only needed if the PR requires a DAG/config change. Config lives in `workflows.composer_metadata.temporal_config` (JSONB), read **at dispatch** — set it **before** feeding, and resolve the composer row by `id` first (a wrong `org_id`/`workflow_code` in a `WHERE` is a silent no-op). See the Notion runbook for the exact SQL if this applies.

---

## Part 3 — Prepare & feed test CSV(s)

### 1) Build the CSV

Reuse **real** source data — don't fabricate note content. Encounter-id column is
`pat_enc_csn_id` (workflow-specific in general — confirm from the dispatch code).

**Dedup rule:** the file-processor dedups on the encounter-id column. Re-dropping an
already-ingested id is silently skipped — **every test round needs a fresh suffix**.

**Gotchas hit doing this:**
- **Don't trust `wc -l` for row count** — multi-line note fields (`consolidated_notes` etc.)
  contain embedded newlines. Always parse with `csv.DictReader`, never naive line-splitting.
- **Check for duplicate ids within the source file itself** before suffixing — drop them,
  don't silently double-feed the same encounter under two ids.
- **Column-schema drift across sources:** an offline eval/benchmark CSV (e.g. from an eval
  harness) may carry a stripped-down column set vs. the real locked production schema
  (`_ALLOWED_FIELDS` in the workflow's `dispatch.py`). Align/blank-fill the extra columns
  before feeding — don't feed a narrower schema as-is.
- **Check `is_new_patient` distribution in your sample** — an all-`New` (or all-`Established`)
  set only exercises one branch of any New-vs-Established logic.
- **Real prod-sourced benchmark data crossing tenants** (e.g. pulled from another
  customer's prod Databricks table) is a data-sensitivity gut-check before uploading into a
  different tenant/environment — even though `clinical` itself is non-prod.

Suffix script pattern (only column 0 changes):
```python
import csv

def resuffix(src, dst, new_suffix):
    with open(src, newline='', encoding='utf-8') as f:
        rows = list(csv.reader(f))
    header, body = rows[0], rows[1:]
    out = [header]
    for row in body:
        base_id = row[0].split('-', 1)[0]     # strip any prior suffix
        row[0] = f'{base_id}{new_suffix}'
        out.append(row)
    with open(dst, 'w', newline='', encoding='utf-8') as f:
        csv.writer(f).writerows(out)
```

### 2) Upload to the clinical drop bucket

Drop bucket convention: `gs://qhai-com-clinical-composer-data-files/<workflow_dir>/` (e.g.
`clinical_coding/`).

⚠️ **Don't confuse with** `gs://qhai-com-clinical-composer-<workflow>-datafiles` (e.g.
`qhai-com-clinical-composer-clinical-coding-datafiles`) — that one holds per-encounter
offloaded artifacts (`ha_number_*/general.json`, `abstractors/`), **not** the CSV drop zone.
Confirm which one is live by listing it — the real drop folder will show recent CSVs from
other engineers' test rounds.

```bash
gcloud storage cp <file>.csv gs://qhai-com-clinical-composer-data-files/<workflow_dir>/ --project=qh-clinical
gcloud storage ls -l gs://.../<workflow_dir>/<file>.csv --project=qh-clinical   # confirm landed
```

### 3) Watch the dispatch (3-CF chain: ingest → schedule → start)

All 3 are gen2 Cloud Run services (`resource.type="cloud_run_revision"`). Expect **~3–4 min**
drop → dispatch lag — the first several minutes legitimately show nothing in Temporal, don't
re-feed. A `Duplicate message` log means the suffix didn't dodge the dedup.
```bash
gcloud logging read 'resource.type="cloud_run_revision" resource.labels.service_name="<cf-service>"' \
  --project=qh-clinical --freshness=10m --limit=60 --order=desc
```

### 4) Watch Temporal to completion

Temporal Cloud UI, namespace `qh-platform-clinical.qyfc8` → filter Workflows by your suffix
tag, wait for all to reach `Completed`.
```bash
temporal workflow list --env clinical --query 'WorkflowType="rcm-workflow"' | grep "<tag>"
```

### 5) Verify the result

Check the rendered result directly at
**[clinical-chat.qualifiedhealthai.com](https://clinical-chat.qualifiedhealthai.com/)** —
pull up the encounters by tag and eyeball the output (e.g. MDM level / E&M code cards)
against expectations.

For a precise field-level check instead of/in addition to the UI, query
`workflows.workflow_run` directly — no `state` column; non-null `result_json` means a real
finished result (`inputs.state=SUCCESS` only means *dispatched*, not finished):
```sql
SELECT external_id, (result_json IS NOT NULL) AS done, run_end_time,
       result_json -> '<field>' AS field
FROM workflows.workflow_run WHERE external_id LIKE '%-<tag>' ORDER BY external_id;
```

### Cleanup

Restore any Phase-2 config to baseline, and restore the pointer branch to its recorded
rollback SHA if you're done testing. Consider a follow-up note in
`#clinical-env-timeshare` once you're done, so the next person knows the pointer is free.

---

## Worked example — QEU-342

| Step | Value |
|---|---|
| PR branch | `qeu_342` — "Fix MDM level and time-based code derivation in clinical coding v1" |
| Pointer branch | `deploy/clinical/cc_test` |
| Round 1 deploy | pointer `ebb03fb8b8` (new branch) — run `30047875104`, image `30047875104-3514-1` |
| Round 2 deploy (new commit `cecda6adc6`) | pointer moved `ebb03fb8b8` → `cecda6adc6` — run `30058455170`, image `30058455170-3522-1` |
| Deploy Action | `Deploy Temporal Worker` (diff only touched `packages/rcm/clinical_coding/**`) |
| Drop bucket | `gs://qhai-com-clinical-composer-data-files/clinical_coding/` |
| Test round 1 | `QEU-342-inputs-cctest-20260723.csv` — 2 RCA repro encounters (dupe dropped from source 3-row extract): `959527231` (Alan Thompson, MRN `E1301961048`), `963676781` (Julia Steuber, MRN `E130515570`) — both `is_new_patient=New`, suffix `-cctest-20260723` |
| Test round 2 | `QEU-342-inputs-cctest-20260723-2.csv` — same 2 encounters, fresh suffix `-cctest-20260723-2` (re-test after round-2 deploy) |
| Test round 3 (broader regression) | `v1_benchmark-cctest-20260723.csv` — 5 encounters hand-picked from the `coding-ai-harness` `v1_benchmark` eval dataset (real Mercy-prod-pulled benchmark w/ auditor GT), covering New @ 15/30/45 documented min + Established @ 10/40 documented min; columns blank-filled from the harness's 32-col eval schema up to the locked 47-col production schema; suffix `-benchtest-20260723` |

---

## Gotchas (all parts)

- `clinical` is timeshared — always post to `#clinical-env-timeshare` before moving the
  pointer branch, to avoid colliding with someone else's test.
- Pointer-branch moves are **git-only** — no UI equivalent; always record the current tip
  before force-moving it, for rollback.
- Every new commit on the PR branch requires a full re-point → re-dispatch → re-verify-roll
  cycle before re-testing — the pointer doesn't auto-follow the PR branch.
- A green deploy Action ≠ rolled out — always confirm via `kubectl rollout status` before
  feeding data.
- Two similarly-named buckets per workflow — `...-composer-data-files/<workflow>/` (CSV drop
  zone) vs `...-composer-<workflow>-datafiles` (per-encounter output artifacts). Confirm by
  listing contents, don't assume from the name.
- `wc -l` undercounts CSV rows when note fields have embedded newlines — always parse with
  a real CSV library.
- Always give each test round a **fresh id-column suffix** — re-feeding the same id silently
  no-ops (dedup), which looks like nothing happened rather than an error.
- Check patient-status (`is_new_patient`) distribution in any hand-built sample so both
  branches of New/Established-specific logic actually get exercised.
