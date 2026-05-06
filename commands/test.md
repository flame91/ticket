# /test — change-scoped protective tests

Based on the current changes or the specified issue, add the smallest valid test set or draft a verification plan.

> **Tip:** When implementing a new feature, consider `/tdd` first (Red-Green-Refactor workflow). `/test` is suited to deciding regression-test scope for existing changes.

## Step 0: load project config

Read `.claude/project.json` from the repo root. If absent, use the defaults:
- `scripts.regression`: `null` (without a regression script, auto-detect the test framework)

## Execution order

1. Identify the core behavior of the current diff or the target issue
2. Prioritize tests by the branches with highest regression risk
3. For frontend, focus on state branching and core rendering; for backend, on contract / authorization / aggregation; for data work, on re-runnability
4. Reuse the existing test structure first; introduce only the minimal new structure when none exists
5. If `scripts.regression` is set, run regression tests via that script. Otherwise auto-detect the project test framework (pytest, jest, vitest, etc.) and run it.
6. If runnable tests exist, also confirm the result. Otherwise explain why they are needed.

## Notes

- Do not expand scope into large test-infrastructure work unrelated to the changes
- Report no-test status on a core user flow as an explicit risk
