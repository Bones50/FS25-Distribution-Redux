# FS25 skills submodule

`fs25-upstream/` is a Git submodule of
[Paint-a-Farm/fs25-skills](https://github.com/Paint-a-Farm/fs25-skills).
The parent repository pins its revision; upstream's MIT license is preserved
inside the submodule. The full upstream repository contains eight skills.

The relevant entry points for this project are:

- `fs25-upstream/plugins/fs25-modding/skills/fs25-scripting-mod/SKILL.md`
- `fs25-upstream/plugins/fs25-modding/skills/fs25-modding-debug/SKILL.md`

Initialize after cloning with `git submodule update --init --recursive`, or
clone the parent repository with `git clone --recurse-submodules <repo-url>`.
After switching branches or pulling changes to the pinned revision, run the
update command again. Skills are documentation dependencies, not runtime or CI
check dependencies; the checks do not require submodule initialization.

Follow project-specific instructions in `AGENTS.md`. Verify patch-specific APIs,
paths, console commands and descriptor versions before copying upstream examples.
Do not edit the submodule to customize this project; put local guidance in
`AGENTS.md`. To update, review a specific upstream commit, check it out inside
`fs25-upstream`, then stage the gitlink in the parent repository. Avoid automatic
updates to the upstream branch tip.
