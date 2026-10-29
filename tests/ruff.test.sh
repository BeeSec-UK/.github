#!/usr/bin/env bash
# Tests for the Python security lint in beesec-app.yml (docs/security-gate-plan.md,
# check 3, the Ruff half). The step's script is lifted out of the workflow
# and run against throwaway repositories. Ruff is stubbed for the file
# selection cases; when ruff 0.17.0 is on PATH as ruff-real, the rule
# cases run it for real.
#
#   bash tests/ruff.test.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
WF="$HERE/../.github/workflows/beesec-app.yml"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fails=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s: %s\n' "$1" "$2"; fails=$((fails + 1)); }

python3 - "$WF" > "$T/steps.json" <<'EOF' || { echo "FAIL  could not read $WF"; exit 1; }
import json, sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
for job, j in wf["jobs"].items():
    for s in j.get("steps", []):
        if s.get("id") == "ruff":
            print(json.dumps({"job": job, "step": s}))
EOF

# --- the workflow wiring --------------------------------------------------

jobs=$(jq -r '.job' "$T/steps.json" | sort | paste -sd, -)
[ "$jobs" = gate ] && pass "the ruff step is in the gate only" || fail "the ruff step is in the gate only" "found in '$jobs'"
s=$(jq -c 'select(.job == "gate") | .step' "$T/steps.json")
script=$(printf '%s' "$s" | jq -r '.run // empty')
if [ -n "$s" ]; then
  printf '%s' "$s" | jq -e '.if | test("inputs.security_checks")' >/dev/null \
    && pass "it runs only when security_checks is on" || fail "it runs only when security_checks is on" "if: $(printf '%s' "$s" | jq -c .if)"
  printf '%s' "$s" | jq -e '."continue-on-error" == "${{ !inputs.security_enforce }}"' >/dev/null \
    && pass "it is shadow until security_enforce" || fail "it is shadow until security_enforce" "$(printf '%s' "$s" | jq -c '."continue-on-error"')"
  printf '%s' "$s" | jq -e '.env.EVENT == "${{ github.event_name }}" and .env.BASE == "${{ github.event.pull_request.base.sha }}"' >/dev/null \
    && pass "it takes the event and PR base through env" || fail "it takes the event and PR base through env" "env: $(printf '%s' "$s" | jq -c .env)"
  printf '%s' "$s" | jq -e '.run | test("\\$\\{\\{") | not' >/dev/null \
    && pass "it interpolates nothing into its script" || fail "it interpolates nothing into its script" "found \${{ }} in run"
fi
printf '%s\n' "$script" | grep -qE '^ *VER=0\.17\.0$' && pass "ruff is pinned to 0.17.0" || fail "ruff is pinned to 0.17.0" "no VER=0.17.0"
printf '%s\n' "$script" | grep -qE '^ *SHA256=[0-9a-f]{64}$' && pass "the archive's SHA-256 is pinned" || fail "the archive's SHA-256 is pinned" "no SHA256="
printf '%s\n' "$script" | grep -q -- '--isolated' && pass "a caller's own ruff config cannot turn the rules off" || fail "a caller's own ruff config cannot turn the rules off" "no --isolated"

# --- the behaviour --------------------------------------------------------

[ -n "$script" ] || { echo "FAIL  no ruff script to run"; echo "$fails failed"; exit 1; }
printf '%s\n' "$script" > "$T/step.sh"
VER=$(printf '%s\n' "$script" | sed -n 's/^ *VER=\(\S*\)$/\1/p')
CACHE="$T/toolcache"; mkdir -p "$CACHE/ruff/$VER"
STUB="$CACHE/ruff/$VER/ruff"
# The stub records the files it is handed and passes.
cat > "$T/ruff-stub" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = --version ] && { echo "ruff 0.17.0"; exit 0; }
for a; do case "$a" in *.py) echo "$a" ;; esac; done >> "$RUFF_FILES"
exit 0
EOF
chmod +x "$T/ruff-stub"; cp "$T/ruff-stub" "$STUB"

