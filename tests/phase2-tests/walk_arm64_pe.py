#!/usr/bin/env python3
"""
Walk ARM64 Windows PE disassembly to find "the deed" (try/finally path) without running on Windows.

Usage:
  walk_arm64_pe.py EXE [OBJDUMP]     # disassemble EXE with OBJDUMP (or $OBJDUMP/PATH), then walk
  walk_arm64_pe.py --disasm FILE     # parse existing disasm file (from objdump -d)

Patterns we look for (to cut down code to walk):
  - "Deed" = instruction that does the try/finally exit: bl _FPC_local_unwind (fix) or b <finally_label> (no-fix)
  - We locate deed addresses first, then trace control flow from entry until we hit one (or max steps).

Exit: 0 if deed found and reached (or FIX_PRESENT); 1 if no deed / unreachable / error.
Output: One-line result (DEED_REACHED, FIX_PRESENT, NO_DEED, etc.) plus optional details to stderr.
"""

import re
import subprocess
import sys
import os

# Patterns: deed = call to _FPC_local_unwind (fix path)
DEED_SYMBOL = re.compile(r"_FPC_local_unwind|_FPC_LOCAL_UNWIND", re.I)
# Instruction line: optional label, then addr: optional_bytes instruction
# GNU: "  1000:  d63f0340  bl  1008 <_FPC_local_unwind>"
# LLVM: "1000:  d63f0340  bl  0x1008"
ADDR_RE = re.compile(r"^\s*([0-9a-fA-F]+)\s*:\s*")
LABEL_RE = re.compile(r"^\s*([0-9a-fA-F]+)\s+<([^>]+)>\s*:\s*$")
# Branch with link: bl <target>
BL_RE = re.compile(r"\bbl\s+(?:0x)?([0-9a-fA-F]+)|bl\s+.*?([_a-zA-Z][_a-zA-Z0-9]*)", re.I)
# Unconditional branch: b <target>
B_RE = re.compile(r"\bb\s+(?:0x)?([0-9a-fA-F]+)|\bb\s+\.L[A-Za-z0-9_$]+")
# Ret
RET_RE = re.compile(r"\bret\b", re.I)


def run_objdump(objdump_cmd, exe_path):
    """Run objdump -d EXE, return stdout lines."""
    try:
        out = subprocess.check_output(
            [objdump_cmd, "-d", exe_path],
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=10,
        )
        return out.splitlines()
    except (subprocess.CalledProcessError, FileNotFoundError, subprocess.TimeoutExpired) as e:
        return None


def parse_disassembly(lines):
    """
    Parse objdump -d output. Returns:
      addrs: list of (addr_int, instruction_str) in order
      addr_to_inst: dict addr_int -> instruction_str
      labels: dict addr_int -> symbol_name (for targets)
      deed_addrs: set of addr_int where instruction is bl _FPC_local_unwind
    """
    addrs = []
    addr_to_inst = {}
    labels = {}
    deed_addrs = set()
    # Symbol table from label lines: symbol_name -> addr (we'll resolve bl target by name)
    symbol_to_addr = {}

    i = 0
    while i < len(lines):
        line = lines[i]
        # Label-only line (GNU): "00001000 <P$PROGRAM$ARM64TRAP>:"
        m = LABEL_RE.match(line)
        if m:
            addr = int(m.group(1), 16)
            sym = m.group(2).strip()
            labels[addr] = sym
            symbol_to_addr[sym] = addr
            i += 1
            continue
        # Instruction line: "  addr:  bytes  inst"
        m = ADDR_RE.match(line)
        if m:
            addr = int(m.group(1), 16)
            # Rest of line after optional bytes (up to 2 hex words) is instruction
            rest = line[m.end() :].strip()
            # Drop leading hex bytes (GNU: "d63f0340  bl ..."  LLVM: "d63f0340    bl ...")
            parts = rest.split()
            inst_parts = []
            for p in parts:
                if re.match(r"^[0-9a-fA-F]{8}$", p):
                    continue
                inst_parts.append(p)
            inst = " ".join(inst_parts) if inst_parts else rest
            addrs.append((addr, inst))
            addr_to_inst[addr] = inst
            if "bl" in inst and DEED_SYMBOL.search(inst):
                deed_addrs.add(addr)
            i += 1
            continue
        i += 1

    return addrs, addr_to_inst, labels, symbol_to_addr, deed_addrs


def resolve_branch_target(inst, addr_to_inst, symbol_to_addr, current_addr):
    """Return (target_addr, is_call, is_ret) or (None, False, False)."""
    if RET_RE.search(inst):
        return (None, False, True)
    # bl target
    m = re.search(r"\bbl\s+(?:0x)?([0-9a-fA-F]+)", inst, re.I)
    if m:
        return (int(m.group(1), 16), True, False)
    m = re.search(r"\bbl\s+([^<\s]+)", inst, re.I)
    if m:
        sym = m.group(1).strip("<>")
        if sym in symbol_to_addr:
            return (symbol_to_addr[sym], True, False)
        return (None, True, False)
    # b target (unconditional)
    m = re.search(r"\bb\s+(?:0x)?([0-9a-fA-F]+)", inst, re.I)
    if m:
        return (int(m.group(1), 16), False, False)
    m = re.search(r"\bb\s+\.?([A-Za-z0-9_$.]+)", inst, re.I)
    if m:
        sym = m.group(1).strip()
        if sym in symbol_to_addr:
            return (symbol_to_addr[sym], False, False)
        # Local label like .L123 - might be in labels by address; we don't have numeric target here
        return (None, False, False)
    return (None, False, False)


