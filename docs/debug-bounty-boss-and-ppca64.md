# Debugging Bounty Boss and ppca64 exit failures

Use these flags and steps to pinpoint where try...finally+exit or ppca64 exit fails.

**Note (Jan 2026):** We run both Bounty Boss and Verify ppca64 in CI without failing on the first failure; we fail at the end if either failed so we can see both results and test whether they’re related (same SEH/unwind path). See **docs/next-steps-detailed.md** § “CI: run both Bounty Boss and ppca64, then fail if either failed”.

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

---

## Assembly patterns: which version was compiled?

When you compile with **-a**, the compiler writes a `.s` (assembly) file. You can grep it to confirm whether the **fix** (call to `_FPC_local_unwind`) or the **no-fix** (plain branch) was emitted.

| Version | Executable / .s | What to look for |
|--------|------------------|------------------|
| **With fix** | `arm64trap.exe` / `arm64trap.s` | A **call** to `_FPC_local_unwind`. |
| **Without fix** | `arm64trap_no_fix.exe` / `arm64trap_no_fix.s` | **No** reference to `_FPC_local_unwind`; instead a direct **branch** to the finally label. |

### Patterns to search for

- **Fix was compiled in (expected in `arm64trap.s`):**
  - `_FPC_local_unwind` or `_FPC_LOCAL_UNWIND` (symbol reference).
  - `bl _FPC_local_unwind` or `bl _FPC_LOCAL_UNWIND` (AArch64 call = branch with link).

- **No-fix was compiled in (expected in `arm64trap_no_fix.s`):**
  - **Absence** of `_FPC_local_unwind` in the try/finally path.
  - A direct **branch** to a local label (e.g. `b .L123` or `b .L$test$...`) instead of a call.

Example (Linux or CI):

```bash
# Fix version: expect at least one match
grep -n '_FPC_local_unwind\|_FPC_LOCAL_UNWIND\|bl.*local_unwind' arm64trap.s

# No-fix version: expect no match
grep -n '_FPC_local_unwind\|_FPC_LOCAL_UNWIND' arm64trap_no_fix.s
```

CI runs these checks in the "Verify assembly patterns (Bounty Boss fix vs no-fix)" step and reports in the log. The artifact includes both `.exe` and `.s` files so you can re-check locally.

---

## Optimization flags (-O1, -O2, -O3, -Os)

Optimization can change code layout (stack frame, branches, tail calls) and might affect SEH/unwind or the try...finally path. **CI currently uses the default: no `-O`**, so `optimizerswitches = []` (no optimizer switches).

### Flags to check

| Flag | Effect (aarch64) |
|------|------------------|
| **(default, no -O)** | No optimizer switches. This is what CI uses. |
| **-O1** | Level 1 (generic). |
| **-O2** | Level 2: adds e.g. `cs_opt_stackframe`, `cs_opt_tailrecursion`, `cs_opt_nodecse`, `cs_opt_consts`. Stack frame and tail-call optimizations can change stack layout and control flow. |
| **-O3** | Level 3: more aggressive (includes level 2). Peephole optimizations (e.g. in `compiler/aarch64/aoptcpu.pas`, branch opts) run. |
| **-O4** | Level 4: even more. |
| **-Os** | Optimize for size (`cs_opt_size`). Used in aarch64 for e.g. concatcopy and division; not in the try/finally path. |

The try...finally code path (`g_local_unwind` in `ncpuflw.pas` / `cgcpu.pas`) does **not** check optimization flags; it always emits either the call to `_FPC_local_unwind` or the plain branch. So the **same** high-level code is generated. What can change with `-O2`/`-O3` is:

- **Peephole** (aoptcpu): branch and instruction reordering (e.g. `OptPass1B`, `OptPass2B`).
- **Stack frame** (`cs_opt_stackframe`): omitting frame pointer can affect unwinder expectations.
- **Tail recursion** (`cs_opt_tailrecursion`): can change call/return pattern.

If the bug appears only with **-O2** or **-O3**, an optimizer is a likely suspect. If it appears with **default** and also with **-O1**, the cause is probably not optimization-level-specific.

### How to test

```bash
# Default (same as CI)
ppcrossa64 -Twin64 ... -oarm64trap.exe arm64trap.pas

# With optimization – compare behaviour
ppcrossa64 -Twin64 -O2 ... -oarm64trap_O2.exe arm64trap.pas
ppcrossa64 -Twin64 -O3 ... -oarm64trap_O3.exe arm64trap.pas
```

Run each on Windows arm64 and compare: does Bounty Boss or ppca64 exit failure depend on `-O`? If yes, bisect with `-O1` vs `-O2` to see which level introduces the problem; then check aarch64’s level2/level3 switches and peephole (aoptcpu) for that target.
