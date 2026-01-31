# Rigorous analysis: g_local_unwind fix for Windows ARM64 (Bounty Boss)

This document provides a final, line-by-line and semantics-level analysis of the fix that makes try...finally + exit work on Windows ARM64 by implementing `tcgaarch64.g_local_unwind` to call the RTL unwinder instead of emitting a plain jump.

---

## 1. Fix location and structure

| Item | Value |
|------|--------|
| **File** | `compiler/aarch64/cgcpu.pas` |
| **Procedure** | `tcgaarch64.g_local_unwind(list: TAsmList; l: TAsmLabel)` |
| **Declaration** | Line 108: `procedure g_local_unwind(list: TAsmList; l: TAsmLabel); override;` |
| **Implementation** | Lines 2210–2237 |

**Structure:**

1. **Guard:** If `target_info.system <> system_aarch64_win64` then call `inherited g_local_unwind(list, l)` and exit. So only aarch64-win64 uses the new behaviour; all other aarch64 targets (Linux, Darwin, etc.) keep the default jump.
2. **Lookup:** `pd := search_system_proc('_fpc_local_unwind');` — resolves the RTL procedure that wraps `RtlUnwindEx`.
3. **Parameters:** Two `tcgpara` (para1, para2), filled via paramanager for params 1 and 2 of `pd`.
4. **Arg1 (frame):** `a_load_reg_cgpara(list, OS_ADDR, NR_STACK_POINTER_REG, para1)` — current stack pointer.
5. **Arg2 (target):** `reference_reset_symbol(href, l, 0, 1, []);` then `a_loadaddr_ref_cgpara(list, href, para2)` — address of the label `l`.
6. **Cleanup / call:** `paramanager.freecgpara` for para2 then para1, `a_call_name(list, '_FPC_local_unwind', false)`, then `para2.done` / `para1.done`.

No code is emitted after the call: `RtlUnwindEx` does not return to the caller; it transfers control to the target address.

---

## 2. Consistency with x86_64-win64

The aarch64 implementation is intentionally aligned with the x86_64-win64 one.

| Aspect | x86_64 (`cgcpu.pas` ~459–485) | aarch64 (2210–2237) |
|--------|-------------------------------|----------------------|
| Guard | `target_info.system <> system_x86_64_win64` → inherited | `target_info.system <> system_aarch64_win64` → inherited |
| Proc lookup | `search_system_proc('_fpc_local_unwind')` | Same |
| Param setup | para1, para2 via getcgtempparaloc(1), (2) | Same |
| Frame | `a_load_reg_cgpara(..., NR_STACK_POINTER_REG, para1)` | Same (NR_STACK_POINTER_REG) |
| Target | `reference_reset_symbol(href, l, 0, 1, []); a_loadaddr_ref_cgpara(list, href, para2)` | Same |
| Cleanup order | freecgpara para2, para1; call; para2.done; para1.done | Same |
| Call | `g_call(list, '_FPC_local_unwind')` | `a_call_name(list, '_FPC_local_unwind', false)` |

The only differences are: (1) target check constant, (2) x86_64 uses `g_call` while aarch64 uses `a_call_name` (backend-specific but equivalent here). So the fix is a direct port of the win64 SEH local-unwind pattern from x86_64 to aarch64.

---

## 3. Call site and label meaning

**Where it’s used:** `compiler/aarch64/ncpuflw.pas` (and the shared `compiler/ncgflw.pas` flow). For example:

- **Exit from try:** `if (fc_unwind_exit in oldflowcontrol) then cg.g_local_unwind(..., oldCurrExitLabel)` (ncpuflw ~519).
- **Break/continue:** Same pattern with `oldBreakLabel` / `oldContinueLabel` when `fc_unwind_loop` is set (~529, ~539).

**What the label is:** In `taarch64tryfinallynode.pass_generate_code` (ncpuflw ~256–260), `current_procinfo.CurrExitLabel` is set to `finallylabel` for the duration of the try block. So when we exit from inside the try, `oldCurrExitLabel` (saved before the try) is the **finally** block label. Hence:

- **Parameter 1 (frame):** Current SP at the exit path — identifies “this frame” for the unwinder.
- **Parameter 2 (target):** Address of the **finally** block — where the OS should transfer control after running unwind handlers.

So we are literally asking the OS: “Unwind from this frame to the finally block,” which is exactly what try...finally + exit requires.

---

## 4. RTL contract

**Definition:** `rtl/win64/seh64.inc` (included by `rtl/win64/system.pp`):

```pascal
procedure _fpc_local_unwind(frame,target: Pointer);[public,alias:'_FPC_local_unwind'];compilerproc;
var
  ctx: TContext;
begin
  RtlUnwindEx(frame,target,nil,nil,@ctx,nil);
end;
```

