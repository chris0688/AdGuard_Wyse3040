# i18n.sh – lädt Texte und Regionaleinstellungen (wird mit "." eingebunden).
#
# Auf dem Gerät: /usr/local/share/adguard/i18n.sh
#
#   Region:  /etc/adguard-region.conf (erzeugt von install.sh aus region/<REGION>.conf)
#   Texte:   lang/en.sh, danach lang/<TEXTS>.sh. Was in einer Sprache fehlt,
#            bleibt dadurch automatisch englisch.
#
# Bewusst POSIX-sh (kein Bash), weil auch /etc/profile.d/adguard-setup.sh es lädt.
# Darf unter "set -euo pipefail" laufen.

ADGUARD_SHARE="${ADGUARD_SHARE:-/usr/local/share/adguard}"
ADGUARD_REGION_CONF="${ADGUARD_REGION_CONF:-/etc/adguard-region.conf}"

# adguard_read_conf DATEI SCHLÜSSEL... – liest KEY=WERT-Zeilen (Anführungszeichen
# um den Wert werden entfernt). Nur die genannten Schlüssel, nie als Shell-Code.
adguard_read_conf() {
    _ag_file="$1"
    shift
    while IFS='=' read -r _ag_k _ag_v; do
        for _ag_w in "$@"; do
            if [ "$_ag_k" = "$_ag_w" ]; then
                _ag_v="${_ag_v#\"}"
                _ag_v="${_ag_v%\"}"
                eval "$_ag_k=\$_ag_v"
            fi
        done
    done < "$_ag_file"
    return 0
}

# Standard ohne Regionsdatei: en_US
REGION=en_US TEXTS=en DATE_FORMAT='%m/%d/%Y' DECIMAL='.'
if [ -r "$ADGUARD_REGION_CONF" ]; then
    adguard_read_conf "$ADGUARD_REGION_CONF" REGION TEXTS DATE_FORMAT DECIMAL
fi
case "$TEXTS" in [a-z][a-z]) ;; *) TEXTS=en ;; esac

. "$ADGUARD_SHARE/lang/en.sh"
if [ "$TEXTS" != en ] && [ -r "$ADGUARD_SHARE/lang/$TEXTS.sh" ]; then
    . "$ADGUARD_SHARE/lang/$TEXTS.sh"
fi

# ------------------------------------------------------------ Hilfsfunktionen

# adguard_date [date-Optionen] – Datum + Uhrzeit im Format der Region,
# z.B.  adguard_date -r DATEI   oder   adguard_date -d "2026-10-18 03:30"
adguard_date() {
    date "$@" "+$DATE_FORMAT %H:%M"
}

# adguard_decimal "6.9 GB" -> "6,9 GB" (Dezimaltrennzeichen der Region)
adguard_decimal() {
    if [ "$DECIMAL" = "," ]; then
        printf '%s\n' "$1" | tr . ,
    else
        printf '%s\n' "$1"
    fi
}

# weekday_name 1..7 (1 = Montag) oder Mon..Sun -> Name in der Sprache der Texte
weekday_name() {
    case "$1" in
        Mon) set -- 1 ;; Tue) set -- 2 ;; Wed) set -- 3 ;; Thu) set -- 4 ;;
        Fri) set -- 5 ;; Sat) set -- 6 ;; Sun) set -- 7 ;;
    esac
    _ag_n="$1"
    # shellcheck disable=SC2086  # T_WEEKDAYS: 7 Namen, durch Leerzeichen getrennt
    set -- $T_WEEKDAYS
    eval "printf '%s\n' \"\${$_ag_n}\""
}

# adguard_yesno "Frage" y|n – Ja/Nein-Abfrage, Rückgabewert 0 bei ja.
# Zweites Argument: Standard bei Enter. Akzeptiert in jeder Sprache
# j/ja/y/yes und n/nein/no; bei anderen Eingaben wird erneut gefragt.
adguard_yesno() {
    if [ "$2" = y ]; then _ag_def="$T_YESNO_DEFAULT_YES"; else _ag_def="$T_YESNO_DEFAULT_NO"; fi
    while :; do
        printf '%s [%s]: ' "$1" "$_ag_def" >&2
        read -r _ag_answer || return 1
        [ -n "$_ag_answer" ] || _ag_answer="$2"
        case "$_ag_answer" in
            [jJyY]|[jJ][aA]|[yY][eE][sS])  return 0 ;;
            [nN]|[nN][eE][iI][nN]|[nN][oO]) return 1 ;;
        esac
        printf '\033[1;33m[!] %s\033[0m\n' "$T_YESNO_INVALID" >&2
    done
}

# adguard_reboot_text – eingerichteter regelmäßiger Neustart als Text,
# z.B. "weekly on Sunday at 04:00"; leer, wenn keiner eingerichtet ist.
# Liest den Zeitplan (OnCalendar), nicht die Beschreibung des Timers.
adguard_reboot_text() {
    _ag_timer=/etc/systemd/system/adguard-reboot.timer
    systemctl is-enabled --quiet adguard-reboot.timer 2>/dev/null || return 0
    [ -f "$_ag_timer" ] || return 0
    _ag_cal="$(sed -n 's/^OnCalendar=//p' "$_ag_timer")"
    # "*-*-* 04:00:00" oder "Sun *-*-* 04:00:00"
    _ag_time="$(printf '%s\n' "$_ag_cal" | grep -oE '[0-9]{2}:[0-9]{2}' | head -n1)"
    case "$_ag_cal" in
        '*-*-*'*) printf "$T_REBOOT_DAILY\n" "$_ag_time" ;;
        *)        printf "$T_REBOOT_WEEKLY\n" "$(weekday_name "${_ag_cal%% *}")" "$_ag_time" ;;
    esac
}
