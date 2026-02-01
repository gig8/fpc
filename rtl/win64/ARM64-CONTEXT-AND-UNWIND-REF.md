# ARM64 Windows CONTEXT and Unwind Reference

Reference for `_fpc_local_unwind` and RtlUnwindEx/RtlRestoreContext on ARM64 Windows.
Use this to verify we restore everything needed and to compare with other runtimes.

## CONTEXT structure (ARM64_NT_CONTEXT)

Fields that RtlRestoreContext restores (depending on ContextFlags):

| Field | Register | Restored when | Notes |
|-------|----------|---------------|--------|
| Pc | PC | CONTEXT_CONTROL / CONTEXT_ARM64 | We set to target (landing pad) |
| Sp | SP | CONTEXT_CONTROL | We set to EstablisherFrame |
| Lr | LR (X30) | CONTEXT_CONTROL or CONTEXT_INTEGER | Return address; must be valid |
| Fp | FP (X29) | CONTEXT_INTEGER | Frame pointer |
| X0–X28 | GPRs | CONTEXT_INTEGER | X19–X28 callee-saved |
| Cpsr | PSTATE | CONTEXT_CONTROL | Condition flags |
| V[0..31] | NEON | CONTEXT_FLOATING_POINT | SIMD; only if target uses them |
| Fpcr, Fpsr | FP control | CONTEXT_FLOATING_POINT | |

We do **not** set CONTEXT_FLOATING_POINT; the unwound context from RtlVirtualUnwind keeps it if it was present. For try/finally/exit we rely on CONTROL + INTEGER.

## ContextFlags (ARM64)

| Constant | Value | Meaning |
|----------|--------|--------|
| CONTEXT_CONTROL_ARM64 | 0x400001 | PC, SP, LR, Cpsr |
| CONTEXT_INTEGER_ARM64 | 0x400002 | X0–X30 (incl. Fp, Lr) |
| CONTEXT_ARM64 | 0x00400000 | Architecture flag |
| CONTEXT_UNWOUND_TO_CALL | 0x20000000 | Clear before RtlUnwindEx |
| CONTEXT_DEBUG_REGISTERS_ARM64 | 0x00100000 | Clear before RtlUnwindEx (named to avoid clash with wininc) |

**Go runtime (defs_windows_arm64.go):**  
"CONTEXT_CONTROL is 0x400001 and should include PC, SP, and LR. However, empirically on Windows 10 LR doesn't come along unless you also set CONTEXT_INTEGER (0x400002)."  
So we set **CONTEXT_CONTROL_ARM64 | CONTEXT_INTEGER_ARM64 | CONTEXT_ARM64** so RtlRestoreContext restores PC, SP, LR, Fp, and X0–X28.

## What we set before RtlUnwindEx

1. **ctx** = unwound context from one RtlVirtualUnwind (TestException’s frame).
2. **ContextSetIP(ctx, target)** → Pc = landing pad.
3. **ctx.Sp := EstablisherFrame** → SP matches frame we’re restoring to.
4. **ContextFlags**: clear CONTEXT_UNWOUND_TO_CALL and CONTEXT_DEBUG_REGISTERS_ARM64; OR in CONTEXT_ARM64 | CONTEXT_CONTROL_ARM64 | CONTEXT_INTEGER_ARM64.

So we **keep** all unwound register state (LR, Fp, X19–X28, Cpsr, etc.) and only override Pc and Sp, and fix flags.

## longjmp / setjmp (MSVC CRT)

- Not open source.
- RtlRestoreContext doc: when ExceptionRecord has **ExceptionCode == STATUS_LONGJUMP**, it copies non-volatile state from the jump buffer into the context before restoring.
- So longjmp path uses a **saved** context (setjmp buffer), not an unwound one; we use unwound + override PC/SP.

## References (Microsoft / runtimes)

1. **Microsoft Docs**
   - RtlRestoreContext: https://learn.microsoft.com/en-us/windows/win32/api/winnt/nf-winnt-rtlrestorecontext  
   - RtlUnwindEx: https://learn.microsoft.com/en-us/windows/win32/api/winnt/nf-winnt-rtlunwindex  
   - ARM64_NT_CONTEXT: https://learn.microsoft.com/en-us/windows/win32/api/winnt/ns-winnt-arm64_nt_context  
   - RtlVirtualUnwind: https://learn.microsoft.com/en-us/windows/win32/api/winnt/nf-winnt-rtlvirtualunwind  

2. **Go runtime (ARM64 Windows)**
   - `src/runtime/defs_windows_arm64.go`: CONTEXT flags, context layout (x[31] with fp=x[29], lr=x[30]), pushCall, prepareContextForSigResume.  
   - Uses CONTEXT_CONTROL | CONTEXT_INTEGER (0x400003) so LR and integer regs are present.

3. **ReactOS**
   - `sdk/lib/rtl/amd64/unwind.c`: RtlUnwindEx/RtlRestoreContext for **x64** only; useful for unwind semantics, not ARM64 layout.

4. **LLVM libunwind**
   - `UnwindLevel1.c`: Itanium C++ ABI; different from Windows SEH; no direct RtlUnwindEx use.

## Checklist: context restored for landing pad

- [x] Pc = target (landing pad)
- [x] Sp = EstablisherFrame
- [x] Lr = return address (from unwound context)
- [x] Fp = frame pointer (from unwound context)
- [x] X19–X28 = callee-saved (from unwound context)
- [x] ContextFlags = CONTEXT_ARM64 | CONTEXT_CONTROL_ARM64 | CONTEXT_INTEGER_ARM64 (and UNWOUND/DEBUG cleared)
- [ ] Cpsr = from unwound context (kept if CONTEXT_CONTROL set)
- [ ] V0–V31 / Fpcr / Fpsr = only if CONTEXT_FLOATING_POINT set (we don’t set; OK for integer-only path)

## Possible gaps

1. **Cpsr**: Unwound context should have it; we keep CONTEXT_CONTROL so it should be restored. If not, we could set CONTEXT_FLOATING_POINT or re-check docs for Cpsr.
2. **NEON (V0–V31)**: If the landing pad or epilogue uses SIMD, we might need CONTEXT_FLOATING_POINT. For typical try/finally/exit, integer + control is enough.
3. **EstablisherFrame**: Must be the SP of the frame we’re restoring (TestException’s SP). We use the EstablisherFrame from RtlVirtualUnwind; if that’s wrong, unwinding or restore could fail.
