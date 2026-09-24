# websrocks.com

Strona firmowa WebsRocks — statyczna (HTML + CSS + grafiki, bez budowania, bez skryptów).
Stoi na VPS `89.167.14.46` (ten sam co panel, Witazo i concierge), za nginx z certyfikatem Let's Encrypt.

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

## Pierwsze uruchomienie (jednorazowo, wrzesień 2026)

0. **Sekret w GitHubie** (Mac): `gh secret set VPS_SSH_KEY --repo bednarczykm/websrocks < ~/.ssh/websrocks-deploy`
1. **VPS, krok 1** — `deploy/vps-setup.sh`: katalog strony, klucz deployu (tylko rrsync), vhost tylko HTTP.
2. **DNS w aftermarket.pl** — najpierw MX (poczta zostaje na Plesku), co najmniej godzinę później A:

   | Typ | Nazwa | Wartość | Kiedy |
   |---|---|---|---|
   | MX | `websrocks.com` | `mail.websrocks.com`, priorytet 10 | najpierw |
   | A | `websrocks.com` | `89.167.14.46` (zamiast `168.119.253.204`) | ≥ 1 h po MX |
   | A | `www.websrocks.com` | `89.167.14.46` (zamiast `168.119.253.204`) | razem z powyższym |

   Rekordów `mail`, `webmail`, `ftp`, `autodiscover`, `autoconfig` **nie ruszać** — zostają na Plesku.
   Domena nie miała rekordu MX, więc poczta szła „po rekordzie A". Bez MX przestawienie A odcięłoby pocztę.
3. **VPS, krok 2** — `deploy/vps-cert.sh`: czeka na nowy DNS, robi certyfikat, włącza HTTPS
   (www → bez www, nagłówki bezpieczeństwa), testuje odnowienie.

Komendy do kroków 1 i 2 (z konkretnym commitem) są w komentarzu na początku każdego skryptu.

## Gdy coś nie działa

- **Deploy czerwony, `Permission denied (publickey)`** — sekret `VPS_SSH_KEY` albo brak kroku 1.
- **Deploy czerwony po obu próbach, `Connection reset/refused`** — fail2ban; na VPS:
  `sudo fail2ban-client status sshd`, ewentualnie odbanuj IP z logu joba.
- **Certyfikat** — `sudo certbot certificates --cert-name websrocks.com`,
  `sudo certbot renew --dry-run --cert-name websrocks.com`.

Źródło treści: eksport „WebsRocks VPS”, source commit `df35b0e580a500af3c022570256e66d3a81298f4`.
