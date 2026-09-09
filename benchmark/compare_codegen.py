#!/usr/bin/env python3
"""Compare a dispatcher symbol's machine code in two Linux benchmark binaries."""
import argparse
import hashlib
import json
import subprocess
import tempfile
from pathlib import Path


def read_code(binary, symbol):
    sections = subprocess.check_output(["objdump", "-h", binary], text=True)
    text_base = next(int(line.split()[3], 16) for line in sections.splitlines()
                     if len(line.split()) > 3 and line.split()[1] == ".text")
    symbols = subprocess.check_output(["nm", "-S", "--defined-only", binary], text=True)
    fields = next(line.split() for line in symbols.splitlines()
                  if len(line.split()) == 4 and line.split()[3] == symbol)
    offset, size = int(fields[0], 16) - text_base, int(fields[1], 16)
    with tempfile.TemporaryDirectory(prefix="c3ttp-codegen-") as directory:
        destination = Path(directory) / "text.bin"
        # Supply an output ELF as well, so objcopy never rewrites the input.
        subprocess.run(["objcopy", "--dump-section", f".text={destination}", binary,
                        str(Path(directory) / "copy.elf")], check=True)
        text = destination.read_bytes()
    return text[offset:offset + size], text


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("before")
    parser.add_argument("after")
    parser.add_argument("--symbol", default="c3ttp.$server$lambda1")
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    before, before_text = read_code(args.before, args.symbol)
    after, after_text = read_code(args.after, args.symbol)
    result = {
        "symbol": args.symbol,
        "before": {"binary": args.before, "size": len(before),
                   "sha256": hashlib.sha256(before).hexdigest()},
        "after": {"binary": args.after, "size": len(after),
                  "sha256": hashlib.sha256(after).hexdigest()},
        "identical_dispatcher": before == after,
        "identical_text_section": before_text == after_text,
        "text_differing_bytes": sum(a != b for a, b in zip(before_text, after_text))
                                + abs(len(before_text) - len(after_text)),
    }
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))
    if not result["identical_dispatcher"]:
        raise SystemExit("Dispatcher machine code differs; inspect disassembly before accepting")


if __name__ == "__main__":
    main()
