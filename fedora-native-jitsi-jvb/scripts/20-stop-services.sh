#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

need_root

stop_if_loaded() {
  local service="$1"
  if systemctl list-unit-files "${service}.service" >/dev/null 2>&1 \
    || systemctl list-units --all "${service}.service" >/dev/null 2>&1; then
    log "Stopping ${service}"
    systemctl stop "${service}" || true
  else
    log "Skipping ${service}; unit not found"
  fi
}

log "Stopping Jitsi stack in dependency-safe order"
stop_if_loaded nginx
stop_if_loaded jitsi-videobridge
stop_if_loaded jicofo
stop_if_loaded prosody
stop_if_loaded prometheus
stop_if_loaded node-exporter
stop_if_loaded grafana-server

log "Current service state"
systemctl --no-pager --plain status \
  prosody jicofo jitsi-videobridge nginx prometheus node-exporter grafana-server || true
