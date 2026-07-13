#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

ENV_FILE="${1:-./config.env}"
ARCHIVE="${2:-${ROOT_DIR}/artifacts/toy-jitsi-meet.tar.bz2}"
TARGET_ROOT="${JITSI_MEET_ROOT:-/opt/jitsi-native/usr/share/jitsi-meet}"
BACKUP_ROOT="${JITSI_BACKUP_ROOT:-/opt/jitsi-native/backups}"

need_root
load_env "${ENV_FILE}"
require_fedora
refuse_container

NGINX_CONF="${NGINX_CONF:-/etc/nginx/conf.d/${JITSI_DOMAIN}.conf}"

[[ -f "${ARCHIVE}" ]] || die "TOY client archive not found: ${ARCHIVE}"
[[ -f "${NGINX_CONF}" ]] || die "Nginx site config not found: ${NGINX_CONF}"
[[ "${TARGET_ROOT}" == /* ]] || die "JITSI_MEET_ROOT must be an absolute path."
[[ "${TARGET_ROOT}" != "/" ]] || die "Refusing to use / as JITSI_MEET_ROOT."

work_dir="$(mktemp -d)"
staging_root="${TARGET_ROOT}.new.$$"
stamp="$(date +%Y%m%d%H%M%S)"
backup_path="${BACKUP_ROOT}/jitsi-meet-${stamp}"
failed_path="${BACKUP_ROOT}/jitsi-meet-failed-${stamp}"
nginx_backup="${work_dir}/nginx-site.conf"
nginx_changed=false

cleanup() {
  rm -rf -- "${work_dir}" "${staging_root}"
}
trap cleanup EXIT

tar -xjf "${ARCHIVE}" -C "${work_dir}"
source_root="${work_dir}/jitsi-meet"

for required in \
  index.html \
  config.js \
  interface_config.js \
  runtime-config-loader.js \
  runtime-config.local.js \
  libs/app.bundle.min.js \
  libs/lib-jitsi-meet.min.js \
  css/all.css; do
  [[ -f "${source_root}/${required}" ]] || die "Archive is missing ${required}."
done

grep -q "wss://${JITSI_DOMAIN}/xmpp-websocket" "${source_root}/runtime-config.local.js" \
  || die "The TOY archive does not target ${JITSI_DOMAIN}."

install -d -m 0755 "$(dirname "${TARGET_ROOT}")" "${BACKUP_ROOT}"
[[ ! -e "${backup_path}" ]] || die "Backup path already exists: ${backup_path}"
cp -a "${source_root}" "${staging_root}"
chown -R root:root "${staging_root}"
find "${staging_root}" -type d -exec chmod 0755 {} +
find "${staging_root}" -type f -exec chmod 0644 {} +

cp -a "${NGINX_CONF}" "${nginx_backup}"
if ! grep -Eq '^[[:space:]]*ssi[[:space:]]+on;' "${NGINX_CONF}"; then
  sed -i '/^[[:space:]]*index[[:space:]]\+index\.html;/a\    ssi on;' "${NGINX_CONF}"
fi

sed -i \
  -e "s#alias /etc/jitsi/meet/${JITSI_DOMAIN}-config.js;#alias ${TARGET_ROOT}/config.js;#" \
  -e "s#alias /etc/jitsi/meet/${JITSI_DOMAIN}-interface_config.js;#alias ${TARGET_ROOT}/interface_config.js;#" \
  "${NGINX_CONF}"

grep -Eq '^[[:space:]]*ssi[[:space:]]+on;' "${NGINX_CONF}" \
  || die "Could not enable SSI in ${NGINX_CONF}."
for asset in config.js interface_config.js; do
  grep -Fq "alias ${TARGET_ROOT}/${asset};" "${NGINX_CONF}" \
    || die "Could not route ${asset} to the TOY client."
done
nginx_changed=true

if [[ -e "${TARGET_ROOT}" ]]; then
  mv "${TARGET_ROOT}" "${backup_path}"
fi

if ! mv "${staging_root}" "${TARGET_ROOT}"; then
  [[ ! -e "${backup_path}" ]] || mv "${backup_path}" "${TARGET_ROOT}"
  cp -a "${nginx_backup}" "${NGINX_CONF}"
  die "Could not activate the TOY client."
fi

restorecon -RF "${TARGET_ROOT}" 2>/dev/null || true

if ! nginx -t; then
  mv "${TARGET_ROOT}" "${failed_path}"
  [[ ! -e "${backup_path}" ]] || mv "${backup_path}" "${TARGET_ROOT}"
  [[ "${nginx_changed}" != "true" ]] || cp -a "${nginx_backup}" "${NGINX_CONF}"
  die "Nginx validation failed; the previous client was restored."
fi

systemctl reload nginx

index_body="$(curl -kfsS --resolve "${JITSI_DOMAIN}:443:127.0.0.1" "https://${JITSI_DOMAIN}/")" \
  || die "Nginx reloaded, but the TOY client is not reachable."
runtime_body="$(curl -kfsS --resolve "${JITSI_DOMAIN}:443:127.0.0.1" \
  "https://${JITSI_DOMAIN}/runtime-config.local.js")" \
  || die "The Fedora runtime config is not reachable."

grep -q 'runtime-config-loader.js' <<< "${index_body}" \
  || die "The served index is not the TOY client."
grep -q "wss://${JITSI_DOMAIN}/xmpp-websocket" <<< "${runtime_body}" \
  || die "The served runtime config has the wrong XMPP endpoint."

echo "TOY client deployed to ${TARGET_ROOT}"
echo "Server: https://${JITSI_DOMAIN}/"
[[ ! -e "${backup_path}" ]] || echo "Backup: ${backup_path}"
