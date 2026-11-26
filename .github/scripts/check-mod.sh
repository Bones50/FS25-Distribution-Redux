#!/usr/bin/env bash
# XPath matches literal GIANTS $l10n_ references, not shell variables.
# shellcheck disable=SC2016
# Shared by GitHub Actions, Make and the Bats fixture tests.
set -euo pipefail
root=${1:-"$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"}
lua=${LUA:-lua5.1}
for tool in "$lua" xmlstarlet; do
    command -v "$tool" >/dev/null || { printf 'ERROR: required tool not found: %s\n' "$tool" >&2; exit 1; }
done
version=$("$lua" -e 'io.write(_VERSION)')
[[ $version == 'Lua 5.1' ]] || { printf 'ERROR: expected Lua 5.1 compatibility, got %s\n' "$version" >&2; exit 1; }
cd -- "$root"
shopt -s nullglob globstar
errors=0
error() { printf 'ERROR: %s\n' "$*" >&2; errors=$((errors + 1)); }
require_file() { [[ -n $1 && -f $1 ]] || error "$2: missing file '$1'"; }
value() { xmlstarlet sel -t -v "$2" "$1"; }
rows() { xmlstarlet sel -t -m "$2" -v "$3" -n "$1"; }

lua_files=(scripts/**/*.lua)
((${#lua_files[@]})) || error 'scripts/: no Lua files found'
for file in "${lua_files[@]}"; do
    if ! "$lua" - "$file" <<'LUA'
local chunk, err = loadfile(arg[1])
if not chunk then io.stderr:write(err, '\n'); os.exit(1) end
LUA
    then error "$file: Lua compilation failed"; fi
done

gui_files=(gui/**/*.xml)
translation_files=(translations/**/*.xml)
((${#gui_files[@]})) || error 'gui/: no XML files found'
((${#translation_files[@]})) || error 'translations/: no XML files found'
xml_files=(modDesc.xml "${gui_files[@]}" "${translation_files[@]}")
declare -A valid=() english=()
for file in "${xml_files[@]}"; do
    if xmlstarlet val -w -q "$file"; then valid["$file"]=1
    else error "$file: invalid or missing XML"; fi
done

if [[ ${valid[modDesc.xml]:-} ]]; then
    [[ $(value modDesc.xml 'name(/*)') == modDesc ]] || error 'modDesc.xml: expected modDesc root'
    [[ $(value modDesc.xml 'string(/modDesc/version)') =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || error 'modDesc.xml: version must have four numeric components'
    require_file "$(value modDesc.xml 'string(/modDesc/iconFilename)')" 'modDesc.xml iconFilename'
    [[ $(value modDesc.xml 'count(/modDesc/extraSourceFiles/sourceFile)') != 0 ]] || error 'modDesc.xml: no extraSourceFiles'
    while IFS= read -r source; do require_file "$source" 'modDesc.xml sourceFile'; done < <(
        rows modDesc.xml '/modDesc/extraSourceFiles/sourceFile' 'string(@filename)'
    )
    [[ $(value modDesc.xml 'count(/modDesc/extraSourceFiles/sourceFile[@filename = preceding-sibling::sourceFile/@filename])') == 0 ]] || error 'modDesc.xml: duplicate sourceFile'
    prefix=$(value modDesc.xml 'string(/modDesc/l10n/@filenamePrefix)')
    if [[ -n $prefix ]]; then require_file "${prefix}_en.xml" 'modDesc.xml l10n'
    else error 'modDesc.xml: missing l10n filenamePrefix'; fi
fi

for file in "${translation_files[@]}"; do
    [[ ${valid[$file]:-} ]] || continue
    [[ $(value "$file" 'count(/l10n/texts)') != 0 ]] || error "$file: expected l10n/texts structure"
    [[ $(value "$file" 'count(/l10n/texts/text[not(@name) or @name="" or not(@text)])') == 0 ]] || error "$file: translation needs name and text attributes"
    [[ $(value "$file" 'count(/l10n/texts/text[@name = preceding-sibling::text/@name])') == 0 ]] || error "$file: duplicate translation"
done
if [[ ${valid[translations/translation_en.xml]:-} ]]; then
    while IFS= read -r name; do
        [[ -z $name ]] || english["$name"]=1
    done < <(rows translations/translation_en.xml '/l10n/texts/text' '@name')
fi
((${#english[@]})) || error 'translations/translation_en.xml: no English translation keys'
for file in "${gui_files[@]}"; do
    [[ ${valid[$file]:-} ]] || continue
    while IFS= read -r name; do
        [[ -n $name && ${english[$name]:-} ]] || error "$file: missing English translation '$name'"
    done < <(rows "$file" '//@*[starts-with(., "$l10n_")]' 'substring(., 7)')
done
printf 'Checked %d Lua files and %d XML files; %d error(s).\n' "${#lua_files[@]}" "${#xml_files[@]}" "$errors"
((errors == 0))
