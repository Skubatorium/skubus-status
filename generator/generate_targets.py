#!/usr/bin/env python3
"""Erzeugt targets.json aus dem Inventar des Repos skubus-vps.

Liest:
  docs/inventory/domains.md        Abschnitt ACTIVE (Tabelle Hostname | Zweck)
  docs/inventory/applications.md   je "## <app>"-Abschnitt die Felder Domain, Passwortschutz
                                   und optional Health-Erwartung (HTTP-Statuscode(s), die als gesund gelten)

Bricht mit Exit-Code 1 ab, wenn das Format nicht wie erwartet parsebar ist.
Es werden keine Projekte stillschweigend weggelassen.
"""
import argparse
import datetime
import json
import os
import re
import subprocess
import sys

# Hostnamen mit Sonderrolle. Alles andere in ACTIVE ist ein Projekt (Anwendung
# laut applications.md) oder "unassigned" (DNS vorhanden, keine Anwendung).
PLATFORM_HOSTS = {"app.skubus.de": "Coolify"}
MAIL_HOSTS = {
    "send.skubus.de": "Transaktions-E-Mail (Resend)",
    "send.maschinenverleih-skubatz.de": "E-Mail Maschinenverleih (Resend)",
}
# Pflicht-Sonderhosts: fehlen sie in ACTIVE, ist das Inventar nicht wie erwartet.
REQUIRED_SPECIAL = {"app.skubus.de", "send.skubus.de"}

HOST_RE = re.compile(r"^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$")
URL_HOST_RE = re.compile(r"https://([a-z0-9][a-z0-9.-]*\.[a-z]{2,})")
NEGATIVE_RE = re.compile(r"^\W*(kein|keine|keiner|nein|none|no)\b", re.IGNORECASE)


class ParseError(Exception):
    pass


def strip_md(value):
    return value.strip().strip("`*").strip()


def parse_active_domains(text):
    """Gibt Liste (hostname, zweck) aus der Tabelle unter '## ACTIVE' zurück."""
    lines = text.splitlines()
    start = None
    for i, line in enumerate(lines):
        if re.match(r"^##\s+ACTIVE\s*$", line):
            start = i + 1
            break
    if start is None:
        raise ParseError("domains.md: Abschnitt '## ACTIVE' nicht gefunden")

    rows = []
    header_seen = False
    separator_seen = False
    for line in lines[start:]:
        if line.startswith("## "):
            break
        stripped = line.strip()
        if not stripped.startswith("|"):
            continue
        cells = [c.strip() for c in stripped.strip("|").split("|", 1)]
        if not header_seen:
            if [strip_md(c).lower() for c in cells[:1]] != ["hostname"]:
                raise ParseError("domains.md: Tabellenkopf unter ACTIVE ist nicht 'Hostname | Zweck'")
            header_seen = True
            continue
        if not separator_seen:
            if not re.match(r"^\|\s*:?-+", stripped):
                raise ParseError("domains.md: Trennzeile unter dem Tabellenkopf fehlt")
            separator_seen = True
            continue
        m = re.match(r"^\|\s*`([^`]+)`\s*\|\s*(.+?)\s*\|?\s*$", stripped)
        if not m:
            raise ParseError("domains.md: Zeile nicht parsebar: " + stripped[:80])
        host = m.group(1)
        if not HOST_RE.match(host):
            raise ParseError("domains.md: ungültiger Hostname: " + host)
        rows.append((host, m.group(2)))
    if not header_seen or not rows:
        raise ParseError("domains.md: keine Tabelle/keine Zeilen unter ACTIVE")
    seen = set()
    for host, _ in rows:
        if host in seen:
            raise ParseError("domains.md: doppelter Hostname " + host)
        seen.add(host)
    return rows


