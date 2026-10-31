# Contributing

Distribution Redux is a Farming Simulator 25 mod. Keep changes focused, preserve
Lua 5.1 compatibility, and include regression tests for behavior changes. Use
English for code comments and pull request descriptions to support upstream review.

## Docker: recommended for Windows, also works on Linux and macOS

Install and start Docker Desktop using **Linux containers**. Docker Engine is
also supported on Linux. Open a terminal in the cloned repository. You do not
need Make, Lua, Bash, Python or the linters on the host.

Windows PowerShell (run each command on one line):

```powershell
docker build --file Dockerfile.checks --tag fs25-distribution-checks .
docker run --rm --mount "type=bind,source=$($PWD.Path),target=/workspace,readonly" fs25-distribution-checks
```

Linux/macOS Bash or a WSL terminal:

```bash
docker build --file Dockerfile.checks --tag fs25-distribution-checks .
docker run --rm --mount "type=bind,source=$(pwd),target=/workspace,readonly" fs25-distribution-checks
```

If Make is already installed, `make docker-check` builds the same image and runs
the same command. The container runs as a non-root user and mounts the source
read-only. Bats creates its fixtures in the container's `/tmp`; no generated
files or root-owned artifacts are written to the checkout. The image contains
tools only, so source edits do not require a rebuild. Rebuild after changing
`Dockerfile.checks` or the pinned linter installer. Building initially requires
Internet access; checks themselves do not need network access.

To run a subset, append a Make command to `docker run`, for example:

```powershell
docker run --rm --mount "type=bind,source=$($PWD.Path),target=/workspace,readonly" fs25-distribution-checks make test-bats
```

A nonzero container exit code means a failed check. In PowerShell inspect
`$LASTEXITCODE` if scripting these commands. If Docker cannot access the mount,
check Docker Desktop's file-sharing permissions for your repository directory.
The image supports Linux amd64 and arm64, including Apple Silicon hosts.
`.gitattributes` enforces LF for scripts, tests, Makefile and workflows to avoid
CRLF failures in Windows checkouts. For an existing checkout with local edits,
save those edits before refreshing files to pick up the new line-ending rules.

## Install development tools

Required: GNU Make, Bash 4.4+, Lua 5.1 or LuaJIT, XMLStarlet, Bats-core 1.5+,
ShellCheck, actionlint and zizmor. Lua 5.2–5.4 are not substitutes for Lua 5.1.
No Python scripts or Python test dependencies are used by this repository.

Ubuntu/Debian (the CI runner uses Ubuntu 24.04):

```bash
sudo apt-get update
sudo apt-get install --no-install-recommends -y \
    make bash lua5.1 xmlstarlet bats shellcheck curl ca-certificates tar coreutils
make install-linters
make check
```

Fedora:

```bash
sudo dnf install make bash luajit xmlstarlet bats ShellCheck curl ca-certificates tar coreutils
make install-linters
make check LUA=luajit
```

`make install-linters` installs actionlint 1.7.12 and zizmor 1.31.1 into the
ignored `.local/bin/` directory. It supports Linux x86_64 and ARM64, checks
SHA-256 against pinned upstream release digests before extraction, and needs
network access but no administrator privileges. Make automatically adds that
directory to PATH. Override the destination with `LINTER_DIR=/path/to/bin` on
both installation and subsequent check commands.

