#!/usr/bin/env python3
"""Create AutomatedTechnologies/tachometer (if absent) and push the local
tree as ONE Git Data API commit to main + build-test. Auth: the stored
custom.github connector credential via authd's surrogate exchange,
mirroring bin/push_files.py. Never prints the credential."""
import base64
import json
import os
import sys
import urllib.request
import urllib.error

sys.path.insert(0, "/opt/muse/skills/custom-connector-setup/bin")
from dynamic_credentials import (
    add_surrogate_to_request,
    read_json_response,
    read_response_body,
)

API = "https://api.github.com"
ALLOWED = ["api.github.com"]
ORG = "AutomatedTechnologies"
REPO = "tachometer"
ROOT = os.path.expanduser("~/workspace/tachometer")

SKIP_DIRS = {".git", "__pycache__"}
SKIP_FILES = {"clang.log"}


def api(method, path, data=None, expect=(200, 201)):
    body = json.dumps(data).encode() if data is not None else None
    req = urllib.request.Request(API + path, data=body, method=method)
    req.add_header("Accept", "application/vnd.github+json")
    if body is not None:
        req.add_header("Content-Type", "application/json")
    add_surrogate_to_request(req, "custom.github", allowed_hosts=ALLOWED)
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            payload = read_json_response(resp)
            return resp.status, payload
    except urllib.error.HTTPError as e:
        detail = read_response_body(e).decode("utf-8", "replace")[:400]
        if e.code in expect:
            raise
        return e.code, {"detail": detail}


def collect_files():
    out = []
    for dirpath, dirnames, filenames in os.walk(ROOT):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for name in filenames:
            if name in SKIP_FILES:
                continue
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, ROOT)
            out.append((full, rel))
    return sorted(out, key=lambda p: p[1])


def main():
    # 1. Repo (public — catalog-serving repos stay public).
    status, payload = api("POST", f"/orgs/{ORG}/repos", {
        "name": REPO,
        "description": "Tachometer — Academy on-device analytics for macOS High Sierra (Detroit Automation Academy)",
        "private": False,
        "auto_init": False,
    }, expect=(201,))
    if status == 201:
        print("repo created")
    elif status == 422:
        print("repo already exists (422) — continuing")
    else:
        print("repo create:", status, payload)
        sys.exit(1)

    # 2. The Git Database API refuses an empty repo (409), so seed one
    # commit through the Contents API when main does not exist yet.
    status, ref = api("GET", f"/repos/{ORG}/{REPO}/git/refs/heads/main",
                      expect=(200,))
    base_commit = None
    base_tree = None
    if status != 200:
        seed = base64.b64encode(b"Seed commit for the Git Data API push.\n").decode()
        s2, _ = api("PUT", f"/repos/{ORG}/{REPO}/contents/SEED.txt",
                    {"message": "Seed (removed by the source push)",
                     "content": seed}, expect=(201,))
        print("seed:", s2)
        _, ref = api("GET", f"/repos/{ORG}/{REPO}/git/refs/heads/main")
    base_commit = ref["object"]["sha"]
    _, base_commit_obj = api("GET", f"/repos/{ORG}/{REPO}/git/commits/{base_commit}")
    base_tree = base_commit_obj["tree"]["sha"]

    # 3. Blobs.
    files = collect_files()
    tree_entries = []
    for full, rel in files:
        with open(full, "rb") as f:
            content = base64.b64encode(f.read()).decode()
        _, blob = api("POST", f"/repos/{ORG}/{REPO}/git/blobs",
                      {"content": content, "encoding": "base64"})
        mode = "100755" if rel == "build.sh" else "100644"
        tree_entries.append({"path": rel, "mode": mode,
                             "type": "blob", "sha": blob["sha"]})
    tree_entries.append({"path": "SEED.txt", "mode": "100644",
                         "type": "blob", "sha": None})  # delete the seed
    print(f"blobs: {len(tree_entries)}")

    # 4. Tree + commit on top of the seed.
    _, tree = api("POST", f"/repos/{ORG}/{REPO}/git/trees",
                  {"base_tree": base_tree, "tree": tree_entries})
    _, commit = api("POST", f"/repos/{ORG}/{REPO}/git/commits", {
        "message": "Tachometer test-1 source — Academy on-device analytics "
                   "(libproc CPU sampler, contract store + budget scorer, "
                   "on-device only, no network code)",
        "tree": tree["sha"],
        "parents": [base_commit],
    })
    sha = commit["sha"]
    print("commit:", sha)

    # 5. Refs: move main (fast-forward), create build-test at the commit.
    s3, p3 = api("PATCH", f"/repos/{ORG}/{REPO}/git/refs/heads/main",
                 {"sha": sha, "force": False}, expect=(200,))
    print("main updated:", s3 if s3 == 200 else p3)
    status, payload = api("POST", f"/repos/{ORG}/{REPO}/git/refs",
                          {"ref": "refs/heads/build-test", "sha": sha},
                          expect=(201,))
    print("ref build-test:", "created" if status == 201 else payload)

    # 5. Dispatch the build workflow on build-test.
    status, payload = api("POST",
        f"/repos/{ORG}/{REPO}/actions/workflows/build-tachometer.yml/dispatches",
        {"ref": "build-test"}, expect=(204,))
    print("workflow dispatch:", status, payload if status != 204 else "")


if __name__ == "__main__":
    main()
