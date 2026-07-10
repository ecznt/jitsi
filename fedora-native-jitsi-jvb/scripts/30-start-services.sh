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

log "Starting Jitsi stack in required order"
systemctl enable prosody jicofo jitsi-videobridge nginx prometheus grafana-server >/dev/null 2>&1 || true

start_service prosody
sleep 2

start_service jicofo
sleep 8

start_service jitsi-videobridge
sleep 3

start_service nginx
start_service prometheus
start_service grafana-server

log "Current service state"
systemctl --no-pager --plain status \
  prosody jicofo jitsi-videobridge nginx prometheus grafana-server || true
