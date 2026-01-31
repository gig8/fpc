# CI for Windows arm64 testing – plan

**Goal:** Run tests (hello.exe, trap.exe, eventually `make cycle`) on **real Windows arm64** in CI so we don’t depend on local hardware.

---

## GitHub vs GitLab for arm64

| Platform        | Windows arm64 hosted runner | Notes |
|-----------------|-----------------------------|--------|
| **GitHub Actions** | Yes (officially GA April 2025) | Label `windows-11-arm`, free for public repos. Native arm64 (real Copilot+ PC–class hardware), no QEMU. |
| **GitLab.com**     | No                           | Windows hosted = `saas-windows-medium-amd64` only. GitLab Dedicated has arm64, not GitLab.com. |

**Conclusion:** For **running** Windows arm64 binaries in CI we use **GitHub Actions**. You can load, register, and test native Arm64 DLLs (e.g. shell extensions) on the runner; no more “guessing” from a Linux-built binary. GitLab CI can still do Linux jobs (e.g. cross-build on Linux for aarch64-win64).

### Shell-extension CI (when we have a DLL)

To prove a shell extension works in CI: (1) Use `runs-on: windows-11-arm`. (2) Register with `regsvr32 /s my_extension_arm64.dll` and verify the CLSID in the registry—if SEH/alignment is wrong, regsvr32 will hang or fail. (3) Use `dumpbin /pdata` (MSVC, often on the runner) to verify the binary has valid ARM64 unwind tables. See **docs/next-steps-detailed.md** § “GitHub Windows Arm64 runners and shell-extension CI (April 2025)”.

---

## Do we need a submodule or a second repo?

**No submodule and no “CI-only” repo.** Use a single repo with two remotes.

- **One repo** = this FPC tree (your fork / bounty branch).
- **Two remotes:**
  - **GitLab** = upstream FPC (e.g. `origin` → `freepascal.org/fpc/source`) for MRs and trunk.
  - **GitHub** = your fork (e.g. `github` → `gig8/fpc` or similar) so GitHub Actions can run.
- **Same branch** pushed to both: e.g. `feature/win-aarch64` on GitLab (for MR) and on GitHub (for CI).
- **Workflows** live in this repo under `.github/workflows/`; they run when you push to GitHub.

A **submodule** would mean “this repo includes another repo inside it” (e.g. FPC as a submodule in a “runner” repo). That doesn’t help here: we want CI **on** the FPC repo. A second repo that only mirrors for CI is possible but unnecessary: just add GitHub as a second remote and push the same branch.

---

## Repo layout (recommended)

- **Current:** `origin` → GitLab (`freepascal.org/fpc/source`).
- **Add:** GitHub remote, e.g. `github` → `github.com/gig8/fpc` (or your org/repo name).
- **Branches:** Work on `feature/win-aarch64` (or `develop`); push to both `origin` and `github`.
- **New dir:** `.github/workflows/` in this repo (only used when the repo is on GitHub).

No new repo “for CI only”, no submodule.

---

## What CI jobs to add

1. **Cross-build on Linux (optional, can stay GitLab)**  
   - Runner: Linux x86_64 (GitLab or GitHub).  
   - Steps: install llvm-mingw, host FPC; run `make crossinstall` for `CPU_TARGET=aarch64` `OS_TARGET=win64`.  
   - Artifact: `ppcrossa64` + aarch64-win64 units (or install tree).  
   - Proves: “our branch still cross-builds.”

2. **Run on Windows arm64 (GitHub only)**  
   - Runner: `windows-11-arm` (GitHub).  
   - Needs: either build the cross-compiler + RTL on a Linux job and pass artifacts, or (simpler) build natively on Windows arm64 (e.g. with a pre-built FPC or bootstrap).  
   - Steps: build or unpack compiler/RTL; compile hello.pas and trap.pas; run hello.exe and trap.exe; check trap prints “Caught: The Unwind Trap”. Later: run `make cycle`.  
   - Proves: “binaries run correctly on Windows arm64.”

Starting with (2) is enough to “setup the CI arm64 test”; (1) can be added later or stay on GitLab.

---

## Step-by-step (concrete)

1. **Create GitHub repo**
   - e.g. `github.com/gig8/fpc` (or your user/org).  
   - Can be empty; we’ll push our branch.

