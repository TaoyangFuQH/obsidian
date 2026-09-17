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

Re-verified per cluster 2026-09-17, matching `workflow_code LIKE '%utilization%'` (an earlier
pass matched only the exact string and **missed two sibling workflows** — see the split-state
finding below). `cv` = `temporal_config.conditions_version`.

| env | cluster | UR workflow rows (cv) | guideline versions | v6 syncope md5 |
|---|---|---|---|---|
| clinical | `qh-clinical-customer-qhai` | `utilization-review` (6) | v1:38, v5:236, **v6:236** | ✅ match |
| staging | `qh-staging-customer-qhai` | `utilization-review` (6), **`utilization-review-guidelines` (6)** | v0–v4, **v6:236** | ✅ match |
| production | `qh-prod-customer-utmb` | `utilization-review` (6), **`utilization-review-ios` (null)** | v0–v4, **v6:236** | ✅ match |
| production | `qh-prod-customer-mercy-stlouis` | `utilization-review` (6) | v2, v4, **v6:236** | ✅ match |
| production | `qh-prod-customer-uthscsa` | `utilization-review` (6), **`utilization-review-guidelines` (null)** | v2, v4, v5, **v6:236** | ✅ match |
| production | `qh-prod-customer-emory` | `utilization-review` (null), `utilization-review-guidelines` (null) | v0, v1, v2:476, v3, v4 — **no v6** | n/a |
| production | `qh-prod-customer-qhai` | `utilization-review-ios` (null), `utilization-review` (null) | v0–v3 — **no v6** | n/a |
| development | `qh-dev-customer-qhai` | `utilization-review` (5) | v0–v3, **v5:236** | n/a |

**Exactly five clusters carry the v6 corpus, and all five have the identical syncope text.**
`prod-emory` and `prod-qhai` run UR but were never given v6; they resolve dynamically against
their own older corpora. The install script aborts there (guard: v6 must be 236 rows), which is
the correct outcome — do not force v7 onto them.

Every other customer cluster in every environment has the unused v2 corpus seeded by the
2025-04 migration and **no** UR workflow at all: clinical `chn`/`emory`/`mercy-stlouis`/`urmc`/
`uthscsa`/`utmb`, staging `mercy-stlouis`, and production `atria`/`chn`/`emory-eu`/`jefferson`/
`lcmc`/`nychhc`/`penn-medicine`/`qhai-org`/`sanfordhealth`/`university-rochester`/`urmc`/
`ut-austin`/`ut-md-anderson`/`ut-rgv`/`ut-tyler`/`uthouston`/`utsouthwestern`. **Skip them
deliberately** — v7 there would be dead rows that a future dynamically-resolving UR workflow
could latch onto without ever having been validated for that tenant.

> [!bug] The cutover script leaves a split state on staging-qhai and does not warn
> `bump_conditions_version_v6_to_v7.sql` updates **only** `workflow_code = 'utilization-review'`.
> Its guard asserts exactly one such row, which passes — and silently ignores the siblings:
>
> - **`staging-qhai`**: `utilization-review-guidelines` is also pinned at **6**. After the
>   cutover it stays at 6 while `utilization-review` moves to 7. Split state, no warning.
> - **`prod-utmb`**: `utilization-review-ios` is `null` → **auto-jumps to v7** when script 1 commits.
> - **`prod-uthscsa`**: `utilization-review-guidelines` is `null` → same auto-jump.
>
> `utilization-review-guidelines` is an older composer_metadata row for the *same* product
> surface — identical `workflow_display` ("Utilization Review") and `workflow_url`
> (`/utilization-report`), created 2025-04-23 vs 2025-10-08 for `utilization-review`, rank 1 vs 5.
> `workflow_run.py:472` notes it has "731 legitimate rows", so it has been used. **Whether it is
> still live is not yet determined** — the lineage runs through `workflows.composition_id` and was
> not chased down. All 236 v6 guideline rows belong to `utilization-review`, so the install
> script's `composer_metadata_id` passthrough is correct either way.
>
> **Fix before step 4:** add a guard to the cutover script that lists every
> `workflow_code LIKE '%utilization%'` row and aborts if any *other* one is pinned at 6 or is
> null, forcing an explicit decision instead of a silent split. Failing loudly is the point.

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

### The check — re-runnable lint

Verified against prod-utmb 2026-09-17: returns exactly 3 conditions / 12 child rows. Run it on
any UR cluster after authoring or importing guidelines; it resolves the live version itself, so
it needs no editing between clusters or corpus versions.