def trace_to_deed(entry_addr, addrs, addr_to_inst, labels, symbol_to_addr, deed_addrs, max_steps=50000):
    """
    Trace control flow from entry_addr. Follow b/bl/ret; count steps.
    Return (reached_deed_addr, steps) or (None, steps).
    """
    if not addrs:
        return None, 0
    # Build sorted list of addresses for "next sequential" (ARM64: 4-byte instructions)
    sorted_addrs = sorted(addr_to_inst.keys())

    def next_seq(addr):
        if addr in sorted_addrs:
            idx = sorted_addrs.index(addr)
            if idx + 1 < len(sorted_addrs):
                return sorted_addrs[idx + 1]
        return addr + 4

    stack = []
    pc = entry_addr
    steps = 0
    visited = set()

    while steps < max_steps:
        if pc in deed_addrs:
            return pc, steps
        if pc in visited:
            # Loop without hitting deed
            break
        visited.add(pc)

        inst = addr_to_inst.get(pc)
        if not inst:
            # Fall through to next (might be gap)
            pc = next_seq(pc)
            steps += 1
            continue

        target, is_call, is_ret = resolve_branch_target(inst, addr_to_inst, symbol_to_addr, pc)
        if is_ret:
            if stack:
                pc = stack.pop()
            else:
                break
            steps += 1
            continue
        if target is not None and (is_call or "b " in inst or "b\t" in inst):
            # Skip following calls into code we don't have (external / missing); step over so we reach deed.
            if is_call and target not in addr_to_inst:
                pc = next_seq(pc)
                steps += 1
                continue
            if is_call:
                stack.append(next_seq(pc))
            pc = target
            steps += 1
            continue
        pc = next_seq(pc)
        steps += 1

    return None, steps


def main():
    import argparse
    p = argparse.ArgumentParser(description="Walk ARM64 PE disassembly to find try/finally deed.")
    p.add_argument("exe", nargs="?", help="Path to .exe (ARM64 Windows PE)")
    p.add_argument("objdump", nargs="?", default=os.environ.get("OBJDUMP", ""),
                    help="objdump binary (default: OBJDUMP env or aarch64-w64-mingw32-objdump)")
    p.add_argument("--disasm", metavar="FILE", help="Use existing disasm file instead of running objdump")
    p.add_argument("--max-steps", type=int, default=50000, help="Max trace steps (default 50000)")
    p.add_argument("-v", "--verbose", action="store_true", help="Print details to stderr")
    args = p.parse_args()

    if args.disasm:
        if not os.path.isfile(args.disasm):
            print("DEED_ERROR: disasm file not found", args.disasm, file=sys.stderr)
            sys.exit(2)
        with open(args.disasm, "r") as f:
            lines = f.read().splitlines()
        if args.verbose:
            print("Parsing disasm from", args.disasm, file=sys.stderr)
    elif args.exe:
        if not os.path.isfile(args.exe):
            print("DEED_ERROR: exe not found", args.exe, file=sys.stderr)
            sys.exit(2)
        objdump = args.objdump or "aarch64-w64-mingw32-objdump"
        if not args.objdump and os.environ.get("PATH"):
            for name in ["aarch64-w64-mingw32-objdump", "llvm-objdump"]:
                for d in os.environ["PATH"].split(os.pathsep):
                    if os.path.isfile(os.path.join(d, name)):
                        objdump = os.path.join(d, name)
                        break
        lines = run_objdump(objdump, args.exe)
        if lines is None:
            print("DEED_ERROR: objdump failed (run with OBJDUMP=... or install llvm-mingw)", file=sys.stderr)
            sys.exit(2)
        if args.verbose:
            print("Disassembled with", objdump, file=sys.stderr)
    else:
        p.print_help()
        sys.exit(2)

    addrs, addr_to_inst, labels, symbol_to_addr, deed_addrs = parse_disassembly(lines)
    if not addrs:
        print("NO_DISASM: no instructions parsed", file=sys.stderr)
        print("NO_DEED")
        sys.exit(1)

    entry_addr = addrs[0][0]
    reached, steps = trace_to_deed(
        entry_addr, addrs, addr_to_inst, labels, symbol_to_addr, deed_addrs, max_steps=args.max_steps
    )

    fix_present = len(deed_addrs) > 0
    if args.verbose:
        print("Entry", hex(entry_addr), "Deed addrs", [hex(a) for a in deed_addrs], "Steps", steps, file=sys.stderr)

    if fix_present:
        print("FIX_PRESENT")
    if reached is not None:
        print("DEED_REACHED", hex(reached), "steps", steps)
        sys.exit(0)
    if fix_present:
        print("DEED_NOT_REACHED", "steps", steps, file=sys.stderr)
        sys.exit(0)  # fix present but trace didn't reach (maybe indirect call)
    print("NO_DEED")
    sys.exit(1)


if __name__ == "__main__":
    main()
