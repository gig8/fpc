# Free Pascal Windows aarch64 – notes

Notes and documentation for the Windows arm64 (aarch64) bug bounty work.

- **Goal:** Fully operational Free Pascal compiler for arm64 on Windows (pure arm64 binaries, not arm64ec).
- **Validation:** Lazarus must compile; toolchain must work for rebuilding projects; changes must be accepted into FPC trunk.

## Docs in this folder

- **[gemini-conversation-summary.md](gemini-conversation-summary.md)** – Summary of the Gemini “Project Triage and Strategy” conversation: WSL vs Windows, toolchain (llvm-mingw), build commands, SEH/unwind, and why `-ClvLLVM` must not be used.
- **[plan-win-aarch64.md](plan-win-aarch64.md)** – Plan and next steps: root cause of “Illegal parameter: -ClvLLVM”, correct `make crossinstall` command (no `-ClvLLVM`), immediate steps, and longer-term bounty roadmap.
- **[next-steps-detailed.md](next-steps-detailed.md)** – Detailed step-by-step plan: phases 1–7 with checkpoints, verification, contingencies, and a re-check summary (order, bounty coverage, SEH risk, Phase 3 output).
- **[ci-arm64-plan.md](ci-arm64-plan.md)** – CI for Windows arm64: GitHub vs GitLab, no submodule, one repo / two remotes; plan and steps for `.github/workflows/` on GitHub.