def parse_applications(text):
    """Gibt Liste {name, hosts, protected} je '## <app>'-Abschnitt zurück."""
    apps = []
    current = None
    for line in text.splitlines():
        if line.startswith("## "):
            if current is not None:
                apps.append(current)
            current = {"name": line[3:].strip(), "fields": {}}
            continue
        if current is None:
            continue
        stripped = line.strip()
        if not stripped.startswith("|"):
            continue
        m = re.match(r"^\|\s*([^|]+?)\s*\|\s*(.*?)\s*\|?\s*$", stripped)
        if not m:
            continue
        key = strip_md(m.group(1))
        if key.lower() in ("feld",) or re.match(r"^:?-+:?$", key):
            continue
        current["fields"].setdefault(key, m.group(2))
    if current is not None:
        apps.append(current)
    if not apps:
        raise ParseError("applications.md: keine '## <app>'-Abschnitte gefunden")

    result = []
    names = set()
    for app in apps:
        name = app["name"]
        if name in names:
            raise ParseError("applications.md: doppelter Abschnitt " + name)
        names.add(name)
        domain = app["fields"].get("Domain")
        if domain is None:
            raise ParseError("applications.md: Abschnitt '%s' hat kein Feld 'Domain'" % name)
        hosts = URL_HOST_RE.findall(domain)
        if not hosts:
            raise ParseError("applications.md: Abschnitt '%s': keine https-Domain im Feld 'Domain'" % name)
        pw = app["fields"].get("Passwortschutz")
        protected = pw is not None and not NEGATIVE_RE.match(strip_md(pw))
        expect = None
        he = app["fields"].get("Health-Erwartung")
        if he is not None:
            expect = [int(c) for c in re.findall(r"\b([1-5][0-9]{2})\b", strip_md(he))[:1]]
            if not expect:
                raise ParseError("applications.md: Abschnitt '%s': Feld 'Health-Erwartung' enthält keinen HTTP-Statuscode" % name)
        result.append({"name": name, "hosts": hosts, "protected": protected, "expect_codes": expect})
    return result


def slug(host):
    return re.sub(r"[^a-z0-9]+", "-", host.lower()).strip("-")


def build_targets(domains, apps):
    by_host = {}
    for app in apps:
        for h in app["hosts"]:
            if h in by_host:
                raise ParseError("Hostname %s in mehreren Anwendungen (%s, %s)" % (h, by_host[h]["name"], app["name"]))
            by_host[h] = app
    active = {h for h, _ in domains}
    for h, app in by_host.items():
        if h not in active:
            raise ParseError("applications.md nennt %s (%s), steht aber nicht in domains.md ACTIVE" % (h, app["name"]))
    for h in REQUIRED_SPECIAL:
        if h not in active:
            raise ParseError("Erwarteter Sonder-Hostname %s fehlt in domains.md ACTIVE" % h)

    targets = []
    for host, _zweck in domains:
        if host in PLATFORM_HOSTS:
            t = {"kind": "platform", "name": PLATFORM_HOSTS[host], "checks": ["dns", "http", "tls", "origin_tls", "uptimerobot"], "auth_required": False}
        elif host in MAIL_HOSTS:
            t = {"kind": "mail", "name": MAIL_HOSTS[host], "checks": ["mail_dns"], "auth_required": False}
        elif host in by_host:
            app = by_host[host]
            t = {"kind": "project", "name": app["name"], "checks": ["dns", "http", "tls", "origin_tls", "uptimerobot"], "auth_required": app["protected"]}
            if app["expect_codes"]:
                t["expect_codes"] = app["expect_codes"]
        else:
            t = {"kind": "unassigned", "name": host, "checks": ["dns"], "auth_required": False}
        t["id"] = slug(host)
        t["hostname"] = host
        targets.append(t)
    order = {"platform": 0, "project": 1, "mail": 2, "unassigned": 3}
    targets.sort(key=lambda t: (order[t["kind"]], t["hostname"]))
    return targets


def inventory_commit(repo_root):
    try:
        out = subprocess.run(["git", "-C", repo_root, "rev-parse", "--short", "HEAD"],
                             capture_output=True, text=True, timeout=10)
        return out.stdout.strip() if out.returncode == 0 else None
    except Exception:
        return None


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.dirname(here)
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--inventory", default=os.path.join(root, "..", "skubus-vps", "docs", "inventory"),
                    help="Pfad zu docs/inventory des skubus-vps-Repos")
    ap.add_argument("--output", default=os.path.join(root, "targets.json"))
    args = ap.parse_args()

    inv = os.path.abspath(args.inventory)
    try:
        with open(os.path.join(inv, "domains.md"), encoding="utf-8") as f:
            domains = parse_active_domains(f.read())
        with open(os.path.join(inv, "applications.md"), encoding="utf-8") as f:
            apps = parse_applications(f.read())
        targets = build_targets(domains, apps)
    except (ParseError, OSError) as e:
        print("FEHLER: %s" % e, file=sys.stderr)
        return 1

    doc = {
        "schema": 1,
        "generated_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "inventory_commit": inventory_commit(os.path.abspath(os.path.join(inv, "..", ".."))),
        "targets": targets,
    }
    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(doc, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print("%d Ziele nach %s geschrieben" % (len(targets), os.path.relpath(args.output)))
    for t in targets:
        extra = " [401 erwartet]" if t["auth_required"] else ""
        if t.get("expect_codes"):
            extra = " [erwartet %s]" % ",".join(str(c) for c in t["expect_codes"])
        print("  %-10s %-34s %s%s" % (t["kind"], t["hostname"], t["name"], extra))
    return 0


if __name__ == "__main__":
    sys.exit(main())
