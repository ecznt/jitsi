#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

ENV_FILE="${1:-./config.env}"
need_root
load_env "${ENV_FILE}"

fail=0

check() {
  local name="$1"
  shift
  echo
  echo "### ${name}"
  if "$@"; then
    echo "OK: ${name}"
  else
    echo "FAIL: ${name}"
    fail=1
  fi
}

service_active() {
  systemctl is-active --quiet "$1"
}

process_uses_java21() {
  local pattern="$1"
  local pid exe version
  pid="$(pgrep -f "${pattern}" | head -n1 || true)"
  [[ -n "${pid}" ]] || return 1
  exe="$(readlink -f "/proc/${pid}/exe")"
  version="$("${exe}" -version 2>&1 || true)"
  echo "pid=${pid}"
  echo "exe=${exe}"
  echo "${version}"
  grep -Eq 'version "21\.|openjdk version "21\.' <<< "${version}"
}

prom_target_up() {
  curl -fsG 'http://127.0.0.1:9090/api/v1/query' --data-urlencode 'query=up{job="jvb"}' \
    | grep -Eq '"value":\[[^]]+,"1"\]'
}

grafana_has_dashboard() {
  [[ -f /var/lib/grafana/dashboards/jvb-first-phase.json ]] && service_active grafana-server
}

web_smoke() {
  curl -kfsS --resolve "${JITSI_DOMAIN}:443:127.0.0.1" "https://${JITSI_DOMAIN}/" | grep -qi 'jitsi'
}

web_asset_smoke() {
  for asset in config.js interface_config.js logging_config.js; do
    body="$(curl -kfsS --resolve "${JITSI_DOMAIN}:443:127.0.0.1" "https://${JITSI_DOMAIN}/${asset}")" || return 1
    grep -q '<!doctype html\|<html' <<< "${body}" && return 1
  done
  curl -kfsS --resolve "${JITSI_DOMAIN}:443:127.0.0.1" "https://${JITSI_DOMAIN}/config.js" \
    | grep -q 'var interfaceConfig'
}

web_index_references_interface_config() {
  body="$(curl -kfsS --resolve "${JITSI_DOMAIN}:443:127.0.0.1" "https://${JITSI_DOMAIN}/")" || return 1
  grep -q 'BEGIN FEDORA NATIVE JITSI CONFIG SHIM' <<< "${body}" || return 1
  grep -q 'var interfaceConfig = window.interfaceConfig' <<< "${body}" || return 1
  grep -q '<script src="interface_config.js"></script>' <<< "${body}" || return 1
  grep -q '<script src="logging_config.js"></script>' <<< "${body}" || return 1
  awk '
    /var interfaceConfig = window\.interfaceConfig/ { interface_line = NR }
    /<script src="logging_config\.js"><\/script>/ { logging_line = NR }
    /<script[^>]+src="libs\/app\.bundle[^"]*"/ && app_line == 0 { app_line = NR }
    END {
      exit !(interface_line > 0 && logging_line > 0 && app_line > 0 && interface_line < app_line && logging_line < app_line)
    }
  ' <<< "${body}"
}

nginx_has_xmpp_routes() {
  local conf="/etc/nginx/conf.d/${JITSI_DOMAIN}.conf"
  [[ -f "${conf}" ]] || return 1
  grep -q 'location \^~ /http-bind' "${conf}" || return 1
  grep -q 'proxy_pass http://127.0.0.1:5280' "${conf}" || return 1
  grep -q 'location \^~ /xmpp-websocket' "${conf}" || return 1
  grep -q 'X-Jitsi-Native-Route xmpp-websocket' "${conf}" || return 1
}

xmpp_bosh_smoke() {
  local response body
  response="$(curl -k -sS -i --resolve "${JITSI_DOMAIN}:443:127.0.0.1" "https://${JITSI_DOMAIN}/http-bind")" || return 1
  body="$(sed -n '/^\r\?$/,$p' <<< "${response}")"
  grep -qi 'X-Jitsi-Native-Route: bosh' <<< "${response}" || {
    echo "Nginx did not select the /http-bind proxy location." >&2
    head -n 20 <<< "${response}" >&2
    return 1
  }
  if grep -qi '<html\|<!doctype html\|app.bundle' <<< "${body}"; then
    echo "BOSH endpoint returned HTML instead of Prosody BOSH response." >&2
    head -n 20 <<< "${response}" >&2
    return 1
  fi
  grep -Eiq 'bosh|xmpp|body|bad-request|not-authorized|missing|invalid' <<< "${body}"
}

prosody_direct_bosh_post_smoke() {
  local rid body
  rid="$(date +%s%N)"
  body="$(curl -sS \
    -H "Host: ${JITSI_DOMAIN}" \
    -H 'Content-Type: text/xml; charset=utf-8' \
    --data "<body rid='${rid}' xmlns='http://jabber.org/protocol/httpbind' to='${JITSI_DOMAIN}' xml:lang='en' wait='60' hold='1' content='text/xml; charset=utf-8' ver='1.6' xmpp:version='1.0' xmlns:xmpp='urn:xmpp:xbosh'/>" \
    "http://127.0.0.1:5280/http-bind")" || return 1
  if grep -qi '<html\|<!doctype html\|app.bundle' <<< "${body}"; then
    echo "Direct Prosody BOSH returned HTML." >&2
    return 1
  fi
  grep -Eiq '<body|sid=|urn:xmpp:xbosh|stream:features|not-authorized|bad-request' <<< "${body}"
}