mkrepo() {
  R="$T/repo.$1"; rm -rf "$R"; mkdir -p "$R/api/tests"
  git -C "$R" init -q -b main
  git -C "$R" config user.email t@example.invalid; git -C "$R" config user.name t
  git -C "$R" remote add origin "$R"
  printf 'import os\n' > "$R/api/old.py"
  git -C "$R" add -A; git -C "$R" commit -qm base
  BASE=$(git -C "$R" rev-parse HEAD)
}
commit() { git -C "$R" add -A; git -C "$R" commit -qm pr; }
run() {  # name expect event base
  : > "$T/files"
  out=$(cd "$R" && RUNNER_TOOL_CACHE="$CACHE" RUFF_FILES="$T/files" EVENT="$3" BASE="$4" bash "$T/step.sh" 2>&1); rc=$?
  if [ "$rc" = "$2" ]; then pass "$1"; else fail "$1" "rc=$rc, expected $2: $(printf '%s' "$out" | tail -4 | tr '\n' ' ')"; fi
}
says() { case "$out" in *"$2"*) pass "$1" ;; *) fail "$1" "output lacks '$2': $(printf '%s' "$out" | tail -3 | tr '\n' ' ')" ;; esac; }
linted() { grep -qxF "$2" "$T/files" && pass "$1" || fail "$1" "linted: $(paste -sd' ' "$T/files")"; }
skipped() { grep -qxF "$2" "$T/files" && fail "$1" "it linted $2" || pass "$1"; }

mkrepo sel; printf 'x = 1\n' > "$R/api/new.py"; mkdir -p "$R/.venv/lib" "$R/api/venv/x"
printf 'x = 1\n' > "$R/.venv/lib/a.py"; printf 'x = 1\n' > "$R/api/venv/x/b.py"; commit
run "a PR is linted" 0 pull_request "$BASE"
linted "it lints the Python the PR changes" api/new.py
skipped "it leaves Python the PR did not touch" api/old.py
skipped "it never lints a committed .venv" .venv/lib/a.py
skipped "it never lints a committed venv" api/venv/x/b.py

mkrepo push; printf 'x = 1\n' > "$R/api/new.py"; commit
run "a push is linted" 0 push ""
linted "a push lints every tracked Python file" api/old.py

mkrepo del; git -C "$R" rm -q api/old.py; commit
run "a PR that only deletes Python passes without linting" 0 pull_request "$BASE"
[ -s "$T/files" ] && fail "and ruff is not run" "it was" || pass "and ruff is not run"

mkrepo nopy; printf 'hi\n' > "$R/README.md"; commit
run "a PR with no Python passes" 0 pull_request "$BASE"

mkrepo badbase; printf 'x = 1\n' > "$R/api/new.py"; commit
run "a PR whose base cannot be fetched fails" 1 pull_request 0123456789abcdef0123456789abcdef01234567

# Suppressions. A `# noqa: S<code>` must say why, after the code.
mkrepo noqa; printf 'a = eval("1")  # noqa: S307\n' > "$R/api/new.py"; commit
run "a security noqa with no reason fails" 1 pull_request "$BASE"
says "it names the file and line" "api/new.py:1"
mkrepo noqa2; printf 'a = eval("1")  # noqa: E501, S307\n' > "$R/api/new.py"; commit
run "a security noqa among other codes, with no reason, fails" 1 pull_request "$BASE"
mkrepo noqa3; printf 'a = eval("1")  # noqa: S307 the input is a literal in this file\n' > "$R/api/new.py"; commit
run "a security noqa with a reason passes" 0 pull_request "$BASE"
mkrepo noqa4; printf 'a = 1  # noqa: E501\n' > "$R/api/new.py"; commit
run "a non-security noqa needs no reason here" 0 pull_request "$BASE"

