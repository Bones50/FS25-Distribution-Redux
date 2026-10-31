SHELL := /bin/bash
.DEFAULT_GOAL := help
LUA ?= lua5.1
BATS ?= bats
ACTIONLINT ?= actionlint
ZIZMOR ?= zizmor
SHELLCHECK ?= shellcheck
LINTER_DIR ?= $(CURDIR)/.local/bin
export PATH := $(LINTER_DIR):$(PATH)

.PHONY: help check validate test test-lua test-bats lint lint-shell lint-actions install-linters skills-init
help:
	@printf '%s\n' 'make check [LUA=luajit]  Run all validation, tests and linters' \
	  'make validate            Compile Lua and validate XML/assets' \
	  'make test                Run Lua and Bats regression tests' \
	  'make lint                Run ShellCheck, actionlint and zizmor' \
	  'make install-linters     Download pinned actionlint/zizmor (Linux)' \
	  'make docker-check        Build and run all checks in Docker' \
	  'make skills-init         Initialize skills at the pinned revision'
skills-init:
	git submodule update --init --recursive -- .agents/skills/fs25-upstream
check: validate test lint
validate:
	LUA="$(LUA)" bash .github/scripts/check-mod.sh
test: test-lua test-bats
test-lua:
	@test "$$($(LUA) -e 'io.write(_VERSION)')" = 'Lua 5.1' || { echo 'Lua 5.1 or LuaJIT required' >&2; exit 1; }
	$(LUA) tests/run.lua
test-bats:
	LUA="$(LUA)" $(BATS) tests/check_mod.bats
lint: lint-shell lint-actions
lint-shell:
	$(SHELLCHECK) .github/scripts/*.sh tests/*.bats
lint-actions:
	$(ACTIONLINT) -color .github/workflows/*.yml
	$(ZIZMOR) --offline --pedantic .github/workflows
install-linters:
	bash .github/scripts/install-linters.sh "$(LINTER_DIR)"

DOCKER ?= docker
CHECK_IMAGE ?= fs25-distribution-checks
.PHONY: docker-build docker-check
docker-build:
	$(DOCKER) build --file Dockerfile.checks --tag "$(CHECK_IMAGE)" .
docker-check: docker-build
	$(DOCKER) run --rm --mount "type=bind,source=$(CURDIR),target=/workspace,readonly" "$(CHECK_IMAGE)"
