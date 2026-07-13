#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

ENV_FILE="${1:-./config.env}"
CONF=/etc/jitsi/videobridge/jvb.conf

need_root
load_env "${ENV_FILE}"
[[ -f "${CONF}" ]] || die "Missing installed JVB config: ${CONF}"

backup="${CONF}.bak.last-n.$(date +%Y%m%d%H%M%S)"
tmp="$(mktemp)"
cp -a "${CONF}" "${backup}"

awk '
  /^# BEGIN FEDORA NATIVE JVB LASTN$/ { managed = 1; next }
  /^# END FEDORA NATIVE JVB LASTN$/ { managed = 0; next }
  !managed { print }
' "${CONF}" > "${tmp}"

cat >> "${tmp}" <<EOF

# BEGIN FEDORA NATIVE JVB LASTN
videobridge.cc.jvb-last-n = ${JVB_LAST_N}
# END FEDORA NATIVE JVB LASTN
EOF

install -m 0640 -o root -g jitsi "${tmp}" "${CONF}"
rm -f "${tmp}"

log "Restarting JVB with global lastN=${JVB_LAST_N}; active meetings will disconnect."
if ! systemctl restart jitsi-videobridge; then
  cp -a "${backup}" "${CONF}"
  systemctl restart jitsi-videobridge || true
  die "JVB restart failed; restored ${backup}."
fi

deadline=$((SECONDS + 90))
while (( SECONDS < deadline )); do
  if systemctl is-active --quiet jitsi-videobridge \
    && curl -fsS http://127.0.0.1:8080/metrics >/dev/null 2>&1; then
    log "JVB global lastN=${JVB_LAST_N} is active."
    echo "Backup: ${backup}"
    exit 0
  fi
  sleep 2
done

cp -a "${backup}" "${CONF}"
systemctl restart jitsi-videobridge || true
die "JVB did not become healthy; restored ${backup}."
