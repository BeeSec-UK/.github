#!/usr/bin/env bash
# Tests for the Python security lint in beesec-app.yml (docs/security-gate-plan.md,
# check 3, the Ruff half). The step's script is lifted out of the workflow
# and run against throwaway repositories. Ruff is stubbed for the file
# selection cases, delivered as an archive whose hash replaces the pinned
# one in a copy of the step. The rule cases then run the real 0.17.0
# release, from RUFF_TGZ if set or else downloaded and checked against the
# pinned hash, and are skipped only when neither is available.
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

desc=$(python3 -c 'import sys, yaml; print(yaml.safe_load(open(sys.argv[1]))[True]["workflow_call"]["inputs"]["security_checks"]["description"])' "$WF" 2>/dev/null)
case "$desc" in
  *"or in pick when the gate is skipped"*) fail "security_checks says the lint runs in the gate only" "$desc" ;;
  *"lint does not run"*) pass "security_checks says the lint runs in the gate only" ;;
  *) fail "security_checks says the lint runs in the gate only" "no mention of the lint being gate-only: $desc" ;;
esac

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
PINNED=$(printf '%s\n' "$script" | sed -n 's/^ *SHA256=\([0-9a-f]*\)$/\1/p')
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
# The same stub as a release archive, and a copy of the step that pins its
# hash, so the step unpacks and runs it the way it would the real release.
mkdir -p "$T/stubpkg/ruff-x86_64-unknown-linux-gnu"; cp "$T/ruff-stub" "$T/stubpkg/ruff-x86_64-unknown-linux-gnu/ruff"
tar czf "$T/stub.tgz" -C "$T/stubpkg" ruff-x86_64-unknown-linux-gnu
STUBSHA=$(sha256sum "$T/stub.tgz" | cut -d' ' -f1)
cp "$T/stub.tgz" "$CACHE/ruff/$VER/ruff.tgz"
sed "s/^\( *SHA256=\)[0-9a-f]*$/\1$STUBSHA/" "$T/step.sh" > "$T/step-stub.sh"
STEP="$T/step-stub.sh"; RUN_CACHE="$CACHE"

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
  rm -rf "$T/rtemp"; mkdir -p "$T/rtemp"
  out=$(cd "$R" && RUNNER_TEMP="$T/rtemp" RUNNER_TOOL_CACHE="$RUN_CACHE" RUFF_FILES="$T/files" EVENT="$3" BASE="$4" bash "$STEP" 2>&1); rc=$?
  if [ "$rc" = "$2" ]; then pass "$1"; else fail "$1" "rc=$rc, expected $2: $(printf '%s' "$out" | tail -4 | tr '\n' ' ')"; fi
}
says() { case "$out" in *"$2"*) pass "$1" ;; *) fail "$1" "output lacks '$2': $(printf '%s' "$out" | tail -3 | tr '\n' ' ')" ;; esac; }
linted() { grep -qxF "$2" "$T/files" && pass "$1" || fail "$1" "linted: $(paste -sd' ' "$T/files")"; }
skipped() { grep -qxF "$2" "$T/files" && fail "$1" "it linted $2" || pass "$1"; }

