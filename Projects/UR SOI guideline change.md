---
tags: [project, ur, guidelines]
ticket: QHE-4200
epic: QHE-3877
status: planning
created: 2026-09-17
---
# UR SOI guideline change — I.B. exclusion criteria (QHE-4200)

Rewording two (recommend three) sub-criteria in the **Syncope** SOI guideline so each
criterion is self-contained instead of relying on a parent heading the UI never renders.

- Ticket: [QHE-4200](https://qualifiedhealth.atlassian.net/browse/QHE-4200) · High · assignee Tao-yang · labels `Product:UR`, `client:utmb`
- Epic: [QHE-3877](https://qualifiedhealth.atlassian.net/browse/QHE-3877) — *UR — Logic Update and Backtest*
- Raised by Steven Mortimer (Slack); rewording decided by Jim Atkins; guideline authored by Harvineet Singh

---

## 1. Why this is a data change, not a code change

Guideline text is **not in git**. It lives in `workflows.guidelines` in each customer
cluster's `mvp_db` (Cloud SQL), loaded by the `guidelines-import` Temporal workflow from a
GCS CSV. The repo's only snapshot is the 2025-04 migration
`3f07b1c58760_upgrade_latest_guidelines.py`, which is the **v2** corpus and does not match
what any tenant runs today.

The bug has two halves:

1. **Exclusion read as a positive finding.** The frontend renders only
   `${guideline_number}. ${report}` (`client/apps/workflows-shared/utils/dataFormatter.ts`,
   `reportWiseStringDataFormatter`). The parent heading — which is where "excluded" lives —
   never reaches `result_json`, let alone the screen. A met `I.B.1` therefore reads to a UR
   nurse as *"the patient had a seizure"*.
2. **Self-contradicting threshold on I.B.2.** The label says `Hypoglycemia`, the
   parenthetical says `≥ 70 mg/dL` (= not hypoglycemic = excluded), and the trailing
   `or correlated with symptoms` says the opposite again (= confirmed as the cause). This is
   the "backwards threshold" in the ticket. The number itself is correct; the trailing clause
   is the defect.

Not cosmetic: `criterion_met` feeds `overall_criteria_met` → threshold → the classifier's
`criteria_met` signal → `overall_ai_classification`. Hence "and Backtest" in the epic name.

---

## 2. Where the guideline lives — full inventory

Read-only sweep of all 33 customer clusters across 4 environments, 2026-09-17.
`live` = `temporal_config.conditions_version` on `composer_metadata` where
`workflow_code = 'utilization-review'`.

### Clusters that actually run UR

| env | cluster | project | versions present | live |
|---|---|---|---|---|
| clinical | `qh-clinical-customer-qhai` | qh-clinical | v1:38, v5:236, **v6:236** | **6** |
| staging | `qh-staging-customer-qhai` | qh-staging | v0, v1, v2, v3, v4, **v6:236** | **6** |
| production | `qh-prod-customer-utmb` | qh-production | v0, v1, v2, v3, v4, **v6:236** | **6** |
| production | `qh-prod-customer-mercy-stlouis` | qh-production | v2, v4, **v6:236** | **6** |
| production | `qh-prod-customer-uthscsa` | qh-production | v2, v4, v5, **v6:236** | **6** |
| production | `qh-prod-customer-emory` | qh-production | v0, v1, **v2:476**, v3, v4 | `None` → dynamic |
| production | `qh-prod-customer-qhai` | qh-production | v0, v1, v2, v3 | `None` → dynamic |
| development | `qh-dev-customer-qhai` | qh-development | v0, v1, v2, v3, **v5:236** | **5** |

### Clusters with a guidelines table but no UR workflow

`NO_UR_WORKFLOW` = no `utilization-review` row in `composer_metadata`; the v2 corpus is
seeded everywhere by the old migration but unused.

- clinical: `chn` (v2:186 + 52 NULL-version), `emory`, `mercy-stlouis`, `urmc`, `uthscsa`, `utmb` — all v2:238
- staging: `mercy-stlouis` — v2:238
- production: `atria`, `chn`, `emory-eu`, `jefferson` (v1:21+v2), `lcmc`, `nychhc` (v1:21+v2), `penn-medicine`, `qhai-org`, `sanfordhealth`, `university-rochester`, `urmc`, `ut-rgv`, `uthouston`, `utsouthwestern` — v2:238
- production, partially-NULL versions: `ut-austin` (v2:101 + 137 NULL), `ut-md-anderson` (v2:141 + 97 NULL), `ut-tyler` (v2:49 + 189 NULL)

### Not reachable

- `qh-clinical-customer-penn-medicine` — `x509: certificate signed by unknown authority`

### Inventory findings worth acting on

- **`qh-clinical-customer-utmb` cannot be the clinical rehearsal env.** It has no UR
  workflow and only the v2 corpus. There is also **no staging utmb cluster at all**. The
  naive "clinical utmb → staging utmb → prod utmb" path does not exist.
- **v6 is shared by three production tenants** — utmb, mercy-stlouis, uthscsa. The ticket
  is labelled `client:utmb` only. ⇒ open question in §5.
- `prod-emory` has **v2:476** = 238 × 2. The bulk upload is insert-only, so someone ran it
  twice. Precedent for the duplication risk in §4.
- `prod-emory` and `prod-qhai` run UR with `conditions_version: None`, i.e. dynamic
  resolution. Three prod tenants have NULL-version guideline rows. Both are pre-existing
  latent problems, not ours — but see the landmine in §4.

### How to query it

```bash
gcloud container clusters get-credentials <cluster> --region us-central1 \
  --project <qh-clinical|qh-staging|qh-production> --internal-ip     # --internal-ip is mandatory
POD=$(kubectl -n qh get pods --field-selector=status.phase=Running -o name \
      | grep -m1 mvp-proxy | cut -d/ -f2)
kubectl -n qh exec -i "$POD" -c mvp-proxy -- python3 -c '...'
```

Two gotchas that cost time:
- Without `--internal-ip`, kubeconfig gets the **public** master IP and every kubectl call
  hangs — master authorized networks only admit the Tailscale range `100.64.0.0/10`.
- `DB_CONNECTION_STRING` in the pod is a Cloud SQL **instance name**, not a DSN. Connect
  from `DB_HOST` / `DB_PORT` / `POSTGRES_USER` / `POSTGRES_PASSWORD` / `POSTGRES_DB`, and
  set `conn.set_session(readonly=True)`.
- Pick a **Ready** pod: most clusters currently have an extra `mvp-proxy` replica stuck in
  `Init:CrashLoopBackOff`, and `exec` into it fails.

---

## 3. The change — v7 rewording

Target row: condition `FAINTING EPISODE REQUIRING HOSPITALIZATION`, version 6
(prod utmb id `ca9a7bce-f94f-4ec5-8539-d8232dfcb87a`, `updated_at 2026-07-01`; ids differ
per cluster — look it up, don't hardcode).

### Current (v6, verbatim)

```markdown
- **I.B.** Alternative diagnoses reasonably excluded by initial evaluation, including:
  - **I.B.1.** Seizure (no postictal confusion lasting > 5 minutes, no tongue biting, no focal neurologic deficit).
  - **I.B.2.** Hypoglycemia (point-of-care glucose ≥ 70 mg/dL at time of evaluation or correlated with symptoms).
  - **I.B.3.** Intoxication or pharmacologic sedation as sole cause.
```

### Proposed v7 (recommended)

```markdown
- **I.B.** Alternative diagnoses reasonably excluded by initial evaluation, including:
  - **I.B.1.** Seizure ruled out (no postictal confusion lasting > 5 minutes, no tongue biting, no focal neurologic deficit).
  - **I.B.2.** Hypoglycemia ruled out (point-of-care glucose ≥ 70 mg/dL at time of evaluation).
  - **I.B.3.** Intoxication or pharmacologic sedation ruled out as sole cause.
```

Diff: **+ "ruled out" ×3**, **− "or correlated with symptoms"** on I.B.2. Nothing else in
the corpus changes.

### Deviations from the ticket

| | ticket text | applied | why |
|---|---|---|---|
| I.B.1 | `... (no postictal confusion > 5 min, no tongue biting, no focal deficit)` | v6 parenthetical kept verbatim | the ticket paraphrased loosely (`> 5 min`, `focal deficit`); keeping v6's wording means the only edit is the two added words |
| I.B.2 | `Hypoglycemia ruled out (POC glucose ≥ 70 mg/dL at evaluation).` | `Hypoglycemia ruled out (point-of-care glucose ≥ 70 mg/dL at time of evaluation).` | same — v6's `point-of-care` / `at time of evaluation` retained. `POC` is never reused in this guideline and it uses parens `(TLOC)`, `(ECG)`, `(BMP)` with zero square brackets, so no abbreviation is introduced |
| I.B.3 | *not in ticket* | **added** — `Intoxication or pharmacologic sedation ruled out as sole cause.` | same block, same parent-heading dependency, same misread; leaving it would be the only ambiguous criterion left in the guideline |

Both ticket issues are addressed: **+ "ruled out"** fixes issue 2 (exclusion read as a
positive finding); **− "or correlated with symptoms"** fixes issue 1 (the self-contradicting
threshold — the half after `or` described hypoglycemia as the confirmed cause, contradicting
the `≥ 70 mg/dL` in the same parenthetical).

The clause deletion is a **substantive narrowing, not a wording tweak** — call it out
explicitly for Harvineet/Jim rather than letting it ride as part of a "rewording" ticket.

### Scope check — verified across all 236 deployed guidelines

Rigorous scan of v6, 2026-09-17. Framing the question as "which conditions use exclusion
language" gives an unstable count — **44** conditions mention it inside a numbered criterion,
but most use it as a *qualifier* (`Hgb drop ≥ 2 g/dL without alternative etiology`,
`troponin elevation … (excluding clear alternative)`), which is self-contained by construction
and cannot be misread. The count depends entirely on where you draw the line, and it does not
change the action.

The question that does matter: **which exclusion-framed criteria split into numbered children
that display individually?** Three do — not one.

| condition | criterion | children | verdict |
|---|---|---|---|
| `FAINTING EPISODE REQUIRING HOSPITALIZATION` | `I.B.` Alternative diagnoses reasonably excluded… | `Seizure`, `Hypoglycemia`, `Intoxication or pharmacologic sedation as sole cause` | ❌ **broken** — bare diagnosis nouns |
| `HYPERTENSIVE URGENCY` | `I.B.` Initial evaluation completed to rule out hypertensive emergency… | `Targeted history and physical`, `12-lead ECG`, `BMP with serum creatinine`, `Urinalysis`, `Chest imaging`, `Troponin` | ✅ safe — workup steps; "ECG — met" correctly means the test was done |
| `CHEST PAIN WITH NEGATIVE TROPONIN BUT RISK FACTORS` | `V.A.` Clinical suspicion requiring inpatient workup for life-threatening alternative diagnosis: | `Suspected aortic dissection`, `Suspected pulmonary embolism…`, `Suspected myocarditis or pericarditis…` | ✅ safe — every child is prefixed `Suspected`, and here a positive reading *is* the intent |

So only Fainting Episode needs editing — but **not** because it is the only one that splits.

### The authoring rule this implies

The defect is not "an exclusion criterion was split into numbered children". Splitting is fine;
the frontend renders criteria individually by design. The defect is:

> **A numbered criterion whose text does not carry its own polarity.**

- `Seizure` — bare noun, no polarity → breaks
- `12-lead electrocardiogram (ECG)` — a test name needs no polarity → fine
- `Suspected aortic dissection` — polarity stated → fine
- `Seizure ruled out` — polarity stated → fixed

Every numbered criterion must state its own polarity: `ruled out`, `Suspected`, `documented`,
`absent`, or simply be the name of a test performed. **Never a bare diagnosis noun.** That is
the guardrail to put in guideline-authoring guidance — it generalises, whereas "don't split"
would forbid two patterns that are already correct.

Worth noting the corpus already contains the *inline* alternative, which is equally safe and
needs no child criteria at all — `SYNCOPE WITH ABNORMAL ECG` I.C.:
`Non-syncopal mimics reasonably excluded (e.g., seizure with postictal state > 5 minutes,
hypoglycemia with glucose < 60 mg/dL as sole cause, intoxication, TIA with focal deficit).`
That is the same clinical content as Fainting Episode's I.B. block, authored correctly.

## 4. How to make the change — recommended mechanism

**Copy the full v6 corpus to v7 with three edited lines, then bump `conditions_version`.**

| option | verdict |
|---|---|
| **A** — `UPDATE` the v6 row in place | ❌ Every completed run records `guidelines_version: 6` in `_provenance`. Editing v6 makes that provenance a lie and past runs unreproducible. No rollback artifact. |
| **B** — import full corpus as v7, bump `conditions_version` 6→7 | ✅ **Recommended.** Clean provenance axis, rollback is one config flip, old runs stay interpretable. |
| **C** — import v7 containing only the edited row | ❌ **Dangerous.** `get_guidelines` fetches by `(conditions, version)` and **degrades silently to `{}`** on a miss — the run still classifies on LOS + IoS alone. Every other condition would lose its guidelines with no error. |

### Runbook (per cluster)

1. **Pre-check** — assert no v7 exists yet and v6 is exactly 236 rows:
   `SELECT version, count(*) FROM workflows.guidelines WHERE is_deleted=false GROUP BY version;`
2. **Export** v6 → CSV with the upload schema's columns
   (`condition, guideline, description, version, is_in_patient, workflow_code`), setting
   `version = 7` and `workflow_code = 'utilization-review'`.
3. **Edit** only the `FAINTING EPISODE REQUIRING HOSPITALIZATION` row's three I.B lines.
   Diff the CSV against the export and confirm exactly 3 changed lines in 1 row.
4. **Upload** — GCS + the `guidelines-import` Temporal workflow (`org_id`, `gcs_uri`), or
   POST the CSV to `/api/v2/workflows/guidelines/upload`.
5. **Post-check** — v7 count is **exactly 236** (not 472), and the three lines read as intended.
6. **Bump** `composer_metadata.temporal_config.conditions_version` 6 → 7 for
   `workflow_code = 'utilization-review'`.
7. **Rerun + backtest** (§5).

**Rollback:** set `conditions_version` back to 6. The v7 rows can stay; they are inert once
nothing points at them.

### Landmines

- **The bulk upload is INSERT-only, not upsert.** `repositories/v2/workflows/guidelines.py::upload`
  constructs a fresh `TableModel` per row. Running it twice gives you 472 v7 rows — exactly
  how `prod-emory` ended up with v2:476. Any row error rolls the whole upload back, so a
  partial state is not a risk, but a *repeated* one is.
- **`utilization-review-ios` resolves its version dynamically.** It has
  `conditions_version: None`, and `get_conditions_version()` is
  `GET /guidelines?page=1&limit=1` ordered `created_at DESC` — it returns whatever row was
  inserted most recently. **It will jump to v7 the instant v7 rows land, before step 6 and
  without any config change.** Confirm per tenant whether that workflow is live and whether
  it should follow. Same exposure for `prod-emory` / `prod-qhai`, whose `utilization-review`
  is also on `None`.
- **Version numbering is not contiguous** — prod utmb has 0,1,2,3,4,6 (no 5); clinical qhai
  has 1,5,6; dev qhai is on 5. Don't assume `max(version) + 1` is free everywhere; check per cluster.

---

## 5. Rollout plan — clinical → staging → production

The env ladder has to follow the **qhai** tenant, because utmb has no clinical or staging
UR deployment. qhai clinical and staging are both already on v6, so they are faithful
rehearsals of the exact same corpus.

### Stage 0 — decide scope (blocking, needs Harvineet/Jim/Kevina)

- Is this **utmb-only** or **all v6 tenants**? Landing v7 only for utmb makes utmb diverge
  from mercy-stlouis and uthscsa, which run the identical v6 corpus and have the identical
  defect. A tenant-specific fix to a shared clinical corpus needs an explicit owner decision.
- Confirm the **I.B.3 addition**.
- Confirm the **`or correlated with symptoms` deletion** on I.B.2 — it is a semantic change,
  not a rewording, and it is what actually fixes the ticket's issue 1.
- Optional: `qh-dev-customer-qhai` (on v5) as a zero-risk mechanics dry-run first.

### Stage 1 — clinical · `qh-clinical-customer-qhai`

Full runbook §4. Goal is to prove the **mechanism**, not the metrics: v7 lands at exactly
236 rows, `conditions_version` flips, a UR run picks up v7, and the three criteria render in
the UI as "… ruled out". Verify the `I.B.1` line in the Severity-of-Illness → Met Criteria tab.

### Stage 2 — staging · `qh-staging-customer-qhai`

Same runbook. This is where the **backtest** runs, since staging has the encounter volume
clinical lacks:
- Pull the syncope-cohort encounters (primary/secondary condition = `FAINTING EPISODE REQUIRING HOSPITALIZATION`) already scored under v6.
- Re-run under v7 and diff per encounter: `I.B.1/.2/.3` `criterion_met`, `overall_criteria_met`,
  and `overall_ai_classification` + `in_patient_confidence`.
- Report population-level movement **and** the per-cause changelog. Two artifacts, per
  `docs/EVALUATION.md` in coding-ai-harness.
- Expected direction: removing `or correlated with symptoms` should make `I.B.2` *harder* to
  mark met on charts where hypoglycemia was symptomatic — so some encounters should lose a
  met criterion. If nothing moves, the LLM was ignoring the contradictory clause and the fix
  is display-only; that is itself a finding worth writing down.
- Gate: no unexplained classification flips outside the syncope cohort (there should be
  **zero** — nothing else in the corpus changed).

### Stage 3 — production

Order: **`qh-prod-customer-utmb`** first (the ticket's client, and the reporter is watching
it), then mercy-stlouis and uthscsa if Stage 0 scoped them in.

- Land during a low-volume window; UR runs continuously off Databricks.
- Post-deploy: re-run the specific HAR from the Slack thread and confirm the UI now reads
  "Seizure ruled out" / "Hypoglycemia ruled out".
- Watch the syncope cohort's classification mix for 48h against the staging prediction.
- Rollback trigger: classification movement materially outside what staging predicted →
  flip `conditions_version` back to 6.

### Open questions

- [ ] utmb-only, or all three v6 prod tenants?
- [ ] I.B.3 in scope? I.B.2 clause deletion confirmed?
- [ ] Ticket text verbatim, or house-style version from §3?
- [ ] Is `utilization-review-ios` live anywhere on v6? It auto-jumps to v7.
- [ ] Who owns the guideline CSV of record? `gs://utmb-clinical-composer-ur-datafiles/` is
      empty, so the v6 corpus has no visible source artifact — v7 should establish one.
- [ ] Does UTMB need to sign off on a clinical-criteria wording change?

---

## 6. Execution plan

### 6.1 Mechanism: SQL script, not the CSV import path

Two candidate mechanisms exist. **SQL wins for this change**, and it is worth writing down why,
because the CSV path is the one the platform nominally provides.

| | `guidelines-import` (GCS CSV → bulk-upload API) | **SQL script** |
|---|---|---|
| fit | bulk authoring a whole corpus from a spreadsheet | ✅ surgical edit to 3 lines inside one row |
| risk | round-trips 236 markdown blobs (embedded newlines, `**`, `≥`, quotes) through CSV — corruption risk for no gain | ✅ text never leaves the DB; `INSERT … SELECT` copies it |
| atomicity | insert-only, no upsert, no assertions | ✅ one transaction, pre- and post-assertions |
| reviewability | a CSV diff is unreadable | ✅ readable git diff |
| repeatability across 5 clusters | re-upload per cluster, hope the CSV is identical | ✅ same file, `psql -f`, per cluster |

The enabling fact: the v6 syncope text is **byte-identical on all five UR clusters**
(`md5 = 26dde41e09a40c637256d34e0c3674f0`), so one script is provably safe everywhere.

There is **no cross-tenant batch** — each customer cluster is its own Cloud SQL instance.
"Batch" here means one reviewed script executed N times, not one statement spanning tenants.

### 6.2 Files to add (qh-platform, branch `fix/qhe-4200-ur-soi-ib-rewording`)

```
packages/rcm/ur/scripts/qhe4200_v6_to_v7_guidelines.sql       # step 1 — install v7
packages/rcm/ur/scripts/qhe4200_bump_conditions_version.sql   # step 2 — cut over
packages/rcm/ur/GUIDELINES_CHANGELOG.md                       # corpus version history
```

Conventions to follow — precedent is `packages/rcm/clinical_coding/dag/migrate_v0_to_v1.sql`:
`\set ON_ERROR_STOP on`, `BEGIN` / `COMMIT`, `DO $$ … RAISE EXCEPTION` guards, and a header
comment carrying usage + rollback. `packages/rcm/ur/scripts/` does not exist yet; the
clinical-coding precedent puts SQL under the package's `dag/`, which is the wrong noun here,
so a new `scripts/` dir is the better home.

Changelog named `GUIDELINES_CHANGELOG.md`, **not** `CHANGELOG.md` — every other package uses
that name for Python code history. This one tracks a database corpus, and conflating the two
would mislead.

### 6.3 Script 1 — install v7

Copies all 236 v6 rows to v7, applying three `replace()` calls to the syncope row only.
Carries over `access`, `status`, `description`, `is_in_patient` and `composer_metadata_id`;
new `gen_random_uuid()` for `id`; `created_at` / `updated_at` from column defaults.

Guards matter more than the INSERT here. Four pre-assertions:

1. **no v7 rows exist** — the script is deliberately not idempotent; a second run would leave
   472 rows. `prod-emory` already carries v2:476 from exactly this mistake on the CSV path.
2. **v6 is exactly 236 rows** — else this cluster is not on the reviewed corpus.
3. **exactly one v6 syncope row.**
4. **`md5(guideline) = 26dde41e09a40c637256d34e0c3674f0`** — the single most important check.
   The rewrite is substring replacement, so whitespace drift would make it a **silent no-op**
   and ship a v7 identical to v6. Asserting the md5 turns that into an abort.

Four post-assertions: v7 has 236 rows; the three `ruled out` strings are present;
`or correlated with symptoms` is gone; and **exactly one** guideline differs between v6 and v7.

Rollback: `DELETE FROM workflows.guidelines WHERE version = 7;` — safe while
`conditions_version` still points at 6, because nothing references v7.

### 6.4 Script 2 — cut over

`jsonb_set(temporal_config, '{conditions_version}', '7')` on the `utilization-review`
`composer_metadata` row (`temporal_config` is `jsonb`, so this is clean). Guards: v7 is
complete at 236 rows; exactly one `utilization-review` row; current version is **exactly 6**
— never cut over from an unknown state; and an explicit abort if `conditions_version` is
`NULL`, since such a cluster resolves dynamically and has already moved on its own.

Rollback: same `jsonb_set` back to `6`. In-flight workflows past `ur-get-guidelines` keep the
version they started with, so no drain is needed.

> [!danger] Script 1 is not as inert as it looks
> Any workflow with `conditions_version: NULL` resolves via
> `get_conditions_version()` → `GET /guidelines?page=1&limit=1` ordered `created_at DESC`, so
> it **jumps to v7 the moment script 1 commits** — before the cutover, with no config change.
> As of 2026-09-17 that is `utilization-review-ios` wherever deployed, plus
> `utilization-review` on `prod-emory` and `prod-qhai`. Run this on every cluster first:
> ```sql
> SELECT workflow_code, temporal_config->'conditions_version'
>   FROM workflows.composer_metadata WHERE is_deleted = false;
> ```

### 6.5 The ladder — update → test, six gates

Same two scripts every rung. A rung is not done until its test passes; a failed test rolls
back that rung only (`conditions_version` → 6) and stops the promotion.

| # | rung | action | test / gate |
|---|---|---|---|
| 1 | **update clinical** `qh-clinical-customer-qhai` | script 1 → verify → script 2 | v7 = 236 rows, 1 changed guideline, `conditions_version` = 7 |
| 2 | **test clinical** | run one syncope encounter through UR | UI Severity-of-Illness → Met Criteria shows `I.B.1. … Seizure ruled out …`; `_provenance.guidelines_version` = 7. **Mechanism only — not a metrics gate** (clinical lacks volume) |
| 3 | **update staging** `qh-staging-customer-qhai` | same two scripts | same structural checks |
| 4 | **test staging — the real gate** | re-run the syncope cohort under v7, diff against v6 | per-encounter diff of `I.B.1/.2/.3 criterion_met`, `overall_criteria_met`, `overall_ai_classification`, `in_patient_confidence`. **Zero** movement outside the syncope cohort (nothing else changed — any movement there means the copy was not clean). Two artifacts: eval report + changelog, per `docs/EVALUATION.md` |
| 5 | **update production** `qh-prod-customer-utmb` | same two scripts, low-volume window | structural checks; then re-run the HAR from the Slack thread |
| 6 | **test production** | watch the syncope cohort 48h | classification mix tracks the stage-4 prediction. Rollback trigger: material divergence → `conditions_version` → 6 |

Then stages 4–5 of the promotion log (mercy-stlouis, uthscsa) **only if §5 Stage 0 scoped them in**.

### 6.6 Still blocking — do not start rung 1 until these are answered

- [ ] **Scope**: utmb only, or all three v6 prod tenants? Landing v7 on utmb alone makes the
      three diverge on a shared clinical corpus. Owner decision, not ours.
- [ ] **I.B.3 addition** confirmed by Harvineet/Jim?
- [ ] **`or correlated with symptoms` deletion** confirmed as intended? It is a semantic
      change, and it is what actually fixes issue 1.
- [ ] Is `utilization-review-ios` live on any v6 cluster? It auto-follows v7.
- [ ] Does UTMB need to sign off on a clinical-criteria wording change?
- [ ] Is `7` free on every target cluster? Numbering is not contiguous (prod-utmb has 0-4 and 6;
      clinical-qhai has 1, 5, 6), so `max + 1` is not a safe assumption.

## Log

- **2026-09-17** — Ticket read. Traced the pipeline, located the live guideline text, confirmed
  the target is `FAINTING EPISODE REQUIRING HOSPITALIZATION` v6 and that `I.B.` is the
  never-rendered parent heading. Swept all 33 customer clusters for guideline versions.
  Found: clinical/staging rehearsal must run on **qhai**, not utmb; v6 is shared by 3 prod
  tenants; `I.B.3` has the same defect and is not in the ticket; upload is insert-only.
  Nothing changed in any environment — all queries read-only.
- Unrelated but observed: a `mvp-proxy` replica is stuck in `Init:CrashLoopBackOff`
  (~47 restarts, ~3h40m, init container `db-migrations`) in most clinical/staging/prod
  clusters. Flagged separately; would block any migration-dependent deploy.

