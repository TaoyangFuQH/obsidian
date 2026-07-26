# Cherry-pick a PR to `release` + Verify on Staging

Reference: [Release Process - Automated Deployments and Git Branching](https://app.notion.com/p/3661358f13e1817e8a14fa640be09d02) —
*"Regressions or fixes found during UAT are addressed on develop first, then cherry-picked onto release with code owner approval."*

`release` is a long-lived branch in practice (not always freshly cut), and gets fixes
landed onto it via cherry-pick PRs, not direct pushes — same review bar as any other PR.
Merging into `release` auto-triggers the staging deploy (push-based path filters — no
manual dispatch needed, unlike the `qh-clinical` pointer-branch flow).

## When to use

Your PR is approved and merged (or about to be merged) to `develop`, and you need the
fix validated on `staging` before it's included in the next full release cut / production
deploy.

---

## Part 1 — Cherry-pick to `release`

1. **Merge the original PR into `develop` first.** Don't cherry-pick the raw feature-branch
   commits — GitHub squash-merges into a single commit, and that's the SHA you want.

2. **Grab the squash-commit SHA from `develop`:**
   ```bash
   git fetch origin
   git log origin/develop -1 --format='%H %s'   # confirm it's the right commit
   ```

3. **Branch off `release` and cherry-pick it.** Naming convention used elsewhere in the
   repo: `cherry-pick/pr<PR#>-release`.
   ```bash
   git checkout -b cherry-pick/pr<PR#>-release origin/release
   git cherry-pick <squash-sha-from-develop>
   # resolve conflicts if any, then: git cherry-pick --continue
   git push -u origin cherry-pick/pr<PR#>-release
   ```

4. **Open a PR from that branch into `release` — not a direct push.** Requires code-owner
   approval on the cherry-pick itself, same as any PR.
   ```bash
   gh pr create --base release --head cherry-pick/pr<PR#>-release \
     --title "<TICKET>: <description> (cherry-pick to release)" \
     --body "Cherry-pick of #<PR#> for staging validation."
   ```

5. **Request approval in `#qhp-eng`.** Tag the code owners directly, link the PR and the
   ticket, and cc anyone else who should be aware. Example (from QEU-342):

   > hi @Vyshakh Babji @Saber may I get your approval for this cherry pick:
   > https://github.com/Qualified-Health/qh-platform/pull/4982 which is for a p0 ticket
   > https://qualifiedhealth.atlassian.net/browse/QEU-342 for clinical coding? thank you!
   >
   > cc @Pranav Budhwant @Alekhya

6. **Get approval, merge into `release`.** Worth checking with the team first whether a
   UAT cycle is already in progress on `release` so you don't collide with someone else's
   testing.

   **Then check the auto-triggered deploy Action succeeded** — a green Action only means
   the image built and the GitOps repo got the tag bump, **not** that the pods rolled yet:
   ```bash
   gh run list --branch release --limit 10     # find "Deploy Temporal Worker" for your merge commit
   gh run watch <run-id> --exit-status
   ```
   Then verify the actual GKE rollout (separate cluster from the DB — see Part 2, step 2):
   ```bash
   gcloud container clusters get-credentials qh-staging-platform \
     --region us-central1 --project qh-staging --internal-ip
   kubectl -n qh get deploy temporal-workers-high temporal-workers-low \
     -o jsonpath='{range .items[*]}{.metadata.name}{" -> "}{.spec.template.spec.containers[0].image}{"\n"}{end}'
   kubectl -n qh rollout status deploy/temporal-workers-high
   kubectl -n qh rollout status deploy/temporal-workers-low
   ```
   Confirm the image tag contains your Actions run ID, and rollout reports "successfully
   rolled out" (new pods can sit `Pending` 1–3 min while the autoscaler adds a node).

7. **Sanity-check what landed:** the resulting commit on `release` should be titled
   `"<original PR title> (#<original PR#>) (#<cherry-pick PR#>)"` — the pattern the
   team's `release` history already uses (e.g. `... (#4957) (#4961)`).

---

## Part 2 — Staging Test Steps

### 1) Prepare test case CSV file(s)

Reuse **real** source data (e.g. a prior benchmark/repro CSV) — don't fabricate clinical
note content. Schema's encounter-id column is `pat_enc_csn_id` (first column).

**Dedup rule:** the file-processor dedups on the encounter-id column. Re-dropping an
already-ingested id is silently skipped — so **every test round needs a fresh suffix**.

Script pattern — strip any existing suffix, apply a new one, leave every other column
untouched:
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

resuffix('source.csv', 'my-test-staging-verify-YYYYMMDD.csv', '-mytag-stgMMDD')
```

**Verify the rewrite touched nothing else** before uploading (only column 0 should ever
differ):
```python
ra = list(csv.reader(open('source.csv', newline='', encoding='utf-8')))
rb = list(csv.reader(open('new.csv', newline='', encoding='utf-8')))
assert len(ra) == len(rb) and len(ra[0]) == len(rb[0])
assert not [i for i,(r1,r2) in enumerate(zip(ra[1:], rb[1:])) if r1[1:] != r2[1:]]
```

Use a descriptive filename, not the original's generic name, e.g.
`qeu342-repro-staging-verify-20260724.csv`.

### 2) Upload the file to the staging drop bucket

First resolve the composer + bucket (one-time per workflow, DB access needs a
**different cluster** than the worker pods):
```bash
gcloud container clusters get-credentials qh-staging-customer-qhai \
  --region us-central1 --project qh-staging --internal-ip
kubectl -n qh port-forward svc/mvp-cloudsqlproxy 5432:5432 &
```
**DB password isn't in Secret Manager** — it's in the `mvp-db` k8s secret:
```bash
kubectl -n qh get secret mvp-db -o jsonpath='{.data}' | python3 -c "
import sys, json, base64
d = json.load(sys.stdin)
for k,v in d.items(): print(k, '=', base64.b64decode(v).decode())
"
```
Resolve the composer row (confirm **exactly one** match):
```sql
SELECT id, workflow_code, org_id FROM workflows.composer_metadata
WHERE workflow_code='<code>' AND COALESCE(is_deleted,false)=false;
```
The drop bucket is **not** config-driven (`temporal_config` has no bucket keys) — it's
convention-based: `gs://qhai-com-staging-composer-data-files/<workflow_dir>/` (e.g.
`clinical_coding/`).

