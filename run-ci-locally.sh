#!/bin/bash
# Run CI workflow locally - executes the same commands as .github/workflows/win-arm64.yml
# This script reads the workflow file and runs the Linux crossbuild job steps directly
# (without Docker/act, since we're already on the right platform)
#
# Usage:
#   ./run-ci-locally.sh [--clean] [--use-cache]

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Parse arguments
CLEAN=0
USE_CACHE=1
for arg in "$@"; do
    case $arg in
        --clean) CLEAN=1 ;;
        --no-cache) USE_CACHE=0 ;;
        *) echo "Unknown option: $arg"; exit 1 ;;
    esac
done

# Environment variables (from workflow env section)
export FPC_VERSION="3.3.1"
export LLVM_MINGW_RELEASE="20251216"
export LLVM_MINGW_ARCHIVE="llvm-mingw-20251216-ucrt-ubuntu-22.04-x86_64.tar.xz"

# Paths (simulate GitHub Actions environment)
export GITHUB_WORKSPACE="$PWD"
export RUNNER_TEMP="${RUNNER_TEMP:-/tmp/fpc_ci_runner}"
export LLVM_MINGW="$RUNNER_TEMP/llvm-mingw"

mkdir -p "$RUNNER_TEMP"

echo -e "${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  Local CI - Windows arm64 (crossbuild job)                    ║${NC}"
echo -e "${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
echo ""
echo "Workspace: $GITHUB_WORKSPACE"
echo "Runner temp: $RUNNER_TEMP"
echo "FPC version: $FPC_VERSION"
echo ""

# Step: Install build tools and host FPC
echo -e "${BLUE}▶ Install build tools and host FPC${NC}"
if ! command -v make &> /dev/null || ! command -v fpc &> /dev/null; then
    echo -e "${RED}✗ Missing tools. Run: sudo apt-get install -y build-essential fpc${NC}"
    exit 1
fi
make -v | head -1
fpc -iV
echo -e "${GREEN}✓ Build tools OK${NC}\n"

# Step: Cache llvm-mingw
echo -e "${BLUE}▶ Cache llvm-mingw${NC}"
CACHE_LLVM_HIT=0
if [ -d "$LLVM_MINGW" ] && [ -f "$LLVM_MINGW/bin/aarch64-w64-mingw32-clang" ]; then
    echo "Cache hit: llvm-mingw exists"
    CACHE_LLVM_HIT=1
else
    echo "Cache miss: need to download"
fi

# Step: Set llvm-mingw env
export PATH="$LLVM_MINGW/bin:$PATH"

# Step: Install llvm-mingw
if [ $CACHE_LLVM_HIT -eq 0 ]; then
    echo "Downloading llvm-mingw $LLVM_MINGW_RELEASE..."
    mkdir -p "$LLVM_MINGW"
    curl -sL "https://github.com/mstorsjo/llvm-mingw/releases/download/$LLVM_MINGW_RELEASE/$LLVM_MINGW_ARCHIVE" \
        -o "$RUNNER_TEMP/llvm-mingw.tar.xz"
    tar -xf "$RUNNER_TEMP/llvm-mingw.tar.xz" -C "$LLVM_MINGW" --strip-components=1
    rm "$RUNNER_TEMP/llvm-mingw.tar.xz"
fi
"$LLVM_MINGW/bin/aarch64-w64-mingw32-clang" --version | head -1
echo -e "${GREEN}✓ llvm-mingw OK${NC}\n"

# Step: Restore FPC cross-build cache
echo -e "${BLUE}▶ Restore FPC cross-build cache${NC}"
CACHE_FPC_HIT=0
if [ $USE_CACHE -eq 1 ] && \
   [ -f "$GITHUB_WORKSPACE/compiler/ppcrossa64" ] && \
   [ -f "$GITHUB_WORKSPACE/compiler/ppca64" ] && \
   [ -d "$RUNNER_TEMP/fpc_install/lib/fpc/$FPC_VERSION/units/aarch64-win64" ]; then
    echo "Cache hit: ppcrossa64, ppca64, and units exist"
    CACHE_FPC_HIT=1
else
    echo "Cache miss: need to build"
