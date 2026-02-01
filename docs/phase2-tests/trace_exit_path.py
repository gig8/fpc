#!/usr/bin/env python3
"""
Trace the EXIT path from try...finally+exit: from bl _FPC_local_unwind through
epilogue, ret to main, and main's continuation. Use this to follow the code
locally without running on Windows ARM64.

Usage:
  trace_exit_path.py arm64trap.s
  trace_exit_path.py arm64trap.s -o exit_path_annotated.txt

Output: Annotated exit path with comments for each step. The failure (exit
code 1, no "Done.") happens somewhere on this path after RtlUnwindEx returns
control to .Lj3.
"""

import re
import sys
import argparse

def parse_s(path):
    """Parse .s file, return (lines, line_numbers, labels_to_line)."""
    with open(path, 'r') as f:
        lines = f.read().splitlines()
    labels = {}  # label -> line index (0-based)
    for i, line in enumerate(lines):
        m = re.match(r'^([.]?[A-Za-z0-9_$.]+)\s*:\s*', line)
        if m:
            labels[m.group(1).rstrip(':')] = i
    return lines, labels

def find_deed(lines, labels):
    """Find bl _FPC_local_unwind and the target (x1 = .Lj3). Return (deed_line_idx, target_label)."""
    deed_idx = None
    target_label = None
    for i, line in enumerate(lines):
        if 'bl' in line and '_FPC_local_unwind' in line:
            deed_idx = i
            # Target is in x1 - look back for adrp/add x1,<label>
            for j in range(i - 1, max(-1, i - 5), -1):
                m = re.search(r'adrp\s+x1,([.\w]+)|add\s+x1,x1,[^,]+\s*/\s*:lo12:([.\w]+)', lines[j])
                if m:
                    target_label = (m.group(1) or m.group(2)).strip()
                    break
            break
    return deed_idx, target_label

def find_label_lines(lines, labels, target_label):
    """Return list of (line_idx, line) from target_label to next ret (inclusive)."""
    if target_label not in labels:
        return []
    start = labels[target_label]
    result = []
    for i in range(start, min(len(lines), start + 20)):
        result.append((i, lines[i]))
        if re.search(r'\bret\b', lines[i]):
            break
    return result

def find_main_after_call(lines, labels, proc_name='PASCALMAIN'):
    """Find main and the code after bl P$ARM64TRAP_$$_TESTEXCEPTION (return point)."""
    if proc_name not in labels:
        return []
    start = labels[proc_name]
    # Find bl P$ARM64TRAP_$$_TESTEXCEPTION
    call_idx = None
    for i in range(start, min(len(lines), start + 30)):
        if 'bl' in lines[i] and 'P$ARM64TRAP_$$_TESTEXCEPTION' in lines[i]:
            call_idx = i
            break
    if call_idx is None:
        return []
    # Return point is the next instruction
    result = []
    for i in range(call_idx + 1, min(len(lines), call_idx + 80)):
        result.append((i, lines[i]))
        # Stop at next procedure or end of main's logic (fpc_do_exit)
        if re.search(r'^\s*\.section\s', lines[i]) or 'fpc_do_exit' in lines[i]:
            if 'fpc_do_exit' in lines[i]:
                result.append((i + 1, lines[i + 1]) if i + 1 < len(lines) else (i, ''))
            break
    return result

def main():
    p = argparse.ArgumentParser(description="Trace exit path from try/finally in .s file")
    p.add_argument("asm_file", help="Path to .s file (e.g. arm64trap.s)")
    p.add_argument("-o", "--output", help="Write annotated output to file")
    p.add_argument("-v", "--verbose", action="store_true")
    args = p.parse_args()

    lines, labels = parse_s(args.asm_file)
    deed_idx, target_label = find_deed(lines, labels)
    if deed_idx is None:
        print("ERROR: bl _FPC_local_unwind not found", file=sys.stderr)
        sys.exit(2)
    if target_label is None:
        target_label = ".Lj3"  # default
    if args.verbose:
        print(f"Deed at line {deed_idx + 1}, target={target_label}", file=sys.stderr)

    out_lines = []
    out_lines.append("=== EXIT PATH TRACE (try...finally+exit) ===\n")
    out_lines.append("Failure: process exits with code 1 before 'Done.' - somewhere on this path.\n")
    out_lines.append("")

    # 1. The deed (bl _FPC_local_unwind)
    out_lines.append("--- 1. DEED: bl _FPC_local_unwind ---")
    for j in range(max(0, deed_idx - 3), min(len(lines), deed_idx + 2)):
        prefix = ">>> " if j == deed_idx else "    "
        out_lines.append(f"{prefix}{j + 1:4d}: {lines[j]}")
    out_lines.append("    ^ x0=frame(sp), x1=target(.Lj3). RtlUnwindEx runs finally handler, then transfers to target.")
    out_lines.append("")

    # 2. Target: .Lj3 epilogue
    epilogue = find_label_lines(lines, labels, target_label)
    out_lines.append(f"--- 2. TARGET ({target_label}): Epilogue (after RtlUnwindEx transfers here) ---")
    for idx, line in epilogue:
        out_lines.append(f"    {idx + 1:4d}: {line}")
    out_lines.append("    ^ Restores x19, sp, x29, x30. RET returns to main (caller of TestException).")
    out_lines.append("    ^ If x29/x30 or stack are wrong when we land here, ret goes to wrong place.")
    out_lines.append("")

    # 3. Main's continuation (after bl P$ARM64TRAP_$$_TESTEXCEPTION returns)
    main_after = find_main_after_call(lines, labels)
    out_lines.append("--- 3. MAIN: After TestException returns ---")
    for idx, line in main_after:
        annot = ""
        if "Ld3" in line or "Back in main" in str(lines[idx:idx+1]):
            annot = "  <- writeln('Back in main.')"
        elif "Ld4" in line:
            annot = "  <- writeln('Done.')"
        elif "FLUSH" in line:
            annot = "  <- Flush(Output)"
        elif "fpc_do_exit" in line:
            annot = "  <- fpc_do_exit (normal shutdown)"
        out_lines.append(f"    {idx + 1:4d}: {line}{annot}")
    out_lines.append("")
    out_lines.append("--- END ---")
    out_lines.append("")
    out_lines.append("Check: When we land at .Lj3, is sp/x29/x30 correct? Does ret reach main?")
    out_lines.append("Check: Does main reach writeln('Back in main.')? Flush? writeln('Done.')?")
    out_lines.append("CI shows: 'Success: Finally block executed!' then exit 1 - so failure is after epilogue ret.")

    output = "\n".join(out_lines)
    if args.output:
        with open(args.output, 'w') as f:
            f.write(output)
        print(f"Wrote {args.output}", file=sys.stderr)
    else:
        print(output)

if __name__ == "__main__":
    main()