```sql
-- Guideline lint: exclusion-framed criteria that split into numbered children.
-- Each child returned must state its own polarity ("ruled out" / "Suspected" /
-- a test name). A bare diagnosis noun is the defect -- see QHE-4200.
WITH live AS (
    SELECT (temporal_config ->> 'conditions_version')::int AS v
      FROM workflows.composer_metadata
     WHERE workflow_code = 'utilization-review' AND is_deleted = false
), g AS (
    SELECT condition, guideline
      FROM workflows.guidelines, live
     WHERE is_deleted = false AND version = live.v
), ln AS (
    SELECT condition,
           regexp_replace(line, '^[[:space:]]*[-*][[:space:]]*', '') AS line
      FROM g, regexp_split_to_table(g.guideline, E'\n') AS line
), parent AS (
    SELECT condition,
           (regexp_match(line, '^\*\*([IVX]+\.[A-Z])\.\*\*'))[1] AS num,
           line AS parent_text
      FROM ln
     WHERE line ~ '^\*\*[IVX]+\.[A-Z]\.\*\*'
       AND line ~* 'exclud|ruled out|rule out|ruling out|mimic|alternative (diagnos|etiolog|primary)'
)
SELECT p.condition,
       p.num                   AS parent,
       left(p.parent_text, 70) AS parent_text,
       left(c.line, 80)        AS child_text
  FROM parent p
  JOIN ln c
    ON c.condition = p.condition
   AND c.line ~ ('^\*\*' || replace(p.num, '.', '\.') || '\.[0-9]')
 ORDER BY p.condition, c.line;
```

Expected output on v6 — anything beyond these three is a new offender to triage:

| condition | parent | children polarity |
|---|---|---|
| `CHEST PAIN WITH NEGATIVE TROPONIN BUT RISK FACTORS` | `V.A.` | ✅ all `Suspected …` |
| `FAINTING EPISODE REQUIRING HOSPITALIZATION` | `I.B.` | ❌ bare nouns — fixed by v7 |
| `HYPERTENSIVE URGENCY` | `I.B.` | ✅ test names |

It deliberately does **not** try to judge polarity automatically — "is this text a bare
diagnosis noun" is a clinical reading, not a regex. The lint narrows 236 guidelines to a
handful of blocks a human can eyeball in a minute.

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

### 6.2 Files to add (qh-platform, branch `QHE-4200-ur-soi-ib-ruled-out`)

```
packages/rcm/ur/scripts/v6_to_v7_guidelines.sql       # step 1 — install v7
packages/rcm/ur/scripts/bump_conditions_version_v6_to_v7.sql   # step 2 — cut over
packages/rcm/ur/CHANGELOG.md                                  # guideline corpus version history
```

Conventions to follow — precedent is `packages/rcm/clinical_coding/dag/migrate_v0_to_v1.sql`:
`\set ON_ERROR_STOP on`, `BEGIN` / `COMMIT`, `DO $$ … RAISE EXCEPTION` guards, and a header
comment carrying usage + rollback. `packages/rcm/ur/scripts/` does not exist yet; the
clinical-coding precedent puts SQL under the package's `dag/`, which is the wrong noun here,
so a new `scripts/` dir is the better home.

Changelog at `packages/rcm/ur/CHANGELOG.md`. Other packages use that filename for Python code
history; here it tracks the **guideline corpus**, which is a database artifact. The file says so
in its header. If this package ever needs a code changelog too, split them at that point.

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

### 6.7 Verified runbook — how to actually execute against a cluster

Every command below was exercised read-only against `qh-clinical-customer-qhai` on 2026-09-17.

**The scripts must run in local `psql`, not in a pod.** `mvp-proxy` has Python but **no psql**
(`command -v psql` → nothing), and the scripts use the psql meta-command
`\set ON_ERROR_STOP on`, which psycopg2 cannot execute. So: port-forward the Cloud SQL proxy and
drive it from the laptop. Local psql is 15.18, server is 15.17 — same major, no client/server
mismatch.

