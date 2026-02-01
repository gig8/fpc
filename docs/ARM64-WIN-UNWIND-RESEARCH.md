# ARM64 Windows try/finally unwind – research summary

Research on what could be wrong with `_fpc_local_unwind` / `RtlUnwindEx` from try block to epilogue, and what C++ runtime, longjmp, and .NET do that we might have missed.

## 1. What we do today

- **Compiler** (`compiler/aarch64/cgcpu.pas`): For try/exit/break/continue it calls `_FPC_local_unwind(frame, target)` with **frame = current SP** (NR_STACK_POINTER_REG) and **target = landing pad** (label after try-finally).
- **RTL** (`rtl/win64/seh64.inc`): We capture context, do **one** `RtlVirtualUnwind` from `_fpc_local_unwind` to get caller (TestException) frame and **EstablisherFrame** (Caller-SP = TestException’s SP). We set `ctx.Pc := target`, `ctx.Sp := EstablisherFrame`, set **ContextFlags** (CONTROL + INTEGER + ARM64, clear UNWOUND_TO_CALL and DEBUG), then call `RtlUnwindEx(FrameToUse, target, nil, nil, @ctx, @UnwindHistory)` where `FrameToUse = EstablisherFrame`.

So we pass a **pre-unwound** context (TestException’s frame, PC = landing pad) and use our computed EstablisherFrame as TargetFrame.

## 2. RtlUnwindEx and the context we pass

- **MSDN**: ContextRecord “stores context during the unwind operation”.
- **Nynaeve (x64)**: “The first order of business within RtlUnwindEx is to **capture** the execution context at the time of the call” (inside RtlUnwindEx). So the implementation **overwrites** the passed context with a fresh capture, then unwinds from that. The context that is finally passed to `RtlRestoreContext` is the one the OS built during the unwind loop, **not** our pre-filled ctx.
- **Implication**: The **ContextFlags** we set on `ctx` are very likely overwritten at the start of `RtlUnwindEx`. So our CONTROL+INTEGER+ARM64 fix might never be used by `RtlRestoreContext`; the OS uses whatever flags it set when it built the context. If the OS does not set CONTEXT_INTEGER on ARM64 when building that context, **LR (and callee-saved regs) may not be restored** (see Go runtime note below).

## 3. C++ runtime, longjmp, .NET

- **ARM64 exception handling (MSVC)**: Same SEH model; EstablisherFrame = **Caller-SP**; unwind codes describe prolog/epilog; no extra requirement we’re obviously missing.
- **longjmp (Windows)**: Uses same unwind semantics as C++ exceptions; setjmp saves context, longjmp uses it. On x64, longjmp-style use of `RtlUnwindEx` passes a **saved** context (from setjmp) and a target frame. We don’t have setjmp; we **synthesize** the target-frame context with one `RtlVirtualUnwind` and set PC to the landing pad. The important difference: longjmp’s context was **captured at the setjmp site**. Our context is **unwound** from inside `_fpc_local_unwind`. For “current frame = TestException at landing pad” that should be equivalent if EstablisherFrame and SP match.
- **.NET CoreCLR**: Uses Windows unwinding (e.g. `ClrUnwindEx` → `RtlUnwind` 4-arg on some paths). ARM64: same SEH, EstablisherFrame = Caller-SP. We already tried 4-arg `RtlUnwind` and still crashed; 6-arg with explicit context was to match longjmp and control ContextFlags.
- **Go runtime** (`src/runtime/defs_windows_arm64.go`): “_CONTEXT_CONTROL (0x400001) should include PC, SP, and LR. However, empirically, **LR doesn’t come along on Windows 10 unless you also set _CONTEXT_INTEGER (0x400002)**.” So they set both (e.g. 0x400003) for stack walking / context use. We set CONTROL+INTEGER+ARM64 for the same reason, but if RtlUnwindEx overwrites our context at entry, the final context passed to RtlRestoreContext may still have flags that don’t include INTEGER, so LR might not be restored.

## 4. Try → epilogue: what might be “not assigned”