- **Signature:** Two `Pointer` arguments: frame, target. Matches what the codegen passes (SP, label address).
- **Availability:** `rtl/win64/Makefile` builds for both `x86_64-win64` and `aarch64-win64`; `system.pp` includes `seh64.inc` for win64. So aarch64-win64 links the same RTL and has `_FPC_local_unwind` in the system unit. No RTL or linker change is required for this fix.
- **Behaviour:** `RtlUnwindEx` runs the Windows unwind (including our .pdata/__FPC_specific_handler logic), runs the finally code, then jumps to `target`. It does not return. So no code after the call is needed.

---

## 5. ABI and parameter passing

- **Arm64 Windows:** First two pointer-sized args in x0, x1. Param 1 = frame → x0, param 2 = target → x1. `paramanager.getcgtempparaloc(list, pd, 1, para1)` and `(..., 2, para2)` yield the correct locations for the current target (aarch64-win64).
- **Frame = SP:** Using the current stack pointer at the call site is consistent with x86_64 (which uses RSP) and with the RTL comment. The unwinder uses this as the “from” frame. Using SP is correct for a fixed stack; if FPC later adds dynamic allocas or more complex frame layout, both backends would need to be revisited (x86_64 already has a TODO to that effect).
- **Target = label address:** `reference_reset_symbol(href, l, 0, 1, [])` and `a_loadaddr_ref_cgpara` put the address of label `l` into the second parameter. That is the instruction pointer to which `RtlUnwindEx` will jump after unwind — correct.

So the call convention and argument values are correct for aarch64-win64.

---

## 6. Edge cases and safety

| Risk | Mitigation |
|------|------------|
| `search_system_proc('_fpc_local_unwind')` returns nil | Only possible if the system unit for the target doesn’t define it. For aarch64-win64 we use rtl/win64, which includes seh64.inc and defines it. The path is only taken when `target_info.system = system_aarch64_win64`, so we never use this on a target that lacks the symbol. |
| Wrong target (e.g. Linux) | Explicit guard: non–aarch64_win64 targets get `inherited g_local_unwind(list, l)` (plain jump). No call to `_FPC_local_unwind` is emitted. |
| Parameter cleanup order | Same as x86_64: free para2 then para1, then done in the same order. No double-free; follows existing cgpara usage. |
| FP vs SP | Unwinder needs a frame reference; SP at call site is valid. Aligning with x86_64 (RSP) keeps behaviour consistent. |

---

## 7. Verification checklist

- [x] **Override present:** `tcgaarch64` declares and implements `g_local_unwind`; for aarch64-win64 it does not fall through to `tcg.g_local_unwind` (plain jump).
- [x] **Single call site:** Only `system_aarch64_win64` triggers the unwinder call; other aarch64 systems get the default jump.
- [x] **RTL exists:** `_fpc_local_unwind` is in rtl/win64/seh64.inc, included by win64 system unit, built for aarch64-win64.
- [x] **Arguments:** Frame = SP, target = address of passed label (finally/break/continue target as set by ncpuflw).
- [x] **No return path:** No instructions after the call; RtlUnwindEx does not return.
- [x] **Flow control:** ncpuflw uses `g_local_unwind` only when `fc_unwind_exit` or `fc_unwind_loop` is set (try...finally / try...except with exit/break/continue), and passes the correct labels.

---

## 8. Conclusion

The fix is **correct and complete** for its scope:

1. **Root cause:** On aarch64-win64, the default `g_local_unwind` was a plain jump, so try...finally + exit did not invoke the Windows unwinder. The Bounty Boss test failed.
2. **Change:** For `system_aarch64_win64` only, `tcgaarch64.g_local_unwind` now calls `_FPC_local_unwind(current_SP, target_label_address)`, matching the x86_64-win64 design.
3. **RTL:** No change; the win64 RTL already provides `_fpc_local_unwind` and is used for aarch64-win64.
4. **ABI and semantics:** Frame and target are passed correctly; the OS runs the unwind and then jumps to the finally (or break/continue) target. No missing or incorrect edge cases were identified.

**Recommendation:** Treat the fix as ready to commit and push. Validate via the existing Bounty Boss test in CI (and, if desired, by inspecting generated assembly for a call to `_FPC_local_unwind` on the exit path).

---

*Document generated for the FPC Windows ARM64 bounty; analysis is based on the current code in `compiler/aarch64/cgcpu.pas`, `compiler/x86_64/cgcpu.pas`, `compiler/aarch64/ncpuflw.pas`, and `rtl/win64/seh64.inc`.*
