---
updated: 2026-09-18
tags: [runbook, coding-pod, ur]
---
# Test UR on the `clinical` Environment

Companion to [[Clinical Environment Test Runbook]], which covers the same environment for
**clinic coding**. Read that one for everything generic — pointer branches, the timeshare
etiquette, the mvp-proxy migration trap, `psql` access. **This file is only what differs for UR**,
and the differences are large enough that following the clinic-coding version verbatim will fail.

Verified against `qh-clinical-customer-qhai` on 2026-09-18.

## The four things that differ

| | clinic coding | **UR** |
|---|---|---|
| Drop folder | `.../composer-data-files/clinical_coding/` | **`.../composer-data-files/ur_data_ios/`** |
| Dedup / suffix column | `pat_enc_csn_id` (column 0) | **`hospital_account_number` (column 1)** |
| Input schema | locked, 47 cols (`_ALLOWED_FIELDS`) | **not locked** — 25 cols in practice |
| Guideline-text changes | n/a | **need no deploy at all** — the corpus is DB data |

---

## Part 0 — Does this change even need a deploy?

Ask first, because for UR the answer is often no.

- **Guideline text** (`workflows.guidelines`) — **no deploy.** The SOI corpus is data in each
  customer cluster's `mvp_db`, not code in this repo. Apply the SQL, feed data, done. Skip Part 1
  entirely. (This is the QHE-4200 shape.)
- **Composer config** — `conditions_version`, `classifier_config` — **no deploy.** Part 2 only.
- **Prompts / activities / business logic** — deploy, see below.

### If you do deploy: `packages/rcm/ur/**` triggers THREE workflows

Unlike `packages/rcm/clinical_coding/**` (Temporal Worker only), the UR package is in the
`on.push.paths` of **`Deploy Temporal Worker`, `Deploy MVP Service`, and `Deploy MVP Proxy
Service`**. Do not blanket-dispatch all three. Match your actual changed files:

| changed files | dispatch |
|---|---|
| `packages/rcm/ur/{callbacks,report,transform,classes,utils,dispatch}.py`, `temporal-workers/app/**/ur/**` | `Deploy Temporal Worker` |
| `packages/rcm/ur/ir_csr/**` | **also** `Deploy MVP Proxy Service` — mvp-proxy imports `ur.ir_csr.types` / `ur.ir_csr.filename` (document generate/download/status) |
| `services/mvp-proxy/**` | `Deploy MVP Proxy Service` |

`packages/rcm/ur/**` is in `Deploy MVP Service`'s trigger list too, but no `from ur.` import was
found in `services/mvp/app` — that glob looks conservative rather than real. Verify before
dispatching it.

> [!warning] Needing the mvp-proxy deploy is the painful path
> The clinical MVP DB is pinned to `release`, so an mvp-proxy image built from `develop` or a
> feature branch dies in its `db-migrations` init container and the rollout silently never
> converges. See the **"If your diff touches mvp-proxy"** section of [[Clinical Environment Test Runbook]]
> for the two ways out. Touching `ur/ir_csr/**` drags you into this; touching the rest of the UR
> package does not.

---

## Part 1 — Deploy

Identical to [[Clinical Environment Test Runbook]] Part 1 (announce in `#clinical-env-timeshare`,
move `deploy/clinical/<pointer>`, dispatch, confirm the roll). UR runs on the same
`temporal-workers-high`/`-low` deployments in `qh-clinical-platform`.

UR task queues are `utilization-review-lite` and the org-routed queues — visible in
`packages/ur-app/ur_app/definition.json`. Nothing UR-specific to do here beyond confirming the
serving image tag before feeding.

---

## Part 2 — DB / config

`psql` access is exactly as in [[Clinical Environment Test Runbook]] Part 2 (port-forward
`svc/mvp-cloudsqlproxy` in `qh-clinical-customer-qhai`, creds from the `mvp-db` secret, and
**use `-w`**).

The UR composer row, as of 2026-09-18:

