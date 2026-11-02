# Plan: automated security on every PR in beesec-app.yml

Status: decisions A to D answered by the operator on 29 October 2026, decision E open. Revised on 1 November after review: Bicep left to section 4, the ruleset's licence, history for pushes, merge-base history for PRs, and the files OSV reads. Revised on 2 November: pushes use the same merge-base loop, `gate_web` gets the history, every `swa_paths` change routes to the API half, and the pushes left to `pick` are stated in full. Revised again on 2 November: Semgrep's PR baseline is the merge commit's first parent, not the merge base, and the scrub secret's exposure is left open as decision E. Building it is a workflow change and needs the operator as maintainer.

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

- **Change:** on a pull request, also run `gitleaks git --log-opts="<base>..<head>"` over the PR's own commits, so a secret added and later removed is still caught. The existing `dir` scan stays for push and dispatch.
- **History it needs:** every checkout in `beesec-app.yml` is a one-commit clone of the merge commit, which holds neither the base nor the PR's own commits. A fixed depth is not enough. `pull_request.base.sha` is the base branch's tip when the event fired, not the merge base, and depth counts generations, not commits. So once main has moved, or the PR has merged main in, the shallow boundary would fall inside the range, and gitleaks would scan that boundary commit as a root, meaning its whole tree. The step therefore:
  1. Fetches `base_sha` and `head_sha` at depth 1.
  2. Deepens both with `git fetch --deepen=50` until `git merge-base <base_sha> <head_sha>` resolves, up to 20 rounds.
  3. Scans `<merge-base>..<head_sha>`, so every PR commit is diffed against a parent that is present.

  If the merge base is still missing after 20 rounds, the step fetches full history once rather than guess. `head_sha` and `base_sha` come from the event payload. The same history serves Semgrep's baseline, OSV and the scrub's diff below. It is added in every job that runs one of these checks: gate, `gate_web` when `parallel_web_gate` is on, because that is a separate checkout, and the `pick` fallback.
- **On a push:** the same loop runs with `github.event.before` in place of `base_sha` and `github.sha` in place of `head_sha`. Fetching `before` alone is not enough, because the checkout is one commit deep and the pushed commits between `before` and `github.sha` would be missing, so gitleaks would scan `github.sha` as a root, and a secret added and removed inside a multi-commit push would be missed. The loop deepens both until `git merge-base <before> <github.sha>` resolves, then scans `<merge-base>..<github.sha>`. If `before` is all zeros, which happens when the branch is created, or the commit cannot be fetched after a force push, there is nothing to diff against. The history scan is skipped and logged as skipped, and the `dir` scan of the tree still runs, so main never goes red for want of a baseline.
- **Where:** gate, as today, and the `pick` fallback when the gate is skipped.
- **Cost:** about 2 s more, single-threaded.
- **False positives:** handled as today. One central `.gitleaks.toml` in this repository, changed only by a PR here, and `gitleaks:allow` on the line for a known test value. Any allowlist change is tested in both directions, as the original adoption was.

### 2. Dependencies and licences: OSV-Scanner

- **Tool:** OSV-Scanner v2 (Google, Apache-2.0), a single Go binary. It checks these against the OSV database:
  - `package_requirements_path`, which is what ships in the Functions package.
  - `requirements_path`, when it names a different file, because the test gate's file may be a dev-requirements file that is never deployed.
  - `package-lock.json` under `app_location`.
  - Every `package-lock.json` under the caller's `swa_paths`, for a caller whose SPA lives outside `web/` and sets `has_web: false`, such as apitoxin's `app-vite/`. Those run in the API half, because such a caller never runs the web half. With `--licenses=<allowlist>` it also checks each package's licence through deps.dev. One tool covers both ecosystems and both checks.
