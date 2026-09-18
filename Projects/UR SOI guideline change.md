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

### Every cluster, by environment

Full GKE inventory, `gcloud container clusters list` per project, 2026-09-17. **37 clusters across
4 environments.** All are private-endpoint with master authorized networks restricted to the
Tailscale range `100.64.0.0/10`.

**`qh-production`** — 22 customer + 1 platform
```
qh-production-platform
qh-prod-customer-{atria, chn, emory, emory-eu, jefferson, lcmc, mercy-stlouis,
                  nychhc, penn-medicine, qhai, qhai-org, sanfordhealth,
                  university-rochester, urmc, utmb, utsouthwestern,
                  ut-austin, ut-md-anderson, ut-rgv, ut-tyler,
                  uthouston, uthscsa}
```

**`qh-clinical`** — 8 customer + 1 platform
```
qh-clinical-platform
qh-clinical-customer-{chn, emory, mercy-stlouis, penn-medicine, qhai,
                      urmc, uthscsa, utmb}
```

**`qh-staging`** — 2 customer + 1 platform · **`qh-development`** — 1 customer + 1 platform
```
qh-staging-platform      qh-staging-customer-{mercy-stlouis, qhai}
qh-dev-platform          qh-dev-customer-qhai
```

Notes that matter for this change:

- **UTMB exists in clinical *and* production, but only the production one runs UR.** There is **no
  staging utmb cluster at all** — hence the qhai-based ladder.
- The UT system is split fine-grained in production only: `utmb`, `uthscsa`, `uthouston`,
  `ut-austin`, `ut-rgv`, `ut-tyler`, `ut-md-anderson`, `utsouthwestern`. "UTSA" is `uthscsa`.
- `mercy-stlouis` is the only customer besides `qhai` with a staging cluster.
- Guidelines live in **customer** clusters only; the `*-platform` clusters have no `mvp_db`.
- A default `gcloud container clusters get-credentials` writes the **public** master IP into
  kubeconfig and every kubectl call then hangs. Always pass `--internal-ip`.

### Where the script runs — 5 clusters of 37

|                                                                          | count | run the script? |
| ------------------------------------------------------------------------ | ----- | --------------- |
| **Platform clusters** — `qh-{production,clinical,staging,dev}-platform`  | 4     | ❌ **no**        |
| Customer clusters reading v6                                             | 5     | ✅ **yes**       |
| Customer clusters with UR but never given v6 — `prod-emory`, `prod-qhai` | 2     | ❌ no            |
| Customer cluster on v5 — `qh-dev-customer-qhai`                          | 1     | ❌ no            |
| Customer clusters with no `utilization-review` workflow at all           | 25    | ❌ no            |

**Platform clusters carry no guideline data — verified 2026-09-17, not inferred.**
`qh-clinical-platform` and `qh-production-platform` run the `mvp` app but have **zero**
`mvp-proxy` and **zero** `mvp-cloudsqlproxy` pods, so there is no path to an `mvp_db` from them.
`workflows.guidelines` exists only behind `mvp-proxy` in customer clusters.

The five targets:

| env | cluster | syncope-related UR runs | UR runs total | last 30d |
|---|---|---|---|---|
| clinical | `qh-clinical-customer-qhai` | **489** | 85,808 | 5,817 |
| staging | `qh-staging-customer-qhai` | **385** | 134,906 | 107,980 |
| production | `qh-prod-customer-utmb` | **4,308** | 520,918 | 112,110 |
| production | `qh-prod-customer-mercy-stlouis` | not measured | — | — |
| production | `qh-prod-customer-uthscsa` | not measured | — | — |

> [!note] Correction to an earlier assumption in this note
> §5 previously said clinical lacks the volume to measure anything, so staging had to be the
> measurement gate. The counts say otherwise: **clinical-qhai's syncope cohort (489) is slightly
> larger than staging's (385)**, and both are an order of magnitude below prod-utmb's 4,308. So the
> measurement can happen at rung 1; staging becomes a second confirmation on a
> higher-throughput environment rather than the first place anything is measurable. The real cohort
> scale only exists in production.