fi
echo ""

# Step: Verify FPC cache contents
if [ $CACHE_FPC_HIT -eq 1 ]; then
    echo -e "${BLUE}▶ Verify FPC cache contents${NC}"
    missing=""
    [ -f "$GITHUB_WORKSPACE/compiler/ppcrossa64" ] || missing="$missing compiler/ppcrossa64"
    [ -f "$GITHUB_WORKSPACE/compiler/ppca64" ] || missing="$missing compiler/ppca64"
    [ -d "$RUNNER_TEMP/fpc_install/lib/fpc/$FPC_VERSION/units/aarch64-win64" ] || missing="$missing fpc_install/.../units/aarch64-win64"
    if [ -n "$missing" ]; then
        echo -e "${RED}✗ FPC cache incomplete (missing:$missing)${NC}"
        CACHE_FPC_HIT=0
    else
        echo -e "${GREEN}✓ FPC cache OK${NC}"
    fi
    echo ""
fi

# Step: Cross-install FPC aarch64-win64
if [ $CACHE_FPC_HIT -eq 0 ] || [ $CLEAN -eq 1 ]; then
    echo -e "${BLUE}▶ Cross-install FPC aarch64-win64${NC}"
    
    if [ $CLEAN -eq 1 ]; then
        echo "Cleaning..."
        make clean
    fi
    
    LOG="$RUNNER_TEMP/crossinstall.log"
    echo "Building (log: $LOG)..."
    
    make crossinstall -j4 \
        CPU_TARGET=aarch64 \
        OS_TARGET=win64 \
        FPC=/usr/bin/fpc \
        BINUTILSPREFIX=aarch64-w64-mingw32- \
        CROSSOPT="-FD$LLVM_MINGW/bin -dFPC_DEBUG_WIN64_UNWIND" \
        INSTALL_PREFIX="$RUNNER_TEMP/fpc_install" \
        2>&1 | tee "$LOG"
    
    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        echo -e "${RED}✗ crossinstall failed${NC}"
        echo "Last 50 lines:"
        tail -50 "$LOG"
        exit 1
    fi
    echo -e "${GREEN}✓ Cross-install complete${NC}\n"
else
    echo -e "${BLUE}▶ Skipping cross-install (using cache)${NC}\n"
fi

# Step: Ensure ppcrossa64 at compiler/
echo -e "${BLUE}▶ Ensure ppcrossa64 at compiler/${NC}"
if [ ! -f "$GITHUB_WORKSPACE/compiler/ppcrossa64" ]; then
    FOUND=$(find "$RUNNER_TEMP/fpc_install" -name ppcrossa64 -type f 2>/dev/null | head -1)
    if [ -n "$FOUND" ] && [ -f "$FOUND" ]; then
        cp "$FOUND" "$GITHUB_WORKSPACE/compiler/ppcrossa64"
        chmod +x "$GITHUB_WORKSPACE/compiler/ppcrossa64"
        echo "Copied ppcrossa64 from $FOUND"
    else
        echo -e "${YELLOW}Warning: ppcrossa64 not found${NC}"
    fi
fi
echo -e "${GREEN}✓ ppcrossa64 at: $GITHUB_WORKSPACE/compiler/ppcrossa64${NC}\n"

# Step: Diagnose system.ppu
echo -e "${BLUE}▶ Diagnose system.ppu for _fpc_local_unwind${NC}"
SPPU="$RUNNER_TEMP/fpc_install/lib/fpc/$FPC_VERSION/units/aarch64-win64/rtl/system.ppu"
if [ -f "$SPPU" ]; then
    if strings "$SPPU" | grep -q '_fpc_local_unwind'; then
        echo -e "${GREEN}✓ system.ppu contains _fpc_local_unwind${NC}"
    else
        echo -e "${YELLOW}⚠ system.ppu does NOT contain _fpc_local_unwind${NC}"
    fi
else
    echo -e "${YELLOW}⚠ system.ppu not found${NC}"
fi
echo ""

