#!/usr/bin/env bats
setup() {
    root=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
    checker="$root/.github/scripts/check-localization-limits.sh"
    locales="$BATS_TEST_TMPDIR/locales with spaces"
    mkdir -p "$locales"
}

locale_file() {
    printf '<l10n><texts>%s</texts></l10n>\n' "$2" > "$locales/translation_$1.xml"
}

@test 'all files and all over-limit phrases are reported before failure' {
    locale_file aa '<text name="dr_col_dest" text="1234567"/><text name="dr_role_inout" text="12345678"/>'
    locale_file zz '<text name="dr_col_dest" text="123456789"/>'
    run bash "$checker" "$locales"
    [[ $status -eq 1 ]]
    [[ $output == *'translation_aa.xml | dr_col_dest | length=7 limit=6 | text="1234567"'* ]]
    [[ $output == *'translation_aa.xml | dr_role_inout | length=8 limit=7'* ]]
    [[ $output == *'translation_zz.xml | dr_col_dest | length=9 limit=6'* ]]
    [[ $output == *'2 file(s), 3 checks, 3 over-limit result(s)'* ]]
}

@test 'Unicode character limits accept the boundary and reject one extra character' {
    locale_file uk '<text name="dr_col_dest" text="ЖЖЖЖЖЖ"/>'
    run bash "$checker" "$locales"
    [[ $status -eq 0 ]]
    locale_file uk '<text name="dr_col_dest" text="ЖЖЖЖЖЖЖ"/>'
    run bash "$checker" "$locales"
    [[ $status -eq 1 ]]
    [[ $output == *'length=7 limit=6'* ]]
}

@test 'partial translations remain valid and English is checked too' {
    locale_file aa '<text name="unbounded_tooltip" text="A long tooltip has no declared character limit."/>'
    locale_file en '<text name="dr_col_dest" text="1234567"/>'
    run bash "$checker" "$locales"
    [[ $status -eq 1 ]]
    [[ $output == *'translation_en.xml | dr_col_dest'* ]]
    [[ $output == *'2 file(s), 1 checks, 1 over-limit result(s)'* ]]
}

@test 'malformed XML does not hide violations in later files' {
    printf '<broken' > "$locales/translation_aa.xml"
    locale_file zz '<text name="dr_col_dest" text="1234567"/>'
    run bash "$checker" "$locales"
    [[ $status -eq 1 ]]
    [[ $output == *'ERROR translation_aa.xml: cannot parse localization XML'* ]]
    [[ $output == *'LIMIT translation_zz.xml'* ]]
}

@test 'formatted samples use translated units and continue after invalid formats' {
    locale_file aa '<text name="dr_rg_nodeIn" text="%d %s"/>'
    locale_file uk '<text name="dr_rg_nodeRes" text="%s"/><text name="dr_unit_kilolitre" text=" кілолітрів-довга-одиниця"/>'
    run bash "$checker" "$locales"
    [[ $status -eq 1 ]]
    [[ $output == *'ERROR translation_aa.xml | dr_rg_nodeIn'* ]]
    [[ $output == *'LIMIT translation_uk.xml | dr_rg_nodeRes'* ]]
    [[ $output == *'sample="123.123 кілолітрів-довга-одиниця"'* ]]
}

@test 'XML entities and escaped controls do not corrupt row framing' {
    locale_file aa '<text name="dr_col_dest" text="AB&amp;CDE"/><text name="dr_role_inout" text="AB&#9;CD&#10;EF"/>'
    run bash "$checker" "$locales"
    [[ $status -eq 1 ]]
    [[ $output == *'dr_role_inout | length=8 limit=7 | text="AB CD EF"'* ]]
    [[ $output == *'2 checks, 1 over-limit result(s), 0 error(s)'* ]]
}

@test 'empty directories fail clearly' {
    run bash "$checker" "$locales"
    [[ $status -eq 1 ]]
    [[ $output == *'no localization files'* ]]
}

@test 'reports have deterministic key ordering' {
    locale_file aa '<text name="dr_role_inout" text="12345678"/><text name="dr_col_dest" text="1234567"/>'
    run bash "$checker" "$locales"
    [[ $status -eq 1 ]]
    [[ ${lines[0]} == *'dr_col_dest'* ]]
    [[ ${lines[1]} == *'dr_role_inout'* ]]
}

@test 'empty partial translation is valid but an incorrect XML root is rejected' {
    locale_file aa ''
    run bash "$checker" "$locales"
    [[ $status -eq 0 ]]
    printf '<wrong/>' > "$locales/translation_zz.xml"
    run bash "$checker" "$locales"
    [[ $status -eq 1 ]]
    [[ $output == *'ERROR translation_zz.xml'* ]]
}
