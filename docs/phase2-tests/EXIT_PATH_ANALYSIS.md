# Assembly Walk-Through: Finally Exit Failure Analysis

This document summarizes the assembly analysis of `arm64trap.exe` (try...finally+exit) to identify potential causes of the exit code 1 failure after "Success: Finally block executed!".

---

## Control Flow Summary

### 1. TestException (P$ARM64TRAP_$$_TESTEXCEPTION)

**Prologue (lines 9-14):**
```
stp x29,x30,[sp, #-16]!   ; push FP, LR
mov x29,sp                 ; FP = SP (canonical frame)
str x19,[sp, #-16]!       ; push x19
sub sp,sp,#16              ; 16 bytes for locals
```

**Stack layout at bl _FPC_local_unwind:**
- `sp` = original_sp - 48 (lowest address)
- `[sp]` = 16 bytes local (used for fpc_get_output temp)
- `[sp+16]` = saved x19
- `[sp+32]` = saved x29, x30  ← return address to main is at [sp+40]
- `x29` = original_sp - 16 (= sp + 32, points at saved FP/LR)

**Try body (lines 18-32):** writeln "Entering try...", then:
```
mov x0,sp                  ; arg1 = frame (CURRENT SP)
adrp x1,.Lj3
add x1,x1,:lo12:.Lj3       ; arg2 = target (.Lj3)
bl _FPC_local_unwind       ; never returns normally
```

**Epilogue target (.Lj3, lines 47-52):**
```
add sp,sp,#16              ; undo sub sp,#16
ldr x19,[sp], #16          ; restore x19, sp += 16
mov sp,x29                 ; sp = FP (point to saved FP/LR)
ldp x29,x30,[sp], #16      ; restore FP, LR
ret                        ; → main
```

---

## Potential Problem: Frame Argument

**We pass `x0 = SP`** (current stack pointer) to `_FPC_local_unwind` → `RtlUnwindEx(TargetFrame, TargetIp, ...)`.

**Hypothesis:** On ARM64 Windows, the unwinder may expect **EstablisherFrame** to identify the frame. Sources suggest:
- For frame-pointer-based functions, the canonical frame identifier may be **x29 (FP)** or **Caller-SP**, not the current SP.
- Our `SP` changes during the function (we did `sub sp,#16`). At the call site, SP = original_sp - 48.
- `x29` is stable and points to the saved frame slot.

**If the unwinder compares TargetFrame to its computed EstablisherFrame and they don't match**, it might:
- Over-unwind (pop past our frame)
- Mis-compute the context when transferring to .Lj3
- Leave SP/x29/x30 wrong so the epilogue or `ret` fails

**Possible fix:** Pass **x29 (frame pointer)** instead of SP:
```pascal
// In g_local_unwind, change:
a_load_reg_cgpara(list, OS_ADDR, NR_STACK_POINTER_REG, para1);
// to:
a_load_reg_cgpara(list, OS_ADDR, NR_FRAME_POINTER_REG, para1);
```

---

## Unwind Info (xdata)

```
xdata_P$ARM64TRAP_$$_TESTEXCEPTION:
  .rva .Lj7        ; try start
  .rva .Lj8        ; try end
  .rva fin         ; finally handler
```

Scope: try region [.Lj7, .Lj8), handler = P$ARM64TRAP$_$TESTEXCEPTION_$$_fin$00000001.
Target .Lj3 is **outside** the try region (after .Lj8) — correct.

---

## Finally Handler (fin)

**Prologue:**
```
stp x29,x30,[sp,#-16]!
mov x29,x0              ; x0 = parent's FP (from ContextGetFP)
```

**Body:** writeln "Success: Finally block executed!", using `str x0,[sp]` for temp.
**Note:** `str x0,[sp]` overwrites the saved x29 slot (we only have 16 bytes from the stp). The saved x30 (return address to unwinder) at [sp+8] remains intact. On `ldp x29,x30` we load corrupted x29 but correct x30 — the `ret` should still work.

---

## Main Continuation (after TestException returns)

Expected flow: `ret` from .Lj3 → instruction after `bl P$ARM64TRAP_$$_TESTEXCEPTION` in PASCALMAIN → writeln "Back in main." → Flush → writeln "Done." → Flush → fpc_do_exit.

If we see "Success: Finally block executed!" but not "Done.", the failure is one of:
1. **Wrong context at .Lj3** — SP/x29/x30 incorrect when RtlUnwindEx transfers; epilogue or `ret` goes wrong.
2. **Wrong return address** — LR when we `ret` doesn't point to main; we jump elsewhere and crash.
3. **Main code path** — FPC_THREADVAR_RELOCATE, Flush, or writeln triggers an exception (e.g. STATUS_REG_NAT_CONSUMPTION, unknown code 255).
4. **PAC (Pointer Auth)** — If enabled, signed pointers might fail verification when we land at .Lj3 from an unconventional path.

---

## Recommended Next Steps

1. **Try passing x29 instead of SP** in `g_local_unwind` — quick test for the frame-argument hypothesis.
2. **Add DEBUG writelns** in arm64trap.pas (after TestException, before Flush, before Done) to narrow the crash to a specific instruction range.
3. **Rebuild RTL with -dFPC_DEBUG_EXIT_EXCEPTION** and run on Windows ARM64 — capture the exact exception code when the crash occurs.
4. **Verify on Windows** — Use WinDbg to break at `_FPC_local_unwind` and single-step through RtlUnwindEx return to .Lj3; inspect Context and stack.
