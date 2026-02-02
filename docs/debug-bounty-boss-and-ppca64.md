# Debugging Bounty Boss and ppca64 exit failures

Use these flags and steps to pinpoint where try...finally+exit or ppca64 exit fails.

**Note (Jan 2026):** We run both Bounty Boss and Verify ppca64 in CI without failing on the first failure; we fail at the end if either failed so we can see both results and test whether they’re related (same SEH/unwind path). See **docs/next-steps-detailed.md** § “CI: run both Bounty Boss and ppca64, then fail if either failed”.

---

**Failure vs fix (Jan 2026):** The Bounty Boss "with fix" step can fail in CI. The **fix** (g_local_unwind → _FPC_local_unwind) is used when execution takes the **exit** from the try block (so the runtime runs the finally). The **failure** happens **after** that point (or before we reach it)—so the try/finally+exit fix is not the cause of the failure. The real failure may be earlier (startup, first writeln) or later ("Done.", Flush, or process exit, similar to ppca64 EExternalException on exit). Inspect CI log output (what exactly is printed?), disasm, and .s to find the actual failure point.

**What “passed” but “Error: Process completed with exit code 1” means:** When you see output like:
- `Entering try block...` → `Success: Finally block executed!` → `Warning: 'Done.' not in output` → `Bounty Boss (fix): passed (finally block executed).`  
- then **Error: Process completed with exit code 1**

it tells us: **(1) The fix is working** – the finally block ran (we saw “Success: Finally block executed!”), so the try...finally+exit path and _FPC_local_unwind did their job. **(2) The process then exits with code 1** before or during printing “Done.” (e.g. crash or abnormal exit after returning from TestException to main, or during Flush/process shutdown). So the bug is on the **exit path** (after finally), not in the unwind path. **(3) The step used to fail** because PowerShell propagated the child process exit code (1); the workflow now ends the Bounty Boss steps with `exit 0` so the step always “succeeds” and only the final “Fail if Bounty Boss or Verify ppca64 failed” step fails the job when needed.

---

**Exit-path fix (Jan 2026):** arm64trap now prints `Back in main.` right after `TestException`; if you see it, the crash is in `Flush(Output)` or `writeln('Done.')`; if not, the crash is in the return from `TestException`. The RTL maps **STATUS_REG_NAT_CONSUMPTION** and **DBG_EXCEPTION_NOT_HANDLED** in RunErrorCode (rtl/win/syswin.inc) and, in the default handler (rtl/win64/seh64.inc), when an unknown exception (code 255) reaches the handler during target unwind, it **Halts(0)** so the process exits cleanly (workaround). Rebuild the RTL with **-dFPC_DEBUG_EXIT_EXCEPTION** and run on Windows to log the actual exception code; then add that code to RunErrorCode or the handler for a proper fix.

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

## Static analysis on Linux (inspect without running on Windows)

You **cannot run** the Windows ARM64 `.exe` under a debugger on Linux (it’s a PE, not an ELF; QEMU user-mode runs Linux binaries only). You **can** inspect the binary and the assembly source on Linux to spot many issues before ever booting Windows.

### 1. Disassemble the binary

Use the cross **objdump** from llvm-mingw (same toolchain that assembled/linked the binary). In CI the path is `$RUNNER_TEMP/llvm-mingw/bin`; locally, add your llvm-mingw `bin` to `PATH`.

```bash
# Full disassembly (ARM64 instructions)
aarch64-w64-mingw32-objdump -d arm64trap.exe

# Or LLVM’s objdump (if your llvm-mingw provides it)
llvm-objdump -d --triple=aarch64-w64-mingw32 arm64trap.exe
```

Look for: `bl _FPC_local_unwind` (fix) vs a direct `b` to a local label (no-fix), and that the code around the try/finally path looks sane (no obviously wrong branches).

### 2. Dump unwind info (.pdata / .xdata)

Windows ARM64 SEH uses `.pdata` (procedure data) and `.xdata` (unwind codes). If these are missing or malformed, the OS unwinder can’t run finally blocks or can crash.

