# Plan: automated security on every PR in beesec-app.yml

Status: decided, 29 October 2026. The operator answered the four decisions at the end on 29 October. Building it is a workflow change and needs the operator as maintainer.

This is step 1 of the review loop in orchestrator `standards/engineering-workflow.md` for step 4 of that loop. Every PR runs secret scanning, dependency and licence checks, static analysis, the IaC policy check and the client-data scrub with no person involved, and any finding fails the PR.

## Constraints

- **Zero spend.** Every tool is free and open source and runs on the self-hosted `beesec-dev` runners. No GitHub Advanced Security, because CodeQL and dependency review are paid on private repositories, and no SaaS tier.
- **Cost rules from [ci.md](ci.md).** No new job under two minutes. Every check is a step in the existing `gate` job, or in `gate_web` where `parallel_web_gate` is on, or in `pick` where the gate is skipped.
- **CPU is the GTX's limit.** On 29 October load reached 29.7 on 8 cores with four jobs running (hivemind#101, `fleet/RUNNERS.md`). Every added second is multiplied by up to four concurrent jobs, so each tool is chosen and scoped to keep CPU low.
- **This repository is public.** No client name, client pattern or engagement detail can live in it. That shapes the scrub below.
- **Binaries are cached like gitleaks.** Each tool is pinned to a version, kept in the runner's tool cache, verified on download and retried on failure. A runner downloads each version once, not on every run.

## What runs today

| Check | Today |
|---|---|
| Secret scanning | gitleaks 8.28.0 runs on every PR, as the gate's first step, or in `pick` when the gate is skipped. It scans the working tree with `gitleaks dir`, so a secret committed and then deleted inside the same PR is not caught. It takes 1 to 2 s. |
| Dependencies and licences | Nothing |
| Static analysis | Nothing beyond `tsc -b` |
| IaC policy | The factory `plan` action (`conform.py` and PSRule) runs on PRs in apitoxin, hivemind and propolis, each as a separate caller job of 24 to 76 s, against the cost rule. Callers pin factory versions from app-stack-v1.8.3 to v1.12.3. |
| Client-data scrub | Nothing in CI. `beesec pr` refuses private-shaped paths locally (`_private/`, `findings-brain.json`, `*.pem`, `*.key`, `id_rsa`, `secrets.md`), but that never runs on a PR. |

## The checks

Times are estimates for one PR run on a GTX runner and are measured in step 1 of the execution plan. The measured times decide whether a tool stays.

### 1. Secret scanning: gitleaks, extended

- **Change:** on a pull request, also run `gitleaks git --log-opts="<base>..<head>"` over the PR's own commits, so a secret added and later removed is still caught. The existing `dir` scan stays for push and dispatch. The base comes from the event payload, so no full-history fetch is needed.
- **Where:** gate, as today, and the `pick` fallback when the gate is skipped.
- **Cost:** about 2 s more, single-threaded.
- **False positives:** handled as today. One central `.gitleaks.toml` in this repository, changed only by a PR here, and `gitleaks:allow` on the line for a known test value. Any allowlist change is tested in both directions, as the original adoption was.

### 2. Dependencies and licences: OSV-Scanner

- **Tool:** OSV-Scanner v2 (Google, Apache-2.0), a single Go binary. One scan reads `api/requirements*.txt` and `web/package-lock.json` against the OSV database. With `--licenses=<allowlist>` it also checks each package's licence through deps.dev. One tool covers both ecosystems and both checks.
- **Where:** gate, after the dependency install, in the API half for Python and the web half for npm. It runs when path gates say that half changed, or always when `path_gates` is off.
- **Cost:** about 5 to 20 s, mostly network. CPU use is small.
- **Licence allowlist:** kept centrally in this repository. It starts as MIT, BSD-2-Clause, BSD-3-Clause, Apache-2.0, ISC, PSF-2.0, MPL-2.0, 0BSD, Unlicense and CC0-1.0. A copyleft licence such as GPL or AGPL fails, because these apps ship as a hosted service and the operator decides each case.
- **False positives:**
  - A vulnerability that does not apply is ignored in the caller's `osv-scanner.toml` as `[[IgnoredVulns]]`, with an id, a reason and an `ignoreUntil` date. The gate fails on any entry without a reason or with an `ignoreUntil` more than 90 days away, so no ignore is permanent.
  - A licence exception goes in the same file with a reason, as a per-package override.
- **Unreachable database:** the step retries, then fails. That is a red run, not a pass, the same rule as gitleaks.

### 3. Static analysis: Ruff security rules and Semgrep CE

- **Python:** `ruff check --select S`, the flake8-bandit rules, in `api/`. Ruff (MIT) is a single binary and runs in under a second on these codebases.
- **TypeScript and Bicep:** Semgrep Community Edition (LGPL-2.1 engine), with a ruleset vendored into this repository at a pinned commit. Runs are offline and repeatable, and nothing is fetched from the registry at run time.
  - On a PR it runs with `--baseline-commit <base>`, so it reports only findings the PR introduces, and existing debt never blocks a PR.
  - It runs with `--jobs 2`, so one job never takes the whole GTX.
