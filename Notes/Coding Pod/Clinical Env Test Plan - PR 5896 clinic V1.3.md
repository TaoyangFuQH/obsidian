---
updated: 2026-09-03
tags: [plan, coding-pod, clinical-env]
---
# Clinical Env Test Plan — PR #5896 (clinic V1.3)

Follows [[Clinical Environment Test Runbook]]. PR: `Qualified-Health/qh-platform#5896`,
branch `feat/clinic-v13-h2h3inj-cv-consensus`, Jira `QHE-3555`.

## Goal

Validate the V1.3 changes end-to-end on the real production-shaped pipeline, on two
encounters chosen because each exercises a **different half** of the PR.

| encounter | GT `em` | V1.2 (stock) | V1.3 | what it proves |
| --- | --- | --- | --- | --- |
| `962495324` | `99214` | 40% correct (2/5 draws) | **100%** (6/6) | the **prompt** hunks (H2 + H3inj) |
| `973014662` | `99215` | 40% correct (2/5 draws) | **83%** (5/6) | the **aggregator** (`tc` TIME-card voting) |

Mechanism, from the offline draws:
- `962495324` — stock's COPA oscillates moderate↔low (GT = moderate); every wrong draw is a
  `low` read. Prompt-only is already 3/3, so `tc+ew` contributes nothing here.
- `973014662` — a **TIME** case, not MDM. Correct draws carry `time_level=level`, wrong draws
  carry none; MDM elements barely move. `tc` majority-votes the TIME card instead of
  inheriting the code-winner's, so the documented time survives and drives `99215`.
  ⚠️ The prompt alone makes this one **worse** (1/3 vs stock 2/5) — the fix is purely the
  logic change.

## ⚠️ Blocker to resolve before Phase B — the PR's "abstention on by default" does not reach production

`rcm_dag_activities` hoists the flags and **always injects a value**:

```python
input_data.setdefault("abstention_enabled", bool(tc.get("abstention_enabled", False)))
input_data.setdefault("abstention_policy",  str(tc.get("abstention_policy") or "unanimous"))
```

Both clinic nodes (`clinic-verifier-scoring`, `clinic-abstention-gate`) read these via
`arg_keys`, so the DAG passes an explicit value and the activity kwarg default never
applies. Consequences for this PR:

1. `abstention_enabled: bool = True` on the activities — **dead through the DAG path**.
2. `DEFAULT_POLICY = POLICY_CONSENSUS_OR_CORROBORATED` — **dead through the DAG path**; when
   the composer's `temporal_config` lacks the key the hoist substitutes **`"unanimous"`**,
   not the new policy.
3. The only change that matters operationally is `dag/temporal_config_v1.json`, and that is
   a **seed file** — it must be loaded into `workflows.composer_metadata.temporal_config`
   per composer to take effect.

**Fixed in `b21048c`** — the hoist fallback is now per-`workflow_code`, so a composer with
no abstention keys gets clinic's `consensus_or_corroborated`, and one with only
`abstention_enabled=true` no longer silently runs ED's `unanimous`. ED unchanged.

⚠️ **But Phase B still needs the DB write.** `migrate_v0_to_v1.sql` already wrote
`abstention_enabled: false` / `abstention_policy: "qh_high"` into
`composer_metadata.temporal_config` as a full overwrite, and the composer value overrides
the code default. So on the likely `clinical` state the gate stays **off** after deploying —
Part 2 below is required, not optional.

## Scope

| phase | config | validates |
| --- | --- | --- |
| **A** | abstention **off** (leave composer as-is) | the two `em` fixes — prompt + aggregator. This is the core test. |
| **B** | `abstention_enabled=true`, `abstention_policy=consensus_or_corroborated` | the gate fires, masks on `NEEDS_REVIEW`, and verifier calls succeed in-cluster |

