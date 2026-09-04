---
created: 2026-09-04
tags: [coding-pod, clinic-coding, release, cherry-pick]
---

# Cherry-pick Plan — Clinic V1.3 + `llm_raw` → `release`

Follows [[Cherry-pick Runbook]]. This note is only the **case-specific** parts: what to
pick, the ordering constraint, the pre-verification result, and the clinic-specific
acceptance criteria for the staging round. Procedure, conventions, approval flow and
gotchas all live in the runbook — don't duplicate them here.

## What gets picked

Both PRs are **already squash-merged to `develop`** and approved; neither is on `release`.

| order | squash commit on `develop` | PR | ticket | files | diff |
|---|---|---|---|---|---|
| 1 | `cf462bb410ca` | [#5896](https://github.com/Qualified-Health/qh-platform/pull/5896) | QHE-3555 | 13 | +670 / −37 |
| 2 | `518681aafb16` | [#5907](https://github.com/Qualified-Health/qh-platform/pull/5907) | QHE-3012 | 13 | +554 / −34 |

**Order is not optional.** #5907 was authored on top of #5896 — `cf462bb410ca` is an
ancestor of `518681aafb16^` — so its diff already assumes V1.3 is present. Picking 5907
first conflicts in the 4 files they share (`clinical_coding_v1_activities.py`,
`clinic_verifier_scoring_activity.py` and their two test files).

### One combined PR, not two

The runbook's naming convention is per-PR (`cherry-pick/pr<PR#>-release`). Here the two
commits are **dependent**, so splitting them means merging 5896 to `release` and waiting
for approval before 5907 can even be picked cleanly — two approval cycles for one
shippable unit. `release` history already has precedent for combined picks, e.g.
`feat(icd-finder-v3): … [cherry-pick #5834 #5913 #5929] (#5926)`.

```
branch: cherry-pick/pr5896-pr5907-release
title:  QHE-3555 QHE-3012: clinic coding V1.3 + per-encounter llm_raw (cherry-pick to release)
body:   Cherry-pick of #5896 and #5907 for staging validation. Order matters — #5907 is
        authored on top of #5896.
```

If a code owner would rather review them separately, fall back to two sequential PRs in
the runbook's exact convention (`cherry-pick/pr5896-release` merged first, then
`cherry-pick/pr5907-release`).

## Pre-verified — 2026-09-04

Real `git cherry-pick` in a scratch worktree off `origin/release`:

- `cf462bb410ca` → **0 conflicts**; `518681aafb16` on top → **0 conflicts**
- `packages/rcm/clinical_coding`: **498 passed**
- `temporal-workers` clinic + rcm: **142 passed**
- `PROMPT_VERSION` = `1.3`; prompt sha256 `633ef00431a2b2f7` (byte-identical to the
  validated `editB-H2H3inj` patch)
- `DEFAULT_POLICY` = `POLICY_CONSENSUS_OR_CORROBORATED`
- Coexists with `release`'s own `facility_scoring_enabled` hoist in
  `rcm_dag_activities.py` — the only place the two lines of work touch, and additive
- `llm_repro.py`, `template_v1.json`, `temporal_config_v1.json` already on `release`, so
  no prerequisite is missing

> Don't predict this with `git merge-tree A B` — it does a full branch merge and reports
> ~74 conflicts from unrelated `client/` renames. Only a real cherry-pick is meaningful.

`release` moves fast (runbook gotcha), so re-run the dry-run if this sits more than a day.

## Staging round — clinic-specific bits

Procedure: [[Cherry-pick Runbook]] Part 2. What's different for these two PRs:

### The DB steps are NOT optional on staging

Deploying the code alone turns **neither** feature on — both are gated on per-composer DB
state, and the DB value overrides the shipped default. Resolve the **staging** composer id
first (the runbook's worked example used `d19245cb-e6f1-4d2a-b4a5-999d2f8c6b09`; re-resolve,
don't assume — and it is *not* the clinical one).

1. **Abstention** — `migrate_v0_to_v1.sql` already wrote `abstention_enabled: false` /
   `abstention_policy: "qh_high"` into the composer row, which **overrides** #5896's new
   `DEFAULT_POLICY`. Without this the gate stays off with the old policy:
   ```sql
   UPDATE workflows.composer_metadata
      SET temporal_config = temporal_config
          || '{"abstention_enabled": true, "abstention_policy": "consensus_or_corroborated"}'::jsonb,
          updated_at = now()
    WHERE id = '<staging composer id>';   -- expect exactly 1 row
   ```
   Read **at dispatch** — set before feeding. Diff the full JSONB and check the key count
   is unchanged.

2. **DAG template reseed** — #5907 gives the terminal `transform-clinical-coding-v1` node
   an 8th `arg_keys` entry (`verifier_raw`) plus an inbound edge from
   `clinic-verifier-scoring`. Re-run
   `packages/rcm/clinical_coding/dag/migrate_v0_to_v1.sql` (re-runnable — inserts a new
   `dag_templates` version and swaps the mapping).

   Backward compatible without it: `verifier_raw` → `None`, extract records still
   populate, only the verifier stage is missing from `llm_raw`.

> **`arg_keys` resolve positionally** — the DAG passes exactly `len(arg_keys)` positional
> args. Deploy the code **before** reseeding, never the reverse, and restore the template
> if you roll the code back.

### Acceptance criteria

Query `workflows.workflow_run` for the suffixed ids (runbook Part 2 step 5):

| check | expected |
|---|---|
| `result_json->>'ai_professional_code'` | matches the encounter's auditor GT |
| `result_json->'abstention'->>'policy'` | `consensus_or_corroborated` (**not** `qh_high`, not `SKIPPED`) |
| `result_json->'abstention'->>'verdict'` | `AUTO_ACCEPTED` or `NEEDS_REVIEW` |
| `abstention.gpt_error` / `gemini_error` | both `null` — proves both verifiers ran |
| `result_json->'llm_raw'` keys | `clinic-extract` (`vote_1..3`) **and** `clinic-verifier-scoring` (`em`) |
| every `llm_raw` record | `prompt_version = "1.3"`, `error: null`, `usage` + `params` populated |

`llm_raw` carries model narrative and thinking over a real chart — keep it out of tickets
and Notion; cite encounter ids only.

Reference result from the `clinical` env (encounter `962495324`, 2026-09-03): `em=99214`,
`qh=99214 / gpt=99213 / gemini=99214`, `confidence=HIGH` → `AUTO_ACCEPTED`. Under the old
`unanimous` policy that encounter would have been **rejected** — that is the coverage this
recovers, and it's the single best case to re-confirm on staging.

## Risks / call-outs

- **`PROMPT_VERSION` 1.3 goes live for clinic coding** — a real behaviour change, not
  instrumentation. Measured across 3 fresh draws each: 177-set em trailing **90.0** (stock
  90.2), v1_benchmark **92.1** (stock 92.6). i.e. **the prompt edits showed no measured
  gain on either dataset**; the headline 91.1 rested on one outlier draw. State this
  plainly in the cherry-pick PR body so nobody promotes it expecting the prompt to be the
  win — the win is the abstention policy.
- **`consensus_or_corroborated` becomes the clinic default** once the DB write lands. Live
  gate on the 177 set: **88.4% coverage / 94.7% accepted accuracy** (3 draws).
- **Verifier cost** — the new policy runs *both* verifiers (GPT-5.4 + Gemini) on every
  encounter, where `qh_high` ran none and `claude_gpt` ran one. ~$1.01/encounter.
- **Merging to `release` also auto-deploys `clinical`**, not just staging —
  `set-environment` maps `release` → `["clinical","staging"]`. Check
  `#clinical-env-timeshare` before merging in case someone is mid-test there; a `release`
  push silently clobbers a pointer-branch deploy (see [[Clinical Environment Test Runbook]]).
- **`release` → prod is a separate decision** (runbook gotcha: landing on `release` only
  gets it to staging early). Note `release` currently carries the icd-v3 migration chain
  whose introducing commit was titled "REVERT BEFORE MERGING TO PROD", later reverted in
  `d2fab6253a` — unrelated to these PRs, but confirm the chain state before promoting.

## Status / log

- **2026-09-04** — plan written against [[Cherry-pick Runbook]]. Dry-run verified clean
  (0 conflicts on both commits, 498 + 142 tests pass, invariants hold). **Not yet branched,
  pushed or PR'd.**
