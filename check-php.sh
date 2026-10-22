#!/usr/bin/env bash
# Linux: PHP-Inventur auf dem Host und in laufenden Docker-Containern.
# Aufruf: sudo bash check-php.sh
# Rein lesende Prüfung; docker exec startet lediglich eine Prüf-Shell.
set -uo pipefail

probe=$(cat <<'PROBE'
found=0
incomplete=0
section() { printf '\n--- %s ---\n' "$1"; }
section 'PHP im PATH'
for name in php php-cgi php-fpm phpdbg php5 php7 php8 php8.1 php8.2 php8.3 php8.4 php8.5; do
    p=$(command -v "$name" 2>/dev/null) || continue
    printf '%s\n' "$p"
    found=1
done
section 'Installierte Pakete (auch Bibliotheken/Module als Hinweise)'
packages=''
if command -v dpkg-query >/dev/null 2>&1; then
    packages=$(dpkg-query -W -f='${db:Status-Status} ${binary:Package} ${Version}\n' 2>/dev/null | awk '$1 == "installed" && tolower($2) ~ /php/ {print}')
elif command -v rpm >/dev/null 2>&1; then
    packages=$(rpm -qa 2>/dev/null | awk 'tolower($0) ~ /php/')
elif command -v apk >/dev/null 2>&1; then
    packages=$(apk info 2>/dev/null | awk 'tolower($0) ~ /php/')
elif command -v pacman >/dev/null 2>&1; then
    packages=$(pacman -Q 2>/dev/null | awk 'tolower($1) ~ /php/')
else
    printf 'Kein unterstützter Paketmanager gefunden.\n'
    incomplete=1
fi
if [ -n "$packages" ]; then printf '%s\n' "$packages"; found=1; fi
section 'Laufende PHP-Prozesse (Prozessname, keine Argumente)'
if [ -d /proc/1 ]; then
    for p in /proc/[0-9]*/comm; do
        [ -r "$p" ] || continue
        IFS= read -r comm < "$p" || continue
        case "$comm" in
            *php*|*PHP*) printf 'PID %s: %s\n' "$(printf '%s' "$p" | cut -d/ -f3)" "$comm"; found=1 ;;
        esac
    done
else
    printf '/proc nicht verfügbar.\n'; incomplete=1
fi
section 'Dateisuche: PHP-Binaries, Module und Konfigurationen'
printf 'Durchsuche alle erreichbaren Dateisysteme; /proc, /sys und /dev ausgenommen.\n'
if command -v find >/dev/null 2>&1; then
    # Kein Ausführen unbekannter Binaries. Beliebig umbenannte/statisch eingebettete
    # PHP-Runtimes sind anhand des Dateinamens nicht zuverlässig erkennbar.
    matches=$(find / \( -path /proc -o -path /sys -o -path /dev \) -prune -o \
        \( -type f -o -type l \) \( -name 'php' -o -name 'php[0-9]*' \
        -o -name 'php-fpm*' -o -name 'php-cgi*' -o -name 'phpdbg*' \
        -o -name 'libphp*.so' -o -name 'php.ini' -o -name 'php-fpm.conf' \) -print)
    result=$?
    if [ -n "$matches" ]; then printf '%s\n' "$matches"; found=1; fi
    if [ "$result" -ne 0 ]; then
        printf 'PRÜFLÜCKE: Dateisuche meldete Fehler (siehe Fehlermeldungen).\n'
        incomplete=1
    fi
else
    printf 'PRÜFLÜCKE: find fehlt.\n'; incomplete=1
fi
printf '\n__PHP_RESULT__ %s %s\n' "$found" "$incomplete"

PROBE
)


# Farben nur auf einem Terminal; NO_COLOR deaktiviert sie explizit.
reset='' blue='' green='' yellow='' bold=''
if [[ -t 1 && ${TERM:-dumb} != dumb && ! ${NO_COLOR+x} ]]; then
    reset=$'\033[0m'; blue=$'\033[36m'; green=$'\033[32m'
    yellow=$'\033[33m'; bold=$'\033[1m'
