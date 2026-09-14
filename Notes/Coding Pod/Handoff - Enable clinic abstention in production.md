---
created: 2026-09-14
tags: [coding-pod, clinic-coding, production, handoff]
---

# Handoff — enable clinic-coding abstention in production

**Ask:** someone with `qh-production` access runs steps 1–5 below. Should take ~20 minutes.
Self-contained — no context from prior work needed.

## Goal

Turn on the `consensus_or_corroborated` abstention gate for clinic coding in production,
by writing two keys into each tenant's `composer_metadata.temporal_config`.

**Why a DB change is needed at all.** The code already ships
`consensus_or_corroborated` as its default (in prod since release `26.3.5`), but the
per-composer `temporal_config` **overrides** the code default, and the original v0→v1 seed
wrote `abstention_enabled: false` / `abstention_policy: "qh_high"` into every row. So the
gate is off until those two keys are updated. Deploying the code was not enough.

**What changes for customers.** The gate declines low-confidence encounters to human review
instead of shipping them. On our 177-encounter tuning set: **~90% coverage at 95.0% accepted
accuracy**, vs 91.6% ungated. Every encounter also gains **two verifier calls** (Azure
GPT-5.4 + Gemini 2.5 Pro) where the old `qh_high` policy made none — roughly $0.30/encounter
and new load against two vendors.

**Accept rule:** ship the code if both verifiers agree with it, **or** if one agrees and
QH's own 3 seed votes were unanimous. Otherwise → human review.

**Not in scope:** a second optional change (`verifier_raw` in the DAG template) is
deliberately excluded — it adds no gate behaviour and ~53 KB per encounter of stored LLM
output. Separate decision, do not bundle.

---

## 1. Confirm verifier credentials exist in the prod worker env

The policy calls **both** verifiers on every encounter. If either credential is missing the
gate degrades silently — that arm errors and the encounter can't be corroborated.

```bash
kubectl -n qh get deploy temporal-workers-high -o yaml | grep -A5 envFrom
kubectl -n qh get secret qh-platform-secrets -o json \
  | python3 -c "import json,sys;print([k for k in json.load(sys.stdin)['data'] if 'GPT' in k or 'GEMINI' in k])"
```

Need `AZURE_GPT_54_OPENAI_ENDPOINT / _API_VERSION / _DEPLOYMENT / _API_KEY` and
`GOOGLE_GEMINI_API_KEY` (or `VERTEX_PROJECT` + Application Default Credentials).

**Stop if either is missing.**

## 2. Open the DB tunnel

The workflow tables are in the **tenant MVP DB**, in the **customer** cluster — *not* the
platform cluster. The platform DB has no `workflows` schema at all, which looks like a
permissions error but isn't.

```bash
gcloud container clusters get-credentials <prod-customer-cluster> \
  --region us-central1 --project qh-production --internal-ip
kubectl -n qh port-forward svc/mvp-cloudsqlproxy 5432:5432    # leave running
```

Credentials are in the `mvp-db` secret in that namespace:

```bash
CTX=<prod-customer-context>
d() { kubectl --context $CTX -n qh get secret mvp-db -o jsonpath="{.data.$1}" | base64 -d; }
PGPASSWORD="$(d POSTGRES_PASSWORD)" psql \
  "host=127.0.0.1 port=5432 dbname=$(d POSTGRES_DB) user=$(d POSTGRES_USER) sslmode=disable" -w
```

⚠️ **Use `-w`.** Without it psql prompts for a password and, with no tty, hangs forever
instead of erroring. The tunnel also drops on its own — just restart the port-forward.

## 3. Dry run — see what's there before changing anything

Production is multi-tenant, so expect **one row per org**. Note the count.

```sql
SELECT id, org_id,
       temporal_config->>'abstention_enabled' AS enabled,
       temporal_config->>'abstention_policy'  AS policy,
       (SELECT count(*) FROM jsonb_object_keys(temporal_config)) AS n_keys
  FROM workflows.composer_metadata
 WHERE workflow_code='clinical-coding' AND COALESCE(is_deleted,false)=false;
```

- Expected: `enabled=false`, `policy=qh_high` → proceed to step 4.
- If both keys are **absent**: the code default already applies, the gate is already on,
  and **step 4 is unnecessary**. Stop and report.
- If already `true` / `consensus_or_corroborated`: already done. Stop and report.

**Save this output** — it's the record of what the state was.

## 4. Apply

Save as `enable_abstention.sql` and run it in the same session.

Surgical `||` merge: only the two keys change, every other key preserved. One transaction,
guards on rowcount and key count, aborts if nothing matches (the "wrong DB" case).
Tested against a Postgres seeded from the real pre-change state across 3 orgs.

