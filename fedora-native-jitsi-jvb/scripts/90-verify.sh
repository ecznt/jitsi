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

jvb_gc_profile_matches() {
  local pid cmdline
  pid="$(systemctl show -p MainPID --value jitsi-videobridge 2>/dev/null || true)"
  [[ -n "${pid}" && "${pid}" != "0" ]] || return 1
  cmdline="$(tr '\0' ' ' < "/proc/${pid}/cmdline")"
  echo "configured_profile=${JVB_GC_PROFILE}"
  echo "configured_heap=${JVB_HEAP}"

  if [[ "${JVB_PROFILE_ENFORCED}" != "true" ]]; then
    echo "Legacy config.env has no explicit JVB JVM profile; collector enforcement skipped."
    return 0
  fi

  grep -Fq -- "-Xms${JVB_HEAP}" <<< "${cmdline}" || return 1
  grep -Fq -- "-Xmx${JVB_HEAP}" <<< "${cmdline}" || return 1
  grep -Fq -- '-XX:+AlwaysPreTouch' <<< "${cmdline}" || return 1
  case "${JVB_GC_PROFILE}" in
    g1)
      grep -Fq -- '-XX:+UseG1GC' <<< "${cmdline}" || return 1
      grep -Fq -- "-XX:MaxGCPauseMillis=${JVB_G1_MAX_PAUSE_MS}" <<< "${cmdline}" || return 1
      grep -Fq -- "-XX:G1ReservePercent=${JVB_G1_RESERVE_PERCENT}" <<< "${cmdline}" || return 1
      ! grep -Fq -- '-XX:+UseZGC' <<< "${cmdline}" || return 1
      ;;
    zgc)
      grep -Fq -- '-XX:+UseZGC' <<< "${cmdline}" || return 1
      grep -Fq -- '-XX:+ZGenerational' <<< "${cmdline}" || return 1
      ! grep -Fq -- '-XX:+UseG1GC' <<< "${cmdline}" || return 1
      ;;
  esac
  if [[ "${JVB_JFR_ENABLED}" == "true" ]]; then
    grep -Fq -- '-XX:StartFlightRecording=' <<< "${cmdline}" || return 1
  fi
}

prom_target_up() {
  curl -fsG 'http://127.0.0.1:9090/api/v1/query' --data-urlencode 'query=up{job="jvb"}' \
    | grep -Eq '"value":\[[^]]+,"1"\]'
}

grafana_has_dashboard() {
  [[ -f /var/lib/grafana/dashboards/jvb-capacity.json ]] \
    && grep -q 'JVB Capacity and Bottleneck Analysis' /var/lib/grafana/dashboards/jvb-capacity.json \
    && service_active grafana-server
}

grafana_prometheus_datasource_healthy() {
  local body
  body="$(curl -fsS \
    -u "${GRAFANA_ADMIN_USER:-admin}:${GRAFANA_ADMIN_PASSWORD:-admin}" \
    http://127.0.0.1:3000/api/datasources/uid/prometheus/health)" || return 1
  grep -Eq '"status"[[:space:]]*:[[:space:]]*"OK"' <<< "${body}"
}

report_clock_sync() {
  local synchronized
  command -v timedatectl >/dev/null 2>&1 || return 0
  synchronized="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)"
  echo "VM UTC time: $(date -u -Is)"
  echo "NTP synchronized: ${synchronized:-unknown}"
  if [[ "${synchronized}" != "yes" ]]; then
    echo "WARN: VM time is not NTP-synchronized. Compare this UTC time with the client host; clock skew can make Grafana panels appear empty." >&2
  fi
}

prom_target_up_job() {
  local job="$1"
  curl -fsG 'http://127.0.0.1:9090/api/v1/query' --data-urlencode "query=up{job=\"${job}\"}" \
    | grep -Eq '"value":\[[^]]+,"1"\]'
}

node_metrics_smoke() {
  local body
  body="$(curl -fsS http://127.0.0.1:9100/metrics)" || return 1
  grep -Eq '^node_cpu_seconds_total|^node_memory_MemAvailable_bytes' <<< "${body}"
}

jvb_jmx_metrics_smoke() {
  local body
  body="$(curl -fsS http://127.0.0.1:9404/metrics)" || return 1
  grep -Eq '^jvm_memory_used_bytes|^process_cpu_seconds_total' <<< "${body}"
}

prometheus_alert_rules_loaded() {
  curl -fsS http://127.0.0.1:9090/api/v1/rules \
    | grep -q 'JVBTargetDown'
}

