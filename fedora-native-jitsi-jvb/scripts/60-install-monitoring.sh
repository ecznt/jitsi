#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

ENV_FILE="${1:-./config.env}"
MODE="${2:-restart}"
need_root
load_env "${ENV_FILE}"

NODE_EXPORTER_VERSION="${NODE_EXPORTER_VERSION:-1.11.1}"
JMX_EXPORTER_VERSION="${JMX_EXPORTER_VERSION:-1.6.0}"
NODE_EXPORTER_AMD64_SHA256="9f5ea48e5bc7b656f8a91a32e7d7deb89f70f73dabd0d974418aca15f37d6810"
NODE_EXPORTER_ARM64_SHA256="ba1886efbd76cb96b0087c695ea8d1b9cb6e8aa946c996d744e9ee16c8e3591a"
JMX_EXPORTER_SHA256="a95983fd96e865d2bcdf911cc500e7c82808c27ab9fd226bf96732b6c3d8c46e"
DOWNLOAD_DIR=/var/cache/jitsi-native/monitoring
JMX_DIR=/opt/jmx-exporter
JMX_JAR="${JMX_DIR}/jmx_prometheus_javaagent-${JMX_EXPORTER_VERSION}.jar"
JMX_CONFIG=/etc/jitsi/videobridge/jmx-exporter.yml
JMX_AGENT_OPT="-javaagent:${JMX_JAR}=127.0.0.1:9404:${JMX_CONFIG}"

download_verified() {
  local url="$1"
  local destination="$2"
  local expected_sha="$3"
  local actual_sha
  if [[ -f "${destination}" ]]; then
    actual_sha="$(sha256sum "${destination}" | awk '{print $1}')"
    if [[ "${actual_sha}" == "${expected_sha}" ]]; then
      log "Using verified cached artifact: ${destination}"
      return 0
    fi
  fi
  curl -fL --retry 3 --retry-delay 2 "${url}" -o "${destination}"
  actual_sha="$(sha256sum "${destination}" | awk '{print $1}')"
  [[ "${actual_sha}" == "${expected_sha}" ]] \
    || die "Checksum mismatch for ${url}: expected ${expected_sha}, got ${actual_sha}"
}

install_node_exporter() {
  local machine release_arch checksum archive extract_dir
  machine="$(uname -m)"
  case "${machine}" in
    x86_64)
      release_arch=amd64
      checksum="${NODE_EXPORTER_AMD64_SHA256}"
      ;;
    aarch64)
      release_arch=arm64
      checksum="${NODE_EXPORTER_ARM64_SHA256}"
      ;;
    *)
      die "Unsupported architecture for Node Exporter: ${machine}"
      ;;
  esac

  archive="${DOWNLOAD_DIR}/node_exporter-${NODE_EXPORTER_VERSION}.linux-${release_arch}.tar.gz"
  extract_dir="${DOWNLOAD_DIR}/node_exporter-${NODE_EXPORTER_VERSION}.linux-${release_arch}"
  download_verified \
    "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/$(basename "${archive}")" \
    "${archive}" \
    "${checksum}"
  rm -rf "${extract_dir}"
  tar -C "${DOWNLOAD_DIR}" -xzf "${archive}"
  install -m 0755 "${extract_dir}/node_exporter" /usr/local/bin/node_exporter
  restorecon /usr/local/bin/node_exporter 2>/dev/null || true
}

install_jmx_exporter() {
  local downloaded_jar
  downloaded_jar="${DOWNLOAD_DIR}/$(basename "${JMX_JAR}")"
  install -d -m 0755 "${JMX_DIR}"
  download_verified \
    "https://github.com/prometheus/jmx_exporter/releases/download/v${JMX_EXPORTER_VERSION}/$(basename "${JMX_JAR}")" \
    "${downloaded_jar}" \
    "${JMX_EXPORTER_SHA256}"
  install -m 0644 "${downloaded_jar}" "${JMX_JAR}"
  install -m 0644 "${ROOT_DIR}/templates/jmx-exporter.yml" "${JMX_CONFIG}"
}

