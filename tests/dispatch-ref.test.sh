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
checkouts = []
for j, job in wf["jobs"].items():
    for s in job.get("steps", []):
        if str(s.get("uses", "")).startswith("actions/checkout"):
            w = s.get("with") or {}
            checkouts.append({"job": j, "ref": w.get("ref"), "persist": str(w.get("persist-credentials"))})
json.dump(checkouts, open(sys.argv[2] + "/checkouts.json", "w"))
json.dump({"env": step.get("env", {}), "pick": wf["jobs"]["pick"].get("outputs", {}),
           "call": (wf.get("on", wf.get(True)) or {})["workflow_call"].get("outputs", {})},
          open(sys.argv[2] + "/shape.json", "w"))
for j, job in wf["jobs"].items():
    for s in job.get("steps", []):
        c = (s.get("with") or {}).get("cache")
        if c is not None:
            caches.append({"job": j, "name": s.get("name", s.get("uses", "")), "cache": c})
json.dump(caches, open(sys.argv[2] + "/caches.json", "w"))
EOF

# A stub curl on PATH: branch main, lightweight tag v1, annotated tag v2.
mkdir -p "$T/bin"
cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do url=$a; done
case "$url" in
  */git/ref/heads/main) echo '{"object":{"type":"commit","sha":"0123456789abcdef0123456789abcdef01234567"}}' ;;
  */git/ref/tags/v1)    echo '{"object":{"type":"commit","sha":"1111111111111111111111111111111111111111"}}' ;;
  */git/ref/tags/v2)    echo '{"object":{"type":"tag","sha":"7777777777777777777777777777777777777777"}}' ;;
  */git/tags/7777777777777777777777777777777777777777) echo '{"object":{"type":"commit","sha":"2222222222222222222222222222222222222222"}}' ;;
  *) echo '{"message":"Not Found"}' ;;
esac
EOF
chmod +x "$T/bin/curl"

# run_target REF [VAR=value ...]: the target step with a passing setup,
# each VAR=value overriding one input.
run_target() {
  local ref=$1; shift
  ( export PATH="$T/bin:$PATH" REF="$ref" EVENT=workflow_dispatch GH_REF=refs/heads/main \
      SHA=ffffffffffffffffffffffffffffffffffffffff DEPLOY_API=false DEPLOY_SWA=false \
      REF_REPOS=BeeSec-UK/app TOKEN=x REPO=BeeSec-UK/app GITHUB_OUTPUT="$T/out" \
      GITHUB_STEP_SUMMARY="$T/summary"
    unset ACTIONS_ID_TOKEN_REQUEST_URL
    for kv in "$@"; do export "${kv?}"; done
    : > "$T/out"; : > "$T/summary"
    bash "$T/target.sh" > "$T/log" 2>&1 )
}

# refused NAME PATTERN REF [VAR=value ...]: the run fails, says PATTERN, and
# outputs no ref_sha.
refused() {
  local name=$1 pat=$2; shift 2
  if run_target "$@"; then
    fail "$name" "accepted: $(cat "$T/out")"
  elif grep -q "$pat" "$T/log" && ! grep -q '^ref_sha=' "$T/out"; then
    pass "$name"
  else
    fail "$name" "$(cat "$T/log")"
  fi
}

# --- empty ref ------------------------------------------------------------

run_target '' REF_REPOS= EVENT=push && ! grep -q '^ref_sha=' "$T/out" \
  && pass "an empty ref resolves nothing and sets no ref_sha, on any event" || fail "an empty ref resolves nothing and sets no ref_sha, on any event" "$(cat "$T/log") $(cat "$T/out")"

# --- refusals before any lookup ---------------------------------------------

refused "refused while REF_REPOS is empty" 'not in REF_REPOS' main REF_REPOS=
refused "refused for a repository not in REF_REPOS" 'not in REF_REPOS' main REF_REPOS=BeeSec-UK/other
refused "refused on a partial name in REF_REPOS" 'not in REF_REPOS' main 'REF_REPOS=BeeSec-UK/ap BeeSec-UK/app-x'
run_target main 'REF_REPOS=BeeSec-UK/other BeeSec-UK/app' && grep -q '^ref_sha=' "$T/out" \
  && pass "accepted for a repository listed among others" || fail "accepted for a repository listed among others" "$(cat "$T/log")"
refused "refused on a push" 'manual run dispatched on main' main EVENT=push
refused "refused on a dispatch off main" 'manual run dispatched on main' main GH_REF=refs/heads/feature
refused "refused with deploy_api on" 'deploy_api or deploy_swa' main DEPLOY_API=true
refused "refused with deploy_swa on" 'deploy_api or deploy_swa' main DEPLOY_SWA=true
refused "refused when the run can mint an OIDC token" 'mint an OIDC token' main ACTIONS_ID_TOKEN_REQUEST_URL=https://example.invalid/token

# --- lookups --------------------------------------------------------------

