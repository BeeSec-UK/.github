#!/usr/bin/env bash
# The pipeline deploys only from main's own ref, and the caller stub this
# repository documents tests every pull request.
#
# Six app repositories were each fixing the same gap separately (pollen#10,
# propolis#178 and #184, honeycomb#758, beehive#65, nectar#252): a caller
# triggered on `pull_request: branches: [main]` runs nothing for a request
# stacked on another branch, and an empty check list reads like a pass rather
# than like an absence. The trigger lives in the caller, not here, so what
# this repository owns is the stub every new app copies and the rule that no
# pull request reaches a deploy.
#
#   bash tests/pr-trigger.test.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
exec python3 "$HERE/pr_trigger_test.py" "$HERE/../.github/workflows/beesec-app.yml"
