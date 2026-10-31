#!/usr/bin/env bats
setup() {
    root=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
    checker="$root/tests/check_localization_contracts.lua"
}

@test 'all localizations preserve shared English formatting and structural contracts' {
    local file name
    local -a locales=()
    for file in "$root"/translations/translation_*.xml; do
        name=${file##*/}
        xmlstarlet sel -T -t -m '/l10n/texts/text' -v '@name' -o $'\t' -v '@text' -n -b -n \
            "$file" > "$BATS_TEST_TMPDIR/$name.tsv"
        if [[ $name != translation_en.xml ]]; then locales+=("$BATS_TEST_TMPDIR/$name.tsv"); fi
    done
    "${LUA:-lua5.1}" "$checker" "$BATS_TEST_TMPDIR/translation_en.xml.tsv" "${locales[@]}"
}

@test 'partial locales and extra legacy keys do not require complete English coverage' {
    printf 'label\tValue %%s\nmissing\tMay fall back\n' > "$BATS_TEST_TMPDIR/en.tsv"
    printf 'label\tЗначення %%s\nlegacy\tLegacy text\n' > "$BATS_TEST_TMPDIR/uk.tsv"
    run "${LUA:-lua5.1}" "$checker" "$BATS_TEST_TMPDIR/en.tsv" "$BATS_TEST_TMPDIR/uk.tsv"
    [[ $status -eq 0 ]]
}

@test 'contract checker reports errors across multiple locales and keys' {
    printf 'label\tValue %%s\ndr_guide_1\t## Heading\ndr_unit_litre\t L\ndr_money_sales\tSales: -\n' > "$BATS_TEST_TMPDIR/en.tsv"
    printf 'label\tValue %%d\ndr_guide_1\tHeading\n' > "$BATS_TEST_TMPDIR/aa.tsv"
    printf 'dr_unit_litre\tL\ndr_money_sales\tSales\n' > "$BATS_TEST_TMPDIR/zz.tsv"
    run "${LUA:-lua5.1}" "$checker" "$BATS_TEST_TMPDIR/en.tsv" "$BATS_TEST_TMPDIR/aa.tsv" "$BATS_TEST_TMPDIR/zz.tsv"
    [[ $status -eq 1 ]]
    [[ $output == *'aa.tsv | label | format arguments differ'* ]]
    [[ $output == *'aa.tsv | dr_guide_1 | guide structure differs'* ]]
    [[ $output == *'zz.tsv | dr_unit_litre | leading spaces differ'* ]]
    [[ $output == *'zz.tsv | dr_money_sales | money sign differs'* ]]
    [[ $output == *'4 error(s)'* ]]
}
