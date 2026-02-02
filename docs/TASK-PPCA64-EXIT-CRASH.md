# Task: Fix ppca64.exe EExternalException loop on Windows ARM64

## Problem

Running `ppca64.exe -iV` on Windows ARM64 crashes with an unhandled exception that loops:

```
An unhandled exception occurred at $00007FF763522368:
EExternalException: 
  $00007FF763522368
  $00007FF763530E94
  $00007FF763530F10
```

- The version is printed before the crash (failure happens in the process exit path).
- EExternalException indicates an unrecognized Windows exception code; the RTL raises it when it doesn't map the code in `rtl/win/sysutils.pp` (FindExceptMapEntry).
- The same addresses repeat in a loop, suggesting the exception handler re-raises or the process restarts.

## Repo context

- **Branch:** `win-aarch64-ppca64`
- **Repo:** https://github.com/gig8/fpc
- **CI:** `.github/workflows/win-arm64.yml` — workflow "Windows arm64" runs on `windows-11-arm`; the step "Run ppca64.exe -iV (native ARM64 compiler test)" runs the test with a 30s timeout and uploads output to the `ppca64-output` artifact.
- **GitHub Actions:** https://github.com/gig8/fpc/actions (select workflow "Windows arm64")
- **Example run (timeout + EExternalException):** https://github.com/gig8/fpc/actions/runs/21595342152/job/62226815709

## Root cause direction

1. **Get the actual exception code:** Rebuild the RTL with `-dFPC_DEBUG_EXIT_EXCEPTION` so the RTL logs the Windows exception code and address to stderr before raising EExternalException. Then add that code to the exception map in `rtl/win/sysutils.pp` or handle it in the default handler (`rtl/win64/seh64.inc`).
2. **Inspect the call stack:** Use `aarch64-w64-mingw32-objdump -d ppca64.exe` (or WinDbg on Windows ARM64) to map addresses `$00007FF763522368`, `$00007FF763530E94`, `$00007FF763530F10` to symbols.

## Debug workflow

- See **docs/debug-bounty-boss-and-ppca64.md** for RTL rebuild steps, FPC_DEBUG_* defines, and disassembly.
- Bounty Boss (try...finally+exit) is already fixed; the ADRP/ADR linker fix is in `compiler/ogcoff.pas`. This task is specifically for ppca64 exit.
