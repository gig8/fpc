# Phase 2 tests – aarch64-win64 validation

After the cross-build (Phase 1), use these to validate binaries and SEH.

## Prerequisites

- `ppcrossa64` built (e.g. `/home/tim/Projects/gig8/fpc/compiler/ppcrossa64`)
- Units installed (e.g. `.../fpc_install/lib/fpc/3.3.1/units/aarch64-win64`)
- llvm-mingw in PATH: `export PATH=/opt/llvm-mingw/bin:$PATH`
- **Important:** Use `-XPaarch64-w64-mingw32-` so the compiler finds `aarch64-w64-mingw32-clang` (not `aarch64-win64-clang`)

## Commands

```bash
cd docs/phase2-tests
PPC=/path/to/ppcrossa64
UP=/path/to/fpc_install/lib/fpc/3.3.1/units/aarch64-win64
export PATH=/opt/llvm-mingw/bin:$PATH

# Hello world
"$PPC" -Twin64 -XPaarch64-w64-mingw32- -Fu"$UP/rtl" -Fu"$UP/rtl-objpas" -FE. -FD/opt/llvm-mingw/bin -ohello.exe hello.pas

# Verify PE is arm64
aarch64-w64-mingw32-objdump -p hello.exe
# Expect: "file format coff-arm64"

# Exception trap (try/except)
"$PPC" -Twin64 -XPaarch64-w64-mingw32- -Fu"$UP/rtl" -Fu"$UP/rtl-objpas" -FE. -FD/opt/llvm-mingw/bin -otrap.exe trap.pas

# Emit assembly for SEH inspection
"$PPC" -Twin64 -XPaarch64-w64-mingw32- -Fu"$UP/rtl" -Fu"$UP/rtl-objpas" -FE. -FD/opt/llvm-mingw/bin -a trap.pas
# Then inspect trap.s for .pdata, .xdata, unwind, __FPC_specific_handler
```

## Phase 2 results (this run)

- **hello.exe:** Built; `objdump -p` shows `file format coff-arm64` (pure arm64).
- **trap.exe:** Built; `trap.s` contains `.pdata` and `.xdata` with unwind info; `main` has `__FPC_specific_handler` and exception handler table.
- **Runtime:** Run `hello.exe` and `trap.exe` on Windows arm64 (or QEMU/CI) to confirm trap prints "Caught: The Unwind Trap".
