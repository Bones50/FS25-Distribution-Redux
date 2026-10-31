#!/usr/bin/env bash
# Report missing English keys for every translation without stopping at one locale.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
directory=${1:-"$root/translations"}
export LC_ALL=C
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
extract_keys() {
    xmlstarlet val -w "$1" >/dev/null || return 1
    [[ $(xmlstarlet sel -t -v 'count(/l10n/texts)' "$1") == 1 ]] || return 1
    xmlstarlet sel -T -t -m '/l10n/texts/text' -v '@name' -n -b -n "$1" | sed '/^$/d' | sort -u
}
extract_keys "$directory/translation_en.xml" > "$scratch/english"
[[ -s $scratch/english ]] || { echo 'English reference contains no keys' >&2; exit 1; }
shopt -s nullglob
files=("$directory"/translation_*.xml)
failed=0
for file in "${files[@]}"; do
    [[ ${file##*/} == translation_en.xml ]] && continue
    if ! extract_keys "$file" > "$scratch/locale"; then
        printf 'ERROR %s | invalid localization XML\n' "${file##*/}"
        failed=1
        continue
    fi
    comm -23 "$scratch/english" "$scratch/locale" > "$scratch/missing"
    while IFS= read -r key; do
        printf 'MISSING %s | %s\n' "${file##*/}" "$key"
    done < "$scratch/missing"
    printf 'KEYS %s | missing=%s\n' "${file##*/}" "$(wc -l < "$scratch/missing")"
    if [[ -s $scratch/missing ]]; then failed=1; fi
done
exit "$failed"
