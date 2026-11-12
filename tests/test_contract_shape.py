#!/usr/bin/env python3
"""Merge-contract conformance (Distro files/36 + INTEGRATION-NOTE.md).

Proves, against the tranche's own reference code staged in the Distro
goal workspace:
  1. A sample stream in the exact shape Tachometer's writer emits
     {ts, app, proc, pid, cpu_pct_thread, rss_bytes, pct_total} is
     scored by the reference budget_scorer without error, and the
     analytics-self + minion budgets resolve to real verdicts
     (not NO DATA) when their processes are present.
  2. minion-avatar is scored from renderer+gpu rows ONLY (a stream with
     just a shell row reads NO DATA for the avatar budget — the role
     label is load-bearing).
  3. The ObjC sources literally contain the contract keys and role
     vocabulary (grep-level identity between this test and the ship
     code), and the bundled budgets table is byte-identical to the
     tranche's table of record.
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
STAGED = os.path.expanduser(
    "~/workspace/goals/distro-academy-application-store-for-high-sierra"
    "-project-07/hidden_files/work/ondevice-fs-rm")
sys.path.insert(0, STAGED)
import budget_scorer  # noqa: E402  (the reference scorer, unmodified)

failures = []

def check(name, ok, detail=""):
    print(("PASS " if ok else "FAIL ") + name + ((" — " + detail) if detail else ""))
    if not ok:
        failures.append(name)

# --- 1. Reference scorer over the emitted shape -------------------------
with open(os.path.join(STAGED, "budgets-v1.json"), encoding="utf-8") as f:
    budgets = json.load(f)

def rec(ts, app, proc, pid, cpu, rss):
    return {"ts": ts, "app": app, "proc": proc, "pid": pid,
            "cpu_pct_thread": cpu, "rss_bytes": rss, "pct_total": cpu / 4.0}

stream = []
for ts in (1794506700.0, 1794506705.0, 1794506710.0):
    stream.append(rec(ts, "com.detroitautomationacademy.analytics",
                      "Tachometer", 4242, 1.2, 30 * 1024 * 1024))
    stream.append(rec(ts, "com.detroitautomationacademy.minion",
                      "shell", 2257, 2.5, 90 * 1024 * 1024))
    stream.append(rec(ts, "com.detroitautomationacademy.minion",
                      "renderer", 2328, 6.0, 120 * 1024 * 1024))
    stream.append(rec(ts, "com.detroitautomationacademy.minion",
                      "gpu", 2323, 2.0, 60 * 1024 * 1024))
verdicts = {v["id"]: v for v in budget_scorer.score(budgets, stream)}
check("reference scorer parses emitted shape", True)
check("analytics-self scores (not NO DATA)",
      verdicts["analytics-self"]["verdict"] == "PASS",
      json.dumps(verdicts["analytics-self"]))
check("minion-avatar scores from renderer+gpu",
      verdicts["minion-avatar"]["verdict"] == "PASS"
      and verdicts["minion-avatar"]["cpu_sustained"] == 8.0,
      json.dumps(verdicts["minion-avatar"]))
check("minion-complex sums the whole complex",
      verdicts["minion-complex"]["cpu_sustained"] == 10.5,
      json.dumps(verdicts["minion-complex"]))

# --- 2. Role label is load-bearing --------------------------------------
shell_only = [r for r in stream if r["proc"] == "shell"]
v2 = {v["id"]: v for v in budget_scorer.score(budgets, shell_only)}
check("shell-only stream -> minion-avatar NO DATA",
      v2["minion-avatar"]["verdict"] == "NO DATA")

# Self-budget breach reads FAIL, never silently passes.
hot = [dict(r, cpu_pct_thread=9.9) if r["app"].endswith(".analytics") else r
       for r in stream]
v3 = {v["id"]: v for v in budget_scorer.score(budgets, hot)}
check("analytics-self breach -> FAIL",
      v3["analytics-self"]["verdict"] == "FAIL",
      json.dumps(v3["analytics-self"]))

# --- 3. Source identity ---------------------------------------------------
mc = open(os.path.join(ROOT, "Tachometer", "MainController.m"),
          encoding="utf-8").read()
for key in ('\\"ts\\":%.3f', '\\"app\\":', '\\"proc\\":', '\\"pid\\":',
            '\\"cpu_pct_thread\\"', '\\"rss_bytes\\"'):
    check("writer emits key " + key, key in mc)
ps = open(os.path.join(ROOT, "Tachometer", "ProcSampler.m"),
          encoding="utf-8").read()
for role in ('@"gpu"', '@"renderer"', '@"shell"', '@"helper"'):
    check("sampler role " + role, role in ps)
check("sampler reads pti_resident_size", "pti_resident_size" in ps)

bundled = open(os.path.join(ROOT, "Tachometer", "Resources",
                            "budgets-v1.json"), "rb").read()
staged = open(os.path.join(STAGED, "budgets-v1.json"), "rb").read()
check("bundled budgets-v1.json byte-identical to table of record",
      bundled == staged)

note = os.path.join(STAGED, "INTEGRATION-NOTE.md")
check("merge contract present at staging path", os.path.exists(note))

print("\n%d failures" % len(failures))
sys.exit(1 if failures else 0)
