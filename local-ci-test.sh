#!/bin/bash
# Local CI test script - mirrors .github/workflows/win-arm64.yml
# Runs all steps up to Windows ARM64 execution (which requires real hardware)
#
# Usage:
#   ./local-ci-test.sh [--clean] [--skip-crossinstall] [--verbose]
#
# Options:
#   --clean              Clean everything and rebuild from scratch
#   --skip-crossinstall  Skip crossinstall (use existing ppcrossa64)
#   --verbose            Show full build output

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Parse arguments
CLEAN=0
SKIP_CROSSINSTALL=0
VERBOSE=0
for arg in "$@"; do
    case $arg in
        --clean) CLEAN=1 ;;
        --skip-crossinstall) SKIP_CROSSINSTALL=1 ;;
        --verbose) VERBOSE=1 ;;
        *) echo "Unknown option: $arg"; exit 1 ;;
    esac
done

# Environment (mirrors CI env vars)
FPC_VERSION="3.3.1"
WORKSPACE="$PWD"
TEMP_DIR="${TEMP_DIR:-/tmp/fpc_local_ci}"
LLVM_MINGW="${LLVM_MINGW:-/opt/llvm-mingw}"
FPC_INSTALL="$TEMP_DIR/fpc_install"

echo -e "${BLUE}=== Local CI Test - FPC ARM64 Windows ===${NC}"
echo "Workspace: $WORKSPACE"
echo "Temp dir: $TEMP_DIR"
echo "llvm-mingw: $LLVM_MINGW"
echo "FPC install: $FPC_INSTALL"
echo ""

# Step 1: Install build tools and host FPC
echo -e "${BLUE}[1/10] Checking build tools and host FPC${NC}"
if ! command -v make &> /dev/null; then
    echo -e "${RED}Error: make not found${NC}"
    exit 1
fi
if ! command -v fpc &> /dev/null; then
    echo -e "${RED}Error: fpc not found (install with: sudo apt-get install fpc)${NC}"
    exit 1
fi
echo "make: $(make -v | head -1)"
echo "fpc: $(fpc -iV)"
echo -e "${GREEN}✓ Build tools OK${NC}\n"

# Step 2: Check llvm-mingw
echo -e "${BLUE}[2/10] Checking llvm-mingw${NC}"
if [ ! -d "$LLVM_MINGW" ]; then
    echo -e "${RED}Error: llvm-mingw not found at $LLVM_MINGW${NC}"
    echo "Install with: sudo mkdir -p /opt/llvm-mingw && curl -sL <url> | sudo tar -xJ -C /opt/llvm-mingw --strip-components=1"
    exit 1
fi
export PATH="$LLVM_MINGW/bin:$PATH"
if ! command -v aarch64-w64-mingw32-clang &> /dev/null; then
    echo -e "${RED}Error: aarch64-w64-mingw32-clang not found in $LLVM_MINGW/bin${NC}"
    exit 1
fi
echo "aarch64-w64-mingw32-clang: $(aarch64-w64-mingw32-clang --version | head -1)"
echo -e "${GREEN}✓ llvm-mingw OK${NC}\n"

# Step 3: Clean if requested
if [ $CLEAN -eq 1 ]; then
    echo -e "${BLUE}[3/10] Cleaning (--clean)${NC}"
    make clean
    rm -rf "$TEMP_DIR"
    echo -e "${GREEN}✓ Clean complete${NC}\n"
else
    echo -e "${BLUE}[3/10] Skipping clean (use --clean to force)${NC}\n"
fi

# Step 4: Check/restore FPC cache
mkdir -p "$TEMP_DIR"
echo -e "${BLUE}[4/10] Checking FPC cache (ppcrossa64)${NC}"
CACHE_HIT=0

# Check if we can use existing install (like CI cache restore)
# Priority: 1) TEMP_DIR install, 2) ~/Projects/gig8/fpc_install, 3) compiler/ppcrossa64
if [ -d "$FPC_INSTALL/lib/fpc/$FPC_VERSION/units/aarch64-win64" ]; then
    echo "Found FPC install at $FPC_INSTALL"
    CACHE_HIT=1
elif [ -d "$HOME/Projects/gig8/fpc_install/lib/fpc/$FPC_VERSION/units/aarch64-win64" ]; then
    echo "Found FPC install at ~/Projects/gig8/fpc_install (using as cache)"
    FPC_INSTALL="$HOME/Projects/gig8/fpc_install"
    CACHE_HIT=1
elif [ -f "$WORKSPACE/compiler/ppcrossa64" ]; then
    echo "Found ppcrossa64 in compiler/ but no install dir (partial cache)"
    CACHE_HIT=0
else
    echo "Cache miss: need to build"
    CACHE_HIT=0
fi

if [ $CACHE_HIT -eq 1 ] && [ $SKIP_CROSSINSTALL -eq 0 ]; then
    echo -e "${YELLOW}Note: Use --skip-crossinstall to skip rebuild${NC}"
fi
echo ""

