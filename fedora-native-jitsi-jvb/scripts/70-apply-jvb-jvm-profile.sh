#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

ENV_FILE="${1:-./config.env}"
MODE="${2:-restart}"
INSTALLED_ENV=/etc/jitsi/videobridge/jvb.env
DIAGNOSTICS_DIR=/var/lib/jitsi-videobridge/diagnostics

need_root
[[ -f "${INSTALLED_ENV}" ]] || die "Missing installed JVB environment: ${INSTALLED_ENV}"

INSTALLED_JAVA_HOME="$(sed -n 's/^JAVA_HOME=//p' "${INSTALLED_ENV}" | head -n1)"
[[ -n "${INSTALLED_JAVA_HOME}" ]] || die "JAVA_HOME is missing from ${INSTALLED_ENV}"
load_env "${ENV_FILE}"

[[ "${JVB_PROFILE_ENFORCED}" == "true" ]] \
  || die "Select profiles/jvb-g1-120.env or profiles/jvb-zgc-120.env with JVB_PROFILE_FILE in config.env."
[[ "${MODE}" == "restart" || "${MODE}" == "--no-restart" || "${MODE}" == "--print-only" ]] \
  || die "Mode must be restart, --no-restart, or --print-only."

HEAP_OPTS="-Xms${JVB_HEAP} -Xmx${JVB_HEAP}"
RUNTIME_OPTS="$(jvb_runtime_opts)"
read -r -a SELECTOR_OPTS <<< "$(jvb_gc_selector_opts)"

log "Selected JVB JVM profile: ${JVB_GC_PROFILE}"
echo "Heap: ${JVB_HEAP}"
echo "JFR: ${JVB_JFR_ENABLED}"
echo "JVM options: ${HEAP_OPTS} ${RUNTIME_OPTS}"

"${INSTALLED_JAVA_HOME}/bin/java" "${SELECTOR_OPTS[@]}" -version >/dev/null

if [[ "${MODE}" == "--print-only" ]]; then
  log "Profile is supported by ${INSTALLED_JAVA_HOME}; no files or services were changed."
  exit 0
fi

install -d -m 0750 -o jvb -g jitsi "${DIAGNOSTICS_DIR}"
restorecon -R /var/lib/jitsi-videobridge /var/log/jitsi 2>/dev/null || true
tmp="$(mktemp)"
awk '
  /^(JVB_GC_PROFILE|JVB_JFR_ENABLED|JVB_HEAP_OPTS|JVB_RUNTIME_OPTS)=/ { next }
  { print }
' "${INSTALLED_ENV}" > "${tmp}"
cat >> "${tmp}" <<EOF
JVB_GC_PROFILE=${JVB_GC_PROFILE}
JVB_JFR_ENABLED=${JVB_JFR_ENABLED}
JVB_HEAP_OPTS='${HEAP_OPTS}'
JVB_RUNTIME_OPTS='${RUNTIME_OPTS}'
EOF
install -m 0640 -o root -g jitsi "${tmp}" "${INSTALLED_ENV}"
rm -f "${tmp}"

if [[ "${MODE}" == "--no-restart" ]]; then
  log "Profile was installed but JVB was not restarted."
  exit 0
fi

log "Restarting JVB; active meetings on this bridge will disconnect."
systemctl restart jitsi-videobridge

deadline=$((SECONDS + 90))
while (( SECONDS < deadline )); do
  if systemctl is-active --quiet jitsi-videobridge \
    && curl -fsS http://127.0.0.1:8080/metrics >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
systemctl is-active --quiet jitsi-videobridge \
  || die "JVB did not become active with the ${JVB_GC_PROFILE} profile."
curl -fsS http://127.0.0.1:8080/metrics >/dev/null \
  || die "JVB metrics did not become ready with the ${JVB_GC_PROFILE} profile."

pid="$(systemctl show -p MainPID --value jitsi-videobridge)"
echo "JVB PID: ${pid}"
tr '\0' ' ' < "/proc/${pid}/cmdline"
echo
log "JVB JVM profile ${JVB_GC_PROFILE} is active."
