#!/usr/bin/env bash
# Tests for #53: a caller that pins the shared workflows to a commit runs
# exactly that commit. So nothing in .github/workflows/ may fetch from a
# moving ref while it runs, and every action it calls is named by commit.
# Checks are numbered as in docs/remediation/issue-53.md. Each work package
# adds the ones it closes.
#
#   bash tests/pin.test.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT="$HERE/.."

python3 -I - "$ROOT" <<'PY'
import os, re, sys, yaml

root = sys.argv[1]
wfdir = os.path.join(root, ".github", "workflows")
fails = 0

def check(name, ok, why=""):
    global fails
    print(("PASS  " if ok else "FAIL  ") + name + ("" if ok else ": " + why))
    if not ok:
        fails += 1

SHA = re.compile(r"^[0-9a-f]{40}$")
wfs = sorted(f for f in os.listdir(wfdir) if f.endswith((".yml", ".yaml")))

def steps_of(wf):
    for jname, job in (wf.get("jobs") or {}).items():
        if "uses" in job:
            yield jname, {"uses": job["uses"]}
        for st in job.get("steps") or []:
            yield jname, st

# A URL that names a branch rather than a commit.
RAW = re.compile(r"raw\.githubusercontent\.com/[^/\s]+/[^/\s]+/([^/\s]+)/")
HEADS = re.compile(r"https?://\S*refs/heads/")

for f in wfs:
    path = os.path.join(wfdir, f)
    text = open(path).read()
    wf = yaml.safe_load(text)

    # 3. Nothing fetched from a branch at run time. Read from parsed values,
    # so comments are not read, and `if:` comparisons are not fetches.
    bad = []
    for j, st in steps_of(wf):
        u = str(st.get("uses", ""))
        if u and not u.startswith("./") and "@" in u and not SHA.match(u.rpartition("@")[2]):
            bad.append(f"{j}: uses {u}")
        ref = (st.get("with") or {}).get("ref")
        if isinstance(ref, str) and ref.strip() and "${{" not in ref and not SHA.match(ref.strip()):
            bad.append(f"{j}: with ref {ref}")
        run = str(st.get("run", ""))
        for m in RAW.finditer(run):
            if not SHA.match(m.group(1)):
                bad.append(f"{j}: run fetches {m.group(0)}")
        if HEADS.search(run):
            bad.append(f"{j}: run fetches a refs/heads URL")
    check(f"3 {f}: nothing is fetched from a branch at run time", not bad, "; ".join(bad))

    # 4. Every uses: is local or a 40-hex commit with a # comment. Read from
    # the raw lines, because the comment is not in the parsed YAML.
    bad = []
    for n, line in enumerate(text.splitlines(), 1):
        m = re.match(r"^\s*(?:-\s+)?uses:\s*(\S+)(.*)$", line)
        if not m:
            continue
        u, rest = m.group(1), m.group(2)
        if u.startswith("./"):
            continue
        if not (SHA.match(u.rpartition("@")[2]) and re.match(r"^\s+#\s*\S", rest)):
            bad.append(f"{f}:{n} {u}")
    check(f"4 {f}: every action is named by commit with its tag as a comment", not bad, "; ".join(bad))

# 5. The gitleaks config travels in the workflow, byte-for-byte .gitleaks.toml.
want = open(os.path.join(root, ".gitleaks.toml")).read()
app = yaml.safe_load(open(os.path.join(wfdir, "beesec-app.yml")))
found = 0
for j, st in steps_of(app):
    if "gitleaks" not in str(st.get("name", "")).lower():
        continue
    found += 1
    run = str(st.get("run", ""))
    m = re.search(r"<<'GITLEAKS_TOML'\n(.*?\n)GITLEAKS_TOML\n", run, re.S)
    check(f"5 {j}: the gitleaks step writes .gitleaks.toml from a quoted heredoc", bool(m), "no <<'GITLEAKS_TOML' heredoc")
    if m:
        check(f"5 {j}: its heredoc is byte-for-byte .gitleaks.toml", m.group(1) == want, "differs from .gitleaks.toml")
check("5 beesec-app.yml has both gitleaks steps", found == 2, f"found {found}")

# 6. Dependabot proposes bumps to these pins as pull requests here.
dp = os.path.join(root, ".github", "dependabot.yml")
ok, why = False, "missing"
if os.path.exists(dp):
    try:
        d = yaml.safe_load(open(dp)) or {}
        ups = d.get("updates") or []
        ok = d.get("version") == 2 and any(
            u.get("package-ecosystem") == "github-actions" and u.get("directory") == "/"
            and (u.get("schedule") or {}).get("interval") for u in ups)
        why = repr(d)
    except yaml.YAMLError as e:
        why = f"does not parse: {e}"
check("6 .github/dependabot.yml has a scheduled github-actions entry for /", ok, why)

sys.exit(1 if fails else 0)
PY
