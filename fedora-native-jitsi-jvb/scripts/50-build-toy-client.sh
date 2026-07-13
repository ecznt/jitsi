#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

ENV_FILE="${1:-./config.env}"
TOY_SOURCE="${2:-${TOY_CLIENT_SOURCE:-https://github.com/aburakt/toy-toplanti.git}}"
TOY_REF="${TOY_CLIENT_REF:-70c8634ee8af5a59c3d73b79988d11c31ef7d28d}"
OUTPUT_DIR="${TOY_CLIENT_OUTPUT_DIR:-${ROOT_DIR}/artifacts}"
OUTPUT_ARCHIVE="${OUTPUT_DIR}/toy-jitsi-meet.tar.bz2"

load_env "${ENV_FILE}"
require_fedora
refuse_container

[[ "${EUID}" -ne 0 ]] || die "Run the TOY client build as a normal user, not with sudo."

for command in git node npm make envsubst tar; do
  command -v "${command}" >/dev/null 2>&1 || die "Missing build command: ${command}"
done

node_major="$(node -p 'process.versions.node.split(".")[0]')"
[[ "${node_major}" =~ ^[0-9]+$ ]] || die "Could not determine the Node.js version."
(( node_major >= 22 )) || die "Node.js 22 or newer is required. Found: $(node --version)"

work_dir="$(mktemp -d)"
build_root="${work_dir}/toy-toplanti"
cleanup() {
  rm -rf -- "${work_dir}"
}
trap cleanup EXIT

if [[ -d "${TOY_SOURCE}" ]]; then
  log "Copying TOY client source to an isolated build directory"
  install -d -m 0755 "${build_root}"
  cp -a "${TOY_SOURCE}/." "${build_root}/"
else
  log "Cloning TOY client ref ${TOY_REF} into an isolated build directory"
  git clone --filter=blob:none --no-checkout "${TOY_SOURCE}" "${build_root}"
  git -C "${build_root}" fetch --depth 1 origin "${TOY_REF}"
  git -C "${build_root}" checkout --detach FETCH_HEAD
fi

for required in package.json package-lock.json Makefile index.html runtime-config-loader.js; do
  [[ -f "${build_root}/${required}" ]] || die "TOY source is missing ${required}."
done

log "Rendering Fedora runtime configuration for ${JITSI_DOMAIN}"
JITSI_DOMAIN="${JITSI_DOMAIN}" envsubst '${JITSI_DOMAIN}' \
  < "${ROOT_DIR}/templates/toy-runtime-config.js.tpl" \
  > "${build_root}/runtime-config.local.js"

grep -q "wss://${JITSI_DOMAIN}/xmpp-websocket" "${build_root}/runtime-config.local.js" \
  || die "Rendered runtime config has the wrong XMPP WebSocket endpoint."

log "Installing locked TOY client dependencies"
(
  cd "${build_root}"
  npm ci
)

log "Building the TOY client source package"
(
  cd "${build_root}"
  make source-package
)

[[ -f "${build_root}/jitsi-meet.tar.bz2" ]] || die "TOY build did not produce jitsi-meet.tar.bz2."
install -d -m 0755 "${OUTPUT_DIR}"
install -m 0644 "${build_root}/jitsi-meet.tar.bz2" "${OUTPUT_ARCHIVE}"

echo "TOY client archive: ${OUTPUT_ARCHIVE}"
