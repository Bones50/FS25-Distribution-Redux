#!/usr/bin/env bash
# Install only the tools required by one Ubuntu CI matrix entry.
set -euo pipefail
[[ $# == 1 ]] || { echo 'Usage: install-ci-tools.sh MAKE_TARGET' >&2; exit 2; }
linter=''
case $1 in
    validate) packages=(lua5.1 xmlstarlet) ;;
    check-localization) packages=(lua5.1 xmlstarlet) ;;
    check-localization-keys) packages=(xmlstarlet) ;;
    test-lua) packages=(lua5.1) ;;
    test-bats|test-localization) packages=(lua5.1 xmlstarlet bats) ;;
    lint-shell) packages=(shellcheck) ;;
    lint-actionlint) packages=(shellcheck curl ca-certificates); linter=actionlint ;;
    lint-zizmor) packages=(curl ca-certificates); linter=zizmor ;;
    *) printf 'Unknown check target: %s\n' "$1" >&2; exit 2 ;;
esac
sudo apt-get update
sudo apt-get install --no-install-recommends -y "${packages[@]}"
if [[ -n $linter ]]; then make install-linters "LINTERS=$linter"; fi
