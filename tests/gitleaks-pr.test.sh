#!/usr/bin/env bash
# Tests for the gitleaks history scan of a PR's own commits in beesec-app.yml
# (docs/security-gate-plan.md, check 1). The step's script is lifted out of
# the workflow and run against throwaway repositories with gitleaks stubbed:
# the stub fails when any commit in the range it is given adds a line with
# FAKESECRET, so what is tested is which commits the step hands gitleaks.
# When gitleaks 8.28.0 is on PATH as gitleaks-real, one case also runs it.
#
#   bash tests/gitleaks-pr.test.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
WF="$HERE/../.github/workflows/beesec-app.yml"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fails=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s: %s\n' "$1" "$2"; fails=$((fails + 1)); }

python3 - "$WF" > "$T/steps.json" <<'EOF' || { echo "FAIL  could not read $WF"; exit 1; }
import json, re, sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
for job in ("pick", "gate"):
    for s in wf["jobs"][job]["steps"]:
        if s.get("id") == "gitleaks_pr":
            print(json.dumps({"job": job, "step": s}))
        if "gitleaks" in s.get("name", "") and "dir ." in s.get("run", ""):
            m = re.search(r"^\s*VER=(\S+)", s["run"], re.M)
            print(json.dumps({"job": job, "dir_ver": m.group(1) if m else None}))
EOF

# --- the workflow wiring --------------------------------------------------

for job in pick gate; do
  s=$(jq -c --arg j "$job" 'select(.job == $j and .step) | .step' "$T/steps.json")
  if [ -z "$s" ]; then fail "$job has a gitleaks_pr step" "no step with id gitleaks_pr"; continue; fi
  pass "$job has a gitleaks_pr step"
  printf '%s' "$s" | jq -e '.if | test("inputs.security_checks") and test("github.event_name == .pull_request.")' >/dev/null \
    && pass "$job gitleaks_pr runs only on a PR with security_checks on" \
    || fail "$job gitleaks_pr runs only on a PR with security_checks on" "if: is $(printf '%s' "$s" | jq -c .if)"
  printf '%s' "$s" | jq -e '."continue-on-error" == "${{ !inputs.security_enforce }}"' >/dev/null \
    && pass "$job gitleaks_pr is shadow until security_enforce" \
    || fail "$job gitleaks_pr is shadow until security_enforce" "continue-on-error is $(printf '%s' "$s" | jq -c '."continue-on-error"')"
  printf '%s' "$s" | jq -e '.env.BASE == "${{ github.event.pull_request.base.sha }}" and .env.PR_HEAD == "${{ github.event.pull_request.head.sha }}" and .env.COMMITS == "${{ github.event.pull_request.commits }}"' >/dev/null \
    && pass "$job gitleaks_pr takes base, head and commit count from the event, through env" \
    || fail "$job gitleaks_pr takes base, head and commit count from the event, through env" "env is $(printf '%s' "$s" | jq -c .env)"
  printf '%s' "$s" | jq -e '.run | test("\\$\\{\\{") | not' >/dev/null \
    && pass "$job gitleaks_pr interpolates nothing into its script" \
    || fail "$job gitleaks_pr interpolates nothing into its script" "found \${{ }} in run"
  v=$(printf '%s' "$s" | jq -r '.run' | sed -n 's/^ *VER=\(\S*\)$/\1/p')
  d=$(jq -r --arg j "$job" 'select(.job == $j and .dir_ver) | .dir_ver' "$T/steps.json")
  [ -n "$v" ] && [ "$v" = "$d" ] \
    && pass "$job gitleaks_pr uses the same gitleaks version as the dir scan" \
    || fail "$job gitleaks_pr uses the same gitleaks version as the dir scan" "history '$v', dir '$d'"
done
a=$(jq -c 'select(.job == "pick" and .step) | .step | {run, env}' "$T/steps.json")
b=$(jq -c 'select(.job == "gate" and .step) | .step | {run, env}' "$T/steps.json")
[ -n "$a" ] && [ "$a" = "$b" ] \
  && pass "the pick and gate copies are identical" \
  || fail "the pick and gate copies are identical" "they differ"

# --- the behaviour --------------------------------------------------------

script=$(jq -r 'select(.job == "gate" and .step) | .step.run' "$T/steps.json")
[ -n "$script" ] || { echo "FAIL  no gate gitleaks_pr script to run"; echo "$fails failed"; exit 1; }
# The step reads the config the dir-scan step before it fetched. Point that
# one path at this test's own copy.
printf '%s\n' "$script" | sed "s#/tmp/gitleaks.toml#$T/gitleaks.toml#g" > "$T/step.sh"
printf '[extend]\nuseDefault = true\n' > "$T/gitleaks.toml"

