#!/usr/bin/env bash
# check-lang.sh – prüft die Sprachdateien (für Übersetzer und vor jedem Release).
#
#   ./scripts/check-lang.sh
#
# Meldet:
#   FEHLER   Texte, die im Code benutzt werden, aber in lang/en.sh fehlen
#            (würde das Skript mit "unbound variable" abbrechen)
#   FEHLER   Sprachdatei, die sich nicht laden lässt
#   FEHLER   Platzhalter (%s, %d) passen nicht zum englischen Text
#   FEHLER   Region, deren Sprachdatei fehlt
#   fehlt    Texte, die in einer Sprache noch nicht übersetzt sind (erscheinen
#            dann englisch – kein Fehler, aber eine Lücke)
#   unbenutzt  Texte in lang/en.sh, die nirgends im Code vorkommen
# Rückgabe 1, wenn es FEHLER gibt.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR" || exit 1
errors=0

keys_of() { grep -oE '^(T_[A-Z0-9_]+|LANG_NAME)=' "$1" | tr -d '=' | sort -u; }

# Platzhalter eines Textes in einer Sprachdatei, z.B. "%s %d"
placeholders() {
    ( . "$1"; eval "printf '%s' \"\${$2-}\"" ) | grep -oE '%[sd%]' | grep -v '%%' | paste -sd ' '
}

code_files=(scripts/*.sh rootfs/etc/update-motd.d/* rootfs/etc/profile.d/*.sh installer/build-iso.sh)
# ohne Präfixe aus Kommentaren wie "Abschnitt T_SETUP_*"
used="$(grep -ohE '\bT_[A-Z0-9_]+' "${code_files[@]}" | grep -v '_$' | sort -u)"
ref="$(keys_of lang/en.sh)"

for k in $(comm -23 <(echo "$used") <(echo "$ref")); do
    echo "FEHLER  lang/en.sh: $k wird benutzt, ist aber nicht definiert"
    errors=1
done
for k in $(comm -13 <(echo "$used") <(echo "$ref" | grep '^T_')); do
    echo "unbenutzt  lang/en.sh: $k"
done

for f in lang/*.sh; do
    if ! sh -n "$f" 2>/dev/null || ! ( . "$f" ) 2>/dev/null; then
        echo "FEHLER  $f lässt sich nicht laden (Anführungszeichen?)"
        errors=1
        continue
    fi
    [[ $f == lang/en.sh ]] && continue
    missing=0
    for k in $(comm -23 <(echo "$ref") <(keys_of "$f")); do
        echo "fehlt   $f: $k"
        missing=$((missing + 1))
    done
    for k in $(comm -12 <(echo "$ref") <(keys_of "$f")); do
        [[ $k == T_* ]] || continue
        a="$(placeholders lang/en.sh "$k")" b="$(placeholders "$f" "$k")"
        if [[ $a != "$b" ]]; then
            echo "FEHLER  $f: $k hat Platzhalter \"$b\", englisch \"$a\""
            errors=1
        fi
    done
    echo "        $f: $missing fehlende Texte"
done

for f in region/*.conf; do
    t="$(sed -n 's/^TEXTS=//p' "$f")"
    [[ -f lang/$t.sh ]] || { echo "FEHLER  $f: lang/$t.sh fehlt"; errors=1; }
done

(( errors )) && echo "==> Es gibt Fehler." || echo "==> OK"
exit "$errors"
