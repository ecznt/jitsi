#!/usr/bin/env bash
set -euo pipefail

# Collects a bounded, point-in-time JVB incident bundle. It intentionally does
# not read /proc/<pid>/environ or JVM system properties because those can
# contain XMPP credentials and other secrets.

REASON="${1:-manual}"
SERVICE="${JVB_SERVICE:-}"
INCIDENT_ROOT="${JVB_INCIDENT_ROOT:-/var/lib/jitsi-videobridge/diagnostics/incidents}"
THREAD_DUMP_COUNT="${JVB_THREAD_DUMP_COUNT:-3}"
THREAD_DUMP_INTERVAL_SECONDS="${JVB_THREAD_DUMP_INTERVAL_SECONDS:-5}"
JFR_MAX_AGE="${JVB_INCIDENT_JFR_MAX_AGE:-10m}"
JOURNAL_SINCE="${JVB_INCIDENT_JOURNAL_SINCE:--10 minutes}"

log() {
  printf '[jvb-incident] %s\n' "$*" >&2
}

safe_reason() {
  printf '%s' "$1" | tr -cs 'A-Za-z0-9._-' '_'
}

detect_service() {
  local candidate
  if [[ -n "${SERVICE}" ]]; then
    printf '%s\n' "${SERVICE}"
    return
  fi
  for candidate in jitsi-videobridge2 jitsi-videobridge; do
    if systemctl show "${candidate}.service" >/dev/null 2>&1; then
      printf '%s\n' "${candidate}"
      return
    fi
  done
  return 1
}

find_pid() {
  local service_name="$1"
  local pid
  pid="$(systemctl show --property MainPID --value "${service_name}.service" 2>/dev/null || true)"
  if [[ "${pid}" =~ ^[1-9][0-9]*$ ]] && [[ -r "/proc/${pid}/status" ]]; then
    printf '%s\n' "${pid}"
    return
  fi
  pgrep -o -f 'org\.jitsi\.videobridge\.MainKt|org\.jitsi\.videobridge\.Main' || true
}

run_capture() {
  local output_file="$1"
  shift
  {
    printf '$'
    printf ' %q' "$@"
    printf '\n'
    timeout 30s "$@"
  } >"${output_file}" 2>&1 || true
}

capture_url() {
  local output_file="$1"
  local url="$2"
  curl --fail --silent --show-error --max-time 10 "${url}" >"${output_file}" 2>&1 || true
}

analyze_thread_dumps() {
  local output_file="$1"
  shift
  local dump_files=("$@")
  local dump_file
  local expected="${#dump_files[@]}"

  {
    printf 'JVB thread incident preliminary analysis\n'
    printf 'generated_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'dump_count=%s\n\n' "${expected}"
    printf 'This summary identifies repeatable evidence; it is not a final root-cause verdict.\n\n'

    printf '=== Thread state counts per dump ===\n'
    for dump_file in "${dump_files[@]}"; do
      printf -- '--- %s ---\n' "$(basename "${dump_file}")"
      awk '/java.lang.Thread.State:/ { state=$2; sub(/\(.*/, "", state); count[state]++ } END { for (state in count) printf "%-20s %d\n", state, count[state] }' "${dump_file}" | sort
    done

    printf '\n=== Threads BLOCKED in every dump ===\n'
    {
      for dump_file in "${dump_files[@]}"; do
        awk '/^"/ { name=$0; sub(/^"/, "", name); sub(/".*/, "", name) } /java.lang.Thread.State: BLOCKED/ && name != "" { print name }' "${dump_file}"
      done
    } | sort | uniq -c | awk -v expected="${expected}" '$1 >= expected { count=$1; $1=""; sub(/^ +/, ""); printf "%d/%d dumps: %s\n", count, expected, $0; found=1 } END { if (!found) print "None" }'

    printf '\n=== All observed BLOCKED threads ===\n'
    for dump_file in "${dump_files[@]}"; do
      printf -- '--- %s ---\n' "$(basename "${dump_file}")"
      awk '/^"/ { header=$0 } /java.lang.Thread.State: BLOCKED/ { print header; print $0 }' "${dump_file}"
    done

    printf '\n=== JVM deadlock evidence ===\n'
    if grep -qE 'Found one Java-level deadlock|Found [0-9]+ deadlocks' "${dump_files[@]}"; then
      grep -nHE -A80 'Found one Java-level deadlock|Found [0-9]+ deadlocks' "${dump_files[@]}" || true
    else
      printf 'No JVM-reported Java-level deadlock in the captured dumps.\n'
    fi

    printf '\n=== Lock and park evidence (first 400 matching lines) ===\n'
    grep -nHE 'waiting to lock|waiting on|parking to wait|locked <|java.lang.Thread.State: BLOCKED' "${dump_files[@]}" | sed -n '1,400p' || true

    printf '\n=== Highest per-thread CPU samples from ps ===\n'
    if [[ -r "${INCIDENT_DIR}/threads-ps.txt" ]]; then
      awk '$1 ~ /^[0-9]+$/ {print}' "${INCIDENT_DIR}/threads-ps.txt" | sort -k7,7nr | head -20 || true
    else
      printf 'threads-ps.txt not available.\n'
    fi
  } >"${output_file}"
}