mkrepo sel; printf 'x = 1\n' > "$R/api/new.py"
mkdir -p "$R/.venv/lib/python3.12/site-packages/pkg" "$R/api/.python_packages/lib/site-packages/pkg" "$R/web/node_modules/gyp" "$R/api/venv"
printf 'x = 1\n' > "$R/.venv/lib/python3.12/site-packages/pkg/a.py"
printf 'x = 1\n' > "$R/api/.python_packages/lib/site-packages/pkg/b.py"
printf 'x = 1\n' > "$R/web/node_modules/gyp/c.py"
printf 'x = 1\n' > "$R/api/venv/handler.py"; commit
run "a PR is linted" 0 pull_request "$BASE"
linted "it lints the Python the PR changes" api/new.py
skipped "it leaves Python the PR did not touch" api/old.py
skipped "it never lints a committed virtualenv's packages" .venv/lib/python3.12/site-packages/pkg/a.py
skipped "it never lints vendored Functions packages" api/.python_packages/lib/site-packages/pkg/b.py
skipped "it never lints node_modules" web/node_modules/gyp/c.py
linted "it lints app code under a directory merely named venv" api/venv/handler.py

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
# Ruff reads the noqa keyword in any case and allows space before its colon.
mkrepo noqa5; printf 'a = eval("1")  # NOQA: S307\n' > "$R/api/new.py"; commit
run "an upper-case security NOQA with no reason fails" 1 pull_request "$BASE"
mkrepo noqa6; printf 'a = eval("1")  #noqa : S307\n' > "$R/api/new.py"; commit
run "a security noqa with a space before its colon, with no reason, fails" 1 pull_request "$BASE"
mkrepo noqa7; printf 'a = eval("1")  # NOQA: S307 the input is a literal in this file\n' > "$R/api/new.py"; commit
run "an upper-case security NOQA with a reason passes" 0 pull_request "$BASE"
# A file-level exemption of a security rule covers the whole file, so it is
# refused outright, reason or not.
mkrepo file1; printf '# ruff: noqa: S307\na = eval("1")\n' > "$R/api/new.py"; commit
run "a file-level ruff noqa of a security rule fails" 1 pull_request "$BASE"
says "and names the file and line" "api/new.py:1"
mkrepo file2; printf '# flake8: noqa: S307\na = eval("1")\n' > "$R/api/new.py"; commit
run "a file-level flake8 noqa of a security rule fails" 1 pull_request "$BASE"
mkrepo file3; printf 'x = 1\n#ruff:NOQA:E501,S307 the input is a literal\na = eval("1")\n' > "$R/api/new.py"; commit
run "a file-level security noqa fails even with a reason, in any case and spacing" 1 pull_request "$BASE"
# Not anchored to the line start, so a trailing one or one after a UTF-8
# byte-order mark is refused too. A false match only fails closed.
mkrepo file5; printf 'x = 1  # ruff: noqa: S307\na = eval("1")\n' > "$R/api/new.py"; commit
run "a trailing file-level security noqa fails" 1 pull_request "$BASE"
mkrepo file6; printf '\xef\xbb\xbf# ruff: noqa: S307\na = eval("1")\n' > "$R/api/new.py"; commit
run "a file-level security noqa after a byte-order mark fails" 1 pull_request "$BASE"
mkrepo file4; printf '# ruff: noqa: E501\na = 1\n' > "$R/api/new.py"; commit
run "a file-level noqa of a non-security rule passes" 0 pull_request "$BASE"
# A range suppression is held to the line rule: it must say why.
mkrepo range1; printf '# ruff: disable[S307]\na = eval("1")\n# ruff: enable[S307]\n' > "$R/api/new.py"; commit
run "a ruff disable range of a security rule with no reason fails" 1 pull_request "$BASE"
mkrepo range2; printf '# ruff: disable[E501, S307] the input is a literal\na = eval("1")\n' > "$R/api/new.py"; commit
run "a ruff disable range of a security rule with a reason passes" 0 pull_request "$BASE"

# The tool cache is shared by every job on a self-hosted runner, so nothing
# in it is run unchecked. A binary planted there is never run, and a cached
# archive that fails the pinned hash is fetched again.
PLANT="$T/plantcache"; mkdir -p "$PLANT/ruff/$VER"
printf '#!/bin/sh\necho "the planted binary ran" >> "$RUFF_FILES"\nexit 0\n' > "$PLANT/ruff/$VER/ruff"; chmod +x "$PLANT/ruff/$VER/ruff"
cp "$T/stub.tgz" "$PLANT/ruff/$VER/ruff.tgz"
mkrepo plant; printf 'x = 1\n' > "$R/api/new.py"; commit
RUN_CACHE="$PLANT" run "a PR is linted with a binary planted in the tool cache" 0 pull_request "$BASE"
grep -q "planted binary ran" "$T/files" && fail "and the planted binary is never run" "it ran" || pass "and the planted binary is never run"
linted "and the checked archive's ruff lints the PR" api/new.py

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
: > "$T/files"; : > "$T/curl.log"; rm -rf "$T/rtemp"; mkdir -p "$T/rtemp"
out=$(cd "$R" && PATH="$T/bin:$PATH" RUNNER_TEMP="$T/rtemp" RUNNER_TOOL_CACHE="$T/empty" RUFF_FILES="$T/files" CURL_LOG="$T/curl.log" CURL_BODY="$T/fake.tgz" \
      EVENT=pull_request BASE="$BASE" bash "$STEP" 2>&1); rc=$?
[ "$rc" != 0 ] && pass "a download that fails the checksum fails" || fail "a download that fails the checksum fails" "rc=$rc"
grep -q "unchecked download ran" "$T/files" && fail "and the download is never run" "it ran" || pass "and the download is never run"
[ -s "$T/curl.log" ] && pass "and a download was tried" || fail "and a download was tried" "curl was not called"

TAMPER="$T/tampercache"; mkdir -p "$TAMPER/ruff/$VER"; cp "$T/fake.tgz" "$TAMPER/ruff/$VER/ruff.tgz"
mkrepo tamper; printf 'x = 1\n' > "$R/api/new.py"; commit
: > "$T/files"; : > "$T/curl.log"; rm -rf "$T/rtemp"; mkdir -p "$T/rtemp"
out=$(cd "$R" && PATH="$T/bin:$PATH" RUNNER_TEMP="$T/rtemp" RUNNER_TOOL_CACHE="$TAMPER" RUFF_FILES="$T/files" CURL_LOG="$T/curl.log" CURL_BODY="$T/stub.tgz" \
      EVENT=pull_request BASE="$BASE" bash "$STEP" 2>&1); rc=$?
