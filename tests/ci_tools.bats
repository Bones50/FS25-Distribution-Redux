#!/usr/bin/env bats
setup() {
    bats_require_minimum_version 1.5.0
    root=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
    export CI_TEST_LOG="$BATS_TEST_TMPDIR/commands"
    mkdir "$BATS_TEST_TMPDIR/bin"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    cat > "$BATS_TEST_TMPDIR/bin/sudo" <<'SH'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >> "$CI_TEST_LOG"
exit "${CI_TEST_INSTALL_STATUS:-0}"
SH
    cat > "$BATS_TEST_TMPDIR/bin/make" <<'SH'
#!/usr/bin/env bash
printf 'make %s\n' "$*" >> "$CI_TEST_LOG"
exit "${CI_TEST_MAKE_STATUS:-0}"
SH
    chmod +x "$BATS_TEST_TMPDIR/bin/"*
}

@test 'every CI target installs only its required dependencies' {
    local target expected
    while IFS='|' read -r target expected; do
        : > "$CI_TEST_LOG"
        run bash "$root/.github/scripts/install-ci-tools.sh" "$target"
        [[ $status -eq 0 ]]
        grep -Fx "sudo apt-get install --no-install-recommends -y $expected" "$CI_TEST_LOG"
        case $target in
            lint-actionlint) grep -Fx 'make install-linters LINTERS=actionlint' "$CI_TEST_LOG" ;;
            lint-zizmor) grep -Fx 'make install-linters LINTERS=zizmor' "$CI_TEST_LOG" ;;
            *) run ! grep -q '^make ' "$CI_TEST_LOG" ;;
        esac
    done <<'TARGETS'
validate|lua5.1 xmlstarlet
check-localization|lua5.1 xmlstarlet
check-localization-keys|xmlstarlet
test-lua|lua5.1
test-bats|lua5.1 xmlstarlet bats
test-localization|lua5.1 xmlstarlet bats
lint-shell|shellcheck
lint-actionlint|shellcheck curl ca-certificates
lint-zizmor|curl ca-certificates
TARGETS
}

@test 'unknown or missing CI target fails before installation' {
    run bash "$root/.github/scripts/install-ci-tools.sh" untrusted-target
    [[ $status -eq 2 ]]
    [[ ! -e $CI_TEST_LOG ]]
    run bash "$root/.github/scripts/install-ci-tools.sh"
    [[ $status -eq 2 ]]
    [[ ! -e $CI_TEST_LOG ]]
}

@test 'package failure stops before linter installation' {
    export CI_TEST_INSTALL_STATUS=17
    run bash "$root/.github/scripts/install-ci-tools.sh" lint-zizmor
    [[ $status -eq 17 ]]
    run ! grep -q '^make ' "$CI_TEST_LOG"
}

@test 'linter installation failure propagates' {
    export CI_TEST_MAKE_STATUS=19
    run bash "$root/.github/scripts/install-ci-tools.sh" lint-actionlint
    [[ $status -eq 19 ]]
}

@test 'invalid linter selector fails before creating destination' {
    run bash "$root/.github/scripts/install-linters.sh" "$BATS_TEST_TMPDIR/not-created" invalid
    [[ $status -eq 2 ]]
    [[ ! -e $BATS_TEST_TMPDIR/not-created ]]
}

mock_downloads() {
    cat > "$BATS_TEST_TMPDIR/bin/curl" <<'SH'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >> "$CI_TEST_LOG"
SH
    cat > "$BATS_TEST_TMPDIR/bin/sha256sum" <<'SH'
#!/usr/bin/env bash
cat >> "$CI_TEST_LOG"
exit "${CI_TEST_CHECKSUM_STATUS:-0}"
SH
    for tool in tar install; do
        cat > "$BATS_TEST_TMPDIR/bin/$tool" <<'SH'
#!/usr/bin/env bash
printf '%s %s\n' "${0##*/}" "$*" >> "$CI_TEST_LOG"
SH
    done
    chmod +x "$BATS_TEST_TMPDIR/bin/"*
}

@test 'linter selection downloads and installs only the requested binaries' {
    mock_downloads
    local selection tool
    for selection in actionlint zizmor all; do
        : > "$CI_TEST_LOG"
        run bash "$root/.github/scripts/install-linters.sh" "$BATS_TEST_TMPDIR/output" "$selection"
        [[ $status -eq 0 ]]
        for tool in actionlint zizmor; do
            if [[ $selection == all || $selection == "$tool" ]]; then
                grep -F -- "-o $tool.tar.gz" "$CI_TEST_LOG"
                grep -F "install -m 755 $tool " "$CI_TEST_LOG"
            else
                run ! grep -F -- "-o $tool.tar.gz" "$CI_TEST_LOG"
                run ! grep -F "install -m 755 $tool " "$CI_TEST_LOG"
            fi
        done
    done
}

@test 'checksum failure prevents extraction and installation' {
    mock_downloads
    export CI_TEST_CHECKSUM_STATUS=1
    run bash "$root/.github/scripts/install-linters.sh" "$BATS_TEST_TMPDIR/output" actionlint
    [[ $status -ne 0 ]]
    run ! grep -E '^(tar|install) ' "$CI_TEST_LOG"
}