if (( EUID != 0 )); then
  log 'Run as root so jcmd, journal and /proc thread data are accessible.'
  exit 1
fi

command -v jcmd >/dev/null 2>&1 || {
  log 'jcmd is required. Install the JDK package matching the JVB runtime.'
  exit 1
}

SERVICE="$(detect_service)" || {
  log 'Could not detect jitsi-videobridge2.service or jitsi-videobridge.service.'
  exit 1
}
PID="$(find_pid "${SERVICE}")"
if [[ ! "${PID}" =~ ^[1-9][0-9]*$ ]]; then
  log "No live JVB PID found for ${SERVICE}."
  exit 1
fi
SERVICE_USER="$(ps -o user= -p "${PID}" 2>/dev/null | awk '{print $1}')"
if [[ -z "${SERVICE_USER}" ]]; then
  SERVICE_USER="$(systemctl show --property User --value "${SERVICE}.service" 2>/dev/null || true)"
fi
SERVICE_USER="${SERVICE_USER:-root}"
SERVICE_GROUP="$(id -gn "${SERVICE_USER}" 2>/dev/null || printf 'root')"

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
INCIDENT_DIR="${INCIDENT_ROOT}/${TIMESTAMP}-$(safe_reason "${REASON}")"
install -d -m 0750 -o root -g "${SERVICE_GROUP}" "${INCIDENT_ROOT}"
# JFR.dump is executed by the target JVM, not by jcmd. Give the JVB service
# group temporary write access, then remove it after all evidence is collected.
install -d -m 0770 -o root -g "${SERVICE_GROUP}" "${INCIDENT_DIR}"
umask 0027

cat >"${INCIDENT_DIR}/metadata.txt" <<EOF
timestamp_utc=${TIMESTAMP}
reason=$(safe_reason "${REASON}")
service=${SERVICE}
pid=${PID}
hostname=$(hostname -f 2>/dev/null || hostname)
kernel=$(uname -srmo)
EOF

run_capture "${INCIDENT_DIR}/service-status.txt" systemctl status --no-pager --full "${SERVICE}.service"
run_capture "${INCIDENT_DIR}/process.txt" ps -p "${PID}" -o pid,ppid,nlwp,psr,stat,etimes,%cpu,%mem,rss,vsz,comm
run_capture "${INCIDENT_DIR}/threads-ps.txt" ps -L -p "${PID}" -o pid,tid,psr,stat,pri,ni,pcpu,time,wchan:32,comm
run_capture "${INCIDENT_DIR}/threads-top.txt" top -H -b -n 1 -p "${PID}"
run_capture "${INCIDENT_DIR}/jvm-flags.txt" jcmd "${PID}" VM.flags
run_capture "${INCIDENT_DIR}/jvm-version.txt" jcmd "${PID}" VM.version
run_capture "${INCIDENT_DIR}/heap-info.txt" jcmd "${PID}" GC.heap_info
run_capture "${INCIDENT_DIR}/jfr-check.txt" jcmd "${PID}" JFR.check

