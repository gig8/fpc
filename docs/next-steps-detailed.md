# Detailed next steps – Windows aarch64 bounty

Step-by-step plan with checkpoints, verification, and contingencies. Re-checked for order, dependencies, and bounty coverage.

---

## Where we are

| Phase | Status | Next |
|-------|--------|------|
| 1 – Cross-build in WSL | [x] Done | – |
| 2 – Validate binaries & SEH | [x] Done | – (hello/trap run on Windows arm64 via CI; trap printed "Caught: The Unwind Trap") |
| 3 – Native ppca64.exe | [x] Done | – (CI builds ppca64, stages it, Windows job runs ppca64 -iV) |
| 3b – Bounty Boss test | [ ] **Next** | Fix try...finally + exit on Windows arm64 so arm64trap.exe passes; then CI fully green. If CI fails at **Cross-install FPC aarch64-win64** (exit 2), see **docs/review-docs-and-ci-failure.md** and get the job log or run `make crossinstall` locally. |
| 4 – Self-hosting (cycle) | [ ] | Run make cycle on Windows arm64 |
| 5 – Lazarus | [ ] | Build Lazarus with toolchain |
| 6 – Shell ext / WinRE | [ ] | Build & test shell extension, WinRE if required |
| 7 – Upstream | [ ] | PR, sponsor comment, FPC acceptance |

---

## Bounty requirements (checklist)

- [x] FPC produces **pure arm64** Windows binaries (not arm64ec)
- [ ] **Lazarus** compiles with the toolchain
- [ ] Toolchain works to **rebuild projects**
- [ ] **Shell extensions** load as pure arm64 in File Explorer’s explorer.exe
- [ ] Other scenarios (e.g. **Windows Recovery Environment**) as specified
- [ ] Changes **accepted by FPC developers** and **in FPC trunk**
- [ ] **Pull request** and patches published for testing
- [ ] **Sponsor comment** in all modified units (client name, website, GitHub fork link)

---

## Phase 1: Complete cross-build in WSL

- [x] **Phase 1 done**

**Goal:** `make crossinstall` finishes so we have a working `ppcrossa64` plus aarch64-win64 RTL/units.

### 1.1 Run crossinstall (no `-ClvLLVM`)

- [x] Run `make crossinstall` with correct flags (no `-ClvLLVM`, BINUTILSPREFIX, CROSSOPT)

```bash
cd ~/Projects/gig8/fpc   # or your FPC source dir
make clean
make crossinstall -j$(nproc) \
  CPU_TARGET=aarch64 \
  OS_TARGET=win64 \
  FPC=/usr/bin/fpc \
  BINUTILSPREFIX=aarch64-w64-mingw32- \
  CROSSOPT="-FD/opt/llvm-mingw/bin" \
  INSTALL_PREFIX=~/Projects/gig8/fpc_install
```

### 1.2 Checkpoint

- [x] `ppcrossa64` exists (build dir or install; e.g. `compiler/ppcrossa64` or `.../lib/fpc/3.3.1/ppcrossa64`)
- [x] `$(INSTALL_PREFIX)/lib/fpc/$(version)/units/aarch64-win64/` contains RTL (system.ppu, rtl/, rtl-objpas/, packages)

### 1.3 If Phase 1 fails

| Symptom | Likely cause | Action |
|--------|---------------|--------|
| Linker “undefined reference” or “cannot find -l…” | Missing lib path or wrong CRT | Add `-Fl/opt/llvm-mingw/…` (lib dir) to CROSSOPT or check rtl/win64 Makefile |
| Assembler “unknown directive” or “invalid instruction” | Wrong triple / asm syntax | Confirm BINUTILSPREFIX invokes llvm-mingw’s clang; check agcpugas triple for win64 |
| “Unit not found: system” or path errors | Unit path not set for target | Ensure INSTALL_PREFIX is used consistently; run from FPC source root |
| Still “Illegal parameter” | Leftover -ClvLLVM somewhere | Search Makefile, .cfg, env for ClvLLVM and remove |

