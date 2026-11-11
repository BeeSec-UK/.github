# Remediation plan: callers use the shared workflows at @main (#53)

Raised by: the .github chat for pkcrisp. Investigated by: the .github chat. Severity: Medium.

Decision: relayed by orchestrator-1 on 11 November 2026, in the operator's words, "pin it". That takes the lean on #53: pin by commit with a Dependabot bump, `beesec-app.yml` first, then `pr-sections.yml`. The operator's own review of this plan is what confirms it.

Operator answers, relayed by orchestrator-1 on 11 November 2026 in their words: "hivemind, and yes Dependabot is fine". So the proving caller is hivemind, and Dependabot's update jobs are accepted.

## Root cause

Every caller names the shared workflows by branch: `uses: BeeSec-UK/.github/.github/workflows/beesec-app.yml@main` in each app's `pipeline.yml`, and `pr-sections.yml@main` in each repository's `pr-sections.yml`. The starter template `workflow-templates/beesec-app.yml:33` writes `@main` too, so every new app starts the same way. A merge to `main` here therefore changes every caller's CI and deploys on its next run. Under `secrets: inherit` it runs with that caller's secrets, with no review in the caller and no record in its history. Nothing is enforced server-side on GitHub Free. The R3 comment on #53 has the candidates and the evidence.

## Fix

Pin callers to a commit, with the tag it carries as a comment, and let Dependabot propose each bump as a pull request in the caller.

1. **Releases here.** `.github` gets semver tags, starting at `v1.0.0` on the `main` commit current when step 1 merges. Each later merge that callers should adopt is tagged by the maintainer with `gh release create vX.Y.Z --target <sha>`, and the release notes say what changed for callers. Today there are no tags or releases, and Dependabot needs a tag to know there is a newer version.
2. **The pin form.** Callers write `uses: BeeSec-UK/.github/.github/workflows/beesec-app.yml@<40-hex sha> # v1.0.0`. Dependabot's `github-actions` ecosystem reads this form, moves the SHA to the newest tag's commit and rewrites the comment.
3. **The bump.** Each caller adds `.github/dependabot.yml` with `package-ecosystem: github-actions`, `directory: /` and a weekly schedule, grouped so that one PR carries every shared-workflow bump. `.github` is public, so Dependabot in a private caller can read its tags with no extra access grant.
4. **The template.** `workflow-templates/beesec-app.yml` writes the pinned form and ships the `dependabot.yml` beside it, so a new app starts pinned.
5. **The order.** `beesec-app.yml` first, because it reaches deploys and inherited secrets. `pr-sections.yml` follows on the same pattern once the first bump PRs have shown they are cheap.

Each caller's own change is routed to that app's chat by the orchestrator, once the pattern here has merged. This plan only changes `.github`.

Alternatives considered:

- **Stay on `@main`.** This leaves the gap open.
- **Pin by tag, `@v1`.** A tag can be moved by a push, so it gives readability but not integrity.
- **Renovate.** It groups better, but it needs a GitHub App installed on the organisation, which is a permission change. Dependabot is built in.
- **A `beesec` command that bumps every caller.** This works, but it only runs when someone remembers to run it. Dependabot runs on a schedule.
- **An auto-tag workflow on every merge to `main`.** It removes a manual step, but it needs `contents: write` here, and it makes every merge a release whether or not callers should take it. Tagging by hand keeps adoption a decision. Revisit this if tags are forgotten.

## Proving test

`tests/pin.test.sh`, new, committed failing before the template changes:

1. Every `uses: BeeSec-UK/.github/...` line in `workflow-templates/` names a 40-hex commit followed by `# v<semver>`, and none names `@main` or a bare tag.
2. The named commit is an ancestor of `origin/main`, and the tag in the comment points at it.
3. `workflow-templates/dependabot.yml` exists, parses, and has a `github-actions` entry for `/`.

The same check, as a script a caller can run, is what each app's chat uses to prove its own change.

## Proof on dev

There is no dev deploy of `.github` itself. The proof is in hivemind, the operator's choice. Its `pipeline.yml:24` calls `beesec-app.yml@main`, and its only deploy is `dev` to `hivemind-dev` on `beesec-dev`, so a push to its `main` deploys nothing to prod. It already pins its factory actions as `@<sha> # app-stack-v1.13.0`, which is the form this plan uses. Pin it to `v1.0.0`, tag a `v1.0.1` here, and show that:

1. Dependabot opens a bump PR in that caller, moving the SHA and the comment to `v1.0.1`.
2. The caller's `pipeline.yml` runs on that PR on `beesec-dev` runners, and pick and gate pass at the new SHA.
3. A `beesec-app.yml` change merged here after `v1.0.1`, but not tagged, does not appear in the caller's next run.

## Risk and rollback

- **Fixes stop reaching callers by themselves.** A security fix here now needs a tag and a merged bump PR in every caller. Mitigation: the release notes mark a security release, and the orchestrator routes the bumps on the same day.
- **Bump PRs run the caller's pipeline as Dependabot.** A Dependabot PR gets only Dependabot secrets, so a gate that needs a secret fails there. This is checked on the dev-only caller before any app adopts the pattern, and the fix there is Dependabot secrets for that caller, not a wider grant.
- **Runner minutes.** Dependabot's own update job runs on GitHub's infrastructure, not on the org's runners. The operator accepted that ("yes Dependabot is fine"), so it is not held against the primary goal. The caller's pipeline on a bump PR still runs on `beesec-dev`.
- **Rollback.** A caller reverts to `@main` with a one-line change. Step 1 here only adds a tag, a template change and a test, and reverting it leaves callers untouched.

## Execution plan

Pending: written by the issue creator after peer review approves this plan.