```sql
-- Enable consensus_or_corroborated for clinic coding, all orgs, one transaction.
-- Surgical `||` merge: only the two abstention keys change; every other key is preserved.
-- Snapshots each row first into _abst_rollback -- that temp table IS the rollback.
\set ON_ERROR_STOP on
BEGIN;

DROP TABLE IF EXISTS _abst_rollback;
CREATE TEMP TABLE _abst_rollback AS
SELECT id, org_id, temporal_config AS before_config
  FROM workflows.composer_metadata
 WHERE workflow_code = 'clinical-coding'
   AND COALESCE(is_deleted, false) = false;

\echo '--- BEFORE ---'
SELECT org_id,
       before_config->>'abstention_enabled' AS enabled,
       before_config->>'abstention_policy'  AS policy,
       (SELECT count(*) FROM jsonb_object_keys(before_config)) AS n_keys
  FROM _abst_rollback ORDER BY org_id;

UPDATE workflows.composer_metadata m
   SET temporal_config = m.temporal_config
       || '{"abstention_enabled": true, "abstention_policy": "consensus_or_corroborated"}'::jsonb,
       updated_at = now()
  FROM _abst_rollback r
 WHERE m.id = r.id;

DO $$
DECLARE bad int; n int;
BEGIN
  SELECT count(*) INTO n FROM _abst_rollback;
  IF n = 0 THEN RAISE EXCEPTION 'no clinical-coding composer rows matched -- wrong DB?'; END IF;

  SELECT count(*) INTO bad
    FROM workflows.composer_metadata m JOIN _abst_rollback r ON r.id = m.id
   WHERE m.temporal_config->>'abstention_enabled' IS DISTINCT FROM 'true'
      OR m.temporal_config->>'abstention_policy'  IS DISTINCT FROM 'consensus_or_corroborated';
  IF bad > 0 THEN RAISE EXCEPTION 'abstention keys not set on % row(s)', bad; END IF;

  -- no key may be added or dropped beyond the two we intended
  SELECT count(*) INTO bad
    FROM workflows.composer_metadata m JOIN _abst_rollback r ON r.id = m.id
   WHERE (SELECT count(*) FROM jsonb_object_keys(m.temporal_config))
      <> (SELECT count(*) FROM jsonb_object_keys(r.before_config))
       + (CASE WHEN r.before_config ? 'abstention_enabled' THEN 0 ELSE 1 END)
       + (CASE WHEN r.before_config ? 'abstention_policy'  THEN 0 ELSE 1 END);
  IF bad > 0 THEN RAISE EXCEPTION 'key count changed on % row(s)', bad; END IF;

  RAISE NOTICE 'OK: % clinical-coding composer row(s) updated', n;
END $$;

\echo '--- AFTER ---'
SELECT m.org_id,
       m.temporal_config->>'abstention_enabled' AS enabled,
       m.temporal_config->>'abstention_policy'  AS policy,
       (SELECT count(*) FROM jsonb_object_keys(m.temporal_config))  AS n_keys
  FROM workflows.composer_metadata m JOIN _abst_rollback r ON r.id = m.id
 ORDER BY m.org_id;

COMMIT;
```

Expect `NOTICE: OK: N clinical-coding composer row(s) updated`, AFTER showing
`true` / `consensus_or_corroborated`, and **`n_keys` identical to BEFORE**.

**Keep the psql session open** — `_abst_rollback` lives in it and is the rollback.

## 5. Verify on live traffic

`temporal_config` is read **at dispatch**, so this affects the next batch, not in-flight work.
On the first encounters through:

```sql
SELECT external_id,
       result_json->>'ai_professional_code'          AS em,
       result_json->'abstention'->>'policy'          AS policy,
       result_json->'abstention'->>'verdict'         AS verdict,
       result_json->'abstention'->>'gpt_error'       AS gpt_err,
       result_json->'abstention'->>'gemini_error'    AS gemini_err
  FROM workflows.workflow_run
 WHERE workflow_id = (SELECT id FROM workflows.workflows WHERE ... )  -- or filter by recent run_start_time
 ORDER BY run_start_time DESC LIMIT 20;
```

Healthy looks like:

- `policy` = **`consensus_or_corroborated`** (not `SKIPPED`, not `qh_high`)
- `verdict` = `AUTO_ACCEPTED` or `NEEDS_REVIEW`
- **`gpt_error` and `gemini_error` both null** — proves both verifiers ran

Watch the accept rate over the first few hundred encounters. **~90% expected.** A sharp drop
means a verifier is erroring — check the null-error condition above first.

---

## Rollback

In the same psql session (temp table still present):

```sql
UPDATE workflows.composer_metadata m
   SET temporal_config = r.before_config, updated_at = now()
  FROM _abst_rollback r
 WHERE m.id = r.id;
```

If the session was lost, restore from the step-3 output — that's why it's saved.

Rollback takes effect at the next dispatch. No redeploy needed either direction.

## Report back

- row count from step 3, and BEFORE/AFTER from step 4
- a sample of step 5 rows (policy / verdict / both error fields)
- the observed accept rate

Encounter ids are fine to share. **No note text, MRNs, or `result_json` pasted whole** —
it carries verbatim chart excerpts.