xmpp_bosh_post_smoke() {
  local rid response body
  rid="$(date +%s%N)"
  response="$(curl -k -sS -i --resolve "${JITSI_DOMAIN}:443:127.0.0.1" \
    -H 'Content-Type: text/xml; charset=utf-8' \
    --data "<body rid='${rid}' xmlns='http://jabber.org/protocol/httpbind' to='${JITSI_DOMAIN}' xml:lang='en' wait='60' hold='1' content='text/xml; charset=utf-8' ver='1.6' xmpp:version='1.0' xmlns:xmpp='urn:xmpp:xbosh'/>" \
    "https://${JITSI_DOMAIN}/http-bind")" || return 1
  body="$(sed -n '/^\r\?$/,$p' <<< "${response}")"
  grep -qi 'X-Jitsi-Native-Route: bosh' <<< "${response}" || {
    echo "Nginx did not select the /http-bind proxy location for POST." >&2
    head -n 20 <<< "${response}" >&2
    return 1
  }
  if grep -qi '<html\|<!doctype html\|app.bundle' <<< "${body}"; then
    echo "BOSH POST returned HTML instead of Prosody XML." >&2
    head -n 20 <<< "${response}" >&2
    return 1
  fi
  grep -Eiq '<body|sid=|urn:xmpp:xbosh|stream:features|not-authorized|bad-request' <<< "${body}"
}

xmpp_websocket_smoke() {
  local headers
  headers="$(curl -k -sS -i --max-time 5 --http1.1 --resolve "${JITSI_DOMAIN}:443:127.0.0.1" \
    -H 'Connection: Upgrade' \
    -H 'Upgrade: websocket' \
    -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
    -H 'Sec-WebSocket-Version: 13' \
    -H 'Sec-WebSocket-Protocol: xmpp' \
    "https://${JITSI_DOMAIN}/xmpp-websocket" || true)"
  grep -qi 'X-Jitsi-Native-Route: xmpp-websocket' <<< "${headers}" || {
    echo "Nginx did not select the /xmpp-websocket proxy location." >&2
    head -n 20 <<< "${headers}" >&2
    return 1
  }
  grep -Eiq 'HTTP/[0-9.]+ 101|101 Switching Protocols' <<< "${headers}"
}

metrics_smoke() {
  curl -fsS http://127.0.0.1:8080/metrics | grep -Eiq 'conferences|endpoints|jvm|jitsi|videobridge'
}

bridge_joined_since_jicofo_start() {
  local since
  since="$(systemctl show -p ActiveEnterTimestamp --value jicofo 2>/dev/null || true)"
  [[ -n "${since}" && "${since}" != "n/a" ]] || since="-10m"
  journalctl -u jicofo --since "${since}" --no-pager \
    | grep -Eq 'Added new videobridge: Bridge\[jid=jvbbrewery@internal\.auth\.'
}

no_muc_owner_errors_since_jicofo_start() {
  local since
  since="$(systemctl show -p ActiveEnterTimestamp --value jicofo 2>/dev/null || true)"
  [[ -n "${since}" && "${since}" != "n/a" ]] || since="-10m"
  ! journalctl -u jicofo -u prosody --since "${since}" --no-pager \
    | grep -Eiq 'Only owners can configure rooms|Failed to create room|forbidden - auth'
}

echo "Verification started at $(date -Is)"

check "Default Java is Java 21" assert_java21
check "Prosody service" service_active prosody
check "Jicofo service" service_active jicofo
check "JVB service" service_active jitsi-videobridge
check "Nginx service" service_active nginx
check "Prometheus service" service_active prometheus
check "Grafana service" service_active grafana-server
check "Jicofo process uses Java 21" process_uses_java21 'jicofo.*\.jar'
check "JVB process uses Java 21" process_uses_java21 'jitsi-videobridge.*\.jar|jvb.*\.jar'
check "Jitsi Meet web opens" web_smoke
check "Jitsi Meet web config assets" web_asset_smoke
check "Jitsi Meet index references interface_config.js" web_index_references_interface_config
check "Nginx has XMPP proxy routes" nginx_has_xmpp_routes
check "Prosody BOSH endpoint through Nginx" xmpp_bosh_smoke
check "Direct Prosody BOSH POST" prosody_direct_bosh_post_smoke
check "Prosody BOSH POST through Nginx" xmpp_bosh_post_smoke
check "Prosody XMPP WebSocket through Nginx" xmpp_websocket_smoke
check "JVB Prometheus metrics endpoint" metrics_smoke
check "Jicofo discovered JVB bridge" bridge_joined_since_jicofo_start
check "No Prosody MUC owner errors since Jicofo start" no_muc_owner_errors_since_jicofo_start
check "Prometheus JVB target UP" prom_target_up
check "Grafana dashboard provisioned" grafana_has_dashboard

echo
echo "Recent JVB/Jicofo/Prosody log lines:"
journalctl -u jitsi-videobridge -u jicofo -u prosody --since -10m --no-pager | tail -n 120 || true

echo
echo "Manual media validation still required:"
echo "  1. Open https://${JITSI_DOMAIN}/jvb-smoke from two browsers or clients."
echo "  2. Join both clients with audio/video."
echo "  3. Re-run this script and inspect JVB logs for ICE/DTLS/media errors."

exit "${fail}"