for (( index=1; index<=THREAD_DUMP_COUNT; index++ )); do
  run_capture "${INCIDENT_DIR}/thread-dump-${index}.txt" jcmd "${PID}" Thread.print -l -e
  if (( index < THREAD_DUMP_COUNT )); then
    sleep "${THREAD_DUMP_INTERVAL_SECONDS}"
  fi
done

analyze_thread_dumps "${INCIDENT_DIR}/thread-analysis.txt" "${INCIDENT_DIR}"/thread-dump-*.txt

# Dump a copy of the already-running rolling recording; do not start a second
# recording if JFR was disabled deliberately.
timeout 30s jcmd "${PID}" JFR.dump \
  filename="${INCIDENT_DIR}/incident.jfr" \
  maxage="${JFR_MAX_AGE}" \
  >/dev/null 2>"${INCIDENT_DIR}/jfr-dump-error.txt" || true

if command -v jfr >/dev/null 2>&1 && [[ -s "${INCIDENT_DIR}/incident.jfr" ]]; then
  run_capture "${INCIDENT_DIR}/jfr-summary.txt" jfr summary "${INCIDENT_DIR}/incident.jfr"
fi

for proc_file in status limits sched io cgroup; do
  if [[ -r "/proc/${PID}/${proc_file}" ]]; then
    cp "/proc/${PID}/${proc_file}" "${INCIDENT_DIR}/proc-${proc_file}.txt"
  fi
done

run_capture "${INCIDENT_DIR}/journal.txt" journalctl -u "${SERVICE}.service" --since "${JOURNAL_SINCE}" --no-pager -o short-iso-precise
run_capture "${INCIDENT_DIR}/vmstat.txt" vmstat 1 5
run_capture "${INCIDENT_DIR}/socket-summary.txt" ss -s
run_capture "${INCIDENT_DIR}/network-statistics.txt" nstat -az
run_capture "${INCIDENT_DIR}/interfaces.txt" ip -s -s link
run_capture "${INCIDENT_DIR}/interrupts.txt" sh -c 'cat /proc/interrupts'
run_capture "${INCIDENT_DIR}/softnet-stat.txt" sh -c 'cat /proc/net/softnet_stat'
run_capture "${INCIDENT_DIR}/snmp.txt" sh -c 'cat /proc/net/snmp'
run_capture "${INCIDENT_DIR}/sysctl-network.txt" sysctl net.core.rmem_max net.core.rmem_default net.core.netdev_max_backlog net.ipv4.udp_mem net.ipv4.udp_rmem_min

if command -v mpstat >/dev/null 2>&1; then
  run_capture "${INCIDENT_DIR}/mpstat.txt" mpstat -P ALL 1 5
fi
if command -v pidstat >/dev/null 2>&1; then
  run_capture "${INCIDENT_DIR}/pidstat.txt" pidstat -p "${PID}" -t -u -w 1 5
fi

capture_url "${INCIDENT_DIR}/jvb-metrics.prom" http://127.0.0.1:8080/metrics
capture_url "${INCIDENT_DIR}/jvm-metrics.prom" http://127.0.0.1:9404/metrics
capture_url "${INCIDENT_DIR}/node-metrics.prom" http://127.0.0.1:9100/metrics

# GC/safepoint logs are copied only when present. The cap prevents a stale log
# directory from turning one incident into an unbounded disk operation.
find /var/log/jitsi -maxdepth 2 -type f \
  \( -name '*gc*.log*' -o -name '*safepoint*.log*' \) \
  -size -256M -mmin -180 -exec cp --parents '{}' "${INCIDENT_DIR}" \; 2>/dev/null || true

chmod -R u=rwX,g=rX,o= "${INCIDENT_DIR}"
log "Incident captured: ${INCIDENT_DIR}"
printf '%s\n' "${INCIDENT_DIR}"
