#!/usr/bin/env bash
# Shared workflows and scripts write scratch files under $RUNNER_TEMP, never
# under a literal /tmp. Several runner slots on one host share /tmp, so a
# fixed path there is shared too, and one job can delete another's download
# halfway through (.github#42).
#
#   bash tests/tmp-paths.test.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT="$HERE/.."
fails=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s: %s\n' "$1" "$2"; fails=$((fails + 1)); }

files=$(cd "$ROOT" && ls .github/workflows/*.yml workflow-templates/*.yml scripts/*.sh 2>/dev/null)
for f in $files; do
  # A comment may name /tmp; code may not.
  hits=$(grep -nE '(^|[^A-Za-z0-9_$])/tmp(/|\b)' "$ROOT/$f" | grep -vE '^[0-9]+:[[:space:]]*#')
  if [ -n "$hits" ]; then
    fail "$f has no literal /tmp" "$(printf '%s' "$hits" | head -3 | tr '\n' ' ')"
  else
    pass "$f has no literal /tmp"
  fi
done

[ "$fails" -eq 0 ] || { echo "$fails failed"; exit 1; }
echo "all passed"