configure_jvb_agent() {
  local env_file=/etc/jitsi/videobridge/jvb.env
  local wrapper=/usr/local/sbin/jitsi-native-jvb
  local tmp
  [[ -f "${env_file}" ]] || die "Missing JVB environment file: ${env_file}"
  [[ -f "${wrapper}" ]] || die "Missing JVB wrapper: ${wrapper}"

  tmp="$(mktemp)"
  grep -v '^JVB_JMX_AGENT_OPTS=' "${env_file}" > "${tmp}"
  printf "JVB_JMX_AGENT_OPTS='%s'\n" "${JMX_AGENT_OPT}" >> "${tmp}"
  cat "${tmp}" > "${env_file}"
  rm -f "${tmp}"
  chown root:jitsi "${env_file}"
  chmod 0640 "${env_file}"

  if ! grep -q 'JVB_JMX_AGENT_OPTS' "${wrapper}"; then
    sed -i \
      's#${JVB_RUNTIME_OPTS} -Dconfig.file#${JVB_RUNTIME_OPTS} ${JVB_JMX_AGENT_OPTS:-} -Dconfig.file#' \
      "${wrapper}"
  fi
  grep -q 'JVB_JMX_AGENT_OPTS' "${wrapper}" \
    || die "Could not enable the JMX javaagent in ${wrapper}"
}

install_monitoring_configs() {
  export JITSI_DOMAIN
  install -d -m 0755 \
    /etc/prometheus \
    /etc/grafana/provisioning/alerting \
    /etc/grafana/provisioning/datasources \
    /etc/grafana/provisioning/dashboards \
    /var/lib/grafana/dashboards
  render_template "${ROOT_DIR}/templates/prometheus-jitsi.yml.tpl" /etc/prometheus/prometheus.yml
  render_template "${ROOT_DIR}/templates/prometheus-jvb-alerts.yml.tpl" /etc/prometheus/jvb-alerts.yml
  install -m 0644 "${ROOT_DIR}/templates/grafana-datasource-prometheus.yml" /etc/grafana/provisioning/datasources/prometheus.yml
  install -m 0644 "${ROOT_DIR}/templates/grafana-dashboard-provider.yml" /etc/grafana/provisioning/dashboards/jvb.yml
  rm -f /var/lib/grafana/dashboards/jvb-first-phase.json
  install -m 0644 "${ROOT_DIR}/templates/grafana-dashboard-jvb.json" /var/lib/grafana/dashboards/jvb-capacity.json
  chown -R grafana:grafana /var/lib/grafana/dashboards

  command -v promtool >/dev/null 2>&1 || die "promtool is required to validate Prometheus configuration."
  promtool check rules /etc/prometheus/jvb-alerts.yml
  promtool check config /etc/prometheus/prometheus.yml
}

install_node_exporter_unit() {
  install -m 0644 "${ROOT_DIR}/templates/node-exporter.service" /etc/systemd/system/node-exporter.service
  systemctl daemon-reload
}

configure_monitoring_selinux() {
  if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce)" != "Disabled" ]]; then
    setsebool -P grafana_can_tcp_connect_prometheus_port on
  fi
}

wait_http() {
  local url="$1"
  local timeout="${2:-30}"
  local deadline=$((SECONDS + timeout))
  while (( SECONDS < deadline )); do
    if curl -fsS "${url}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

restart_monitoring() {
  log "Restarting JVB and monitoring services"
  systemctl enable node-exporter prometheus grafana-server >/dev/null 2>&1 || true
  systemctl restart node-exporter
  systemctl restart jitsi-videobridge
  wait_http http://127.0.0.1:9100/metrics 30 || die "Node Exporter did not become ready."
  wait_http http://127.0.0.1:9404/metrics 45 || die "JVB JMX Exporter did not become ready."
  wait_http http://127.0.0.1:8080/metrics 45 || die "JVB metrics endpoint did not become ready."
  systemctl restart prometheus
  systemctl restart grafana-server
  wait_http http://127.0.0.1:9090/-/ready 30 || die "Prometheus did not become ready."
  wait_http http://127.0.0.1:3000/api/health 30 || die "Grafana did not become ready."
}

log "Installing detailed JVB monitoring"
install -d -m 0755 "${DOWNLOAD_DIR}"
install_node_exporter
install_jmx_exporter
configure_jvb_agent
install_monitoring_configs
install_node_exporter_unit
configure_monitoring_selinux

if [[ "${MODE}" != "--no-restart" ]]; then
  restart_monitoring
fi

log "Detailed JVB monitoring is installed"
