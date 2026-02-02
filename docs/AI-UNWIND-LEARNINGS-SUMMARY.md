# What we learned from the AIs (ARM64 unwind) – summary

**Purpose:** Synthesize AI responses (Gemini, Grok, Claude Sonnet, Gemini Pro) and branch experiments (feature/win-aarch64-opus45, win-aarch64-gpt52) into a single "what we learned and does it make sense" summary. This doc is in the repo so other agents can read it.

---

## 0. Review of agent-branch commits (win-aarch64-opus45, win-aarch64-gpt52)

### feature/win-aarch64-opus45 (Cursor / Opus)

Commits on top of feature/win-aarch64, in chronological order:

| Commit | Summary | What changed |
|--------|---------|---------------|
| **ebee79394d** | Fix CPUAARCH64 not defined during cross-compilation | **compiler/options.pas** (+144 lines). Adds target-based CPU macro definitions in `read_arguments`: when cross-compiling, defines CPUI386, CPUX86_64, **CPUAARCH64**, CPU64, etc. from `target_info.cpu` (using `systems.cpu_*`). Rationale: host macros only were set, so `{$ifdef CPUAARCH64}` in rtl/win64/seh64.inc was false during cross-build → ARM64 _fpc_local_unwind/RtlCaptureContext path was not compiled. |
| **0fd5467d9d** | Trigger CI | Workflow: reverted `branches` from `feature/win-aarch64*` to `[ develop, feature/win-aarch64, main ]` (no glob). |
| **195378d2ed** | CI: use glob pattern for feature/win-aarch64* branches | **.github/workflows/win-arm64.yml**: restored glob so workflow runs on feature/win-aarch64, feature/win-aarch64-opus45, feature/win-aarch64-gpt52, etc. |
| **0e080caab8** | Fix nested comment warning in options.pas | **compiler/options.pas** (4 lines): fixes a nested comment that triggered a compiler warning in the block added by ebee79394d. |

**Net proposal from opus45:** Define target CPU macros during cross-compilation so the ARM64 RTL path is built. Plus CI glob and a small options.pas cleanup.

### win-aarch64-gpt52 (GPT-5.2)

Commits on top of feature/win-aarch64:

| Commit | Summary | What changed |
|--------|---------|---------------|
| **cff49d8e14** | Docs: note CI trigger branch | **docs/AI-HELP-ARM64-UNWIND.md**: added one line under Current state: "**CI trigger branch:** `win-aarch64-gpt52` (baseline for new experiments)." |
| **99f61e3750** | Docs: date CI trigger branch | **docs/AI-HELP-ARM64-UNWIND.md**: one-line edit (e.g. date or wording of the CI trigger branch note). |

**Net proposal from gpt52:** Doc-only; record which branch is the baseline for experiments. No RTL or unwind code changes.

---

## 1. Does it make sense?

**Yes, with caveats.** The AIs converge on a small set of plausible causes and experiments; several ideas are consistent with what we already know (RtlUnwindEx overwrites context, Caller-SP vs Local-SP, TargetFrame semantics). One branch (Opus) surfaced a **different** kind of bug that could explain everything if true: the ARM64 unwind code might not be compiled at all when cross-building.

---

## 2. Cross-cutting story the AIs tell

