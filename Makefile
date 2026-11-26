SHELL := /bin/bash
.DEFAULT_GOAL := help
LUA ?= lua5.1
BATS ?= bats
ACTIONLINT ?= actionlint
ZIZMOR ?= zizmor
SHELLCHECK ?= shellcheck
CHECK_JOBS ?= 7
LOCALIZATION_BATS := $(wildcard tests/localization*.bats)
.PHONY: check-localization-keys
check-localization-keys:
	bash .github/scripts/check-localization-keys.sh
GENERAL_BATS := $(filter-out $(LOCALIZATION_BATS),$(wildcard tests/*.bats))
LINTERS ?= all
LINTER_DIR ?= $(CURDIR)/.local/bin
export PATH := $(LINTER_DIR):$(PATH)

.PHONY: help check check-localization validate test test-lua test-bats test-localization lint lint-shell lint-actions lint-actionlint lint-zizmor install-linters skills-init
help:
	@printf '%s\n' 'make check [LUA=luajit]  Run all validation, tests and linters' \
	  'make validate            Compile Lua and validate XML/assets' \
	  'make check-localization  Report over-limit labels in every locale' \
	  'make check-localization-keys  Report missing English keys per locale' \
	  'make test                Run Lua and Bats regression tests' \
	  'make test-localization   Run localization Bats tests separately' \
	  'make lint                Run ShellCheck, actionlint and zizmor' \
	  'make lint-actionlint     Run actionlint only' \
	  'make lint-zizmor         Run zizmor only' \
	  'make install-linters     Download pinned actionlint/zizmor (Linux)' \
	  'make docker-check        Build and run all checks in Docker' \
	  'make skills-init         Initialize skills at the pinned revision'
skills-init:
	git submodule update --init --recursive -- .agents/skills/fs25-upstream
check:
	+$(MAKE) --keep-going --jobs=$(CHECK_JOBS) --output-sync=target validate test lint test-localization check-localization check-localization-keys
check-localization:
	LUA="$(LUA)" bash .github/scripts/check-localization-limits.sh
validate:
	LUA="$(LUA)" bash .github/scripts/check-mod.sh
test: test-lua test-bats
test-lua:
	@test "$$($(LUA) -e 'io.write(_VERSION)')" = 'Lua 5.1' || { echo 'Lua 5.1 or LuaJIT required' >&2; exit 1; }
	$(LUA) tests/run.lua
test-bats:
	LUA="$(LUA)" $(BATS) $(GENERAL_BATS)
test-localization:
	LUA="$(LUA)" $(BATS) $(LOCALIZATION_BATS)
lint: lint-shell lint-actions
lint-shell:
	$(SHELLCHECK) .github/scripts/*.sh tests/*.bats
lint-actions: lint-actionlint lint-zizmor
lint-actionlint:
	$(ACTIONLINT) -color .github/workflows/*.yml
lint-zizmor:
	$(ZIZMOR) --offline --pedantic .github/workflows
install-linters:
	bash .github/scripts/install-linters.sh "$(LINTER_DIR)" "$(LINTERS)"

DOCKER ?= docker
CHECK_IMAGE ?= fs25-distribution-checks
.PHONY: docker-build docker-check
docker-build:
	$(DOCKER) build --file Dockerfile.checks --tag "$(CHECK_IMAGE)" .
docker-check: docker-build
	$(DOCKER) run --rm --mount "type=bind,source=$(CURDIR),target=/workspace,readonly" "$(CHECK_IMAGE)"
