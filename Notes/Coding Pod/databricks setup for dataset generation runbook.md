---
updated: 2026-09-23
tags: [runbook, coding-pod, databricks, datasets]
---
# Databricks Setup for Dataset Generation

Reference: `coding-ai-harness` → `clinic/build_dataset_dbx.py`, `docs/DATASETS.md`, `.env.example`

`clinic.build_dataset_dbx` builds a dataset **without a pre-exported CSV**: it takes the
(MRN, DOS) pairs off a review workbook and pulls `input.csv` — the note blobs — live from
the clinical warehouse. That needs warehouse credentials. This is how to get them, which
route to pick, and how to tell which one is failing.

Ground truth still comes from the spreadsheet. **Only the notes come from Databricks.**

## When to use

- Building a new clinic dataset from a client feedback / ground-truth workbook.
- `build_dataset_dbx` fails with `missing Databricks endpoint config` or
  `Invalid access token`.
- Your PAT expired (it will — see *Pick a route* below).

Not needed to **run** an experiment against an already-built dataset, or for ED, which
builds from a CSV and touches Databricks not at all.

## Prerequisites

- `coding-ai-harness` cloned, `scripts/setup-env.sh` run, `source scripts/env.sh` working.
- Access to the Azure Databricks workspace holding `mercy_standard.clinic_coding`.
- `databricks-sql-connector` + `databricks-sdk` installed (they are declared in
  `pyproject.toml`; `setup-env.sh` brings them in).

---

## The four variables

All live in **this repo's `.env.secrets`** (gitignored; names documented in
`.env.example`).

> [!warning] Not in `qh-platform/.env.local.secrets`
> `build_dataset_dbx` will still read that file as a fallback, but **that filename is
> matched by none of qh-platform's `.gitignore` rules** (`**/.env.local` and
> `.env.secrets` both miss it), so credentials left there are one `git add -A` from being
> committed to the prod repo. Use the harness's own `.env.secrets`.

| variable | secret? | required |
|---|---|---|
| `CLINICAL_DBX_HOST` | no | **always** |
| `CLINICAL_DBX_HTTP_PATH` | no | **always** |
| `CLINICAL_DBX_TOKEN` | **yes** | PAT route |
| `CLINICAL_DBX_AUTH` | no | browser-OAuth route only |

### Endpoint config (not secret)

Both come from **SQL Warehouses → your warehouse → Connection details**:

- `CLINICAL_DBX_HOST` ← "Server hostname". Bare hostname, **no `https://`** — the
  validator rejects a value containing `://`. It is also just the domain of any workspace
  URL you are logged into.
- `CLINICAL_DBX_HTTP_PATH` ← "HTTP path", of the form `/sql/1.0/warehouses/<id>`.

Current values for the Mercy workspace (safe to paste, these are not secrets):

```bash
CLINICAL_DBX_HOST=adb-98428946577281.1.azuredatabricks.net
CLINICAL_DBX_HTTP_PATH=/sql/1.0/warehouses/0b48b044cb527ab0
```

---

## Pick a route

`_connect()` tries three, in this order:

1. **OAuth M2M** — `CLINICAL_DBX_CLIENT_ID` + `CLINICAL_DBX_CLIENT_SECRET`, a *service
   principal*. Most durable, but minting the secret generally needs workspace admin.
2. **PAT** — `CLINICAL_DBX_TOKEN`. Self-serve, authenticates as *you*, **and expires**.
3. **Browser OAuth (U2M)** — same identity as your PAT, nothing to mint, nothing to
   expire. Needs an interactive terminal. Reached automatically when no other credential
   exists, or forced with `CLINICAL_DBX_AUTH=azure-oauth`.

> [!tip] If you are doing this repeatedly, use route 3
> The PAT route's default lifetime is **14 days**, and the failure mode is a confusing
> `Invalid access token` weeks later on a command that used to work. Browser OAuth has
> nothing to expire. The only reason to prefer a PAT is unattended runs — an agent or a
> cron job cannot complete a browser login.

Routes 1 and 2 are also **different identities**, which matters for grants: a table shared
with named users is readable by their PATs and not necessarily by a service principal. If
one route is denied, try the other before concluding there is no access.

### Route 2 — mint a PAT

**avatar (top right) → Settings → Developer → Access tokens → Generate new token.**

- **Scope: `BI Tools`** if prompted. That is the SQL-warehouse / Thrift endpoint the
  connector speaks; the builder issues one SQL query and makes no REST calls, so
  `Other APIs` is unnecessary.
- **Set a long lifetime.** The default is short and is the usual cause of breakage.

