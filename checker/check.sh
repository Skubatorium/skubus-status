#!/usr/bin/env bash
# Skubus Status-Checker: prüft alle Ziele aus targets.json und schreibt
# status.json (aktueller Stand) und history.json (rollierend, 24 h) atomar nach $OUT_DIR.
# Prüflogik (DNS / HTTP / TLS) nach Vorbild von skubus-vps/scripts/health-check.sh.
#
# Ausgabe enthält bewusst keine IPs, keine internen Hostnamen, keine Secrets —
# die Dateien werden öffentlich ausgeliefert.
set -uo pipefail
umask 022

TARGETS_FILE="${TARGETS_FILE:-/app/targets.json}"
OUT_DIR="${OUT_DIR:-/data}"
INTERVAL="${CHECK_INTERVAL:-300}"
RUN_ONCE="${RUN_ONCE:-0}"
ORIGIN_PROXY_HOST="${ORIGIN_PROXY_HOST:-coolify-proxy}"
UPTIMEROBOT_API_KEY="${UPTIMEROBOT_API_KEY:-}"
TLS_WARN_DAYS=14
TLS_FAIL_DAYS=3
HTTP_TIMEOUT=10

have() { command -v "$1" >/dev/null 2>&1; }
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
with_timeout() { if have timeout; then timeout "$@"; else shift; "$@"; fi; }

# --- Einzelprüfungen: geben je ein JSON-Objekt {status, ...} auf stdout aus ---

check_dns() {
  local host="$1" a aaaa
  if ! have dig; then jq -nc '{status:"unavailable",detail:"dig nicht verfügbar"}'; return; fi
  a=$(dig +short +time=3 +tries=2 A "$host" 2>/dev/null | head -n1)
  aaaa=$(dig +short +time=3 +tries=2 AAAA "$host" 2>/dev/null | head -n1)
  if [[ -n "$a" || -n "$aaaa" ]]; then
    jq -nc '{status:"ok"}'
  else
    jq -nc '{status:"fail",detail:"kein A/AAAA-Record aufgelöst"}'
  fi
}

check_http() {
  local host="$1" auth="$2" expect="${3:-}" result code time_s ms
  result=$(curl -o /dev/null -s -w "%{http_code} %{time_total}" --max-time "$HTTP_TIMEOUT" "https://${host}/" 2>/dev/null) || true
  code="${result%% *}"; time_s="${result##* }"
  [[ "$code" =~ ^[0-9]{3}$ ]] || { code="000"; time_s="0"; }
  ms=$(awk -v t="$time_s" 'BEGIN{printf "%d", t*1000}')
  local status detail=""
  if [[ "$code" == "000" ]]; then
    status="fail"; detail="keine Antwort"
  elif [[ -n "$expect" ]]; then
    if [[ ",${expect}," == *",${code},"* ]]; then status="ok"
    else status="fail"; detail="erwartet ${expect}, erhalten ${code}"; fi
  elif [[ "$auth" == "true" ]]; then
    if [[ "$code" == "401" ]]; then status="ok"
    elif [[ "$code" =~ ^[23] ]]; then status="warn"; detail="Passwortschutz scheint nicht aktiv (erwartet 401)"
    else status="fail"; detail="erwartet 401, erhalten ${code}"; fi
  else
    if [[ "$code" =~ ^[23] ]]; then status="ok"
    else status="fail"; detail="HTTP ${code}"; fi
  fi
  jq -nc --arg s "$status" --arg d "$detail" --argjson c "$code" --argjson ms "$ms" \
    '{status:$s,code:$c,time_ms:$ms} + (if $d != "" then {detail:$d} else {} end)'
}

# Liest ein PEM-Zertifikat von stdin, gibt {status, expires, ...} aus. $1 = Label für Detailtext.
cert_status() {
  local pem enddate expires
  pem=$(cat)
  if ! grep -q "BEGIN CERTIFICATE" <<<"$pem"; then return 1; fi
  enddate=$(openssl x509 -noout -enddate <<<"$pem" 2>/dev/null | cut -d= -f2)
  expires=$(awk -v d="$enddate" 'BEGIN{
    split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", m, " ");
    for (i=1;i<=12;i++) mon[m[i]]=i;
    n=split(d, p, " ");
    # Format: "Mon DD HH:MM:SS YYYY GMT" (DD ggf. mit führendem Leerzeichen)
    printf "%04d-%02d-%02d", p[4], mon[p[1]], p[2] }')
  local status
  if openssl x509 -noout -checkend $((TLS_WARN_DAYS*86400)) <<<"$pem" >/dev/null 2>&1; then status="ok"
  elif openssl x509 -noout -checkend $((TLS_FAIL_DAYS*86400)) <<<"$pem" >/dev/null 2>&1; then status="warn"
  else status="fail"; fi
  local issuer
  issuer=$(openssl x509 -noout -issuer <<<"$pem" 2>/dev/null)
  printf '%s\n' "$status|$expires|$issuer"
}

