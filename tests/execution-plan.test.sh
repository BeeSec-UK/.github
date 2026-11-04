#!/usr/bin/env bash
# Tests for .github/workflows/execution-plan.yml, the check that a
# repository's docs/execution-plan.md has the standard Work packages table
# (orchestrator standards/execution-plan.md, operator, 4 Nov 2026). The
# workflow's own steps are lifted out of the YAML and run here, so the test
# runs the code the runner runs. Each rule has one passing and one failing
# fixture under tests/fixtures/execution-plan/.
#
#   bash tests/execution-plan.test.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
WF="$HERE/../.github/workflows/execution-plan.yml"
FX="$HERE/fixtures/execution-plan"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fails=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s: %s\n' "$1" "$2"; fails=$((fails + 1)); }

python3 - "$WF" "$T" <<'PY' || { echo "FAIL  could not read $WF"; exit 1; }
import json, sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
job = wf["jobs"]["plan"]
steps = {s.get("id"): s for s in job["steps"]}
open(sys.argv[2] + "/changed.sh", "w").write(steps["changed"]["run"])
open(sys.argv[2] + "/check.py", "w").write(steps["check"]["run"])
json.dump({"on": list(wf[True].keys()), "permissions": wf.get("permissions"),
           "job_permissions": job.get("permissions"), "if": job.get("if"),
           "check_if": steps["check"].get("if"), "check_shell": steps["check"].get("shell"),
           "checkout": [s for s in job["steps"] if "actions/checkout@" in s.get("uses", "")]},
          open(sys.argv[2] + "/wf.json", "w"))
PY
q() { jq -c "$1" "$T/wf.json"; }

# Wiring. Reusable only, no token beyond reading the repository, the token
# is not left in the checkout, and the check is skipped unless the plan
# changed.
[ "$(q .on)" = '["workflow_call"]' ] && pass "called only as a reusable workflow" || fail "trigger" "$(q .on)"
[ "$(q .permissions)" = '{}' ] && [ "$(q .job_permissions)" = '{"contents":"read"}' ] \
  && pass "permissions are contents: read on the job and nothing else" || fail "permissions" "$(q .permissions) $(q .job_permissions)"
[ "$(q '.checkout | length')" = 1 ] && [ "$(q '.checkout[0].with["persist-credentials"]')" = false ] \
  && [ "$(q '.checkout[0].with["fetch-depth"]')" = 2 ] \
  && pass "one checkout, depth 2, credentials not persisted" || fail "checkout" "$(q .checkout)"
case "$(q .check_if)" in *"steps.changed.outputs.plan == 'true'"*) pass "the check runs only when the plan changed";; *) fail "check if" "$(q .check_if)";; esac
case "$(q .if)" in *"github.event_name == 'pull_request'"*) pass "runs on pull requests";; *) fail "job if" "$(q .if)";; esac
[ "$(q .check_shell)" = '"python3 {0}"' ] && pass "the check is inline Python" || fail "shell" "$(q .check_shell)"

# The rules, one passing and one failing fixture each. A failing fixture
# must fail with errors about its own rule only.
declare -A KEY=(
  [heading]="no '## Work packages' heading"
  [header]="header row"
  [id]="is not a valid ID"
  [unique]="more than once"
  [numbers]="must be a number"
  [state]="State"
  [depends]="Depends on"
)
for rule in heading header id unique numbers state depends; do
  out=$(PLAN="$FX/$rule-pass.md" python3 "$T/check.py" 2>&1); rc=$?
  [ $rc = 0 ] && pass "$rule: passing fixture passes" || fail "$rule: passing fixture" "exit $rc: $out"
  out=$(PLAN="$FX/$rule-fail.md" python3 "$T/check.py" 2>&1); rc=$?
  errs=$(printf '%s\n' "$out" | grep '^::error ' || true)
  other=$(printf '%s\n' "$errs" | grep -vF -- "${KEY[$rule]}" || true)
  if [ $rc = 1 ] && [ -n "$errs" ] && [ -z "$other" ]; then
    pass "$rule: failing fixture fails on that rule"
  else
    fail "$rule: failing fixture" "exit $rc: $out"
  fi
done

# Errors carry the file and the line, so GitHub annotates the plan.
out=$(PLAN="$FX/state-fail.md" python3 "$T/check.py" 2>&1)
case "$out" in *"::error file=$FX/state-fail.md,line=9,"*) pass "errors name the file and line";; *) fail "annotation" "$out";; esac

# Change detection, run against a merge commit like the one a pull_request
# run checks out: first parent is the base tip, second the PR head.
mkrepo() {
  r="$T/repo-$1"; git init -q -b main "$r"; cd "$r" || exit 1
  git config user.email t@example.invalid; git config user.name t
  mkdir docs; echo one > docs/execution-plan.md; echo a > README.md
  git add .; git commit -qm base
  git checkout -qb pr; eval "$2"; git commit -qam pr --allow-empty
  git checkout -q main; echo b >> README.md; git commit -qam main-moved
  git merge -q --no-ff pr -m merge
  cd - >/dev/null || exit 1
}
detect() { (cd "$T/repo-$1" && GITHUB_OUTPUT="$T/out-$1" bash "$T/changed.sh" >/dev/null 2>&1) && cat "$T/out-$1"; }
mkrepo touched 'echo two > docs/execution-plan.md'
mkrepo untouched 'echo c > other.md; git add other.md'
[ "$(detect touched)" = plan=true ] && pass "a PR that edits the plan is checked" || fail "touched" "$(detect touched)"
[ "$(detect untouched)" = plan=false ] && pass "a PR that does not edit the plan is skipped" || fail "untouched" "$(detect untouched)"

echo
[ $fails = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
