# Execution plan: stinger

## Goal

Text about goal.

## Plan

Text about plan.

## Costing

Text about costing.

## Work packages

| ID | Outcome | Depends on | Owner | Model | Hours | Tokens (M) | Gate on dev | State |
|---|---|---|---|---|---|---|---|---|
| ST-1 | The admin list reads from the shared gate | – | stinger chat | Opus 5.5 | 3 | 6 | /admin lists staff on stinger-dev | in_review |
| ST-2 | Approvals are logged | ST-1 | stinger chat | Fable 5.1 | 2 | 2 | /audit shows the approval | blocked |
| ST-3 | Release notes | ST-1, ST-2 | operator | – | 0.5 | 0 | notes on the release | done |

## Plan coverage

Text about plan coverage.

## Goal coverage

Text about goal coverage.

## Route to prod

Text about route to prod.

## Dependencies outside this project

Text about dependencies outside this project.

## Decisions

Text about decisions.

## Risks

| Risk | Package |
|---|---|
| the gate moves | ST-1 |

### ST-1. The admin list reads from the shared gate

**Why this model:** something for ST-1.

**Depends on:** something for ST-1.

**Gate on dev:** something for ST-1.

**Done when:** something for ST-1.

**Build prompt:**

```text
You are building ST-1.
## Not a section heading
```

### ST-2. Approvals are logged

**Why this model:** something for ST-2.

**Depends on:** something for ST-2.

**Gate on dev:** something for ST-2.

**Done when:** something for ST-2.

**Build prompt:**

```text
You are building ST-2.
## Not a section heading
```

### ST-3. Release notes

**Why this model:** something for ST-3.

**Depends on:** something for ST-3.

**Gate on dev:** something for ST-3.

**Done when:** something for ST-3.

**Build prompt:**

```text
You are building ST-3.
## Not a section heading
```