# Step 5: Cross-install FPC aarch64-win64
if [ $SKIP_CROSSINSTALL -eq 0 ] || [ $CACHE_HIT -eq 0 ]; then
    echo -e "${BLUE}[5/10] Cross-install FPC aarch64-win64${NC}"
    LOG="$TEMP_DIR/crossinstall.log"
    
    if [ $VERBOSE -eq 1 ]; then
        make crossinstall -j$(nproc) \
            CPU_TARGET=aarch64 \
            OS_TARGET=win64 \
            FPC=/usr/bin/fpc \
            BINUTILSPREFIX=aarch64-w64-mingw32- \
            CROSSOPT="-FD$LLVM_MINGW/bin -dFPC_DEBUG_WIN64_UNWIND" \
            INSTALL_PREFIX="$FPC_INSTALL" \
            2>&1 | tee "$LOG"
    else
        echo "Building (log: $LOG)..."
        make crossinstall -j$(nproc) \
            CPU_TARGET=aarch64 \
            OS_TARGET=win64 \
            FPC=/usr/bin/fpc \
            BINUTILSPREFIX=aarch64-w64-mingw32- \
            CROSSOPT="-FD$LLVM_MINGW/bin -dFPC_DEBUG_WIN64_UNWIND" \
            INSTALL_PREFIX="$FPC_INSTALL" \
            > "$LOG" 2>&1 || {
                echo -e "${RED}Error: crossinstall failed. Last 50 lines:${NC}"
                tail -50 "$LOG"
                exit 1
            }
    fi
    echo -e "${GREEN}✓ Cross-install complete${NC}\n"
else
    echo -e "${BLUE}[5/10] Skipping cross-install (--skip-crossinstall)${NC}\n"
fi

# Step 6: Ensure ppcrossa64 at compiler/ for Phase 2
echo -e "${BLUE}[6/10] Ensuring ppcrossa64 at compiler/${NC}"
if [ ! -f "$WORKSPACE/compiler/ppcrossa64" ]; then
    FOUND=$(find "$FPC_INSTALL" -name ppcrossa64 -type f 2>/dev/null | head -1)
    if [ -n "$FOUND" ] && [ -f "$FOUND" ]; then
        cp "$FOUND" "$WORKSPACE/compiler/ppcrossa64"
        chmod +x "$WORKSPACE/compiler/ppcrossa64"
        echo "Copied ppcrossa64 from $FOUND"
    else
        echo -e "${RED}Error: ppcrossa64 not found${NC}"
        exit 1
    fi
fi
echo "ppcrossa64: $WORKSPACE/compiler/ppcrossa64"
echo -e "${GREEN}✓ ppcrossa64 OK${NC}\n"

# Step 7: Diagnose system.ppu for _fpc_local_unwind
echo -e "${BLUE}[7/10] Diagnosing system.ppu for _fpc_local_unwind${NC}"
SPPU="$FPC_INSTALL/lib/fpc/$FPC_VERSION/units/aarch64-win64/rtl/system.ppu"
if [ -f "$SPPU" ]; then
    if strings "$SPPU" | grep -q '_fpc_local_unwind'; then
        echo -e "${GREEN}✓ system.ppu contains _fpc_local_unwind${NC}"
    else
        echo -e "${YELLOW}Warning: system.ppu does NOT contain _fpc_local_unwind${NC}"
        echo "This will cause sysutils.pp(659) to fail with Unknown compilerproc"
    fi
else
    echo -e "${RED}Error: system.ppu not found at $SPPU${NC}"
    exit 1
fi
echo ""

# Step 8: Compile Phase 2 tests
echo -e "${BLUE}[8/10] Compiling Phase 2 tests${NC}"
PPC="$WORKSPACE/compiler/ppcrossa64"

# Use local RTL if it exists (from recent rebuild), otherwise use install
if [ -d "$WORKSPACE/rtl/units/aarch64-win64/rtl" ] && [ -f "$WORKSPACE/rtl/units/aarch64-win64/rtl/system.ppu" ]; then
    UP="$WORKSPACE/rtl/units/aarch64-win64"
    echo "Using local RTL: $UP (recently rebuilt)"
else
    UP="$FPC_INSTALL/lib/fpc/$FPC_VERSION/units/aarch64-win64"
    echo "Using installed RTL: $UP"
fi

P2="$WORKSPACE/tests/phase2-tests"

if [ ! -d "$P2" ]; then
    echo -e "${RED}Error: tests/phase2-tests not found${NC}"
    exit 1
fi

cd "$P2"

# hello.exe
echo "Compiling hello.pas..."
"$PPC" -Twin64 -XPaarch64-w64-mingw32- \
    -Fu"$UP/rtl" -Fu"$UP/rtl-objpas" \
    -FE. -FD"$LLVM_MINGW/bin" \
    -ohello.exe hello.pas

# trap.exe
echo "Compiling trap.pas..."
"$PPC" -Twin64 -XPaarch64-w64-mingw32- \
    -Fu"$UP/rtl" -Fu"$UP/rtl-objpas" \
    -FE. -FD"$LLVM_MINGW/bin" \
    -otrap.exe trap.pas