```bash
# 0. target the cluster.  --internal-ip is MANDATORY: without it kubeconfig gets the
#    public master IP and every kubectl call hangs (authorized networks = Tailscale only).
gcloud container clusters get-credentials qh-clinical-customer-qhai \
  --region us-central1 --project qh-clinical --internal-ip

# 1. PRE-FLIGHT: which workflows resolve their version dynamically?  Any row showing
#    null here will jump to v7 the instant script 1 commits -- before the cutover.
kubectl -n qh exec -i \
  "$(kubectl -n qh get pods --field-selector=status.phase=Running -o name \
       | grep -m1 mvp-proxy | cut -d/ -f2)" -c mvp-proxy -- \
  python3 -c 'import os,psycopg2;c=psycopg2.connect(host=os.environ["DB_HOST"],port=os.environ["DB_PORT"],user=os.environ["POSTGRES_USER"],password=os.environ["POSTGRES_PASSWORD"],dbname=os.environ["POSTGRES_DB"]);c.set_session(readonly=True);u=c.cursor();u.execute("SELECT workflow_code, temporal_config->>%s FROM workflows.composer_metadata WHERE is_deleted=false ORDER BY 1",("conditions_version",));[print(r) for r in u.fetchall()]'

# 2. credentials -- read from the k8s secret, never hardcode.  NOTE the DB user is
#    per-tenant: 'qhai-com-postgres' on clinical-qhai, 'utmb-postgres' on prod-utmb.
export PGPASSWORD=$(kubectl -n qh get secret mvp-db -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d)
PGUSER=$(kubectl -n qh get secret mvp-db -o jsonpath='{.data.POSTGRES_USER}' | base64 -d)

# 3. port-forward the Cloud SQL proxy (leave running in its own shell)
kubectl -n qh port-forward svc/mvp-cloudsqlproxy 5433:5432

# 4. DRY RUN -- exercises every guard and the INSERT, then throws it away.
#    Do this on every cluster before the real run; it is free and catches a drifted
#    corpus or an already-present v7 without touching anything.
sed 's/^COMMIT;/ROLLBACK;/' packages/rcm/ur/scripts/v6_to_v7_guidelines.sql \
  | psql -h 127.0.0.1 -p 5433 -U "$PGUSER" -d qh_mvp_db

# 5. for real
psql -h 127.0.0.1 -p 5433 -U "$PGUSER" -d qh_mvp_db \
  -f packages/rcm/ur/scripts/v6_to_v7_guidelines.sql

# 6. VERIFY before cutting over -- v7 = 236 rows, one changed guideline, three
#    criteria reworded.  The script asserts all of this itself and aborts on failure,
#    so reaching this point clean is the verification; the tail SELECTs print the I.B. block.

# 7. the cutover
psql -h 127.0.0.1 -p 5433 -U "$PGUSER" -d qh_mvp_db \
  -f packages/rcm/ur/scripts/bump_conditions_version_v6_to_v7.sql

unset PGPASSWORD
```

Rollback, either stage:

```bash
# undo the cutover (instant, no data loss)
psql -h 127.0.0.1 -p 5433 -U "$PGUSER" -d qh_mvp_db -c \
  "UPDATE workflows.composer_metadata
      SET temporal_config = jsonb_set(temporal_config,'{conditions_version}','6'::jsonb),
          updated_at = timezone('UTC', now())
    WHERE workflow_code='utilization-review' AND is_deleted=false;"

# then, if you also want the corpus gone
psql -h 127.0.0.1 -p 5433 -U "$PGUSER" -d qh_mvp_db -c \
  "DELETE FROM workflows.guidelines WHERE version = 7;"
```

### 6.8 Merging the PR does not deploy this

The two `.sql` files are **not** Alembic migrations — nothing runs them automatically. The PR
makes them reviewed, versioned artifacts; applying them is the manual, per-cluster procedure in
6.7. Say so in the PR description so no reviewer assumes merge = applied.

Neither CI gate touches these files, confirmed 2026-09-17:
`.github/workflows/migration-check.yml` only watches
`services/{api,qh-proxy,qh-apps-proxy}/migrations/versions/**`, and
`scripts/check_phi_added_lines.py` scans **added Python lines only**. Commit convention from
recent history is `QHE-4200: <description>`, base branch `develop`; there is no PR template.

## 7. Next steps — ordered checklist

