#!/usr/bin/env bats
setup() {
    root=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
    cat > "$BATS_TEST_TMPDIR/bats" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@"
for suite in "$@"; do
    if [[ $suite == tests/localization*.bats ]]; then exit 43; fi
done
SH
    chmod +x "$BATS_TEST_TMPDIR/bats"
}

@test 'general Bats target excludes failing localization suites' {
    run make --no-print-directory -C "$root" test-bats "BATS=$BATS_TEST_TMPDIR/bats"
    [[ $status -eq 0 ]]
    [[ $output == *'tests/check_mod.bats'* ]]
    [[ $output == *'tests/ci_tools.bats'* ]]
    [[ $output != *'tests/localization'* ]]
}

@test 'workflow limits push checks to main and retains pull request checks' {
    # Inspect the trigger block; actionlint validates the full YAML syntax.
    local triggers
    triggers=$(sed -n '/^on:$/,/^permissions:$/p' "$root/.github/workflows/quality.yml")
    [[ $triggers == *$'  push:\n    branches: [main]\n'* ]]
    [[ $triggers == *$'  pull_request:\n'* ]]
    [[ $triggers != *'tags:'* ]]
    [[ $triggers != *'branches-ignore:'* ]]
}

@test 'localization target selects only localization suites and propagates failure' {
    run make --no-print-directory -C "$root" test-localization "BATS=$BATS_TEST_TMPDIR/bats"
    [[ $status -ne 0 ]]
    [[ $output == *'tests/localization.bats'* ]]
    [[ $output == *'tests/localization_limits.bats'* ]]
    [[ $output != *'tests/check_mod.bats'* ]]
    [[ $output != *'tests/ci_tools.bats'* ]]
}
