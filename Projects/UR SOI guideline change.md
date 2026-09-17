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
  - **I.B.2.** Hypoglycemia ruled out (point-of-care [POC] glucose ≥ 70 mg/dL at time of evaluation).
  - **I.B.3.** Intoxication or pharmacologic sedation ruled out as sole cause.
```

Diff: **+ "ruled out" ×3**, **− "or correlated with symptoms"**. Nothing else in the corpus changes.

### Deviations from the ticket, for review

| | ticket text | proposed | why |
|---|---|---|---|
| I.B.1 | `... (no postictal confusion > 5 min, no tongue biting, no focal deficit)` | keeps `lasting > 5 minutes` / `focal neurologic deficit` | v6 house style spells units and clinical terms out; keeps the diff to the two words that matter |
| I.B.2 | `(POC glucose ≥ 70 mg/dL at evaluation)` | `(point-of-care [POC] glucose ≥ 70 mg/dL at time of evaluation)` | v6 expands every abbreviation on first use (`electrocardiogram (ECG)`, `Transient Ischemic Attack`) |
| I.B.3 | *not in ticket* | **added** | same block, same parent-heading dependency, same misread. Leaving it is the only remaining ambiguous criterion in the guideline — it would look like an oversight |

If Harvineet/Jim want the ticket text literally, use it — the semantics are identical and
the decision is theirs. Flag the I.B.2 clause deletion explicitly either way: it is a
substantive narrowing, not just wording.

### Scope check — this pattern is rare

Scanned all 236 v6 guidelines for "exclusion-style parent heading + numbered children that
lack their own exclusion wording". Only two conditions match:

- `FAINTING EPISODE REQUIRING HOSPITALIZATION` — I.B.1/.2/.3 ← this ticket
- `HYPERTENSIVE URGENCY` — I.B.1–.6 are workup steps (ECG, BMP, UA…), which read naturally
  as "tests completed". Low misread risk; **recommend no change**

Good pattern to copy, already in the corpus — `SYNCOPE WITH ABNORMAL ECG` I.C. states the
exclusion inline in a single self-contained criterion:
`Non-syncopal mimics reasonably excluded (e.g., seizure with postictal state > 5 minutes, hypoglycemia with glucose < 60 mg/dL as sole cause, intoxication, TIA with focal deficit).`

---

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
- Confirm the **I.B.3 addition** and the **I.B.2 clause deletion**.
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