[ "$rc" = 0 ] && pass "a cached archive that fails the checksum is fetched again" || fail "a cached archive that fails the checksum is fetched again" "rc=$rc: $(printf '%s' "$out" | tail -3 | tr '\n' ' ')"
grep -q "unchecked download ran" "$T/files" && fail "and the tampered archive is never run" "it ran" || pass "and the tampered archive is never run"
[ -s "$T/curl.log" ] && pass "and a fresh download was tried" || fail "and a fresh download was tried" "curl was not called"

# With neither a tool cache nor RUNNER_TOOL_CACHE, it works from RUNNER_TEMP.
mkrepo nocache; printf 'x = 1\n' > "$R/api/new.py"; commit
: > "$T/files"; : > "$T/curl.log"; rm -rf "$T/rtemp"; mkdir -p "$T/rtemp"
out=$(cd "$R" && env -u RUNNER_TOOL_CACHE PATH="$T/bin:$PATH" RUNNER_TEMP="$T/rtemp" RUFF_FILES="$T/files" CURL_LOG="$T/curl.log" CURL_BODY="$T/stub.tgz" \
      EVENT=pull_request BASE="$BASE" bash "$STEP" 2>&1); rc=$?
[ "$rc" = 0 ] && pass "with no RUNNER_TOOL_CACHE it runs from RUNNER_TEMP" || fail "with no RUNNER_TOOL_CACHE it runs from RUNNER_TEMP" "rc=$rc: $(printf '%s' "$out" | tail -3 | tr '\n' ' ')"

# The real release, checked against the pinned hash, for the rule cases.
REAL="$T/realcache/ruff/$VER"; mkdir -p "$REAL"
if [ -n "${RUFF_TGZ:-}" ]; then cp "$RUFF_TGZ" "$REAL/ruff.tgz"
else curl -sSfL --retry 3 -o "$REAL/ruff.tgz" "https://github.com/astral-sh/ruff/releases/download/${VER}/ruff-x86_64-unknown-linux-gnu.tar.gz" 2>/dev/null || rm -f "$REAL/ruff.tgz"
fi
if [ -s "$REAL/ruff.tgz" ] && [ "$(sha256sum "$REAL/ruff.tgz" | cut -d' ' -f1)" = "$PINNED" ]; then
  pass "the pinned SHA-256 is the real ruff $VER release archive's"
  STEP="$T/step.sh"; RUN_CACHE="$T/realcache"
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
  mkrepo realupper; printf 'a = eval("1")  # NOQA: S307\n' > "$R/api/new.py"; commit
  run "real ruff with an upper-case security NOQA and no reason fails" 1 pull_request "$BASE"
  mkrepo realfile; printf '# ruff: noqa: S307\na = eval("1")\n' > "$R/api/new.py"; commit
  run "real ruff with a file-level security noqa fails" 1 pull_request "$BASE"
  mkrepo realfiletrail; printf 'x = 1  # ruff: noqa: S307\na = eval("1")\n' > "$R/api/new.py"; commit
  run "real ruff with a trailing file-level security noqa fails" 1 pull_request "$BASE"
  # Ruff reads a file-level noqa after a byte-order mark as exempting the file.
  mkrepo realfilebom; printf '\xef\xbb\xbf# ruff: noqa: S307\na = eval("1")\n' > "$R/api/new.py"; commit
  run "real ruff with a file-level security noqa after a byte-order mark fails" 1 pull_request "$BASE"
  mkrepo realfileblanket; printf '# ruff: noqa\na = eval("1")\n' > "$R/api/new.py"; commit
  run "real ruff fails a blanket file-level ruff noqa" 1 pull_request "$BASE"
  says "through PGH004" "PGH004"
  mkrepo realflakeblanket; printf '# flake8: noqa\na = eval("1")\n' > "$R/api/new.py"; commit
  run "real ruff fails a blanket file-level flake8 noqa" 1 pull_request "$BASE"
  mkrepo realrange; printf '# ruff: disable[S307]\na = eval("1")\n' > "$R/api/new.py"; commit
  run "real ruff with a security disable range and no reason fails" 1 pull_request "$BASE"
  mkrepo realreason; printf 'a = eval("1")  # noqa: S307 the input is a literal in this file\n' > "$R/api/new.py"; commit
  run "real ruff honours a security noqa that gives its reason" 0 pull_request "$BASE"
else
  echo "SKIP  real ruff (no RUFF_TGZ, and the release could not be fetched or did not match the pinned hash)"
fi

echo
[ "$fails" = 0 ] && echo "all passed" || echo "$fails failed"
[ "$fails" = 0 ]
