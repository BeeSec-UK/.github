#!/usr/bin/env bash
# Tests for the IaC policy check folded into beesec-app.yml
# (docs/security-gate-plan.md, check 4). The plan steps are `uses:` of the
# factory plan action, one per supported version, so their wiring is checked
# in the YAML, and the step that picks the caller's version is run against
# made-up caller workflows. The pick job's
# scope step, which says whether the change touched infra/, is lifted out
# and run with the compare API stubbed.
#
#   bash tests/iac.test.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
WF="$HERE/../.github/workflows/beesec-app.yml"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fails=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s: %s\n' "$1" "$2"; fails=$((fails + 1)); }

python3 - "$WF" > "$T/wf.json" <<'EOF' || { echo "FAIL  could not read $WF"; exit 1; }
import json, sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
on = wf[True]["workflow_call"]
steps = [{"job": j, "step": s} for j, job in wf["jobs"].items() for s in job.get("steps", [])]
out = {"inputs": {k: on["inputs"].get(k) for k in ("iac_params_file", "iac_subscription_name", "iac_subscription_id")},
       "pick_outputs": wf["jobs"]["pick"].get("outputs", {}),
       "version": [x for x in steps if x["step"].get("id") == "iac_version"],
       "plans": [x for x in steps if "beesec-factory/.github/actions/plan@" in x["step"].get("uses", "")],
       "scope": next(s for s in wf["jobs"]["pick"]["steps"] if s.get("id") == "scope")}
print(json.dumps(out))
EOF
q() { jq -c "$1" "$T/wf.json"; }

# The factory versions the callers deploy today, and the default (decision
# A). Each caller is planned at the version it deploys, never a newer one,
# because a plan against a newer template reports drift that is not there.
declare -A PIN=(
  [app-stack-v1.8.3]=34553a903f9e38660720e2468d46f265e9db1f23
  [app-stack-v1.8.4]=826215084c92be84a3e4ccc843d0464a67cda943
  [app-stack-v1.10.1]=f23c87d7bddc5be3e47329241298801cbc14937e
  [app-stack-v1.12.3]=28b74eb34426471f4450d41f60247a37a9a00e6c
)

# --- the workflow wiring --------------------------------------------------

for k in iac_params_file iac_subscription_name iac_subscription_id; do
  q ".inputs.$k | .type == \"string\" and .default == \"\"" | grep -qx true \
    && pass "$k is a string input, empty by default" || fail "$k is a string input, empty by default" "$(q ".inputs.$k")"
done
[ "$(q '.version | map(.job)')" = '["gate"]' ] && pass "the version step is in the gate only" || fail "the version step is in the gate only" "$(q '.version | map(.job)')"
[ "$(q '[.plans[].job] | unique')" = '["gate"]' ] && pass "the plan steps are in the gate only" || fail "the plan steps are in the gate only" "$(q '[.plans[].job] | unique')"
[ "$(q '.plans | length')" = "${#PIN[@]}" ] && pass "there is one plan step per supported version" || fail "there is one plan step per supported version" "$(q '.plans | length') plan steps"
for tag in "${!PIN[@]}"; do
  s=$(jq -c --arg u "BeeSec-UK/beesec-factory/.github/actions/plan@${PIN[$tag]}" '.plans[] | select(.step.uses == $u) | .step' "$T/wf.json")
  if [ -z "$s" ]; then fail "$tag has a plan step pinned by commit" "no step uses plan@${PIN[$tag]}"; continue; fi
  pass "$tag has a plan step pinned by commit"
  grep -qF "plan@${PIN[$tag]} # $tag" "$WF" && pass "$tag's pin names its tag" || fail "$tag's pin names its tag" "no '# $tag' beside the sha"
  cond=$(printf '%s' "$s" | jq -r '.if // empty')
  case "$cond" in *"steps.iac_version.outputs.tag == '$tag'"*) pass "$tag's step runs only when the caller deploys $tag" ;; *) fail "$tag's step runs only when the caller deploys $tag" "if: $cond" ;; esac
  printf '%s' "$s" | jq -e '."continue-on-error" == "${{ !inputs.security_enforce }}"' >/dev/null \
    && pass "$tag's step is shadow until security_enforce" || fail "$tag's step is shadow until security_enforce" "$(printf '%s' "$s" | jq -c '."continue-on-error"')"
  printf '%s' "$s" | jq -e '.with == {"params-file": "${{ inputs.iac_params_file }}", "subscription-name": "${{ inputs.iac_subscription_name }}", "subscription-id": "${{ inputs.iac_subscription_id || '"'"'00000000-0000-0000-0000-000000000000'"'"' }}"}' >/dev/null \
    && pass "$tag's step hands over the caller's params file and subscription" || fail "$tag's step hands over the caller's params file and subscription" "with: $(printf '%s' "$s" | jq -c .with)"
