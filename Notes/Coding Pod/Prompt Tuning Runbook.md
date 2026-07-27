---
updated: 2026-07-27
tags: [runbook, coding-pod]
---
# Prompt Tuning a Workflow

Reference: <coding-ai-harness repo README / eval docs — add link>

How to change an LLM prompt to fix a defect **without introducing regressions**:
validate the prompt change offline in the eval harness first, then ship it through the
exact same deploy/test path as any logic change. A prompt edit is a behavior change —
it gets the full clinical + staging validation, not a shortcut.

## When to use
A prompt is producing wrong output on some cases (e.g. an MDM-level or E&M-code miss) and
you want to tune it. Use this instead of hand-testing one case — the harness proves the
fix *and* guards the rest of the benchmark set from regressing.

## Prerequisites
- `coding-ai-harness` repo cloned and runnable locally, with access to the benchmark
  dataset (e.g. `v1_benchmark`) and its auditor ground truth.
- The failing case(s) identified — ideally already in (or added to) the benchmark set.
- Write access to `qh-platform` (PR) and the clinical/staging deploy paths.
- Access to the Notion "coding reports" area.

## Steps

### 1) Validate the prompt change offline in `coding-ai-harness`
Apply the prompt change via `--patch` and run the benchmark. Confirm **both**: the failing
cases now pass, **and** no previously-passing case regresses.
```bash
# <confirm exact invocation from the harness README>
<harness-cmd> --patch <prompt-patch> --dataset v1_benchmark
```
- The failing encounters flip to correct against auditor ground truth.
- Diff the full benchmark result vs. the pre-patch baseline — every other case must be
  unchanged (no net-new failures). Record the before/after numbers for the report (step 4).
- Make sure the benchmark set actually exercises the relevant branches (e.g. New vs.
  Established, documented-time buckets) — a fix that only helps one branch isn't validated.

### 2) Open a PR in `qh-platform`
Land the prompt change as a normal PR against `develop`, same review bar as any code change.
Include the harness before/after numbers in the PR description as evidence.

### 3) Deploy & validate through the standard path
A prompt change follows the **same deployment logic as a logic change** — both env tests:
- **Clinical env test** → [[Clinical Environment Test Runbook]]
- **Staging test** (cherry-pick to `release`) → [[Cherry-pick Runbook]]

Run clinical first to validate end-to-end on the real pipeline, then staging as part of
getting it toward release. Reuse a fresh id-column suffix per round (see those runbooks).

### 4) Write the change up in Notion
Create a note under the **coding reports** path documenting:
- The defect and root cause.
- The prompt change (before → after).
- Harness results (benchmark before/after, cases fixed, regression check).
- Clinical + staging validation results (tags/encounters tested).
- Linked JIRA ticket and PR.

## Verify
- Harness: target cases pass, zero regressions vs. baseline.
- Clinical + staging: tuned output matches expectations for the repro encounters, no
  regression on the broader set.
- Notion report published and linked from the JIRA ticket.

## Rollback
- Not yet merged: close the PR — nothing deployed.
- Merged and bad: revert the PR on `develop` and re-run the standard deploy path; on
  `release`/clinical, roll back per the [[Cherry-pick Runbook]] / [[Clinical Environment Test Runbook]]
  rollback steps (revert PR / restore the pointer branch).

## Related
- [[Coding Pod]]
- [[Clinical Environment Test Runbook]]
- [[Cherry-pick Runbook]]