check_tls() {
  local host="$1" out status expires
  if ! have openssl; then jq -nc '{status:"unavailable",detail:"openssl nicht verfügbar"}'; return; fi
  out=$(echo | with_timeout 10 openssl s_client -servername "$host" -connect "${host}:443" 2>/dev/null \
        | openssl x509 2>/dev/null | cert_status) || out=""
  if [[ -z "$out" ]]; then jq -nc '{status:"fail",detail:"Zertifikat nicht abrufbar"}'; return; fi
  status="${out%%|*}"; expires="${out#*|}"; expires="${expires%%|*}"
  jq -nc --arg s "$status" --arg e "$expires" '{status:$s,expires:$e}'
}

# Origin-Zertifikat (Let's Encrypt via Traefik) direkt am Proxy im Coolify-Netzwerk.
# Nicht erreichbar -> "unavailable" (neutral), nie stillschweigend grün.
check_origin_tls() {
  local host="$1" out status expires issuer
  if ! have openssl; then jq -nc '{status:"unavailable",detail:"openssl nicht verfügbar"}'; return; fi
  out=$(echo | with_timeout 10 openssl s_client -servername "$host" -connect "${ORIGIN_PROXY_HOST}:443" 2>/dev/null \
        | openssl x509 2>/dev/null | cert_status) || out=""
  if [[ -z "$out" ]]; then
    jq -nc '{status:"unavailable",detail:"Origin nicht prüfbar (Checker erreicht Proxy-Netzwerk nicht)"}'; return
  fi
  status="${out%%|*}"; local rest="${out#*|}"; expires="${rest%%|*}"; issuer="${rest#*|}"
  if [[ "$issuer" != *"Let's Encrypt"* ]]; then
    jq -nc --arg e "$expires" '{status:"fail",expires:$e,detail:"Origin-Zertifikat nicht von Let'"'"'s Encrypt (Default-Zertifikat?)"}'; return
  fi
  jq -nc --arg s "$status" --arg e "$expires" '{status:$s,expires:$e}'
}

check_mail_dns() {
  local host="$1" parent="${1#*.}" mx spf dkim
  if ! have dig; then jq -nc '{status:"unavailable",detail:"dig nicht verfügbar"}'; return; fi
  mx=$(dig +short +time=3 +tries=2 MX "$host" 2>/dev/null | head -n1)
  spf=$(dig +short +time=3 +tries=2 TXT "$host" 2>/dev/null | grep -c "v=spf1")
  dkim=$(dig +short +time=3 +tries=2 TXT "resend._domainkey.${parent}" 2>/dev/null | grep -c "p=")
  jq -nc --arg mx "$mx" --argjson spf "$spf" --argjson dkim "$dkim" '
    def st(b): if b then "ok" else "fail" end;
    {mx:{status:st($mx != "")}, spf:{status:st($spf > 0)}, dkim:{status:st($dkim > 0)}}
    | . + {status: (if ([.mx.status,.spf.status,.dkim.status] | all(. == "ok")) then "ok" else "fail" end)}'
}

# UptimeRobot: einmal je Zyklus abrufen -> $WORK/uptimerobot.json
#   {state: not_configured|ok|error, monitors: {hostname: {status, uptime_30d}}}
fetch_uptimerobot() {
  local out="$1/uptimerobot.json" raw
  if [[ -z "$UPTIMEROBOT_API_KEY" ]]; then
    jq -nc '{state:"not_configured",monitors:{}}' >"$out"; return
  fi
  raw=$(curl -s --max-time 20 -X POST "https://api.uptimerobot.com/v2/getMonitors" \
        --data-urlencode "api_key=${UPTIMEROBOT_API_KEY}" -d "format=json" -d "custom_uptime_ratios=30" 2>/dev/null) || raw=""
  if ! jq -e '.stat == "ok"' >/dev/null 2>&1 <<<"$raw"; then
    jq -nc '{state:"error",monitors:{}}' >"$out"; return
  fi
  jq -c '{state:"ok", monitors:(
      [.monitors[] | {
         host: (.url | sub("^[a-zA-Z]+://";"") | split("/")[0] | split(":")[0] | ascii_downcase),
         status: (if .status == 2 then "ok" elif .status == 0 then "paused"
                  elif .status == 8 or .status == 9 then "fail" else "unknown" end),
         uptime_30d: ((.custom_uptime_ratio // "") | tonumber? // null)
       }] | map({key:.host, value:{status:.status, uptime_30d:.uptime_30d}}) | from_entries)}' <<<"$raw" >"$out"
}

check_uptimerobot() {
  local host="$1" file="$2/uptimerobot.json"
  jq -c --arg h "$host" '
    if .state == "not_configured" then {status:"not_configured",detail:"UptimeRobot nicht konfiguriert"}
    elif .state == "error" then {status:"unavailable",detail:"UptimeRobot-Abfrage fehlgeschlagen"}
    elif .monitors[$h] then .monitors[$h]
    else {status:"none",detail:"kein Monitor für diesen Hostnamen"} end' "$file"
}