run_target v1 && grep -qx 'ref_sha=1111111111111111111111111111111111111111' "$T/out" \
  && pass "a lightweight tag resolves to its commit" || fail "a lightweight tag resolves to its commit" "$(cat "$T/log")"
run_target v2 && grep -qx 'ref_sha=2222222222222222222222222222222222222222' "$T/out" \
  && pass "an annotated tag resolves to the commit it tags" || fail "an annotated tag resolves to the commit it tags" "$(cat "$T/log")"
refused "an unknown ref is refused" 'is not a branch or tag of' nosuchbranch

# --- the tested commit is reported --------------------------------------------

run_target main
grep -q '0123456789abcdef0123456789abcdef01234567' "$T/summary" && grep -q 'ffffffffffffffffffffffffffffffffffffffff' "$T/summary" \
  && pass "the job summary names the tested commit and the commit check runs attach to" \
  || fail "the job summary names the tested commit and the commit check runs attach to" "$(cat "$T/summary")"

# --- the ref shape check --------------------------------------------------

run_target main && grep -qx 'ref_sha=0123456789abcdef0123456789abcdef01234567' "$T/out" \
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

# --- what ships ---------------------------------------------------------------

# The allowlist is a literal in this workflow, empty, never a variable a
# caller's admin could set.
jq -e '.env.REF_REPOS == ""' "$T/shape.json" >/dev/null \
  && pass "REF_REPOS ships empty and is a literal" || fail "REF_REPOS ships empty and is a literal" "$(jq -c .env.REF_REPOS "$T/shape.json")"
jq -e '[.env[] | tostring | select(test("vars\\."))] | length == 0' "$T/shape.json" >/dev/null \
  && pass "the target step reads no org or repo variable" || fail "the target step reads no org or repo variable" "$(jq -c .env "$T/shape.json")"
# A prod deploy wired to `sha` must keep building main on a ref run.
jq -e '.pick.sha == "${{ github.sha }}" and .call.sha.value == "${{ jobs.pick.outputs.sha }}"' "$T/shape.json" >/dev/null \
  && pass "the sha output is github.sha on every run" || fail "the sha output is github.sha on every run" "$(jq -c '.pick.sha, .call.sha' "$T/shape.json")"
jq -e '.pick.ref_sha == "${{ steps.target.outputs.ref_sha }}" and (.call | has("ref_sha") and has("ref_run"))' "$T/shape.json" >/dev/null \
  && pass "ref_sha and ref_run are separate outputs" || fail "ref_sha and ref_run are separate outputs" "$(jq -c '.pick, (.call|keys)' "$T/shape.json")"

# --- caches ---------------------------------------------------------------

n=$(jq 'length' "$T/caches.json")
[ "$n" -gt 0 ] && pass "the workflow has cache settings to check ($n)" || fail "the workflow has cache settings to check" "none found"
for i in $(seq 0 $((n - 1))); do
  job=$(jq -r ".[$i].job" "$T/caches.json"); c=$(jq -r ".[$i].cache" "$T/caches.json")
  case "$job" in
    gate|gate_web)
      case "$c" in *"inputs.ref == ''"*) pass "$job: a ref run saves no cache" ;; *) fail "$job: a ref run saves no cache" "cache: $c" ;; esac ;;
    *)
      # A ref run's branch code can write main's cache scope itself, so a
      # job that deploys must never restore a GitHub cache.
      fail "$job: restores no GitHub cache" "cache: $c" ;;
  esac
done

# --- checkouts --------------------------------------------------------------

# With ref empty, the checkouts keep their default, the branch a push came
# from, rather than a detached github.sha.
# Every checkout in those jobs, not only the first, follows ref_sha and keeps
# no credentials on a ref run.
for job in pick gate gate_web; do
  n=$(jq --arg j "$job" '[.[] | select(.job == $j)] | length' "$T/checkouts.json")
  [ "$n" -gt 0 ] || { fail "$job: has a checkout to check" "none found"; continue; }
  for i in $(seq 0 $((n - 1))); do
    r=$(jq -r --arg j "$job" --argjson i "$i" '[.[] | select(.job == $j)][$i].ref // ""' "$T/checkouts.json")
    pc=$(jq -r --arg j "$job" --argjson i "$i" '[.[] | select(.job == $j)][$i].persist' "$T/checkouts.json")
    case "$r" in
      *"inputs.ref != ''"*ref_sha*) pass "$job checkout $((i + 1)): follows ref_sha only when ref is set" ;;
      *) fail "$job checkout $((i + 1)): follows ref_sha only when ref is set" "ref: $r" ;;
    esac
    case "$pc" in
      *"inputs.ref == ''"*) pass "$job checkout $((i + 1)): keeps no credentials on a ref run" ;;
      *) fail "$job checkout $((i + 1)): keeps no credentials on a ref run" "persist-credentials: $pc" ;;
    esac
  done
done

echo
[ "$fails" -eq 0 ] && echo "all passed" || echo "$fails failed"
[ "$fails" -eq 0 ]
