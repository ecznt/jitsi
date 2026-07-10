#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

need_root

start_service() {
  local service="$1"
  log "Starting ${service}"
  systemctl reset-failed "${service}" >/dev/null 2>&1 || true
  systemctl start "${service}"
}

wait_active() {
  local service="$1"
  local timeout="${2:-30}"
  local deadline=$((SECONDS + timeout))
  while (( SECONDS < deadline )); do
    if systemctl is-active --quiet "${service}"; then
      return 0
    fi
    sleep 1
  done
  systemctl --no-pager --plain status "${service}" || true
  die "${service} did not become active within ${timeout}s"
}

unit_start_time() {
  local service="$1"
  local since
  since="$(systemctl show -p ActiveEnterTimestamp --value "${service}" 2>/dev/null || true)"
  [[ -n "${since}" && "${since}" != "n/a" ]] || since="-2m"
  echo "${since}"
}

wait_journal() {
  local service="$1"
  local pattern="$2"
  local timeout="${3:-60}"
  local since="$4"
  local deadline=$((SECONDS + timeout))
  while (( SECONDS < deadline )); do
    if journalctl -u "${service}" --since "${since}" --no-pager | grep -Eq "${pattern}"; then
      return 0
    fi
    sleep 2
  done
  journalctl -u "${service}" --since "${since}" --no-pager || true
  die "${service} did not log expected pattern within ${timeout}s: ${pattern}"
}

log "Starting Jitsi stack in required order"
systemctl enable prosody jicofo jitsi-videobridge nginx prometheus grafana-server >/dev/null 2>&1 || true

start_service prosody
wait_active prosody 30

start_service jicofo
jicofo_since="$(unit_start_time jicofo)"
wait_active jicofo 30
wait_journal jicofo 'Registered\.' 60 "${jicofo_since}"

start_service jitsi-videobridge
jvb_since="$(unit_start_time jitsi-videobridge)"
wait_active jitsi-videobridge 45
wait_journal jitsi-videobridge 'Joined MUC: jvbbrewery@internal\.auth\.' 90 "${jvb_since}"
wait_journal jicofo 'Added new videobridge: Bridge\[jid=jvbbrewery@internal\.auth\.' 90 "${jicofo_since}"

start_service nginx
start_service prometheus
start_service grafana-server

log "Current service state"
systemctl --no-pager --plain status \
  prosody jicofo jitsi-videobridge nginx prometheus grafana-server || true