| Idea | Who | Makes sense? |
|------|-----|---------------|
| **TargetFrame = FP (x29) not SP** | Gemini, Claude | **Partially.** ARM64 ABI uses x29 for frame chain; EstablisherFrame is often defined as Caller-SP in docs, but some runtimes use FP for frame identity. We currently pass EstablisherFrame (from RtlVirtualUnwind = Caller-SP). Trying FP as first arg to RtlUnwindEx is a low-cost experiment. |
| **Caller-SP vs Local-SP** | Gemini Pro | **Yes.** If RtlUnwindEx sets SP = TargetFrame (= Caller-SP) at restore, we're effectively "popped" to the caller's stack while PC is at the landing pad inside the function. First use of SP (e.g. `str x0,[sp]`) or ret would then fault. That matches our symptom. Fix: patch Sp in the context to **Local SP** (value at landing pad)—but we'd need the compiler to give us that value; we don't have it in the handler today. |
| **Patch Sp (and Fp) in handler** | Gemini (diagnostic), Gemini Pro (fix) | **Risky.** We already reverted Pc/Sp overwrite because dispatch.TargetIp/EstablisherFrame refer to the **current** frame, not the target. Patching Sp := EstablisherFrame in the handler would set Sp to the *current* frame's establisher, not the landing-pad frame's SP—so it could corrupt. Gemini Pro's "CorrectLocalSP" only works if we have the landing-pad frame's SP from somewhere (e.g. compiler). |
| **Bypass RtlUnwindEx → RtlRestoreContext only** | Grok | **Yes.** Already in our doc as "Minimal bypass." If we RtlCaptureContext + RtlVirtualUnwind once, set PC/Sp/ContextFlags, then call RtlRestoreContext ourselves (no RtlUnwindEx), we skip the OS unwind loop. Success ⇒ bug is inside RtlUnwindEx. Failure ⇒ bug in our context or EstablisherFrame. Clear diagnostic. |
| **16-byte alignment / .pdata** | Gemini | **Yes.** ARM64 requires 16-byte aligned SP. Wrong or inconsistent .pdata (e.g. stack adjustment not multiple of 16, or frame register mismatch) could yield bad SP after restore. Worth checking with dumpbin/llvm-objdump. |
| **STATUS_UNWIND_CONSOLIDATE** | Gemini Pro | **Maybe.** If the OS always overwrites our Sp with TargetFrame after the handler returns, the only way to control the final context might be CONSOLIDATE. That's a bigger change and needs verification against MSDN/behavior. |
| **Define target CPU macros when cross-compiling** | Opus (win-aarch64-opus45) | **Critical if true.** If, when we cross-build from e.g. x86_64 Linux to aarch64-win64, the compiler only defines *host* macros (CPUX86_64), then `{$ifdef CPUAARCH64}` in rtl/win64/seh64.inc is false and the ARM64 CONTEXT/unwind code is **not compiled** into the RTL. We'd be running the x86_64 or generic path on ARM64—undefined behavior and a perfect explanation for "nothing we do to the handler helps." Opus's change in compiler/options.pas defines target CPU macros from `target_info.cpu` during cross-compilation. **This should be verified first:** inspect the built RTL (e.g. whether ARM64 CONTEXT and _fpc_local_unwind ARM64 branch are present in the binary). If they're missing, Opus's fix is the top priority. |

---

## 3. What we learned (concise)

1. **Frame identity:** Multiple AIs say use FP (x29) or "correct" SP for TargetFrame or for the restored context. We use EstablisherFrame (Caller-SP) from RtlVirtualUnwind. Trying FP as the first argument to RtlUnwindEx is a simple experiment; patching Sp in the handler needs a **correct** value (landing-pad SP), which we don't have unless the compiler passes it.
2. **Caller-SP vs Local-SP:** Gemini Pro's explanation (RtlUnwindEx restores Caller-SP; landing pad expects Local-SP) is consistent with the crash and with our observation that PC is right but SP is wrong. The fix (patch Sp to Local-SP) requires a way to get Local-SP—e.g. compiler passes it, or we compute it—and we must not use the current frame's EstablisherFrame.
3. **Isolation test:** Bypassing RtlUnwindEx and calling RtlRestoreContext directly (Grok, and already in our doc) cleanly separates "our context setup" from "OS unwind behavior." Run this experiment if not already done.
4. **Cross-compilation macros (Opus):** The only proposal that explains "no amount of handler/context tweak helps": the ARM64 code path might not be in the build. Verifying whether CPUAARCH64 is defined when building the RTL for aarch64-win64 (and whether the ARM64 branches are present in the built object) is high priority. If they're absent, Opus's compiler/options.pas change belongs in the suite and should be applied (and the workflow/branch choices are independent).
5. **gpt52 branch:** No new unwind proposal; doc note only.

---

## 4. Suggested order of operations

