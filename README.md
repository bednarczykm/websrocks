# websrocks.com

Strona firmowa WebsRocks — statyczna (HTML + CSS + grafiki, bez budowania, bez skryptów).
Stoi na VPS `89.167.14.46` (ten sam co panel, Witazo i concierge), za nginx z certyfikatem Let's Encrypt.
Działa od 25.09.2026; certyfikat odnawia się sam (pierwszy ważny do 24.12.2026).

## Jak zmienić stronę

1. Edytuj pliki w `public/` (treść i układ: `index.html`, kolory i wersja mobilna: `style.css`,
   logo i zdjęcie: osobne pliki).
2. Zrób PR do `main`. CI sprawdzi, czy nie ma martwych odwołań do plików, i przetestuje konfigurację nginx.
3. Po merge GitHub Actions sam wgra `public/` na VPS i sprawdzi, że serwer oddaje nową wersję.
   Nic nie robisz ręcznie.

Odwołania do plików zaczynają się od `/` — strona musi stać w głównym katalogu domeny.
Nowy skrypt, font albo obrazek z innej domeny wymaga dopisania jej do nagłówka
`Content-Security-Policy` w `deploy/nginx/websrocks.com.conf` — inaczej przeglądarka go zablokuje.

## Jak działa deploy

`.github/workflows/deploy.yml` → `rsync` katalogu `public/` do `/var/www/websrocks` na VPS
(użytkownik `gh-deploy`). Klucz z sekretu `VPS_SSH_KEY` jest po stronie VPS ograniczony
wymuszoną komendą `rrsync`: umie **tylko** wgrywać pliki do tego jednego katalogu — bez powłoki
i bez sudo. Klucz hosta VPS jest przypięty w workflow. Gdy fail2ban zbanuje IP runnera,
job `deploy-retry` powtarza wgranie z nowej maszyny.

| Co | Gdzie |
|---|---|
| Pliki strony | VPS: `/var/www/websrocks` |
| vhost nginx | VPS: `/etc/nginx/sites-available/websrocks.com` = `deploy/nginx/websrocks.com.conf` |
| Certyfikat | VPS: `/etc/letsencrypt/live/websrocks.com/` (odnawia się sam, potem reload nginx) |
| Logi | VPS: `/var/log/nginx/websrocks.access.log`, `websrocks.error.log` |
| DNS | aftermarket.pl (`ns1/ns2.aftermarket.pl`) |
| Poczta `@websrocks.com` | stary serwer Plesk `168.119.253.204` (`mail.websrocks.com`) — **bez zmian** |

## DNS (aftermarket.pl) — stan docelowy

| Nazwa | Typ | Wartość | Po co |
|---|---|---|---|
| `@` (websrocks.com) | A | `89.167.14.46` | strona (VPS) |
| `www` | A | `89.167.14.46` | strona (VPS) → przekierowanie na `websrocks.com` |
| `*`, `mail`, `webmail`, `ftp`, `autodiscover`, `autoconfig` | A | `168.119.253.204` | poczta i reszta na Plesku |
| `@` | MX | `10 mail` | poczta `@websrocks.com` na Plesku |

Zasada: nowy serwer mają **tylko** `@` i `www`. Pułapki z uruchomienia (wrzesień 2026):

- **Gwiazdka `*` nie obejmuje samej domeny** — `@` musi mieć własny rekord A. Bez niego `websrocks.com` przestaje działać, gdy wygaśnie cache.
- **Serwery ns1/ns2.aftermarket.pl mają cache przed strefą**: po zmianie w panelu odpowiedzi bez bitu DO zostają stare do pełnego TTL (6 h), a serial SOA wygląda na niezmieniony. Świeży stan strefy: `dig +dnssec +bufsize=<dowolna liczba 1300–4000> @ns1.aftermarket.pl websrocks.com A`.
- **Zły adres zapamiętują też resolwery** (Cloudflare, Google…) na TTL = 6 h. Let's Encrypt sprawdza domenę z kilku miejsc naraz, więc przy świeżej pomyłce certyfikat nie przejdzie, dopóki cache nie wygaśnie. Czyszczenie: one.one.one.one/purge-cache, dns.google/cache.
- Po każdej zmianie w panelu sprawdź **całą strefę** z tabeli, nie tylko edytowany rekord.

## Pierwsze uruchomienie (jednorazowo — zrobione 24–25.09.2026)

0. **Sekret w GitHubie** (Mac): `gh secret set VPS_SSH_KEY --repo bednarczykm/websrocks < ~/.ssh/websrocks-deploy`
1. **VPS, krok 1** — `deploy/vps-setup.sh`: katalog strony, klucz deployu (tylko rrsync), vhost tylko HTTP.
2. **DNS** — najpierw MX (domena nie miała MX, poczta szła „po rekordzie A”; bez MX przestawienie A odcięłoby pocztę), co najmniej godzinę później A dla `@` i `www`.
3. **VPS, krok 2** — `deploy/vps-cert.sh`: czeka na DNS (zapytania z bitem DO — omijają cache aftermarket), robi certyfikat, włącza HTTPS (www → bez www, nagłówki bezpieczeństwa), testuje odnowienie. Gdy Let's Encrypt trafia na stary cache, ponawianie w tle:
   `sudo systemd-run --unit=websrocks-cert bash -c 'for i in $(seq 1 20); do sleep 1200; bash /tmp/websrocks-cert.sh <commit> && exit 0; done; exit 1'`

Komendy do kroków 1 i 2 (z konkretnym commitem) są w komentarzu na początku każdego skryptu.
Na VPS testy vhostów rób po publicznym IP — `127.0.0.1:80` trafia tam do innej strony.

## Gdy coś nie działa

- **Deploy czerwony, `Permission denied (publickey)`** — sekret `VPS_SSH_KEY` albo brak kroku 1.
- **Deploy czerwony po obu próbach, `Connection reset/refused`** — fail2ban; na VPS:
  `sudo fail2ban-client status sshd`, ewentualnie odbanuj IP z logu joba.
- **Certyfikat** — `sudo certbot certificates --cert-name websrocks.com`,
  `sudo certbot renew --dry-run --cert-name websrocks.com`.

Źródło treści: eksport „WebsRocks VPS”, source commit `df35b0e580a500af3c022570256e66d3a81298f4`.