# arm64trap.exe (with fix)
echo "Compiling arm64trap.pas (with fix)..."
"$PPC" -Twin64 -XPaarch64-w64-mingw32- \
    -Fu"$UP/rtl" -Fu"$UP/rtl-objpas" \
    -FE. -FD"$LLVM_MINGW/bin" \
    -a -oarm64trap.exe arm64trap.pas

# arm64trap_no_fix.exe (without fix)
echo "Compiling arm64trap.pas (no fix)..."
"$PPC" -Twin64 -XPaarch64-w64-mingw32- -dFPC_NO_WIN64_LOCAL_UNWIND \
    -Fu"$UP/rtl" -Fu"$UP/rtl-objpas" \
    -FE. -FD"$LLVM_MINGW/bin" \
    -a -oarm64trap_no_fix.exe arm64trap.pas

# neontest.exe (optional)
if [ -f neontest.pas ]; then
    echo "Compiling neontest.pas..."
    "$PPC" -Twin64 -XPaarch64-w64-mingw32- \
        -Fu"$UP/rtl" -Fu"$UP/rtl-objpas" \
        -FE. -FD"$LLVM_MINGW/bin" \
        -oneontest.exe neontest.pas
else
    echo "neontest.pas not found, skipping"
fi

cd "$WORKSPACE"
echo -e "${GREEN}✓ Phase 2 tests compiled${NC}\n"

# Step 9: Verify assembly patterns
echo -e "${BLUE}[9/10] Verifying assembly patterns${NC}"

# Check fix version
if [ -f "$P2/arm64trap.s" ]; then
    if grep -q '_FPC_local_unwind\|_FPC_LOCAL_UNWIND' "$P2/arm64trap.s"; then
        echo -e "${GREEN}✓ arm64trap.s contains _FPC_local_unwind (fix active)${NC}"
        grep -n 'bl.*_FPC_local_unwind\|bl.*_FPC_LOCAL_UNWIND' "$P2/arm64trap.s" | head -3
    else
        echo -e "${YELLOW}Warning: arm64trap.s does NOT contain _FPC_local_unwind${NC}"
    fi
else
    echo -e "${YELLOW}Warning: arm64trap.s not found${NC}"
fi

# Check no-fix version
if [ -f "$P2/arm64trap_no_fix.s" ]; then
    if grep -q '_FPC_local_unwind\|_FPC_LOCAL_UNWIND' "$P2/arm64trap_no_fix.s"; then
        echo -e "${YELLOW}Warning: arm64trap_no_fix.s contains _FPC_local_unwind (unexpected)${NC}"
    else
        echo -e "${GREEN}✓ arm64trap_no_fix.s has no _FPC_local_unwind (as expected)${NC}"
    fi
else
    echo -e "${YELLOW}Warning: arm64trap_no_fix.s not found${NC}"
fi
echo ""

# Step 10: Disassemble and dump unwind (static analysis)
echo -e "${BLUE}[10/10] Disassembling and dumping unwind info${NC}"
STAGE="$TEMP_DIR/analysis"
mkdir -p "$STAGE"

OBJDUMP=""
for cand in aarch64-w64-mingw32-objdump llvm-objdump; do
    if command -v "$cand" &> /dev/null; then
        OBJDUMP="$cand"
        break
    fi
done

if [ -z "$OBJDUMP" ]; then
    echo -e "${YELLOW}Warning: No objdump found (static analysis skipped)${NC}"
else
    echo "Using: $OBJDUMP"
    
    for exe in arm64trap arm64trap_no_fix; do
        if [ ! -f "$P2/${exe}.exe" ]; then continue; fi
        
        echo "Disassembling ${exe}.exe..."
        "$OBJDUMP" -d -C "$P2/${exe}.exe" > "$STAGE/${exe}_disasm.txt" 2>/dev/null || true
        
        if [ "$OBJDUMP" = "llvm-objdump" ]; then
            echo "Dumping unwind info for ${exe}.exe..."
            "$OBJDUMP" -u "$P2/${exe}.exe" > "$STAGE/${exe}_unwind.txt" 2>/dev/null || true
        fi
    done
    
    echo -e "${GREEN}✓ Disassembly complete (saved to $STAGE)${NC}"
fi
echo ""

# Summary
echo -e "${GREEN}=== Local CI Test Complete ===${NC}"
echo ""
echo "Built artifacts:"
echo "  - ppcrossa64: $WORKSPACE/compiler/ppcrossa64"
echo "  - RTL units:  $FPC_INSTALL/lib/fpc/$FPC_VERSION/units/aarch64-win64/"
echo "  - Test exes:  $P2/*.exe"
echo "  - Assembly:   $P2/*.s"
echo "  - Analysis:   $STAGE/"
echo ""
echo -e "${BLUE}Next steps:${NC}"
echo "  1. Copy test exes to Windows ARM64 machine"
echo "  2. Run: arm64trap.exe (should show 'Success: Finally block executed!' and 'Done.')"
echo "  3. Check debug output for [FPC_DEBUG_WIN64_UNWIND] messages"
echo ""
echo -e "${YELLOW}Note: This script runs all CI steps except Windows ARM64 execution${NC}"
echo -e "${YELLOW}      (requires actual ARM64 hardware or emulator)${NC}"
