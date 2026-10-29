#!/usr/bin/env bash
# Tests for the client-data scrub step in beesec-app.yml (docs/security-gate-plan.md,
# check 5). The step's script is lifted out of the workflow and run against
# throwaway git repositories, so what is tested is the YAML that ships.
#
#   bash tests/scrub.test.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
WF="$HERE/../.github/workflows/beesec-app.yml"
CLI=/opt/beesec/claude-project-setup/bin/beesec
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fails=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s: %s\n' "$1" "$2"; fails=$((fails + 1)); }

# The step as YAML, per job, as JSON lines: {"job":..,"step":{..}}.
python3 - "$WF" > "$T/steps.json" <<'EOF' || { echo "FAIL  could not read $WF"; exit 1; }
import json, sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
inputs = wf[True]["workflow_call"]["inputs"]  # PyYAML reads `on:` as True
print(json.dumps({"inputs": {k: inputs.get(k) for k in ("security_checks", "security_enforce")}}))
for job in ("pick", "gate"):
    for s in wf["jobs"][job]["steps"]:
        if s.get("id") == "scrub":
            print(json.dumps({"job": job, "step": s}))
EOF

# --- the workflow wiring --------------------------------------------------

jq -e 'select(.inputs) | .inputs.security_checks | .type == "boolean" and .default == false' "$T/steps.json" >/dev/null \
  && pass "security_checks is a boolean input, default off" \
  || fail "security_checks is a boolean input, default off" "missing or wrong"
jq -e 'select(.inputs) | .inputs.security_enforce | .type == "boolean" and .default == false' "$T/steps.json" >/dev/null \
  && pass "security_enforce is a boolean input, default off" \
  || fail "security_enforce is a boolean input, default off" "missing or wrong"

for job in pick gate; do
  s=$(jq -c --arg j "$job" 'select(.job == $j) | .step' "$T/steps.json")
  if [ -z "$s" ]; then fail "$job has a scrub step" "no step with id scrub"; continue; fi
  pass "$job has a scrub step"
  printf '%s' "$s" | jq -e '.if | test("inputs.security_checks")' >/dev/null \
    && pass "$job scrub runs only when security_checks is on" \
    || fail "$job scrub runs only when security_checks is on" "if: is $(printf '%s' "$s" | jq -c .if)"
  printf '%s' "$s" | jq -e '."continue-on-error" == "${{ !inputs.security_enforce }}"' >/dev/null \
    && pass "$job scrub is shadow until security_enforce" \
    || fail "$job scrub is shadow until security_enforce" "continue-on-error is $(printf '%s' "$s" | jq -c '."continue-on-error"')"
  printf '%s' "$s" | jq -e '.env.PATTERNS == "${{ secrets.CLIENT_SCRUB_PATTERNS }}"' >/dev/null \
    && pass "$job scrub reads the list from the org secret, through env" \
    || fail "$job scrub reads the list from the org secret, through env" "env.PATTERNS is $(printf '%s' "$s" | jq -c .env.PATTERNS)"
  printf '%s' "$s" | jq -e '.run | test("secrets\\.|\\$\\{\\{") | not' >/dev/null \
    && pass "$job scrub interpolates nothing into its script" \
    || fail "$job scrub interpolates nothing into its script" "found \${{ }} in run"
done
a=$(jq -c 'select(.job == "pick") | .step | {run, env}' "$T/steps.json")
b=$(jq -c 'select(.job == "gate") | .step | {run, env}' "$T/steps.json")
[ -n "$a" ] && [ "$a" = "$b" ] \
  && pass "the pick and gate copies are identical" \
  || fail "the pick and gate copies are identical" "they differ"

# The path shape must be the one `beesec pr` refuses, so the two never drift.
script=$(jq -r 'select(.job == "gate") | .step.run' "$T/steps.json")
if [ -f "$CLI" ]; then
  cli=$(sed -n "s/^PRIVATE_SHAPED='\(.*\)'$/\1/p" "$CLI")
  wf=$(printf '%s\n' "$script" | sed -n "s/^ *PRIVATE_SHAPED='\(.*\)'$/\1/p")
  [ -n "$cli" ] && [ "$cli" = "$wf" ] \
    && pass "the path shape matches beesec pr's PRIVATE_SHAPED" \
    || fail "the path shape matches beesec pr's PRIVATE_SHAPED" "cli='$cli' workflow='$wf'"
else
  echo "SKIP  the path shape matches beesec pr's PRIVATE_SHAPED ($CLI not on this machine)"
fi

# --- the behaviour --------------------------------------------------------

[ -n "$script" ] || { echo "FAIL  no gate scrub script to run"; echo "$fails failed"; exit 1; }
printf '%s\n' "$script" > "$T/scrub.sh"

