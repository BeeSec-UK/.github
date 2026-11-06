"""Checks behind tests/pr-trigger.test.sh. Run through that script.

Two things this repository owns, and one it does not.

It owns the rule that no pull request reaches a deploy, and that a deploy
runs only from main's own ref. beesec-factory's ADR 0002 requires the second:
without it a dispatch on any branch, or a caller that widens its push
trigger, reaches a deploy, and the only thing refusing it is Azure's
federated subject rather than this pipeline.

It owns the caller stub in beesec-app.yml's header comment, because that is
what every new app copies. The stub showed `pull_request: { branches: [main] }`
and a top-level `id-token: write`, so each app copying it inherited both.

It does not own the trigger. That lives in each app's own workflow, in each
app's own repository, and nothing here can reach it. Fixing the stub stops
the next app from inheriting the gap; it does not fix the apps that already
have it.
"""
import sys

import yaml

fails = []


def check(name, ok, why=""):
    if ok:
        print(f"PASS  {name}")
    else:
        print(f"FAIL  {name}: {why}")
        fails.append(name)


def deploy_jobs(jobs):
    return {n: j for n, j in jobs.items()
            if "deploy_swa" in str(j.get("if")) or "deploy_api" in str(j.get("if"))}


def main(path):
    text = open(path).read()
    doc = yaml.safe_load(text)
    jobs = doc.get("jobs") or {}
    deploys = deploy_jobs(jobs)

    check("a deploy job exists to check", bool(deploys),
          "no job conditions on deploy_swa or deploy_api, so the rest proves nothing")

    missing = [n for n, j in deploys.items()
               if "github.ref == 'refs/heads/main'" not in str(j.get("if"))]
    check("deploys are held to main's own ref", deploys and not missing,
          "without a ref check: " + ", ".join(missing))

    loose = [n for n, j in deploys.items()
             if "github.event_name == 'push'" not in str(j.get("if"))
             and "github.event_name == 'workflow_dispatch'" not in str(j.get("if"))]
    check("deploys never run on a pull request", deploys and not loose,
          "not held to push or dispatch: " + ", ".join(loose))

    # The stub is a comment. Read it as text, which is how an app author reads it.
    check("the documented stub filters no pull request by base",
          "pull_request: { branches:" not in text,
          "the stub still shows a base filter, which is the gap six repositories fixed")

    check("the documented stub names edited among its types",
          "pull_request: { types: [opened, synchronize, reopened, edited] }" in text,
          "the stub must list all four types, because naming types drops the defaults")

    i = text.find("#   permissions:")
    j = text.find("#   concurrency:", i + 1) if i >= 0 else -1
    check("the documented stub grants no top-level id-token",
          i >= 0 and j > i and "id-token" not in text[i:j],
          "the stub grants id-token above the jobs, which reaches the jobs a "
          "pull request runs")

    check("the documented stub keeps secrets: inherit on the pipeline job",
          "#       secrets: inherit" in text,
          "the stub no longer shows where the secret store goes, which is the "
          "job whose deploys are the only user of it")

    print()
    print("all checks passed" if not fails else f"{len(fails)} check(s) failed")
    return len(fails)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
