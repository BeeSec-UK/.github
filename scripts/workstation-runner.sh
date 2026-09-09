#!/usr/bin/env bash
# Register this machine as a BeeSec CI runner, so it takes the next queued
# job alongside the Mele whenever it is on.
#
#   scripts/workstation-runner.sh                # org-wide: needs admin:org on gh
#   scripts/workstation-runner.sh BeeSec-UK/honeycomb   # one repo: repo admin is enough
#   scripts/workstation-runner.sh --instances 2  # take two jobs at once (big box)
#
# What it does, in order, and each step is skipped when already done:
#   1. downloads the current actions/runner into ~/actions-runner[-N]
#   2. seeds the tool cache with Python 3.11 when the distribution is one
#      actions/setup-python does not recognise (Linux Mint reports itself as
#      Linuxmint, not Ubuntu, and the action then finds nothing)
#   3. mints a registration token through gh and registers the runner with
#      the pool labels self-hosted, linux, x64 plus workstation
#   4. prints the one sudo command that installs it as a service
#
# Nothing here needs sudo. The service install does, and is printed rather
# than run because it is the one step that outlives this shell. The runner
# needs docker, the Azure CLI and the app's apt packages present, because
# deploy jobs land on it too; the pipeline's apt step only runs when a
# package is missing, so a machine without passwordless sudo is fine once
# it has them. See docs/ci.md for why this exists and what it saves.
set -euo pipefail

scope="orgs/BeeSec-UK"
url="https://github.com/BeeSec-UK"
instances=1
while [ $# -gt 0 ]; do
  case "$1" in
    --instances) instances="$2"; shift 2 ;;
    */*) scope="repos/$1"; url="https://github.com/$1"; shift ;;
    *) echo "usage: $0 [OWNER/REPO] [--instances N]" >&2; exit 2 ;;
  esac
done

command -v gh >/dev/null || { echo "gh is required and must be logged in" >&2; exit 1; }
command -v docker >/dev/null || echo "warning: docker not found; the SWA deploy job cannot run here" >&2
command -v az >/dev/null || echo "warning: az not found; the Function App deploy cannot run here" >&2

version="$(gh api repos/actions/runner/releases/latest -q .tag_name | sed 's/^v//')"
distro="$(. /etc/os-release && echo "${ID:-}")"

seed_python() {
  local tool="$1/_work/_tool"
  [ -d "$tool/Python" ] && return 0
  local tag asset tmp
  tag="$(gh release list -R actions/python-versions --limit 80 --json tagName \
        --jq '.[] | select(.tagName|startswith("3.11.")) | .tagName' | head -1)"
  asset="$(gh release view "$tag" -R actions/python-versions --json assets \
        --jq '.assets[] | select(.name|test("linux-24.04-x64.tar.gz$")) | .name' | head -1)"
  tmp="$(mktemp -d)"
  ( cd "$tmp" && gh release download "$tag" -R actions/python-versions -p "$asset" >/dev/null \
    && tar xzf "$asset" && RUNNER_TOOL_CACHE="$tool" bash ./setup.sh >/dev/null 2>&1 || true )
  local ver
  ver="$(ls "$tool/Python" | head -1)"
  [ -n "$ver" ] && touch "$tool/Python/$ver/x64.complete"
  rm -rf "$tmp"
  echo "seeded Python $ver into $tool"
}

for n in $(seq 1 "$instances"); do
  dir="$HOME/actions-runner"; [ "$n" -gt 1 ] && dir="$HOME/actions-runner-$n"
  name="$(hostname)"; [ "$n" -gt 1 ] && name="$(hostname)-$n"
  mkdir -p "$dir"
  if [ ! -f "$dir/config.sh" ]; then
    curl -sSL -o "$dir/runner.tgz" \
      "https://github.com/actions/runner/releases/download/v${version}/actions-runner-linux-x64-${version}.tar.gz"
    tar xzf "$dir/runner.tgz" -C "$dir" && rm "$dir/runner.tgz"
  fi
  case "$distro" in ubuntu|debian) ;; *) seed_python "$dir" ;; esac
  if [ -f "$dir/.runner" ]; then
    echo "$name is already registered from $dir"
  else
    token="$(gh api -X POST "$scope/actions/runners/registration-token" -q .token)"
    ( cd "$dir" && ./config.sh --unattended --url "$url" --token "$token" --name "$name" \
        --labels workstation --work _work --replace >/dev/null )
    unset token
    echo "registered $name against $url"
  fi
  echo "to run it as a service:  sudo $dir/svc.sh install && sudo $dir/svc.sh start"
done