**Step 1 is done** (PR [#6310](https://github.com/Qualified-Health/qh-platform/pull/6310)). Next up: step 2, update clinical.

Text is settled (`ruled out` x3 + the clause deletion + I.B.3), so **step 1 is unblocked now**.
The one open decision — scope, i.e. utmb alone or all three v6 tenants — gates step 5 only, so
it can be chased in parallel with steps 1-4.

### Step 1 — branch, files, commit, PR

Branch first, off `develop`. Two naming conventions coexist in the repo (`feat/…`/`fix/…`, and
`QHE-XXXX-…`); use the ticket-key form so Jira auto-links the branch.

```bash
git -C ~/workspace/qh-platform worktree add .worktrees/qhe-4200 \
  -b QHE-4200-ur-soi-ib-ruled-out develop
cd ~/workspace/qh-platform/.worktrees/qhe-4200
mkdir -p packages/rcm/ur/scripts
# add: scripts/v6_to_v7_guidelines.sql
#      scripts/bump_conditions_version_v6_to_v7.sql
#      CHANGELOG.md
git add packages/rcm/ur/scripts packages/rcm/ur/CHANGELOG.md
git commit -m "QHE-4200: UR SOI guideline v7 — self-contained I.B. exclusion criteria"
git push -u origin QHE-4200-ur-soi-ib-ruled-out
gh pr create --base develop --title "QHE-4200: UR SOI guideline v7 — self-contained I.B. exclusion criteria"
```

- [x] worktree + branch off `develop` — `.worktrees/qhe-4200`, branch `QHE-4200-ur-soi-ib-ruled-out`
- [x] three files added under `packages/rcm/ur/`
- [x] commit `fe08cdd` — `QHE-4200: UR SOI guideline v7 — self-contained I.B. exclusion criteria`
- [x] PR against `develop` — [#6310](https://github.com/Qualified-Health/qh-platform/pull/6310)
- [x] **PR description leads with "merging does not change any environment"** — see 6.8
- [x] PR links QHE-4200 and tables the three reviewed decisions, plus the scope question for reviewers

No CI gate touches these files (verified 2026-09-17): `migration-check.yml` watches only
`services/{api,qh-proxy,qh-apps-proxy}/migrations/versions/**`, and
`check_phi_added_lines.py` scans added **Python** lines only.

### Step 2 — update clinical · `qh-clinical-customer-qhai`

Mechanics in **6.7**. Summary: no psql in the pod, so port-forward `svc/mvp-cloudsqlproxy`
and drive from local psql.

- [ ] `get-credentials … --internal-ip`
- [ ] pre-flight: list every `workflow_code` + `conditions_version`; note any `null` (those
      follow v7 the moment script 1 commits, before the cutover)
- [ ] credentials from the `mvp-db` secret — the DB user is per-tenant, never hardcode it
- [ ] port-forward `svc/mvp-cloudsqlproxy 5433:5432`
- [ ] **dry run** — `sed 's/^COMMIT;/ROLLBACK;/'` piped into psql. Exercises every guard and
      the INSERT, discards the result. Free; catches a drifted corpus or a pre-existing v7
- [ ] run `v6_to_v7_guidelines.sql` — a clean exit *is* the verification (the script asserts
      236 rows, one changed guideline, three reworded criteria, and aborts otherwise)
- [ ] run `bump_conditions_version_v6_to_v7.sql`
- [ ] fill in the promotion-log row in `packages/rcm/ur/CHANGELOG.md`

### Step 3 — test clinical

Mechanism only; clinical has no volume for a metrics judgement.

- [ ] one syncope encounter through UR
- [ ] UI Severity of Illness → Met Criteria reads `I.B.1. … Seizure ruled out …`
- [ ] `result_json._provenance.guidelines_version` = 7

### Step 4 — staging · `qh-staging-customer-qhai` — the real gate

Same runbook, then the backtest.

- [ ] scripts applied + structural checks pass
- [ ] re-run the syncope cohort under v7; diff per encounter against v6:
      `I.B.1/.2/.3 criterion_met`, `overall_criteria_met`, `overall_ai_classification`,
      `in_patient_confidence`
- [ ] **zero** movement outside the syncope cohort — nothing else in the corpus changed, so any
      movement there means the copy was not clean
- [ ] expected direction: dropping `or correlated with symptoms` should make `I.B.2` harder to
      mark met where hypoglycemia was symptomatic. If nothing moves at all, the model was
      ignoring the contradictory clause and the change is display-only — record that
- [ ] two artifacts: eval report + changelog, per `docs/EVALUATION.md`

### Step 5 — production

- [ ] **scope decided** (utmb only, or + mercy-stlouis + uthscsa)
- [ ] `qh-prod-customer-utmb`, low-volume window
- [ ] re-run the HAR from the Slack thread; confirm the UI wording
- [ ] watch the syncope cohort 48h against the stage-4 prediction
- [ ] rollback trigger: material divergence → `conditions_version` back to 6
- [ ] close QHE-4200 noting both issues addressed, and that I.B.3 went beyond ticket scope

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
- **2026-09-17** — Step 1 landed. Branch `QHE-4200-ur-soi-ib-ruled-out` off `develop`, commit
  `fe08cdd`, PR [#6310](https://github.com/Qualified-Health/qh-platform/pull/6310) against `develop`.
  Three files under `packages/rcm/ur/`. Structural validation only — balanced `BEGIN`/`COMMIT`, even
  `$$` quoting, balanced string literals, `ON_ERROR_STOP` present. **The SQL has not been executed
  anywhere.** First real validation is the ROLLBACK dry-run on clinical-qhai (step 2). Confirmed
  neither CI gate applies: `migration-check.yml` watches only
  `services/{api,qh-proxy,qh-apps-proxy}/migrations/versions/**`, and `check_phi_added_lines.py`
  scans added Python lines only.
