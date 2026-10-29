#!/usr/bin/env bash
# Tests for the IaC policy check folded into beesec-app.yml
# (docs/security-gate-plan.md, check 4). The step is a `uses:` of the
# factory plan action, so its wiring is checked in the YAML. The pick job's
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
FACTORY_SHA=28b74eb34426471f4450d41f60247a37a9a00e6c   # app-stack-v1.12.3, decision A

python3 - "$WF" > "$T/wf.json" <<'EOF' || { echo "FAIL  could not read $WF"; exit 1; }
import json, sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
on = wf[True]["workflow_call"]
out = {"inputs": {k: on["inputs"].get(k) for k in ("iac_params_file", "iac_subscription_name", "iac_subscription_id")},
       "pick_outputs": wf["jobs"]["pick"].get("outputs", {}),
       "iac_steps": [{"job": j, "step": s} for j, job in wf["jobs"].items() for s in job.get("steps", []) if s.get("id") == "iac"],
       "scope": next(s for s in wf["jobs"]["pick"]["steps"] if s.get("id") == "scope")}
print(json.dumps(out))
EOF
q() { jq -c "$1" "$T/wf.json"; }

# --- the workflow wiring --------------------------------------------------

for k in iac_params_file iac_subscription_name iac_subscription_id; do
  q ".inputs.$k | .type == \"string\" and .default == \"\"" | grep -qx true \
    && pass "$k is a string input, empty by default" || fail "$k is a string input, empty by default" "$(q ".inputs.$k")"
done
[ "$(q '.iac_steps | map(.job)')" = '["gate"]' ] && pass "the iac step is in the gate only" || fail "the iac step is in the gate only" "$(q '.iac_steps | map(.job)')"
s=$(q '.iac_steps[0].step // empty')
uses=$(printf '%s' "$s" | jq -r '.uses // empty')
[ "$uses" = "BeeSec-UK/beesec-factory/.github/actions/plan@$FACTORY_SHA" ] \
  && pass "it pins the factory plan action to app-stack-v1.12.3 by commit" || fail "it pins the factory plan action to app-stack-v1.12.3 by commit" "uses: $uses"
grep -qF "plan@$FACTORY_SHA # app-stack-v1.12.3" "$WF" && pass "the pin names its tag" || fail "the pin names its tag" "no '# app-stack-v1.12.3' beside the sha"
cond=$(printf '%s' "$s" | jq -r '.if // empty')
for want in "inputs.security_checks" "inputs.iac_params_file != ''" "github.event_name == 'pull_request'" "needs.pick.outputs.infra == 'true'"; do
  case "$cond" in *"$want"*) pass "it runs only when $want" ;; *) fail "it runs only when $want" "if: $cond" ;; esac
done
printf '%s' "$s" | jq -e '."continue-on-error" == "${{ !inputs.security_enforce }}"' >/dev/null \
  && pass "it is shadow until security_enforce" || fail "it is shadow until security_enforce" "$(printf '%s' "$s" | jq -c '."continue-on-error"')"
printf '%s' "$s" | jq -e '.with == {"params-file": "${{ inputs.iac_params_file }}", "subscription-name": "${{ inputs.iac_subscription_name }}", "subscription-id": "${{ inputs.iac_subscription_id || '"'"'00000000-0000-0000-0000-000000000000'"'"' }}"}' >/dev/null \
  && pass "it hands the action the caller's params file and subscription" || fail "it hands the action the caller's params file and subscription" "with: $(printf '%s' "$s" | jq -c .with)"
[ "$(q '.pick_outputs.infra')" = '"${{ steps.scope.outputs.infra }}"' ] \
  && pass "pick exposes the scope step's infra output" || fail "pick exposes the scope step's infra output" "$(q '.pick_outputs.infra')"

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
