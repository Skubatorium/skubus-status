# skubus-status

Öffentliche Status-Seite **„Skubus Health Check“** für die Skubus-Plattform (`status.skubus.de`).
Rein lesend (Tier 0): prüft Erreichbarkeit, TLS und Mail-DNS aller dokumentierten Hostnamen und zeigt das Ergebnis an. Ändert nichts an der Infrastruktur.

Konzept und Entscheidungen: `skubus-vps/docs/plans/2026-10-12_agent-gestuetzte-infrastruktur-konfiguration.md` (Abschnitt 5.4) und das zugehörige Audit. Betriebsdokumentation der Plattform: Repo `skubus-vps`.

## Architektur

```
skubus-vps/docs/inventory/{domains,applications}.md
        │  generator/generate_targets.py   (lokal, manuell)
        ▼
   targets.json  ── committet ──► Git ──► Coolify (Docker Compose)
                                            │
                    ┌───────────────────────┴───────────────────────┐
                    ▼                                               ▼
        checker (alpine+bash)                              web (nginx:alpine)
        alle 5 min: DNS, HTTP, TLS,                        statische Seite +
        Origin-TLS, UptimeRobot                            /status.json, /history.json
        schreibt status.json + history.json  ── Volume ──► (read-only)
```

| Teil | Zweck |
|---|---|
| `generator/generate_targets.py` | Liest das Inventar aus `skubus-vps`, erzeugt `targets.json`. Bricht bei unerwartetem Tabellenformat ab. |
| `targets.json` | Zielliste (committet, wird ins Checker-Image gebacken). Enthält nur Hostnamen und Check-Typen. |
| `checker/check.sh` | Prüfschleife. Prüflogik nach Vorbild von `skubus-vps/scripts/health-check.sh`. |
| `web/` | nginx-Konfiguration und statische Seite (ohne externe Abhängigkeiten, kein CDN). |
| `docker-compose.yml` | Zwei Services `checker` und `web`, gemeinsames Volume `status-data`. |

## Workflow: Inventar geändert → Generator → Commit → Push

Die Zielliste ist nicht hartcodiert, sondern kommt aus dem Inventar. Nach jeder Änderung an `domains.md` (Abschnitt ACTIVE) oder `applications.md` in `skubus-vps`:

```bash
cd ~/Workspace/Repos/skubus-status
python3 generator/generate_targets.py        # liest ../skubus-vps/docs/inventory
git diff targets.json                        # Änderung prüfen
git add targets.json && git commit -m "chore(targets): Inventar-Stand aktualisiert"
git push                                     # Coolify deployt
```

Schlägt der Generator fehl, ist das Tabellenformat im Inventar verändert worden — Generator oder Inventar anpassen, nicht umgehen.

### Gelesenes Inventar-Format

- `domains.md`: Tabelle unter `## ACTIVE`, Spalten `Hostname | Zweck`, Hostname in Backticks.
- `applications.md`: je Anwendung ein `## <name>`-Abschnitt mit Zwei-Spalten-Tabelle `Feld | Wert`:
  - `Domain` (Pflicht): enthält die `https://`-URL(s); jeder Hostname muss in `domains.md` ACTIVE stehen.
  - `Passwortschutz` (optional): Feld vorhanden und nicht mit „Kein/Nein“ beginnend → HTTP `401` gilt als gesund.
  - `Health-Erwartung` (optional): enthält einen HTTP-Statuscode, der als gesund gilt (z. B. `401` für Kong ohne API-Key).
- Sonderrollen (`app.skubus.de` = Plattform „Coolify“, `send.skubus.de` = Mail-Kachel) sind im Generator festgelegt.
- Hostnames in ACTIVE ohne Anwendung (z. B. nur DNS vorhanden) erscheinen als Kachel „keine Anwendung dokumentiert“ und prüfen nur DNS.

## Prüfungen

| Check | Beschreibung |
|---|---|
| DNS | Hostname löst auf (A/AAAA). Ergebnis ohne IP-Adresse. |
| HTTP | Status und Antwortzeit von `https://<host>/`, Redirects werden nicht verfolgt. 2xx/3xx gesund; bei Passwortschutz 401; bei `Health-Erwartung` der dort genannte Code. |
| TLS (Edge) | Ablaufdatum des öffentlich sichtbaren Cloudflare-Zertifikats. Warnung < 14 Tage, Fehler < 3 Tage. |
| TLS (Origin) | Let's-Encrypt-Zertifikat direkt am Traefik (`ORIGIN_PROXY_HOST`, Standard `coolify-proxy`). Nicht erreichbar → „nicht prüfbar“, nie grün. Braucht in Coolify die Option „Connect to Predefined Network“ für den `checker`. |
| UptimeRobot | `getMonitors` mit Read-only-Key, Zuordnung über die Monitor-URL. Ohne Key: „nicht konfiguriert“, der Rest läuft weiter. |
| Mail-DNS | Für `send.skubus.de`: MX, SPF (TXT) und DKIM (`resend._domainkey.<Elterndomain>`). Kein Resend-Key nötig. |

Die Seite markiert den Gesamtstand als „veraltet“, wenn `generated_at` älter als 15 Minuten ist.

## Sicherheit / öffentliche Auslieferung

Die Seite ist ohne Zugriffsschutz öffentlich (Entscheidung 2026-10-12). Daraus folgt:

- `status.json` und `history.json` enthalten keine Secrets, keine IPs, keine internen Container-Namen. Der UptimeRobot-Key existiert nur als Env-Var im `checker`-Container.
- JSON wird mit `Cache-Control: no-store` ausgeliefert, alle Antworten mit `X-Robots-Tag: noindex, nofollow`; `robots.txt` sperrt alles.
- **Hostnamen** der Anwendungen sind sichtbar, auch die passwortgeschützter Portale.
- Basic-Auth lässt sich bei Bedarf über Traefik-Labels nachrüsten (Muster wie bei `norwegen.skubus.de`).

## Lokal testen

```bash
python3 -m unittest discover -s tests           # Generator-Tests
python3 generator/generate_targets.py           # targets.json erzeugen

# Checker einmal ohne Docker (schreibt nach ./out)
mkdir -p out && RUN_ONCE=1 TARGETS_FILE=targets.json OUT_DIR=$PWD/out ./checker/check.sh

# Gesamtstack mit Seite auf http://127.0.0.1:8080
docker compose -f docker-compose.yml -f docker-compose.local.yml up --build
```

## Konfiguration (Umgebungsvariablen des `checker`)

| Variable | Standard | Bedeutung |
|---|---|---|
| `UPTIMEROBOT_API_KEY` | leer | Read-only-Key. In Coolify setzen, **nie** committen. |
| `CHECK_INTERVAL` | `300` | Sekunden zwischen den Zyklen. |
| `ORIGIN_PROXY_HOST` | `coolify-proxy` | Host für den Origin-TLS-Check. |

## Grenzen

- Läuft auf derselben VPS wie die geprüften Dienste: Fällt die VPS aus, ist die Seite mit weg. Unabhängige Alarmierung bleibt UptimeRobot (ADR-005 in `skubus-vps`).
- Datenbank-Checks sind nicht implementiert (derzeit keine netzwerkerreichbare DB dokumentiert).
- Die Seite prüft nur `/` je Hostname — Erreichbarkeit der Startseite, nicht Anwendungslogik.
