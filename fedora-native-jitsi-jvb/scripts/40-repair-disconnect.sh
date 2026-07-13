#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

ENV_FILE="${1:-./config.env}"
need_root
load_env "${ENV_FILE}"

log "Repairing disconnect state with a clean ordered restart"
bash "${SCRIPT_DIR}/20-stop-services.sh"

log "Resetting failed units"
systemctl reset-failed prosody jicofo jitsi-videobridge nginx prometheus grafana-server || true

log "Provisioning the Prosody client proxy subscription"
provision_prosody_focus_proxy_subscription \
  || die "Could not persist the Jicofo client proxy subscription in Prosody."

log "Starting stack and waiting for Jicofo/JVB readiness"
bash "${SCRIPT_DIR}/30-start-services.sh"

log "Running verification"
bash "${SCRIPT_DIR}/90-verify.sh" "${ENV_FILE}"

log "If the browser still disconnects, collect fresh logs with:"
echo "journalctl -u nginx -u prosody -u jicofo -u jitsi-videobridge --since -5m --no-pager"