web_smoke() {
  local body
  body="$(curl -kfsS --resolve "${JITSI_DOMAIN}:443:127.0.0.1" "https://${JITSI_DOMAIN}/")" || return 1
  grep -qi 'jitsi' <<< "${body}"
}

prosody_plugins_present() {
  [[ -f /opt/jitsi-native/usr/share/jitsi-meet/prosody-plugins/mod_conference_duration.lua ]]
}

prosody_selinux_http_port() {
  command -v getenforce >/dev/null 2>&1 || return 0
  [[ "$(getenforce)" == "Disabled" ]] && return 0
  ! semanage port -l -C 2>/dev/null \
    | awk '$1 == "http_port_t" && $2 == "tcp" { print $0 }' \
    | grep -Eq '(^|[[:space:],])5280([[:space:],]|$)'
}

web_asset_smoke() {
  local body
  for asset in config.js interface_config.js logging_config.js; do
    body="$(curl -kfsS --resolve "${JITSI_DOMAIN}:443:127.0.0.1" "https://${JITSI_DOMAIN}/${asset}")" || return 1
    grep -q '<!doctype html\|<html' <<< "${body}" && return 1
  done
  body="$(curl -kfsS --resolve "${JITSI_DOMAIN}:443:127.0.0.1" "https://${JITSI_DOMAIN}/config.js")" || return 1
  grep -q 'var config' <<< "${body}" || return 1
  body="$(curl -kfsS --resolve "${JITSI_DOMAIN}:443:127.0.0.1" "https://${JITSI_DOMAIN}/interface_config.js")" || return 1
  grep -q 'var interfaceConfig' <<< "${body}"
}

web_index_references_interface_config() {
  body="$(curl -kfsS --resolve "${JITSI_DOMAIN}:443:127.0.0.1" "https://${JITSI_DOMAIN}/")" || return 1
  if grep -q 'BEGIN FEDORA NATIVE JITSI CONFIG SHIM' <<< "${body}"; then
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
    return
  fi

  grep -q 'runtime-config-loader.js' <<< "${body}" || return 1
  grep -q 'var config = {' <<< "${body}" || return 1
  grep -q 'var interfaceConfig = {' <<< "${body}" || return 1
  awk '
    /runtime-config-loader\.js/ { runtime_line = NR }
    /<script[^>]+src="libs\/app\.bundle[^"]*"/ && app_line == 0 { app_line = NR }
    END {
      exit !(runtime_line > 0 && app_line > 0 && runtime_line < app_line)
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

prosody_http_listener() {
  timeout 3 bash -c 'cat < /dev/null > /dev/tcp/127.0.0.1/5280'
}

prosody_config_check() {
  local check_output
  if ! check_output="$(timeout 30 prosodyctl check config 2>&1)"; then
    echo "${check_output}"
    return 1
  fi
  echo "${check_output}"
  ! grep -Eiq 'failed to load|No such file or directory|Check for typos' <<< "${check_output}"
}

prosody_main_http_modules() {
  local cfg="/etc/prosody/prosody.cfg.lua"
  [[ -f "${cfg}" ]] || return 1
  awk '
    /^[[:space:]]*modules_enabled[[:space:]]*=[[:space:]]*\{/ {
      in_modules = 1
    }
    in_modules == 1 && /"http"/ { has_http = 1 }
    in_modules == 1 && /"bosh"/ { has_bosh = 1 }
    in_modules == 1 && /"websocket"/ { has_websocket = 1 }
    in_modules == 1 && /^[[:space:]]*\}/ {
      in_modules = 0
    }
    END {
      exit !(has_http == 1 && has_bosh == 1 && has_websocket == 1)
    }
  ' "${cfg}"
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
  grep -Eiq '^HTTP/[0-9.]+ 200' <<< "${response}" || return 1
  # A GET request intentionally returns Prosody's small BOSH status page.
  grep -Eiq 'Prosody BOSH endpoint|bosh|xmpp' <<< "${body}"
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
    "https://${JITSI_DOMAIN}/xmpp-websocket" 2>/dev/null || true)"
  grep -qi 'X-Jitsi-Native-Route: xmpp-websocket' <<< "${headers}" || {
    echo "Nginx did not select the /xmpp-websocket proxy location." >&2
    head -n 20 <<< "${headers}" >&2
    return 1
  }
  grep -Eiq 'HTTP/[0-9.]+ 101|101 Switching Protocols' <<< "${headers}"
}