# A repository with one base commit; the caller adds the PR's changes on top.
# origin points at the repository itself, so the step's fetch of the base
# works offline.
mkrepo() {
  R="$T/repo.$1"; rm -rf "$R"; mkdir -p "$R"
  git -C "$R" init -q -b main
  git -C "$R" config user.email t@example.invalid; git -C "$R" config user.name t
  git -C "$R" remote add origin "$R"
  printf 'hello\nan old line naming acme-widgets\n' > "$R/README.md"
  git -C "$R" add -A; git -C "$R" commit -qm base
  BASE=$(git -C "$R" rev-parse HEAD)
}
commit() { git -C "$R" add -A; git -C "$R" commit -qm pr; }
# run <name> <expect rc> <event> <base> <patterns>
run() {
  out=$(cd "$R" && EVENT="$3" BASE="$4" PATTERNS="$5" bash "$T/scrub.sh" 2>&1); rc=$?
  if [ "$rc" = "$2" ]; then pass "$1"; else fail "$1" "rc=$rc, expected $2: $(printf '%s' "$out" | head -3 | tr '\n' ' ')"; fi
}
says()    { case "$out" in *"$2"*) pass "$1" ;; *) fail "$1" "output lacks '$2': $(printf '%s' "$out" | head -3 | tr '\n' ' ')" ;; esac; }
silent()  { if printf '%s' "$out" | grep -qiF -- "$2"; then fail "$1" "output contains '$2'"; else pass "$1"; fi; }

P=$'acme-widgets\nglobex.example'

mkrepo clean; printf 'new\n' > "$R/notes.md"; commit
run "a clean PR passes" 0 pull_request "$BASE" "$P"

mkrepo private; mkdir -p "$R/_private"; printf 'x\n' > "$R/_private/notes.md"; commit
run "a PR adding _private/ fails" 1 pull_request "$BASE" "$P"
says "it names the private path" "_private/notes.md"

for f in docs/findings-brain.json certs/client.pem deploy.key .ssh/id_rsa ops/secrets.md; do
  mkrepo shape; mkdir -p "$R/$(dirname "$f")"; printf 'x\n' > "$R/$f"; commit
  run "a PR adding $f fails" 1 pull_request "$BASE" "$P"
done

mkrepo delpriv; mkdir -p "$R/_private"; printf 'x\n' > "$R/_private/old.md"; commit
BASE=$(git -C "$R" rev-parse HEAD); git -C "$R" rm -q _private/old.md; commit
run "a PR deleting a private file passes" 0 pull_request "$BASE" "$P"

mkrepo hit; printf 'one\ntwo\nmeeting with ACME-Widgets today\n' > "$R/notes.md"; commit
run "an added line naming a client fails" 1 pull_request "$BASE" "$P"
says "it reports file and line" "notes.md:3"
silent "it never prints the matched text" "acme-widgets"
silent "it never prints the line around it" "meeting with"
silent "it never prints any pattern" "globex"

mkrepo old; printf 'unrelated\n' >> "$R/README.md"; commit
run "a client named only on an unchanged line passes" 0 pull_request "$BASE" "$P"

mkrepo del; printf 'hello\n' > "$R/README.md"; commit
run "a client named only on a deleted line passes" 0 pull_request "$BASE" "$P"

mkrepo space; mkdir -p "$R/my docs"; printf 'x\nglobex.example\n' > "$R/my docs/a b.md"; commit
run "a hit in a path with spaces fails" 1 pull_request "$BASE" "$P"
says "it reports that path and line" "my docs/a b.md:2"

mkrepo fixed; printf 'globexXexample\n' > "$R/notes.md"; commit
run "patterns are fixed strings, not regexes" 0 pull_request "$BASE" "$P"

mkrepo blank; printf 'new\n' > "$R/notes.md"; commit
run "blank lines and CRLF in the list match nothing" 0 pull_request "$BASE" $'acme-widgets\r\n\r\n\n  \n'

mkrepo crlf; printf 'acme-widgets\n' > "$R/notes.md"; commit
run "a CRLF list still matches" 1 pull_request "$BASE" $'globex.example\r\nacme-widgets\r\n'

mkrepo unset; printf 'new\n' > "$R/notes.md"; commit
run "an unset list fails" 1 pull_request "$BASE" ""
says "it says the secret is not set" "CLIENT_SCRUB_PATTERNS is not set"

mkrepo push; commit 2>/dev/null || true
run "a push scans the whole tree" 1 push "" "$P"
says "it reports the tree hit by file and line" "README.md:2"
silent "the tree scan never prints the matched text" "acme-widgets"

mkrepo pushpriv; mkdir -p "$R/_private"; printf 'x\n' > "$R/_private/v.md"; commit
run "a push with a private path in the tree fails" 1 push "" $'nothing-matches-this'

mkrepo nobase; printf 'new\n' > "$R/notes.md"; commit
run "a PR whose base cannot be fetched fails" 1 pull_request 0123456789abcdef0123456789abcdef01234567 "$P"

echo
[ "$fails" = 0 ] && echo "all passed" || echo "$fails failed"
[ "$fails" = 0 ]