- **Where:** gate, API half for Ruff, web half for Semgrep.
- **Cost:** Ruff under 1 s. Semgrep is the costliest check, estimated at 20 to 60 s of two cores on a changed-files baseline run. It is the first candidate to be cut down if the measurement in step 1 shows it lengthening the queue.
- **False positives:**
  - `# noqa: S<code> <reason>` for Ruff and `// nosemgrep: <rule-id> <reason>` for Semgrep, on the line. The gate fails on a suppression with no reason after the rule id.
  - A rule that is noisy across the estate is removed from the vendored ruleset by a PR here.
  - Existing debt found by a one-off full scan becomes one issue per repository, not a PR blocker.

### 4. IaC policy: the factory plan action, folded in

- **Change:**
  - A new input `iac_params_file`, for example `infra/dev.bicepparam`, plus `iac_subscription_name` and `iac_subscription_id`.
  - When it is set and the PR touches `infra/`, the gate runs the factory `plan` action, which is `conform.py` and PSRule offline with no Azure sign-in, as a step. Path gates already route `infra/` to the API half.
  - The callers then delete their own `plan` jobs, which removes a sub-two-minute job from three repositories.
- **Cost:** 12 to 35 s, moved rather than added. A separate job's checkout and set-up are saved, so the net cost is lower than today.
- **False positives:** stay where they are, in the factory's conform rules and PSRule baseline, changed by a factory PR.
- **Pin, decision A:** `uses:` cannot take a version from an input, so `beesec-app.yml` pins one factory version for every caller, app-stack-v1.12.3. Callers are on v1.8.3 to v1.12.3 today and move with it.

### 5. Client-data scrub: new

- **Paths:** fail on any file in the PR whose path matches the `beesec pr` private shape, `_private/`, `findings-brain.json`, `*.pem`, `*.key`, `id_rsa` or `secrets.md`. The pattern is copied with a test that it matches the CLI's.
- **Content:** fail on any added line that matches a client pattern list. The list cannot live in this public repository. It is read at run time from an org secret, `CLIENT_SCRUB_PATTERNS`, which reaches the gate through `secrets: inherit`. The step reports only the file and line number, never the matched text, so a match never echoes client data into a log.
- **Where:** gate, and the `pick` fallback, because a docs-only change is where pasted client data hides.
- **Cost:** under 2 s. It is a `git diff` of the PR and a fixed-string grep.
- **False positives:** there is no inline override, because client data has no legitimate place in an app repository. A false match is fixed by changing the pattern list, which the operator owns. Fixtures use neutral, made-up engagement references.
- **Source, decision B:** the list is the org secret above, which the operator owns and keeps current.

## Total cost

On a PR that touches both halves, the gate gains an estimated 30 to 90 s, of which Semgrep is most. The IaC fold saves one job in three repositories. No new job is added. A docs-only PR gains about 4 s in `pick`.

## Execution plan

1. **Measure:** build the steps on a branch of this repository behind a `security_checks` input, default off. Run them against one PR in each of honeycomb, propolis and apitoxin, which are the largest, the IaC caller and the spores caller. Record each step's wall time and CPU on the GTX in this file.
2. **Shadow for one week:** turn `security_checks` on in every caller with `continue-on-error` on each new step, so findings are reported as annotations and nothing fails. Count findings per repository and per tool, and fix or record the real ones.
3. **Enforce:** remove `continue-on-error`, so any finding fails the PR. Make `security_checks` default on, and delete the three caller `plan` jobs.
4. **Document:** update the README's inputs table and `ci.md`'s rules.

Each step is its own PR in this repository, with the operator as maintainer. Steps 2 and 3 also touch the nine callers.

## Not covered

- **Repositories that do not call `beesec-app.yml`:** queen, claude-skills, forager, beeline, swarm, nasonov and the rest get only `pr-sections`. Bringing them under the same checks is a separate plan.
- **Push runs on `main`:** these are not re-scanned beyond today's gitleaks step, because `trust_pr_gate` already proves the tree passed on its PR.

## Decisions

The operator answered all four on 29 October 2026.

- A, the factory pin: `beesec-app.yml` pins the factory `plan` action at app-stack-v1.12.3 for every caller. The three IaC callers move to it when their own `plan` jobs are deleted.
- B, the client pattern list: an org secret, `CLIENT_SCRUB_PATTERNS`, owned by the operator. The step reports file and line only, never the matched text.
- C, shadow mode: yes. A week with every new step reporting and nothing failing, before enforcement.
- D, an unreachable vulnerability database: the run fails, the same rule as gitleaks.