```
workflow_code   = utilization-review
workflow_folder = ur_data_ios
workflow_url    = /utilization-report
org_id          = org_hCdKESeaLsROQhVg
temporal_config.conditions_version = 6
temporal_config.input_mapping.external_id = hospital_account_number
```

UR-specific keys worth knowing in `temporal_config`:

- **`conditions_version`** — which guideline corpus version `ur-get-guidelines` reads. If it is
  `NULL` the version is resolved dynamically (`GET /guidelines?page=1&limit=1` ordered
  `created_at DESC`), i.e. whatever was inserted most recently. Clinical pins it.
- **`classifier_config`** — `classifier_version` (`v1` linear score / `v2` rule-based) plus the
  rules. `v2` is production. The rules decide `overall_ai_classification`, so a prompt change that
  moves a signal the rules don't key on will show no classification movement.
- **`input_mapping.external_id`** — names the payload field used as the run's external id. **Missing
  mapping or an empty mapped field fails the run**; it does not fall back to `encounter_id`.

Same rule as the clinic-coding runbook: resolve the row's `id` once, save the whole JSONB as your
rollback, and merge with `||` rather than overwriting.

---

## Part 3 — Prepare & feed test CSV(s)

### 1) The drop folder — and three decoys

```
gs://qhai-com-clinical-composer-data-files/ur_data_ios/
```

`workflow-file-processor` takes `file_path.split("/")[-2]` and reverse-looks-up
`composer_metadata.workflow_folder`. Only `ur_data_ios` resolves.

**Proven, not inferred.** `qhai-com-composer-workflow-file-processor` logs show it ingesting
files from this exact folder, most recently 2026-09-15:

```
Processing CSV file: ur_data_ios/stress_ur_legacy_burst_129_054244.csv
                     in bucket: qhai-com-clinical-composer-data-files
Getting http://mvp-proxy.org-hcdkesealsroqhvg-vpn.private
        /api/v1/workflows/composer_metadata/search  {'workflow_folder': 'ur_data_ios'}
Dataframe loaded with 129 records from file: ur_data_ios/stress_ur_legacy_burst_129_054244.csv
```

"Dataframe loaded with N records" is the success signal — the file was ingested, not skipped.
Check your own round the same way:

```bash
gcloud logging read 'resource.type="cloud_run_revision"
  resource.labels.service_name="qhai-com-composer-workflow-file-processor"
  textPayload:"<your-filename>"' --project=qh-clinical --freshness=30m --limit=20 \
  --format="value(timestamp,textPayload)"
``` The bucket contains three other
UR-looking folders, all dead ends:

| folder | what it actually is |
|---|---|
| `ur_data/` | **no composer row — drops are silently skipped.** Has stale test CSVs in it, which makes it look live. The trap most likely to cost you an afternoon |

> [!note] "oldpath" / "legacy" in those filenames is not a deprecation warning
> `smoke-oldpath-*.csv`, `stress_ur_legacy_burst_*.csv`, `ur-old-path-test-v2.csv` are engineers
> labelling **which of UR's two live ingestion paths they were exercising**, not marking the path
> as dead. Both paths work; see the section below. Use the CSV path for hand-fed tests.
| `ur-temporal/` | composer row exists but `is_deleted = true`. June-2026 CSVs |
| `rcm-utilization-review/` | offloaded artifacts (`refs/<csv>:<row>/note.txt`), not a drop zone |

The folder name is misleading: **`ur_data_ios` serves plain `utilization-review`**, not an "iOS"
variant. There is only one UR composer row on clinical-qhai. (Staging-qhai has a second,
`utilization-review-guidelines`, sharing the same corpus.)

Confirm rather than trust this file:

```sql
SELECT workflow_code, workflow_folder,
       temporal_config->'input_mapping'->>'external_id' AS id_field
  FROM workflows.composer_metadata WHERE is_deleted = false;
```

### 2) Suffix the RIGHT column

