#!/bin/bash
# Local diagnosis for arm64trap try/finally unwind.
# Run from tests/phase2-tests with llvm-mingw in PATH.
# Use -g -gl to build with symbols (no strip) so objdump shows symbol names.

set -e
D="$(dirname "$0")"
cd "$D"
PPC="$(cd ../.. && pwd)/compiler/ppcrossa64"
LLVM_BIN="${LLVM_BIN:-/opt/llvm-mingw/bin}"
export PATH="$LLVM_BIN:$PATH"

echo "=== 1. Compile arm64trap (-a keeps .s, -g -gl keeps symbols for static analysis) ==="
"$PPC" -Twin64 -XPaarch64-w64-mingw32- \
  -Fu../../rtl/units/aarch64-win64 -Fu../../rtl/objpas/units/aarch64-win64 \
  -FE. -FD"$LLVM_BIN" -a -g -gl -oarm64trap.exe arm64trap.pas

echo ""
echo "=== 2. Assembly: bl _FPC_local_unwind and target ==="
grep -n -A1 -B3 "bl.*_FPC_local_unwind" arm64trap.s || true

echo ""
echo "=== 3. Target label .Lj32 (from adrp x1,.Lj32) ==="
grep -n "\.Lj32:" arm64trap.s
echo "Code at target:"
awk '/^\.Lj32:/{p=1} p{print; if(/ret$/){exit}}' arm64trap.s

echo ""
echo "=== 4. Disassemble (GNU objdump) ==="
mkdir -p arm64-exes
aarch64-w64-mingw32-objdump -d -C arm64trap.exe > arm64-exes/arm64trap_disasm.txt 2>/dev/null || true
echo "Symbols in disasm:"
grep -c "<" arm64-exes/arm64trap_disasm.txt 2>/dev/null || echo "0"
echo "bl instructions: $(grep -c '\bbl\b' arm64-exes/arm64trap_disasm.txt 2>/dev/null || echo 0)"
echo "_FPC_local_unwind in disasm: $(grep -c 'local_unwind' arm64-exes/arm64trap_disasm.txt 2>/dev/null || echo 0)"

echo ""
echo "=== 5. Analyze from assembly source (.s has symbols) ==="
python3 analyze_from_asm.py arm64trap.s 2>&1 || true

echo ""
echo "=== 6. Python scripts on disasm (stripped binary = no symbols) ==="
python3 extract_unwind_target.py --disasm arm64-exes/arm64trap_disasm.txt 2>&1 || true
python3 walk_arm64_pe.py --disasm arm64-exes/arm64trap_disasm.txt -v 2>&1 || true

echo ""
echo "=== Summary ==="
if grep -q "local_unwind" arm64-exes/arm64trap_disasm.txt 2>/dev/null; then
  echo "Build has symbols (-g -gl). Objdump shows _FPC_local_unwind. Python scripts work."
else
  echo "Binary stripped. Use -g -gl when compiling to keep symbols for static analysis."
  echo "Or use analyze_from_asm.py on .s for deed/target."
fi