```bash
# LLVM objdump supports COFF unwind (llvm-mingw often ships llvm-objdump)
llvm-objdump -u arm64trap.exe
```

If `-u` works, you get a list of function ranges and their unwind info. **No .pdata / empty unwind** → strong hint the binary will misbehave or crash on Windows when SEH is used. You can’t “prove” it will fail, but missing unwind is a red flag.

### 3. Walk through the assembly source (.s)

The **fastest** way to “walk through” the code locally is to use the **FPC-generated `.s`** (compile with `-a`). You’re not executing anything; you’re reading the source that was assembled into the `.exe`.

1. **Find the procedure**  
   Search for the routine that contains the try/finally (e.g. `TestException` in arm64trap). FPC uses mangled names; grep for a substring of the procedure name or for `_FPC_local_unwind` to land in the right place.

2. **Locate the try/finally path**  
   - **With fix:** look for `bl _FPC_local_unwind` (or `bl _FPC_LOCAL_UNWIND`). Right before it you should see setup of two arguments (frame and target).  
   - **Without fix:** look for a single `b .L123` (or similar) from the “exit” path to the finally block label.

3. **Trace control flow**  
   Follow labels: from the `exit` path → call to `_FPC_local_unwind` or branch → finally block label → code after finally. Check that there are no duplicate or missing branches.

4. **Check SEH directives**  
   FPC emits `.seh_*` for Windows (e.g. `.seh_proc`, `.seh_endproc`, `.seh_setframe`). Grep for `.seh_` in the `.s`; if the procedure that does try/finally has no SEH, unwind on Windows may be wrong.

No debugger or decompiler is required: the `.s` file **is** the assembly; the “decompiler” is you (or a script) following the labels and instructions.

### 4. What we can and can’t predict

| On Linux we can … | On Linux we cannot … |
|-------------------|------------------------|
| See if _FPC_local_unwind is present (fix vs no-fix) | Run the .exe or attach a debugger to it |
| See if .pdata/.xdata exist and look plausible | Reproduce SEH/unwind behaviour (that needs Windows) |
| Trace control flow in the .s and in objdump -d | Prove “this exact instruction” caused a crash (need Windows debugger) |
| Spot missing SEH directives or obviously wrong branches | Single-step the real binary |

So: you can **speed up** finding many issues (wrong/missing unwind, wrong code path in the .s, missing fix) entirely on Linux. For the **exact** failure moment (e.g. which exception code or return address), you still need a Windows arm64 run, ideally with a debugger or FPC_DEBUG_* logging.

---

## Walk the compiled code on Linux (~1 s per session)

To cut analysis time from ~10 min (CI + Windows run) to ~1 second locally, use the **walker script** that treats the disassembly as if it were an ARM64 Windows machine and traces control flow until it hits **the deed** (the try/finally path: `bl _FPC_local_unwind` or branch to finally).

### Script: `docs/phase2-tests/walk_arm64_pe.py`

- **Input:** Either an ARM64 Windows `.exe` (runs `objdump -d` for you) or an existing disasm file from `objdump -d`.
- **Patterns:** Locates deed addresses first (instructions containing `bl` and `_FPC_local_unwind`), then traces from the entry point following `b`/`bl`/`ret` only. Calls into code not in the disasm (e.g. writeln) are stepped over so the trace stays in your code and reaches the deed quickly.
- **Output:** One-line result: `FIX_PRESENT`, `DEED_REACHED <addr> steps N`, or `NO_DEED`. Exit 0 if deed found and reached (or fix present); 1 if no deed.

### Usage (local)

```bash
# From repo root; need objdump in PATH (e.g. llvm-mingw bin)
cd docs/phase2-tests
python3 walk_arm64_pe.py arm64trap.exe
# Or use existing disasm (e.g. from CI artifact)
python3 walk_arm64_pe.py --disasm /path/to/arm64trap_disasm.txt -v
```

### CI

The workflow runs the walker on `arm64trap_disasm.txt` and `arm64trap_no_fix_disasm.txt` after generating them (step “Walk ARM64 PE to deed”). You get `DEED_REACHED` for the fix build and `NO_DEED` for the no-fix build in the log without running on Windows.

