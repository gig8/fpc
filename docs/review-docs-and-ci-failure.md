# Review: docs, analysis, and CI Cross-install failure

**Purpose:** Tie together our docs and analysis, and reason about the CI failure (Cross-install FPC aarch64-win64, exit code 2) after the g_local_unwind fix.

---

## 1. What the docs and analysis say

| Doc | Content |
|-----|--------|
| **next-steps-detailed.md** | Phase plan (1–7). Phase 1–3 done (cross-build, hello/trap, ppca64). **Phase 3b = Bounty Boss** (try...finally + exit) is “Next”. Diagnosing section: root cause = aarch64 had no `g_local_unwind` override (plain JMP); fix = implement it like x86_64, call `_FPC_local_unwind(SP, target)`. Build chain: ppcrossa64 (Linux) → RTL/units; Phase 3 builds ppca64 with ppcrossa64. |
| **bounty-boss-local-unwind-fix.md** | White paper: problem (Bounty Boss test), root cause (default `a_jmp_always`), fix (override in cgcpu.pas for aarch64-win64 only), RTL already has `_fpc_local_unwind` in seh64.inc. Three-perspective review: ABI, SEH semantics, edge cases — all OK. |
| **fix-unwind-metadata-analysis.md** | Rigorous analysis: fix location (cgcpu.pas 2210–2237), parity with x86_64, call site (ncpuflw, label = finally), RTL contract (seh64.inc, no CPU guard — present for aarch64). Verification checklist and conclusion: fix is correct. |
| **ci-arm64-plan.md** | CI strategy (GitHub for windows-11-arm), caching, no submodule. Checklist: workflow in place, cross-build → artifact → Windows run. |

**Unanimous:** The g_local_unwind change is correct. RTL provides `_fpc_local_unwind` for aarch64-win64 (seh64.inc, no CPU conditional). No RTL change required.

---

## 2. What’s going on: CI failure