The file processor dedups on the **`external_id`-mapped** field, which for UR is
**`hospital_account_number`** — and in the real CSV that is **column 1**, not column 0. Column 0 is
`encounter_id`. The clinic-coding runbook's suffix helper only rewrites `row[0]`; used as-is on a
UR file it suffixes the wrong column and every row silently dedups away.

```python
import csv

def resuffix_ur(src, dst, new_suffix, id_col="hospital_account_number"):
    with open(src, newline="", encoding="utf-8") as f:
        rows = list(csv.reader(f))
    header, body = rows[0], rows[1:]
    i = header.index(id_col)          # resolve by NAME, never by position
    out = [header]
    for row in body:
        row[i] = f'{row[i].split("-", 1)[0]}{new_suffix}'
        out.append(row)
    with open(dst, "w", newline="", encoding="utf-8") as f:
        csv.writer(f).writerows(out)
```

Every round needs a fresh suffix — re-feeding an id is a silent no-op, not an error.

### 3) Columns

UR has **no locked field list** — `URWorkflowInput` only adds the `workflow_code` discriminator to
`BaseWorkflowInput`, whose payload is an open `input_data: dict`. So there is no `_ALLOWED_FIELDS`
to align against; copy the column set from a CSV already working in the drop folder.

The 25 columns in use as of 2026-09-18:

```
encounter_id · hospital_account_number · first_name · last_name · patient_sex ·
patient_dob · patient_age · insurance · original_classification ·
current_classification · note · admission_date · admission_time · bed · unit ·
campus · payer_financial_class · discharge_date_key · fetched_at · max_note_time ·
service_or_team · emergency_dept_on_admission · medication_administration_record ·
lab_results · row_number
```

Coverage to check in any hand-built sample — UR scores three independent axes, and a careless
sample only exercises one:

- **SOI** needs real `note` content. As with clinic coding, don't fabricate notes.
- **LOS** is computed from `admission_date`/`admission_time`/`discharge_date_key`. An all-same-date
  or all-null sample makes `length_of_stay_report.met_status` null and the LOS signal untested.
- **IoS** is read from the note by `ur-intensity-llm`. A sample with no ICU/drip/vent documentation
  will sit at Tier D throughout.
- `original_classification` / `current_classification` are the *incumbent* human decision — useful
  as a comparison column, and worth having both Inpatient and Observation present.

### 4) Upload

```bash
gcloud storage cp <file>.csv gs://qhai-com-clinical-composer-data-files/ur_data_ios/ --project=qh-clinical
gcloud storage ls -l gs://qhai-com-clinical-composer-data-files/ur_data_ios/<file>.csv --project=qh-clinical
```

Expect the same **~3–4 min** drop → dispatch lag as clinic coding. `Duplicate message` in the CF
logs means the suffix did not dodge the dedup.

### 5) Verify

