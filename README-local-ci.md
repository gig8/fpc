# Running CI Locally

This directory contains scripts to run the GitHub Actions workflow locally, using the exact same steps as defined in `.github/workflows/win-arm64.yml`.

## Quick Start

```bash
# Run the full CI workflow (uses cache if available)
./run-ci-locally.sh

# Force clean rebuild
./run-ci-locally.sh --clean --no-cache

# Just rebuild RTL after editing seh64.inc
make -C rtl clean OS_TARGET=win64 CPU_TARGET=aarch64
make -C rtl all OS_TARGET=win64 CPU_TARGET=aarch64 \
  FPC=/tmp/fpc_ci_runner/fpc_install/lib/fpc/3.3.1/ppcrossa64 \
  BINUTILSPREFIX=aarch64-w64-mingw32- \
  OPT="-FD/tmp/fpc_ci_runner/llvm-mingw/bin -dFPC_DEBUG_WIN64_UNWIND"
```

## Scripts

### `run-ci-locally.sh` (Recommended)

Runs the exact same steps as the GitHub Actions `crossbuild` job:

1. ✓ Install build tools and host FPC
2. ✓ Cache/install llvm-mingw
3. ✓ Restore FPC cross-build cache (ppcrossa64 + units + ppca64)
4. ✓ Cross-install FPC aarch64-win64 (if cache miss)
5. ✓ Ensure ppcrossa64 at compiler/
6. ✓ Diagnose system.ppu for _fpc_local_unwind
7. ✓ Compile Phase 2 tests (hello, trap, arm64trap, neontest)
8. ✓ Verify assembly patterns
9. ✓ Generate msgtxt.inc
10. ✓ Build native ppca64 (Phase 3)
11. ✓ Disassemble and dump unwind
12. ✓ Stage artifacts

**Advantages:**
- Uses the exact workflow logic
- Manages cache like GitHub Actions
- Produces identical artifacts
- Shows step-by-step progress with colors

**Usage:**
```bash
./run-ci-locally.sh              # Normal run (uses cache)
./run-ci-locally.sh --clean      # Clean build
./run-ci-locally.sh --no-cache   # Ignore cache, rebuild
```

### `local-ci-test.sh` (Alternative)

Simpler script for quick testing:

```bash
./local-ci-test.sh --skip-crossinstall  # Use existing compiler
./local-ci-test.sh --clean              # Full rebuild
./local-ci-test.sh --verbose            # Show all output
```

## What Gets Built

After running, you'll have:

```
/tmp/fpc_ci_runner/
├── llvm-mingw/                  # ARM64 Windows toolchain
├── fpc_install/                 # Installed FPC cross-compiler
│   └── lib/fpc/3.3.1/
│       ├── ppcrossa64           # Cross-compiler (Linux → Windows ARM64)
│       └── units/aarch64-win64/ # RTL units
└── crossinstall.log             # Build log

compiler/
├── ppcrossa64                   # Cross-compiler (copy)
└── ppca64                       # Native compiler (Windows ARM64 PE)

tests/phase2-tests/
├── hello.exe                    # Test programs
├── trap.exe
├── arm64trap.exe                # Bounty Boss test (with fix)
├── arm64trap_no_fix.exe         # Bounty Boss test (no fix)
├── neontest.exe
├── arm64trap.s                  # Assembly (with _FPC_local_unwind call)
└── arm64trap_no_fix.s           # Assembly (plain branch)

arm64-exes/                      # Staged artifacts (ready to copy to Windows)
├── *.exe
├── *.s
├── *_disasm.txt                 # Disassembly
└── *_unwind.txt                 # Unwind info
```

## Quick Edit-Test Cycle

When editing `rtl/win64/seh64.inc`:

```bash
# 1. Edit seh64.inc
vim rtl/win64/seh64.inc

# 2. Rebuild just the RTL (fast: ~10-15 seconds)
make -C rtl clean OS_TARGET=win64 CPU_TARGET=aarch64
make -C rtl all OS_TARGET=win64 CPU_TARGET=aarch64 \
  FPC=/tmp/fpc_ci_runner/fpc_install/lib/fpc/3.3.1/ppcrossa64 \
  BINUTILSPREFIX=aarch64-w64-mingw32- \
  OPT="-FD/tmp/fpc_ci_runner/llvm-mingw/bin -dFPC_DEBUG_WIN64_UNWIND"

# 3. Recompile test (uses new RTL)
cd tests/phase2-tests
/tmp/fpc_ci_runner/fpc_install/lib/fpc/3.3.1/ppcrossa64 \
  -Twin64 -XPaarch64-w64-mingw32- \
  -Fu../../rtl/units/aarch64-win64 \
  -FD/tmp/fpc_ci_runner/llvm-mingw/bin \
  -a -oarm64trap.exe arm64trap.pas

# 4. Check assembly
grep -n "bl.*_FPC_local_unwind" arm64trap.s

# 5. Copy to Windows and test
# (or push to GitHub for CI)
```

## Differences from GitHub Actions

| Aspect | GitHub Actions | Local Script |
|--------|----------------|--------------|
| Environment | Ubuntu 22.04 container | Your WSL/Linux |
| Cache | GitHub cache API | Local filesystem |
| Artifacts | GitHub artifacts | `arm64-exes/` directory |
| Windows test | Real ARM64 runner | Manual (copy .exe files) |
| Isolation | Fresh container each run | Persistent state |

## Cache Management

The script uses `/tmp/fpc_ci_runner/` for cache (like `$RUNNER_TEMP` in CI):

```bash
# View cache
ls -lh /tmp/fpc_ci_runner/

# Clear cache
rm -rf /tmp/fpc_ci_runner/

# Keep llvm-mingw, rebuild FPC
rm -rf /tmp/fpc_ci_runner/fpc_install
./run-ci-locally.sh
```

## Troubleshooting

### "ppcrossa64 not found"
```bash
# Force rebuild
./run-ci-locally.sh --clean --no-cache
```

### "system.ppu does NOT contain _fpc_local_unwind"
```bash
# Check if seh64.inc exports it
grep "_fpc_local_unwind" rtl/win64/seh64.inc

# Rebuild RTL
make -C rtl clean OS_TARGET=win64 CPU_TARGET=aarch64
./run-ci-locally.sh --no-cache
```

### "aarch64-w64-mingw32-clang not found"
```bash
# llvm-mingw not in PATH
export PATH="/tmp/fpc_ci_runner/llvm-mingw/bin:$PATH"
```

### Assembly doesn't contain `_FPC_local_unwind`
```bash
# Using old RTL - rebuild
make -C rtl clean OS_TARGET=win64 CPU_TARGET=aarch64
./run-ci-locally.sh --no-cache
```

## See Also

- `.github/workflows/win-arm64.yml` - The actual CI workflow
- `/mnt/c/Users/timuy/Dropbox/personal/Vault/Projects/fpc/local-build-test.md` - Detailed build notes
- `/mnt/c/Users/timuy/Dropbox/personal/Vault/Projects/fpc/next-steps-detailed.md` - Project roadmap