**Observed:** [Run](https://github.com/gig8/fpc/actions/runs/21540638738/job/62074495043) fails in **Cross-build (Linux → aarch64-win64)** at step **“Cross-install FPC aarch64-win64”** with **Process completed with exit code 2**.

**Context:**

- That step runs only when **FPC cross-build cache misses** (`if: steps.cache_fpc.outputs.cache-hit != 'true'`).
- Cache key includes `hashFiles('compiler/**', 'rtl/**', ...)-v2`. The g_local_unwind change is under `compiler/**`, so the key changed and the cache missed.
- So the failing run did a **full** `make crossinstall` (no restored compiler/RTL).

**So:** The failure is “make crossinstall” (effectively `make install CROSSINSTALL=1`) exiting with 2. We do **not** have the actual log (GitHub shows “Sign in to view logs”). So we’re inferring.

---

## 3. Hypotheses for exit code 2

### A) Our change breaks the RTL build (e.g. missing `_fpc_local_unwind` during system compile)

- **Idea:** When ppcrossa64 compiles the **system** unit (rtl/win64/system.pp → seh64.inc), some code path might trigger `g_local_unwind` (e.g. try...finally + exit). We’d call `search_system_proc('_fpc_local_unwind')`. If the system unit is still being compiled and the symbol isn’t in the table yet, `search_system_proc` can call `message1(cg_f_unknown_compilerproc,...)` and then dereference a nil sym → internal error / crash → make exit 2.
- **Check:** In seh64.inc there is no try...finally with **exit**; the `exit` usages are plain “leave procedure” in exception handlers. So **normal** compilation of the system unit should **not** call `g_local_unwind`. So this is **plausible only** if some other RTL unit or an unexpected path has try...finally+exit and is compiled before or without a visible `_fpc_local_unwind`. **Verdict:** Possible but not proven; would need the real error message.

### B) Install / path mismatch (no compiler in expected place)

- **Idea:** `make install CROSSINSTALL=1` might install the cross-compiler under `INSTALL_PREFIX` (e.g. `$RUNNER_TEMP/fpc_install/bin/`) and **not** leave a copy at `compiler/ppcrossa64`. Later steps (and cache) expect `compiler/ppcrossa64` and `compiler/ppca64`. If the Makefile doesn’t put binaries there, “Cross-install” could still succeed but a **later** step (e.g. “Compile Phase 2 tests”) would fail; the annotation might point at the wrong step, or make might report exit 2 from a dependent target.
- **Verdict:** Possible. next-steps and the workflow assume ppcrossa64 ends up at `compiler/ppcrossa64` after a full build; the Makefile’s install layout for cross would need to be checked.

### C) Unrelated make failure (tools, env, disk)

- **Idea:** Exit 2 could be a generic make failure: missing tool (llvm-mingw, host FPC), path not set, or a transient error. Our change only affects code generation for aarch64-win64; building the **compiler** (ppcrossa64) is done by the **host** FPC; our code runs only when **ppcrossa64** is compiling user/RTL code for aarch64-win64.
- **Verdict:** Possible. Without the log we can’t rule it out.

---

## 4. What we know from code

- **`_fpc_local_unwind` for aarch64:** It **is** there. In rtl/win64/seh64.inc (lines 410–415) the procedure is **not** inside any `{$ifdef CPUX86_64}`; it’s compiled for both x86_64-win64 and aarch64-win64. So “_fpc_local_unwind is not there for arm” is **false** — the RTL is fine.
- **`search_system_proc`:** In symtable.pas, if the symbol isn’t found it calls `message1(cg_f_unknown_compilerproc,s)` and then does `result:=tprocdef(tprocsym(srsym).procdeflist[0])`. If `srsym` is nil, that dereferences nil. So we never “return nil” safely; we either get a procdef or we error and then crash. So if we ever call `g_local_unwind` in a context where `_fpc_local_unwind` isn’t in the system unit yet, we’d get a compiler error/crash.

---

## 5. Recommendations

1. **Get the real failure:** Run the same `make crossinstall` locally (same env: CPU_TARGET=aarch64, OS_TARGET=win64, FPC, BINUTILSPREFIX, CROSSOPT, INSTALL_PREFIX) or open the failed job log when signed in. The last 20–50 lines usually show the actual error (e.g. “Error: unknown compilerproc” or a make recipe failure).
2. **Optional defensive guard:** In `tcgaarch64.g_local_unwind`, if we want to harden against “system proc not found” (e.g. during weird RTL build order), we could add:  
   `if not assigned(pd) then begin inherited g_local_unwind(list, l); exit; end;`  
   after `pd := search_system_proc('_fpc_local_unwind');`  
   But `search_system_proc` doesn’t return nil today — it messages and then dereferences, so we’d only get this if FPC is changed to return nil. So this is optional.
3. **CI: preserve log on failure:** Add a step that runs on failure and dumps the last N lines of the build log (or uploads the log as an artifact) so we can see the exact error without signing in.
4. **Docs:** Keep next-steps-detailed.md and the analysis docs as-is; they correctly describe the fix and that `_fpc_local_unwind` is present for aarch64. Add a short “CI: Cross-install failure” note in next-steps pointing to this review and to “get the job log / run make crossinstall locally”.

---

## 6. Root cause (from log)

**Actual error (from user-provided log):**
```
sysutils.pp(659,7) Fatal: Unknown compilerproc "_fpc_local_unwind". Check if you use the correct run time library.
```

- **What happens:** When compiling **rtl/win/sysutils.pp** (line 659 = `exit` inside try...finally), the backend calls `search_system_proc('_fpc_local_unwind')`. The system unit (system.ppu) is loaded, but **`_fpc_local_unwind` is not in the .ppu**.
- **Why:** FPC only writes **registered** (i.e. "used") symbols to the .ppu. When the **system** unit is compiled, nothing in it references `_fpc_local_unwind`; only other units (e.g. sysutils) need it when they use try...finally+exit. So the procsym was never registered and never written to system.ppu.
- **Fix (RTL):** In **rtl/win64/seh64.inc**, add a constant that references `@_fpc_local_unwind` so the symbol is used when compiling the system unit and thus registered and written to system.ppu. Then backends that call `search_system_proc('_fpc_local_unwind')` when compiling sysutils (or any unit with try...finally+exit) will find it.

### Diagnostic when you see sysutils.pp(659,7) Fatal: Unknown compilerproc "_fpc_local_unwind"

1. **Check whether system.ppu exports the symbol:**  
   `strings <path>/system.ppu | grep -i fpc_local_unwind`  
   (Path = e.g. `fpc_install/lib/fpc/3.3.1/units/aarch64-win64/rtl/system.ppu`.)  
   If the output is empty, the system unit did not export `_fpc_local_unwind`; ensure rtl/win64/seh64.inc references it (var initializer and/or init block) so it is registered and written to the .ppu.

2. **CI:** The workflow step **"Diagnose system.ppu for _fpc_local_unwind (sysutils.pp:659)"** runs when the FPC cache misses and prints whether system.ppu contains the symbol and shows the sysutils.pp context (lines 655–665: the try...finally + exit block).

3. **Context:** sysutils.pp line 659 is an `exit` inside a try...finally (GetFinalPathNameByHandle / CreateFile block). That code path triggers the aarch64 backend’s `g_local_unwind`, which looks up `_fpc_local_unwind` via `search_system_proc`.

## 7. Short summary

| Question | Answer |
|----------|--------|
| Is the g_local_unwind fix correct? | Yes; docs and analysis agree. |
| Is `_fpc_local_unwind` there for aarch64? | Yes; in rtl/win64/seh64.inc, no CPU guard. |
| Why did CI fail at Cross-install? | sysutils.pp(659) Fatal: Unknown compilerproc "_fpc_local_unwind". |
| Root cause | Only if some compiled code (e.g. RTL) triggers `g_local_unwind` before `_fpc_local_unwind` is visible; seh64.inc did not’t have try...finally+exit, so not obviously. |
| Fix | Compiler: register procsym when parsing `@proc` (pexpr.pas). RTL: init block assigns `fpc_local_unwind_export_ref := @_fpc_local_unwind` so that line is parsed and triggers registration. |

---

## 8. Security impact of the global fix (register on @proc)

**Question:** Does registering every procsym when we parse `@procedure_name` make things less secure?

**Answer: No meaningful security regression.**

- **What the fix does:** Any unit that contains `@some_procedure` in its code now has `some_procedure` written to that unit's .ppu (so the compiler can resolve it when compiling other units that use this one).
- **Before:** A procedure that was *only* referenced by address (e.g. in an init block) was not registered, so it was *missing* from the .ppu. That didn't "hide" it for security; it was a bug that caused "Unknown compilerproc" when another unit (e.g. sysutils) needed to resolve it from the system unit.
- **Exposure:** The .ppu is an internal compiler format used for compilation and linking. Putting a symbol in the .ppu doesn't add a new way for untrusted code to call it; the linker and runtime don't change. Other units can only reference what their *source code* references. We're just making the compiler record "this unit uses this procedure by address" correctly.
- **Conclusion:** We're fixing incorrect *omission* of a symbol, not exposing something that was intentionally hidden. No new attack surface.

---

## 9. x86_64 vs aarch64: same code path, why did we see it on aarch64?

**Entry point for needing _fpc_local_unwind**

1. We compile a unit that contains **try...finally** with **exit** (or break/continue) — e.g. **sysutils.pp** line 659.
2. Codegen (ncpuflw.pas / nx64flw.pas) emits **g_local_unwind(list, finally_label)**.
3. **g_local_unwind** (x86_64/cgcpu.pas or aarch64/cgcpu.pas) runs only for **win64** (`system_x86_64_win64` or `system_aarch64_win64`). It calls **search_system_proc('_fpc_local_unwind')**.
4. **search_system_proc** looks up in **systemunit** — the in-memory symtable for the **system** unit, which was **loaded from system.ppu** when we started compiling the current unit (e.g. sysutils).
5. If **system.ppu** did not contain `_fpc_local_unwind` when it was *written*, then **systemunit** doesn't have it → **message1(cg_f_unknown_compilerproc, '_fpc_local_unwind')** → Fatal.

So the **failure point** is: when we *wrote* **system.ppu** (during "compile system.pp"), we only wrote symbols that were **registered**. The only reference to `_fpc_local_unwind` was in the **init block** ("fpc_local_unwind_export_ref := @_fpc_local_unwind"). The init block's node tree is **not** walked in **buildderefimpl**, so that procsym was never registered and never written to system.ppu. That is **independent of target**: same source (rtl/win64/system.pp + seh64.inc), same write path, same bug for **both** x86_64-win64 and aarch64-win64.

**Why x86_64 often "works"**

- **Same code path:** For a **full** RTL build from source (e.g. `make crossinstall` with cache miss), both targets use the same flow: compile system.pp → write system.ppu (without _fpc_local_unwind) → compile sysutils.pp → load system.ppu → try...finally+exit → search_system_proc → not found → Fatal. So in principle **x86_64-win64 would fail the same way** with a compiler that doesn't register on @proc.
- **Why we see it on aarch64:** Your workflow does a **full** cross-build (Linux → aarch64-win64) with cache miss, so you always rebuild the RTL and hit this path.
- **Why x86_64 might not:** (1) Many x86_64 Windows users use **pre-built** FPC binaries; that system.ppu was built by the FPC team (possibly with another compiler/version or process). (2) Full "from scratch" RTL build for x86_64-win64 may be less common. (3) The bug may have been hit for x86_64 too and fixed or worked around elsewhere. So it's about **how** people build, not a different code path for x86_64.

**Why we see it on our setup (Linux + llvm-mingw)**

- We build on **Linux** and cross-compile to aarch64-win64 using **llvm-mingw**. For that target there is no pre-built RTL in tree, so we **always** do a full RTL build (compile system.pp, then sysutils.pp, …). So we **always** hit the path that looks up `_fpc_local_unwind` and fails. The bug is in the compiler (not registering on @proc); Linux and llvm-mingw are why we're always on the code path that exposes it.
- **aarch64 "worked" (build completed) before** because we had not yet added the `g_local_unwind` override for aarch64-win64 — the backend used a plain JMP, so we never called `search_system_proc('_fpc_local_unwind')`. Once we added the correct `g_local_unwind` (to fix Bounty Boss), we started needing the symbol and hit the pre-existing bug.
- **x86_64** would hit the same bug on a full from-source RTL build; many x86_64 Windows users use pre-built FPC, so they don't see it.

**Conclusion:** The **entry point** (try...finally+exit → g_local_unwind → search_system_proc) and the **bug** (init block not walked → symbol not in system.ppu) are the **same** for x86_64-win64 and aarch64-win64. Our fix (register when parsing @proc) fixes the root cause for **both**.
