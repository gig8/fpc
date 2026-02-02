# GitLab Merge Request

**MR opened:** [!1276 – aarch64-win64: fix try...finally+exit (Bounty Boss), add CI](https://gitlab.com/freepascal.org/fpc/source/-/merge_requests/1276)

**Status:** Submitted Jan 31, 2026. Awaiting FPC maintainer review.

---

## How we opened this MR

1. Forked [freepascal.org/fpc/source](https://gitlab.com/freepascal.org/fpc/source) to [gig8/fpc-source](https://gitlab.com/gig8/fpc-source).
2. Pushed `bounty-submission` branch.
3. Opened MR from fork's `bounty-submission` → upstream `main`.

---

# aarch64-win64: fix try...finally+exit (Bounty Boss)

Fixes the try...finally+exit behaviour on Windows ARM64 so the finally block runs when leaving via `exit` (or break/continue). Addresses forum topic 66952 (Reply #67) and [GitLab #40203](https://gitlab.com/freepascal.org/fpc/source/-/issues/40203).

## Summary

- **Compiler (`compiler/aarch64/cgcpu.pas`):** For aarch64-win64, `g_local_unwind` now emits a call to `_FPC_local_unwind` (using `RtlUnwindEx`) instead of a plain jump when leaving a try block via exit/break/continue.
- **Compiler (`compiler/symtable.pas`):** Case-insensitive fallback for `_fpc_local_unwind` in `search_system_proc`.
- **RTL (`rtl/win64/system.pp`, `rtl/win64/seh64.inc`):** Declare and implement `_fpc_local_unwind` via `RtlUnwindEx`.

## Test

Minimal test (Bounty Boss): `begin` → `try` → `exit` → `finally` → `end`. Success criterion: output contains `finally` when run on Windows ARM64.

- Test source: `docs/phase2-tests/arm64trap.pas`
- CI: `.github/workflows/win-arm64.yml` cross-builds on Linux and runs the test on `windows-11-arm`; the "Run Bounty Boss test" step prints the test code and confirms execution on Windows ARM64. Job passes when output contains "finally".

## Scope

This MR does **not** include native ppca64 (compiler self-compilation on ARM64) or other phases—only the try...finally+exit fix and the CI that demonstrates it.

---

**Forum:** https://forum.lazarus.freepascal.org/index.php?topic=66952.0
