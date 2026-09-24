#!/usr/bin/env bash
# websrocks.com — jednorazowa konfiguracja VPS, KROK 1 z 2 (PRZED zmianą DNS).
#
# Uruchom na VPS (komendę z konkretnym commitem dostajesz w README / od Claude):
#   curl -fsSL https://raw.githubusercontent.com/bednarczykm/websrocks/<commit>/deploy/vps-setup.sh -o /tmp/websrocks-setup.sh
#   sudo bash /tmp/websrocks-setup.sh <commit>
#
# Co robi:
#   1. katalog strony /var/www/websrocks (właściciel gh-deploy) + katalog wyzwań certbota,
#   2. klucz deployu GitHub Actions w authorized_keys użytkownika gh-deploy — z wymuszoną
#      komendą rrsync: ten klucz umie TYLKO wgrywać pliki do /var/www/websrocks
#      (bez powłoki, bez sudo, bez przekierowań portów),
#   3. vhost nginx websrocks.com w wersji startowej (tylko HTTP) — certyfikat robi krok 2
#      (deploy/vps-cert.sh), gdy domena będzie już wskazywać ten serwer.
# Skrypt można bezpiecznie uruchomić ponownie. Nie rusza innych stron na serwerze.
set -euo pipefail

REF="${1:-main}"
RAW="https://raw.githubusercontent.com/bednarczykm/websrocks/${REF}"
DOMAIN="websrocks.com"
VPS_IP="89.167.14.46"   # testy idą przez publiczne IP — 127.0.0.1 trafia na tym serwerze do innego vhosta
WEBROOT="/var/www/websrocks"
ACME_ROOT="/var/www/certbot"
DEPLOY_USER="gh-deploy"
DEPLOY_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICsmvITDXlvbF8i8ui8HglTuVCY3pGvtmZA3CbiMPIvF websrocks-deploy (GitHub Actions)"
VHOST="/etc/nginx/sites-available/${DOMAIN}"
VHOST_LINK="/etc/nginx/sites-enabled/${DOMAIN}"

say()  { printf '\n==> %s\n' "$*"; }
fail() { printf '\n❌ %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || fail "Uruchom przez sudo: sudo bash $0 ${REF}"
getent passwd "$DEPLOY_USER" >/dev/null || fail "Brak użytkownika ${DEPLOY_USER} na tym serwerze."
DEPLOY_HOME="$(getent passwd "$DEPLOY_USER" | cut -d: -f6)"
command -v nginx >/dev/null || fail "Brak nginx na tym serwerze."

say "Sprawdzam, czy żaden inny vhost nie obsługuje już ${DOMAIN}"
others="$(grep -RlE "server_name[^;]*[[:space:]](www\.)?websrocks\.com[[:space:];]" \
    /etc/nginx/sites-enabled/ /etc/nginx/conf.d/ 2>/dev/null | grep -vx "$VHOST_LINK" || true)"
[ -z "$others" ] || fail "websrocks.com jest już w innym pliku nginx: ${others} — przerwane, nic nie zmieniono."

say "rsync + rrsync (wgrywanie plików ograniczone do jednego katalogu)"
command -v rsync >/dev/null || { apt-get update -qq && apt-get install -y -qq rsync; }
RRSYNC="$(command -v rrsync || true)"
if [ -z "$RRSYNC" ]; then
    if [ -f /usr/share/doc/rsync/scripts/rrsync.gz ]; then
        gunzip -c /usr/share/doc/rsync/scripts/rrsync.gz > /usr/local/bin/rrsync
    elif [ -f /usr/share/doc/rsync/scripts/rrsync ]; then
        cp /usr/share/doc/rsync/scripts/rrsync /usr/local/bin/rrsync
    else
        fail "Nie znalazłem rrsync (pakiet rsync)."
    fi
    chmod 755 /usr/local/bin/rrsync
    RRSYNC="/usr/local/bin/rrsync"
fi
echo "rrsync: ${RRSYNC}"

say "Katalogi: ${WEBROOT} (właściciel ${DEPLOY_USER}), ${ACME_ROOT}"
[ -d "$ACME_ROOT" ] || install -d -m 755 "$ACME_ROOT"   # wspólny z innymi domenami — istniejącego nie ruszam
install -d -m 755 "$WEBROOT"
chown "${DEPLOY_USER}:${DEPLOY_USER}" "$WEBROOT"
chmod 755 "$WEBROOT"

say "Klucz deployu GitHub Actions → ${DEPLOY_HOME}/.ssh/authorized_keys"
install -d -m 700 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "${DEPLOY_HOME}/.ssh"
AUTH="${DEPLOY_HOME}/.ssh/authorized_keys"
touch "$AUTH"
KEY_BODY="$(printf '%s' "$DEPLOY_KEY" | awk '{print $2}')"
if grep -qF "$KEY_BODY" "$AUTH"; then
    echo "Klucz już jest — bez zmian."
else
    cp -p "$AUTH" "${AUTH}.bak-$(date +%F-%H%M%S)"
    printf 'restrict,command="%s %s" %s\n' "$RRSYNC" "$WEBROOT" "$DEPLOY_KEY" >> "$AUTH"
    echo "Dodano (kopia poprzedniej wersji: ${AUTH}.bak-*)."
fi
chown "${DEPLOY_USER}:${DEPLOY_USER}" "$AUTH"
chmod 600 "$AUTH"

# ForceCommand w sshd_config nadpisałby command= z authorized_keys i rsync by nie ruszył.
if sshd -T -C "user=${DEPLOY_USER},host=github-actions,addr=192.0.2.1" 2>/dev/null | grep -qi '^forcecommand '; then
    echo "⚠️  sshd_config ma ForceCommand dla ${DEPLOY_USER} — deploy przez rsync nie zadziała, daj znać Claude."
fi

say "nginx: vhost ${DOMAIN} (wersja startowa, tylko HTTP)"
if [ -e "$VHOST" ] && ! grep -q 'WEBSROCKS-BOOTSTRAP' "$VHOST"; then
    echo "${VHOST} jest już w wersji docelowej (HTTPS) — nie nadpisuję."
else
    curl -fsSL "${RAW}/deploy/nginx/websrocks.com.bootstrap.conf" -o "${VHOST}.tmp"
    grep -q 'WEBSROCKS-BOOTSTRAP' "${VHOST}.tmp" || fail "Pobrany plik vhosta wygląda na uszkodzony."
    mv "${VHOST}.tmp" "$VHOST"
fi
ln -sfn "$VHOST" "$VHOST_LINK"
if nginx -t; then
    systemctl reload nginx
else
    rm -f "$VHOST_LINK"
    fail "nginx -t nie przeszedł — wyłączyłem vhost websrocks.com, reszta serwera bez zmian."
fi

say "Test przez publiczne IP (tak jak sprawdza Let's Encrypt)"
code="$(curl -s -o /dev/null -w '%{http_code}' -H "Host: ${DOMAIN}" "http://${VPS_IP}/.well-known/acme-challenge/nie-ma" || true)"
echo "Wyzwania certbota przez nginx: HTTP ${code} (404 = OK, katalog działa)"

printf '\n✅ KROK 1 GOTOWY. Strona pojawi się tu po pierwszym deployu z GitHuba.\n'
printf '   Dalej: rekordy DNS w aftermarket.pl, potem krok 2 (deploy/vps-cert.sh).\n'
