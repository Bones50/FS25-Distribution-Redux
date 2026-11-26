#!/usr/bin/env bash
# Pinned upstream release archives; installs only into the supplied directory.
set -euo pipefail
[[ $# -ge 1 && $# -le 2 ]] || { echo 'Usage: install-linters.sh DESTINATION [all|actionlint|zizmor]' >&2; exit 2; }
selection=${2:-all}
case $selection in all|actionlint|zizmor) ;; *) echo 'Unknown linter selection' >&2; exit 2 ;; esac
[[ $(uname -s) == Linux ]] || { echo 'This installer supports Linux; see CONTRIBUTING.md.' >&2; exit 1; }
case $(uname -m) in
    x86_64)
        action_arch=amd64
        zizmor_arch=x86_64
        action_sha=8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8
        zizmor_sha=d185f726bdaf92df78273217dfdd24ebcd6b0ef48cf3ce776ff5762b6e138c99
        ;;
    aarch64|arm64)
        action_arch=arm64
        zizmor_arch=aarch64
        action_sha=325e971b6ba9bfa504672e29be93c24981eeb1c07576d730e9f7c8805afff0c6
        zizmor_sha=37eebbd5762a44f262d94875431b14a6d2402991e90a685113ea97b8b41be833
        ;;
    *) echo 'Unsupported architecture; see CONTRIBUTING.md.' >&2; exit 1 ;;
esac
mkdir -p -- "$1"
destination=$(cd -- "$1" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
cd -- "$tmp"
if [[ $selection == all || $selection == actionlint ]]; then
    curl --fail --silent --show-error --location --retry 3 \
    "https://github.com/rhysd/actionlint/releases/download/v1.7.12/actionlint_1.7.12_linux_${action_arch}.tar.gz" -o actionlint.tar.gz
    printf '%s  actionlint.tar.gz\n' "$action_sha" | sha256sum --check --strict
    tar -xzf actionlint.tar.gz actionlint
    install -m 755 actionlint "$destination/"
fi
if [[ $selection == all || $selection == zizmor ]]; then
    curl --fail --silent --show-error --location --retry 3 \
    "https://github.com/zizmorcore/zizmor/releases/download/v1.31.1/zizmor-${zizmor_arch}-unknown-linux-gnu.tar.gz" -o zizmor.tar.gz
    printf '%s  zizmor.tar.gz\n' "$zizmor_sha" | sha256sum --check --strict
    tar -xzf zizmor.tar.gz zizmor
    install -m 755 zizmor "$destination/"
fi
