# Remediation plan: callers use the shared workflows at @main (#53)

Raised by: the .github chat for pkcrisp. Investigated by: the .github chat. Severity: Medium.

Decision: relayed by orchestrator-1 on 11 November 2026, in the operator's words, "pin it". That takes the lean on #53: pin by commit with a Dependabot bump, `beesec-app.yml` first, then `pr-sections.yml`. The operator's own review of this plan is what confirms it.

Operator answers, relayed by orchestrator-1 on 11 November 2026 in their words: "hivemind, and yes Dependabot is fine". So the proving caller is hivemind, and Dependabot's update jobs are accepted.

## Root cause

Every caller names the shared workflows by branch: `uses: BeeSec-UK/.github/.github/workflows/beesec-app.yml@main` in each app's `pipeline.yml`, and `pr-sections.yml@main` in each repository's `pr-sections.yml`. The starter template `workflow-templates/beesec-app.yml:33` writes `@main` too, so every new app starts the same way. A merge to `main` here therefore changes every caller's CI and deploys on its next run. Under `secrets: inherit` it runs with that caller's secrets, with no review in the caller and no record in its history. Nothing is enforced server-side on GitHub Free.

Pinning the caller is not enough on its own, because the shared workflow still reads from moving refs while it runs:

- Both gitleaks steps, at `.github/workflows/beesec-app.yml:723-724` and `:872-873`, download `https://raw.githubusercontent.com/BeeSec-UK/.github/main/.gitleaks.toml` on every run. So a merge to `main` would still change every pinned caller's secret scan at once.
- `actions/checkout@v4`, `actions/setup-node@v4`, `actions/setup-python@v5`, `Azure/static-web-apps-deploy@v1`, `azure/login@v2` and `Azure/functions-action@v1` are named by tags their owners can move, and they run with the caller's inherited secrets.

`scripts/roll-out-pr-sections.sh:32` also writes `pr-sections.yml@main` into callers. The R3 comment on #53 has the candidates and the evidence.

## Fix

Pin callers to a commit, with the tag it carries as a comment, and let Dependabot propose each bump as a pull request in the caller. First make the shared workflows self-contained, so that the commit a caller pins is all that runs.

0. **Nothing read from a moving ref at run time.**
   - The gitleaks config is written into the step as a quoted heredoc, in place of the download from `main`, so it moves with the commit. The test holds the heredoc byte-for-byte equal to `.gitleaks.toml`, which stays as this repository's own config. The alternative, fetching the file at the workflow's own commit, needs that commit at run time. The OIDC token's `job_workflow_sha` claim carries that commit, but reading it adds a token request and a network fetch to every scan. The heredoc needs neither.
   - Every third-party `uses:` in `.github/workflows/` is pinned as `@<40-hex sha> # <tag>`, as `pr-tests.yml` and the `create-github-app-token` step already are. `.github` gets its own `.github/dependabot.yml` for `github-actions`, so these pins are proposed for update here as PRs.
1. **Releases here.** `.github` gets semver tags, starting at `v1.0.0` on the `main` commit current when step 1 merges. Each later merge that callers should adopt is tagged by the maintainer with `gh release create vX.Y.Z --target <sha>`, and the release notes say what changed for callers. Today there are no tags or releases, and Dependabot needs a tag to know there is a newer version.
2. **The pin form.** Callers write `uses: BeeSec-UK/.github/.github/workflows/beesec-app.yml@<40-hex sha> # v1.0.0`. Dependabot's `github-actions` ecosystem reads this form, moves the SHA to the newest tag's commit and rewrites the comment.
3. **The bump.** Each caller adds `.github/dependabot.yml` with `package-ecosystem: github-actions`, `directory: /` and a weekly schedule, grouped so that one PR carries every shared-workflow bump. `.github` is public, so Dependabot in a private caller can read its tags with no extra access grant.
4. **What writes new callers.** `workflow-templates/beesec-app.yml` writes the pinned form and ships the `dependabot.yml` beside it, so a new app starts pinned. `scripts/roll-out-pr-sections.sh` writes the pinned form of the current release, and its review prompt at `:55` says so, in place of `@main`.
5. **The order.** `beesec-app.yml` first, with step 0, because it reaches deploys and inherited secrets. `pr-sections.yml` and `execution-plan.yml`, the other two shared workflows, follow on the same pattern once the first bump PRs have shown they are cheap.

Each caller's own change is routed to that app's chat by the orchestrator, once the pattern here has merged. This plan only changes `.github`.

Alternatives considered:

- **Stay on `@main`.** This leaves the gap open.
- **Pin by tag, `@v1`.** A tag can be moved by a push, so it gives readability but not integrity.
- **Renovate.** It groups better, but it needs a GitHub App installed on the organisation, which is a permission change. Dependabot is built in.
- **A `beesec` command that bumps every caller.** This works, but it only runs when someone remembers to run it. Dependabot runs on a schedule.
- **An auto-tag workflow on every merge to `main`.** It removes a manual step, but it needs `contents: write` here, and it makes every merge a release whether or not callers should take it. Tagging by hand keeps adoption a decision. Revisit this if tags are forgotten.

## Proving test

`tests/pin.test.sh`, new, committed failing before any change:

