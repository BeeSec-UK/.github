#!/usr/bin/env bash
# Tests for the dependency and licence check in beesec-app.yml
# (docs/security-gate-plan.md, check 2). The step's script is lifted out of
# the workflow and run against throwaway repositories with osv-scanner and
# curl stubbed, so it runs offline. When osv-scanner 2.7.0 is on PATH as
# osv-scanner-real, two cases also run it against the live database.
#
#   bash tests/osv.test.sh
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
        if s.get("id") == "osv":
            print(json.dumps({"job": job, "step": s}))
EOF

# --- the workflow wiring --------------------------------------------------

desc=$(python3 -c 'import sys, yaml; print(yaml.safe_load(open(sys.argv[1]))[True]["workflow_call"]["inputs"]["security_checks"]["description"])' "$WF" 2>/dev/null)
case "$desc" in
  *"or in pick when the gate is skipped"*) fail "security_checks does not say the dependency check runs in pick" "$desc" ;;
  *dependency*gate*|*gate*dependency*) pass "security_checks does not say the dependency check runs in pick" ;;
  *) fail "security_checks does not say the dependency check runs in pick" "no mention of the dependency check: $desc" ;;
esac

jobs=$(jq -r '.job' "$T/steps.json" | sort | paste -sd, -)
[ "$jobs" = gate ] && pass "the osv step is in the gate only" || fail "the osv step is in the gate only" "found in '$jobs'"
s=$(jq -c 'select(.job == "gate") | .step' "$T/steps.json")
script=$(printf '%s' "$s" | jq -r '.run // empty')
if [ -n "$s" ]; then
  printf '%s' "$s" | jq -e '.if | test("inputs.security_checks")' >/dev/null \
    && pass "it runs only when security_checks is on" || fail "it runs only when security_checks is on" "if: $(printf '%s' "$s" | jq -c .if)"
  printf '%s' "$s" | jq -e '."continue-on-error" == "${{ !inputs.security_enforce }}"' >/dev/null \
    && pass "it is shadow until security_enforce" || fail "it is shadow until security_enforce" "$(printf '%s' "$s" | jq -c '."continue-on-error"')"
  printf '%s' "$s" | jq -e '.run | test("\\$\\{\\{") | not' >/dev/null \
    && pass "it interpolates nothing into its script" || fail "it interpolates nothing into its script" "found \${{ }} in run"
fi
printf '%s\n' "$script" | grep -qE '^ *VER=2\.7\.0$' && pass "osv-scanner is pinned to 2.7.0" || fail "osv-scanner is pinned to 2.7.0" "no VER=2.7.0"
printf '%s\n' "$script" | grep -qE '^ *SHA256=[0-9a-f]{64}$' && pass "the binary's SHA-256 is pinned" || fail "the binary's SHA-256 is pinned" "no SHA256="
allow=$(printf '%s\n' "$script" | sed -n "s/^ *ALLOW='\(.*\)'$/\1/p")
[ "$allow" = "MIT,BSD-2-Clause,BSD-3-Clause,Apache-2.0,ISC,PSF-2.0,MPL-2.0,0BSD,Unlicense,CC0-1.0" ] \
  && pass "the licence allowlist is the plan's, with no GPL, LGPL or AGPL" || fail "the licence allowlist is the plan's, with no GPL, LGPL or AGPL" "ALLOW='$allow'"

# --- the behaviour --------------------------------------------------------

[ -n "$script" ] || { echo "FAIL  no osv script to run"; echo "$fails failed"; exit 1; }
printf '%s\n' "$script" > "$T/step-real.sh"
VER=$(printf '%s\n' "$script" | sed -n 's/^ *VER=\(\S*\)$/\1/p')