**Running it on the wrong cluster is safe.** The guard requires exactly one live v6 syncope row;
everywhere else that count is 0 and the script aborts before touching anything. Verified locally
(scenario T4).

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
> **Fixed 2026-09-17** in commit `9a10492` (PR #6310), two guards:
> - **install script** refuses to run while any `%utilization%` workflow has `conditions_version =
>   NULL`; takes `-v allow_dynamic_followers=1` to proceed once decided
> - **cutover script** aborts if any *other* `%utilization%` workflow is pinned at 6. No override —
>   a corpus split between two workflows serving the same screen is never intended

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

## 3. The change — the three I.B. criteria

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

### The amended text

```markdown
- **I.B.** Alternative diagnoses reasonably excluded by initial evaluation, including:
  - **I.B.1.** Seizure ruled out (no postictal confusion lasting > 5 minutes, no tongue biting, no focal neurologic deficit).
  - **I.B.2.** Hypoglycemia ruled out (point-of-care glucose ≥ 70 mg/dL at time of evaluation).
  - **I.B.3.** Intoxication or pharmacologic sedation ruled out as sole cause.
```

Diff: **+ "ruled out" ×3**, **− "or correlated with symptoms"** on I.B.2. Nothing else in
the corpus changes. Applied in place to v6 — see §4.

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

## 4. How to make the change — in place on v6

> [!info] Plan changed 2026-09-17
> This started as "copy the corpus to v7 and cut `conditions_version` over". It is now a **single
> in-place `UPDATE` of one row**. The v7 route is kept in §6 for the reasoning and because the
> guards built for it produced the two fingerprints this approach now asserts.

| option | verdict |
|---|---|
| **A** — `UPDATE` the v6 row in place | ✅ **chosen.** One column of one row. No cutover, no new rows, no config change anywhere — reading v6 is what every affected workflow already does. |
| **B** — full corpus copy to v7 + bump `conditions_version` | ❌ disproportionate to a three-word wording fix, and carries three hazards (below) |
| **C** — v7 containing only the edited row | ❌ **dangerous.** `get_guidelines` fetches by `(conditions, version)` and degrades **silently to `{}`** on a miss — the run still classifies on LOS + IoS. Would strip guidelines from 235 conditions invisibly. |

### What in place avoids

All three were found while building the v7 route, which is why they are worth recording:

- **`utilization-review-guidelines`** is pinned at 6 on `staging-qhai` and shares the corpus — an
  older `composer_metadata` row for the *same* product surface (identical `workflow_display`
  "Utilization Review" and `workflow_url` `/utilization-report`, created 2025-04-23 vs 2025-10-08,
  rank 1 vs 5). A cutover touching only `utilization-review` left it behind on the old corpus.
- Any workflow with **`conditions_version = NULL`** resolves dynamically
  (`get_conditions_version()` → `GET /guidelines?page=1&limit=1` ordered `created_at DESC`) and
  would have auto-followed the new version untested the moment its rows landed —
  `utilization-review-ios` on prod-utmb/prod-qhai, `utilization-review-guidelines` on
  prod-uthscsa/prod-emory.
- **Version numbering is not contiguous** across clusters (prod-utmb has 0–4 and 6; clinical-qhai
  has 1, 5, 6), so no single next number was free everywhere.

None of these exist when the text every workflow already reads is the text that changes.

### What it costs

`ur/transform.py` records `_provenance.guidelines_version`, so **runs from before and after the
edit both report 6**. Provenance cannot separate them, and past runs are not reproducible from the
corpus. Discriminators, in descending reliability:

1. the two md5s — **asserted by the script on both sides**, not merely documented
2. the row's `updated_at`
3. the per-cluster applied date — which, after the changelog trim, has no home in the repo. Track
   it somewhere or it is only recoverable from `updated_at`.

**Consequence for the backtest:** with v7 the comparison was v6 against v7. In place there is no
second version afterwards, so the syncope cohort's baseline **must be exported before the script
runs**. That makes baseline export a new step-2 precondition, not a step-4 activity.

### The script

`packages/rcm/ur/scripts/v6_ib_ruled_out_inplace.sql` — one file, no cutover, no second script.

```
\set ON_ERROR_STOP on
SET client_encoding = 'UTF8'     -- U+2265 lives in the matched literals
BEGIN
  guard    3 accepted states only: reviewed original (apply) / reviewed result
           (no-op) / anything else (abort, naming all three hashes)
  UPDATE   keyed on md5 = 26dde41e... -> 1 row first run, 0 rows thereafter
  assert   md5 = 8c73daf3..., three "ruled out" present, clause absent
COMMIT
```

**Genuinely idempotent**, which the v7 install script could not be — it had to refuse a second run
outright or risk 472 rows. Here a re-run is simply a no-op that still passes its assertions.

| | md5 of the syncope guideline |
|---|---|
| before | `26dde41e09a40c637256d34e0c3674f0` |
| after | `8c73daf316210e278a1f1a67e48454ab` |

Measured on `clinical-qhai` during the v7 dry run; exact on all five clusters because the v6 source
is byte-identical across them.

Rollback: the reverse `UPDATE`, keyed on the post-change md5 so it likewise cannot fire twice.
Full text in the script header.

## 5. Rollout plan — clinical → staging → production

The ladder follows the **qhai** tenant for the lower rungs: `qh-clinical-customer-utmb` has no UR
workflow and only the unused v2 corpus, and there is **no staging utmb cluster at all**. Clinical
and staging qhai both read the same v6, so they are faithful rehearsals.

### Stage 0 — decide scope (blocking, owner decision)

v6 is read by three production tenants — utmb, mercy-stlouis, uthscsa — all carrying the identical
defect. QHE-4200 is labelled `client:utmb` only. Amending one copy makes them diverge.

### Stage 1 — export the backtest baseline ← NEW, and it must come first

In-place editing leaves no second version to compare against. Export the syncope cohort's current
results (per-encounter `I.B.1/.2/.3 criterion_met`, `overall_criteria_met`,
`overall_ai_classification`, `in_patient_confidence`) from staging **before** any cluster is
amended. Miss this and the change is unmeasurable after the fact — the only fallback is filtering
runs by timestamp against the row's `updated_at`.

### Stage 2 — clinical · `qh-clinical-customer-qhai`

Dry run, then apply. Goal is mechanism, not metrics: the guard passes against the real text, md5
lands on `8c73daf3…`, and the UI's Severity of Illness → Met Criteria tab reads
`I.B.1. … Seizure ruled out …`.

### Stage 3 — staging · `qh-staging-customer-qhai` — the measurement gate

Apply, then re-run the syncope cohort and diff against the Stage 1 baseline.

- **Zero** movement outside the syncope cohort — nothing else in the corpus changed, so any
  movement there means the `UPDATE` hit more than it should have (it cannot, being pinned to one
  condition + one md5, but verify rather than assume).
- Expected direction: dropping `or correlated with symptoms` should make `I.B.2` harder to mark met
  where hypoglycemia was symptomatic, so some encounters lose a met criterion. **If nothing moves,
  the model was ignoring the contradictory clause and the change is display-only** — itself a
  finding worth writing down.
- Two artifacts: eval report + changelog, per `docs/EVALUATION.md`.
- Note `utilization-review-guidelines` is also pinned at 6 here, so it picks the change up too —
  with the v7 route it would have been left behind.

### Stage 4 — production

`qh-prod-customer-utmb` first, low-volume window; then mercy-stlouis and uthscsa if Stage 0 scoped
them in. Re-run the HAR from the Slack thread and confirm the UI wording. Watch the syncope cohort
48h against the Stage 3 prediction. Rollback trigger: material divergence → reverse `UPDATE`.

## 6. Execution plan

### 6.1 Files (qh-platform, branch `QHE-4200-ur-soi-ib-ruled-out`, PR #6310)

```
packages/rcm/ur/scripts/v6_ib_ruled_out_inplace.sql   # the whole change
packages/rcm/ur/CHANGELOG.md                          # corpus history entry
```

The v7 pair (`v6_to_v7_guidelines.sql`, `bump_conditions_version_v6_to_v7.sql`) was deleted in
commit `f81a646`. Convention followed: `\set ON_ERROR_STOP on`, `BEGIN`/`COMMIT`,
`DO $$ … RAISE EXCEPTION` guards, header carrying usage + rollback — precedent is
`packages/rcm/clinical_coding/dag/migrate_v0_to_v1.sql`.

### 6.2 Verified runbook — how to execute against a cluster

Every command exercised read-only against `qh-clinical-customer-qhai` on 2026-09-17.

**The script must run in local `psql`, not in a pod.** `mvp-proxy` has Python but **no psql**, and
the script uses the meta-command `\set ON_ERROR_STOP on`, which psycopg2 cannot execute. Local
psql is 15.18, server 15.17 — same major.

```bash
# 0. target the cluster. --internal-ip is MANDATORY: without it kubeconfig gets the
#    public master IP and every kubectl call hangs (authorized networks = Tailscale only).
gcloud container clusters get-credentials qh-clinical-customer-qhai \
  --region us-central1 --project qh-clinical --internal-ip

# 1. credentials from the k8s secret. The DB user is PER-TENANT --
#    qhai-com-postgres here, utmb-postgres on prod-utmb. Never hardcode.
PGUSER=$(kubectl -n qh get secret mvp-db -o jsonpath='{.data.POSTGRES_USER}' | base64 -d)
export PGPASSWORD=$(kubectl -n qh get secret mvp-db -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d)

# 2. port-forward the Cloud SQL proxy (own shell, leave running)
kubectl -n qh port-forward svc/mvp-cloudsqlproxy 5433:5432

# 3. DRY RUN -- exercises the guard, the UPDATE and every assertion, then discards.
#    Free, and it is where a drifted corpus surfaces. Do this on every cluster first.
sed 's/^COMMIT;/ROLLBACK;/' packages/rcm/ur/scripts/v6_ib_ruled_out_inplace.sql \
  | psql -h 127.0.0.1 -p 5433 -U "$PGUSER" -d qh_mvp_db

# 4. for real
psql -h 127.0.0.1 -p 5433 -U "$PGUSER" -d qh_mvp_db \
  -f packages/rcm/ur/scripts/v6_ib_ruled_out_inplace.sql

unset PGPASSWORD
```

A dry run prints `UPDATE 1` and the success `NOTICE`, then `ROLLBACK` — and the two tail SELECTs run
*outside* the rolled-back transaction, so they show the **unamended** text. Expected, not a failure.

Rollback after a real run: the reverse `UPDATE` from the script header, keyed on the post-change
md5. Confirm `md5(guideline)` returns to `26dde41e09a40c637256d34e0c3674f0`.

### 6.3 Merging the PR does not deploy this

The `.sql` is **not** an Alembic migration — nothing runs it automatically. Neither CI gate touches
it (confirmed 2026-09-17): `migration-check.yml` watches only
`services/{api,qh-proxy,qh-apps-proxy}/migrations/versions/**`, and `check_phi_added_lines.py` scans
added **Python** lines only. Commit convention `QHE-4200: …`, base `develop`, no PR template. The
PR description leads with this.

### 6.4 Still blocking — before the production rung

- [ ] **Scope**: utmb only, or all three prod tenants reading v6 (utmb, mercy-stlouis, uthscsa)?
      Amending only utmb's copy makes them diverge on a shared clinical corpus. Owner decision.
- [ ] Does UTMB need to sign off on a clinical-criteria wording change?
- [ ] Where do the per-cluster applied dates live, now that the changelog no longer carries a
      promotion log? Provenance reports 6 on both sides, so that date is a real discriminator.

## 7. Next steps

**Step 1 done** (PR [#6310](https://github.com/Qualified-Health/qh-platform/pull/6310), 7 commits).
Pre-flight and a dry run of the superseded *v7* script passed on clinical-qhai — that is where both
fingerprints came from — but **the in-place script has not been run against any cluster.**

Runs on **5 clusters only**; see §2. Platform clusters are not targets.

### Step 1 — branch, files, commit, PR · ✅ done

- [x] branch `QHE-4200-ur-soi-ib-ruled-out` off `develop`; script + changelog under `packages/rcm/ur/`
- [x] PR against `develop`, leading with "merging does not change any environment"
- [x] v7 pair replaced by the single in-place script (`f81a646`); PR title and body updated
- [x] changelog trimmed to ticket / PR / script / scope / diff (`092ba87`, `39cc851`)
- [x] script trimmed 213 → 146 lines (`c9ffbc0`)

### Step 2 — export the baseline · ⬅ next, and it gates everything after

No second version exists after an in-place edit, so the "before" state must be captured first.

- [ ] export from **both** `clinical-qhai` (489 runs) and `staging-qhai` (385)
- [ ] per encounter: encounter id · `I.B.1/.2/.3 criterion_met` ·
      `overall_criteria_met` · `met_status` · `threshold` · `overall_ai_classification` ·
      `in_patient_confidence` · plus the LOS and IoS reports as a **control** (neither should move)
- [ ] **exclude** `report`, `citations`, `source_quote` — verbatim note text, i.e. PHI. Encounter
      ids are fine and are the join key
- [ ] local only — not git, not GCS

### Step 3 — apply on clinical-qhai

- [ ] `get-credentials … --internal-ip`; creds from the `mvp-db` secret (user `qhai-com-postgres`)
- [ ] port-forward `svc/mvp-cloudsqlproxy 5433:5432`
- [ ] **dry run** — `sed 's/^COMMIT;/ROLLBACK;/'`; expect `UPDATE 1` + success `NOTICE` + `ROLLBACK`,
      and the tail SELECT showing the *unamended* text
- [ ] apply for real; a clean exit is the verification — the script asserts the result md5
- [ ] confirm `md5(guideline)` = `8c73daf316210e278a1f1a67e48454ab`
- [ ] record the applied date for this cluster (§6.4 — no promotion log in the changelog any more)

### Step 4 — verify clinical, two things

- [ ] **UI**: one syncope encounter through UR; Met Criteria reads `I.B.1. … Seizure ruled out …`
- [ ] **measurement**: re-run the 489-encounter cohort, diff per encounter against the Step 2
      baseline. This is now possible at rung 1 — see the correction in §2
- [ ] `_provenance.guidelines_version` still reports **6** — expected, and exactly why the applied
      date matters

### Step 5 — apply on staging-qhai + second measurement

- [ ] same runbook; re-run the 385-encounter cohort against its baseline
- [ ] **zero** movement outside the syncope cohort — nothing else in the corpus changed
- [ ] additional check unique to this cluster: `utilization-review-guidelines` is also pinned at 6,
      so confirm its output moves too. The v7 route would have left it on the old corpus
- [ ] two artifacts: eval report + changelog, per `docs/EVALUATION.md`

### Step 6 — scope decision · blocks production

- [ ] utmb only, or also `prod-mercy-stlouis` and `prod-uthscsa`? All three read the same v6 and
      carry the identical defect; QHE-4200 is labelled `client:utmb` only
- [ ] does UTMB need to sign off on a clinical-criteria wording change?

### Step 7 — apply on prod-utmb

- [ ] low-volume window
- [ ] re-run the HAR from the Slack thread; confirm the UI wording
- [ ] watch the 4,308-encounter cohort for 48h against the Step 4/5 prediction — **this is the only
      rung with real cohort scale**
- [ ] rollback trigger: material divergence → reverse `UPDATE` (script header)

### Step 8 — remaining production tenants, if scoped in

- [ ] `prod-mercy-stlouis`, `prod-uthscsa` — same runbook, same verification

### Step 9 — close out

- [ ] per-cluster applied dates recorded somewhere durable
- [ ] eval report + changelog published per `docs/EVALUATION.md`
- [ ] QHE-4200 closed, noting I.B.3 went beyond the ticket's stated scope, and that both reported
      issues are addressed

### Expected result, so it is on record before measuring

Dropping `or correlated with symptoms` should make `I.B.2` **harder** to mark met where hypoglycemia
was symptomatic, so some encounters lose a met criterion and a few may change classification.
**If nothing moves at all, the model was ignoring the contradictory clause and this change is
display-only** — a legitimate finding, not a failed rollout. Write it down either way.

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
- **2026-09-17** — Re-swept all 33 customer clusters matching `workflow_code LIKE '%utilization%'`
  instead of the exact string; found two sibling workflows the first pass missed
  (`utilization-review-guidelines`, `utilization-review-ios`) and, with them, a silent split-state
  bug in the cutover script. Added both guards, commit `9a10492`, pushed to PR #6310.
  **Validated the scripts end-to-end against a throwaway local PostgreSQL 15** with the real table
  shapes and a 236-row fixture corpus — seven scenarios, all passing (clean install; re-run
  refused; cutover; null sibling refused with rollback leaving 0 v7 rows; null sibling accepted
  under override; sibling pinned at 6 refused with cv left at 6; sibling repinned then cutover
  clean). Confirmed the reworded I.B. block character-for-character in the resulting v7 row.
  Still not run against any real cluster. PR body's Testing section updated to match.
- **2026-09-17** — Reviewed PR #6310 feedback (automated review, no human reviewers yet;
  verdict *approve with changes*). CI: the only real failure was **Require Jira ticket(s) in PR** —
  `pr-jira-check.yml` requires every Jira key in the body to also appear in the title, and the body
  cited epic QHE-3877. Reworded to name the epic without its key; now passing. The 2842
  "vulnerabilities" in the push output are repo-wide dependabot debt on **develop**, not from this
  PR — it adds only `.sql`/`.md`, and all five Wiz scanners pass.
  Took three findings (commit `39b1c14`): pin `client_encoding = 'UTF8'` (the `≥` in the
  `replace()` literals would silently no-op under another encoding), print `md5(v7 syncope)` as a
  cross-cluster fingerprint, and split the rollback guidance by stage (the old `DELETE … version = 7`
  read as unconditional but destroys the live corpus post-cutover). Declined "assert which
  guideline changed" — already implied by the existing assertions. Trimmed `CHANGELOG.md` 237→84
  lines (commit `2acffe8`); the polarity rule + lint were briefly moved to `packages/rcm/ur/CLAUDE.md`
  and then **removed at the user's request**, so the PR touches no `CLAUDE.md`. Those now live only
  in this note — if the guardrail should be shared with guideline authors it still needs a home in
  the repo.
- **2026-09-17** — Rollback guidance switched from hard `DELETE` to soft delete (commit `cb88649`). Prompted by asking whether the dry run is really non-destructive: **ROLLBACK is not a
  delete** (an uncommitted INSERT never becomes visible, so no DELETE privilege is involved) — but
  the question surfaced that `workflows.guidelines` soft-deletes by convention (712 `is_deleted`
  rows on clinical-qhai) and every read path filters it. The role does hold DELETE/TRUNCATE, so the
  old recipe worked; it was just irreversible at exactly the point the guidance already has to warn
  about stage confusion. Validated the full round trip locally.
- **2026-09-17** — **Ran 2a + 2b on `qh-clinical-customer-qhai`. Nothing was committed.**
  Pre-flight: a single UR workflow (`utilization-review`, cv=6), so neither sibling guard applies
  on this cluster; v6 = 236 live, version 7 = 0 in any state, target md5 matches.
  ROLLBACK dry run: all four pre-asserts and all four post-asserts passed **against the real
  corpus** — the md5 guard's first real test — `INSERT 0 236`, then discarded. Post-checks confirm
  version 7 = 0 rows, `conditions_version` = 6, v6 md5 unchanged.
  **v7 fingerprint is `8c73daf316210e278a1f1a67e48454ab`**; recorded in `CHANGELOG.md`
  (commit `b4a0b2e`) alongside the v6 source hash, since the rewrite is deterministic and all five
  target clusters share the v6 source byte-for-byte — a cluster printing a different v7 md5 did not
  apply the same change.
- **2026-09-17** — **Plan changed to an in-place amendment of v6**; both v7 scripts deleted,
  replaced by `v6_ib_ruled_out_inplace.sql` (commit `f81a646`, PR #6310, title and body updated).
  In place removes the three hazards the v7 route had to carry — the `utilization-review-guidelines`
  split state on staging-qhai, the `conditions_version = NULL` auto-followers, and non-contiguous
  version numbering — because the text every workflow already reads is the text that changes. It
  also allows genuine idempotency: the `UPDATE` is keyed on the pre-change md5, so a re-run is a
  clean no-op rather than a refusal. Both fingerprints are now **asserted**, not documented.
  Cost: provenance reports `guidelines_version = 6` on both sides, so the backtest baseline must be
  exported **before** anything is applied — that is now step 2 and it gates the rest. Validated
  locally across five scenarios. Changelog trimmed twice at the user's request (`092ba87`,
  `39cc851`) and now ends at the diff; rationale lives in the script header. Note §3–§7 rewritten
  to match.
