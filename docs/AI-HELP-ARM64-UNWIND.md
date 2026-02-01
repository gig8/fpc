# AI help request: FPC ARM64 Windows try/finally crash

**Repository:** https://github.com/gig8/fpc  
**CI (Windows ARM64):** https://github.com/gig8/fpc/actions/workflows/win-arm64.yml — **check the latest run** after the most recent push for logs and test results. CI builds with `FPC_DEBUG_WIN64_UNWIND` defined, so step and handler logs appear in the arm64trap run; on failure, `arm64trap_output.txt` is uploaded as an artifact.  
**Branches:** `develop` (upstream baseline), `bounty-submission` (clean fix attempt for bounty), `feature/win-aarch64` (current: full debug + all attempted fixes).

**Test program:** `arm64trap` — minimal try/exit/finally; source is generated in the workflow (see `.github/workflows/win-arm64.yml`). Bounty criterion was “output contains **finally**”; we achieve that but then **crash before** the code after the try-finally runs (e.g. never reach "Done." or "LANDED at first instr"). We are fixing this **post-finally** restore so the process reaches the landing pad and exits cleanly.

---

## Goal

Fix a **crash on ARM64 Windows** when `exit` (or break/continue) is used inside a `try...finally` block. The `finally` block runs, but execution then faults at the **landing pad** (first instruction after the try-finally) with **STATUS_ACCESS_VIOLATION**. Same pattern works on x86_64 Windows and other targets.

**Success looks like:** program prints begin, try, finally, then runs the first instruction at the landing pad and continues (e.g. "Done.") and exits with code 0. We currently fault on the **first instruction at** the landing pad (PC correct; SP or FP wrong).

---

## Stack

- **Compiler** (`compiler/aarch64/cgcpu.pas`): emits `_FPC_local_unwind(frame, target)` with `frame = current SP`, `target = landing-pad address`.
- **RTL** (`rtl/win64/seh64.inc`): `_fpc_local_unwind` uses `RtlCaptureContext`, one `RtlVirtualUnwind` to get caller frame and EstablisherFrame (Caller-SP), sets `ctx.Pc := target`, `ctx.Sp := EstablisherFrame`, sets ContextFlags (full user: CONTROL+INTEGER+FLOATING_POINT+ARM64, clear DEBUG/UNWOUND_TO_CALL), then `RtlUnwindEx(FrameToUse, target, nil, nil, @ctx, @UnwindHistory)`.
- **OS:** unwinds frames, runs finally blocks via `__FPC_specific_handler`, then should restore to our context (PC=landing pad, SP=EstablisherFrame, LR/FP/X19–X28 valid). **RtlRestoreContext** restores only what **ContextFlags** request.

**Observed:** VEH reports fault at **landing-pad address**; first memory access there is `str x0,[sp]` — so PC is right but **SP (or FP) is wrong**. Epilogue needs correct FP and LR for `ret`.

---

## What we know

1. **RtlUnwindEx overwrites** the context we pass (see Nynaeve x64 analysis). The context finally given to RtlRestoreContext is **OS-built during unwind**, not our pre-filled one. So our ContextFlags on entry can be ignored.
2. **Go runtime** (defs_windows_arm64.go): on Windows 10 ARM64, **LR is not filled** unless ContextFlags includes CONTEXT_INTEGER in addition to CONTEXT_CONTROL. We set full user context (CONTROL+INTEGER+FLOATING_POINT+ARM64) everywhere we can.
3. **RtlCaptureContext** on ARM64 did not fill LR when ContextFlags was not set before the call. We now set **CONTEXT_FULL_USER_ARM64** before every RtlCaptureContext (in `_fpc_local_unwind` and `fpc_RaiseException`).
4. **EXCEPTION_TARGET_UNWIND** is not set when our handler is called during unwind (CI shows only EXCEPTION_UNWINDING). So we **patch context on every unwind call** in `__FPC_specific_handler`: we set `dispatch.ContextRecord^.ContextFlags` to full user (and clear UNWOUND_TO_CALL and DEBUG_REGISTERS), and we **copy Lr and Fp from the OS-provided context into `dispatch.ContextRecord^`** so RtlRestoreContext has valid values if it respects our flags. We do **not** overwrite Pc/Sp in the handler — in the unwind path, dispatch.TargetIp and EstablisherFrame refer to the **current** frame being unwound, not the final target, so overwriting would corrupt the context.
5. **Landing pad:** NOP then `str x0,[sp]`; if SP is bad → access violation. Epilogue uses FP and LR; if either is wrong, `ret` or earlier insn can fault. A second VEH (e.g. ExceptionCode $C00000AA or low ExceptionAddress) is usually a cascade from bad LR/PC during exception dispatch.

---

## What we tried (concise)

