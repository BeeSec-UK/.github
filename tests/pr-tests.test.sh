#!/usr/bin/env bash
# Tests for .github/workflows/pr-tests.yml, the workflow that runs these
# tests on every pull request. This repository is public, so a fork's pull
# request runs whatever its branch holds: the workflow must stay on
# GitHub-hosted runners, with a read-only token and no stored credentials.
#
#   bash tests/pr-tests.test.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
WF="$HERE/../.github/workflows/pr-tests.yml"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

[ -f "$WF" ] || { echo "FAIL  $WF is missing"; exit 1; }

python3 - "$WF" > "$T/out" 2>&1 <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
# PyYAML reads a bare `on:` key as True.
on = wf.get("on", wf.get(True))
def check(name, ok, why=""):
    print(("PASS  " if ok else "FAIL  ") + name + ("" if ok else ": " + why))
check("runs on pull_request", isinstance(on, dict) and "pull_request" in on, repr(on))
check("never pull_request_target", not (isinstance(on, dict) and "pull_request_target" in on), repr(on))
check("the token is read-only", wf.get("permissions") == {"contents": "read"}, repr(wf.get("permissions")))
for j, job in wf["jobs"].items():
    r = job.get("runs-on")
    check(f"{j}: runs on a GitHub-hosted runner", isinstance(r, str) and r.startswith("ubuntu-"), repr(r))
    check(f"{j}: raises no permission", "permissions" not in job, repr(job.get("permissions")))
    steps = job.get("steps", [])
    co = [s for s in steps if str(s.get("uses", "")).startswith("actions/checkout")]
    check(f"{j}: has a plain check name", isinstance(job.get("name"), str) and job["name"].replace("-", "").isalnum(), repr(job.get("name")))
    for st in steps:
        u = str(st.get("uses", ""))
        if u:
            ref = u.rpartition("@")[2]
            check(f"{j}: {u.partition('@')[0]} is pinned to a commit SHA",
                  len(ref) == 40 and all(c in "0123456789abcdef" for c in ref), u)
    check(f"{j}: checkout keeps no credentials",
          bool(co) and all((s.get("with") or {}).get("persist-credentials") is False for s in co), repr(co))
    runs = " ".join(s.get("run", "") for s in steps)
    check(f"{j}: runs every tests/*.test.sh", "tests/*.test.sh" in runs, runs[:200])
PY
rc=$?
cat "$T/out"
fails=$(grep -c '^FAIL\|Error' "$T/out")
# A crash in the checker counts as a failure even if it printed no FAIL line.
[ "$rc" -eq 0 ] || { echo "FAIL  the checker exited $rc"; fails=$((fails + 1)); }

echo
[ "$fails" -eq 0 ] && echo "all passed" || echo "$fails failed"
[ "$fails" -eq 0 ]
