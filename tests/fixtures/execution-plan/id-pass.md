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
| RS-22b | The admin list reads from the shared gate | – | stinger chat | Opus 5.5 | 3 | 6 | /admin lists staff on stinger-dev | not_started |
| QUEENGAT-12345 | Approvals are logged | RS-22b | stinger chat | Fable 5.1 | 2 | 2 | /audit shows the approval | in_progress |
| ST-3 | Release notes | RS-22b, QUEENGAT-12345 | operator | – | 0.5 | 0 | notes on the release | done |

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

### RS-22b. The admin list reads from the shared gate

**Why this model:** something for RS-22b.

**Depends on:** something for RS-22b.

**Gate on dev:** something for RS-22b.

**Done when:** something for RS-22b.

**Build prompt:**

```text
You are building RS-22b.
## Not a section heading
```

### QUEENGAT-12345. Approvals are logged

**Why this model:** something for QUEENGAT-12345.

**Depends on:** something for QUEENGAT-12345.

**Gate on dev:** something for QUEENGAT-12345.

**Done when:** something for QUEENGAT-12345.

**Build prompt:**

```text
You are building QUEENGAT-12345.
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
