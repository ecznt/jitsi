#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${JVB_WATCHDOG_ENV_FILE:-/etc/jitsi/videobridge/stall-watchdog.env}"
if [[ -r "${ENV_FILE}" ]]; then
  set -a
  source "${ENV_FILE}"
  set +a
fi

STATE_DIR="${JVB_WATCHDOG_STATE_DIR:-/var/lib/jitsi-videobridge/diagnostics/watchdog}"
TEXTFILE_DIR="${JVB_NODE_EXPORTER_TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"
CAPTURE_SCRIPT="${JVB_CAPTURE_SCRIPT:-/usr/local/sbin/jvb-capture-incident}"
PROMETHEUS_URL="${JVB_PROMETHEUS_URL:-http://127.0.0.1:9090}"

CONSECUTIVE_LIMIT="${JVB_WATCHDOG_CONSECUTIVE_LIMIT:-3}"
COOLDOWN_SECONDS="${JVB_WATCHDOG_COOLDOWN_SECONDS:-900}"
THREAD_LIMIT="${JVB_WATCHDOG_THREAD_LIMIT:-0}"
BLOCKED_THREAD_LIMIT="${JVB_WATCHDOG_BLOCKED_THREAD_LIMIT:-8}"
CPU_PERCENT_LIMIT="${JVB_WATCHDOG_CPU_PERCENT_LIMIT:-87.5}"
STRESS_LIMIT="${JVB_WATCHDOG_STRESS_LIMIT:-0.90}"
TRANSIT_P99_MS_LIMIT="${JVB_WATCHDOG_TRANSIT_P99_MS_LIMIT:-100}"
MAX_SAMPLE_LINES="${JVB_WATCHDOG_MAX_SAMPLE_LINES:-40320}"

query() {
  local expression="$1"
  curl --fail --silent --show-error --max-time 5 \
    --get --data-urlencode "query=${expression}" \
    "${PROMETHEUS_URL}/api/v1/query" \
    | sed -n 's/.*"value":\[[^]]*,"\([^"]*\)"\].*/\1/p'
}

number_or_zero() {
  local value="$1"
  if [[ "${value}" =~ ^-?[0-9]+([.][0-9]+)?([eE][-+]?[0-9]+)?$ ]]; then
    printf '%s' "${value}"
  else
    printf '0'
  fi
}

greater_equal() {
  awk -v observed="$1" -v limit="$2" 'BEGIN { exit !(observed >= limit) }'
}

install -d -m 0750 "${STATE_DIR}"
install -d -m 0755 "${TEXTFILE_DIR}"
umask 0027

if ! curl --fail --silent --max-time 5 "${PROMETHEUS_URL}/-/ready" >/dev/null; then
  printf '{"timestamp":"%s","error":"prometheus_not_ready"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    >"${STATE_DIR}/last-error.json"
  exit 0
fi
rm -f "${STATE_DIR}/last-error.json"

NOW="$(date +%s)"
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
THREADS="$(number_or_zero "$(query 'max(jvm_threads_current{job="jvb-jmx"})' || true)")"
BLOCKED="$(number_or_zero "$(query 'sum(jvm_threads_state{job="jvb-jmx",state=~"BLOCKED|blocked"})' || true)")"
DEADLOCKED="$(number_or_zero "$(query 'max(jvm_threads_deadlocked{job="jvb-jmx"})' || true)")"
CPU_CORES="$(number_or_zero "$(query 'sum(rate(process_cpu_seconds_total{job="jvb-jmx"}[1m]))' || true)")"
CPU_PERCENT="$(number_or_zero "$(query '100 * sum(rate(process_cpu_seconds_total{job="jvb-jmx"}[1m])) / count(node_cpu_seconds_total{job="node",mode="idle"})' || true)")"
STRESS="$(number_or_zero "$(query 'max(jitsi_jvb_stress_level)' || true)")"
TRANSIT_P99_MS="$(number_or_zero "$(query 'histogram_quantile(0.99, sum by (le) (rate(jitsi_jvb_rtp_transit_time_bucket[1m])))' || true)")"
HEALTHY_RAW="$(query 'max(jitsi_jvb_healthy)' || true)"
HEALTHY_PRESENT=0
if [[ "${HEALTHY_RAW}" =~ ^-?[0-9]+([.][0-9]+)?([eE][-+]?[0-9]+)?$ ]]; then
  HEALTHY="${HEALTHY_RAW}"
  HEALTHY_PRESENT=1
else
  HEALTHY=0
fi
JVB_UP="$(number_or_zero "$(query 'max(up{job="jvb"})' || true)")"
ENDPOINTS="$(number_or_zero "$(query 'sum(jitsi_jvb_local_endpoints) + sum(jitsi_jvb_current_visitors)' || true)")"
CONFERENCES="$(number_or_zero "$(query 'sum(jitsi_jvb_conferences)' || true)")"