Phase A is the one the two encounters were chosen for. Phase B is optional and can be
skipped if the abstention commit is split out of the PR (see the PR's Recommendation).

## Part 1 — Deploy

Pointer branch: **`deploy/clinical/cc_test`** (already exists, currently `d3cdac077`).

1. Post to `#clinical-env-timeshare` before touching the pointer:
   ```
   testing on clinical
   - branch: deploy/clinical/cc_test  (PR #5896, clinic V1.3)
   - pods: temporal worker
   ```
2. Record the rollback SHA, then force-move:
   ```bash
   git fetch origin
   git rev-parse origin/deploy/clinical/cc_test          # SAVE — rollback SHA
   git branch -f deploy/clinical/cc_test origin/feat/clinic-v13-h2h3inj-cv-consensus
   git push origin deploy/clinical/cc_test --force-with-lease
   ```
3. **One deploy action only — `Deploy Temporal Worker`.** The diff touches
   `packages/rcm/clinical_coding/**` (prompts) and `temporal-workers/**` (aggregator,
   abstention); both are in that workflow's `on.push.paths`, and nothing else in the diff
   matches another deploy workflow.
   ```bash
   gh workflow run "Deploy Temporal Worker" --ref deploy/clinical/cc_test
   gh run list --workflow "Deploy Temporal Worker" --branch deploy/clinical/cc_test --limit 3
   gh run watch <run-id> --exit-status
   ```
4. Confirm the roll actually landed (green Action ≠ rolled pods):
   ```bash
   gcloud container clusters get-credentials qh-clinical-platform \
     --region us-central1 --project qh-clinical --internal-ip
   kubectl -n qh get deploy temporal-workers-high temporal-workers-low \
     -o jsonpath='{range .items[*]}{.metadata.name}{" -> "}{.spec.template.spec.containers[0].image}{"\n"}{end}'
   kubectl -n qh rollout status deploy/temporal-workers-high
   kubectl -n qh rollout status deploy/temporal-workers-low
   ```
   Image tag must embed the Actions run id, and both must report "successfully rolled out".

## Part 2 — DB config (Phase B only; skip for Phase A)

Resolve the composer row **by `id`** first — a wrong `org_id`/`workflow_code` in the `WHERE`
is a silent no-op. Record the existing JSONB so it can be restored.

```sql
-- 1. find the row and save the current value
SELECT id, temporal_config FROM workflows.composer_metadata WHERE /* clinical coding composer */;
-- 2. set the two keys by id
UPDATE workflows.composer_metadata
   SET temporal_config = temporal_config
       || '{"abstention_enabled": true, "abstention_policy": "consensus_or_corroborated"}'::jsonb
 WHERE id = '<id>';
```

Read **at dispatch** — set it before feeding, not after.

## Part 3 — Test data

### Source
`clinic/dataset/clinic-feedback-177-dos-match-20260730/input.csv` in `coding-ai-harness`
(**PHI — GCS-backed, never commit**). Extract the two rows by `pat_enc_csn_id`.

- `962495324` — `is_new_patient=Established`, note 9,615 chars, DOS 2026-08-06
- `973014662` — `is_new_patient=Established`, note 10,727 chars, DOS 2026-08-07

⚠️ **Both are `Established`.** The New-patient branch of the DPC logic is **not** exercised
by this test. Accept that, or add one `New` encounter that V1.3 does not change, purely as a
smoke row.

⚠️ **Data-sensitivity gut-check:** this is client-feedback data being uploaded into the
`qhai-com` tenant on `clinical`. Non-prod, but confirm that crossing tenants with this
source is acceptable before uploading (runbook Part 3 flags exactly this).

### Schema alignment
The harness CSV has **49 columns**; the dispatch allow-list (`ClinicalCodingDispatch._ALLOWED_FIELDS`)
is the locked production set. The note is **not** forwarded inline — it is offloaded to GCS
and read back via `input_gcs_uri` by `rcm-format-notes` — so the note column must be present
for the drain, but blank-fill any locked-schema columns the harness set lacks. Do not feed a
narrower schema as-is.

### Rounds — 3 per version, not 1
Neither encounter is deterministic under V1.2, and `973014662` is not deterministic under
V1.3 either. A single pass can easily show no difference, or the reverse of the expected one.

| | V1.2 right | V1.3 right | P(one run shows no difference) |
| --- | --- | --- | --- |
| `962495324` | 40% | 100% | ~40% |
| `973014662` | 40% | 83% | ~50% |

So: **3 rounds on `develop` (baseline) and 3 rounds on the PR branch**, 2 encounters each =
12 workflow runs. Each round needs a **fresh id suffix** — the file processor dedups on
`pat_enc_csn_id` and silently skips a repeat, which looks like nothing happened.

Suffix scheme:
```
962495324-cc5896-base-1 / -2 / -3      (pointer on develop)
962495324-cc5896-v13-1  / -2 / -3      (pointer on the PR branch)
973014662-cc5896-base-1 / …            etc.
```

### Upload
```bash
gcloud storage cp PR5896-<round>.csv \
  gs://qhai-com-clinical-composer-data-files/clinical_coding/ --project=qh-clinical
gcloud storage ls -l gs://qhai-com-clinical-composer-data-files/clinical_coding/PR5896-<round>.csv \
  --project=qh-clinical
```
⚠️ Not `qhai-com-clinical-composer-clinical-coding-datafiles` — that holds per-encounter
output artifacts, not the CSV drop zone. List the folder to confirm it shows other
engineers' recent CSVs.

### Watch
Drop → dispatch lag is **~3–4 min**; the first minutes legitimately show nothing in
Temporal. Do not re-feed. A `Duplicate message` log means the suffix did not dodge dedup.
```bash
gcloud logging read 'resource.type="cloud_run_revision" resource.labels.service_name="<cf-service>"' \
  --project=qh-clinical --freshness=10m --limit=60 --order=desc
temporal workflow list --env clinical --query 'WorkflowType="rcm-workflow"' | grep cc5896
```

## Expected results

Phase A, per encounter across 3 rounds:

| encounter | baseline (develop) | PR branch (V1.3) | pass condition |
| --- | --- | --- | --- |
| `962495324` | `99214` in ~1 of 3; `99213` otherwise | **`99214` in 3 of 3** | V1.3 = 3/3 and baseline < 3/3 |
| `973014662` | `99214` in ~2 of 3 | **`99215` in ≥2 of 3** | V1.3 ≥ 2/3 correct, with `time_level` populated |

Also worth eyeballing per run, since these are the mechanism:
- `962495324` → `copa_level` should read **moderate** on every V1.3 run.
- `973014662` → the TIME card should be **present/attributed** on V1.3 runs; that is what
  lifts it to `99215`.

Verify in the UI at [clinical-chat.qualifiedhealthai.com](https://clinical-chat.qualifiedhealthai.com/),
and field-level via:
```sql
SELECT external_id,
       (result_json IS NOT NULL) AS done,
       result_json -> 'ai_professional_code' AS em_code,
       result_json -> 'copa_level'  AS copa,
       result_json -> 'time_level'  AS time_level,
       result_json -> 'abstention'  AS abstention
  FROM workflows.workflow_run
 WHERE external_id LIKE '%cc5896%'
 ORDER BY external_id;
```

Phase B additionally: `abstention.policy = consensus_or_corroborated`, a real
`AUTO_ACCEPTED`/`NEEDS_REVIEW` verdict (not `SKIPPED`), and **no** `gpt_error` /
`gemini_error`. A verifier error is treated as "does not confirm" and masquerades as a
policy abstention — see the known contamination below.

## Known risks

- **Verifier failures look like policy abstentions.** In offline runs one draw came back
  structurally complete (139/139, no stubs) but with 45 GPT and 64 Gemini errors, producing
  32 `both_verifiers_failed` abstentions and crushing coverage from 88% to 59%. If Phase B
  shows low coverage, check `gpt_error`/`gemini_error` before blaming the policy.
- **`v1_benchmark` is not usable for a clinical round.** ~8% of its `clinic-extract` streams
  fail with `ReadError` (243/3,105 calls, 85 of 139 encounters) versus **zero** on the 177
  set. Use the 177 set for any broader regression round.
- Every new commit on the PR branch = full re-point → re-dispatch → re-verify-roll before
  re-testing.

## Cleanup

1. Restore `temporal_config` to the recorded baseline (Phase B only).
2. Restore the pointer:
   ```bash
   git branch -f deploy/clinical/cc_test <recorded-rollback-SHA>
   git push origin deploy/clinical/cc_test --force-with-lease
   ```
3. Post to `#clinical-env-timeshare` that the pointer is free.

## Log

_(append per round: suffix, pointer SHA, Actions run id, image tag, result per encounter)_

---

# Appendix — Enabling `consensus_or_corroborated` after the deploy

Deploying the PR is **not** sufficient (see the blocker section above). This is the ordered
procedure. Do it per environment; `clinical` first, then production.

## Step 0 — Prerequisite: verifier credentials must exist in the target cluster

`consensus_or_corroborated` calls **GPT-5.4 and Gemini on every encounter**. The clinic
verifier reads exactly the same env vars as the ED verifier:

```
AZURE_GPT_54_OPENAI_ENDPOINT
AZURE_GPT_54_OPENAI_API_VERSION
AZURE_GPT_54_OPENAI_DEPLOYMENT
AZURE_GPT_54_OPENAI_API_KEY
GOOGLE_GEMINI_API_KEY          (preferred)  — or VERTEX_PROJECT + ADC
```

⚠️ **If any are missing the gate does not crash — it abstains on everything.** A missing key
raises inside `_safe`, which returns `{"error": ...}`, and a failed verifier is treated as
"does not confirm". Observed offline: one draw with 45 GPT + 64 Gemini errors produced 32
`both_verifiers_failed` abstentions and coverage collapsed 88% → 59%, with no error surfaced
anywhere else. **Verify before flipping the config, not after.**

```bash
kubectl -n qh get deploy temporal-workers-high -o json \
  | jq -r '.spec.template.spec.containers[0].env[]?.name' | grep -E 'AZURE_GPT_54|GEMINI|VERTEX'
kubectl -n qh get deploy temporal-workers-high -o json \
  | jq -r '.spec.template.spec.containers[0].envFrom[]?.secretRef.name'
# then confirm the referenced secret actually carries the keys
kubectl -n qh get secret <name> -o json | jq -r '.data | keys[]' | grep -E 'AZURE_GPT_54|GEMINI|VERTEX'
```
If they are absent, stop — wiring them is a separate change.

## Step 1 — Deploy the code first

The code must be live before the config points at a policy it does not know. An unknown
`abstention_policy` falls back to `DEFAULT_POLICY` with a warning, so a config-first order
would silently run the wrong policy for the gap.

Deploy per Part 1 above, and confirm `kubectl rollout status` on both worker deployments.

## Step 2 — Find the row and save the current value

Resolve by `id`. The v1 migration keys on `workflow_code + org_id + is_deleted`, so a
multi-org install has **one row per org** — check the count before assuming a single row.

```sql
SELECT id, org_id,
       temporal_config -> 'abstention_enabled' AS enabled,
       temporal_config -> 'abstention_policy'  AS policy
  FROM workflows.composer_metadata
 WHERE workflow_code = 'clinical-coding'
   AND is_deleted = false;
```

Record the full `temporal_config` for each row you intend to touch — that is the rollback:

```sql
SELECT id, temporal_config FROM workflows.composer_metadata WHERE id = '<id>';
```

## Step 3 — Patch the two keys, by `id`

`||` merges, so nothing else in the JSONB is disturbed. One statement per row.

```sql
UPDATE workflows.composer_metadata
   SET temporal_config = temporal_config
       || '{"abstention_enabled": true, "abstention_policy": "consensus_or_corroborated"}'::jsonb,
       updated_at = now()
 WHERE id = '<id>';
```

⚠️ Do **not** use `SET temporal_config = '<whole json>'` — a full overwrite is how the
existing `false` / `qh_high` values got there, and it would drop any drift since the seed.

Confirm the write landed and nothing else moved:

```sql
SELECT temporal_config -> 'abstention_enabled' AS enabled,
       temporal_config -> 'abstention_policy'  AS policy,
       temporal_config -> 'llm_model'          AS model,
       temporal_config -> 'ensemble_votes'     AS votes
  FROM workflows.composer_metadata WHERE id = '<id>';
```

## Step 4 — Smoke ONE encounter before opening the tap

`temporal_config` is read **at dispatch**, so the next encounter fed picks it up. Feed a
single encounter with a fresh id suffix and check the gate actually ran:

```sql
SELECT external_id,
       result_json -> 'abstention' AS abstention,
       result_json -> 'ai_professional_code' AS em_code
  FROM workflows.workflow_run
 WHERE external_id LIKE '%<your-suffix>%';
```

Pass conditions — all four:

| check | expected |
| --- | --- |
| `abstention.policy` | `consensus_or_corroborated` — **not** `unanimous`, not `qh_high` |
| `abstention.verdict` | `AUTO_ACCEPTED` or `NEEDS_REVIEW` — **not** `SKIPPED` |
| `abstention.gpt_error` | `null` |
| `abstention.gemini_error` | `null` |

A `SKIPPED` verdict means the config did not take (wrong row, or dispatch predates the
write). Non-null verifier errors mean Step 0 was not actually satisfied — **roll back rather
than proceed**, because coverage will be destroyed while accuracy looks fine.

## Step 5 — Watch the first real batch

The thing to watch is **coverage**, not accuracy. Expect roughly **88%** of encounters with
an E/M to be auto-accepted, i.e. ~12% routed to human review. Offline, on the shipped code
path: 88.4% coverage / 94.7% accepted accuracy on the 177 set, 88.4% / 95.2% on the holdout.

```sql
SELECT count(*)                                                        AS n,
       count(*) FILTER (WHERE result_json #>> '{abstention,verdict}' = 'AUTO_ACCEPTED') AS accepted,
       count(*) FILTER (WHERE result_json #>> '{abstention,verdict}' = 'NEEDS_REVIEW')  AS review,
       count(*) FILTER (WHERE result_json #>> '{abstention,gpt_error}'    IS NOT NULL)  AS gpt_err,
       count(*) FILTER (WHERE result_json #>> '{abstention,gemini_error}' IS NOT NULL)  AS gem_err
  FROM workflows.workflow_run
 WHERE run_end_time > now() - interval '1 hour' AND result_json IS NOT NULL;
```

⚠️ **If `review` is far above ~12%, check `gpt_err` / `gem_err` before concluding the policy
is wrong.** Verifier failures are indistinguishable from policy abstentions in the coverage
number — that is the single most misleading failure mode of this feature.

Also expect **per-encounter model cost to rise from ~$0.76 to ~$1.01** (3 Claude + 1 GPT +
1 Gemini).

## Rollback

One statement, using the value saved in Step 2:

```sql
UPDATE workflows.composer_metadata
   SET temporal_config = temporal_config
       || '{"abstention_enabled": false}'::jsonb,
       updated_at = now()
 WHERE id = '<id>';
```

Takes effect on the next dispatch; no redeploy needed, and in-flight workflows are
unaffected. Setting `abstention_enabled=false` is enough — leaving the policy key in place
is harmless and keeps the intended value recorded for the next attempt.