done
vcond=$(jq -r '.version[0].step.if // empty' "$T/wf.json")
for want in "inputs.security_checks" "inputs.iac_params_file != ''" "github.event_name == 'pull_request'" "needs.pick.outputs.infra == 'true'"; do
  case "$vcond" in *"$want"*) pass "the version step runs only when $want" ;; *) fail "the version step runs only when $want" "if: $vcond" ;; esac
done
jq -e '.version[0].step."continue-on-error" == "${{ !inputs.security_enforce }}"' "$T/wf.json" >/dev/null \
  && pass "the version step is shadow until security_enforce" || fail "the version step is shadow until security_enforce" "$(q '.version[0].step."continue-on-error"')"
[ "$(q '.pick_outputs.infra')" = '"${{ steps.scope.outputs.infra }}"' ] \
  && pass "pick exposes the scope step's infra output" || fail "pick exposes the scope step's infra output" "$(q '.pick_outputs.infra')"

# --- which version the caller deploys -------------------------------------

vscript=$(jq -r '.version[0].step.run // empty' "$T/wf.json")
# The script's own table must name exactly the versions that have a step.
table=$(printf '%s\n' "$vscript" | grep -oE 'app-stack-v[0-9]+\.[0-9]+\.[0-9]+=[0-9a-f]{40}' | sort -u | paste -sd' ' -)
want=$(for t in "${!PIN[@]}"; do echo "$t=${PIN[$t]}"; done | sort | paste -sd' ' -)
[ -n "$table" ] && [ "$table" = "$want" ] && pass "the version table matches the plan steps" || fail "the version table matches the plan steps" "table: '$table'"
printf '%s\n' "$vscript" > "$T/version.sh"
caller() {  # name expect-rc expect-tag workflow-lines...
  local name=$1 erc=$2 etag=$3; shift 3
  R="$T/caller"; rm -rf "$R"; mkdir -p "$R/.github/workflows"
  printf '%s\n' "$@" > "$R/.github/workflows/pipeline.yml"
  printf 'name: other\n' > "$R/.github/workflows/other.yaml"
  : > "$T/vout"
  out=$(cd "$R" && GITHUB_OUTPUT="$T/vout" bash "$T/version.sh" 2>&1); rc=$?
  got=$(sed -n 's/^tag=//p' "$T/vout")
  if [ "$rc" = "$erc" ] && [ "$got" = "$etag" ]; then pass "$name"; else fail "$name" "rc=$rc tag='$got', expected rc=$erc tag='$etag': $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"; fi
}
caller "a tag pin on deploy-app.yml is read" 0 app-stack-v1.8.4 \
  "    uses: BeeSec-UK/beesec-factory/.github/workflows/deploy-app.yml@app-stack-v1.8.4"
caller "a commit pin with its tag in a comment is read" 0 app-stack-v1.8.4 \
  "    uses: BeeSec-UK/beesec-factory/.github/workflows/deploy-app.yml@826215084c92be84a3e4ccc843d0464a67cda943 # app-stack-v1.8.4"
