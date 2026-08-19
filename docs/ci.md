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

## The billing backstop (org owners)

Budget alerts at 75/90% of the Actions allowance under Organisation
Settings → Billing, and a small non-zero spending limit so one busy month
degrades to a few pounds instead of a three-day org-wide outage.
