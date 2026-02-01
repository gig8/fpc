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

## 5. Related docs

- **In repo:** docs/AI-HELP-ARM64-UNWIND.md (context for AIs), docs/ARM64-WIN-UNWIND-RESEARCH.md (full research).
- **Vault (Dropbox/personal/Vault/Projects/fpc):** AI-RESPONSES-ARM64-UNWIND-REF.md (full AI and branch proposal catalog), AI-UNWIND-LEARNINGS-SUMMARY.md (Vault copy of this doc).