# --- Ziel prüfen, Kachel-JSON nach $WORK/tile-<id>.json ---

run_target() {
  local work="$1" t="$2"
  local id host kind name auth expect c res checks='{}'
  id=$(jq -r .id <<<"$t"); host=$(jq -r .hostname <<<"$t"); kind=$(jq -r .kind <<<"$t")
  name=$(jq -r .name <<<"$t"); auth=$(jq -r .auth_required <<<"$t")
  expect=$(jq -r '(.expect_codes // []) | join(",")' <<<"$t")
  for c in $(jq -r '.checks[]' <<<"$t"); do
    case "$c" in
      dns) res=$(check_dns "$host") ;;
      http) res=$(check_http "$host" "$auth" "$expect") ;;
      tls) res=$(check_tls "$host") ;;
      origin_tls) res=$(check_origin_tls "$host") ;;
      uptimerobot) res=$(check_uptimerobot "$host" "$work") ;;
      mail_dns)
        res=$(check_mail_dns "$host")
        checks=$(jq -c --argjson v "$res" '. + {mx:$v.mx, spf:$v.spf, dkim:$v.dkim}' <<<"$checks"); continue ;;
      *) res='{"status":"unavailable","detail":"unbekannter Check-Typ"}' ;;
    esac
    checks=$(jq -c --arg k "$c" --argjson v "$res" '. + {($k):$v}' <<<"$checks")
  done
  jq -nc --arg id "$id" --arg host "$host" --arg kind "$kind" --arg name "$name" --argjson checks "$checks" '
    def rank: if . == "fail" then 3 elif . == "warn" then 2 elif . == "ok" then 1 else 0 end;
    ([$checks[].status] | map(rank) | max // 0) as $r
    | {id:$id, hostname:$host, kind:$kind, name:$name,
       status: (if $r == 3 then "fail" elif $r == 2 then "warn" elif $r == 1 then "ok" else "unknown" end),
       checks:$checks}
    | if $kind == "unassigned" and .status == "ok" then .status = "info" else . end' >"$work/tile-${id}.json"
}

write_atomic() { # $1 = Zieldatei, stdin = Inhalt
  local dest="$1" tmp
  tmp=$(mktemp "${OUT_DIR}/.tmp.XXXXXX") || return 1
  cat >"$tmp" && chmod 644 "$tmp" && mv -f "$tmp" "$dest"
}

run_cycle() {
  local work ts targets_meta tiles overall max_hist
  work=$(mktemp -d) || return 1
  fetch_uptimerobot "$work"

  local count; count=$(jq '.targets | length' "$TARGETS_FILE")
  local i
  for ((i = 0; i < count; i++)); do
    run_target "$work" "$(jq -c ".targets[$i]" "$TARGETS_FILE")" &
  done
  wait

  tiles=$(jq -s -c 'sort_by(.id)' "$work"/tile-*.json)
  ts=$(now_iso)
  overall=$(jq -r '
    def rank: if . == "fail" then 3 elif . == "warn" then 2 else 0 end;
    ([.[].status | rank] | max // 0) as $r | if $r == 3 then "fail" elif $r == 2 then "warn" else "ok" end' <<<"$tiles")
  local ur_state; ur_state=$(jq -r .state "$work/uptimerobot.json")

  jq -n -c --arg ts "$ts" --argjson interval "$INTERVAL" --arg overall "$overall" \
        --arg ur "$ur_state" --argjson tiles "$tiles" '
    {generated_at:$ts, interval_seconds:$interval, overall:$overall,
     uptimerobot:$ur, tiles:$tiles}' \
    | write_atomic "$OUT_DIR/status.json"

  # History: rollierend 24 h = 86400/INTERVAL Einträge
  max_hist=$((86400 / INTERVAL))
  local old='[]'
  [[ -s "$OUT_DIR/history.json" ]] && old=$(jq -c '.entries // []' "$OUT_DIR/history.json" 2>/dev/null || echo '[]')
  jq -n -c --argjson old "$old" --arg ts "$ts" --arg overall "$overall" --argjson tiles "$tiles" --argjson max "$max_hist" '
    {entries: (($old + [{t:$ts, overall:$overall, tiles:($tiles | map({key:.id, value:.status}) | from_entries)}]) | .[-$max:])}' \
    | write_atomic "$OUT_DIR/history.json"

  rm -rf "$work"
  echo "$(now_iso) Zyklus fertig: overall=${overall}, ${count} Ziele, uptimerobot=${ur_state}"
}

main() {
  [[ -r "$TARGETS_FILE" ]] || { echo "FEHLER: ${TARGETS_FILE} nicht lesbar" >&2; exit 1; }
  mkdir -p "$OUT_DIR" || exit 1
  trap 'exit 0' TERM INT
  while true; do
    run_cycle || echo "$(now_iso) Zyklus fehlgeschlagen" >&2
    [[ "$RUN_ONCE" == "1" ]] && break
    sleep "$INTERVAL" &
    wait $!
  done
}

main "$@"
