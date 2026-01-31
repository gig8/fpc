# Gemini conversation summary – Windows aarch64 bounty

Summary of the Project Triage and Strategy session with Gemini, for the Free Pascal Windows arm64 bug bounty.

## Goal (aligned with bounty)

1. **Phase 1 (WSL lab):** Use Linux (WSL) + cross-toolchain (llvm-mingw aarch64) to build a **cross-compiler** that produces Windows arm64 `.exe`/`.dll` (PE/COFF), not Linux ELF.
2. **Phase 2 (bridge):** Use that cross-compiler to compile FPC source into a **native** `fpc.exe` for Windows arm64.
3. **Phase 3 (cycle):** On a real Windows arm64 machine, run `make cycle` so the arm64 compiler compiles itself. If that succeeds, the compiler is **self-hosting**.

Validation: Lazarus must compile; toolchain must work for rebuilding projects; changes must be accepted into FPC trunk. Target is **pure arm64** (not arm64ec).

## WSL vs native Windows

- **WSL:** Fine for building the cross-compiler and RTL. Must set **target** to `win64` + `aarch64` so output is Windows PE/COFF, not Linux ELF.
- **Testing:** Shell extensions and “cycle” must be tested on real Windows arm64 (or QEMU / GitHub Actions arm64 runners). x86_64 Windows cannot run arm64 binaries.

## Toolchain (WSL)

- **llvm-mingw** (not GCC MinGW) for Windows arm64: better PE/COFF and SEH support.
- Use **stable** llvm-mingw, e.g. **20251216** (LLVM 21.1.8), not RC/bleeding-edge, to avoid mixing FPC bugs with toolchain changes.
- Install host FPC: `sudo apt install fpc` (e.g. 3.2.2).
- Clone FPC **main** (trunk); aarch64-win64 and SEH work is on main, not fixes_3_2.
- **Branch:** Work on `main` (or our `feature/win-aarch64` off develop).

## Build commands (and current failure)

- **Wrong:** Passing `-ClvLLVM` in OPT or CROSSOPT. **That option does not exist in FPC trunk** (see plan doc). Both the host compiler (3.2.2) and the built `ppcrossa64` reject it.
- **Right:** Rely on the default aarch64-win64 assembler (`as_clang_gas`) and only point the compiler at the llvm-mingw bin dir with `-FD` (and set `BINUTILSPREFIX` so it uses the right `clang`/`ld`).

Correct crossinstall (no `-ClvLLVM`):

```bash
make crossinstall -j$(nproc) \
  CPU_TARGET=aarch64 \
  OS_TARGET=win64 \
  FPC=/usr/bin/fpc \
  BINUTILSPREFIX=aarch64-w64-mingw32- \
  CROSSOPT="-FD/opt/llvm-mingw/bin" \
  INSTALL_PREFIX=~/Projects/gig8/fpc_install
```

## Known technical issues (from Gemini / community)

- **SEH (Structured Exception Handling):** Primary reason “cycle” fails. Windows arm64 uses `.pdata`/unwind info; incorrect unwind data → crash on exceptions. Bug report #66952; recent MR (Jan 2026) for “local unwind” (try/finally Exit/Break/Continue).
- **Key files for SEH/unwind:** `compiler/aarch64/cgobj.pas` (e.g. `WriteUnwindInfo`), plus opcodes/asm in `aarch64ins.pas`, `nagcpu.pas`.
- **Verification:** `aarch64-w64-mingw32-objdump -p my_test.exe | grep "Machine"` should show `0xaa64` (ARM64), not `0x8664` (x64).

## Proving it without arm64 hardware

- **QEMU:** Windows 11 arm64 VM on x86_64 host (slow but valid).
- **GitHub Actions:** Windows arm64 runners for CI and “cycle” proof.
- **Static checks:** `objdump`/`dumpbin` on PE and `.pdata` to check against Microsoft ARM64 PCS/SEH.

## Build time (WSL)

- Full cycle build: on the order of 10–15 minutes; RTL/crossinstall typically less. Keep FPC source on WSL filesystem (e.g. `~/Projects/gig8/fpc`), not `/mnt/c/`, for faster builds.

## Next steps (see plan)

- Drop `-ClvLLVM` from all build commands.
- Run the corrected `make crossinstall` and capture any new errors.
- If RTL builds, compile a small “exception trap” program and inspect generated `.s` / unwind info; compare with Microsoft ARM64 SEH and with clang-generated code.
