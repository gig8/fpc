# Plan: Free Pascal Windows aarch64 bounty

## Current status

- **Branch:** `feature/win-aarch64` (off `develop`).
- **Cross-compiler:** `make crossinstall` successfully builds `ppcrossa64` (the aarch64-win64 cross-compiler binary).
- **Failure:** RTL build fails in `rtl/win64` with:
  ```text
  ppcrossa64 ... -ClvLLVM -FD/opt/llvm-mingw/bin ... system.pp
  Error: Illegal parameter: -ClvLLVM
  ```

## Root cause: `-ClvLLVM` does not exist

Searched the FPC trunk codebase:

- **No** `ClvLLVM` or `clvllvm` in the repo.
- **No** `-Cl` option that takes `vLLVM` as a value.
- AArch64-win64 **default assembler** is already **clang** (`as_clang_gas` in `compiler/systems/i_win.pas` and `compiler/aarch64/agcpugas.pas`). So we do **not** need an extra option to “enable” LLVM/clang for this target.
- The `{$ifdef llvm}` path in `options.pas` (e.g. `as_clang_llvm`) is for the **LLVM code-generation** backend (different from “use clang as assembler”). AArch64 in FPC uses its own code generator and calls **clang** as the external assembler; that is controlled by the target’s `assem`/`assemextern`, not by `-ClvLLVM`.

**Conclusion:** Remove `-ClvLLVM` from all build commands. Use only:

- `BINUTILSPREFIX=aarch64-w64-mingw32-` so the compiler invokes `aarch64-w64-mingw32-clang` (and linker) from llvm-mingw.
- `CROSSOPT="-FD/opt/llvm-mingw/bin"` so the compiler finds those binaries.

## Immediate next steps

1. **Re-run crossinstall without `-ClvLLVM`:**
   ```bash
   make clean
   make crossinstall -j$(nproc) \
     CPU_TARGET=aarch64 \
     OS_TARGET=win64 \
     FPC=/usr/bin/fpc \
     BINUTILSPREFIX=aarch64-w64-mingw32- \
     CROSSOPT="-FD/opt/llvm-mingw/bin" \
     INSTALL_PREFIX=~/Projects/gig8/fpc_install
   ```

2. **If it still fails:** Capture the **exact** error (e.g. missing symbol, asm/link error, wrong triple). Then:
   - Adjust `CROSSOPT` or RTL/win64 make logic only if needed.
   - Do **not** re-add `-ClvLLVM`.

3. **If RTL builds:** 
   - Install from `INSTALL_PREFIX` and test compile a small program, e.g.:
     ```bash
     ~/Projects/gig8/fpc_install/bin/ppcrossa64 -Twin64 -Ful/.../units/aarch64-win64 -FE/tmp /tmp/hello.pas
     ```
   - Then try an “exception trap” (try/except) and inspect generated `.s` and PE unwind info (see gemini-conversation-summary.md).

## Longer-term plan (bounty)

1. **Stable cross-build in WSL:** Cross-compiler + RTL for aarch64-win64 using llvm-mingw, no invalid options.
2. **Fix SEH/unwind:** Get try/except and try/finally (and Exit/Break/Continue in try/finally) working; align with Microsoft ARM64 PCS and existing MRs (e.g. local unwind).
3. **Self-hosting:** Build FPC with the cross-compiler → native `fpc.exe`; run `make cycle` on Windows arm64 (real hardware or CI).
4. **Lazarus:** Ensure the toolchain can build Lazarus and that shell extensions (pure arm64) load in Explorer.
5. **Upstream:** Prepare patches/PR for FPC trunk; add sponsor comment/link in modified units as required by the bounty.

## Reference: FPC source locations (aarch64 / win64)

| Area            | Path / files |
|-----------------|--------------|
| Target config   | `compiler/systems/i_win.pas` (aarch64_win64 → as_clang_gas) |
| AArch64 asm     | `compiler/aarch64/agcpugas.pas` (as_aarch64_clang_gas_info, as_aarch64_win64_gas_info) |
| Unwind / .pdata | `compiler/aarch64/cgobj.pas` (e.g. WriteUnwindInfo) |
| RTL win64       | `rtl/win64/`, `rtl/win/` |

## WSL setup (quick reference)

- llvm-mingw: e.g. 20251216, extract to `/opt/llvm-mingw`, `PATH=/opt/llvm-mingw/bin:$PATH`.
- Check: `aarch64-w64-mingw32-clang --version` → `Target: aarch64-w64-windows-gnu`.
- Host FPC: `sudo apt install fpc` (3.2.2).
- Build from FPC source dir (e.g. `~/Projects/gig8/fpc`), not from `/mnt/c/`.