⚠️ **Gotcha:** don't confuse with the similarly-named
`qhai-com-staging-composer-<workflow>-datafiles` bucket — that one holds per-encounter
offloaded-note artifacts (`ha_number_*/`), **not** the CSV drop zone.

Upload:
```bash
gcloud storage cp <file>.csv gs://qhai-com-staging-composer-data-files/<workflow_dir>/ --project qh-staging
gcloud storage ls -l gs://.../<workflow_dir>/<file>.csv --project qh-staging   # confirm landed, size matches
```

### 3) Check the file-processor picked it up

[Cloud Run → Logs Explorer, `qhai-com-composer-workflow-file-processor`, project
`qh-staging`](https://console.cloud.google.com/run/detail/us-central1/qhai-com-composer-workflow-file-processor/observability/logs?project=qh-staging)

Expect **~3–4 min lag** before anything appears downstream in Temporal — the first
several minutes legitimately show nothing; don't re-feed. Watch for a `Duplicate message`
log — means the suffix didn't actually dodge the dedup.

### 4) Check the cases are processing in Temporal

[Temporal Cloud → `qh-platform-staging.qyfc8` namespace,
Workflows](https://cloud.temporal.io/namespaces/qh-platform-staging.qyfc8/workflows)

Filter by your suffix tag, wait until all workflows reach `Completed`.

### 5) Check the processed results

[staging-chat.qualifiedhealthai.com](https://staging-chat.qualifiedhealthai.com/) — pull
up the encounters by tag and eyeball the rendered result (e.g. MDM level / E&M code
cards) against expectations.

For a precise field-level check instead of/in addition to the UI, query
`workflows.workflow_run` directly (no `state` column — non-null `result_json` means a
real finished result):
```sql
SELECT external_id, result_json->>'<field>' AS field, ...
FROM workflows.workflow_run
WHERE external_id LIKE '%-<tag>' ORDER BY external_id;
```
Check fields against the bug's known-bad baseline (from the RCA/ticket).

---

## Worked example — QEU-342

| Step | Value |
|---|---|
| Original PR (→ develop) | [#4939](https://github.com/Qualified-Health/qh-platform/pull/4939) — "Fix MDM level and time-based code derivation in clinical coding v1" |
| Squash commit on develop | `1a030b99f0bda77e394f483ab63aa8698f33147b` |
| Cherry-pick branch | `cherry-pick/pr4939-release` (applied clean — one test file auto-merged, no conflicts) |
| Cherry-pick PR (→ release) | [#4982](https://github.com/Qualified-Health/qh-platform/pull/4982) |
| Resulting commit on release | `4b720e10648bca37afac233e7c0200f6424fe283` — `"Fix MDM level and time-based code derivation in clinical coding v1 (#4939) (#4982)"` |
| Deploy Action | `Deploy Temporal Worker`, run id `30114191316` — image tag `30114191316-3534-1` rolled out on `temporal-workers-high`/`-low` in `qh-staging` |
| Composer | `workflow_code='clinical-coding'`, `id=d19245cb-e6f1-4d2a-b4a5-999d2f8c6b09`, `org_id=org_hCdKESeaLsROQhVg` (tenant `qhai-com`) |
| Drop bucket | `gs://qhai-com-staging-composer-data-files/clinical_coding/` |
| Test round 1 | `qeu342-repro-staging-verify-20260724.csv` — 2 RCA repro encounters (`963676781`, `959527231`), suffix `-qeu342-stg0724` — result: fix confirmed |
| Test round 2 | `v1-benchmark-staging-verify-20260724b.csv` — 5-encounter broader regression set, suffix `-v1bench-stg0724b` — result: no regressions |

Verified the cherry-pick actually landed (not merged-then-reverted) via:
```bash
git merge-base --is-ancestor 4b720e10648bca37afac233e7c0200f6424fe283 origin/release
```

---

## Gotchas (all parts)

- Cherry-pick from the **develop squash commit**, not the raw feature-branch commits —
  otherwise `release`'s history gets noisy/duplicated.
- `release` moves fast — conflicts are more likely the longer you wait between merging to
  `develop` and cherry-picking.
- Landing on `release` only gets the fix onto staging early — it doesn't replace the
  normal release cut. Confirm separately when this rides an actual production deployment.
- GKE rollout lags the Actions run by a few minutes — don't feed test data until
  `kubectl rollout status` confirms it.
- DB access and worker-pod access are **different GKE clusters**
  (`qh-staging-customer-qhai` vs `qh-staging-platform`).
- The MVP DB password lives in the `mvp-db` k8s secret, not Secret Manager.
- Don't confuse the CSV drop bucket (`qhai-com-staging-composer-data-files/<workflow>/`)
  with the per-encounter artifacts bucket
  (`qhai-com-staging-composer-<workflow>-datafiles`).
- Always give each test round a **fresh id-column suffix** — re-feeding the same id
  silently no-ops (dedup), which looks like nothing happened rather than an error.
