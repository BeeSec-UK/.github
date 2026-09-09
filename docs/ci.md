# BeeSec CI — the house pipeline and the cost rules

One shared pipeline, `.github/workflows/beesec-app.yml` in this repo, runs
CI and deploys for every app-shaped repo (Python Functions `api/` + Vite
SPA `web/` + SWA/Function App, per `orchestrator/standards/stack.md`). A
repo's own workflow is a ~30-line caller naming its resources — the full
input reference and a caller example live at the top of the pipeline file.

## Why it exists

In August 2026 the org ran out of free GitHub Actions minutes mid-month and
every deploy in every repo failed for three days, silently at first. The
minutes were going on structure, not on work: many under-a-minute jobs
(each billed as a full minute plus VM spin-up), no dependency caching,
duplicate runs on rapid pushes, and PR preview deploys nobody used.

## The rules (apply to every repo, templated or not)

1. **No job that finishes in under two minutes gets to be its own job.**
   Fold it into an existing one — the shared pipeline's
   `extra_gate_script` hook exists for exactly this.
2. **Every workflow carries a concurrency group** cancelling superseded PR
   runs. Never cancel an in-flight main deploy.
3. **Cache pip and npm.** `setup-python`/`setup-node` both take a `cache:`
   input — there is no reason to rebuild the toolbox each run.
4. **Deploys on push to main and manual dispatch only.** No PR preview
   deploys.
5. **Changes to `.github/workflows/**` need a maintainer's review** — CI
   changes are spend changes.

## For repos that are not app-shaped

Shell/tool repos (forager, claude-project-setup, pawdit …) keep their own
workflows but follow the same rules — rule 1 is usually the whole saving.

## Runners, and why a run takes fourteen minutes

Since the runner default moved to `self-hosted`, every app's CI queues on
the one org runner, the Mele. Measured on honeycomb on 2026-09-09: pytest
307s, vitest 375s, tsc 63s, the whole test job 14 minutes, against 35s,
90s and 10s for the same steps on a developer laptop. One runner also
means one run at a time, so four PRs and their merges in an afternoon
queue for over an hour, and the 15-minute job timeout is a minute away.

Two things reduce it, and they only work together:

1. **More runners on the same labels.** A workstation registered with the
   default labels (`self-hosted`, `linux`, `x64`) takes the next queued job
   whenever it is on, and is roughly seven times faster than the Mele on
   these suites. Register it at repo level (a repo admin can mint the token
   through `POST /repos/{org}/{repo}/actions/runners/registration-token`)
   or at org level (needs `admin:org` on the `gh` token, then
   `POST /orgs/{org}/actions/runners/registration-token`), with
   `./config.sh --unattended --url <repo or org url> --token <token>
   --labels workstation` from the unpacked runner, then `sudo ./svc.sh
   install && sudo ./svc.sh start` to run it as a service. Docker, the Azure
   CLI and the app's apt packages must be present, because the deploy jobs
   land there too. The Mele stays the floor: a workstation runner helps only
   while that machine is on.
2. **`parallel_web_gate: true`** in the caller, which runs the web half of
   the gate as its own job beside pytest. With two runners a run takes the
   slower half rather than both; with one runner it gains nothing and costs
   a checkout, which is why it is opt-in.

The apt step installs only what `dpkg` says is missing, so a runner that
already has the packages never runs `apt-get`, and a workstation without
passwordless sudo is not stopped by it.

## The billing backstop (org owners)

Budget alerts at 75/90% of the Actions allowance under Organisation
Settings → Billing, and a small non-zero spending limit so one busy month
degrades to a few pounds instead of a three-day org-wide outage.