- **Where:** gate, after the dependency install, in the API half for Python and in the web half for `app_location`'s npm tree. It runs when path gates say that half changed, or always when `path_gates` is off. A dependency-only change must not skip it, so `pick` also routes any change to a scanned manifest to the half that scans it. A requirements file outside `api/` routes to the API half. For a caller with `has_web: false`, any change under `swa_paths` routes to the API half, source as well as lockfile, because that half is where the SPA's OSV and Semgrep run. Routing only the lockfile would leave a source-only change to such a SPA with both halves off and no Semgrep scan.
- **Cost:** about 5 to 20 s, mostly network. CPU use is small.
- **Licence allowlist:** kept centrally in this repository. It starts as MIT, BSD-2-Clause, BSD-3-Clause, Apache-2.0, ISC, PSF-2.0, MPL-2.0, 0BSD, Unlicense and CC0-1.0. A copyleft licence such as GPL or AGPL fails, because these apps ship as a hosted service and the operator decides each case.
- **False positives:**
  - A vulnerability that does not apply is ignored in the caller's `osv-scanner.toml` as `[[IgnoredVulns]]`, with an id, a reason and an `ignoreUntil` date. The gate fails on any entry without a reason or with an `ignoreUntil` more than 90 days away, so no ignore is permanent.
  - A licence exception goes in the same file with a reason, as a per-package override.
  - **No licence data:** many Python packages have none in deps.dev. A package with no licence fails like a disallowed one, and needs an override with a reason. The shadow week counts these per repository, so the size of that list is known before anything is enforced.
- **Unreachable database:** the step retries, then fails. That is a red run, not a pass, the same rule as gitleaks.

### 3. Static analysis: Ruff security rules and Semgrep CE

- **Python:** `ruff check --select S`, the flake8-bandit rules, in `api/`. Ruff (MIT) is a single binary and runs in under a second on these codebases.
- **TypeScript:** Semgrep Community Edition (LGPL-2.1 engine), with a ruleset vendored into this repository at a pinned commit. Runs are offline and repeatable, and nothing is fetched from the registry at run time.
  - **No Bicep:** Semgrep CE has no Bicep parser. It reads Terraform/HCL, JSON and YAML, but not Bicep, so Bicep rules would have to be generic-mode text patterns, which are too weak to rely on. Bicep is left to the IaC policy check in section 4, PSRule and `conform.py`, which reads the compiled template.
  - **Ruleset licence:** this repository is public, and the Semgrep registry's rules are under the Semgrep Rules License, whose terms limit how they may be redistributed. So the vendored ruleset holds only rules BeeSec writes, plus third-party rules under an OSI-approved licence, each with its source and licence recorded beside it. Step 1 checks the licence of every rule before it is vendored, and any rule whose licence does not allow redistribution stays out.
  - On a PR it runs with `--baseline-commit HEAD^1`. A `pull_request` run checks out GitHub's merge commit, which is the base tip plus the PR, and its first parent is that base tip, fetched by the loop in section 1. Diffing against the merge base instead would count every commit that reached main since the PR branched as new, so a finding already on main could fail an unrelated PR. Against `HEAD^1` it reports only findings the PR introduces, and existing debt never blocks a PR. Gitleaks and the scrub keep `<merge-base>..<head_sha>`, because they read the PR's own commits rather than the merged tree. On a push it uses `github.event.before`, fetched the same way. When there is no usable `before`, as in section 1, Semgrep is skipped and logged rather than run against the whole tree.
  - It runs with `--jobs 2`, so one job never takes the whole GTX.
