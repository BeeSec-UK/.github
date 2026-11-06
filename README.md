# .github

BeeSec-UK's shared CI. Two reusable workflows live here, and every other
repository calls them rather than keeping its own copy, so a fix made here
reaches every caller on its next run. The cost rules and the measurements
behind them are in [docs/ci.md](docs/ci.md).

## Runners

The org's GitHub spending limit is zero, so nothing runs on GitHub-hosted
runners. Every job lands on one of three self-hosted pools, chosen by label.

| Label | Machine | Registered at | Used by |
|---|---|---|---|
| `beesec-dev` | the GTX, runners `gtx-dev-1` to `gtx-dev-3` | org | `beesec-app.yml`, every job |
| `beesec-prod` | drone2, runners `drone2-prod-1` to `drone2-prod-4` | `beesec-release` only | `beesec-release` promotion, nothing in this repo |
| `beesec-preflight` | the Pi, runners `waker-preflight` and `waker-preflight-2` | org | `pr-sections.yml` |

None of them carries the `self-hosted` label, so `runs-on: self-hosted`
or `["self-hosted","beesec-dev"]` matches nothing and the job queues
forever.

## `beesec-app.yml`

The house pipeline for an app-shaped repository: a Python Functions API in
`api/` and a Vite SPA in `web/`, deployed to a Function App and a Static
Web App. On a pull request it runs the gate only. On a push to `main` or a
manual dispatch it runs the gate and then deploys.

Jobs, in order:

1. `pick` chooses the runner labels and decides what the change needs.
   It runs the secret scan itself when the gate is skipped.
2. `gate` runs gitleaks, pytest, `tsc -b`, vitest and `extra_gate_script`
   in one job.
3. `gate_web` runs the web half on its own, only with `parallel_web_gate`.
4. `deploy_frontend` builds and deploys the SWA.
5. `deploy_api` deploys the Function App, then smoke-tests `smoke_path`.

Every job has a 15-minute timeout, and `pick` has three minutes.

### Inputs

Test gate:

| Input | Default | What it does |
|---|---|---|
| `python_version` | `3.11` | Python for the gate and the package |
| `node_version` | `20` | Node for the web gate and the SWA build |
| `apt_packages` | empty | System packages pytest needs, installed only where missing |
| `requirements_path` | `api/requirements.txt` | What the gate installs |
| `package_requirements_path` | `api/requirements.txt` | What is vendored into the deployed package |
| `extra_pip` | `pytest` | Test-only packages that never ship |
| `pytest_workdir` | `api` | Where pytest runs |
| `pytest_args` | `-q` | Arguments to pytest |
| `has_web` | `true` | `false` for an API-only app skips every web step |
| `npm_install_command` | `npm ci` | Installs `web/` |
| `typecheck_command` | `npx tsc -b` | Must check the real projects |
| `run_vitest` | `true` | Runs vitest |
| `vitest_command` | `npx vitest run` | The vitest command |
| `extra_gate_script` | empty | Repo-specific checks, run in the same job after the standard gate |

Frontend deploy:

| Input | Default | What it does |
|---|---|---|
| `deploy_swa` | `true` | Deploys the Static Web App |
| `app_location` | `web` | SPA source |
| `output_location` | `dist` | Build output |
| `app_build_command` | `npm install && npm run build` | The SWA build |
| `frontend_build_env` | empty | `KEY=VALUE` lines set on the Vite build, non-secret |
| `swa_paths` | empty | Path prefixes that redeploy the SWA when the SPA is not in `web/` |

API deploy:

| Input | Default | What it does |
|---|---|---|
| `deploy_api` | `true` | Deploys the Function App |
| `api_deploy_mode` | `run-from-package` | `run-from-package`, `flex` or `publish-profile` |
| `function_app` | empty | Function App name |
| `resource_group` | empty | Its resource group |
| `storage_account` | empty | Where the release zip goes, `run-from-package` only |
| `releases_container` | `function-releases` | Container for the release zip |
| `azure_client_id` | empty | Managed identity client id for OIDC |
| `azure_tenant_id` | empty | Tenant for OIDC |
| `azure_subscription_id` | empty | Subscription for OIDC |
| `post_deploy_script` | empty | Runs after the deploy with the az session still live |
| `smoke_path` | `/api/healthz` | Smoke-tested after the deploy |
| `smoke_expect_sha` | `false` | Requires the deployed commit in the smoke response |

Runners and narrowing:

| Input | Default | What it does |
|---|---|---|
| `runner` | `["beesec-dev"]` | Labels for every job |
| `prefer_runner` | empty | Labels to use instead while one of them is idle, read through the `beesec-runner-status` App |
| `parallel_web_gate` | `false` | Runs the web gate as its own job beside pytest |
| `path_gates` | `false` | Tests and deploys only the half the change touched |
| `trust_pr_gate` | `false` | Skips re-testing a squash merge whose tree already passed on its PR |

Outputs `deploy_api`, `deploy_web` and `tests` carry the `pick` verdict
for a caller that keeps its own deploy jobs.

Secrets arrive through `secrets: inherit`: `AZURE_STATIC_WEB_APPS_API_TOKEN`
for the SWA, `AZURE_FUNCTIONAPP_PUBLISH_PROFILE` in `publish-profile` mode
only, and the org secret `RUNNER_STATUS_APP_KEY` for `prefer_runner`.

### Callers

apiary, apitoxin, beehive, hivemind, honeycomb, nectar, propolis, stinger
and varroa, each from `.github/workflows/pipeline.yml` at `@main`. A
starter caller is in
[workflow-templates/beesec-app.yml](workflow-templates/beesec-app.yml), and
the full caller example is at the top of the workflow file.

## `pr-sections.yml`

Fails a pull request while `What it does` or `Try it on dev` is empty, or
while the Claude test prompt is missing, still holds template placeholders,
names a host other than dev or GitHub, or holds anything credential-shaped.
It skips drafts, takes no inputs and no secrets, runs with no permissions,
and runs on `beesec-preflight` with a two-minute timeout. The body is read
from the event payload, so nothing in a PR description runs.

### Callers

37 repositories on 28 October 2026, each from
`.github/workflows/pr-sections.yml` at `@main`. [scripts/roll-out-pr-sections.sh](scripts/roll-out-pr-sections.sh)
opens the caller PR in any private repository that lacks it. Public
repositories are skipped on purpose, because a fork's pull request would
run on the self-hosted runner.

## Everything else here

- [`.gitleaks.toml`](.gitleaks.toml) is the secret-scan config that both
  gate paths download from `main`.
- [`PULL_REQUEST_TEMPLATE.md`](PULL_REQUEST_TEMPLATE.md) is the org default
  template whose sections `pr-sections.yml` checks.
- [`profile/README.md`](profile/README.md) is the org's public profile page.
- [`scripts/workstation-runner.sh`](scripts/workstation-runner.sh)
  registers a workstation runner. It still applies the old `self-hosted`
  and `workstation` labels, which no caller asks for any more.
