#!/usr/bin/env python3
"""Preserve a Git revision's server and build matching before/after -O3 binaries."""
import argparse
import json
import platform
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "benchmark/out"
p = argparse.ArgumentParser(description=__doc__)
p.add_argument("--before-ref", default="ce049990004207ef47ec6e0cfc01662a316ceb0e")
args = p.parse_args()
OUT.mkdir(parents=True, exist_ok=True)
revision = subprocess.check_output(["git", "rev-parse", "--verify", args.before_ref + "^{commit}"], cwd=ROOT, text=True).strip()
with tempfile.TemporaryDirectory(prefix="c3ttp-baseline-") as directory:
    baseline = Path(directory)
    files = subprocess.check_output(["git", "ls-tree", "-r", "--name-only", revision], cwd=ROOT, text=True).splitlines()
    for name in files:
        if name == "c3ttp.c3i" or name.startswith("src/") or name == "examples/hello_server/src/main.c3":
            destination = baseline / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(subprocess.check_output(["git", "show", f"{revision}:{name}"], cwd=ROOT))
    for label, tree in (("before", baseline), ("after", ROOT)):
        common = ["c3c", "-O3", "compile", str(tree / "c3ttp.c3i"), str(tree / "src")]
        for name, source in (("server", tree / "examples/hello_server/src/main.c3"), ("parser", ROOT / "benchmark/parser.c3")):
            subprocess.run(common + [str(source), "-o", str(OUT / f"{label}-{name}")], cwd=directory, check=True)
metadata = {
    "baseline_commit": revision,
    "compiler": subprocess.check_output(["c3c", "--version"], text=True),
    "platform": platform.platform(),
    "flags": "-O3",
}
(OUT / "build.json").write_text(json.dumps(metadata, indent=2) + "\n")
print(f"Binaries and build metadata: {OUT}")
