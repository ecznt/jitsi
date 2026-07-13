#!/usr/bin/env bash
set -euo pipefail

die() {
  echo "ERROR: $*" >&2
  exit 1
}

log() {
  echo "==> $*"
}

need_root() {
  [[ ${EUID} -eq 0 ]] || die "Run as root."
}

load_env() {
  local env_file="${1:-./config.env}"
  local profile_file
  [[ -f "${env_file}" ]] || die "Missing env file: ${env_file}"
  # shellcheck disable=SC1090
  source "${env_file}"

  if [[ -n "${JVB_PROFILE_FILE:-}" ]]; then
    profile_file="${JVB_PROFILE_FILE}"
    if [[ "${profile_file}" != /* ]]; then
      profile_file="$(dirname "${env_file}")/${profile_file}"
    fi
    [[ -f "${profile_file}" ]] || die "Missing JVB profile file: ${profile_file}"
    # shellcheck disable=SC1090
    source "${profile_file}"
  fi

  if [[ -n "${JVB_PROFILE_FILE:-}" || -n "${JVB_GC_PROFILE:-}" ]]; then
    JVB_PROFILE_ENFORCED=true
  else
    JVB_PROFILE_ENFORCED=false
  fi
  JVB_GC_PROFILE="${JVB_GC_PROFILE:-g1}"
  JVB_JFR_ENABLED="${JVB_JFR_ENABLED:-false}"
  JVB_G1_MAX_PAUSE_MS="${JVB_G1_MAX_PAUSE_MS:-50}"
  JVB_G1_RESERVE_PERCENT="${JVB_G1_RESERVE_PERCENT:-20}"
  JVB_JFR_MAXAGE="${JVB_JFR_MAXAGE:-2h}"
  JVB_JFR_MAXSIZE="${JVB_JFR_MAXSIZE:-1g}"
  JVB_LAST_N="${JVB_LAST_N:-16}"

  : "${JITSI_DOMAIN:?JITSI_DOMAIN is required}"
  : "${TLS_MODE:?TLS_MODE is required}"
  : "${JITSI_REPO_URL:?JITSI_REPO_URL is required}"
  : "${JVB_HEAP:?JVB_HEAP is required}"
  : "${JICOFO_HEAP:?JICOFO_HEAP is required}"

  [[ "${JVB_GC_PROFILE}" == "g1" || "${JVB_GC_PROFILE}" == "zgc" ]] \
    || die "JVB_GC_PROFILE must be g1 or zgc."
  [[ "${JVB_JFR_ENABLED}" == "true" || "${JVB_JFR_ENABLED}" == "false" ]] \
    || die "JVB_JFR_ENABLED must be true or false."
  [[ "${JVB_G1_MAX_PAUSE_MS}" =~ ^[1-9][0-9]*$ ]] \
    || die "JVB_G1_MAX_PAUSE_MS must be a positive integer."
  [[ "${JVB_G1_RESERVE_PERCENT}" =~ ^[1-9][0-9]*$ ]] \
    || die "JVB_G1_RESERVE_PERCENT must be a positive integer."
  [[ "${JVB_LAST_N}" =~ ^[0-9]+$ ]] \
    || die "JVB_LAST_N must be a non-negative integer."
}

jvb_gc_selector_opts() {
  case "${JVB_GC_PROFILE}" in
    g1)
      printf '%s\n' "-XX:+UseG1GC -XX:MaxGCPauseMillis=${JVB_G1_MAX_PAUSE_MS} -XX:G1ReservePercent=${JVB_G1_RESERVE_PERCENT}"
      ;;
    zgc)
      printf '%s\n' '-XX:+UseZGC -XX:+ZGenerational'
      ;;
  esac
}

jvb_runtime_opts() {
  local opts diagnostics_dir gc_log
  diagnostics_dir=/var/lib/jitsi-videobridge/diagnostics
  gc_log="/var/log/jitsi/jvb-${JVB_GC_PROFILE}-gc.log"
  opts="$(jvb_gc_selector_opts) -XX:+AlwaysPreTouch"
  opts+=" -XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath=${diagnostics_dir} -XX:+ExitOnOutOfMemoryError"
  opts+=" -Xlog:gc*,safepoint:file=${gc_log}:time,uptime,level,tags:filecount=10,filesize=100M"
  if [[ "${JVB_JFR_ENABLED}" == "true" ]]; then
    opts+=" -XX:StartFlightRecording=filename=${diagnostics_dir}/jvb-${JVB_GC_PROFILE}.jfr,settings=profile,dumponexit=true,maxage=${JVB_JFR_MAXAGE},maxsize=${JVB_JFR_MAXSIZE}"
  fi
  printf '%s\n' "${opts}"
}

prosody_focus_proxy_roster_file() {
  local auth_host encoded_host
  auth_host="auth.${JITSI_DOMAIN}"
  encoded_host="${auth_host//./%2e}"
  printf '/var/lib/prosody/%s/roster/focus.dat\n' "${encoded_host}"
}

prosody_focus_proxy_subscription_present() {
  local roster_file focus_jid
  roster_file="$(prosody_focus_proxy_roster_file)"
  focus_jid="focus.${JITSI_DOMAIN}"
  [[ -r "${roster_file}" ]] || return 1
  awk -v jid="${focus_jid}" '
    index($0, "[\"" jid "\"]") {
      in_entry = 1
      next
    }
    in_entry && /\["subscription"\][[:space:]]*=[[:space:]]*"from"/ {
      found = 1
    }
    in_entry && /^[[:space:]]*};/ {
      exit !found
    }
    END {
      exit !found
    }
  ' "${roster_file}"
}

provision_prosody_focus_proxy_subscription() {
  prosodyctl mod_roster_command subscribe \
    "focus.${JITSI_DOMAIN}" \
    "focus@auth.${JITSI_DOMAIN}" \
    || return 1
  prosody_focus_proxy_subscription_present
}

require_fedora() {
  [[ -r /etc/os-release ]] || die "Cannot read /etc/os-release"
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == "fedora" ]] || die "This installer is for Fedora. Detected ID=${ID:-unknown}"
}

refuse_container() {
  if command -v systemd-detect-virt >/dev/null 2>&1 && systemd-detect-virt -c --quiet; then
    die "Container environment detected. This first-phase lab must run without Docker/Podman/container."
  fi
}

random_secret() {
  openssl rand -hex 24
}

backup_file() {
  local path="$1"
  if [[ -e "${path}" && ! -L "${path}" ]]; then
    cp -a "${path}" "${path}.bak.$(date +%Y%m%d%H%M%S)"
  fi
}

render_template() {
  local src="$1"
  local dst="$2"
  install -d -m 0755 "$(dirname "${dst}")"
  backup_file "${dst}"
  envsubst '${JITSI_DOMAIN} ${TLS_DIR} ${PROSODY_PLUGIN_PATH} ${JICOFO_AUTH_PASSWORD} ${JVB_AUTH_PASSWORD} ${PRIVATE_IP} ${PUBLIC_IP} ${JITSI_MEET_ROOT} ${GRAFANA_ADMIN_USER} ${GRAFANA_ADMIN_PASSWORD} ${JVB_LAST_N}' < "${src}" > "${dst}"
}

java21_home() {
  local home
  home="$(dirname "$(dirname "$(readlink -f /usr/bin/java)")")"
  if [[ -x /usr/lib/jvm/java-21-openjdk/bin/java ]]; then
    echo "/usr/lib/jvm/java-21-openjdk"
  elif [[ "${home}" == *java-21* ]]; then
    echo "${home}"
  else
    find /usr/lib/jvm -maxdepth 2 -path '*/bin/java' -type f 2>/dev/null | grep -m1 'java-21' | sed 's#/bin/java##' || true
  fi
}

assert_java21() {
  local output
  output="$(java -version 2>&1 || true)"
  echo "${output}"
  grep -Eq 'version "21\.|openjdk version "21\.' <<< "${output}" || die "Default java is not Java 21."
}
