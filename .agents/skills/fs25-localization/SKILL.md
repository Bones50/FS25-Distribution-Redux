---
name: fs25-localization
description: Translate or review Distribution Redux localization XML, preserving runtime keys, formatting, UI limits and FS25 terminology. Use for localization changes and localization validation tests in this repository.
---

# Distribution Redux localization

Read `CONTRIBUTING.md`, the translation guidance in `README.md`, and comments in `translations/translation_en.xml` before editing. Resolve repository paths from the project root.

- Treat English as the reference for meaning and runtime formatting. Inspect the Lua or GUI use of a key when its grammatical role or available width is unclear.
- Preserve every existing `name="..."` identifier exactly. Translate `text="..."` values only; do not rename keys to match translated wording. Preserve locale filenames and language codes unless explicitly requested otherwise.
- Restrict edits to languages requested by the user. Report findings in other languages without silently fixing them. Partial translations are supported through English fallback; do not fill missing entries merely to make key counts equal.
- Preserve format arguments, their order and precision, escaped percent signs, guide heading/list markers, and significant unit spacing or appended numeric signs. Distinguish literal percentages in prose from strings passed to `string.format`; punctuation spacing can legitimately differ by language.
- Check meaning in the production/distribution context: inputs, outputs, storage, routing, capacity, costs and profit are distinct. Use natural grammar around dynamic numbers and building names; prefer neutral labels where plural or case inflection cannot be selected at runtime.
- Follow the length budgets above each English block. Use `tests/check_localization_limits.lua` as the executable budget reference. Tooltips may wrap; short labels and table headers may clip. Character counts are approximations: report any in-game visual checks still needed.
- Keep XML well formed and escape attribute content. XML comments cannot contain double hyphens. Avoid rewriting unrelated XML formatting or metadata. Keep the existing English mod title fallback unless the task explicitly calls for localized titles.

Run focused checks from the repository root:

```bash
LUA=luajit bats tests/localization.bats tests/localization_limits.bats
make check-localization LUA=luajit
```

Use `lua5.1` instead of `luajit` when appropriate. Finish with `make docker-check` or `make check LUA=luajit` as described in `AGENTS.md`. The general contract test compares all present translations with English; the separate localization job reports all length violations. Report pre-existing failures separately from regressions and do not weaken checks or edit unrelated translations to obtain a green result. When modifying a checker, add Bats fixtures for its changed behavior, including partial locales and aggregated diagnostics.
