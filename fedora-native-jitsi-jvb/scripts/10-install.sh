#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

ENV_FILE="${1:-./config.env}"
need_root
load_env "${ENV_FILE}"
require_fedora
refuse_container

export JITSI_DOMAIN TLS_MODE LE_EMAIL JVB_HEAP JICOFO_HEAP GRAFANA_ADMIN_USER GRAFANA_ADMIN_PASSWORD

NATIVE_ROOT=/opt/jitsi-native
DOWNLOAD_DIR=/var/cache/jitsi-native
TLS_DIR=/etc/jitsi/tls
REPORT=/var/log/jitsi/fedora-native-install-report.txt
export TLS_DIR

guard_existing_services() {
  if [[ "${ALLOW_EXISTING_SERVICES:-false}" == "true" ]]; then
    return
  fi

  local active=()
  for svc in nginx httpd prosody grafana-server prometheus jicofo jitsi-videobridge jitsi-videobridge2; do
    if systemctl is-active --quiet "${svc}" 2>/dev/null; then
      active+=("${svc}")
    fi
  done

  if ((${#active[@]})); then
    printf 'Active possibly conflicting services: %s\n' "${active[*]}" >&2
    die "Set ALLOW_EXISTING_SERVICES=true only after confirming this is not production traffic."
  fi
}

install_packages() {
  log "Installing Fedora packages"
  dnf install -y \
    java-21-openjdk-headless \
    prosody \
    nginx \
    prometheus \
    grafana \
    curl \
    tar \
    gzip \
    xz \
    zstd \
    binutils \
    openssl \
    gettext-envsubst \
    policycoreutils-python-utils \
    firewalld \
    certbot \
    python3-certbot-nginx
}

select_java21() {
  log "Selecting Java 21 as the default runtime"
  local jhome
  jhome="$(java21_home)"
  [[ -n "${jhome}" && -x "${jhome}/bin/java" ]] || die "Java 21 home not found after package install."
  alternatives --set java "${jhome}/bin/java" || true
  export JAVA_HOME="${jhome}"
  assert_java21
}

ensure_users() {
  log "Creating service users"
  getent group jitsi >/dev/null || groupadd --system jitsi
  id jicofo >/dev/null 2>&1 || useradd --system --home-dir /var/lib/jicofo --shell /sbin/nologin --gid jitsi jicofo
  id jvb >/dev/null 2>&1 || useradd --system --home-dir /var/lib/jitsi-videobridge --shell /sbin/nologin --gid jitsi jvb
  install -d -m 0775 -o root -g jitsi /var/log/jitsi
  install -d -m 0750 -o jicofo -g jitsi /var/lib/jicofo
  install -d -m 0750 -o jvb -g jitsi /var/lib/jitsi-videobridge
}

detect_addresses() {
  PRIVATE_IP="${PRIVATE_IP:-$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')}"
  PUBLIC_IP="${PUBLIC_IP:-$(curl -fsS --max-time 5 https://ifconfig.me 2>/dev/null || true)}"
  PUBLIC_IP="${PUBLIC_IP:-${PRIVATE_IP}}"
  export PRIVATE_IP PUBLIC_IP
  log "Using PRIVATE_IP=${PRIVATE_IP:-unset}, PUBLIC_IP=${PUBLIC_IP:-unset}"
}

ensure_secrets() {
  JICOFO_AUTH_PASSWORD="${JICOFO_AUTH_PASSWORD:-$(random_secret)}"
  JVB_AUTH_PASSWORD="${JVB_AUTH_PASSWORD:-$(random_secret)}"
  export JICOFO_AUTH_PASSWORD JVB_AUTH_PASSWORD

  install -d -m 0750 /etc/jitsi
  cat > /etc/jitsi/native.env <<EOF
JITSI_DOMAIN=${JITSI_DOMAIN}
PUBLIC_IP=${PUBLIC_IP}
PRIVATE_IP=${PRIVATE_IP}
JICOFO_AUTH_PASSWORD=${JICOFO_AUTH_PASSWORD}
JVB_AUTH_PASSWORD=${JVB_AUTH_PASSWORD}
EOF
  chmod 0640 /etc/jitsi/native.env
}

package_index() {
  local repo="${JITSI_REPO_URL%/}"
  if curl -fsSL "${repo}/Packages.xz" 2>/dev/null | xz -dc 2>/dev/null; then
    return
  fi
  if curl -fsSL "${repo}/Packages.gz" 2>/dev/null | gzip -dc 2>/dev/null; then
    return
  fi
  curl -fsSL "${repo}/Packages"
}

package_filename() {
  local pkg="$1"
  package_index \
    | awk -v pkg="${pkg}" '
      $1 == "Package:" { hit = ($2 == pkg) }
      hit && $1 == "Version:" { version = $2 }
      hit && $1 == "Filename:" { filename = $2 }
      END {
        if (filename != "") {
          print version "|" filename
        }
      }
    '
}

package_url() {
  local filename="$1"
  local repo="${JITSI_REPO_URL%/}"
  local origin
  origin="$(printf '%s' "${repo}" | sed -E 's#^(https?://[^/]+).*#\1#')"
  case "${filename}" in
    http://*|https://*)
      echo "${filename}"
      ;;
    ./*)
      echo "${repo}/${filename#./}"
      ;;
    /*)
      echo "${origin}${filename}"
      ;;
    *)
      if [[ "${filename}" == */* ]]; then
        echo "${origin}/${filename}"
      else
        echo "${repo}/${filename}"
      fi
      ;;
  esac
}

extract_deb() {
  local deb="$1"
  local work="$2"
  rm -rf "${work}"
  install -d -m 0755 "${work}"
  (cd "${work}" && ar x "${deb}")
  local data
  data="$(find "${work}" -maxdepth 1 -type f -name 'data.tar.*' | head -n1)"
  [[ -n "${data}" ]] || die "No data archive in ${deb}"
  tar -C "${NATIVE_ROOT}" -xf "${data}"
}

install_jitsi_artifacts() {
  log "Downloading and extracting official Jitsi artifacts"
  install -d -m 0755 "${NATIVE_ROOT}" "${DOWNLOAD_DIR}"
  local summary="${DOWNLOAD_DIR}/artifact-versions.txt"
  : > "${summary}"

  for pkg in ${JITSI_PACKAGES}; do
    local meta version filename url deb
    meta="$(package_filename "${pkg}")"
    [[ -n "${meta}" ]] || die "Could not resolve package ${pkg} from ${JITSI_REPO_URL}"
    version="${meta%%|*}"
    filename="${meta#*|}"
    url="$(package_url "${filename}")"
    deb="${DOWNLOAD_DIR}/$(basename "${filename}")"
    log "Resolved ${pkg} ${version} -> ${url}"
    curl -fsIL "${url}" >/dev/null || die "Resolved URL is not reachable for ${pkg}: ${url}"
    curl -fL "${url}" -o "${deb}"
    extract_deb "${deb}" "${DOWNLOAD_DIR}/extract-${pkg}"
    printf '%s %s %s\n' "${pkg}" "${version}" "${filename}" | tee -a "${summary}"
  done
}

locate_jars() {
  JICOFO_JAR="$(find "${NATIVE_ROOT}" -type f -name 'jicofo*.jar' | head -n1)"
  JVB_JAR="$(find "${NATIVE_ROOT}" -type f \( -name 'jitsi-videobridge*.jar' -o -name 'jvb*.jar' \) | head -n1)"
  [[ -n "${JICOFO_JAR}" ]] || die "Could not find jicofo jar under ${NATIVE_ROOT}"
  [[ -n "${JVB_JAR}" ]] || die "Could not find JVB jar under ${NATIVE_ROOT}"
  export JICOFO_JAR JVB_JAR
}

configure_tls() {
  install -d -m 0750 "${TLS_DIR}"
  if [[ "${TLS_MODE}" == "selfsigned" ]]; then
    log "Generating self-signed TLS certificate"
    openssl req -x509 -nodes -newkey rsa:4096 -days 365 \
      -keyout "${TLS_DIR}/${JITSI_DOMAIN}.key" \
      -out "${TLS_DIR}/${JITSI_DOMAIN}.crt" \
      -subj "/CN=${JITSI_DOMAIN}" \
      -addext "subjectAltName=DNS:${JITSI_DOMAIN}"
  elif [[ "${TLS_MODE}" == "letsencrypt" ]]; then
    log "Requesting Let's Encrypt certificate through certbot standalone"
    systemctl enable --now firewalld
    firewall-cmd --permanent --add-service=http
    firewall-cmd --permanent --add-service=https
    firewall-cmd --reload
    systemctl stop nginx 2>/dev/null || true
    certbot certonly --standalone -n --agree-tos -m "${LE_EMAIL}" -d "${JITSI_DOMAIN}"
    ln -sf "/etc/letsencrypt/live/${JITSI_DOMAIN}/fullchain.pem" "${TLS_DIR}/${JITSI_DOMAIN}.crt"
    ln -sf "/etc/letsencrypt/live/${JITSI_DOMAIN}/privkey.pem" "${TLS_DIR}/${JITSI_DOMAIN}.key"
  else
    die "TLS_MODE must be selfsigned or letsencrypt"
  fi
  chmod 0640 "${TLS_DIR}/${JITSI_DOMAIN}.key"
}

configure_prosody() {
  log "Configuring Prosody"
  install -d -m 0755 /etc/prosody/conf.d
  export PROSODY_PLUGIN_PATH="${NATIVE_ROOT}/usr/share/jitsi-meet/prosody-plugins"
  render_template "${ROOT_DIR}/templates/prosody-jitsi.cfg.lua.tpl" "/etc/prosody/conf.d/${JITSI_DOMAIN}.cfg.lua"
  prosodyctl register focus "auth.${JITSI_DOMAIN}" "${JICOFO_AUTH_PASSWORD}" || true
  prosodyctl register jvb "auth.${JITSI_DOMAIN}" "${JVB_AUTH_PASSWORD}" || true
}

write_wrappers() {
  log "Writing service wrappers"
  local jhome
  jhome="$(java21_home)"
  install -d -m 0755 /usr/local/sbin /etc/jitsi/jicofo /etc/jitsi/videobridge /var/log/jitsi

  cat > /etc/jitsi/jicofo/jicofo.env <<EOF
JAVA_HOME=${jhome}
JICOFO_JAR=${JICOFO_JAR}
JICOFO_JAVA_OPTS='-Xms${JICOFO_HEAP} -Xmx${JICOFO_HEAP} -XX:+UseG1GC -Xlog:gc*:file=/var/log/jitsi/jicofo-gc.log:time,uptime,level,tags:filecount=10,filesize=50M'
EOF

  cat > /etc/jitsi/videobridge/jvb.env <<EOF
JAVA_HOME=${jhome}
JVB_JAR=${JVB_JAR}
JVB_JAVA_OPTS='-Xms${JVB_HEAP} -Xmx${JVB_HEAP} -XX:+UseG1GC -Xlog:gc*:file=/var/log/jitsi/jvb-gc.log:time,uptime,level,tags:filecount=10,filesize=50M'
EOF

  cat > /usr/local/sbin/jitsi-native-jicofo <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /etc/jitsi/jicofo/jicofo.env
exec "${JAVA_HOME}/bin/java" ${JICOFO_JAVA_OPTS} -Dconfig.file=/etc/jitsi/jicofo/jicofo.conf -jar "${JICOFO_JAR}"
EOF

  cat > /usr/local/sbin/jitsi-native-jvb <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /etc/jitsi/videobridge/jvb.env
exec "${JAVA_HOME}/bin/java" ${JVB_JAVA_OPTS} -Dconfig.file=/etc/jitsi/videobridge/jvb.conf -jar "${JVB_JAR}"
EOF

  chmod 0755 /usr/local/sbin/jitsi-native-jicofo /usr/local/sbin/jitsi-native-jvb
  chown root:jitsi /etc/jitsi/jicofo/jicofo.env /etc/jitsi/videobridge/jvb.env
  chmod 0640 /etc/jitsi/jicofo/jicofo.env /etc/jitsi/videobridge/jvb.env
}

render_configs() {
  log "Rendering Jitsi, Nginx, Prometheus, and Grafana configuration"
  install -d -m 0755 /etc/jitsi/meet /etc/nginx/conf.d /etc/prometheus /etc/grafana/provisioning/datasources /etc/grafana/provisioning/dashboards /var/lib/grafana/dashboards
  export JITSI_MEET_ROOT="${NATIVE_ROOT}/usr/share/jitsi-meet"
  render_template "${ROOT_DIR}/templates/jicofo.conf.tpl" /etc/jitsi/jicofo/jicofo.conf
  render_template "${ROOT_DIR}/templates/jvb.conf.tpl" /etc/jitsi/videobridge/jvb.conf
  render_template "${ROOT_DIR}/templates/jitsi-meet-config.js.tpl" "/etc/jitsi/meet/${JITSI_DOMAIN}-config.js"
  backup_file "${JITSI_MEET_ROOT}/config.js"
  cp "/etc/jitsi/meet/${JITSI_DOMAIN}-config.js" "${JITSI_MEET_ROOT}/config.js"
  render_template "${ROOT_DIR}/templates/nginx-jitsi.conf.tpl" "/etc/nginx/conf.d/${JITSI_DOMAIN}.conf"
  render_template "${ROOT_DIR}/templates/prometheus-jitsi.yml.tpl" /etc/prometheus/prometheus.yml
  backup_file /etc/grafana/provisioning/datasources/prometheus.yml
  cp "${ROOT_DIR}/templates/grafana-datasource-prometheus.yml" /etc/grafana/provisioning/datasources/prometheus.yml
  backup_file /etc/grafana/provisioning/dashboards/jvb.yml
  cp "${ROOT_DIR}/templates/grafana-dashboard-provider.yml" /etc/grafana/provisioning/dashboards/jvb.yml
  backup_file /var/lib/grafana/dashboards/jvb-first-phase.json
  cp "${ROOT_DIR}/templates/grafana-dashboard-jvb.json" /var/lib/grafana/dashboards/jvb-first-phase.json
  chown -R grafana:grafana /var/lib/grafana/dashboards
  chown -R root:jitsi /etc/jitsi/jicofo /etc/jitsi/videobridge
  chmod 0640 /etc/jitsi/jicofo/jicofo.conf /etc/jitsi/videobridge/jvb.conf
}

configure_grafana_admin() {
  log "Configuring Grafana admin bootstrap credentials"
  if [[ -f /etc/grafana/grafana.ini ]]; then
    sed -i \
      -e "s/^;\\?admin_user = .*/admin_user = ${GRAFANA_ADMIN_USER}/" \
      -e "s/^;\\?admin_password = .*/admin_password = ${GRAFANA_ADMIN_PASSWORD}/" \
      /etc/grafana/grafana.ini
  fi
}

configure_selinux_firewall() {
  log "Configuring SELinux and firewalld without disabling SELinux"
  if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce)" != "Disabled" ]]; then
    setsebool -P httpd_can_network_connect 1 || true
    for port in 5280 8080 8888 9091; do
      semanage port -a -t http_port_t -p tcp "${port}" 2>/dev/null || semanage port -m -t http_port_t -p tcp "${port}" || true
    done
  fi

  systemctl enable --now firewalld
  firewall-cmd --permanent --add-service=http
  firewall-cmd --permanent --add-service=https
  firewall-cmd --permanent --add-port=10000/udp
  if [[ "${EXPOSE_XMPP_PORTS:-false}" == "true" ]]; then
    firewall-cmd --permanent --add-port=5222/tcp
    firewall-cmd --permanent --add-port=5280/tcp
  fi
  firewall-cmd --reload
}

