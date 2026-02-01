#!/usr/bin/env python3
"""
Parse FPC assembly (.s) to find _FPC_local_unwind call and its target label.
Use when objdump disasm has no symbols (stripped PE).

Usage: analyze_from_asm.py arm64trap.s
"""

import re
import sys

def main():
    if len(sys.argv) < 2:
        print("Usage: analyze_from_asm.py <file.s>")
        sys.exit(2)
    path = sys.argv[1]
    try:
        with open(path) as f:
            lines = f.readlines()
    except OSError as e:
        print("Error:", e)
        sys.exit(2)

    # Find: adrp x1, .Lxxx \n add x1, x1, :lo12:.Lxxx \n bl _FPC_local_unwind
    target_label = None
    bl_line = None
    for i, line in enumerate(lines):
        if "bl" in line and "_FPC_local_unwind" in line:
            bl_line = i + 1
            # Look backwards for adrp x1, .Lxxx and add x1, x1, :lo12:.Lxxx
            for j in range(i - 1, max(-1, i - 6), -1):
                m = re.search(r"adrp\s+x1\s*,\s*([.\w]+)", lines[j])
                if m:
                    target_label = m.group(1)
                    break
            break

    if bl_line and target_label:
        print("ASM_DEED: bl _FPC_local_unwind at line", bl_line)
        print("ASM_TARGET_LABEL:", target_label)
        # Find where target is defined and show code
        for i, line in enumerate(lines):
            if re.match(r"^" + re.escape(target_label) + r"\s*:", line):
                print("ASM_TARGET_AT_LINE:", i + 1)
                for j in range(i, min(i + 8, len(lines))):
                    print(" ", lines[j].rstrip())
                    if "ret" in lines[j]:
                        break
                break
    elif bl_line:
        print("ASM_DEED: bl _FPC_local_unwind at line", bl_line, "(could not find target label)")
    else:
        print("ASM_DEED: no bl _FPC_local_unwind found in", path)

if __name__ == "__main__":
    main()