# The stub records its arguments and answers as $OSV_MODE says:
# clean, vulns, nopkgs, down (always 127), flaky (127 once, then clean), or
# silent (exit 0 having failed to reach the database, as a log line says), or
# extract128 (every lockfile failed to extract, so no package sources, 128).
mkdir -p "$T/bin"
cat > "$T/osv-stub" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = --version ] && { echo "osv-scanner version: 2.7.0"; exit 0; }
printf '%s\n' "$*" >> "$OSV_CALLS"
case "$OSV_MODE" in
  clean)  echo "No issues found"; exit 0 ;;
  vulns)  echo "| https://osv.dev/GHSA-xxxx | PyPI | django | 2.0.0 |"; exit 1 ;;
  nopkgs) echo "No package sources found"; exit 128 ;;
  down)   echo "Error during extraction: (extracting as vulnmatch/osvdev) max retries exceeded"; exit 127 ;;
  flaky)  if [ "$(grep -c . "$OSV_CALLS")" -lt 2 ]; then echo "Error during extraction: down"; exit 127; fi; echo "No issues found"; exit 0 ;;
  silent) echo "Error during extraction: (extracting as vulnmatch/osvdev) max retries exceeded"; echo "No issues found"; exit 0 ;;
  extract128) echo "Error during extraction: (extracting as python/requirements) bad line"; echo "No package sources found"; exit 128 ;;
esac
EOF
chmod +x "$T/osv-stub"
# The offline cases pin the stub's own SHA-256 in place of the release's, so
# a cached or downloaded stub passes the checksum and anything else fails it.
stubsha=$(sha256sum "$T/osv-stub" | cut -d' ' -f1)
sed "s/^\( *SHA256=\)[0-9a-f]\{64\}$/\1$stubsha/" "$T/step-real.sh" > "$T/step.sh"
# curl only ever fetches the binary here. It writes whatever $CURL_BODY names.
cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
out=""; prev=""; for a; do [ "$prev" = -o ] && out=$a; prev=$a; done
echo "$*" >> "$CURL_LOG"
cp "$CURL_BODY" "$out"
EOF
chmod +x "$T/bin/curl"
cat > "$T/bin/sleep" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$T/bin/sleep"

CACHE="$T/toolcache"; mkdir -p "$CACHE/osv-scanner/$VER"
cp "$T/osv-stub" "$CACHE/osv-scanner/$VER/osv-scanner"

mkrepo() {
  R="$T/repo.$1"; rm -rf "$R"; mkdir -p "$R"
  git -C "$R" init -q -b main
  git -C "$R" config user.email t@example.invalid; git -C "$R" config user.name t
}
track() { git -C "$R" add -A; git -C "$R" commit -qm c; }
run() {  # name expect mode [cache]
  : > "$T/calls"; : > "$T/curl.log"; mkdir -p "$T/runner-temp"
  out=$(cd "$R" && PATH="${EXTRA_PATH:+$EXTRA_PATH:}$T/bin:$PATH" RUNNER_TOOL_CACHE="${4:-$CACHE}" RUNNER_TEMP="$T/runner-temp" \
        OSV_MODE="$3" OSV_CALLS="$T/calls" \
        CURL_LOG="$T/curl.log" CURL_BODY="${CURL_BODY:-$T/osv-stub}" bash "${STEP:-$T/step.sh}" 2>&1); rc=$?
  if [ "$rc" = "$2" ]; then pass "$1"; else fail "$1" "rc=$rc, expected $2: $(printf '%s' "$out" | tail -3 | tr '\n' ' ')"; fi
}
calls() { grep -c . "$T/calls"; }
says() { case "$out" in *"$2"*) pass "$1" ;; *) fail "$1" "output lacks '$2': $(printf '%s' "$out" | tail -3 | tr '\n' ' ')" ;; esac; }

ahead() { date -u -d "+$1 days" +%F; }

mkrepo lock; mkdir -p "$R/api" "$R/web" "$R/app-vite" "$R/web/node_modules/x"
echo 'django==4.2.16' > "$R/api/requirements.txt"; echo 'pytest==8.3.3' > "$R/api/requirements-dev.txt"
echo '{}' > "$R/web/package-lock.json"; echo '{}' > "$R/app-vite/package-lock.json"
echo '{}' > "$R/web/node_modules/x/package-lock.json"; track
echo 'flask==0.1' > "$R/requirements.txt"   # untracked
run "a clean scan passes" 0 clean
a=$(cat "$T/calls")
for f in api/requirements.txt api/requirements-dev.txt web/package-lock.json app-vite/package-lock.json; do
  case " $a " in *"-L $f "*|*"--lockfile=$f "*|*"--lockfile $f "*) pass "it scans tracked $f" ;; *) fail "it scans tracked $f" "args: $a" ;; esac