- **Frame / TargetFrame**: Compiler passes **frame = SP at call site** (TestException’s SP when it called `_fpc_local_unwind`). We recompute **EstablisherFrame** via `RtlVirtualUnwind` (Caller-SP of `_fpc_local_unwind`). On ARM64, EstablisherFrame is defined as Caller-SP, so they **should** be the same. If they differ (e.g. alignment, or different interpretation of “caller SP”), using the compiler’s `frame` directly as TargetFrame is a good experiment (see “Experiments” below).
- **ContextFlags**: As above, we set them but the OS may overwrite the context; the restored context might not have CONTEXT_INTEGER set, so **LR (and possibly FP, X19–X28)** might not be restored. First instruction at the landing pad or the following `ret` could then fault (bad LR).
- **ReturnValue**: We pass `nil` (X0 = 0). The landing pad doesn’t use a return value; epilogue just runs and returns to main. Unlikely to be the cause unless the epilogue or caller expect something in X0.
- **Landing pad / prolog–epilog**: ARM64 requires prolog/epilog to be described by unwind codes; “no conditional code in epilogs”. If the code at the landing pad or the path to the real epilog doesn’t match what the unwinder expects, the restored SP/FP might be wrong. Worth checking that the first instruction at `target` is valid and that the function’s unwind info is correct for that PC.

## 5. RtlRestoreContext (MSDN / NtDoc)

- Restores the caller to the given CONTEXT. Restores only the parts indicated by **ContextFlags**.
- **STATUS_LONGJUMP**: copies non-volatile state from jmp_buf into the context before restore.
- **STATUS_UNWIND_CONSOLIDATE**: used for catch handlers; we don’t use it.
- So the only thing we can rely on is: whatever context the OS passes to RtlRestoreContext, only the portions specified by **that** context’s ContextFlags are restored. If the OS didn’t set CONTEXT_INTEGER, LR (and integer callee-saved) are not restored.

## 6. Similar usages (GitHub / references)

- **Go**: `defs_windows_arm64.go` – CONTEXT_CONTROL + CONTEXT_INTEGER for LR; `establisherFrame` in DISPATCHER_CONTEXT.
- **MS ARM64 exception handling**: EstablisherFrame = Caller-SP; .xdata/.pdata describe unwinding.
- **Nynaeve**: x64 RtlUnwindEx overwrites context, then unwinds; at target, loads ReturnValue into Rax, sets Rip := TargetIp, calls RtlRestoreContext. ARM64 should be analogous (X0, Pc).
- **dotnet/runtime**: ARM64 Windows unwind in exception handling; no public snippet that changes our approach.
- **longjmp on Windows**: Custom wrappers using RtlUnwindEx with a context saved at setjmp; we emulate “target frame context” by one RtlVirtualUnwind.

## 7. What could be wrong (concise)

1. **Context overwrite**: RtlUnwindEx may overwrite our context at entry; the context finally restored may not have CONTEXT_INTEGER, so **LR (and callee-saved)** might not be restored → fault at ret or use of LR/FP.
2. **Frame mismatch**: Compiler’s `frame` (SP at call) might differ from our EstablisherFrame (e.g. alignment or ABI nuance). Then TargetFrame could be wrong and the OS might not run the finally or might restore the wrong frame.
3. **Unwind / .pdata**: Incorrect or incomplete unwind info for TestException or _fpc_local_unwind could make the OS compute a wrong context (SP/FP/LR) for the “target” frame.
4. **Landing pad**: First instruction at `target` might assume a certain stack layout or register state that doesn’t hold after restore (e.g. missing LR).

## 8. Experiments to try

1. **Use compiler’s frame as TargetFrame**  
   Call `RtlUnwindEx(frame, target, nil, nil, @ctx, @UnwindHistory)` with **no** pre-unwind: only `RtlCaptureContext(ctx)` and optionally set ContextFlags, then call. So we use the same pattern as x64 (frame = compiler’s SP). If the crash changes (e.g. finally not run, or different fault address), then EstablisherFrame vs compiler `frame` matters. If the same crash, the issue is likely in the context that gets restored (e.g. ContextFlags / LR).

2. **VEH / ExceptionCode**  
   Rely on the VEH already in arm64trap: **ExceptionCode** and **ExceptionAddress** tell us whether we fault in RtlRestoreContext, at the first instruction of the landing pad, or in the epilogue (e.g. ret). That narrows where to look (context vs code gen vs unwind info).

3. **Inspect context after OS unwind**  
   We can’t patch context between “target reached” and RtlRestoreContext. We could build a minimal test that uses only RtlCaptureContext + RtlVirtualUnwind (no RtlUnwindEx) and then **RtlRestoreContext** ourselves with a context we fully control (PC=target, Sp=EstablisherFrame, LR/FP/X19–X28 from RtlVirtualUnwind, ContextFlags = CONTROL+INTEGER+ARM64). If that lands and runs correctly, the bug is inside RtlUnwindEx’s use/overwrite of context or its call to RtlRestoreContext. If that also crashes, the bug is in our context or in RtlRestoreContext’s handling of it.

