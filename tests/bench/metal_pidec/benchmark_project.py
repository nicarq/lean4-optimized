#!/usr/bin/env python3
"""Measure the normal FPrime package emitter, without saved replay inputs.

Run with the selected Lean toolchain on PATH and a new external output directory.
Build artifacts and dependencies may be cached; the record states that scope.
The complete emitted bytes must match the checked project artifact.
"""
import argparse
import filecmp
import json
import os
from pathlib import Path
import shutil
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("project", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    project = args.project.resolve(strict=True)
    expected = project / "artifacts/nightstream-fprime-stage1-poseidon2-hash-chain-v1.json"
    if not expected.is_file():
        parser.error("the checked canonical project artifact is required")
    lake = shutil.which("lake")
    timeout = Path("/opt/homebrew/bin/timeout")
    if lake is None or not timeout.is_file():
        parser.error("select a Lean toolchain on PATH and install Homebrew coreutils")
    args.output.mkdir(parents=True, exist_ok=False)
    output = args.output.resolve()
    bounded = output / "bounded-tools"
    bounded.mkdir()
    wrapper = bounded / "timeout"
    wrapper.write_text('#!/bin/sh\nexec /opt/homebrew/bin/timeout --foreground "$@"\n')
    wrapper.chmod(0o755)
    env = os.environ.copy()
    env["PATH"] = str(bounded) + os.pathsep + env["PATH"]
    env["LEAN_NUM_THREADS"] = subprocess.check_output(
        ["sysctl", "-n", "hw.logicalcpu"], text=True).strip()
    record = {
        "scope": "Normal canonical package emission; no saved witness or custom driver",
        "project": str(project), "lake": lake,
        "commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=project, text=True).strip(),
        "dirty": subprocess.check_output(["git", "status", "--porcelain"], cwd=project, text=True),
        "build_scope": "Build emit with existing artifacts and dependency caches; not a clean build",
        "workers": int(env["LEAN_NUM_THREADS"]), "commands": [],
        "metal_speedup": None,
        "metal_status": "Current PR changes only a separate replay driver; this command has no Metal integration",
    }
    result_path = output / "results.json"

    def run(name, command):
        # 1,500 seconds is the project policy cap for each Lean command.
        argv = [str(timeout), "--signal=KILL", "1500", "/usr/bin/time", "-l",
                "bash", "scripts/validate.sh", "lean-executable", *map(str, command)]
        started = time.perf_counter()
        with (output / (name + ".log")).open("x") as log:
            result = subprocess.run(argv, cwd=project, env=env, stdout=log, stderr=subprocess.STDOUT)
        entry = {"name": name, "argv": argv, "exit": result.returncode,
                 "wall_seconds": time.perf_counter() - started}
        record["commands"].append(entry)
        result_path.write_text(json.dumps(record, indent=2) + "\n")
        print(json.dumps(entry), flush=True)
        if result.returncode:
            raise SystemExit(result.returncode)

    run("build", [lake, "build", "emit"])
    emitted = output / "package.json"
    run("emit", [project / ".lake/build/bin/emit", "--poseidon2-hash-chain-v1", emitted])
    record["output_bytes"] = emitted.stat().st_size
    record["checked_artifact"] = str(expected)
    record["complete_bytes_match"] = filecmp.cmp(emitted, expected, shallow=False)
    result_path.write_text(json.dumps(record, indent=2) + "\n")
    if not record["complete_bytes_match"]:
        raise SystemExit("emitted package differs from the checked artifact")
    print("Complete package bytes match the checked artifact.", flush=True)


if __name__ == "__main__":
    main()