done
case "$a" in *node_modules*) fail "it skips node_modules" "args: $a" ;; *) pass "it skips node_modules" ;; esac
case " $a " in *" -L requirements.txt "*|*"=requirements.txt "*) fail "it skips untracked files" "args: $a" ;; *) pass "it skips untracked files" ;; esac
case "$a" in *"--licenses=$allow"*) pass "it passes the allowlist" ;; *) fail "it passes the allowlist" "args: $a" ;; esac

mkrepo vulns; echo 'django==2.0.0' > "$R/requirements.txt"; track
run "a vulnerability or licence finding fails" 1 vulns

mkrepo nolock; echo hi > "$R/README.md"; track
run "a repository with no lockfile passes without scanning" 0 clean
[ "$(calls)" = 0 ] && pass "and osv-scanner is not run" || fail "and osv-scanner is not run" "$(calls) calls"

mkrepo nopkgs; echo '# nothing pinned' > "$R/requirements.txt"; track
run "lockfiles with no packages in them pass" 0 nopkgs

mkrepo down; echo 'django==4.2.16' > "$R/requirements.txt"; track
run "an unreachable database fails" 1 down
[ "$(calls)" -ge 2 ] && pass "after trying again" || fail "after trying again" "$(calls) calls"
run "a database that comes back on the retry passes" 0 flaky
run "an exit 0 after a database error fails" 1 silent
run "an exit 128 after an extraction error fails" 1 extract128
[ "$(calls)" -ge 2 ] && pass "after trying again" || fail "after trying again" "$(calls) calls"