## 9. CI run: VEH and fix

**Latest run (arm64trap):**
- Steps 0–7 run; finally runs; then crash before "LANDED at first instr".
- **VEH #1**: `ExceptionCode=$C0000005` (STATUS_ACCESS_VIOLATION), `ExceptionAddress=$00007FF706D2A3A8` = **landing pad**. So we fault **on the first instruction at the landing pad** (bad memory access). PC is correct; SP/FP or another base register is wrong.
- **VEH #2**: `ExceptionCode=$C00000AA`, `ExceptionAddress=$000000000000D7B2` – low address, cascade (e.g. bad LR/PC during exception dispatch).
- **Step 1**: `Lr=$0000000000000000` after RtlCaptureContext inside _fpc_local_unwind (LR not captured). After RtlVirtualUnwind we get a valid Lr ($00007FF706A52138).

**Conclusion**: RtlUnwindEx overwrites our context at entry; the context passed to RtlRestoreContext is the OS-built one and likely did not have CONTEXT_INTEGER set, so LR (and possibly FP/X19–X28) were not restored. The first instruction at the landing pad then faults (e.g. load/store using bad FP or stack).

**Fix**: In `__FPC_specific_handler`, when we are the target frame (EXCEPTION_TARGET_UNWIND), **patch** the context at the **start** of the unwind branch (landing pad is after the try-finally scope, so "TargetRva in scope" was always false). Set `ContextFlags` to include CONTEXT_ARM64, CONTEXT_CONTROL_ARM64, CONTEXT_INTEGER_ARM64 so RtlRestoreContext restores PC, SP, LR, FP, X19–X28.

## 10. Assembly analysis (arm64trap_disasm.txt)

**TestException prolog** (P$ARM64TRAP_$$_TESTEXCEPTION): `stp x29,x30,[sp,#-0x10]!`; `mov x29,sp`; `str x19,[sp,#-0x10]!`; `sub sp,sp,#0x10`. So SP -= 48, FP = SP after first two (points at saved x29,x30).

**Call to _fpc_local_unwind**: `mov x0,sp` (frame = current SP), then `adrp`/`add` for target, then `bl _fpc_local_unwind`. So first arg = TestException’s SP at call; second = landing-pad address.

**Landing pad** (first instruction after try-finally): **NOP**, then `bl fpc_get_output`, then **`str x0,[sp]`** then `ldr x1,[sp]` … So the first memory access after the NOP is **`str x0,[sp]`**. If SP is not restored by RtlRestoreContext (e.g. OS didn’t set CONTEXT_CONTROL/INTEGER), that STR faults → ACCESS_VIOLATION at or near the landing pad. So the fault is consistent with **SP (and/or FP) not restored**; the handler patch (CONTEXT_CONTROL + CONTEXT_INTEGER at EXCEPTION_TARGET_UNWIND) is intended to fix that.

**Epilogue** (after landing-pad block): `add sp,sp,#0x10`; `ldr x19,[sp],#0x10`; `mov sp,x29`; `ldp x29,x30,[sp],#0x10`; `ret`. So the epilogue restores SP from x29 (FP); FP and LR must be correct for the epilogue and ret to work.

## 11. If it still fails: what to check, and could it be a Windows ARM64 bug?

### What to inspect on the ARM64 machine

1. **Handler logs**  
   With `FPC_DEBUG_WIN64_UNWIND`, we now log when we hit EXCEPTION_TARGET_UNWIND: ContextFlags, Lr, Sp, Fp before/after patch. If we **never** see "TARGET_UNWIND: before patch", we're still not in the right path (e.g. handler not called for target frame, or different build). If we **do** see it:
   - **Lr or Fp is 0 (or clearly wrong)** → the OS-built context didn't fill integer/control state; our flag patch alone won't fix it (we'd need to supply correct values, which we don't have in the handler).
   - **Lr/Sp/Fp look plausible** but we still fault → either the OS overwrites the context after we return, or RtlRestoreContext ignores our flags on this path.

2. **Faulting instruction**  
   VEH gives `ExceptionAddress`. Disassemble that instruction in the built exe (e.g. `llvm-objdump -d` or dump bytes and decode). That tells you:
   - Which **register** is used (SP, FP, x19, etc.) and whether it's a load or store.
   - If it's `str x0,[sp]` and we fault → SP is bad (unmapped or misaligned).
   - If it's something like `ldr x0,[x29,#offset]` → FP is bad.
   So you can tie the fault directly to a missing or wrong register in the restored context.

