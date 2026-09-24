#!/usr/bin/env bash
# Wgrywa public/ na VPS (rsync przez SSH) i sprawdza, że serwer oddaje dokładnie wgrany
# index.html. Klucz SSH_KEY po stronie VPS jest ograniczony (rrsync w authorized_keys
# gh-deploy) do wgrywania plików w /var/www/websrocks — patrz deploy/vps-setup.sh.
set -euo pipefail
: "${VPS_HOST:?}" "${VPS_USER:?}" "${VPS_HOST_KEY:?}" "${SITE_DOMAIN:?}" "${SSH_KEY:?}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
printf '%s\n' "$SSH_KEY" > "$tmp/key"
chmod 600 "$tmp/key"
printf '%s\n' "$VPS_HOST_KEY" > "$tmp/known_hosts"

echo "==> rsync public/ → ${VPS_USER}@${VPS_HOST}"
# -c: porównanie po treści — niezmienione pliki zostają nietknięte (ich cache w przeglądarkach też).
rsync -rlpcz --delete --chmod=D755,F644 --itemize-changes \
    -e "ssh -i $tmp/key -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$tmp/known_hosts -o ConnectTimeout=20" \
    public/ "${VPS_USER}@${VPS_HOST}:./"

echo "==> Kontrola: serwer oddaje wgrany index.html"
expected="$(sha256sum public/index.html | cut -d' ' -f1)"
if curl -fsS --max-time 20 --resolve "${SITE_DOMAIN}:443:${VPS_HOST}" \
        "https://${SITE_DOMAIN}/" -o "$tmp/index.html" 2>/dev/null; then
    via="HTTPS"
else
    # Przed krokiem 2 (certyfikat) vhost działa tylko po HTTP.
    curl -fsS --max-time 20 -H "Host: ${SITE_DOMAIN}" "http://${VPS_HOST}/" -o "$tmp/index.html"
    via="HTTP (certyfikatu jeszcze nie ma — krok 2 w README)"
fi
got="$(sha256sum "$tmp/index.html" | cut -d' ' -f1)"
if [ "$got" != "$expected" ]; then
    echo "::error title=deploy::Serwer (${via}) oddaje inny index.html niż wgrany."
    exit 1
fi

msg="✅ ${SITE_DOMAIN} na ${VPS_HOST} (${via}) oddaje wgraną wersję — commit ${GITHUB_SHA:-lokalny}"
echo "$msg"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    echo "$msg" >> "$GITHUB_STEP_SUMMARY"
fi
