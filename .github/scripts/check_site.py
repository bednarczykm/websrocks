#!/usr/bin/env python3
"""Sprawdza stronę w public/: czy każde lokalne odwołanie (src/href, url() w CSS)
wskazuje na istniejący plik i czy każda kotwica #id istnieje na stronie."""
import re
import sys
from html.parser import HTMLParser
from pathlib import Path

PUBLIC = Path(__file__).resolve().parents[2] / "public"
EXTERNAL = re.compile(r"^(?:[a-z][a-z0-9+.-]*:|//)", re.I)  # https:, mailto:, data:, //cdn…


class Refs(HTMLParser):
    def __init__(self):
        super().__init__()
        self.refs, self.ids = [], set()

    def handle_starttag(self, tag, attrs):
        for name, value in attrs:
            if name in ("src", "href") and value:
                self.refs.append(value)
            elif name == "id" and value:
                self.ids.add(value)


def local_target(ref, base_dir):
    path = ref.split("#", 1)[0].split("?", 1)[0]
    target = PUBLIC / path.lstrip("/") if path.startswith("/") else base_dir / path
    return target / "index.html" if target.is_dir() else target


errors = []
if not (PUBLIC / "index.html").is_file():
    errors.append("brak public/index.html")

for page in sorted(PUBLIC.rglob("*.html")):
    parser = Refs()
    parser.feed(page.read_text(encoding="utf-8"))
    for ref in parser.refs:
        if EXTERNAL.match(ref):
            continue
        if ref.startswith("#"):
            if len(ref) > 1 and ref[1:] not in parser.ids:
                errors.append(f"{page.relative_to(PUBLIC)}: kotwica {ref} nie istnieje")
            continue
        if not local_target(ref, page.parent).is_file():
            errors.append(f"{page.relative_to(PUBLIC)}: brak pliku dla {ref}")

for css in sorted(PUBLIC.rglob("*.css")):
    for ref in re.findall(r"url\(\s*['\"]?([^'\")]+)", css.read_text(encoding="utf-8")):
        if not EXTERNAL.match(ref) and not ref.startswith("#") and not local_target(ref, css.parent).is_file():
            errors.append(f"{css.relative_to(PUBLIC)}: brak pliku dla url({ref})")

if errors:
    print("\n".join(f"❌ {e}" for e in errors))
    sys.exit(1)
print(f"✅ public/: wszystkie odwołania OK ({len(list(PUBLIC.rglob('*')))} plików)")
