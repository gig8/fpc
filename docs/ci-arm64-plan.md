# CI for Windows arm64 testing – plan

**Goal:** Run tests (hello.exe, trap.exe, eventually `make cycle`) on **real Windows arm64** in CI so we don’t depend on local hardware.

---

## GitHub vs GitLab for arm64

| Platform        | Windows arm64 hosted runner | Notes |
|-----------------|-----------------------------|--------|
| **GitHub Actions** | Yes (GA / public preview 2025) | Label `windows-11-arm`, free for public repos. Native arm64, no QEMU. |
| **GitLab.com**     | No                           | Windows hosted = `saas-windows-medium-amd64` only. GitLab Dedicated has arm64, not GitLab.com. |

**Conclusion:** For **running** Windows arm64 binaries in CI we use **GitHub Actions**. GitLab CI can still do Linux jobs (e.g. cross-build on Linux for aarch64-win64).

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

## Checklist (CI arm64 setup)

- [ ] Create GitHub repo (e.g. `github.com/gig8/fpc`)
- [ ] Add remote: `git remote add github git@github.com:gig8/fpc.git`
- [ ] Add workflow: `.github/workflows/win-arm64.yml` (stub added; replace “Setup FPC” placeholder with real steps)
- [ ] Push branch: `git push github feature/win-aarch64`
- [ ] Implement “Setup FPC” on Windows arm64 (download artifact from Linux cross-build, or install pre-built FPC, or bootstrap build)
- [ ] Uncomment “Compile Phase 2 tests” and “Run hello.exe / trap.exe” steps once FPC is available on the runner
- [ ] (Optional) Add Linux job to cross-build and upload artifact so Windows job downloads it

The repo already contains a **stub** `.github/workflows/win-arm64.yml` that runs on `windows-11-arm` and fails at “Setup FPC” until you implement it (no submodule or second repo).
