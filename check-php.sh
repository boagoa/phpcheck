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
printf '\nErgebnis: '
if [ "$found" -eq 1 ]; then
    printf 'PHP oder PHP-bezogene Hinweise gefunden.\n'
else
    printf 'Keine PHP-Hinweise gefunden.\n'
fi
if [ "$incomplete" -eq 1 ]; then printf 'Prüfung unvollständig.\n'; fi
PROBE
)

printf 'PHP-Inventur – %s\n' "$(date -Iseconds)"
printf 'Dateitreffer und Modul-Pakete sind Hinweise, kein Beweis für eine aktive PHP-Runtime.\n'
if [ "$(id -u)" -ne 0 ]; then
    printf 'HINWEIS: Ohne root können Dateien, Prozesse und Docker unzugänglich sein.\n'
fi
printf '\n========== HOST ==========\n'
sh -c "$probe"

printf '\n========== LAUFENDE DOCKER-CONTAINER ==========\n'
if ! command -v docker >/dev/null 2>&1; then
    printf 'Docker-CLI fehlt; Containerprüfung nicht möglich.\n'
    exit 0
fi
printf 'Docker-Kontext: %s\n' "$(docker context show 2>/dev/null || printf unbekannt)"
printf 'Geprüft wird der konfigurierte Docker-Endpunkt (ggf. DOCKER_HOST/DOCKER_CONTEXT).\n'
if ! ids=$(docker ps -q --no-trunc); then
    printf 'PRÜFLÜCKE: Docker nicht erreichbar oder keine Berechtigung.\n'
    exit 0
fi
if [ -z "$ids" ]; then printf 'Keine laufenden Container.\n'; fi
while IFS= read -r cid; do
    [ -n "$cid" ] || continue
    docker inspect --format '\nContainer: {{.Name}} | Image: {{.Config.Image}} | ID: {{.Id}}' "$cid"
    shell=''
    for candidate in /bin/sh /bin/bash /busybox/sh; do
        if docker exec --user 0 "$cid" "$candidate" -c ':' >/dev/null 2>&1; then
            shell=$candidate; break
        fi
    done
    if [ -z "$shell" ]; then
        printf 'PRÜFLÜCKE: Keine nutzbare Shell oder docker exec nicht möglich.\n'
        continue
    fi
    if ! docker exec --user 0 "$cid" "$shell" -c "$probe"; then
        printf 'PRÜFLÜCKE: Containerprüfung fehlgeschlagen.\n'
    fi
done <<< "$ids"
printf '\nFertig. Gestoppte Container, andere Docker-Daemons und ungemountete Datenträger wurden nicht geprüft.\n'
printf 'Keine Treffer sind kein vollständiger Ausschluss (z. B. umbenannte Binaries).\n'