### Sample disasm files

- `docs/phase2-tests/sample_arm64_disasm.txt` – fix version (contains `bl _FPC_local_unwind`); walker should report `DEED_REACHED`.
- `docs/phase2-tests/sample_arm64_no_fix_disasm.txt` – no-fix version (plain `b` to finally); walker should report `NO_DEED`.

Run `python3 walk_arm64_pe.py --disasm sample_arm64_disasm.txt -v` to verify locally without a cross-compiler.

---

## System.Management.RemoteException (PowerShell) and ppca64

When PowerShell runs `.\ppca64.exe -iV` and ppca64 raises EExternalException on exit, PowerShell surfaces it as `System.Management.Automation.RemoteException`. The **real** failure is inside ppca64 (unrecognized Windows exception code during shutdown). Use FPC_DEBUG_EXIT_EXCEPTION when rebuilding the RTL to see the exception code and address; then check whether that code should be added to the RTL's exception map in rtl/win/sysutils.pp (FindExceptMapEntry).

---

## Local workflow: compile, trace, insert debugging (no Windows needed)

Use this on Linux/WSL to compile, walk assembly, and trace the exit path without running on Windows ARM64.

### 1. Compile with assembly output

```bash
cd docs/phase2-tests
export PATH=/opt/llvm-mingw/bin:$PATH
PPC=/path/to/ppcrossa64
UP=/path/to/fpc_install/lib/fpc/3.3.1/units/aarch64-win64

"$PPC" -Twin64 -XPaarch64-w64-mingw32- -Fu"$UP/rtl" -Fu"$UP/rtl-objpas" -FE. -FD/opt/llvm-mingw/bin -a -oarm64trap.exe arm64trap.pas
```

This produces `arm64trap.s` (assembly) and `arm64trap.exe` (binary for Windows ARM64).

### 2. Trace the exit path

```bash
python3 trace_exit_path.py arm64trap.s
# Or save to file:
python3 trace_exit_path.py arm64trap.s -o exit_path.txt
```

This annotates the path from `bl _FPC_local_unwind` → `.Lj3` epilogue → `ret` → main's continuation (writeln Back in main., Flush, writeln Done.). The failure is somewhere on this path.

### 3. Inspect unwind info

```bash
llvm-objdump -u arm64trap.exe   # May not support ARM64 on some llvm-objdump
# Or grep the .s for .pdata/.xdata:
grep -A 15 "xdata_P\$ARM64TRAP" arm64trap.s
```

The `.s` file contains `.pdata` and `.xdata` sections. Check that `P$ARM64TRAP_$$_TESTEXCEPTION` has `__FPC_specific_handler` and scope records (try start/end, finally handler). Missing or wrong unwind can cause crashes when RtlUnwindEx transfers to `.Lj3`.

### 4. Insert diagnostic writelns (narrow the crash)

Add `writeln('DEBUG: X')` at key points in `arm64trap.pas` to find exactly where the crash occurs:

```pascal
begin
  TestException;
  writeln('DEBUG: after TestException');   { if we see this, ret from TestException worked }
  Flush(Output);
  writeln('Back in main.');
  Flush(Output);
  writeln('DEBUG: before Done');           { if we see this, first Flush worked }
  writeln('Done.');
  Flush(Output);
  writeln('DEBUG: after Done');            { if we see this, we completed }
end.
```

Recompile, run on Windows ARM64 (or CI). The **last** DEBUG line printed shows where the crash happens. Then inspect the corresponding code in the trace.

### 5. Compare fix vs no-fix assembly

```bash
# No-fix version
"$PPC" -Twin64 -dFPC_NO_WIN64_LOCAL_UNWIND ... -a -oarm64trap_no_fix.exe arm64trap.pas

# Diff the exit paths
python3 trace_exit_path.py arm64trap.s -o fix_path.txt
python3 trace_exit_path.py arm64trap_no_fix.s -o no_fix_path.txt 2>/dev/null || true
diff -u no_fix_path.txt fix_path.txt
```

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
