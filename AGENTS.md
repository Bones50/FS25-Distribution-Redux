# Agent instructions

- Write documentation in English. See `CONTRIBUTING.md` for setup and commands.
- Run all checks with `make docker-check` (preferred, Docker required), or `make check LUA=luajit` with native tools. Use `make test-lua`, `make test-bats`, and `make lint` for focused checks; pass `LUA=luajit` when Lua 5.1 is unavailable.
- CI changes must add or update regression tests covering the changed behavior. Keep workflow `run:` blocks short: put logic in `.github/scripts/*.sh` and test those scripts with Bats.
- For functionality changes, add or update relevant Lua regression tests, run the affected tests, then the full checks. Report any required FS25 gameplay or multiplayer checks that were not run; test doubles do not replace the engine.
- Consider performance when defining scope and choosing an implementation. Prefer efficient algorithms; avoid repeated scans, allocations, I/O and network events in hot paths. Measure relevant changes where practical, and explicitly flag possible regressions or unmeasured performance tradeoffs.
- Initialize skills with `make skills-init` if missing. Use `.agents/skills/fs25-upstream/plugins/fs25-modding/skills/fs25-scripting-mod/SKILL.md` for Lua mod development and `.agents/skills/fs25-upstream/plugins/fs25-modding/skills/fs25-modding-debug/SKILL.md` for debugging. These are upstream references: verify patch-specific APIs, paths, commands and descriptor versions against the target game. Keep this repository's Lua 5.1 compatibility and checks; do not blindly copy sample versions or assume optional tools are installed.