# Step: Compile Phase 2 tests
echo -e "${BLUE}▶ Compile Phase 2 tests${NC}"
PPC="$GITHUB_WORKSPACE/compiler/ppcrossa64"
UP="$RUNNER_TEMP/fpc_install/lib/fpc/$FPC_VERSION/units/aarch64-win64"
P2="$GITHUB_WORKSPACE/tests/phase2-tests"

if [ ! -f "$PPC" ]; then
    echo -e "${RED}✗ ppcrossa64 not found${NC}"
    exit 1
fi

cd "$P2"

# hello.exe
"$PPC" -Twin64 -XPaarch64-w64-mingw32- \
    -Fu"$UP/rtl" -Fu"$UP/rtl-objpas" \
    -FE. -FD"$LLVM_MINGW/bin" \
    -ohello.exe hello.pas

# trap.exe
"$PPC" -Twin64 -XPaarch64-w64-mingw32- \
    -Fu"$UP/rtl" -Fu"$UP/rtl-objpas" \
    -FE. -FD"$LLVM_MINGW/bin" \
    -otrap.exe trap.pas

# arm64trap.exe (with fix)
"$PPC" -Twin64 -XPaarch64-w64-mingw32- \
    -Fu"$UP/rtl" -Fu"$UP/rtl-objpas" \
    -FE. -FD"$LLVM_MINGW/bin" \
    -a -oarm64trap.exe arm64trap.pas

# arm64trap_no_fix.exe (without fix)
"$PPC" -Twin64 -XPaarch64-w64-mingw32- -dFPC_NO_WIN64_LOCAL_UNWIND \
    -Fu"$UP/rtl" -Fu"$UP/rtl-objpas" \
    -FE. -FD"$LLVM_MINGW/bin" \
    -a -oarm64trap_no_fix.exe arm64trap.pas

# neontest.exe (optional)
if [ -f neontest.pas ]; then
    "$PPC" -Twin64 -XPaarch64-w64-mingw32- \
        -Fu"$UP/rtl" -Fu"$UP/rtl-objpas" \
        -FE. -FD"$LLVM_MINGW/bin" \
        -oneontest.exe neontest.pas
fi

cd "$GITHUB_WORKSPACE"
echo -e "${GREEN}✓ Phase 2 tests compiled${NC}\n"

# Step: Verify assembly patterns
echo -e "${BLUE}▶ Verify assembly patterns${NC}"
if [ -f "$P2/arm64trap.s" ]; then
    if grep -q '_FPC_local_unwind\|_FPC_LOCAL_UNWIND' "$P2/arm64trap.s"; then
        echo -e "${GREEN}✓ arm64trap.s contains _FPC_local_unwind${NC}"
        grep -n '_FPC_local_unwind\|_FPC_LOCAL_UNWIND\|bl.*local_unwind' "$P2/arm64trap.s" | head -3
    else
        echo -e "${YELLOW}⚠ arm64trap.s does NOT contain _FPC_local_unwind${NC}"
    fi
fi

if [ -f "$P2/arm64trap_no_fix.s" ]; then
    if grep -q '_FPC_local_unwind\|_FPC_LOCAL_UNWIND' "$P2/arm64trap_no_fix.s"; then
        echo -e "${YELLOW}⚠ arm64trap_no_fix.s contains _FPC_local_unwind (unexpected)${NC}"
    else
        echo -e "${GREEN}✓ arm64trap_no_fix.s has no _FPC_local_unwind${NC}"
    fi
fi
echo ""

# Step: Cache msgtxt.inc
echo -e "${BLUE}▶ Cache msgtxt.inc / msgidx.inc${NC}"
if [ -f "$GITHUB_WORKSPACE/compiler/msgtxt.inc" ]; then
    echo "Cache hit: msgtxt.inc exists"
else
    echo "Cache miss"
fi
echo ""

# Step: Generate msgtxt.inc
if [ $CACHE_FPC_HIT -eq 0 ]; then
    echo -e "${BLUE}▶ Generate msgtxt.inc with host FPC${NC}"
    make -C compiler msgtxt.inc FPC=/usr/bin/fpc
    echo -e "${GREEN}✓ msgtxt.inc generated${NC}\n"
fi