1. Every `uses: BeeSec-UK/.github/...` line written by `workflow-templates/` or `scripts/` names a 40-hex commit followed by `# v<semver>`, and none names `@main` or a bare tag. This fails today on `workflow-templates/beesec-app.yml:33` and `scripts/roll-out-pr-sections.sh:32`.
2. The named commit is an ancestor of `origin/main`, and the tag in the comment points at it.
3. Nothing in `.github/workflows/` fetches from a branch at run time: no `raw.githubusercontent.com/<owner>/<repo>/main/`, no `@main` or other branch in a `uses:`, and no `ref: main` in a checkout. Comparisons such as `github.ref == 'refs/heads/main'` are allowed, because they decide what runs, not what is fetched. This fails today on `beesec-app.yml:724` and `:873`.
4. Every `uses:` in `.github/workflows/` is local or names a 40-hex commit with a `#` comment. This fails today on the six tag-pinned actions above.
5. The gitleaks heredoc in each step is byte-for-byte equal to `.gitleaks.toml`.
6. `workflow-templates/dependabot.yml` and `.github/dependabot.yml` exist, parse, and each has a `github-actions` entry for `/`.

The same check, as a script a caller can run, is what each app's chat uses to prove its own change.

## Proof on dev

There is no dev deploy of `.github` itself. The proof is in hivemind, the operator's choice. Its `pipeline.yml:24` calls `beesec-app.yml@main`, and its only deploy is `dev` to `hivemind-dev` on `beesec-dev`, so a push to its `main` deploys nothing to prod. It already pins its factory actions as `@<sha> # app-stack-v1.13.0`, which is the form this plan uses. Pin it to `v1.0.0`, tag a `v1.0.1` here, and show that:

1. Dependabot opens a bump PR in that caller, moving the SHA and the comment to `v1.0.1`.
2. The caller's `pipeline.yml` runs on that PR on `beesec-dev` runners, and pick and gate pass at the new SHA.
3. A `beesec-app.yml` change merged here after `v1.0.1`, but not tagged, does not appear in the caller's next run. The caller's gitleaks step makes no request to `raw.githubusercontent.com`, because the config travels in the pinned commit.

## Risk and rollback

- **Fixes stop reaching callers by themselves.** A security fix here now needs a tag and a merged bump PR in every caller. Mitigation: the release notes mark a security release, and the orchestrator routes the bumps on the same day.
- **Bump PRs run the caller's pipeline as Dependabot.** A Dependabot PR gets only Dependabot secrets, so a gate that needs a secret fails there. This is checked on the dev-only caller before any app adopts the pattern, and the fix there is Dependabot secrets for that caller, not a wider grant.
- **Runner minutes.** Dependabot's own update job runs on GitHub's infrastructure, not on the org's runners. The operator accepted that ("yes Dependabot is fine"), so it is not held against the primary goal. The caller's pipeline on a bump PR still runs on `beesec-dev`.
- **Rollback.** A caller reverts to `@main` with a one-line change. Step 1 here only adds a tag, a template change and a test, and reverting it leaves callers untouched.

## Execution plan

Written by the issue creator, the .github chat for pkcrisp, after the plan was approved at 645ccaa by the operator (queen approval 73352267) and by the peer reviewer. One work package per PR. Each `.github` PR is based on `main`, says `Refs #53`, and commits its failing test first.

| ID | Outcome | Depends on | Owner | Model | h | Forecast tokens | Gate on dev |
|---|---|---|---|---|---|---|---|
| GH-fix-53.1 | `tests/pin.test.sh` committed, failing on checks 1 and 3 to 6 | – | github-1 | Opus | 0.5 | 1 M | pr-tests red on the branch, naming `workflow-templates/beesec-app.yml:33`, `beesec-app.yml:724` and `:873`, and the tag-pinned actions |
| GH-fix-53.2 | Step 0 in `beesec-app.yml`: the gitleaks config as a heredoc, every third-party action pinned by commit, and `.github/dependabot.yml` | .1 | github-1 | Opus | 2 | 4 M | Checks 3 to 6 pass. After the merge, hivemind's next run, still at `@main`, passes pick and gate on `beesec-dev` and makes no request to `raw.githubusercontent.com` |
| GH-fix-53.3 | The template and `roll-out-pr-sections.sh` write the pinned form, and `workflow-templates/dependabot.yml` exists | .2 | github-1 | Opus | 1 | 2 M | Checks 1, 2 and 6 pass against a `v1.0.0` tag on a scratch clone |
| GH-fix-53.4 | `v1.0.0` tagged on the `main` commit after .3 merges, with release notes | .3 | pkcrisp | – | 0.25 | – | `gh api repos/BeeSec-UK/.github/tags` lists `v1.0.0` at that commit |
| GH-fix-53.5 | hivemind pinned to `@<sha> # v1.0.0`, with its `dependabot.yml` | .4 | hivemind-1 | Opus | 1 | 2 M | hivemind's pipeline is green on `beesec-dev` at the pinned commit, and its dev deploy to `hivemind-dev` succeeds |
| GH-fix-53.6 | The dev proof: `v1.0.1` tagged, Dependabot's bump PR in hivemind, and an untagged change not seen | .5 | pkcrisp tags, hivemind-1 proves | Opus | 1 | 2 M | The three points under Proof on dev, each captured on the issue |
| GH-fix-53.7 | `pr-sections.yml` and `execution-plan.yml` on the same pattern | .6 | github-1 | Opus | 1 | 2 M | Checks 1 to 4 pass for both, and a hivemind PR runs pr-sections at the pinned commit |

That is about 7 hours and 13 M tokens, inside a day. Each other app's caller change is routed to that app's chat by the orchestrator after .6, and is outside this plan.
