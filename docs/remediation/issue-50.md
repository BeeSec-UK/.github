# Remediation plan: gitleaks cached binary runs without a hash check (#50)

Raised by: the .github chat for pkcrisp. Investigated by: the .github chat. Severity: Medium.

## Root cause

Both gitleaks steps in `.github/workflows/beesec-app.yml`, the pick job's fallback scan and the gate's scan, pin `VER=8.28.0` but no SHA-256. A binary already in `$RUNNER_TOOL_CACHE` is used whenever it answers `version`, and a fresh download is only checked as a readable tarball. In the R0 reproduction on the issue, a stub in the cache and a substituted tarball were each run, and the step exited 0 over a file holding an AWS key. The full analysis, with the candidates ruled out, is in the R3 comment on #50.

## Fix

In both steps:

- Pin `GL_TGZ_SHA256=a65b5253807a68ac0cafa4414031fd740aeb55f54fb7e55f386acb52e6a840eb`, from `gitleaks_8.28.0_checksums.txt` on the v8.28.0 release, and `GL_BIN_SHA256=5fd1b3b0073269484d40078662e921d07427340ab9e6ed526ccd215a565b3298`, the binary inside that archive.
- Before every use, check the cached binary with `sha256sum -c`. If it is missing or doesn't match, log `::warning::cached gitleaks failed its hash check, downloading again` and delete it.
- Download to `$RUNNER_TEMP`. Check the archive with `sha256sum -c` before `tar x`, and extract into `$RUNNER_TEMP`. Check the binary, then copy it into the cache. Keep the existing four-attempt retry. If no attempt verifies, the step fails with `::error::`.
- A comment beside `VER` says how to get both hashes when bumping the version.

Alternatives considered:

- **Drop the cache and download every run.** This closes the cache path but not the download path, and it brings back the flaky-download failures the cache was added to absorb (the 2026-09-10 honeycomb incident in the step's comment).
- **Use `gitleaks/gitleaks-action`.** It needs a licence key for organisations, and it moves trust to another unpinned action.
- **Move both steps into one composite action.** This would remove the duplication, but it is a larger change that every caller picks up. The test holds the two copies to the same pins instead.

## Proving test

`tests/gitleaks.test.sh`, new. It lifts both steps out of the workflow with PyYAML, as `tests/dispatch-ref.test.sh` does, and runs each with `curl` and `RUNNER_TOOL_CACHE` stubbed. It asserts:

1. A tampered cached binary is never run. It is replaced by a verified download, and the warning is logged.
2. A download whose archive hash is wrong is never extracted or run, and the step exits non-zero.
3. A cached binary with the right hash is used, and `curl` is never called for it.
4. Both steps carry the same `VER` and the same two hashes.

Cases 1 and 2 fail on main today. Cases 1 to 3 use a fixture archive and its own hashes, injected by rewriting the pins in the lifted script. Case 4 reads the real pins. pr-tests runs the file, and the existing `tests/tmp-paths.test.sh` keeps it free of literal `/tmp`.

## Proof on dev

There is no `-dev.beesec.co.uk` surface: this is GitHub Actions logic. The proof is:

- the R0 reproduction re-run against the fixed steps, which should show no `TAMPERED` or `SUBSTITUTED` line and a non-zero exit for the substituted download
- pr-tests green on the fix PR
- one real caller's PR run on a self-hosted `beesec-dev` runner, pointed at the fix branch, whose gate log shows gitleaks verified from the cache with no download

## Risk and rollback

- Every caller of `beesec-app.yml` picks this up. A wrong pinned hash would fail every gate's secret scan closed. The test's case 4 and a check against the published checksums file before merge guard that.
- A runner whose cache holds a genuine 8.28.0 binary verifies on the first run, so there is no extra download.
- Rollback is reverting the fix PR.
- #35, #38, #39 and #40 also touch the gate job. The fix PR should rebase cleanly or merge after them, whichever lands first.

## Execution plan

Pending: written by the issue creator after peer review approves this plan.
