# Debugging Bounty Boss and ppca64 exit failures

Use these flags and steps to pinpoint where try...finally+exit or ppca64 exit fails.

---

## Compiler flags (for the program you compile, e.g. arm64trap.pas)

| Flag | Effect |
|------|--------|
| **-dFPC_NO_WIN64_LOCAL_UNWIND** | Turn **off** the try...finally+exit fix: emit a plain jump to the finally block instead of calling _FPC_local_unwind. Use this to build a "no fix" version and compare with the "fix" version (default). |
| (default) | Emit call to _FPC_local_unwind (RtlUnwindEx) for try...finally+exit on aarch64-win64. |

Example:
```bash
# With fix (default)
ppcrossa64 -Twin64 ... docs/phase2-tests/arm64trap.pas

# Without fix (old behaviour)
ppcrossa64 -Twin64 -dFPC_NO_WIN64_LOCAL_UNWIND ... docs/phase2-tests/arm64trap.pas
```

---

## RTL debug defines (rebuild RTL with these to get debug output)

| Define | Effect |
|--------|--------|
| **FPC_DEBUG_WIN64_UNWIND** | In rtl/win64/seh64.inc: log ENTER/EXIT of _fpc_local_unwind to stderr (frame and target addresses). Rebuild system unit with -dFPC_DEBUG_WIN64_UNWIND so arm64trap.exe (or ppca64) prints when unwind is entered and when it returns. |
| **FPC_DEBUG_EXIT_EXCEPTION** | In rtl/win/sysutils.pp: when creating EExternalException (unrecognized Windows exception code), log code and exception address to stderr. Rebuild with -dFPC_DEBUG_EXIT_EXCEPTION to see the exact code when ppca64 hits EExternalException on exit. |

Example (rebuild RTL and then compile your test):
```bash
# Rebuild RTL with unwind debug (in FPC source tree)
make -C rtl clean
make -C rtl install FPC=compiler/ppcrossa64 OS_TARGET=win64 CPU_TARGET=aarch64 \
  CROSSOPT="-dFPC_DEBUG_WIN64_UNWIND -dFPC_DEBUG_EXIT_EXCEPTION" \
  BINUTILSPREFIX=aarch64-w64-mingw32- OPT="-FD/path/to/llvm-mingw/bin" \
  INSTALL_PREFIX=/path/to/install

# Then compile arm64trap with the new RTL
ppcrossa64 -Twin64 -Fu/path/to/install/.../units/aarch64-win64 ...
```

---

## Disassembly and debugger

- **Disassembly:** Compile with **-a** to get `.s` (e.g. `ppcrossa64 ... -a -oarm64trap.exe arm64trap.pas`). Inspect the try/finally region: look for call to _FPC_local_unwind vs a plain branch, and for `.seh_*` directives.
- **Windows arm64 debugger:** On a Windows arm64 machine (or VM), run the exe under **WinDbg** (ARM64) or **Visual Studio** (native ARM64 debugging). Set a breakpoint on `_FPC_local_unwind` or on the return from RtlUnwindEx to see exactly where execution goes after the unwind.
- **EExternalException on ppca64 exit:** The failure happens after the version is printed; run `ppca64.exe -iV` under the debugger and continue until the exception. With FPC_DEBUG_EXIT_EXCEPTION the RTL will log the exception code and address to stderr before raising, which helps even without a debugger.

---

## System.Management.RemoteException (PowerShell) and ppca64

When PowerShell runs `.\ppca64.exe -iV` and ppca64 raises EExternalException on exit, PowerShell surfaces it as `System.Management.Automation.RemoteException`. The **real** failure is inside ppca64 (unrecognized Windows exception code during shutdown). Use FPC_DEBUG_EXIT_EXCEPTION when rebuilding the RTL to see the exception code and address; then check whether that code should be added to the RTL's exception map in rtl/win/sysutils.pp (FindExceptMapEntry).

---

## Spinning up test versions

1. **With fix (default):** `ppcrossa64 ... arm64trap.pas` → arm64trap.exe (calls _FPC_local_unwind).
2. **Without fix:** `ppcrossa64 -dFPC_NO_WIN64_LOCAL_UNWIND ... arm64trap.pas` → arm64trap_no_fix.exe.
3. **RTL debug:** Rebuild RTL with -dFPC_DEBUG_WIN64_UNWIND and -dFPC_DEBUG_EXIT_EXCEPTION; build arm64trap and ppca64 with that RTL; run and capture stderr.

Compare behaviour (output, crash point) between 1 and 2 to confirm whether the failure is in the unwind path or elsewhere. Use 3 to get the exact moment and exception code.