1. **Verify Opus's hypothesis:** Confirm that when cross-building aarch64-win64 RTL, CPUAARCH64 is (or isn't) defined and that the ARM64 unwind/context code is (or isn't) in the built unit. If it isn't, add target CPU macro definitions (Opus's options.pas change) and re-run CI.
2. **Run bypass experiment:** In _fpc_local_unwind, after setting up ctx, call RtlRestoreContext(@ctx, nil) instead of RtlUnwindEx. Interpret result as in AI-HELP-ARM64-UNWIND.md.
3. **Try FP as TargetFrame:** In _fpc_local_unwind, pass ctx.Fp (or equivalent) as the first argument to RtlUnwindEx instead of EstablisherFrame. Low risk, quick test.
4. **If still broken:** Consider .pdata/.xdata check (alignment, frame register) and, only if we can supply a correct Local-SP, a handler patch of Sp; or investigate STATUS_UNWIND_CONSOLIDATE.

---

## 5. Integration status and next plan

**Integrated into feature/win-aarch64 (2026-02-01):**

- **opus45 options.pas fix:** Cherry-picked `ebee79394d` (target CPU macros for cross-compilation) and `0e080caab8` (nested comment fix). CI glob for `feature/win-aarch64*` was already on this branch. The RTL is now built with CPUAARCH64 (and other target macros) defined when cross-compiling to aarch64-win64.

**Additional debug (2026-02-01):** To diagnose which register is wrong at the landing pad and to confirm the "landing pad ~3MB from caller" observation:
- **_fpc_local_unwind** (FPC_DEBUG_WIN64_UNWIND): step 3 now logs `frame(compiler)`, `target`, `delta_target_caller` (target − caller Pc), and labels ctx.Pc as caller.
- **Handler:** "after patch" now logs Pc, Sp, Lr, Fp (not only ContextFlags).
- **arm64trap VEH:** logs **ContextAtFault** (Pc, Sp, Lr, Fp, ContextFlags) from the exception context so we see the actual register state at the fault. CI artifact and notice include this.

**CI run [21566529344](https://github.com/gig8/fpc/actions/runs/21566529344) (2026-02-01):**

- **VEH context at fault:** Pc=$00007FF608D5A760, Sp=$000000B4877FF680, Lr=$00007FF608A8B5B8, Fp=$000000B4877FFC50.
- **Interpretation:** PC is correct (landing pad = ExceptionAddress). LR is in image range (plausible return address). **Sp and Fp** are in a low range (0xB4877FFxxx) and are likely **Caller-SP / Caller-FP** (or wrong frame) rather than the **Local-SP / Local-FP** the landing pad expects—consistent with “RtlUnwindEx restores Caller-SP; first instruction `str x0,[sp]` faults.” Next: compare step 3 EstablisherFrame vs this Sp; try bypass (RtlRestoreContext) or supplying Local-SP.

**Later run (same branch, 2026-02-01) — full comparison:**

| Where | Sp | Fp |
|-------|-----|-----|
| **Step 1** (after RtlCaptureContext, inside _fpc_local_unwind) | $6A543FF400 | — |
| **Step 3 / 7** (we pass to RtlUnwindEx: EstablisherFrame = TestException's SP) | $6A543FF9E0 | $6A543FFA00 |
| **VEH at fault** (what RtlRestoreContext actually restored) | **$6A543FF400** | **$6A543FF9D0** |

- **Sp at fault ($6A543FF400) = Step 1 Sp** — i.e. **_fpc_local_unwind's** SP (the frame that called RtlUnwindEx). We passed **ctx.Sp = $6A543FF9E0** (EstablisherFrame). So the OS did **not** use our Sp; it restored the **capturing frame's** SP. That matches Nynaeve: RtlUnwindEx overwrites our context at entry; the context used for the final restore appears to have Sp (and Fp) from the wrong frame.
- **delta_target_caller = $2D8270** (~2.98 MB) — landing pad and caller are far apart in the image (same function, big try/finally).
- **frame(compiler) = EstablisherFrame = $6A543FF9E0** — they match; our context setup is consistent.
- **Conclusion:** The bug is in **what the OS restores**, not in our EstablisherFrame. Bypass experiment (call RtlRestoreContext ourselves with our ctx, no RtlUnwindEx) is the next step: we control the full context and should land with Sp=$6A543FF9E0.

**Answers to: (1) Can we fix it? (2) OS bug revert risk? (3) Sequencing?**

1. **Can we fix it and make it work?** We're trying: store target Sp/Fp in globals in _fpc_local_unwind before RtlUnwindEx; in the handler, patch ContextRecord.Sp and ContextRecord.Fp to those values (in addition to Lr/Fp). If the OS uses our patched ContextRecord for the final RtlRestoreContext, we should land with the right SP/FP. If the OS overwrites our patch after we return, we'll need the bypass or another approach.
2. **If it's an OS "bug", would it get reverted?** The behavior (RtlUnwindEx overwrites our context at entry; the context used for restore has the capturing frame's SP/FP) matches Nynaeve's x64 analysis and may be by design. So it's not a Windows bug we're working around; we're adapting to the API: we can't control the context RtlUnwindEx builds, so we patch it in the handler. A future OS update could change how/when the context is applied; our patch is "correct" for the contract (we supply target Sp/Fp so the restored context is consistent). Unlikely to be "reverted" unless the OS stops calling our handler or changes ContextRecord semantics.
3. **Is it possible we're sequencing commands wrong?** Our sequencing (RtlCaptureContext → RtlVirtualUnwind → set Pc/Sp/ContextFlags → RtlUnwindEx) matches longjmp-style usage. The issue isn't our order of calls; it's that RtlUnwindEx overwrites our context at entry, so the OS never uses our Sp/Fp for the final restore. Patching in the handler is the only place we can correct the context the OS will use.

**Fix attempt (2026-02-01):** In seh64.inc (ARM64): _fpc_local_unwind stores ctx.Sp and ctx.Fp in fpc_local_unwind_target_sp/fp before RtlUnwindEx; __FPC_specific_handler patches ContextRecord.Sp and ContextRecord.Fp to those values (when non-zero) on every unwind call. Debug: step 7 logs stored target_sp/target_fp; handler logs "after patch (Sp/Fp from target)". **Result:** Did not fix; at fault Sp still Step 1 Sp (see §5c attempt #1).

**Bypass experiment (2026-02-01):** When FPC_ARM64_UNWIND_BYPASS_RTLUNWINDEX is defined, _fpc_local_unwind calls RtlRestoreContext(@ctx, nil) instead of RtlUnwindEx. Finally blocks do NOT run; we jump straight to the landing pad. CI is built with this define for diagnostic: if we get "Done." + "LANDED at first instr" → our ctx is correct and the bug is in RtlUnwindEx.

**Bypass run (2026-02-01) — Sp/Fp correct, still fault:**

| Where | Pc | Sp | Fp | Lr |
|-------|-----|-----|-----|-----|
| **Step 7** (we pass to RtlRestoreContext) | $57A780 | $7F01BFFB00 | $7F01BFFB20 | $7FF77B2A2510 |
| **VEH at fault** (first exception C0000005) | $57A780 | $7F01BFFB00 | $7F01BFFB20 | $7FF77B2A2510 |

- Sp and Fp at fault **match** our ctx (EstablisherFrame and ctx.Fp). So **our constructed context is correct**; RtlRestoreContext did restore Sp/Fp as we set them.
- We still get **STATUS_ACCESS_VIOLATION at the landing pad** ($57A780). So the fault is **not** “wrong SP/FP”; with correct SP/FP the first instruction at the landing pad still faults.
- Possible causes: (1) first instruction at landing pad is not `str x0,[sp]` but uses another address (e.g. wrong base reg or offset); (2) memory at [Sp] not writable (guard page, wrong region); (3) another register (e.g. X0 or address-forming reg) not restored by RtlRestoreContext and wrong at landing pad; (4) alignment or .pdata mismatch.
- Second VEH: ExceptionCode=$C00000AA, ExceptionAddress=$D7B2 (bogus) — cascade after we patched and continued from the first fault.
- **Next:** Disassemble the instruction at the landing pad (e.g. `llvm-objdump -d` on arm64trap.exe, or CI step); check whether [Sp] is writable; confirm which operand faults (address vs. data).

**Artifact analysis (2026-02-01, optimized + unoptimized):**

- **Both builds:** Bypass runs; at fault Sp/Fp **match** step 7 (our ctx). Same crash: ACCESS_VIOLATION at landing pad. Optimized and unoptimized behave the same.
- **Landing pad (from disasm):** Right after `bl _FPC_local_unwind` we have: **nop** (100002510), **bl fpc_get_output** (100002514), **str x0,[sp]** (100002518). So first instruction at pad is nop, then call, then store. The fault is likely on **str x0,[sp]** (first store to [SP]).
- **frame(compiler) = EstablisherFrame** in logs → same value; using compiler frame for ctx.Sp wouldn’t change the value.
- **Hypothesis:** [SP] may be in a **guard page** (first touch commits or faults). Try touching the stack at frame before RtlRestoreContext so the page is committed.

**Next plan (in order):**

1. ~~Run CI~~ Done. Inspect artifact for step 3 (frame vs EstablisherFrame, delta_target_caller) and confirm Sp at fault matches EstablisherFrame.
2. **If crash persists:** Run the **bypass experiment** (step 2 in §4): in `_fpc_local_unwind`, after setting up `ctx`, call `RtlRestoreContext(@ctx, nil)` instead of `RtlUnwindEx`. If we land correctly → bug is inside RtlUnwindEx. If we still fault → bug is in our context/EstablisherFrame setup.
3. **If bypass still faults:** Inspect **landing pad vs caller** (opus45 finding: landing pad address ~3MB from caller PC is suspicious). Consider .pdata/.xdata for TestException and _fpc_local_unwind (`llvm-objdump -u arm64trap.exe`), and whether we can pass or compute **Local-SP** for the landing-pad frame.
4. **Optional low-risk test:** Try **FP as TargetFrame** (step 3 in §4) in a short-lived branch; opus45 already tried this and got INVALID_UNWIND_TARGET, so only if we have new evidence it might help.

---

## 5a. Verifying the cross-compile fix (is the ARM64 path actually in the build?)

**Problem opus45 identified:** During cross-build (e.g. Linux x86_64 → aarch64-win64), the compiler used *host* macros only, so `{$ifdef CPUAARCH64}` in rtl/win64/seh64.inc was **false** and the ARM64 block was not compiled. We’d get the `{$else}` branch: `RtlUnwindEx(frame, target, nil, nil, @ctx, nil)` with **uninitialized ctx** — undefined behavior.

**How we know the fix worked:**

1. **CI output:** If the ARM64 path were missing, we would not see `[FPC_DEBUG_WIN64_UNWIND] step 0` through `step 7` — those are inside the `{$ifdef CPUAARCH64}` block. Run [21566529344](https://github.com/gig8/fpc/actions/runs/21566529344) shows steps 0–7 and "UNWIND: patch context", so the ARM64 _fpc_local_unwind and ARM64 handler are present and running.
2. **system.ppu:** CI already checks `strings system.ppu | grep _fpc_local_unwind` (symbol exists). That does not prove the *ARM64* implementation is in the unit; the proof is (1) at runtime.
3. **Optional CI check:** Assert that arm64trap output contains `[FPC_DEBUG_WIN64_UNWIND] step 0` so we fail the job if someone reverts the options.pas fix and the wrong path is used.

**Conclusion:** With the options.pas fix, the RTL is built with target CPU macros; the ARM64 path is compiled and we see it run. The remaining bug (Sp/Fp wrong at landing pad) is **not** “wrong code path” — it’s context/SP semantics (Caller-SP vs Local-SP or OS overwriting our context).

---

## 5b. Pascal try/finally vs .NET, C++, Go — what’s special and what we can simplify

**Same as others:** All use Windows SEH: RtlUnwindEx with a target frame and a context. EstablisherFrame = Caller-SP; .pdata/.xdata describe unwinding. C++/MSVC, .NET CoreCLR, and Go use the same model.

**What’s different for Pascal:** We don’t have **setjmp**. longjmp passes a context *saved at the setjmp site* (at the target). We **synthesize** the target-frame context: one RtlVirtualUnwind from _fpc_local_unwind to get the caller (TestException) frame, set PC := landing pad, Sp := EstablisherFrame. So we emulate “context at landing pad” without ever having been there. That’s valid if EstablisherFrame (Caller-SP) equals the SP the landing pad expects (Local-SP); in a single frame they should match unless the compiler uses a different SP at the landing pad.

**“Fancy” handler patching we added:** Because RtlUnwindEx **overwrites** our context at entry (Nynaeve) and the OS may not set CONTEXT_INTEGER when building the restore context, we patch in `__FPC_specific_handler`: set ContextFlags to full user, copy Lr and Fp from the OS context into ContextRecord. We do **not** touch Pc/Sp (dispatch.TargetIp/EstablisherFrame are for the *current* frame, not the target). So our patch only reinforces Lr/Fp; it cannot fix a wrong SP if the OS restores Caller-SP.

**Simplification options (if we’ve fixed the cross-compile):**

1. **Minimal .NET/C++ style:** In _fpc_local_unwind only: RtlCaptureContext, RtlVirtualUnwind once, set ctx.Pc := target, ctx.Sp := EstablisherFrame, ContextFlags := full user, call RtlUnwindEx. No handler patch. We already tried this and it crashed (LR/FP or SP wrong). So “minimal” alone isn’t enough without fixing SP/LR/FP.
2. **Bypass RtlUnwindEx (diagnostic):** Call RtlRestoreContext(@ctx, nil) instead of RtlUnwindEx. If it works → bug is inside RtlUnwindEx (e.g. OS overwrites Sp with TargetFrame). If it still faults → bug is our ctx (e.g. ctx.Sp := EstablisherFrame is wrong; we need Local-SP from the compiler).
3. **Compiler passes Local-SP:** Have the compiler pass the SP *at the landing pad* (or a second “frame” value) to _FPC_local_unwind so we set ctx.Sp to that instead of EstablisherFrame. Then we might not need handler patching for SP (and we’d match what the landing pad expects).

**Summary:** Pascal doesn’t require a different *SEH* model; we just don’t have setjmp so we synthesize context. The “fancy” Lr/Fp patch is a workaround for OS not restoring INTEGER; it doesn’t fix SP. Next: try bypass, then if needed get Local-SP from the compiler.

---

## 5c. Attempts log (do not repeat)

Track each fix attempt so we don't go backwards. **Do not repeat** failed attempts.

| # | Date | What we did | Result | Do not repeat |
|---|------|-------------|--------|----------------|
| 1 | 2026-02-01 | **Handler patches Sp/Fp from stored target:** _fpc_local_unwind stores target_sp/target_fp; handler sets ContextRecord.Sp/Fp to those values (when <>0). | **Did not fix.** Handler "after patch" showed Sp=$9E2DBFF810, Fp=$9E2DBFF830; at fault VEH still had **Sp=$9E2DBFF230** (Step 1 Sp). OS overwrites our patch or uses a different context for the final restore. | Do not rely on handler Sp/Fp patch alone; OS does not use it for restore. |
| 2 | (opus45) | **FP as TargetFrame:** pass ctx.Fp as first arg to RtlUnwindEx. | INVALID_UNWIND_TARGET. | Do not use FP as TargetFrame. |
| 3 | (earlier) | **Pc/Sp from dispatch.TargetIp/EstablisherFrame in handler.** | Wrong: those refer to current frame, not target. Reverted. | Do not overwrite Pc/Sp in handler from dispatch. |
| 4 | 2026-02-01 | **Bypass RtlUnwindEx:** call RtlRestoreContext(@ctx, nil) instead. | **Proved our ctx is correct:** at fault Sp=$7F01BFFB00, Fp=$7F01BFFB20 (match our ctx). Still fault at landing pad → RtlUnwindEx restores wrong context; with our ctx, Sp/Fp are right but first instruction still faults (stack slot? page?). | Use bypass as proof; next: why does first instr fault with correct Sp? |
| 5 | 2026-02-01 | **Guard-page touch:** before RtlRestoreContext (bypass path), read PByte(frame)^ so the stack page may be committed. | Pending CI. If [SP] was in a guard page, the touch commits it and landing-pad str x0,[sp] may succeed. | Run CI; if no fix, try compiler Local-SP. |

---

## 5d. Checklist: things to try (date | result)

Use this list so we don’t go in circles. Update the “Result” column when done.

| # | What to try / verify | Date | Result |
|---|----------------------|------|--------|
| 1 | **Cross-compile fix:** ARM64 path in built RTL (options.pas target macros) | 2026-02-01 | Done. CI shows step 0–7 and handler UNWIND patch → ARM64 path present. |
| 2 | **system.ppu contains _fpc_local_unwind** (CI step) | (in workflow) | Done. Step "Diagnose system.ppu" checks this. |
| 3 | **VEH ContextAtFault:** which register wrong at landing pad | 2026-02-01 | Done. Sp and Fp wrong (Caller-SP/Caller-FP); Pc and Lr OK. |
| 4 | **Compare step 3 EstablisherFrame vs VEH Sp at fault** (artifact) | 2026-02-01 | Done. **Sp at fault ≠ EstablisherFrame.** Sp at fault = Step 1 Sp (_fpc_local_unwind’s SP); we passed Sp = EstablisherFrame ($6A543FF9E0). OS restored wrong frame’s SP. |
| 5 | **Bypass RtlUnwindEx:** call RtlRestoreContext(@ctx, nil) instead (FPC_ARM64_UNWIND_BYPASS_RTLUNWINDEX) | 2026-02-01 | Done. **Our ctx is correct:** at fault VEH showed Sp=$7F01BFFB00, Fp=$7F01BFFB20 (match step 7 ctx). We still fault at landing pad → bug is in RtlUnwindEx (OS restores wrong context); landing-pad fault with correct Sp/Fp may be stack slot / first instruction / page. |
| 6 | **Minimal path (no handler patch):** remove Lr/Fp patch, only _fpc_local_unwind setup | — | Pending. See if crash changes (e.g. LR now wrong too). |
| 7 | **Compiler passes Local-SP (or second frame):** use as ctx.Sp instead of EstablisherFrame | — | Pending. Requires compiler change. |
| 8 | **FP as TargetFrame:** pass ctx.Fp as first arg to RtlUnwindEx | (opus45) | Tried. INVALID_UNWIND_TARGET. |
| 9 | **.pdata/.xdata:** llvm-objdump -u arm64trap.exe for TestException, _fpc_local_unwind | — | Pending. Check alignment, frame register. |
| 10 | **CI assert:** output contains "step 0" so we fail if ARM64 path missing | 2026-02-01 | Done. Workflow now emits notice "ARM64 unwind path verified (step 0 present)". |
| 11 | **Handler patches Sp/Fp from stored target** | 2026-02-01 | Done. **Did not fix.** At fault Sp still Step 1 Sp; OS overwrites or uses different context. See §5c attempt #1. |
| 12 | **Bypass run: Sp/Fp at fault vs step 7** | 2026-02-01 | Done. **Match.** Our ctx is correct; fault at landing pad with correct Sp/Fp → next: disasm at landing pad, [Sp] writable, other reg. |
| 13 | **Disassemble instruction at landing pad** (CI step + artifact) | 2026-02-01 | Done. CI step "Disassemble landing pad" runs extract_unwind_target.py; snippet in arm64-exes/landing_pad_instructions.txt. See §5e. |

---

## 5e. CI landing-pad disasm, debug build, and “does anyone else have this?”

**Landing-pad disassembly in CI**

- **Step:** "Disassemble landing pad (arm64trap) – Bounty Boss" (crossbuild job).
- **What it does:** Runs `extract_unwind_target.py` on `arm64-exes/arm64trap_disasm.txt` (from `llvm-objdump -d`). The script finds the `bl _FPC_local_unwind` call, resolves the target (landing-pad) address from the preceding adrp/add, and prints the **next 6 instructions at that address**.
- **Artifact:** Full output (including "resolved target = 0x...") is saved to **arm64-exes/landing_pad_instructions.txt**, which is part of the `phase2-arm64-exes` artifact.
- **How to use:** Download the artifact, open `landing_pad_instructions.txt`. Compare "resolved target" (hex) with runtime "target=$..." from FPC_DEBUG_WIN64_UNWIND in arm64trap_output.txt. The listed instructions are the landing pad; the first one is the one that faults with correct Sp/Fp — check whether it is `str x0,[sp]` or uses another base/offset.

**Debug build**

- **Current:** arm64trap is compiled with **-g** (debug info) so disassembly has symbols where available; codegen is unchanged.
- **Optional -O-** (no optimizations): Would change codegen (different layout, possibly simpler landing pad). Not enabled by default; add to the arm64trap compile line if we want to compare optimized vs unoptimized behavior.

**Does anyone else have this problem?**

- **FPC:** No public reports found of "try...finally...exit crash on ARM64 Windows" or similar. Worth reporting to FPC bugtracker (gitlab.com/freepascal.org/fpc/source/-/issues) once we have a fix or a clear repro.
- **Go:** Go’s Windows ARM64 runtime documents that **LR is not filled** unless ContextFlags includes CONTEXT_INTEGER (we already set that). Go’s SEH stack unwinding for Windows/ARM64 was still incomplete as of 1.20 (e.g. WinDbg/stack walk issues). So we’re not the only ones hitting ARM64 Windows unwind/context quirks; no direct “same bug” report found.
- **MSDN / Stack Overflow:** RtlUnwindEx/RtlRestoreContext and STATUS_UNWIND_CONSOLIDATE are documented; no hit for “landing pad fault with correct SP” on ARM64.

---

## 6. **RESOLVED** – Root Cause and Fix (2026-02-02)

### Root Cause: Internal Linker ADRP/ADR Relocation Bug

The crash was **not** caused by SEH/unwind logic, SP/FP mismatches, or context corruption. The real issue was in the **internal COFF linker** (`compiler/ogcoff.pas`): ARM64 `ADRP` and `ADR` instruction relocations were computed incorrectly, causing the **landing pad address** to be wrong by ~3MB.

**The bug:** When processing `IMAGE_REL_ARM64_PAGEBASE_REL21` (ADRP) and `IMAGE_REL_ARM64_REL21` (ADR) relocations, the 21-bit immediate encoded in the instruction was treated as a **page count** to be added *after* converting addresses to page numbers. This is wrong.

**Correct behavior (per LLVM lld, Go linker, .NET CoreCLR):** The 21-bit immediate is a **byte offset** that must be added to the symbol's absolute address *before* computing the page difference.

### Diagnostic Evidence

- **Runtime debug logs** showed `target_offset=$00000000002DA780` (~3MB from image base) while `caller_offset=$0000000000002510` (~9KB). The landing pad should be ~600 bytes from the caller, not 3MB away.
- **`extract_unwind_target.py`** in CI confirmed the resolved target was `0x1002da780` (wrong) instead of `0x100002780` (correct).
- **After fix:** target resolved to `0x100002780`, which is 628 bytes from the call site—correct.

### The Fix

**File: `compiler/ogcoff.pas`**

1. **ADRP (`RELOC_ADR_PREL_PG_HI21`)** – around line 1494:
   ```pascal
   // Extract the 21-bit signed immediate (addend) from instruction
   addend:=((address shr 29) and $3) or (((address shr 5) and $7ffff) shl 2);
   // Sign extend: bit 20 is sign bit (not 21!)
   if (addend and (1 shl 20)) <> 0 then
     addend:=addend or (not ((int64(1) shl 21) - 1));
   // LLVM-style: add addend to symbol address FIRST (as bytes),
   // then compute page difference
   relocval:=relocval + addend;  // target_addr = symbol_addr + addend
   relocval:=(relocval shr 12) - ((objsec.mempos+objreloc.dataoffset) shr 12);
   // Encode page difference into instruction
   address:=address and not (($3 shl 29) or ($7ffff shl 5));
   address:=address or ((relocval and $3) shl 29) or (((relocval shr 2) and $7ffff) shl 5);
   ```

2. **ADR (`RELOC_ADR_PREL_LO21`)** – around line 1483:
   ```pascal
   // Extract the 21-bit signed immediate (addend)
   addend:=((address shr 29) and $3) or (((address shr 5) and $7ffff) shl 2);
   // Sign extend: bit 20 is sign bit (not 21!)
   if (addend and (1 shl 20)) <> 0 then
     addend:=addend or (not ((int64(1) shl 21) - 1));
   // Add addend to symbol address, then compute byte difference from PC
   relocval:=relocval + addend;
   relocval:=relocval - (objsec.mempos + objreloc.dataoffset);
   // Encode byte difference into instruction
   address:=address and not (($3 shl 29) or ($7ffff shl 5));
   address:=address or ((relocval and $3) shl 29) or (((relocval shr 2) and $7ffff) shl 5);
   ```

**File: `compiler/options.pas`** (prerequisite fix)

- Define target CPU macros (`CPUAARCH64`, etc.) during cross-compilation so the ARM64 RTL code path is built.

### Result

- **Test output:** `Entering try block...` → `Success: Finally block executed!` → `Done.`
- **CI status:** ✅ `success` on `feature/win-aarch64-opus45`

### Why This Bug Existed

The ARM64 COFF relocation code in FPC's internal linker appears to have been written without full testing on Windows ARM64. The ADRP/ADR instructions and their relocations are ARM64-specific (no equivalent on x86_64), so this bug would never manifest on x86_64. The original code had:
- Sign extension checking bit 21 instead of bit 20 (off-by-one)
- Treating the immediate as a page count instead of a byte offset

Both issues combined to produce wildly incorrect target addresses for any PC-relative address load that wasn't exactly page-aligned.

---

## 7. Related docs

- **In repo:** docs/AI-HELP-ARM64-UNWIND.md (context for AIs), docs/ARM64-WIN-UNWIND-RESEARCH.md (full research).
- **Vault (Dropbox/personal/Vault/Projects/fpc):** AI-RESPONSES-ARM64-UNWIND-REF.md (full AI and branch proposal catalog), AI-UNWIND-LEARNINGS-SUMMARY.md (Vault copy of this doc).
