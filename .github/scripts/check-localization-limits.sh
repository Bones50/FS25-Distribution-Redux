#!/usr/bin/env bash
# Extract every locale once, then report all budget violations in one Lua process.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
directory=${1:-"$root/translations"}
lua=${LUA:-lua5.1}
for tool in "$lua" xmlstarlet; do
    command -v "$tool" >/dev/null || { printf 'ERROR: required tool not found: %s\n' "$tool" >&2; exit 1; }
done
[[ $("$lua" -e 'io.write(_VERSION)') == 'Lua 5.1' ]] || { echo 'ERROR: Lua 5.1 or LuaJIT required' >&2; exit 1; }
export LC_ALL=C
shopt -s nullglob
files=("$directory"/translation_*.xml)
((${#files[@]})) || { printf 'ERROR: no localization files in %s\n' "$directory" >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
args=()
failed=0
xml_errors=0
index=0
for file in "${files[@]}"; do
    index=$((index + 1))
    # Keep the TSV framing safe for XML attributes containing escaped controls.
    # For the single-line label budgets, tabs and line breaks count as spaces.
    if xmlstarlet val -w -q "$file" &&
       [[ $(xmlstarlet sel -t -v 'count(/l10n/texts)' "$file") == 1 ]] &&
       xmlstarlet sel -T -t -m '/l10n/texts/text' -v '@name' -o $'\t' \
           -v $'translate(@text, "\t\r\n", "   ")' -n -b -n "$file" > "$tmp/$index.tsv"; then
        args+=("${file##*/}" "$tmp/$index.tsv")
    else
        printf 'ERROR %s: cannot parse localization XML\n' "${file##*/}" >&2
        failed=1
        xml_errors=$((xml_errors + 1))
    fi
done
if ((${#args[@]})); then
    "$lua" "$root/tests/check_localization_limits.lua" "${args[@]}" || failed=1
fi
printf 'Scanned %d localization file(s); %d XML error(s).\n' "${#files[@]}" "$xml_errors"
exit "$failed"
