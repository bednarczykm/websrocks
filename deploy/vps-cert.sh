#!/usr/bin/env bash
# websrocks.com — KROK 2 z 2: certyfikat HTTPS + docelowy vhost nginx.
#
# Uruchom na VPS od razu po zapisaniu nowych rekordów A w aftermarket.pl
# (możesz też wcześniej — skrypt sam poczeka na DNS):
#   curl -fsSL https://raw.githubusercontent.com/bednarczykm/websrocks/<commit>/deploy/vps-cert.sh -o /tmp/websrocks-cert.sh
#   sudo bash /tmp/websrocks-cert.sh <commit>
#
# Co robi:
#   1. czeka, aż serwery DNS domeny (aftermarket.pl) pokażą ten VPS dla websrocks.com i www,
#   2. certbot certonly --webroot (Let's Encrypt) dla obu nazw + automatyczny reload nginx
#      po każdym odnowieniu,
#   3. podmienia vhost na docelowy (HTTPS, www → bez www, nagłówki bezpieczeństwa),
#      z kopią i automatycznym powrotem, gdyby nginx -t nie przeszedł,
#   4. test odnowienia certyfikatu (dry-run) i test strony.
# Skrypt można bezpiecznie uruchomić ponownie.
set -euo pipefail

REF="${1:-main}"
RAW="https://raw.githubusercontent.com/bednarczykm/websrocks/${REF}"
DOMAIN="websrocks.com"
VPS_IP="89.167.14.46"   # testy idą przez publiczne IP — 127.0.0.1 trafia na tym serwerze do innego vhosta
NAMESERVERS=(ns1.aftermarket.pl ns2.aftermarket.pl)
ACME_ROOT="/var/www/certbot"
VHOST="/etc/nginx/sites-available/${DOMAIN}"
WAIT_MAX_SECONDS=$((3 * 3600))

say()  { printf '\n==> %s\n' "$*"; }
fail() { printf '\n❌ %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || fail "Uruchom przez sudo: sudo bash $0 ${REF}"
[ -e "$VHOST" ] || fail "Brak ${VHOST} — najpierw krok 1 (deploy/vps-setup.sh)."
command -v certbot >/dev/null || fail "Brak certbota na tym serwerze."
command -v dig >/dev/null || { apt-get update -qq && apt-get install -y -qq bind9-dnsutils; }

# +dnssec (bit DO) celowo: serwery aftermarket.pl mają przed strefą cache, który odpowiedzi bez DO
# trzyma do pełnego TTL (6 h) po zmianie w panelu; z DO odpowiadają świeżo — i tak pytają
# resolwery walidujące, w tym Let's Encrypt. Zostawiamy tylko adresy (bez linii RRSIG).
a_records() {
    dig +short +dnssec +time=5 +tries=2 A "$1" "@$2" | grep -E '^[0-9]+(\.[0-9]+){3}$' | sort | tr '\n' ' ' | sed 's/ $//'
}

say "Czekam, aż DNS pokaże ${VPS_IP} dla ${DOMAIN} i www.${DOMAIN} (Ctrl+C przerywa)"
start=$SECONDS
while :; do
    ok=1; status=""
    for ns in "${NAMESERVERS[@]}"; do
        for name in "$DOMAIN" "www.${DOMAIN}"; do
            got="$(a_records "$name" "$ns" || true)"
            status+="  ${name} @${ns}: ${got:-brak}"$'\n'
            [ "$got" = "$VPS_IP" ] || ok=0
        done
    done
    [ "$ok" = 1 ] && { printf '%s' "$status"; break; }
    [ $((SECONDS - start)) -lt "$WAIT_MAX_SECONDS" ] || fail "Po 3 h DNS nadal nie wskazuje ${VPS_IP}:"$'\n'"${status}Sprawdź rekordy A (ma być JEDEN rekord A = ${VPS_IP}, stary 168.119.253.204 usunięty)."
    printf '%s  …jeszcze nie, sprawdzę za 30 s\n' "$status"
    sleep 30
done
echo "DNS OK."

say "Test ścieżki wyzwań certbota przez nginx (przed wywołaniem Let's Encrypt)"
probe="websrocks-probe-$$"
mkdir -p "${ACME_ROOT}/.well-known/acme-challenge"
echo "$probe" > "${ACME_ROOT}/.well-known/acme-challenge/${probe}"
got="$(curl -fsS --max-time 10 -H "Host: ${DOMAIN}" "http://${VPS_IP}/.well-known/acme-challenge/${probe}" || true)"
rm -f "${ACME_ROOT}/.well-known/acme-challenge/${probe}"
[ "$got" = "$probe" ] || fail "nginx nie serwuje ${ACME_ROOT} dla ${DOMAIN} — certbot by nie przeszedł. Daj znać Claude."
echo "OK."

say "Certyfikat Let's Encrypt (${DOMAIN} + www.${DOMAIN})"
certbot certonly --webroot -w "$ACME_ROOT" \
    -d "$DOMAIN" -d "www.${DOMAIN}" \
    --cert-name "$DOMAIN" \
    --non-interactive --keep-until-expiring \
    --deploy-hook "systemctl reload nginx"
[ -s "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ] || fail "Certyfikatu nie ma w /etc/letsencrypt/live/${DOMAIN}/."

say "nginx: docelowy vhost (HTTPS)"
backup="/root/${DOMAIN}.nginx.bak-$(date +%F-%H%M%S)"
cp -p "$VHOST" "$backup"
curl -fsSL "${RAW}/deploy/nginx/websrocks.com.conf" -o "${VHOST}.tmp"
grep -q 'listen 443 ssl' "${VHOST}.tmp" || fail "Pobrany plik vhosta wygląda na uszkodzony — nic nie zmieniono."
mv "${VHOST}.tmp" "$VHOST"
if nginx -t; then
    systemctl reload nginx
else
    cp -p "$backup" "$VHOST"
    nginx -t && systemctl reload nginx
    fail "Nowy vhost nie przeszedł nginx -t — przywróciłem poprzedni (${backup}). Daj znać Claude."
fi
echo "OK (kopia poprzedniego: ${backup})."

say "Test odnowienia certyfikatu (dry-run)"
certbot renew --dry-run --cert-name "$DOMAIN" --no-random-sleep-on-renew \
    || echo "⚠️  Test odnowienia nie przeszedł — certyfikat działa, ale daj znać Claude."

say "Test strony"
curl -sS -o /dev/null --max-time 15 --resolve "${DOMAIN}:443:${VPS_IP}" \
    -w "https://${DOMAIN}/ → HTTP %{http_code}\n" "https://${DOMAIN}/" \
    || echo "⚠️  https://${DOMAIN}/ nie odpowiada poprawnie — daj znać Claude."
curl -sS -o /dev/null --max-time 15 --resolve "www.${DOMAIN}:443:${VPS_IP}" \
    -w "https://www.${DOMAIN}/ → HTTP %{http_code} → %{redirect_url}\n" "https://www.${DOMAIN}/" \
    || echo "⚠️  https://www.${DOMAIN}/ nie odpowiada poprawnie — daj znać Claude."

printf '\n✅ KROK 2 GOTOWY — https://%s działa z tego serwera.\n' "$DOMAIN"
