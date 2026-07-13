#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

need_root

section() {
  echo
  echo "### $*"
}

section "OS"
cat /etc/os-release || true

section "Kernel"
uname -a || true

section "Virtualization/container"
systemd-detect-virt || true
if command -v systemd-detect-virt >/dev/null 2>&1 && systemd-detect-virt -c --quiet; then
  echo "CONTAINER_DETECTED=yes"
else
  echo "CONTAINER_DETECTED=no"
fi

section "SELinux"
getenforce 2>/dev/null || echo "SELinux tools not installed"

section "firewalld"
systemctl is-active firewalld 2>/dev/null || true
firewall-cmd --state 2>/dev/null || true
firewall-cmd --list-all 2>/dev/null || true

section "Hostname and DNS"
hostnamectl || true
hostname -f 2>/dev/null || true
getent hosts "$(hostname -f 2>/dev/null || hostname)" || true

section "IP addresses"
ip -br addr || true
echo "Default route:"
ip route show default || true
echo "Public IP probe:"
curl -fsS --max-time 3 https://ifconfig.me 2>/dev/null || true
echo

section "Open listening ports"
ss -tulpen || true

section "Java"
command -v java || true
java -version 2>&1 || true
find /usr/lib/jvm -maxdepth 2 -path '*/bin/java' -type f -print 2>/dev/null || true

section "Existing relevant services"
for svc in nginx httpd prosody grafana-server prometheus node-exporter jicofo jitsi-videobridge jitsi-videobridge2; do
  printf '%-24s ' "${svc}"
  systemctl is-active "${svc}" 2>/dev/null || true
done

section "Likely production processes"
ps -eo pid,user,comm,args --sort=comm | grep -E 'nginx|httpd|apache|prosody|java|jicofo|jitsi|grafana|prometheus' | grep -v grep || true

section "Important paths"
for p in /etc/jitsi /usr/share/jitsi-meet /var/log/jitsi /etc/nginx/conf.d /etc/prosody/conf.d /etc/prometheus /etc/grafana; do
  if [[ -e "${p}" ]]; then
    ls -ld "${p}"
  else
    echo "missing ${p}"
  fi
done

echo
echo "Discovery complete. Review this output before running scripts/10-install.sh."
