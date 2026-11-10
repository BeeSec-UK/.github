---
plan: runner-labels
---

# Runner labels: beesec-linux to beesec-dev, preflight to beesec-preflight

The operator renamed the fleet's runner labels on 25 Oct 2026. GTX-Dev's four runners took `beesec-dev`, and the Pi's two took `beesec-preflight`. Both old and new labels stay on the runners until every workflow has moved, so no job queues without a runner. This plan records what has moved, what is left, and the step that removes the old labels. It was written on 30 Oct 2026, after the first package had already merged, so that the track has a package table that hive can read.

## Where it stands

Read from each private repository's default branch on 30 Oct 2026:

- **Moved:** this repository's `beesec-app.yml`, which defaults to `["beesec-dev"]` (#28, merged 26 Oct). The callers took the new label with it.
- **Still on `beesec-linux`:**
  - beesec-factory: `ci.yml` (4 jobs) and `ping.yml` (1). Its PR is beesec-factory#49.
  - apitoxin: `pipeline.yml` (4). Its PR is apitoxin#116.
  - pollen: `azure-static-web-apps.yml` (3). No PR yet.
  - orchestrator: `inventory-tests.yml` on main, and `programme-to-hive.yml` on the working branch. No PR yet.
- **Still on `preflight`:** none found.
- **Not part of this rename:** `gtx-host` and `desktop-bindings`, used by swarm and queen, name what a runner can do rather than which fleet it is in. They stay. `[drone]` and `beesec-prod` are the prod runners, which are outside this plan.

## Execution plan

| Id | Outcome | Depends on | Owner | Model | Hours | Tokens | Gate on dev |
|---|---|---|---|---|---|---|---|
| RL-1 | `beesec-app.yml` and this repository's jobs move to `beesec-dev` and `beesec-preflight` | none | github-1 | Opus | 0.5 | 1 M | Done: #28 merged 26 Oct, and caller runs since then picked up on `gtx-dev-*` |
| RL-2 | beesec-factory moves: `ci.yml` and `ping.yml` | none | beesec-factory chat | Opus | 0.5 | 1 M | beesec-factory#49 merged, and the next `ci.yml` run's "Set up job" shows `beesec-dev` |
| RL-3 | apitoxin moves: `pipeline.yml` | none | apitoxin chat | Opus | 0.5 | 1 M | apitoxin#116 merged, and the next PR run picks up on a `gtx-dev-*` runner |
| RL-4 | pollen moves: `azure-static-web-apps.yml` | pollen#10 | github-1 | Opus | 0.5 | 1 M | Its PR merged, and the next PR run picks up on a `gtx-dev-*` runner |
| RL-5 | orchestrator moves: `inventory-tests.yml`, and `programme-to-hive.yml` as part of HV-PIPE's HP-3, which picks its runner under HV-PIPE D7 | HP-3 for the second file | github-1 | Opus | 0.5 | 1 M | Its PR merged, and the next run picks up on the new label |
| RL-6 | Check that nothing still asks for an old label: no default-branch workflow in any private repository names `beesec-linux` or `preflight`, and no queued job asks for either for a week | RL-2 to RL-5 | github-1 | Opus | 0.5 | 1 M | The scan returns nothing, and the org's queued runs over seven days show no old label |
| RL-7 | The old labels come off the six runners | RL-6, operator go | operator | – | 0.5 | 0 M | `gh api orgs/BeeSec-UK/actions/runners` lists no `beesec-linux` or `preflight`, and a dispatch in each moved repository is picked up |

That is 3.5 hours and 6 M tokens.

## Decisions

| # | Question | Lean | Answer |
|---|---|---|---|
| D1 | Do `gtx-host` and `desktop-bindings` come off too? | No. They say what a runner can do, swarm's desktop tests need them, and the 25 Oct rename did not cover them | |
| D2 | Who removes the old labels in RL-7? | The operator. It changes the runners' registration, which is a permission change on the fleet | |