For other platforms, install the same versions using the upstream
[actionlint instructions](https://github.com/rhysd/actionlint/blob/main/docs/install.md)
and [zizmor instructions](https://docs.zizmor.sh/installation/), then make them
available on PATH. Bash tests use GNU `sed`; on macOS, a Linux container is the
simplest way to reproduce CI. Tool updates must update both the version and
architecture-specific checksums in `.github/scripts/install-linters.sh`.

## Run checks

Run these from the repository root, or use `make -C /path/to/repository`.

| Command | What it checks |
| --- | --- |
| `make docker-check` | Build the tool image and run every check in Docker |
| `make check` | All validation, regression tests and linters (native tools) |
| `make validate` | Lua compilation, XML syntax and mod asset references |
| `make test` | Lua behavior tests and Bats validator tests |
| `make test-lua` | Lua behavior tests only |
| `make test-bats` | Bash validator tests only |
| `make test-localization` | Localization contracts and checker regression tests |
| `make check-localization-keys` | Report every missing English key per locale |
| `make lint` | ShellCheck, actionlint and zizmor |
| `make lint-shell` | Shared Bash scripts and Bats tests |
| `make lint-actions` | Both workflow linters |
| `make lint-actionlint` | Workflow syntax, expressions and embedded shell |
| `make lint-zizmor` | Workflow security checks only |

Append `LUA=luajit` to validation/test commands if Lua 5.1 is not installed.
Missing tools or a failed check cause a nonzero exit status; no checks are
silently skipped. Executables can be overridden through `BATS`, `ACTIONLINT`,
`ZIZMOR` and `SHELLCHECK` Make variables.

The workflow `.github/workflows/quality.yml` runs on pushes to `main`, pull requests and
manual dispatch. Eight independent matrix jobs run `validate`, `test-lua`, `test-bats`,
`test-localization`, `check-localization-keys`, `lint-shell`, `lint-actionlint` and `lint-zizmor` in parallel. Each installs only
its dependencies through `.github/scripts/install-ci-tools.sh`; `fail-fast: false`
keeps other jobs running after a failure. An additional independent job checks all localization lengths. CI uses native Ubuntu tools to avoid
building the same Docker image for each job. Local Docker checks use the same Make
targets. The checkout
action is pinned to a full commit SHA with credential persistence disabled;
workflow permissions are limited to reading repository contents.
Feature-branch pushes do not trigger a second run alongside `pull_request`.
Each PR update runs one set of checks; merging into `main` runs one set for the
resulting push. Manual dispatch remains available. Concurrency cancels stale
runs for the same PR or branch when a newer update arrives.

Zizmor runs with `--offline --pedantic`: local workflow security checks require
no GitHub token or network access. Audits requiring GitHub API access are not
part of this command. Actionlint validates workflow structure and expressions
and uses ShellCheck for embedded Bash. See the
[zizmor operating modes](https://docs.zizmor.sh/usage/) for online audit options.

## Validation and test coverage

`.github/scripts/check-mod.sh` is the shared Bash validator. XMLStarlet parses
XML and evaluates XPath; XML is not parsed using regular expressions. It checks:

- Compilation of all `scripts/**/*.lua` files without executing game code.
- XML syntax in `modDesc.xml`, GUI files and translations.
- Descriptor root, four-component version, icon and source-file existence,
  duplicate sources, and the declared English localization file.
- Translation structure, required attributes, duplicate keys and English
  translations for GUI `$l10n_` references. Partial translations are valid.

`tests/check_mod.bats` invokes the real validator on temporary miniature mods.
Fixtures are created inside Bats temporary directories and never modify game
saves or installed mods. Add a passing fixture and a rejection case when
extending validation. The tests also cover XML-escaped keys, nested files,
paths containing spaces, missing tools and incompatible Lua versions.

`tests/run.lua` runs the Lua suites with isolated globals and small engine test
doubles. Current suites cover seasonal prices, locale-aware sorting, feed
planner validation/fallback, event serialization and server-authoritative UID
relay. Add cases to the relevant `tests/test_*.lua` file; register new suites
in `tests/run.lua`. For a bug fix, demonstrate the failing case before applying
the fix, then run the complete checks.

These tests do not simulate the GIANTS engine. Before shipping gameplay changes,
test the affected behavior in FS25: resource conservation and storage limits,
save/load, UI interactions, and multiplayer synchronization where relevant.
For multiplayer changes, test a host and two clients, rejoining, different farm
ownership and unauthorized requests. Document anything you could not verify.

## Prepare a contribution

1. Create a branch for one focused change.
2. Keep unrelated files and local editor settings out of the diff.
3. Add or update regression tests and relevant user documentation/translations.
4. Run `make check` (or `make check LUA=luajit`) and `git diff --check`.
5. Open a pull request describing the problem, resulting behavior, checks run
   and any required in-game verification. Include reproduction steps for bugs.

Translation contributors should follow the translation guidance in `README.md`.
Agent guidance is available in `.agents/skills/fs25-localization/SKILL.md`.
`tests/localization.bats` checks shared English formatting and structural
contracts across all locales, allowing missing keys and extra legacy keys.
Completeness is checked separately by `make check-localization-keys` and its
independent CI job. Every locale is compared with English, all missing keys are
reported, and incomplete locales fail that check. Runtime English fallback
remains supported. Extra legacy keys do not compensate for missing keys.
Keep localization key names unchanged; missing translated entries fall back to
English. Development files (`tests/`, `.github/`, `.local/`, Makefile and docs)
are not mod runtime assets and should not be included in the game ZIP.

## Optional agent skills

FS25 agent guidance is included as the `.agents/skills/fs25-upstream` Git
submodule, with a revision pinned by this repository. Initialize it with:

```bash
git submodule update --init --recursive
```

For a new checkout, use `git clone --recurse-submodules <repo-url>`. Repeat the
update command after pulling or switching branches when the pinned revision
changes. These commands also work in Windows PowerShell. The submodule is not
needed to run the mod or `make check`; CI therefore does not fetch it.

See `.agents/skills/README.md` for entry points, license and update policy.
Project-specific guidance belongs in `AGENTS.md`, not in the upstream submodule.

With Make installed, `make skills-init` initializes or synchronizes the skills
submodule to the revision pinned by this repository. It does not advance to the
latest upstream commit. Run this on the host, outside the read-only check container.

## Parallel checks

`make check` runs the seven check types concurrently with grouped output. Set
`CHECK_JOBS=2` to reduce CPU/memory pressure, or `CHECK_JOBS=1` for sequential
execution. Docker's default command uses the same parallel entry point; pass
`make check CHECK_JOBS=2` after the image name to override it. Tests use separate
temporary fixtures and do not write to the checkout.

`tests/ci_tools.bats` covers CI dependency selection, selective linter downloads,
checksum failure handling and propagated installation failures using command
stubs; it never installs packages or downloads tools. Add regression coverage
there when changing CI installation behavior. `make test-bats` discovers
`tests/*.bats` except `tests/localization*.bats`, which run through
`make test-localization` in an independent CI job. Localization failures do not
fail `make test` or the general Bats job. `make check` and Docker still run all
suites and report their failures. Run `make lint-actionlint` and `make lint-zizmor`
independently when diagnosing workflow issues.

## Localization length checks

Run `make check-localization` (or append `LUA=luajit`) to check every
`translations/translation_*.xml`, including English. The independent
**Localization limits (all languages)** CI job runs the same target and reports
all failures in its check step. It does not stop at the first file or phrase.
This target is also included in `make check` and Docker checks.

Each `LIMIT` line contains the filename, localization key, actual Unicode
character count, allowed count and full phrase. For formatted routing labels,
it also prints the rendered sample using that locale's units and Off label
(with English fallback). Output order is deterministic. Invalid XML and format
errors are reported while other files continue to be checked. Any violation or
parsing error fails the command; existing violations are not silently exempted.

The budgets in `tests/check_localization_limits.lua` come from the English
localization comments. They are approximate character budgets, not pixel-width
measurements. Keys without a declared numeric budget are not length-gated, and
partial translations may omit keys. Formatting samples cannot guarantee that
arbitrarily long runtime names or volumes fit. XML parsing is delegated to
XMLStarlet; all extracted labels are checked in a single Lua process. Tests in
`tests/localization_limits.bats` cover the reporting and failure behavior.
