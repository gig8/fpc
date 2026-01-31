# Bounty Boss fix: Local unwind for try...finally + exit on Windows ARM64

**Summary:** Try...finally with **exit** (or break/continue) from inside the try block failed on Windows ARM64 because the aarch64 code generator did not call the Windows unwind API. The fix is to implement `g_local_unwind` in the aarch64 backend so that it calls `_FPC_local_unwind(frame, target)` (RtlUnwindEx), matching the x86_64-win64 behaviour.

---

## 1. Problem statement

### 1.1 Bounty Boss test

The “Bounty Boss” test is the try...finally + exit case that the bounty foundation uses to validate Windows ARM64 SEH (Structured Exception Handling):

```pascal
procedure TestException;
begin
  try
    writeln('Entering try block...');
    exit;
  finally
    writeln('Success: Finally block executed!');
  end;
end;
begin
  TestException;
  writeln('Done.');
end.
```

**Expected behaviour:** The program prints “Entering try block…”, then “Success: Finally block executed!”, then “Done.”  
**Observed behaviour (before fix):** On Windows ARM64 the program crashed, hung, or produced wrong output; the finally block was not executed correctly.

### 1.2 Why it matters

On Windows, leaving a try block via **exit**, **break**, or **continue** must run the **finally** block (and any in-scope exception handlers) through the OS unwinder. The compiler must not simply jump to the finally label; it must call the runtime so that RtlUnwindEx runs and the kernel executes the appropriate unwind handlers. Otherwise the stack and control flow are inconsistent and the program can crash or hang.

---

## 2. Root cause

### 2.1 What x86_64-win64 does (correct)

In `compiler/x86_64/cgcpu.pas`, **tcgx86_64** overrides **g_local_unwind** for `system_x86_64_win64`:

- It calls **\_FPC_local_unwind(frame, target)** with two arguments:
  1. **frame:** current stack pointer (so the unwinder knows where we are).
  2. **target:** address of the target label (the finally block or exit point).

The RTL implements `_fpc_local_unwind` in `rtl/win64/seh64.inc` by calling **RtlUnwindEx(frame, target, …)**. The OS then runs the unwind logic and eventually transfers control to the target, so the finally block runs as required.

### 2.2 What aarch64-win64 did (wrong)

In `compiler/aarch64/cgcpu.pas`, **tcgaarch64** did **not** override **g_local_unwind**. The default implementation in `compiler/cgobj.pas` is:

```pascal
procedure tcg.g_local_unwind(list: TAsmList; l: TAsmLabel);
  begin
    a_jmp_always(list, l);
  end;
```

So for try...finally + exit, the aarch64 backend emitted a **plain JMP** to the finally label. That:

- Does not invoke the Windows unwinder.
- Does not run SEH/unwind handlers.
- Can leave the stack and runtime state inconsistent.

Hence the Bounty Boss test failed on Windows ARM64.

### 2.3 Evidence

- **Code:** `compiler/aarch64/ncpuflw.pas` sets `fc_unwind_exit` for try...finally and then calls `cg.g_local_unwind(current_asmdata.CurrAsmList, oldCurrExitLabel)`. So the backend’s `g_local_unwind` is the single place that decides whether we do a proper unwind or a plain jump.
- **Comparison:** x86_64-win64 overrides `g_local_unwind` and calls `_FPC_local_unwind`; aarch64-win64 did not override it, so it used the default jump. The RTL already provides `_fpc_local_unwind` for win64 (including aarch64-win64) in `rtl/win64/seh64.inc`; only the compiler call site was missing for aarch64.

---

## 3. Fix

### 3.1 Implementation

In **compiler/aarch64/cgcpu.pas**:

1. **Declaration (interface):**  
   `procedure g_local_unwind(list: TAsmList; l: TAsmLabel); override;`

2. **Implementation:**  
   For **system_aarch64_win64** only, override `g_local_unwind` to:
   - Look up the system procedure `_fpc_local_unwind`.
   - Prepare two parameters (current stack pointer, address of target label) according to the aarch64 Windows calling convention (e.g. x0, x1).
   - Emit a call to **\_FPC_local_unwind**.

   For all other targets, call **inherited** so that the default jump behaviour is kept.

This mirrors the existing logic in **compiler/x86_64/cgcpu.pas** (procedure **tcgx86_64.g_local_unwind**), adapted to aarch64 parameter passing and symbol names.

### 3.2 Code change (summary)

- **File:** `compiler/aarch64/cgcpu.pas`
- **Behaviour:**
  - If `target_info.system <> system_aarch64_win64` then `inherited g_local_unwind(list, l)` (plain jump).
  - Else:
    - `pd := search_system_proc('_fpc_local_unwind');`
    - Allocate two cgparas (paramanager.getcgtempparaloc for params 1 and 2).
    - First parameter: current stack pointer (NR_STACK_POINTER_REG).
    - Second parameter: address of label `l` (reference_reset_symbol(href, l, …)).
    - a_load_reg_cgpara / a_loadaddr_ref_cgpara, then a_call_name(list, '_FPC_local_unwind', false).
    - Free/done cgparas.

No RTL or linker script changes are required; `_fpc_local_unwind` is already implemented and linked for win64 (including aarch64-win64).

---

## 4. Verification

### 4.1 Test program

- **Source:** `docs/phase2-tests/arm64trap.pas` (Bounty Boss test).
- **Build:** Cross-compile with ppcrossa64 for `-Twin64` (aarch64-win64), then run the resulting executable on Windows ARM64 (e.g. GitHub Actions runner `windows-11-arm`).

### 4.2 Expected result after fix

- The program prints:
  - `Entering try block...`
  - `Success: Finally block executed!`
  - `Done.`
