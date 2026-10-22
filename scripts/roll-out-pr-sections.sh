#!/usr/bin/env bash
# Open the one-file pr-sections caller PR in every non-archived private
# BeeSec-UK repo that does not already have it. Run by the operator, or a
# session acting for them, with their own gh. Safe to re-run: a repo with the
# file on its default branch, or with the branch already pushed, is skipped.
#
#   scripts/roll-out-pr-sections.sh            open the PRs
#   scripts/roll-out-pr-sections.sh --dry-run  list what it would do
#
# Public repos are skipped on purpose: the check runs on the self-hosted
# beesec-linux runners, and a fork's pull request to a public repo would run
# there too. Review alerts decision 10, BeeSec-UK/beesec-release.
set -euo pipefail
ORG=BeeSec-UK
BRANCH=ci/pr-sections
FILE=.github/workflows/pr-sections.yml
dry=false; [ "${1:-}" = --dry-run ] && dry=true

caller=$(cat <<'YAML'
# Checks the PR description has What it does, Try it on dev and the Claude
# test prompt. The check lives in BeeSec-UK/.github, and this file only calls it.
name: pr-sections

on:
  pull_request:
    types: [opened, edited, reopened, synchronize, ready_for_review]

permissions: {}

jobs:
  sections:
    uses: BeeSec-UK/.github/.github/workflows/pr-sections.yml@main
YAML
)

body() {  # $1 repo, $2 PR URL or empty
  local diff="Open this pull request's Files changed tab."
  [ -n "$2" ] && diff="Read the diff first: $2/files"
  cat <<MD
## What it does

Adds the pr-sections check to this repository. Every pull request here then shows a failing check while "What it does" or "Try it on dev" is empty, or while the Claude test prompt is missing, names a non-dev host or holds anything credential-shaped. That way a reviewer can pick a change up without asking the author. The check only reads the pull request description, and it has no permissions.

## Try it on dev

There is nothing to run on dev, because this changes CI only. This pull request is its own test. The pr-sections check runs on it and passes, because this description is filled in. To see it fail, empty "What it does" in this description: the check turns red within a minute. Put the text back afterwards.

## Claude test prompt

\`\`\`text
Review a pull request that adds one CI file to BeeSec-UK/$1, then report.

Rules: work only on github.com. Never open any other host. I am already signed in, so never type a password or token. Report what you find and change nothing: no commits, comments, reviews or edits.

1. $diff Expect exactly one new file, $FILE, which only calls BeeSec-UK/.github/.github/workflows/pr-sections.yml@main and sets permissions to {}.
2. Open https://github.com/BeeSec-UK/.github/blob/main/.github/workflows/pr-sections.yml and expect it to read the description from the event file, with no checkout, no secrets and no write permission.
3. Open this pull request's Checks tab and expect pr-sections / sections to have passed.
4. Negative case: in that check's log, expect no step that checks out code or uses a token.
5. Evidence: a screenshot of the Checks tab and of the file in step 2.
6. Verdict: pass or fail for each case, one line each, then anything else you noticed.
\`\`\`

A Claude run is evidence, not approval. The second person still submits the approving review.

## How it was checked

The reusable check was tested against 14 descriptions in BeeSec-UK/.github#23. This pull request runs it for real.
MD
}

mapfile -t repos < <(gh repo list "$ORG" --no-archived -L 500 --json name,visibility,isEmpty \
  --jq '.[] | select(.visibility == "PRIVATE" and (.isEmpty | not)) | .name' | sort -f)
for r in "${repos[@]}"; do
  base=$(gh api "repos/$ORG/$r" --jq .default_branch)
  if gh api "repos/$ORG/$r/contents/$FILE?ref=$base" >/dev/null 2>&1; then echo "skip $r: already has $FILE"; continue; fi
  if gh api "repos/$ORG/$r/git/ref/heads/$BRANCH" >/dev/null 2>&1; then echo "skip $r: $BRANCH already exists"; continue; fi
  if $dry; then echo "would open $r (base $base)"; continue; fi
  sha=$(gh api "repos/$ORG/$r/git/ref/heads/$base" --jq .object.sha)
  gh api -X POST "repos/$ORG/$r/git/refs" -f ref="refs/heads/$BRANCH" -f sha="$sha" >/dev/null
  gh api -X PUT "repos/$ORG/$r/contents/$FILE" -f branch="$BRANCH" \
    -f message="ci: add the pr-sections check" -f content="$(printf '%s\n' "$caller" | base64 -w0)" >/dev/null
  url=$(gh api -X POST "repos/$ORG/$r/pulls" -f title="ci: add the pr-sections check" -f head="$BRANCH" \
    -f base="$base" -f body="$(body "$r" "")" --jq .html_url)
  n=${url##*/}
  gh api -X PATCH "repos/$ORG/$r/pulls/$n" -f body="$(body "$r" "$url")" >/dev/null
  echo "$url"
done