REASONS=()
greater_equal "${DEADLOCKED}" 1 && REASONS+=(deadlock)
greater_equal "${BLOCKED}" "${BLOCKED_THREAD_LIMIT}" && REASONS+=(blocked_threads)
greater_equal "${CPU_PERCENT}" "${CPU_PERCENT_LIMIT}" && REASONS+=(cpu_saturation)
greater_equal "${STRESS}" "${STRESS_LIMIT}" && REASONS+=(jvb_stress)
greater_equal "${TRANSIT_P99_MS}" "${TRANSIT_P99_MS_LIMIT}" && REASONS+=(media_transit)
if greater_equal "${HEALTHY_PRESENT}" 0.5 && greater_equal "${JVB_UP}" 0.5 && greater_equal 0.5 "${HEALTHY}"; then
  REASONS+=(unhealthy)
fi
if [[ "${THREAD_LIMIT}" != 0 ]] && greater_equal "${THREADS}" "${THREAD_LIMIT}"; then
  REASONS+=(thread_count)
fi

COUNT_FILE="${STATE_DIR}/consecutive-count"
LAST_TRIGGER_FILE="${STATE_DIR}/last-trigger-epoch"
COUNT="$(cat "${COUNT_FILE}" 2>/dev/null || printf '0')"
LAST_TRIGGER="$(cat "${LAST_TRIGGER_FILE}" 2>/dev/null || printf '0')"
TRIGGERED=0

if (( ${#REASONS[@]} > 0 )); then
  COUNT=$((COUNT + 1))
else
  COUNT=0
fi
printf '%s\n' "${COUNT}" >"${COUNT_FILE}"

if (( COUNT >= CONSECUTIVE_LIMIT && NOW - LAST_TRIGGER >= COOLDOWN_SECONDS )); then
  REASON="$(IFS=+; printf '%s' "${REASONS[*]}")"
  if "${CAPTURE_SCRIPT}" "watchdog-${REASON}" >>"${STATE_DIR}/capture.log" 2>&1; then
    TRIGGERED=1
    LAST_TRIGGER="${NOW}"
    printf '%s\n' "${NOW}" >"${LAST_TRIGGER_FILE}"
  fi
  printf '0\n' >"${COUNT_FILE}"
fi

printf '{"timestamp":"%s","threads":%s,"blocked":%s,"deadlocked":%s,"cpu_cores":%s,"cpu_percent":%s,"stress":%s,"rtp_transit_p99_ms":%s,"healthy":%s,"healthy_present":%s,"endpoints":%s,"conferences":%s,"consecutive":%s,"triggered":%s,"reasons":"%s"}\n' \
  "${TIMESTAMP}" "${THREADS}" "${BLOCKED}" "${DEADLOCKED}" "${CPU_CORES}" "${CPU_PERCENT}" "${STRESS}" "${TRANSIT_P99_MS}" "${HEALTHY}" "${HEALTHY_PRESENT}" \
  "${ENDPOINTS}" "${CONFERENCES}" "${COUNT}" "${TRIGGERED}" "$(IFS=,; printf '%s' "${REASONS[*]:-none}")" \
  >>"${STATE_DIR}/samples.jsonl"

SAMPLE_LINES="$(wc -l <"${STATE_DIR}/samples.jsonl")"
if (( SAMPLE_LINES > MAX_SAMPLE_LINES * 2 )); then
  SAMPLE_TMP="$(mktemp "${STATE_DIR}/samples.jsonl.XXXXXX")"
  tail -n "${MAX_SAMPLE_LINES}" "${STATE_DIR}/samples.jsonl" >"${SAMPLE_TMP}"
  chmod 0640 "${SAMPLE_TMP}"
  mv "${SAMPLE_TMP}" "${STATE_DIR}/samples.jsonl"
fi

PROM_TMP="$(mktemp "${TEXTFILE_DIR}/jvb_watchdog.prom.XXXXXX")"
cat >"${PROM_TMP}" <<EOF
# HELP jvb_watchdog_last_run_timestamp_seconds Unix timestamp of the last watchdog sample.
# TYPE jvb_watchdog_last_run_timestamp_seconds gauge
jvb_watchdog_last_run_timestamp_seconds ${NOW}
# HELP jvb_watchdog_last_trigger_timestamp_seconds Unix timestamp of the last incident capture.
# TYPE jvb_watchdog_last_trigger_timestamp_seconds gauge
jvb_watchdog_last_trigger_timestamp_seconds ${LAST_TRIGGER}
# HELP jvb_watchdog_triggered Whether this sample triggered an incident capture.
# TYPE jvb_watchdog_triggered gauge
jvb_watchdog_triggered ${TRIGGERED}
# HELP jvb_watchdog_consecutive_breaches Current number of consecutive threshold breaches.
# TYPE jvb_watchdog_consecutive_breaches gauge
jvb_watchdog_consecutive_breaches ${COUNT}
jvb_watchdog_threads ${THREADS}
jvb_watchdog_blocked_threads ${BLOCKED}
jvb_watchdog_deadlocked_threads ${DEADLOCKED}
jvb_watchdog_process_cpu_cores ${CPU_CORES}
jvb_watchdog_process_cpu_percent ${CPU_PERCENT}
jvb_watchdog_jvb_stress ${STRESS}
jvb_watchdog_rtp_transit_p99_milliseconds ${TRANSIT_P99_MS}
jvb_watchdog_jvb_health_metric_present ${HEALTHY_PRESENT}
EOF
chmod 0644 "${PROM_TMP}"
mv "${PROM_TMP}" "${TEXTFILE_DIR}/jvb_watchdog.prom"
