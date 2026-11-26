#!/usr/bin/env bats
setup() {
    root=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
    checker="$root/.github/scripts/check-localization-keys.sh"
    mkdir "$BATS_TEST_TMPDIR/locales"
    locales="$BATS_TEST_TMPDIR/locales"
    printf '<l10n><texts><text name="a" text="A"/><text name="b" text="B"/></texts></l10n>' > "$locales/translation_en.xml"
}

@test 'complete translations allow extra keys and different ordering' {
    printf '<l10n><texts><text name="b"/><text name="extra"/><text name="a"/></texts></l10n>' > "$locales/translation_aa.xml"
    run bash "$checker" "$locales"
    [[ $status -eq 0 ]]
    [[ $output == *'KEYS translation_aa.xml | missing=0'* ]]
}

@test 'all missing keys are reported separately for every incomplete locale' {
    printf '<l10n><texts/></l10n>' > "$locales/translation_aa.xml"
    printf '<l10n><texts><text name="a"/></texts></l10n>' > "$locales/translation_zz.xml"
    run bash "$checker" "$locales"
    [[ $status -eq 1 ]]
    [[ $output == *'MISSING translation_aa.xml | a'* ]]
    [[ $output == *'MISSING translation_aa.xml | b'* ]]
    [[ $output == *'MISSING translation_zz.xml | b'* ]]
    [[ $output == *'KEYS translation_aa.xml | missing=2'* ]]
    [[ $output == *'KEYS translation_zz.xml | missing=1'* ]]
}

@test 'invalid locale does not hide missing keys in subsequent locales' {
    printf '<wrong/>' > "$locales/translation_aa.xml"
    printf '<l10n><texts/></l10n>' > "$locales/translation_zz.xml"
    run bash "$checker" "$locales"
    [[ $status -eq 1 ]]
    [[ $output == *'ERROR translation_aa.xml'* ]]
    [[ $output == *'MISSING translation_zz.xml | b'* ]]
}

@test 'missing or empty English reference fails clearly' {
    printf '<l10n><texts/></l10n>' > "$locales/translation_en.xml"
    run bash "$checker" "$locales"
    [[ $status -eq 1 ]]
    [[ $output == *'English reference contains no keys'* ]]
    rm "$locales/translation_en.xml"
    run bash "$checker" "$locales"
    [[ $status -ne 0 ]]
}
