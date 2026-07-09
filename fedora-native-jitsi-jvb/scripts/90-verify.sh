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
}

web_index_references_interface_config() {
  curl -kfsS --resolve "${JITSI_DOMAIN}:443:127.0.0.1" "https://${JITSI_DOMAIN}/" \
    | grep -q 'interface_config.js'
}

metrics_smoke() {
  curl -fsS http://127.0.0.1:8080/metrics | grep -Eiq 'conferences|endpoints|jvm|jitsi|videobridge'
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
check "JVB Prometheus metrics endpoint" metrics_smoke
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
