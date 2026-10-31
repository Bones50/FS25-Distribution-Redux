#!/usr/bin/env bats
# Localization keys intentionally contain literal dollar signs.
# shellcheck disable=SC2016
# Exercise the production validator against isolated miniature mods.
setup() {
    validator="$BATS_TEST_DIRNAME/../.github/scripts/check-mod.sh"
    fixture="$BATS_TEST_TMPDIR/mod with spaces"
    mkdir -p "$fixture/scripts" "$fixture/gui" "$fixture/translations"
    printf '%s\n' 'return 1' > "$fixture/scripts/main.lua"
    printf '%s\n' 'fixture' > "$fixture/icon.dds"
    cat > "$fixture/modDesc.xml" <<'XML'
<modDesc><version>1.0.0.0</version><iconFilename>icon.dds</iconFilename>
<extraSourceFiles><sourceFile filename="scripts/main.lua"/></extraSourceFiles>
<l10n filenamePrefix="translations/translation"/></modDesc>
XML
    printf '%s\n' '<l10n><texts><text name="label" text="Label"/></texts></l10n>' > "$fixture/translations/translation_en.xml"
    printf '%s\n' '<GUI><Text text="$l10n_label"/></GUI>' > "$fixture/gui/menu.xml"
}

check_fails() {
    run bash "$validator" "$fixture"
    [[ $status -ne 0 ]]
    [[ $output == *"$1"* ]]
}

@test 'valid mod and partial translation pass' {
    printf '%s\n' '<l10n><texts/></l10n>' > "$fixture/translations/translation_uk.xml"
    run bash "$validator" "$fixture"
    [[ $status -eq 0 ]]
    [[ $output == *'0 error(s)'* ]]
}

@test 'Lua is compiled without executing game calls' {
    printf '%s\n' 'error("must not execute")' 'g_missingGame:method()' > "$fixture/scripts/main.lua"
    run bash "$validator" "$fixture"
    [[ $status -eq 0 ]]
}

@test 'invalid Lua fails validation' {
    printf '%s\n' 'function broken(' > "$fixture/scripts/main.lua"
    check_fails 'Lua compilation failed'
}

@test 'malformed XML fails validation' {
    printf '%s\n' '<GUI>' > "$fixture/gui/menu.xml"
    check_fails 'gui/menu.xml: invalid or missing XML'
}

@test 'missing source file fails validation' {
    rm "$fixture/scripts/main.lua"
    check_fails "missing file 'scripts/main.lua'"
}

@test 'duplicate source references fail validation' {
    sed -i 's|</extraSourceFiles>|<sourceFile filename="scripts/main.lua"/></extraSourceFiles>|' "$fixture/modDesc.xml"
    check_fails 'duplicate sourceFile'
}

@test 'invalid version fails validation' {
    sed -i 's/1.0.0.0/1.0/' "$fixture/modDesc.xml"
    check_fails 'version must have four numeric components'
}

@test 'duplicate translations fail validation' {
    printf '%s\n' '<l10n><texts><text name="label" text="a"/><text name="label" text="b"/></texts></l10n>' > "$fixture/translations/translation_en.xml"
    check_fails 'duplicate translation'
}

@test 'missing English GUI translation fails validation' {
    printf '%s\n' '<GUI text="$l10n_missing"/>' > "$fixture/gui/menu.xml"
    check_fails "missing English translation 'missing'"
}

@test 'missing text attribute fails validation' {
    printf '%s\n' '<l10n><texts><text name="label"/></texts></l10n>' > "$fixture/translations/translation_uk.xml"
    check_fails 'translation needs name and text attributes'
}

@test 'missing English localization fails validation' {
    rm "$fixture/translations/translation_en.xml"
    check_fails 'no English translation keys'
}

@test 'missing icon fails validation' {
    rm "$fixture/icon.dds"
    check_fails "missing file 'icon.dds'"
}

@test 'wrong descriptor root fails validation' {
    sed -i 's/modDesc/wrongRoot/g' "$fixture/modDesc.xml"
    check_fails 'expected modDesc root'
}

@test 'source filenames containing spaces are preserved' {
    mv "$fixture/scripts/main.lua" "$fixture/scripts/main script.lua"
    sed -i 's/main.lua/main script.lua/' "$fixture/modDesc.xml"
    run bash "$validator" "$fixture"
    [[ $status -eq 0 ]]
}

@test 'empty source filename fails validation' {
    sed -i 's/filename="scripts\/main.lua"/filename=""/' "$fixture/modDesc.xml"
    check_fails "missing file ''"
}

@test 'nested Lua and GUI files are checked' {
    mkdir -p "$fixture/scripts/nested" "$fixture/gui/nested"
    printf '%s\n' 'local =' > "$fixture/scripts/nested/bad.lua"
    printf '%s\n' '<GUI text="$l10n_missing"/>' > "$fixture/gui/nested/menu.xml"
    check_fails 'Lua compilation failed'
    [[ $output == *"missing English translation 'missing'"* ]]
}

@test 'missing Lua executable fails clearly' {
    run env LUA=nonexistent-dr-lua bash "$validator" "$fixture"
    [[ $status -ne 0 ]]
    [[ $output == *'required tool not found: nonexistent-dr-lua'* ]]
}

@test 'Lua 5.4 is rejected before tests run' {
    printf '#!/usr/bin/env bash\nprintf "Lua 5.4"\n' > "$BATS_TEST_TMPDIR/fake-lua"
    chmod +x "$BATS_TEST_TMPDIR/fake-lua"
    run env LUA="$BATS_TEST_TMPDIR/fake-lua" bash "$validator" "$fixture"
    [[ $status -ne 0 ]]
    [[ $output == *'expected Lua 5.1 compatibility, got Lua 5.4'* ]]
}

@test 'XML-escaped keys are matched as decoded values' {
    printf '%s\n' '<l10n><texts><text name="a&amp;b" text="Label"/></texts></l10n>' > "$fixture/translations/translation_en.xml"
    printf '%s\n' '<GUI text="$l10n_a&amp;b"/>' > "$fixture/gui/menu.xml"
    run bash "$validator" "$fixture"
    [[ $status -eq 0 ]]
}

@test 'empty GUI localization key fails with a diagnostic' {
    printf '%s\n' '<GUI text="$l10n_"/>' > "$fixture/gui/menu.xml"
    check_fails "missing English translation ''"
}
