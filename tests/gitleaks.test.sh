#!/usr/bin/env bash
# Tests for the two gitleaks steps in beesec-app.yml (#50): the pick job's
# fallback scan and the gate's scan. Each step is lifted out and run with
# curl, sleep and RUNNER_TOOL_CACHE stubbed. A binary is only ever run after
# its SHA-256 matches the pin, whether it came from the cache or a download,
# and the copy that runs is in RUNNER_TEMP, not the shared cache.
#
#   bash tests/gitleaks.test.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
WF="$HERE/../.github/workflows/beesec-app.yml"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fails=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s: %s\n' "$1" "$2"; fails=$((fails + 1)); }

python3 - "$WF" "$T" <<'EOF' || { echo "FAIL  could not read $WF"; exit 1; }
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
for job in ("pick", "gate"):
    step = next(s for s in wf["jobs"][job]["steps"] if "gitleaks" in str(s.get("name", "")))
    open(f"{sys.argv[2]}/{job}.sh", "w").write(step["run"])
EOF

# Fixtures: a good archive, whose gitleaks says where it ran from, and an
# archive with a different gitleaks in it.
mkdir -p "$T/good" "$T/evil" "$T/bin"
printf '#!/bin/sh\necho "FIXTURE RAN from $0: $*" >&2\nexit 0\n' > "$T/good/gitleaks"
printf '#!/bin/sh\necho "SUBSTITUTED RAN: $*" >&2\nexit 0\n' > "$T/evil/gitleaks"
chmod +x "$T/good/gitleaks" "$T/evil/gitleaks"
tar czf "$T/good.tgz" -C "$T/good" gitleaks
tar czf "$T/evil.tgz" -C "$T/evil" gitleaks
TGZ_SHA=$(sha256sum "$T/good.tgz" | cut -d' ' -f1)
BIN_SHA=$(sha256sum "$T/good/gitleaks" | cut -d' ' -f1)

# curl serves $SERVE for the release and a minimal config for the TOML, and
# notes each release download. sleep returns at once.
cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
out=
while [ $# -gt 0 ]; do [ "$1" = -o ] && { out=$2; shift; }; url=$1; shift; done
case "$url" in
  *releases/download*) echo "$url" >> "$DOWNLOADS"; cp "$SERVE" "$out" ;;
  *) exit 22 ;;
esac
EOF
printf '#!/bin/sh\nexit 0\n' > "$T/bin/sleep"
chmod +x "$T/bin/curl" "$T/bin/sleep"

# run_step JOB SERVE: the step with its pins swapped for the fixture's.
run_step() {
  local job=$1 serve=$2
  sed -e "s/^\( *GL_TGZ_SHA256=\).*/\1$TGZ_SHA/" -e "s/^\( *GL_BIN_SHA256=\).*/\1$BIN_SHA/" \
    "$T/$job.sh" > "$T/run.sh"
  mkdir -p "$T/rt" "$T/repo"
  ( cd "$T/repo" && export PATH="$T/bin:$PATH" RUNNER_TOOL_CACHE="$T/cache" RUNNER_TEMP="$T/rt" \
      SERVE="$serve" DOWNLOADS="$T/downloads"
    bash "$T/run.sh" > "$T/log" 2>&1 )
}
reset() { rm -rf "$T/cache" "$T/rt" "$T/downloads"; touch "$T/downloads"; }
cache_bin() { echo "$T/cache/gitleaks/8.28.0/gitleaks"; }

for job in pick gate; do
  # 1. A tampered binary in the cache is never run, and is replaced.
  reset; mkdir -p "$(dirname "$(cache_bin)")"
  printf '#!/bin/sh\necho "TAMPERED RAN: $*" >&2\nexit 0\n' > "$(cache_bin)"; chmod +x "$(cache_bin)"
  if run_step "$job" "$T/good.tgz" && ! grep -q TAMPERED "$T/log" && grep -q 'FIXTURE RAN.* dir ' "$T/log" \
     && grep -q 'failed its hash check' "$T/log" && [ "$(sha256sum "$(cache_bin)" | cut -d' ' -f1)" = "$BIN_SHA" ]; then
    pass "$job: a tampered cached binary is not run and is replaced by a checked download"
  else
    fail "$job: a tampered cached binary is not run and is replaced by a checked download" "$(cat "$T/log")"
  fi

  # 2. A download with the wrong hash is never extracted or run.
  reset
  if run_step "$job" "$T/evil.tgz"; then
    fail "$job: a download with the wrong hash fails the step" "exit 0: $(cat "$T/log")"
  elif grep -q SUBSTITUTED "$T/log" || [ -e "$(cache_bin)" ] || find "$T/rt" -name gitleaks -type f | grep -q .; then
    fail "$job: a download with the wrong hash is never extracted or run" "$(cat "$T/log")"
  else
    pass "$job: a download with the wrong hash is never extracted or run, and the step fails"
  fi

  # 3. A good cached binary is used with no download, and the copy that runs
  # is in RUNNER_TEMP, not the shared cache.
  reset; mkdir -p "$(dirname "$(cache_bin)")"; cp "$T/good/gitleaks" "$(cache_bin)"
  if run_step "$job" "$T/evil.tgz" && [ ! -s "$T/downloads" ] && grep -q 'FIXTURE RAN.* dir ' "$T/log"; then
    pass "$job: a good cached binary is used with no download"
  else
    fail "$job: a good cached binary is used with no download" "downloads: $(cat "$T/downloads") log: $(cat "$T/log")"
  fi
  if grep 'FIXTURE RAN.* dir ' "$T/log" | grep -q "from $T/rt/"; then
    pass "$job: the binary that runs is a checked copy in RUNNER_TEMP"
  else
    fail "$job: the binary that runs is a checked copy in RUNNER_TEMP" "$(grep 'FIXTURE RAN' "$T/log")"
  fi
done

# 4. Both steps carry the same, well-formed pins.
pins() { grep -oE '^ *(VER|GL_TGZ_SHA256|GL_BIN_SHA256)=[^ ]*' "$T/$1.sh" | sed 's/^ *//' | sort; }
if [ "$(pins pick)" = "$(pins gate)" ] && [ "$(pins pick | wc -l)" -eq 3 ] \
   && pins pick | grep -E '^GL_(TGZ|BIN)_SHA256=' | cut -d= -f2 | grep -vqE '^[0-9a-f]{64}$' ; then
  fail "both steps pin the same version and hashes" "a hash is not 64 hex: $(pins pick)"
elif [ "$(pins pick)" = "$(pins gate)" ] && [ "$(pins pick | wc -l)" -eq 3 ]; then
  pass "both steps pin the same version and hashes"
else
  fail "both steps pin the same version and hashes" "pick: $(pins pick | tr '\n' ' ') gate: $(pins gate | tr '\n' ' ')"
fi

echo
[ "$fails" -eq 0 ] && echo "all passed" || echo "$fails failed"
[ "$fails" -eq 0 ]