- Exit code 0.
- CI step “Run Bounty Boss test (try...finally + exit)” passes.

### 4.3 How to confirm the fix in generated code

- Compile **arm64trap.pas** with **-a** to get assembly.
- In the generated `.s` for the procedure that contains try...finally + exit, the path that implements “exit” should now contain a **call** to **\_FPC_local_unwind** (or the appropriate symbol) instead of only a direct branch to the finally label.
- Before the fix: that path was a single jump to the finally label.

### 4.4 CI

- The workflow **.github/workflows/win-arm64.yml** runs the Bounty Boss test as the last step of the Windows ARM64 job.
- A green run after the change demonstrates that try...finally + exit works on Windows ARM64 with the new `g_local_unwind` implementation.

---

## 5. References

- **Bug #66952** (and related “local unwind” work for try/finally Exit/Break/Continue).
- **x86_64 implementation:** `compiler/x86_64/cgcpu.pas`, procedure **tcgx86_64.g_local_unwind**.
- **RTL:** `rtl/win64/seh64.inc`, procedure **\_fpc_local_unwind** (RtlUnwindEx).
- **Try/finally codegen:** `compiler/aarch64/ncpuflw.pas` (taarch64tryfinallynode, fc_unwind_exit, call to g_local_unwind).
- **Unwind scope data:** `compiler/aarch64/cpupi.pas` (add_finally_scope, dump_scopes).

---

## 6. Three-perspective code review

Three “genius programmer” angles on whether the fix really makes sense.

### Brain 1: ABI and low-level correctness

**Question:** Are we calling the RTL with the right convention and the right values?

- **Signature:** RTL is `_fpc_local_unwind(frame, target: Pointer)`. We pass two parameters; paramanager.getcgtempparaloc for params 1 and 2 gives us the ABI locations (on ARM64 Windows: x0, x1 for first two pointer args). We load SP into para1 and the label’s address into para2. So we pass (current SP, address of target label). That matches the RTL and matches x86_64’s (RSP, target).
- **Frame = SP:** x86_64 explicitly passes RSP and has a TODO that “using RSP is correct only while the stack is fixed.” We pass NR_STACK_POINTER_REG. At the point we emit the call, we’re in the middle of the procedure (inside the try block, at the exit path). SP is the current stack pointer and identifies “this frame” for the unwinder. Passing SP is consistent with x86_64 and is correct for “unwind from here.”
- **Target = label address:** reference_reset_symbol(href, l, 0, 1, []) and a_loadaddr_ref_cgpara put the **address** of the label (the finally block) into the second parameter. RtlUnwindEx(TargetFrame, TargetIp, …) expects the IP to jump to after unwind. So we’re passing the right value.
- **Verdict:** The call convention and argument values are correct. The fix is ABI-sound.

### Brain 2: Control flow and SEH semantics

**Question:** Does calling RtlUnwindEx here give the right runtime behaviour?

- **Call site:** g_local_unwind is invoked from ncpuflw.pas when we have fc_unwind_exit (or fc_unwind_loop) and we’re leaving the try block via exit/break/continue. The label we pass is CurrExitLabel, which for try...finally is the **finally** label (set in taarch64tryfinallynode.pass_generate_code). So we’re saying: “unwind from current frame to the finally block.”
- **RtlUnwindEx semantics:** The OS unwinds from TargetFrame toward the target, running each frame’s unwind handlers (our .pdata / __FPC_specific_handler). Our procedure has a scope that includes the try and the finally; the handler will run the finally code and then control is transferred to TargetIp. So the OS will run the finally block and then jump to the address we passed — i.e. the finally label. That is exactly what we want.
- **No return:** RtlUnwindEx does not return to the caller; it transfers control to TargetIp. So we never “come back” from the call; the next instruction in the exit path is irrelevant. We don’t need to emit anything after the call.
- **Verdict:** The choice to call _FPC_local_unwind (RtlUnwindEx) with (SP, finally_label) matches the Windows SEH model and gives correct try...finally + exit semantics.

### Brain 3: Edge cases and robustness

**Question:** What could go wrong, and is the implementation robust?

- **search_system_proc:** If '_fpc_local_unwind' were missing, pd could be nil and getcgtempparaloc(list, pd, 1, para1) could fault. For win64 (including aarch64-win64), seh64.inc is included in the system unit and defines _fpc_local_unwind. So we’re safe as long as we only hit this path for system_aarch64_win64, which we guard with target_info.system <> system_aarch64_win64 → inherited. So we’re good.
- **FP vs SP:** On aarch64-win64 we use a frame pointer (FP); g_proc_exit restores SP from FP. One could ask: should we pass FP instead of SP? x86_64 passes RSP and the RTL comment doesn’t mention FP. The unwinder needs a frame identifier to walk the stack; SP at the call site is a valid “current frame” reference. Using SP keeps us consistent with x86_64 and is correct. If future FPC work changes “frame” meaning (e.g. dynamic allocas), both backends would need to be updated together; the TODO in x86_64 already notes that.
- **Parameter cleanup:** We do freecgpara and done in the same order as x86_64 (para2 then para1). No double-free; we’re consistent with the existing pattern.
- **Verdict:** No obvious edge-case bugs. The fix is consistent with x86_64, properly guarded by target check, and uses the same RTL that already works for win64.

**Overall:** All three perspectives agree: the fix is correct, ABI- and semantics-sound, and robust. It makes sense.

---

## 7. Document info

- **Title:** Bounty Boss fix: Local unwind for try...finally + exit on Windows ARM64  
- **Purpose:** White-paper style description of the problem, root cause, fix, and verification for the Bounty Boss (try...finally + exit) failure on Windows ARM64.  
- **Status:** Fix implemented in compiler/aarch64/cgcpu.pas; verification via arm64trap.exe and CI.