# Step: Build native ppca64
if [ $CACHE_FPC_HIT -eq 0 ]; then
    echo -e "${BLUE}▶ Build native ppca64 (Phase 3)${NC}"
    make -C compiler compiler -j4 \
        FPC="$GITHUB_WORKSPACE/compiler/ppcrossa64" \
        OS_TARGET=win64 \
        CPU_TARGET=aarch64 \
        BINUTILSPREFIX=aarch64-w64-mingw32- \
        OPT="-FD$LLVM_MINGW/bin -Fu$UP/rtl -Fu$UP/rtl-objpas"
    
    # Find and copy ppca64
    for cand in "$GITHUB_WORKSPACE/compiler/ppca64" \
                "$GITHUB_WORKSPACE/compiler/aarch64/bin/aarch64-win64/ppca64" \
                "$GITHUB_WORKSPACE/ppca64"; do
        if [ -f "$cand" ]; then
            if [ "$cand" != "$GITHUB_WORKSPACE/compiler/ppca64" ]; then
                cp "$cand" "$GITHUB_WORKSPACE/compiler/ppca64"
            fi
            break
        fi
    done
    echo -e "${GREEN}✓ ppca64 built${NC}\n"
fi

# Step: Disassemble and dump unwind
echo -e "${BLUE}▶ Disassemble and dump unwind (static analysis)${NC}"
STAGE="$GITHUB_WORKSPACE/arm64-exes"
mkdir -p "$STAGE"

OBJDUMP=""
for cand in aarch64-w64-mingw32-objdump llvm-objdump; do
    if command -v "$cand" &> /dev/null; then
        OBJDUMP="$cand"
        break
    fi
done

if [ -n "$OBJDUMP" ]; then
    for exe in arm64trap arm64trap_no_fix; do
        if [ ! -f "$P2/${exe}.exe" ]; then continue; fi
        "$OBJDUMP" -d -C "$P2/${exe}.exe" > "$STAGE/${exe}_disasm.txt" 2>/dev/null || true
        if [ "$OBJDUMP" = "llvm-objdump" ]; then
            "$OBJDUMP" -u "$P2/${exe}.exe" > "$STAGE/${exe}_unwind.txt" 2>/dev/null || true
        fi
    done
    echo -e "${GREEN}✓ Disassembly complete${NC}"
else
    echo -e "${YELLOW}⚠ No objdump found${NC}"
fi
echo ""

# Step: Stage artifacts
echo -e "${BLUE}▶ Stage and upload arm64 executables${NC}"
for f in hello trap; do
    if [ -f "$P2/${f}.exe" ]; then
        cp "$P2/${f}.exe" "$STAGE/"
    fi
done

for exe in arm64trap arm64trap_no_fix; do
    if [ -f "$P2/${exe}.exe" ]; then
        cp "$P2/${exe}.exe" "$STAGE/"
    fi
done

for asm in arm64trap arm64trap_no_fix; do
    if [ -f "$P2/${asm}.s" ]; then
        cp "$P2/${asm}.s" "$STAGE/"
    fi
done

if [ -f "$P2/neontest.exe" ]; then
    cp "$P2/neontest.exe" "$STAGE/"
fi

if [ -f "$GITHUB_WORKSPACE/compiler/ppca64" ]; then
    cp "$GITHUB_WORKSPACE/compiler/ppca64" "$STAGE/ppca64.exe"
fi

echo -e "${GREEN}✓ Artifacts staged in $STAGE${NC}\n"

# Summary
echo -e "${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  Local CI Complete ✓                                          ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "Artifacts:"
echo "  - Executables: $STAGE/*.exe"
echo "  - Assembly:    $STAGE/*.s"
echo "  - Disassembly: $STAGE/*_disasm.txt"
echo ""
echo -e "${BLUE}Next: Copy executables to Windows ARM64 and run arm64trap.exe${NC}"
echo ""
echo "Cache status:"
echo "  - llvm-mingw: $([[ $CACHE_LLVM_HIT -eq 1 ]] && echo "hit" || echo "miss")"
echo "  - FPC build:  $([[ $CACHE_FPC_HIT -eq 1 ]] && echo "hit" || echo "miss")"
echo ""
echo "To force rebuild: ./run-ci-locally.sh --clean --no-cache"