UI: [clinical-chat.qualifiedhealthai.com](https://clinical-chat.qualifiedhealthai.com/) →
`/utilization-report`. The **Severity of Illness** tab has `Met Criteria` / `All Criteria`
sub-tabs; each line renders as `${guideline_number}. ${report}` — note the parent heading from the
guideline is *not* shown, which is the whole subject of QHE-4200.

Field-level, against `workflows.workflow_run`:

```sql
SELECT external_id,
       result_json -> 'guideline_report' -> 'statistics' ->> 'overall_ai_classification' AS classification,
       result_json -> 'guideline_report' -> 'statistics' ->> 'in_patient_confidence'     AS confidence,
       result_json -> 'guideline_report' -> 'statistics' ->> 'overall_criteria_met'      AS criteria_met,
       result_json -> 'guideline_report' -> 'statistics' ->> 'threshold'                 AS threshold,
       result_json -> 'length_of_stay_report' -> 'statistics' ->> 'length_of_stay'       AS los,
       result_json -> 'intensity_of_service_report' -> 'statistics' ->> 'overall_intensity_of_service_tier' AS ios_tier,
       result_json -> '_provenance'                                                      AS provenance
  FROM workflows.workflow_run
 WHERE external_id LIKE '%-<tag>'
 ORDER BY external_id;
```

`result_json IS NOT NULL` means finished; `inputs.state = SUCCESS` only means dispatched.

Per-criterion detail lives in `result_json.guideline_report.guidelines[]` as
`{condition, guideline_number, criterion_met, report, citations}`. **`report` and `citations`
contain verbatim note text** — fine to read in the DB, but do not paste them into tickets, reports
or Notion.

`_provenance` carries `model`, `prompt_version` and `guidelines_version` — the last one is the
corpus version, so it is how you confirm a guideline change was actually picked up. Caveat: an
**in-place** corpus edit leaves the version number unchanged on both sides, so it cannot
distinguish before/after; only a new version can.

---

## UR's second, live ingestion path

UR is one of the few workflows on **both** drop paths. `temp_bucket_dispatch.py` allowlists it
explicitly — `ALLOWED_WORKFLOW_CODES = {"utilization-review"}` — because its code predates the
`rcm-`/`cgo-`/`qr-` prefix convention:

```
gs://qhai-com-clinical-composer-data-files-temp/ur_data_ios/databricks-sync/json/<batch>/<file>.json
```

That path is the **Databricks sync** and was actively receiving data on 2026-09-18. One JSON per
encounter, not CSV, and it goes through a Pub/Sub pull subscriber in temporal-workers rather than
the Cloud Function chain.

**Use the legacy CSV path for hand-fed tests.** The JSON path requires a uuid4 embedded in the
filename as `input_file_id`:

```
959699844_208_efb68dbc-adc7-4397-b458-f746d0d97e4e.json
              └───────── input_file_id (uuid4) ─────────┘
```

If the subscriber cannot recover it, `workflows.inputs.state` sticks at `QUEUED` **forever even
though the run itself succeeds** — a silent failure that reads like nothing was ingested.

---

## Gotchas

- **`ur_data/` is not the drop folder** even though it is the obvious guess and contains recent
  CSVs. No composer row → silently skipped.
- **Suffix `hospital_account_number` (col 1), not col 0.** The clinic-coding suffix snippet rewrites
  `row[0]` and will silently break UR dedup.
- **A guideline-text change needs no deploy** — skip Part 1. Conversely, a code change to
  `ur/ir_csr/**` drags in the mvp-proxy deploy and its `release`-pinned-migration problem.
- `packages/rcm/ur/**` triggers three deploy workflows; match your diff, don't blanket-dispatch.
- UR has **no locked input schema**, so there is nothing to align a narrow eval CSV against —
  copy the columns from a known-good file instead.
- **Check all three axes get exercised** (SOI / LOS / IoS). A sample with uniform dates or no
  high-intensity documentation silently tests only one of them.
- `result_json.guideline_report.guidelines[].report` / `.citations` are **verbatim note text**.
  Encounter ids and HARs are fine to cite; those fields are not.
- Everything generic — timeshare collisions, pointer-branch moves, "green Action ≠ rolled out",
  mid-rollout mixed code, `release` clobbering your pointer, `wc -l` undercounting CSV rows — is in
  [[Clinical Environment Test Runbook]] and applies unchanged.

## Dispatch-chain service names (qhai-com tenant, clinical)

All Cloud Run, all `resource.type="cloud_run_revision"`:

```
qhai-com-composer-workflow-file-processor       <- ingests the CSV; watch this one first
qhai-com-composer-workflow-schedule-processor
qhai-com-composer-workflow-processor
qhai-com-composer-workflow-filters-processor
qhai-com-composer-workflow-result-persister
```

Other tenants follow the same `<tenant>-composer-workflow-*` shape.

## Not yet verified

- Whether `Deploy MVP Service` is ever genuinely needed for a UR change (no `from ur.` import found
  in `services/mvp/app`).
- The `ur_data_ios` folder mapping on **staging** and **prod** clusters; the values above are
  clinical-qhai's. Staging has a second UR composer row (`utilization-review-guidelines`) whose
  folder was not checked.