install_systemd_units() {
  log "Installing systemd units"
  backup_file /etc/systemd/system/jicofo.service
  cp "${ROOT_DIR}/templates/jicofo.service" /etc/systemd/system/jicofo.service
  backup_file /etc/systemd/system/jitsi-videobridge.service
  cp "${ROOT_DIR}/templates/jitsi-videobridge.service" /etc/systemd/system/jitsi-videobridge.service
  systemctl daemon-reload
}

start_services() {
  log "Starting services"
  systemctl enable --now prosody
  systemctl restart prosody
  systemctl enable --now jicofo jitsi-videobridge nginx prometheus grafana-server
  systemctl restart jicofo jitsi-videobridge nginx prometheus grafana-server
}

write_report() {
  log "Writing install report to ${REPORT}"
  {
    echo "Installed on: $(date -Is)"
    echo "Domain: ${JITSI_DOMAIN}"
    echo "TLS_MODE: ${TLS_MODE}"
    echo "PRIVATE_IP: ${PRIVATE_IP}"
    echo "PUBLIC_IP: ${PUBLIC_IP}"
    echo
    echo "Java:"
    java -version 2>&1 || true
    echo
    echo "Artifacts:"
    cat "${DOWNLOAD_DIR}/artifact-versions.txt" 2>/dev/null || true
    echo
    echo "JAR paths:"
    echo "JICOFO_JAR=${JICOFO_JAR}"
    echo "JVB_JAR=${JVB_JAR}"
    echo
    echo "Ports opened:"
    firewall-cmd --list-all 2>/dev/null || true
    echo
    echo "Important config files:"
    echo "/etc/prosody/conf.d/${JITSI_DOMAIN}.cfg.lua"
    echo "/etc/jitsi/jicofo/jicofo.conf"
    echo "/etc/jitsi/videobridge/jvb.conf"
    echo "/etc/nginx/conf.d/${JITSI_DOMAIN}.conf"
    echo "/etc/prometheus/prometheus.yml"
    echo "/var/lib/grafana/dashboards/jvb-first-phase.json"
  } > "${REPORT}"
}

guard_existing_services
install_packages
select_java21
ensure_users
detect_addresses
ensure_secrets
install_jitsi_artifacts
locate_jars
configure_tls
configure_prosody
write_wrappers
render_configs
configure_grafana_admin
configure_selinux_firewall
install_systemd_units
start_services
write_report

log "Install complete. Run: sudo bash scripts/90-verify.sh ${ENV_FILE}"