VER=$(printf '%s\n' "$script" | sed -n 's/^ *VER=\(\S*\)$/\1/p')
CACHE="$T/toolcache"; mkdir -p "$CACHE/gitleaks/$VER"
STUB="$CACHE/gitleaks/$VER/gitleaks"
cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
# Records its arguments, then fails when the commits named by --log-opts add
# a FAKESECRET line, the way gitleaks fails on a finding.
[ "${1:-}" = version ] && { echo 8.28.0; exit 0; }
printf '%s\n' "$*" > "$GL_ARGS"
[ "${1:-}" = git ] || { echo "stub: expected the git subcommand"; exit 2; }
opts=""; cfg=""
for a; do case "$a" in --log-opts=*) opts=${a#--log-opts=} ;; esac; done
prev=""; for a; do [ "$prev" = -c ] && cfg=$a; prev=$a; done
[ -f "$cfg" ] || { echo "stub: no config at '$cfg'"; exit 2; }
# shellcheck disable=SC2086
git log -p --format=%H $opts > "$GL_ARGS.log" 2>"$GL_ARGS.err" || { cat "$GL_ARGS.err"; exit 2; }
if grep -q '^+.*FAKESECRET' "$GL_ARGS.log"; then echo "leaks found: 1"; exit 1; fi
echo "no leaks found"
EOF
chmod +x "$STUB"

mkrepo() {
  R="$T/repo.$1"; rm -rf "$R" "$R.origin"; mkdir -p "$R.origin"
  git -C "$R.origin" init -q -b main
  git -C "$R.origin" config user.email t@example.invalid; git -C "$R.origin" config user.name t
  git -C "$R.origin" config uploadpack.allowAnySHA1InWant true
  for i in 1 2 3; do printf 'base %s\n' "$i" >> "$R.origin/app.py"; git -C "$R.origin" add -A; git -C "$R.origin" commit -qm "base $i"; done
  BASE=$(git -C "$R.origin" rev-parse HEAD)
  git -C "$R.origin" switch -q -c pr
}
# pr_commit <content line> : one PR commit on the origin's pr branch.
pr_commit() { printf '%s\n' "$1" >> "$R.origin/app.py"; git -C "$R.origin" add -A; git -C "$R.origin" commit -qm "pr: $1"; }
# The checkout a runner does: depth 1 of the PR head, as actions/checkout.
checkout() {
  HEADSHA=$(git -C "$R.origin" rev-parse HEAD)
  N=$(git -C "$R.origin" rev-list --count "$BASE..$HEADSHA")
  git clone -q --depth=1 --no-local --branch pr "file://$R.origin" "$R" 2>/dev/null
}
run() {  # name expect [COMMITS override]
  out=$(cd "$R" && RUNNER_TOOL_CACHE="$CACHE" GL_ARGS="$T/args" EVENT=pull_request BASE="$BASE" PR_HEAD="$HEADSHA" COMMITS="${3:-$N}" bash "$T/step.sh" 2>&1); rc=$?
  if [ "$rc" = "$2" ]; then pass "$1"; else fail "$1" "rc=$rc, expected $2: $(printf '%s' "$out" | tail -3 | tr '\n' ' ')"; fi
}

mkrepo clean; pr_commit "x = 1"; pr_commit "y = 2"; checkout
run "a PR with no secret passes" 0
grep -q -- "--log-opts=$BASE..$HEADSHA" "$T/args" \
  && pass "gitleaks is given exactly the PR's range" \
  || fail "gitleaks is given exactly the PR's range" "args: $(cat "$T/args")"
grep -qw -- "--redact" "$T/args" && pass "findings are redacted" || fail "findings are redacted" "no --redact in: $(cat "$T/args")"
n=$(grep -cE '^[0-9a-f]{40}$' "$T/args.log")
[ "$n" = 2 ] && pass "only the PR's two commits are scanned" || fail "only the PR's two commits are scanned" "$n commits"

mkrepo removed; pr_commit "token = FAKESECRET"; printf 'clean\n' > "$R.origin/app.py"; git -C "$R.origin" commit -qam "pr: remove it"; checkout
grep -q FAKESECRET "$R/app.py" && fail "setup" "the tree still has the secret" || true
run "a secret added and then removed inside the PR fails" 1

mkrepo deep; for i in $(seq 1 12); do pr_commit "line $i"; done; pr_commit "k = FAKESECRET"; for i in $(seq 13 20); do pr_commit "line $i"; done; checkout
run "a secret buried among twenty-one commits fails" 1

mkrepo baseold; git -C "$R.origin" switch -q main; printf 'old = FAKESECRET\n' >> "$R.origin/app.py"; git -C "$R.origin" commit -qam "old secret on main"
BASE=$(git -C "$R.origin" rev-parse HEAD); git -C "$R.origin" switch -q -C pr; pr_commit "z = 3"; checkout
run "a secret already on the base, outside the PR, does not fail the PR" 0

mkrepo badcount; pr_commit "x = 1"; checkout
run "a non-numeric commit count fails" 1 "1; rm -rf /"
run "a zero commit count fails" 1 "0"

mkrepo badbase; pr_commit "x = 1"; checkout; BASE="not-a-sha"
run "a malformed base fails" 1

mkrepo nobin; pr_commit "x = 1"; checkout
out=$(cd "$R" && RUNNER_TOOL_CACHE="$T/empty" GL_ARGS="$T/args" EVENT=pull_request BASE="$BASE" PR_HEAD="$HEADSHA" COMMITS="$N" bash "$T/step.sh" 2>&1); rc=$?
[ "$rc" != 0 ] && pass "a missing gitleaks binary fails" || fail "a missing gitleaks binary fails" "rc=$rc"

if command -v gitleaks-real >/dev/null; then
  cp "$(command -v gitleaks-real)" "$STUB"
  # Made up at run time, so this file never holds a secret-shaped literal.
  tok="ghp_$(head -c 400 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 36)"
  mkrepo real; printf 'token = "%s"\n' "$tok" > "$R.origin/conf.ini"
  git -C "$R.origin" add -A; git -C "$R.origin" commit -qm "pr: add"; git -C "$R.origin" rm -q conf.ini; git -C "$R.origin" commit -qm "pr: remove"; checkout
  run "real gitleaks finds a removed AWS key in the PR's history" 1
else
  echo "SKIP  real gitleaks (no gitleaks-real on PATH)"
fi

echo
[ "$fails" = 0 ] && echo "all passed" || echo "$fails failed"
[ "$fails" = 0 ]