Write it without it landing in shell history or a chat log:

```bash
cd ~/workspace/coding-ai-harness && .venv/bin/python -c "
import getpass, pathlib
p = pathlib.Path('.env.secrets'); t = getpass.getpass('token: ').strip()
ls = p.read_text().splitlines(True)
p.write_text(''.join('CLINICAL_DBX_TOKEN=' + t + '\n' if l.startswith('CLINICAL_DBX_TOKEN=') else l for l in ls))
print('wrote', len(t), 'chars')
"
```

### Route 3 — browser OAuth

```bash
export CLINICAL_DBX_AUTH=azure-oauth
```

Setting the variable is only necessary **because a stale `CLINICAL_DBX_TOKEN` would
otherwise win** — routes are tried in order and a dead PAT shadows a working login. With
no token present at all, route 3 is chosen automatically.

---

## Verify before you build

One query, no side effects. Do this rather than discovering the problem partway through a
paid run:

```bash
cd ~/workspace/coding-ai-harness && source scripts/env.sh
PYTHONPATH=. $PY -c "
from clinic import build_dataset_dbx as B
with B._connect().cursor() as c:
    c.execute('SELECT current_user(), current_date()')
    print('OK —', c.fetchall()[0])
"
```

Prints the identity you authenticated as, which is worth reading: it tells you *which*
route won, and grants are per-identity.

### Reading the failures

| message | meaning | fix |
|---|---|---|
| `missing Databricks endpoint config: …` | HOST/HTTP_PATH unset | set them, above |
| `Invalid access token` | PAT expired or wrong | mint a new one, or use route 3 |
| `INSUFFICIENT_PERMISSIONS … does not have SELECT on Table` | authenticated fine, no grant on **that table** | see below |
| hangs with no prompt | route 3 in a non-interactive shell | run it from a real terminal |

> [!note] `SELECT` is per-table, and the two clinic source tables differ
> `mercy_standard.clinic_coding.silver_clinic_coding` is what `build_dataset_dbx` uses.
> `v1_benchmark` and `clinic/build_dataset.py` use a **different** table,
> `dbw_prod_mercy.clinical_coding_asst.clinic_coding_extract_v1_test`, and a token with
> access to one may have none on the other. Encounters from the older batches
> (`6.1.26 Worksheet`, `Clinic_Pro_Coding_Primary`) exist **only** in the second table —
> they resolve 0/198 against silver, which looks like a date-matching bug and is not one.

---

## Then build

```bash
cd ~/workspace/coding-ai-harness && source scripts/env.sh
PYTHONPATH=. $PY -m clinic.build_dataset_dbx \
    --name <dataset-name> \
    --gt-sheet "Consolidated Ground Truth" \
    --source "QH Updated Logic 8.20.26.xslx" \
    --xlsx /path/to/workbook.xlsx
```

- `--gt-sheet` picks a layout from `SHEET_SPECS` / `CONSOLIDATED_SPECS`. Successive client
  batches arrive shaped differently; **adding a batch means adding a spec, not editing the
  shared parsing code.**
- `--source` (repeatable) narrows a consolidated sheet to specific `Source` batches.
- `--single-dos-fallback` resolves a date mismatch when the MRN has exactly **one**
  encounter in silver. Refuses when it has several — picking the nearest would be
  inventing a match.
- `--exact-dos` disables all date reconciliation: only encounters whose date silver
  confirms directly.

Then, **as the last step of any run that adds cache** (per `CLAUDE.md`):

```bash
scripts/sync_data.sh push
```

> [!warning] A `--fresh` experiment run's cache is **not** covered by that
> `sync_data.sh` syncs `<product>/dataset/` only. `run_exp.py --fresh` writes its model
> I/O into `<slug>/.ns/`, under `experiments/`, which is neither committed nor synced —
> so those paid calls exist on one machine only.

## Gotchas

- **Dates in these workbooks are unreliable.** The Consolidated tab's DOS has run ~5 days
  earlier than silver's `contact_date` on a whole batch. `build_dataset_dbx` reconciles
  via a sibling tab / single-encounter fallback / an explicit `MANUAL_DOS` map, and
  records the original in `gt.csv`'s `dos_on_gt_sheet`. Check that column after a build.
- **Schema-valid does not mean the notes are real.** `core.dataset.check_note_content`
  runs automatically and catches an extract whose resolved note came back empty. Read its
  line in the build output.
- **`Invalid access token` is not always the token.** A revoked *user* produces the same
  error as an expired token. `SELECT current_user()` distinguishes them.