fi
heading() { printf '\n%s%s%s\n' "$bold$blue" "$1" "$reset"; }
info() { printf '  %s[i]%s %s\n' "$blue" "$reset" "$1"; }
warn() { printf '  %s[!]%s %s\n' "$yellow" "$reset" "$1"; }
labels=(); findings=(); gaps=()
run_probe() {
    local label=$1 output rc line marked=0 hit=0 gap=0
    shift
    heading "$label"
    output=$("$@" 2>&1); rc=$?
    while IFS= read -r line; do
        case "$line" in
            '__PHP_RESULT__ '*)
                read -r _ hit gap <<< "$line"
                marked=1 ;;
            '--- '*) printf '\n  %s%s%s\n' "$bold" "${line//---/}" "$reset" ;;
            *PRÜFLÜCKE*|*'Permission denied'*|*'nicht verfügbar'*|*'Kein unterstützter'*)
                warn "$line" ;;
            '') ;;
            *) printf '    %s\n' "$line" ;;
        esac
    done <<< "$output"
    if (( rc != 0 || marked == 0 )); then gap=1; warn 'Prüfung abgebrochen oder nicht ausführbar.'; fi
    labels+=("$label"); findings+=("$hit"); gaps+=("$gap")
    if (( hit )); then warn 'PHP-Hinweise gefunden'; else info 'Keine PHP-Hinweise gefunden'; fi
    if (( gap )); then warn 'Prüfung unvollständig'; fi
}

heading 'PHP-INVENTUR'
info "Start: $(date -Iseconds)"
info 'Rein lesend. Die vollständige Dateisuche kann einige Zeit dauern.'
if (( EUID != 0 )); then warn 'Ohne root sind Zugriffs- und Sichtbarkeitslücken möglich.'; fi
run_probe 'HOST' sh -c "$probe"
# Ohne root ist selbst eine fehlerfreie Suche kein vollständiger Systemcheck.
if (( EUID != 0 )); then gaps[0]=1; fi

heading 'DOCKER'
docker_note=''
if ! command -v docker >/dev/null 2>&1; then
    docker_note='Nicht geprüft: Docker-CLI fehlt.'
    warn "$docker_note"
elif ! ids=$(docker ps -q --no-trunc 2>&1); then
    docker_note='Nicht geprüft: Docker nicht erreichbar / keine Berechtigung.'
    warn "$docker_note"
    printf '    %s\n' "$ids"
else
    info "Kontext: $(docker context show 2>/dev/null || printf unbekannt)"
    info 'Es wird nur der konfigurierte Docker-Endpunkt geprüft.'
    if [[ -z $ids ]]; then docker_note='Keine laufenden Container.'; info "$docker_note"; fi
    while IFS= read -r cid; do
        [[ -n $cid ]] || continue
        name=$(docker inspect --format '{{.Name}}' "$cid" 2>/dev/null) || name=$cid
        name=${name#/}
        image=$(docker inspect --format '{{.Config.Image}}' "$cid" 2>/dev/null) || image='unbekannt'
        shell=''
        for candidate in /bin/sh /bin/bash /busybox/sh; do
            if docker exec --user 0 "$cid" "$candidate" -c ':' >/dev/null 2>&1; then
                shell=$candidate; break
            fi
        done
        if [[ -z $shell ]]; then
            heading "CONTAINER: $name"
            warn 'Keine nutzbare Shell oder docker exec nicht möglich.'
            labels+=("Container: $name"); findings+=(0); gaps+=(1)
            continue
        fi
        info "Image: $image"
        run_probe "Container: $name" docker exec --user 0 "$cid" "$shell" -c "$probe"
    done <<< "$ids"
fi

heading 'ZUSAMMENFASSUNG'
printf '  %-30s | %-20s | %s\n' 'Ziel' 'PHP-Hinweise' 'Prüfung'
printf '  %s\n' '-------------------------------+----------------------+----------------'
hits=0; incomplete=0
for (( i=0; i<${#labels[@]}; i++ )); do
    status='Keine gefunden'; color=$green; coverage='Durchgelaufen'
    if (( findings[i] )); then status='GEFUNDEN'; color=$yellow; ((hits+=1)); fi
    if (( gaps[i] )); then coverage='UNVOLLSTÄNDIG'; color=$yellow; ((incomplete+=1)); fi
    printf '  %-30s | %s%-20s%s | %s\n' "${labels[i]}" "$color" "$status" "$reset" "$coverage"
done
printf '\n'
info "${#labels[@]} Ziele · $hits mit Hinweisen · $incomplete unvollständig geprüft"
[[ -z $docker_note ]] || warn "Docker: $docker_note"
info 'Pakete, Module und Konfigurationsdateien können auch Installationsreste sein.'
info 'Dateitreffer in Docker-Speicherverzeichnissen des Hosts können zu Images gehören.'
info 'Nicht erfasst: gestoppte Container, andere Daemons, ungemountete Datenträger.'
info 'Keine Treffer schließen umbenannte oder eingebettete PHP-Runtimes nicht aus.'