# Ignores. Every [[IgnoredVulns]] needs a reason and an ignoreUntil at most
# 90 days away, and every [[PackageOverrides]] a reason and a name.
policy() {  # name expect toml
  mkrepo policy; echo 'django==4.2.16' > "$R/requirements.txt"; printf '%s\n' "$3" > "$R/osv-scanner.toml"; track
  run "$1" "$2" clean
}
policy "a reasoned ignore within 90 days passes" 0 "[[IgnoredVulns]]
id = \"GHSA-aaaa-bbbb-cccc\"
ignoreUntil = $(ahead 30)
reason = \"Only the admin path is affected and it is not mounted.\""
case "$(cat "$T/calls")" in *"--config=osv-scanner.toml"*|*"--config osv-scanner.toml"*) pass "the root osv-scanner.toml is passed as the config" ;; *) fail "the root osv-scanner.toml is passed as the config" "args: $(cat "$T/calls")" ;; esac
policy "an ignore with no reason fails" 1 "[[IgnoredVulns]]
id = \"GHSA-aaaa-bbbb-cccc\"
ignoreUntil = $(ahead 30)"
[ "$(calls)" = 0 ] && pass "and fails before scanning" || fail "and fails before scanning" "$(calls) calls"
policy "an ignore with a blank reason fails" 1 "[[IgnoredVulns]]
id = \"GHSA-aaaa-bbbb-cccc\"
ignoreUntil = $(ahead 30)
reason = \"  \""
policy "an ignore with no ignoreUntil fails" 1 "[[IgnoredVulns]]
id = \"GHSA-aaaa-bbbb-cccc\"
reason = \"later\""
policy "an ignore more than 90 days away fails" 1 "[[IgnoredVulns]]
id = \"GHSA-aaaa-bbbb-cccc\"
ignoreUntil = $(ahead 91)
reason = \"later\""
policy "an ignoreUntil written as a datetime is read" 0 "[[IgnoredVulns]]
id = \"GHSA-aaaa-bbbb-cccc\"
ignoreUntil = $(ahead 10)T00:00:00Z
reason = \"short\""
policy "a licence override with no reason fails" 1 "[[PackageOverrides]]
name = \"idna\"
ecosystem = \"PyPI\"
license.override = [\"BSD-3-Clause\"]"
policy "a reasoned licence override passes" 0 "[[PackageOverrides]]
name = \"idna\"
ecosystem = \"PyPI\"
license.override = [\"BSD-3-Clause\"]
reason = \"deps.dev reports non-standard; the LICENSE.md is BSD-3-Clause.\""
# An override that ignores is an ignore, so it must run out within 90 days
# through effectiveUntil. Every override must name its package, because one
# with no name, or a name that is a pattern, covers a whole ecosystem.
policy "an ecosystem-wide vulnerability.ignore fails" 1 "[[PackageOverrides]]
ecosystem = \"PyPI\"
vulnerability.ignore = true
reason = \"x\""
policy "a named vulnerability.ignore with no effectiveUntil fails" 1 "[[PackageOverrides]]
name = \"django\"
ecosystem = \"PyPI\"
vulnerability.ignore = true
reason = \"x\""
policy "a named ignore = true with no effectiveUntil fails" 1 "[[PackageOverrides]]
name = \"django\"
ecosystem = \"PyPI\"
ignore = true
reason = \"x\""
policy "a license.ignore with no effectiveUntil fails" 1 "[[PackageOverrides]]
name = \"idna\"
ecosystem = \"PyPI\"
license.ignore = true
reason = \"x\""
policy "an override ignore more than 90 days away fails" 1 "[[PackageOverrides]]
name = \"django\"
ecosystem = \"PyPI\"
vulnerability.ignore = true
effectiveUntil = $(ahead 91)
reason = \"later\""
policy "a named override ignore within 90 days passes" 0 "[[PackageOverrides]]
name = \"django\"
ecosystem = \"PyPI\"
vulnerability.ignore = true
effectiveUntil = $(ahead 30)
reason = \"Only the admin path is affected and it is not mounted.\""
policy "a licence override with no name fails" 1 "[[PackageOverrides]]
ecosystem = \"PyPI\"
license.override = [\"MIT\"]
reason = \"x\""
policy "an override whose name is a pattern fails" 1 "[[PackageOverrides]]
name = \".*\"
nameIsRegex = true
ecosystem = \"PyPI\"
license.override = [\"MIT\"]
reason = \"x\""
# osv-scanner reads its config keys in any case, at the top level and inside
# an entry, so the check does too, and it refuses a top-level key it does not
# know rather than let a new field past.
policy "a lower-case ignoredvulns with no reason fails" 1 "[[ignoredvulns]]
id = \"GHSA-aaaa-bbbb-cccc\"
ignoreUntil = $(ahead 30)"
policy "a lower-case packageoverrides ignore with no reason or expiry fails" 1 "[[packageoverrides]]
name = \"django\"
ignore = true"
policy "an upper-case IGNORE inside an override with no effectiveUntil fails" 1 "[[PackageOverrides]]
name = \"django\"
IGNORE = true
reason = \"x\""
policy "a NameIsRegex inside an override fails" 1 "[[PackageOverrides]]
name = \".*\"
NameIsRegex = true
license.override = [\"MIT\"]
reason = \"x\""
policy "keys that differ only in case fail" 1 "[[IgnoredVulns]]
id = \"GHSA-aaaa-bbbb-cccc\"
ignoreUntil = $(ahead 30)
reason = \"x\"
REASON = \"\""
policy "an unknown top-level key fails" 1 "[[IgnoredVuln]]
id = \"GHSA-aaaa-bbbb-cccc\""
policy "a reasoned lower-case ignore within 90 days passes" 0 "[[ignoredvulns]]
id = \"GHSA-aaaa-bbbb-cccc\"
ignoreuntil = $(ahead 30)
reason = \"short\""
policy "a GoVersionOverride alone passes" 0 "GoVersionOverride = \"1.22.0\""
policy "an unreadable osv-scanner.toml fails" 1 "[[IgnoredVulns]
id = "

mkrepo nested; echo 'django==4.2.16' > "$R/requirements.txt"; mkdir -p "$R/api"
printf '[[IgnoredVulns]]\nid = "GHSA-aaaa-bbbb-cccc"\n' > "$R/api/osv-scanner.toml"; track
run "a nested osv-scanner.toml is held to the same rules" 1 clean

# With a root osv-scanner.toml, osv-scanner reads only that one, so a nested
# file's entries would be dropped without a word. The step says so.
mkrepo shadowed; mkdir -p "$R/api"; echo 'django==4.2.16' > "$R/api/requirements.txt"
printf '[[IgnoredVulns]]\nid = "GHSA-aaaa-bbbb-cccc"\nignoreUntil = %s\nreason = "r"\n' "$(ahead 30)" > "$R/osv-scanner.toml"
cp "$R/osv-scanner.toml" "$R/api/osv-scanner.toml"; track
run "a nested osv-scanner.toml beside a root one passes" 0 clean
says "and is named as not read" "api/osv-scanner.toml"

# tomllib needs Python 3.11. A runner whose Python is older gets a plain
# error, not an import traceback.
mkdir -p "$T/oldpy"
for p in python3 python3.11 python3.12 python3.13 python3.14; do
  printf '#!/bin/sh\necho "ModuleNotFoundError: No module named tomllib" >&2\nexit 1\n' > "$T/oldpy/$p"; chmod +x "$T/oldpy/$p"
done
mkrepo oldpy; echo 'django==4.2.16' > "$R/requirements.txt"; printf '[[IgnoredVulns]]\nid = "x"\n' > "$R/osv-scanner.toml"; track
EXTRA_PATH="$T/oldpy" run "a Python older than 3.11 fails the check" 1 clean
says "with a clear error" "::error::"
says "naming the version it needs" "3.11"
case "$out" in *Traceback*) fail "and no traceback" "$out" ;; *) pass "and no traceback" ;; esac

# The binary: from the tool cache when it is there, else downloaded and
# checked against the pinned SHA-256 before it is ever run.
mkrepo fetch; echo 'django==4.2.16' > "$R/requirements.txt"; track
# A download that would run, and report itself, if the checksum were skipped.
printf '#!/bin/sh\necho "the unchecked download ran" >> "$OSV_CALLS"\nexit 0\n' > "$T/junk"; chmod +x "$T/junk"
CURL_BODY="$T/junk" run "a download that fails the checksum fails" 1 clean "$T/emptycache"
[ "$(calls)" = 0 ] && pass "and the download is never run" || fail "and the download is never run" "$(calls) calls"
[ -s "$T/curl.log" ] && pass "and a download was tried" || fail "and a download was tried" "curl was not called"
run "a cached binary is used without a download" 0 clean
[ -s "$T/curl.log" ] && fail "and nothing is downloaded" "curl was called" || pass "and nothing is downloaded"

# A cached binary is checked on every use, not trusted for answering
# --version. One that does not match is fetched again and never run.
printf '#!/bin/sh\n[ "$1" = --version ] && exit 0\necho "the tampered cache ran" >> "$OSV_CALLS"\nexit 0\n' > "$CACHE/osv-scanner/$VER/osv-scanner"
run "a tampered cached binary is replaced by a checked download" 0 clean
grep -q 'tampered' "$T/calls" && fail "and the tampered binary is never run" "$(cat "$T/calls")" || pass "and the tampered binary is never run"
[ -s "$T/curl.log" ] && pass "and it was downloaded again" || fail "and it was downloaded again" "curl was not called"
cmp -s "$T/osv-stub" "$CACHE/osv-scanner/$VER/osv-scanner" && pass "and the cache now holds the checked binary" || fail "and the cache now holds the checked binary" "cache differs"

if command -v osv-scanner-real >/dev/null; then
  cp "$(command -v osv-scanner-real)" "$CACHE/osv-scanner/$VER/osv-scanner"
  mkrepo realvuln; echo 'django==2.0.0' > "$R/requirements.txt"; track
  STEP="$T/step-real.sh" run "real osv-scanner fails a known-vulnerable django" 1 x
  mkrepo realgpl; echo 'mysqlclient==2.2.0' > "$R/requirements.txt"; track
  STEP="$T/step-real.sh" run "real osv-scanner fails a GPL-2.0 package" 1 x
  says "and names the licence" "GPL-2.0"
  # The scanner honours a lower-case [[packageoverrides]], so the check must
  # read one: unreasoned it fails before the scan, reasoned it hides django.
  mkrepo reallower; echo 'django==2.0.0' > "$R/requirements.txt"; printf '[[packageoverrides]]\nname = "django"\necosystem = "PyPI"\nignore = true\n' > "$R/osv-scanner.toml"; track
  STEP="$T/step-real.sh" run "real osv-scanner: a lower-case packageoverrides with no reason fails" 1 x
  says "and the check names it" "has no reason"
  mkrepo reallowerok; echo 'django==2.0.0' > "$R/requirements.txt"; printf '[[packageoverrides]]\nname = "django"\necosystem = "PyPI"\nignore = true\neffectiveUntil = %s\nreason = "test"\n' "$(ahead 30)" > "$R/osv-scanner.toml"; track
  STEP="$T/step-real.sh" run "real osv-scanner honours a reasoned lower-case packageoverrides" 0 x
else
  echo "SKIP  real osv-scanner (no osv-scanner-real on PATH)"
fi

echo
[ "$fails" = 0 ] && echo "all passed" || echo "$fails failed"
[ "$fails" = 0 ]