- **develop / bounty-submission:** ARM64 SEH with single RtlVirtualUnwind + RtlUnwindEx(6-arg). No ARM64-specific ContextFlags; no handler patch. **Crashes.**
- **Set ContextFlags** (CONTROL+INTEGER+ARM64, then +FLOATING_POINT) before RtlUnwindEx and in handler only when EXCEPTION_TARGET_UNWIND → still crash (handler never saw TARGET_UNWIND).
- **Patch context on every unwind** (not only TARGET_UNWIND) → still crash.
- **Reinforce Pc/Sp from dispatch.TargetIp / EstablisherFrame in handler** → wrong (those are for current frame); reverted.
- **Set ContextFlags before RtlCaptureContext** (so LR is filled in _fpc_local_unwind and in fpc_RaiseException) → step 1 now can show non-zero Lr; **still crash at landing pad.**
- **Handler:** only patch ContextFlags + reinforce Lr/Fp from OS context; do not touch Pc/Sp. **Current state** — still crashing in CI.

---

## Current state (feature/win-aarch64)

- **CONTEXT_FULL_USER_ARM64** used everywhere (capture, pre–RtlUnwindEx, handler patch). DEBUG_REGISTERS and UNWOUND_TO_CALL cleared for restore.
- **Handler:** on unwind, clear UNWOUND_TO_CALL and DEBUG_REGISTERS, OR in CONTEXT_FULL_USER_ARM64, write to `dispatch.ContextRecord^.ContextFlags`, and copy `context.Lr` and `context.Fp` into `dispatch.ContextRecord^`.
- **Debug:** `FPC_DEBUG_WIN64_UNWIND` logs steps 0–7 in _fpc_local_unwind and "UNWIND: patch context" / "after patch" in handler. arm64trap test has VEH printing ExceptionCode and ExceptionAddress.
- **CI:** builds FPC, runs arm64trap (and others). Latest run at link above; logs show whether handler ran and what Lr/Fp/ContextFlags were.

---

## Hypotheses still open

1. **OS overwrites context after handler returns** — we set ContextFlags and Lr/Fp on ContextRecord; RtlUnwindEx might overwrite them before RtlRestoreContext.
2. **RtlRestoreContext ignores CONTEXT_INTEGER** on this path (e.g. ARM64 unwind path restores only PC/SP).
3. **Wrong frame / EstablisherFrame** — we use EstablisherFrame from RtlVirtualUnwind; compiler passes current SP; if they differ (alignment/ABI), TargetFrame could be wrong.
4. **Unwind metadata** — .pdata/.xdata for TestException or _fpc_local_unwind wrong → RtlVirtualUnwind (inside RtlUnwindEx) could yield wrong SP/FP/LR for the “target” frame.
5. **Windows 10 ARM64 bug** — Go already documents CONTEXT quirk; possible further bugs in RtlUnwindEx/RtlRestoreContext.

---

## Useful next steps (for an AI or human)

1. **Inspect latest CI log** (workflow link above): confirm "UNWIND: patch context" and "after patch"; note ContextFlags and Lr/Fp. If Lr or Fp is 0 after patch, the OS didn’t fill integer/control state and our copy-back has nothing to reinforce.
2. **Experiment: use compiler’s `frame` as TargetFrame** — call RtlUnwindEx with no pre-unwind, only RtlCaptureContext + ContextFlags, and the compiler's `frame` (current SP) as first arg. If behavior changes, EstablisherFrame vs compiler frame matters. **Alternatively:** try having the compiler pass **x29 (FP)** instead of SP as the first argument to `_FPC_local_unwind` (hypothesis: unwinder may expect Caller-SP or FP for frame identity).
3. **Minimal bypass of RtlUnwindEx:** RtlCaptureContext + RtlVirtualUnwind once, set PC/Sp, ContextFlags, then call **RtlRestoreContext** ourselves (no RtlUnwindEx). If that lands and runs correctly, the bug is inside RtlUnwindEx’s use/overwrite of context or its call to RtlRestoreContext.
4. **On-device:** breakpoint at landing pad, inspect SP/FP/LR/x19 after “restore”; verify .pdata/.xdata for TestException and _fpc_local_unwind (e.g. `llvm-objdump -u arm64trap.exe`).

---

## Key files

- `rtl/win64/seh64.inc` — ARM64 CONTEXT flags, _fpc_local_unwind, __FPC_specific_handler, fpc_RaiseException.
- `docs/ARM64-WIN-UNWIND-RESEARCH.md` — full research, assembly notes, experiments, references (Go, MSDN, Nynaeve).
- `.github/workflows/win-arm64.yml` — CI: builds FPC, generates arm64trap.pas, compiles and runs arm64trap.exe; defines FPC_DEBUG_WIN64_UNWIND for RTL logs.

We need either a **code or configuration change** that makes the landing pad run without fault, or **concrete evidence** (e.g. which register is wrong, or OS version/behavior) to pursue an OS bug or alternate approach (e.g. different unwind strategy).