---

## Phase 2: Validate binaries and SEH

- [x] **Phase 2 done**

**Goal:** Confirm we produce valid PE/COFF arm64 and catch SEH issues early (before cycle/Lazarus).

### 2.1 Hello world

- [x] Create `hello.pas` (in `docs/phase2-tests/`)
- [x] Compile with `-XPaarch64-w64-mingw32-` and unit paths; produce `hello.exe`
- Compile (use **-XPaarch64-w64-mingw32-** so the assembler/linker are found; llvm-mingw uses that prefix, not `aarch64-win64-`):
  ```bash
  export PATH=/opt/llvm-mingw/bin:$PATH
  ppcrossa64 -Twin64 -XPaarch64-w64-mingw32- -Fu$(INSTALL_PREFIX)/lib/fpc/3.3.1/units/aarch64-win64/rtl -Fu.../rtl-objpas -FE. -FD/opt/llvm-mingw/bin -ohello.exe hello.pas
  ```
  (Adjust unit path to match your install.)

### 2.2 Checkpoint – PE is arm64

- [x] Run `aarch64-w64-mingw32-objdump -p hello.exe` → **file format coff-arm64**

### 2.3 Exception trap (SEH stress)

- [x] Create `trap.pas` with `{$mode objfpc}`, try/except, `raise Exception.Create('The Unwind Trap')`
- [x] Compile `trap.exe`; compile with `-a` → `trap.s`
- [x] Inspect `trap.s`: `.pdata`/`.xdata`, unwind, `__FPC_specific_handler` present
- [ ] (Optional) Compare unwind with [Microsoft ARM64 PCS](https://docs.microsoft.com/en-us/cpp/build/arm64-windows-abi-conventions) (stack alignment, KNONVOLATILE_CONTEXT_POINTERS 80 bytes)

### 2.4 Checkpoint – run on Windows arm64 (or defer)

- [x] Run `hello.exe` and `trap.exe` on Windows arm64 (GitHub Actions `windows-11-arm`); trap printed “Caught: The Unwind Trap”
- [x] CI workflow (`.github/workflows/win-arm64.yml`) runs cross-build on Linux, then runs hello/trap on Windows arm64; step passes

### 2.5 Has the UNWIND/SEH bug been fixed?

We don’t know for certain. Phase 2 only proved that **one** SEH case works: a simple try/except with `raise` in a nested procedure (trap.exe printed “Caught: The Unwind Trap”). Trunk may already include fixes (e.g. the Jan 2026 “local unwind” MR for try/finally Exit/Break/Continue). The **real** stress test is **make cycle**: the compiler compiling itself uses many more exception paths and recursion. So we’re **ready to try** Phase 3 (build ppca64) and Phase 4 (make cycle); if cycle crashes, we may still hit SEH or other bugs and need to fix them (e.g. in `cgobj.pas`).

### 2.6 If Phase 2 fails (SEH)

- **Crash in trap or wrong unwind in .s:** Focus on `compiler/aarch64/cgobj.pas` (e.g. `WriteUnwindInfo`), stack layout, and alignment. Compare FPC’s .s with clang-generated .s for a similar C try/except.
- **Bug #66952** and recent “local unwind” MR (try/finally Exit/Break/Continue) are the same area; align fixes with trunk.


### 2.7 Bounty Boss test (try...finally + exit)

- **Goal:** arm64trap.exe (try...finally + exit) must run on Windows arm64 and print "Success: Finally block executed!" and "Done." CI runs it last; when it fails, we diagnose and fix.

---

## Diagnosing Bounty Boss (try...finally + exit)

When arm64trap.exe fails on Windows arm64, use this to find the cause and fix.

### Step 1: Capture the failure mode

- **Where:** Run arm64trap.exe on Windows arm64 (download artifact from CI or build locally with ppcrossa64).
- **What to record:**
  - Exit code (e.g. 0, 1, or crash/hang).
  - Stdout: does it print "Entering try block..."? "Success: Finally block executed!"? "Done."?
  - Stderr: any message?
  - If it crashes: address or exception type if visible.
- **CI:** The "Run Bounty Boss test" step already prints output and fails with a clear message; check the job log for the exact output.

### Step 2: Generate and inspect assembly

- **On Linux (WSL or CI):** Compile arm64trap.pas with `-a` to get assembly:
  ```bash
  ppcrossa64 -Twin64 -XPaarch64-w64-mingw32- -Fu$UP/rtl -Fu$UP/rtl-objpas -FD/path/to/llvm-mingw/bin \
    -a -FE. -oarm64trap.exe docs/phase2-tests/arm64trap.pas
  ```
  This produces `arm64trap.s`. Inspect:
  - `.seh_proc` / `.seh_endproc` and `.seh_handler __FPC_specific_handler` (unwind scope).
  - `.seh_handlerdata` and scope records (SCOPE_FINALLY / SCOPE_IMPLICIT: try start, try end, finally handler).
  - The code path for **exit**: do we emit a **plain JMP** to the finally label, or a **call** to an unwind helper?
- **Compare with working case:** trap.pas (try/except) works; diff `trap.s` vs `arm64trap.s` for the procedure that contains try/finally and the exit path.

### Step 3: Compare with x86_64-win64 (working)

- **x86_64-win64:** In `compiler/x86_64/cgcpu.pas`, `g_local_unwind` is overridden for `system_x86_64_win64`: it calls `_FPC_local_unwind(frame, target)` (two args: current stack frame, target label). The RTL implements this in `rtl/win64/seh64.inc` with `RtlUnwindEx(frame,target,...)` so the OS runs finally blocks during unwind.
- **aarch64-win64:** In `compiler/aarch64/cgcpu.pas` there is **no** override of `g_local_unwind`. The default in `compiler/cgobj.pas` is `a_jmp_always(list,l)` — a plain jump to the finally label. So we never call the Windows unwind API; the runtime never runs the finally in the “correct” way for SEH, and the program can crash, hang, or print wrong output.

### Step 4: Root cause and fix

- **Root cause:** For try...finally + exit (or break/continue), the aarch64 backend emitted a **plain JMP** to the finally label instead of calling **RtlUnwindEx** (via `_FPC_local_unwind`). So local unwind for finally was not implemented for aarch64-win64.
- **Fix (compiler):** Implement `tcgaarch64.g_local_unwind` in `compiler/aarch64/cgcpu.pas` for `system_aarch64_win64`, mirroring `tcgx86_64.g_local_unwind`: call `_FPC_local_unwind(SP, target)` (current frame pointer and target label). The RTL already provides `_fpc_local_unwind` in `rtl/win64/seh64.inc`; the compiler just had to emit the call for aarch64.
- **Fix implemented:** See **docs/bounty-boss-local-unwind-fix.md** (white paper: problem, root cause, implementation, verification). Code change: `compiler/aarch64/cgcpu.pas` — override `g_local_unwind` for `system_aarch64_win64` to call `_FPC_local_unwind(SP, target)`.
- **Check:** Recompile arm64trap.pas, run on Windows arm64; expect "Success: Finally block executed!" and "Done."; CI “Run Bounty Boss test” should pass.
- **References:** Bug #66952; “local unwind” MR; `compiler/aarch64/ncpuflw.pas`; `compiler/aarch64/cpupi.pas`; **docs/bounty-boss-local-unwind-fix.md**.

### Optional: CI artifact for assembly

- Add a step in the crossbuild job (optional): compile arm64trap.pas with `-a`, upload `arm64trap.s` (or the whole phase2-tests dir) as an artifact so you can inspect the generated unwind without a local Windows arm64 run.

---

## Build chain: what we have vs what we’re building

- **We have (Phase 1–2):** **ppcrossa64** = cross-compiler. It **runs on Linux** (WSL or CI) and **produces** Windows arm64 binaries (.exe, .dll). We built it on Linux with the host FPC (e.g. `fpc` from apt). So we did **not** build a compiler that runs on Windows arm64 yet.
- **Phase 3:** Use ppcrossa64 to **compile the FPC compiler source** for target aarch64-win64. The **output** is **ppca64** = a Windows .exe that **runs on** Windows arm64. So ppcrossa64 (parent, on Linux) **produces** ppca64 (child, for Windows arm64). One more “generation”: we’re building the native compiler from the cross-compiler.
- **Phase 4 (make cycle):** Take ppca64.exe to Windows arm64 and run **make cycle**: ppca64 **compiles the FPC source again** and produces a **new** compiler binary. That proves the compiler can compile itself (self-hosting). So: Linux ppcrossa64 → ppca64 (Windows) → make cycle on Windows → new ppca64. No “child of a child” in name; it’s the same compiler, just proving it can reproduce itself on Windows arm64.

**Summary:** We built the cross-compiler on Linux (ppcrossa64). We have **not** yet built the native Windows arm64 compiler (ppca64). Phase 3 = build ppca64 using ppcrossa64. Phase 4 = run make cycle with ppca64 on Windows arm64.

---

## What is Lazarus and why it’s in the bounty

- **Lazarus** = the **IDE** for Free Pascal (like Delphi: visual designer, debugger, form designer). It’s a separate, big Pascal project that **depends on** the FPC compiler. The name is a “resurrection” reference (project rose from the earlier Megido effort).
- **Relation to this work:** The bounty says **“Lazarus itself must compile.”** So the **validation** is: our Windows arm64 toolchain (ppca64 + RTL/units) must be able to **build** the Lazarus IDE. If Lazarus builds and runs on Windows arm64, the compiler is considered production-ready for real projects.
- **Place in the plan:** **Phase 5** = build Lazarus with the (Phase 3/4) Windows arm64 compiler. So: Phase 3 (ppca64) → Phase 4 (make cycle) → Phase 5 (build Lazarus with that compiler). Lazarus is the “stress test” after self-hosting.

---

## ppca64 vs make cycle (clarification)

- **ppca64** = the **native Windows arm64 compiler binary** (e.g. `ppca64.exe`). It *runs* on Windows arm64 and compiles Pascal to Windows arm64 code. We **don’t have it yet**. We have **ppcrossa64** = cross-compiler (runs on Linux, produces Windows arm64 code).
- **Phase 3** = **produce ppca64**: use ppcrossa64 (on Linux/WSL or CI) to compile the FPC compiler source *for* target aarch64-win64. The *output* of that build is ppca64 (a Windows PE). So we *build* the native compiler using the cross-compiler.
- **make cycle** = the **self-hosting test**: on Windows arm64, you run the compiler (ppca64.exe) and tell it to compile the FPC source; it produces a new compiler binary. If that finishes without crashing, the compiler is “self-hosting.” **Phase 4** = run make cycle on Windows arm64 using the ppca64 we built in Phase 3.

So: **Phase 3 → get ppca64.exe. Phase 4 → run make cycle with it on Windows arm64.**

---

## Phase 3: Build native Windows arm64 compiler (bridge)

- [ ] **Phase 3** (next)

**Goal:** Use `ppcrossa64` (on WSL) to build the FPC compiler + RTL **for** aarch64-win64 and obtain the **Windows .exe** of the compiler (the one that will run on Windows arm64).

### 3.1 Produce the native compiler binary

- [ ] From FPC source root, build the compiler **for** aarch64-win64 using ppcrossa64 (output = Windows arm64 PE). EXENAME = **ppca64** (ppca64.exe on Windows).
- **Option A – build only the compiler:** From `compiler/` or the top-level Makefile, run the compiler build with `FPC=path/to/ppcrossa64`, `OS_TARGET=win64`, `CPU_TARGET=aarch64`, and the same BINUTILSPREFIX/CROSSOPT. The resulting binary (e.g. `compiler/ppca64` when built on WSL) is a **Windows PE** even though it has no .exe suffix on Linux; copy it to Windows as `ppca64.exe`.
- **Option B – install for target:** If the top-level `make install` with CROSSINSTALL=1 already produces a “target” compiler binary in the install tree, use that. Confirm where the aarch64-win64 compiler lands (e.g. `$(INSTALL_PREFIX)/bin/ppca64` or in a target-specific subdir).
- **Intent:** The **output** is a compiler that is a **Windows arm64** PE (name ppca64 or ppca64.exe). That file is the “native” FPC for Windows arm64.

### 3.2 Checkpoint

- [ ] Windows .exe (ppca64 / ppca64.exe) exists in build or install tree
- [ ] `objdump -p ppca64` → file format coff-arm64

### 3.3 If Phase 3 fails

- Link errors building compiler: same as Phase 1 (libs, CRT, CROSSOPT).
- “Cycle” or bootstrap confusion: ensure we are only **building for** aarch64-win64, not trying to run the new compiler on WSL (it’s a Windows binary).

---

## Phase 4: Self-hosting (make cycle on Windows arm64)

- [ ] **Phase 4**

**Goal:** Run the native compiler (from Phase 3) on a **Windows arm64** machine and complete `make cycle` so the compiler compiles itself.

### 4.1 Environment

- [ ] **Where:** Real Windows arm64 hardware, or QEMU Windows 11 arm64 VM, or **GitHub Actions** Windows arm64 runner
- [ ] **What to copy:** Native compiler .exe from Phase 3, aarch64-win64 RTL/units, FPC source (or minimal tree for cycle)

### 4.2 Run cycle

- [ ] On Windows arm64: `set FPC=C:\path\to\ppca64.exe` and `make cycle CPU_TARGET=aarch64 OS_TARGET=win64`
- [ ] **Checkpoint:** Cycle completes without crash; new compiler binary produced by arm64 compiler

### 4.3 If Phase 4 fails

- **Crash during cycle (e.g. in middle of compile):** Very often **SEH/unwind** (same as Phase 2). Fix unwind/.pdata in `cgobj.pas` (and related), then re-do Phase 1–3 and retry cycle.
- **Link or asm errors:** Same debugging as Phase 1/3 (toolchain, paths, BINUTILSPREFIX on Windows if using MinGW there).

---

## Phase 5: Lazarus

- [ ] **Phase 5**

**Goal:** Build **Lazarus** with the (fixed) aarch64-win64 toolchain.

### 5.1 Build Lazarus

- [ ] Use native Windows arm64 compiler (Phase 3 or 4) + RTL/units; follow Lazarus build docs for Windows arm64
- [ ] **Checkpoint:** Lazarus builds; IDE starts on Windows arm64; can open and rebuild a project

### 5.2 If Phase 5 fails

- Missing units or packages: add/fix aarch64-win64 in Lazarus/FPC packages.
- Crashes or runtime errors: back to SEH/RTL (Phase 2) and possibly debug info.

---

## Phase 6: Shell extensions and WinRE

- [ ] **Phase 6**

**Goal:** Satisfy bounty clause: “Shell extensions which would only load as pure arm64 in File Explorer’s explorer.exe” (and WinRE if required).

### 6.1 Shell extension

- [ ] Build small shell extension (DLL) with toolchain; ensure pure arm64 (objdump → coff-arm64)
- [ ] On Windows arm64, register and load in Explorer; **checkpoint:** Explorer loads without crash

### 6.2 WinRE

- [ ] If required: build and test minimal app in Windows Recovery Environment; document result

---

## GitHub Windows Arm64 runners and shell-extension CI (April 2025)

**Context:** As of April 2025, GitHub officially released **Windows Arm64 hosted runners** for all public repositories. Proving shell extensions in CI is now significantly easier: you can load, register, and test native Arm64 DLLs on a real Windows 11 Arm64 environment (the “Copilot+ PC” architecture) directly in the pipeline. In the past you had to run a Linux worker and “guess” if the binary was correct.

### Shell-extension CI strategy

To prove a shell extension works, it’s not enough to just compile it. You need to:

1. **Target the runner:** In `.github/workflows/*.yml`, use `runs-on: windows-11-arm` so the job runs on real Arm64 hardware.
2. **Smoke test – register and verify:** Register the DLL with `regsvr32 /s my_extension_arm64.dll`. If FPC messed up SEH or alignment, regsvr32 will hang or return non-zero because it can’t initialize the COM object. Then verify the CLSID exists in the registry (e.g. `Test-Path "HKCR:\CLSID\{YOUR-GUID}"`); fail the step if not found.
3. **Golden proof – SEH unwind tables:** For the $10k bounty, the foundation wants to see valid **Structured Exception Handling (SEH)** data. In CI you can use **dumpbin** (MSVC tools, often pre-installed on the Windows runner) to inspect the `.pdata` section:
   - `dumpbin /pdata my_extension_arm64.dll > unwind_tables.txt`
   - Assert that the output contains “Unwind Index” (or equivalent) so the binary has valid ARM64 unwind metadata.

### Why this “closes the loop” for the bounty

If you can point the FPC core team to a GitHub Action that:

- Compiles on Linux (using the current cross-build setup),
- Deploys the artifact to a `windows-11-arm` runner,
- Successfully registers the DLL without crashing,
- Passes an exception test (DLL handles try/except while registered),

then you have provided **concrete proof** that the backend is production-ready. A green checkmark on actual Arm64 silicon is hard to argue with.

### CI additions we use today

- **Already in workflow:** `runs-on: windows-11-arm` for the test job; run hello.exe, trap.exe, arm64trap (Bounty Boss), neontest; verify ppca64 -iV.
- **Added:** “Verify SEH unwind tables” step: run `dumpbin /pdata` on `trap.exe` (or another built PE) and check for unwind metadata; documents that our binaries have valid .pdata.
- **When we have a shell-extension DLL:** Add a job or step: regsvr32 the DLL, then verify CLSID in registry (see above).

---

## Phase 7: Upstream and bounty closure

- [ ] **Phase 7**

**Goal:** Get changes into FPC trunk and meet sponsor requirements.

### 7.1 Patches and PR

- [ ] Prepare patches (or branch) against **FPC trunk** (official GitLab)
- [ ] Open **merge request** / **pull request**; describe fixes (SEH/unwind, RTL/win64)
- [ ] Publish patches (mailing list or fork) for community testing

### 7.2 Sponsor comment

- [ ] In **every modified unit**, add sponsor comment: “This work was sponsored by [client]. See [website] and [GitHub fork URL].”
- [ ] Do before or as part of the MR

### 7.3 Acceptance

- [ ] FPC developers merge; “changes accepted by compiler developers” and “in Free Pascal trunk”

---

## Order and dependency check (re-check)

| Phase | Depends on | Rationale |
|-------|------------|-----------|
| 1 | – | Must have cross-compiler + RTL before any validation. |
| 2 | 1 | Need working ppcrossa64 and units to compile hello/trap. |
| 3 | 1 (and 2 recommended) | Need ppcrossa64 to produce the Windows .exe; SEH fix can come later but earlier is cheaper. |
| 4 | 3 | Need the Windows .exe to run cycle on Windows arm64. |
| 5 | 2 or 4 | Need a working compiler; self-hosting (4) is strongest proof, but Lazarus can be attempted after 2 if cycle is blocked. |
| 6 | 2 (or 4) | Need working toolchain; can parallel with 5. |
| 7 | 1–6 | All technical work and sponsor text before final MR. |

**Risks re-checked:**

- **SEH blocks 4 and 5:** Phase 2 explicitly validates SEH early so we don’t discover it only at cycle/Lazarus.
- **Phase 3 exact make target:** If “installbase” doesn’t produce the Windows .exe in the right place, we need to find the correct target (e.g. “compiler” for aarch64-win64 only) and document it in this plan.
- **No Windows arm64 hardware:** Phases 4, 5, 6 need Windows arm64; plan already mentions QEMU and GitHub Actions as alternatives.

---

## Immediate action list (where we are)

1. [x] Confirm Phase 1 checkpoints (ppcrossa64 + units).
2. [x] Run Phase 2.1–2.3 (hello, objdump, trap + .s inspection).
3. [x] Run hello/trap on Windows arm64 (CI); trap passed (“Caught: The Unwind Trap”).
4. [x] Phase 3 – build ppca64 with ppcrossa64; CI builds, stages, and verifies ppca64 -iV on Windows arm64.
5. [ ] **Next:** Fix Bounty Boss (arm64trap.exe try...finally + exit) so CI is fully green; then Phase 4 (make cycle).
6. [ ] Phase 4: make cycle on Windows arm64 (CI already has `windows-11-arm`).

---

## Bounty launch to-do (once CI is green)

Strategy: **Public–Private multi-stage launch** (see `docs/gemini-conversation-summary.md`). Order: Proof of Life (public) → Dark Byte (strategic) → Formal bounty (financial).

- [ ] **CI green:** Action passes (hello, trap, arm64trap/Bounty Boss, ppca64 verify). Pull artifact (arm64-exes), run Arm64Trap.exe locally if desired; capture screen/video.
- [ ] **Stage 1 – Proof of Life:** Post to Lazarus/FPC Windows/Arm64 forum: “Stabilized AArch64-Win64 with llvm-mingw; SEH and try...finally clearing. GitHub Action logs available.”
- [ ] **Stage 2 – Dark Byte:** Open “Arm64 Support” issue or targeted message on Cheat Engine GitHub; offer to test FPC Arm64 against CE codebase for driver-level exceptions.
- [ ] **Stage 3 – Formal bounty:** Submit patch to FPC GitLab with short report (before/after assembly, stack alignment, .pdata compliance); request $10k.
- [ ] **If CI is red:** Get the Fatal (or first real) error from the failed step; fix linker flags (e.g. **-Fl** path) or missing mingw lib; re-run and re-check logs.

---

## Re-check summary (plan validated)

- **Order:** 1 → 2 → 3 → 4 → 5/6 → 7. No phase can be done without its predecessor (except 5/6 in parallel after 4 or 2).
- **Bounty coverage:** All bounty items (pure arm64, Lazarus, toolchain, shell extensions, WinRE, trunk acceptance, PR, sponsor comment) are assigned to a phase.
- **SEH risk:** Phase 2 explicitly validates SEH (trap + .s inspection) so we don’t discover unwind bugs only at cycle or Lazarus.
- **Phase 3 clarity:** “Native” compiler = Windows arm64 PE produced by ppcrossa64; output name is ppca64 (ppca64.exe on Windows). Phase 3 may require building the compiler sub-tree for aarch64-win64 and taking that binary; exact make target is to be confirmed when Phase 1–2 are done.
- **Hardware:** Phases 4–6 need Windows arm64; plan allows QEMU or GitHub Actions if no real hardware.
- **Contingencies:** Each phase has an “If it fails” row or paragraph so we don’t block without a next action.

---

## Doc references

- **Strategy / WSL / SEH:** `docs/gemini-conversation-summary.md`
- **Plan and -ClvLLVM:** `docs/plan-win-aarch64.md`
- **This file:** `docs/next-steps-detailed.md`
- **Bounty Boss fix (white paper):** `docs/bounty-boss-local-unwind-fix.md` — problem, root cause, g_local_unwind implementation, verification.
