#!/usr/bin/env python3
"""Verify dispatcher equivalence allowing only relocated, identical string literals."""
import argparse
import hashlib
import json
import re
import subprocess
from pathlib import Path

from compare_codegen import read_code


def instructions(binary, symbol):
    text = subprocess.check_output(['objdump', '-d', '--no-show-raw-insn', '--disassemble=' + symbol,
                                    str(binary)], text=True)
    return [match[1].strip() for line in text.splitlines()
            if (match := re.match(r'^\s*[0-9a-f]+:\s+(.+)$', line))]


def literal(binary, address):
    sections = subprocess.check_output(['objdump', '-h', str(binary)], text=True)
    for line in sections.splitlines():
        fields = line.split()
        if len(fields) >= 7 and fields[0].isdigit():
            size, start, offset = (int(fields[i], 16) for i in (2, 3, 5))
            if start <= address < start + size:
                data = binary.read_bytes()
                begin = offset + address - start
                end = data.find(b'\0', begin, min(begin + 128, offset + size))
                if end < 0:
                    raise RuntimeError('Reference is not a short NUL-terminated literal')
                return data[begin:end].decode('utf-8')
    raise RuntimeError('Address is outside file sections')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('before', type=Path)
    p.add_argument('after', type=Path)
    p.add_argument('--output', type=Path, required=True)
    args = p.parse_args()
    symbol = 'c3ttp.$server$lambda1'
    before, _ = read_code(str(args.before), symbol)
    after, _ = read_code(str(args.after), symbol)
    first, second = instructions(args.before, symbol), instructions(args.after, symbol)
    assert len(before) == len(after) and len(first) == len(second), 'Dispatcher size/instruction count changed'
    changes = []
    for i, (a, b) in enumerate(zip(first, second)):
        # Comments name linker-generated symbols and are not instructions.
        if a.split('#')[0].strip() == b.split('#')[0].strip():
            continue
        pattern = r'^lea\s+0x[0-9a-f]+\(%rip\),(%\w+)\s+#\s+([0-9a-f]+)'
        left, right = re.match(pattern, a), re.match(pattern, b)
        assert left and right and left[1] == right[1], f'Non-literal instruction changed: {a} -> {b}'
        value = literal(args.before, int(left[2], 16))
        assert value == literal(args.after, int(right[2], 16)), 'Referenced literal changed'
        changes.append(dict(instruction_index=i, before=a, after=b, literal=value))
    result = dict(symbol=symbol, size=len(before), instruction_count=len(first),
                  before_sha256=hashlib.sha256(before).hexdigest(), after_sha256=hashlib.sha256(after).hexdigest(),
                  identical_bytes=before == after, equivalent_except_verified_literal_addresses=True,
                  relocated_literals=changes)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(f'PASS: {len(before)} bytes, {len(first)} instructions; {len(changes)} identical string literals relocated')


if __name__ == '__main__':
    main()