2. **Add GitHub remote**
   ```bash
   git remote add github git@github.com:gig8/fpc.git   # or HTTPS
   ```

3. **Add workflow file in this repo**
   - Create `.github/workflows/win-arm64.yml` (or similar) that:
     - Runs on `windows-11-arm`.
     - Checks out repo.
     - Installs/builds FPC for aarch64-win64 (option A: use your cross-built artifact from another job; option B: download a nightly or build from source on the runner).
     - Compiles `docs/phase2-tests/hello.pas` and `docs/phase2-tests/trap.pas` with the correct `-XP` and unit paths.
     - Runs `hello.exe` and `trap.exe`; asserts trap output contains “Caught: The Unwind Trap”.

4. **Push branch to GitHub**
   ```bash
   git push github feature/win-aarch64
   ```
   GitHub Actions runs the workflow. No submodule, no separate “CI repo”.

5. **Ongoing**
   - Push to `origin` (GitLab) for upstream MRs.  
   - Push to `github` for arm64 CI (or set up a mirror so every push to GitLab also pushes to GitHub).

---

## Summary

| Question | Answer |
|----------|--------|
| Arm64 CI only on GitHub? | For **Windows arm64** hosted runners, yes – use GitHub. GitLab.com doesn’t offer them. |
| Submodule? | No. One repo, two remotes. |
| Second repo? | Only as “GitHub fork” of this repo; same code, push same branch to GitHub so Actions can run. |
| Where do workflows live? | In this repo: `.github/workflows/` (e.g. `win-arm64.yml`). |

---

## Caching best practices (win-arm64 workflow)

- **Key = inputs that affect the output.** Each cache key must include everything that affects the cached paths (e.g. source hash for FPC, release id for llvm-mingw). See comments at top of `win-arm64.yml`.
- **Bump key when cache structure changes.** If you add/remove paths in the cache (e.g. we added `compiler/ppca64`), bump a suffix in the key (e.g. `-v6` → `-v7`) so old caches (saved without that path) are not restored. Otherwise you get a “hit” but missing files.
- **Verify after restore.** When a cache hit skips a build step, verify that the restored paths actually contain the expected files. The workflow has a “Verify FPC cache contents” step that runs only on cache hit and fails if `ppcrossa64`, `ppca64`, or `fpc_install/.../units/aarch64-win64` are missing.
- **No restore-keys for FPC.** We use an exact key (source hash + suffix) so we don’t restore a stale compiler/RTL. Partial matches would risk wrong binaries.
- **Why the cache can be incomplete:** The cache action saves at job end even when the job fails. If a run failed after crossinstall but before or during “Build native ppca64”, the saved cache has `ppcrossa64` and `fpc_install` but no `compiler/ppca64`. A later run with the same key restores that incomplete cache → “Verify FPC cache contents” fails. **Fix we use:** We now use restore-only plus save with `if: success()`, so we never save incomplete cache. Bump -vN only when you change cache paths or inputs.
- **Document invalidation in the workflow.** The top-of-file comments list what each key depends on and when to bump it.

**ppca64 vs ppca64.exe:** We want the Windows runner to get **ppca64.exe** so `ppca64.exe -iV` works reliably (output and exit code). Make produces the native Windows compiler as `ppca64` (no extension). We cache it as `compiler/ppca64`. For the artifact we stage it as **ppca64.exe** so the Windows job runs `ppca64.exe -iV`.

---

## Checklist (CI arm64 setup)

- [x] Create GitHub repo (`github.com/gig8/fpc`)
- [x] Add remote: `git remote add github git@github.com:gig8/fpc.git`
- [x] Add workflow: `.github/workflows/win-arm64.yml` (Linux cross-build → upload hello.exe/trap.exe → Windows arm64 runs them)
- [x] Push branch: `git push github feature/win-aarch64`
- [x] Linux job: cross-build FPC aarch64-win64, compile Phase 2 tests, upload artifact
- [x] Windows arm64 job: download artifact, run hello.exe and trap.exe; assert “Caught: The Unwind Trap”
-build FPC aarch64-win64, compile Phase 2 tests, upload artifact
- [x] Windows arm64 job: download artifact, run hello.exe and trap.exe; assert “Caught: The Unwind Trap”