# The download is checked against the pinned SHA-256 before it is used.
mkdir -p "$T/bin"
cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
out=""; prev=""; for a; do [ "$prev" = -o ] && out=$a; prev=$a; done
echo "$*" >> "$CURL_LOG"; cp "$CURL_BODY" "$out"
EOF
printf '#!/bin/sh\nexit 0\n' > "$T/bin/sleep"; chmod +x "$T/bin/curl" "$T/bin/sleep"
mkdir -p "$T/fake/ruff-x86_64-unknown-linux-gnu"
printf '#!/bin/sh\necho "the unchecked download ran" >> "$RUFF_FILES"\nexit 0\n' > "$T/fake/ruff-x86_64-unknown-linux-gnu/ruff"
chmod +x "$T/fake/ruff-x86_64-unknown-linux-gnu/ruff"; tar czf "$T/fake.tgz" -C "$T/fake" ruff-x86_64-unknown-linux-gnu
mkrepo fetch; printf 'x = 1\n' > "$R/api/new.py"; commit
: > "$T/files"; : > "$T/curl.log"
out=$(cd "$R" && PATH="$T/bin:$PATH" RUNNER_TOOL_CACHE="$T/empty" RUFF_FILES="$T/files" CURL_LOG="$T/curl.log" CURL_BODY="$T/fake.tgz" \
      EVENT=pull_request BASE="$BASE" bash "$T/step.sh" 2>&1); rc=$?
[ "$rc" != 0 ] && pass "a download that fails the checksum fails" || fail "a download that fails the checksum fails" "rc=$rc"
grep -q "unchecked download ran" "$T/files" && fail "and the download is never run" "it ran" || pass "and the download is never run"
[ -s "$T/curl.log" ] && pass "and a download was tried" || fail "and a download was tried" "curl was not called"

if command -v ruff-real >/dev/null; then
  cp "$(command -v ruff-real)" "$STUB"
  mkrepo real; printf 'import subprocess\n\ndef run(cmd):\n    subprocess.call(cmd, shell=True)\n' > "$R/api/new.py"; commit
  run "real ruff fails subprocess with shell=True" 1 pull_request "$BASE"
  says "and names the rule" "S602"
  mkrepo realtest; printf 'def test_x():\n    assert 1 + 1 == 2\n' > "$R/api/tests/test_x.py"; commit
  run "real ruff allows assert in tests" 0 pull_request "$BASE"
  mkrepo realapp; printf 'def f(x):\n    assert x\n' > "$R/api/new.py"; commit
  run "real ruff fails assert in app code" 1 pull_request "$BASE"
  mkrepo realblanket; printf 'a = eval("1")  # noqa\n' > "$R/api/new.py"; commit
  run "real ruff fails a blanket noqa" 1 pull_request "$BASE"
  mkrepo realcfg; printf '[tool.ruff.lint]\nignore = ["S"]\n' > "$R/pyproject.toml"; printf 'a = eval("1")\n' > "$R/api/new.py"; commit
  run "real ruff ignores a caller config that turns S off" 1 pull_request "$BASE"
  # Without --isolated a caller exclude would silence the rules. A plain
  # `ignore` or per-file-ignores does not, because the command line wins.
  mkrepo realpfi; printf '[tool.ruff.lint.per-file-ignores]\n"api/*" = ["S"]\n' > "$R/pyproject.toml"; printf 'a = eval("1")\n' > "$R/api/new.py"; commit
  run "real ruff ignores a caller's per-file-ignores of S" 1 pull_request "$BASE"
  mkrepo realexcl; printf 'exclude = ["api"]\nforce-exclude = true\n' > "$R/ruff.toml"; printf 'a = eval("1")\n' > "$R/api/new.py"; commit
  run "real ruff ignores a caller's exclude" 1 pull_request "$BASE"
  mkrepo realhelper; printf 'def check(x):\n    assert x\n' > "$R/api/tests/helpers.py"; commit
  run "real ruff allows assert in a tests/ helper that is not test_*.py" 0 pull_request "$BASE"
else
  echo "SKIP  real ruff (no ruff-real on PATH)"
fi

echo
[ "$fails" = 0 ] && echo "all passed" || echo "$fails failed"
[ "$fails" = 0 ]