3. **Unwind metadata (.pdata/.xdata)**  
   If the **unwind info** for TestException or _fpc_local_unwind is wrong, RtlVirtualUnwind (inside RtlUnwindEx) could produce a wrong EstablisherFrame or wrong context (SP/FP/LR). On the ARM64 machine, dump unwind for the relevant functions, e.g.:
   - `llvm-objdump -u arm64trap.exe` (or the system unit / exe that contains the call).
   Check that the prolog/epilog described in .xdata matches the actual instructions (saved regs, frame size, EstablisherFrame = Caller-SP).

4. **Debugger at the landing pad**  
   Set a **breakpoint at the landing-pad address** (the `target` we pass to _fpc_local_unwind). Run until the breakpoint (after the unwind). When you hit it, inspect **SP, FP (x29), LR (x30), x19** in the debugger. If any are wrong (e.g. SP not 16-byte aligned, or FP/LR zero), that’s the register RtlRestoreContext didn’t restore correctly.

5. **Compare with another runtime**  
   On the same ARM64 Windows machine, run a **minimal C** program that does `setjmp` / `longjmp` (or a minimal C++ try/finally-style unwind). If that works, the OS path is capable of restoring context; if it also fails in a similar way, that supports an OS/ABI quirk or bug.

### Could it be a bug in Windows ARM64?

**Yes, it’s plausible.**

- **Go** already documents a **Windows 10 ARM64 quirk**: “_CONTEXT_CONTROL should include PC, SP, and LR, but empirically LR doesn’t come along unless you also set _CONTEXT_INTEGER.” So the OS doesn’t quite match the documented behavior; we’re working around that by patching flags. If the OS **ignores** our patched context (e.g. RtlUnwindEx copies from an internal buffer to the context *after* calling our handler), our patch would have no effect and it would look like “Windows doesn’t restore LR/INTEGER in this path.”
- **RtlUnwindEx** might, on ARM64, **overwrite the context again** after the language handler returns (e.g. set PC/SP from internal state but never copy our ContextRecord back). We can’t see that from our code; we’d only infer it if we patch, see good values in the handler, and still fault.
- **RtlRestoreContext** might have a code path (e.g. when called from RtlUnwindEx) that **only restores a subset** of the context (e.g. PC + SP) and ignores CONTEXT_INTEGER on ARM64. That would be a Windows bug.
- **RtlVirtualUnwind** might, in some builds, **not fill** LR/FP in the context structure on ARM64. Then even with CONTEXT_INTEGER set, the values we restore would be garbage.

**How to gather evidence**

- **Same binary on Windows 11 ARM64** (if available): if it works there but not on Windows 10 ARM64, that points at an OS version–specific bug or quirk.
- **Search** for “RtlRestoreContext ARM64”, “CONTEXT_INTEGER ARM64”, “RtlUnwindEx ARM64” in Windows Feedback Hub, MSDN forums, or GitHub (e.g. dotnet/runtime, golang/go) to see if others hit similar behavior.
- **Report** to Microsoft (Feedback Hub or support) with: minimal repro (try/finally + exit), VEH ExceptionAddress/ExceptionCode, and the observation that CONTEXT_CONTROL+INTEGER patch in the target-frame handler doesn’t restore LR/FP. Include the Go runtime comment as precedent for CONTEXT behavior on Windows 10 ARM64.

So: if it still doesn’t work, the next steps are (1) use the handler logs and faulting instruction to see *which* register is wrong, (2) check unwind metadata and a debugger at the landing pad to confirm what state we’re actually in, and (3) treat a Windows ARM64 bug as a real possibility and look for OS version differences and existing reports.

## 12. References

- MSDN: RtlUnwindEx, RtlRestoreContext, RtlVirtualUnwind, CONTEXT (ARM64).
- MSDN: ARM64 exception handling (prolog/epilog, EstablisherFrame = Caller-SP).
- Nynaeve: “Programming against the x64 exception handling support, part 4” (RtlUnwindEx overwrites context, then unwinds; at target, sets Rip, Rax, RtlRestoreContext).
- Go: `src/runtime/defs_windows_arm64.go` (CONTEXT_CONTROL + CONTEXT_INTEGER for LR on Windows 10 ARM64).
- Stack Overflow: RtlRestoreContext and STATUS_UNWIND_CONSOLIDATE; longjmp landing wrong on 64-bit Windows.
