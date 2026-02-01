#!/usr/bin/env python3
"""
Extract the target address passed to _FPC_local_unwind from ARM64 disassembly.

Before the "bl _FPC_local_unwind" call, the compiler sets:
  x0 = SP (frame)
  x1 = target (address to jump to after unwind)

We find the bl, then scan backwards to find how x1 was set (adrp+add or similar),
and report the resolved target plus the instructions at that address.

Usage:
  extract_unwind_target.py --disasm FILE

Output: Target address (hex), label if any, and next few instructions.
"""

import re
import sys
import os

DEED_SYMBOL = re.compile(r"_FPC_local_unwind|_FPC_LOCAL_UNWIND", re.I)
# Instruction patterns
ADDR_RE = re.compile(r"^\s*([0-9a-fA-F]+)\s*:\s*")
LABEL_RE = re.compile(r"^\s*([0-9a-fA-F]+)\s+<([^>]+)>\s*:\s*$")
# adrp x1, 0x12345678  or  adrp x1, imm
ADRP_RE = re.compile(r"\badrp\s+x1\s*,\s*(?:0x)?([0-9a-fA-F]+)", re.I)
# add x1, x1, #0x5c  or  add x1, x1, #imm
ADD_X1_RE = re.compile(r"\badd\s+x1\s*,\s*x1\s*,\s*#(?:0x)?([0-9a-fA-F]+)", re.I)
# adr x1, 0x...  (single instruction, PC-relative, disasm shows resolved addr)
ADR_X1_RE = re.compile(r"\badr\s+x1\s*,\s*(?:0x)?([0-9a-fA-F]+)", re.I)
# Alternative: add x1, x0, #imm when x0 was set by adrp
ADRP_ANY = re.compile(r"\badrp\s+x([0-9]+)\s*,\s*(?:0x)?([0-9a-fA-F]+)", re.I)
ADD_ANY = re.compile(r"\badd\s+x1\s*,\s*x([0-9]+)\s*,\s*#(?:0x)?([0-9a-fA-F]+)", re.I)


def parse_disasm(lines):
    """Parse disasm. Return (addr_to_inst, labels, bl_addr)."""
    addr_to_inst = {}
    labels = {}
    bl_addr = None

    i = 0
    while i < len(lines):
        line = lines[i]
        m = LABEL_RE.match(line)
        if m:
            addr = int(m.group(1), 16)
            labels[addr] = m.group(2).strip()
            i += 1
            continue
        m = ADDR_RE.match(line)
        if m:
            addr = int(m.group(1), 16)
            rest = line[m.end():].strip()
            parts = rest.split()
            inst_parts = [p for p in parts if not re.match(r"^[0-9a-fA-F]{8}$", p)]
            inst = " ".join(inst_parts) if inst_parts else rest
            addr_to_inst[addr] = inst
            if "bl" in inst and DEED_SYMBOL.search(inst):
                bl_addr = addr
            i += 1
            continue
        i += 1

    return addr_to_inst, labels, bl_addr


def extract_target(addr_to_inst, labels, bl_addr):
    """
    Find instructions before bl_addr that set x1 (target param). ARM64 typically:
      adrp x1, page   ; page-aligned base
      add  x1, x1, #offset
    In linked PE output, adrp shows resolved address; we add the low 12 bits from add.
    """
    addrs = sorted(addr_to_inst.keys())
    idx = addrs.index(bl_addr) if bl_addr in addrs else -1
    if idx < 0:
        return None

    adrp_val = None
    add_imm = None

    for k in range(1, min(10, idx + 1)):
        a = addrs[idx - k]
        inst = addr_to_inst.get(a, "")
        if not inst:
            continue
        m = ADR_X1_RE.search(inst)
        if m:
            return int(m.group(1), 16)
        m = ADRP_RE.search(inst)
        if m:
            adrp_val = int(m.group(1), 16)
        m = ADD_X1_RE.search(inst)
        if m:
            add_imm = int(m.group(1), 16)
        m = ADRP_ANY.search(inst)
        if m and adrp_val is None:
            adrp_val = int(m.group(2), 16)
        m = ADD_ANY.search(inst)
        if m and add_imm is None:
            add_imm = int(m.group(2), 16)

    if adrp_val is not None and add_imm is not None:
        target = (adrp_val & 0xfffffffffffff000) + add_imm
        return target
    if adrp_val is not None:
        return adrp_val & 0xfffffffffffff000
    return None


def main():
    import argparse
    p = argparse.ArgumentParser(description="Extract _FPC_local_unwind target from disasm.")
    p.add_argument("--disasm", required=True, metavar="FILE", help="Disassembly file (objdump -d)")
    args = p.parse_args()

    if not os.path.isfile(args.disasm):
        print("Error: disasm file not found:", args.disasm, file=sys.stderr)
        sys.exit(2)

    with open(args.disasm, "r") as f:
        lines = f.read().splitlines()

    addr_to_inst, labels, bl_addr = parse_disasm(lines)
    if bl_addr is None:
        print("UNWIND_TARGET: no bl _FPC_local_unwind found")
        sys.exit(0)

    target = extract_target(addr_to_inst, labels, bl_addr)

    addrs = sorted(addr_to_inst.keys())
    print("UNWIND_TARGET: bl _FPC_local_unwind at", hex(bl_addr))

    if target is not None:
        label = labels.get(target, "")
        print("UNWIND_TARGET: resolved target =", hex(target), label or "(no label)")
        # Show instructions at target (next 6)
        for i, a in enumerate(addrs):
            if a >= target:
                for j in range(6):
                    if i + j < len(addrs):
                        addr = addrs[i + j]
                        inst = addr_to_inst.get(addr, "")
                        lbl = labels.get(addr, "")
                        print("  ", hex(addr), lbl or "", inst)
                break
    else:
        print("UNWIND_TARGET: could not resolve target (scan instructions before bl)")
        # Dump instructions before bl for manual inspection
        idx = addrs.index(bl_addr)
        for k in range(min(6, idx + 1)):
            a = addrs[idx - k]
            print("  ", hex(a), addr_to_inst.get(a, ""))


if __name__ == "__main__":
    main()