- **Where:** gate. Ruff runs in the API half. The TypeScript rules run in the web half, and in the API half for a `swa_paths` SPA, as for OSV above. `pick` routes every change under `swa_paths` to the API half for such a caller, so a source-only change to the SPA is scanned.
- **Cost:** Ruff under 1 s. Semgrep is the costliest check, estimated at 20 to 60 s of two cores on a changed-files baseline run. It is the first candidate to be cut down if the measurement in step 1 shows it lengthening the queue.
- **False positives:**
  - `# noqa: S<code> <reason>` for Ruff and `// nosemgrep: <rule-id> <reason>` for Semgrep, on the line. The gate fails on a suppression with no reason after the rule id. Step 1 checks that both tools still honour the suppression with text after the rule id, and if either does not, the reason moves to a comment on the line above and the gate checks for that instead.
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
- **Empty list:** an empty or missing `CLIENT_SCRUB_PATTERNS` fails the step, never passes it. Dependabot PRs do not receive Actions secrets, so they fail this step until the operator copies the secret into the Dependabot secrets as well. The path half still runs on them.
- **Who can read the list:** a `pull_request` run takes its workflow from the PR's head, so anyone who can push a branch to a caller repository can edit the caller's workflow to print the secret. Those people are BeeSec staff with write access, who already handle the clients named in it. The secret is limited to the nine caller repositories, not the whole org. Decision B chose where the list lives and does not cover this exposure, so it is open as decision E below and nothing is built until the operator answers it.
- **Cost:** under 2 s. It is a `git diff` of the PR's range from section 1, `<merge-base>..<head>` on a PR and `<before>..<sha>` on a push, and a fixed-string grep. With no usable `before` on a push, it checks the paths only, which needs no history, and logs that the content half was skipped.
- **False positives:** there is no inline override, because client data has no legitimate place in an app repository. A false match is fixed by changing the pattern list, which the operator owns. Fixtures use neutral, made-up engagement references.
- **Source, decision B:** the list is the org secret above, which the operator owns and keeps current.

## Total cost

On a PR that touches both halves, the gate gains an estimated 30 to 90 s, of which Semgrep is most. The IaC fold saves one job in three repositories. No new job is added. A docs-only PR gains about 4 s in `pick`.

## Execution plan

1. **Measure:** build the steps on a branch of this repository behind a `security_checks` input, default off. Run them against one PR in each of honeycomb, propolis and apitoxin, which are the largest, the IaC caller and the spores caller. Record each step's wall time and CPU on the GTX in this file.
2. **Shadow for one week:** turn `security_checks` on in every caller with `continue-on-error` on each new step, so findings are reported as annotations and nothing fails. Count findings per repository and per tool, and fix or record the real ones.
3. **Enforce:** remove `continue-on-error`, so any finding fails the PR. Make `security_checks` default on, and delete the three caller `plan` jobs.
4. **Document:** update the README's inputs table and `ci.md`'s rules.

Step 1 does not start until decision E is answered. Each step is its own PR in this repository, with the operator as maintainer. Steps 2 and 3 also touch the nine callers.

## Not covered

- **Repositories that do not call `beesec-app.yml`:** queen, claude-skills, forager, beeline, swarm, nasonov and the rest get only `pr-sections`. Bringing them under the same checks is a separate plan.
- **Push runs on `main` where the gate is skipped:** the new checks are steps in the gate, so they run on a push whenever the gate runs. A caller that turns on `trust_pr_gate` skips the gate on a push that came from a merged PR, which already passed them on its PR. Two cases are covered by `pick` alone, which runs gitleaks and the scrub and nothing else: that one, and a push with `path_gates` on that touches neither half, such as a docs-only change. Neither loses a check that applies, since the second has no code for the other checks to read. Any other push runs the full gate.

## Decisions

The operator answered A to D on 29 October 2026. E is open.

- A, the factory pin: `beesec-app.yml` pins the factory `plan` action at app-stack-v1.12.3 for every caller. The three IaC callers move to it when their own `plan` jobs are deleted.
- B, the client pattern list: an org secret, `CLIENT_SCRUB_PATTERNS`, owned by the operator. The step reports file and line only, never the matched text.
- C, shadow mode: yes. A week with every new step reporting and nothing failing, before enforcement.
- D, an unreachable vulnerability database: the run fails, the same rule as gitleaks.
- E, who can read the scrub list: open. Anyone who can push a branch to one of the nine caller repositories can make a `pull_request` run print `CLIENT_SCRUB_PATTERNS`. The operator either accepts that exposure explicitly, or narrows it, for example by holding the secret in a deployment environment that only main may use, so the content half runs after merge rather than on the PR.