caller "a bare commit pin of a known version is read" 0 app-stack-v1.10.1 \
  "    uses: BeeSec-UK/beesec-factory/.github/workflows/deploy-app.yml@f23c87d7bddc5be3e47329241298801cbc14937e"
caller "no deploy-app.yml pin defaults to app-stack-v1.12.3" 0 app-stack-v1.12.3 \
  "    uses: BeeSec-UK/beesec-factory/.github/actions/release-artifact@app-stack-v1.4.1"
caller "the same version in two places is fine" 0 app-stack-v1.8.3 \
  "    uses: BeeSec-UK/beesec-factory/.github/workflows/deploy-app.yml@app-stack-v1.8.3" \
  "    uses: BeeSec-UK/beesec-factory/.github/workflows/deploy-app.yml@app-stack-v1.8.3"
caller "a version with no plan step fails" 1 "" \
  "    uses: BeeSec-UK/beesec-factory/.github/workflows/deploy-app.yml@app-stack-v1.9.0"
caller "an unknown commit with no tag comment fails" 1 "" \
  "    uses: BeeSec-UK/beesec-factory/.github/workflows/deploy-app.yml@0123456789abcdef0123456789abcdef01234567"
caller "a commit whose comment names another version fails" 1 "" \
  "    uses: BeeSec-UK/beesec-factory/.github/workflows/deploy-app.yml@826215084c92be84a3e4ccc843d0464a67cda943 # app-stack-v1.12.3"
caller "two different deploy versions fail" 1 "" \
  "    uses: BeeSec-UK/beesec-factory/.github/workflows/deploy-app.yml@app-stack-v1.8.3" \
  "    uses: BeeSec-UK/beesec-factory/.github/workflows/deploy-app.yml@app-stack-v1.10.1"
caller "a branch pin fails" 1 "" \
  "    uses: BeeSec-UK/beesec-factory/.github/workflows/deploy-app.yml@main"

# --- the scope step's infra output ----------------------------------------

jq -r '.scope.run' "$T/wf.json" > "$T/scope.sh"
mkdir -p "$T/bin"
# The compare API answers with the files in $FILES, one per line, or with an
# error body when $FILES is "ERROR".
cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
if [ "$FILES" = ERROR ]; then echo '{"message":"Not Found"}'; exit 0; fi
printf '%s\n' "$FILES" | jq -R . | jq -s '{files: map({filename: .})}'
EOF
chmod +x "$T/bin/curl"
run() {  # name expect-infra path_gates files
  : > "$T/out"
  PATH="$T/bin:$PATH" GITHUB_OUTPUT="$T/out" PATH_GATES="$3" FILES="$4" TRUST=false HAS_WEB=true SWA_PATHS="" PARALLEL_WEB=false \
    TOKEN=x REPO=BeeSec-UK/app EVENT=pull_request SHA=ffffffffffffffffffffffffffffffffffffffff BEFORE="" \
    PR_BASE=1111111111111111111111111111111111111111 PR_HEAD=2222222222222222222222222222222222222222 bash "$T/scope.sh" >/dev/null 2>&1
  got=$(sed -n 's/^infra=//p' "$T/out")
  [ "$got" = "$2" ] && pass "$1" || fail "$1" "infra='$got', expected $2"
}
run "an infra/ change says infra=true" true true $'infra/main.bicep\nREADME.md'
run "a change outside infra/ says infra=false" false true $'api/app.py\nweb/src/a.ts'
run "a docs-only change says infra=false" false true 'docs/x.md'
run "path gates off says infra=true, as for everything else" true false 'README.md'
run "an unreadable diff says infra=true" true true ERROR
grep -q '^api=' "$T/out" && pass "the other outputs are still written" || fail "the other outputs are still written" "$(cat "$T/out")"

echo
[ "$fails" = 0 ] && echo "all passed" || echo "$fails failed"
[ "$fails" = 0 ]
