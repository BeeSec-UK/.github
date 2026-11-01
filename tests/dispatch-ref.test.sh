#!/usr/bin/env bash
# Tests for the `ref` input on beesec-app.yml (#34). The pick job's target
# step, which turns ref into a commit, is lifted out and run with curl
# stubbed. The cache settings are checked in the YAML, because a ref run
# executes a branch's unreviewed code in main's cache scope, so it must not
# save a cache that a later main run, deploy_api included, restores.
#
#   bash tests/dispatch-ref.test.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
WF="$HERE/../.github/workflows/beesec-app.yml"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fails=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s: %s\n' "$1" "$2"; fails=$((fails + 1)); }

python3 - "$WF" "$T" <<'EOF' || { echo "FAIL  could not read $WF"; exit 1; }
import json, sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
step = next(s for s in wf["jobs"]["pick"]["steps"] if s.get("id") == "target")
open(sys.argv[2] + "/target.sh", "w").write(step["run"])
caches = []
for j, job in wf["jobs"].items():
    for s in job.get("steps", []):
        c = (s.get("with") or {}).get("cache")
        if c is not None:
            caches.append({"job": j, "name": s.get("name", s.get("uses", "")), "cache": c})
json.dump(caches, open(sys.argv[2] + "/caches.json", "w"))
EOF

# A stub curl on PATH that resolves refs/heads/main and nothing else.
mkdir -p "$T/bin"
cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do url=$a; done
case "$url" in
  */git/ref/heads/main) echo '{"object":{"type":"commit","sha":"0123456789abcdef0123456789abcdef01234567"}}' ;;
  *) echo '{"message":"Not Found"}' ;;
esac
EOF
chmod +x "$T/bin/curl"

run_target() {
  ( export PATH="$T/bin:$PATH" REF="$1" EVENT=workflow_dispatch GH_REF=refs/heads/main \
      SHA=ffffffffffffffffffffffffffffffffffffffff DEPLOY_API=false DEPLOY_SWA=false \
      TOKEN=x REPO=BeeSec-UK/app GITHUB_OUTPUT="$T/out"
    unset ACTIONS_ID_TOKEN_REQUEST_URL
    : > "$T/out"
    bash "$T/target.sh" > "$T/log" 2>&1 )
}

# --- the ref shape check --------------------------------------------------

run_target main && grep -qx 'sha=0123456789abcdef0123456789abcdef01234567' "$T/out" \
  && pass "a branch name resolves to its commit" || fail "a branch name resolves to its commit" "$(cat "$T/log")"

for bad in $'main\nx y' $'main\n::warning::x' $'ok\n..' 'a..b' '-x' ''; do
  [ -z "$bad" ] && continue
  if run_target "$bad"; then
    fail "ref $(printf '%q' "$bad") is refused" "accepted: $(cat "$T/out")"
  elif grep -q 'ref is not a branch or tag name' "$T/log"; then
    pass "ref $(printf '%q' "$bad") is refused by the shape check"
  else
    fail "ref $(printf '%q' "$bad") is refused by the shape check" "$(cat "$T/log")"
  fi
done

# --- caches ---------------------------------------------------------------

n=$(jq 'length' "$T/caches.json")
[ "$n" -gt 0 ] && pass "the workflow has cache settings to check ($n)" || fail "the workflow has cache settings to check" "none found"
for i in $(seq 0 $((n - 1))); do
  job=$(jq -r ".[$i].job" "$T/caches.json"); c=$(jq -r ".[$i].cache" "$T/caches.json")
  case "$job" in
    gate|gate_web)
      case "$c" in *"inputs.ref == ''"*) pass "$job: a ref run saves no cache" ;; *) fail "$job: a ref run saves no cache" "cache: $c" ;; esac ;;
  esac
done

echo
[ "$fails" -eq 0 ] && echo "all passed" || echo "$fails failed"
[ "$fails" -eq 0 ]