metrics_smoke() {
  local body
  body="$(curl -fsS \
    -H 'Accept: application/openmetrics-text; version=1.0.0; charset=utf-8, text/plain; version=0.0.4' \
    http://127.0.0.1:8080/metrics)" || return 1
  grep -Eq '^jitsi_jvb_(conferences|local_endpoints|healthy)' <<< "${body}"
}

bridge_joined_since_jicofo_start() {
  local since logs
  since="$(systemctl show -p ActiveEnterTimestamp --value jicofo 2>/dev/null || true)"
  [[ -n "${since}" && "${since}" != "n/a" ]] || since="-10m"
  logs="$(journalctl -u jicofo --since "${since}" --no-pager 2>/dev/null || true)"
  grep -Eq 'Added new videobridge: Bridge\[jid=jvbbrewery@internal\.auth\.' <<< "${logs}"
}

no_muc_owner_errors_since_jicofo_start() {
  local since logs
  since="$(systemctl show -p ActiveEnterTimestamp --value jicofo 2>/dev/null || true)"
  [[ -n "${since}" && "${since}" != "n/a" ]] || since="-10m"
  logs="$(journalctl -u jicofo -u prosody --since "${since}" --no-pager 2>/dev/null || true)"
  ! grep -Eiq 'Only owners can configure rooms|Failed to create room|forbidden - auth' <<< "${logs}"
}

echo "Verification started at $(date -Is)"
report_clock_sync

check "Default Java is Java 21" assert_java21
check "Prosody service" service_active prosody
check "Jicofo service" service_active jicofo
check "JVB service" service_active jitsi-videobridge
check "Nginx service" service_active nginx
check "Prometheus service" service_active prometheus
check "Node Exporter service" service_active node-exporter
check "Grafana service" service_active grafana-server
check "Jicofo process uses Java 21" process_uses_java21 'jicofo.*\.jar'
check "JVB process uses Java 21" process_uses_java21 'jitsi-videobridge.*\.jar|jvb.*\.jar'
check "JVB JVM profile and heap" jvb_gc_profile_matches
check "Jitsi Meet web opens" web_smoke
check "Jitsi Meet web config assets" web_asset_smoke
check "Jitsi Meet index references interface_config.js" web_index_references_interface_config
check "Nginx has XMPP proxy routes" nginx_has_xmpp_routes
check "Prosody config check" prosody_config_check
check "Prosody main config loads HTTP modules" prosody_main_http_modules
check "Jitsi Prosody plugins are present" prosody_plugins_present
check "Prosody focus client proxy subscription" prosody_focus_proxy_subscription_present
check "SELinux reserves 5280 for Prosody" prosody_selinux_http_port
check "Prosody HTTP listener on 5280" prosody_http_listener
check "Prosody BOSH endpoint through Nginx" xmpp_bosh_smoke
check "Direct Prosody BOSH POST" prosody_direct_bosh_post_smoke
check "Prosody BOSH POST through Nginx" xmpp_bosh_post_smoke
check "Prosody XMPP WebSocket through Nginx" xmpp_websocket_smoke
check "JVB Prometheus metrics endpoint" metrics_smoke
check "JVB JMX metrics endpoint" jvb_jmx_metrics_smoke
check "Fedora Node Exporter metrics endpoint" node_metrics_smoke
check "Jicofo discovered JVB bridge" bridge_joined_since_jicofo_start
check "No Prosody MUC owner errors since Jicofo start" no_muc_owner_errors_since_jicofo_start
check "Prometheus JVB target UP" prom_target_up
check "Prometheus JVB JMX target UP" prom_target_up_job jvb-jmx
check "Prometheus Node Exporter target UP" prom_target_up_job node
check "Prometheus bottleneck alert rules loaded" prometheus_alert_rules_loaded
check "Grafana dashboard provisioned" grafana_has_dashboard
check "Grafana Prometheus datasource healthy" grafana_prometheus_datasource_healthy

echo
echo "Recent JVB/Jicofo/Prosody log lines:"
journalctl -u jitsi-videobridge -u jicofo -u prosody --since -10m --no-pager | tail -n 120 || true

echo
echo "Manual media validation still required:"
echo "  1. Open https://${JITSI_DOMAIN}/jvb-smoke from two browsers or clients."
echo "  2. Join both clients with audio/video."
echo "  3. Re-run this script and inspect JVB logs for ICE/DTLS/media errors."

exit "${fail}"
