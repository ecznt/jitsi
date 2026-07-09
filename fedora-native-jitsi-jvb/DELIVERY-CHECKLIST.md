# Delivery checklist

Fill this after running the installer and verifier on the Fedora host.

## Install summary

- Fedora version:
- Kernel:
- SELinux mode:
- firewalld state:
- Hostname:
- Domain:
- Private IP:
- Public IP:
- TLS mode: selfsigned / letsencrypt

## Versions

- Java:
  ```text
  paste java -version output
  ```
- Jitsi artifacts:
  ```text
  cat /var/cache/jitsi-native/artifact-versions.txt
  ```

## Java 21 process verification

- Jicofo Java 21 verification:
  ```text
  paste scripts/90-verify.sh Jicofo process section
  ```
- JVB Java 21 verification:
  ```text
  paste scripts/90-verify.sh JVB process section
  ```

## Config files changed

- `/etc/prosody/conf.d/<domain>.cfg.lua`
- `/etc/jitsi/jicofo/jicofo.conf`
- `/etc/jitsi/videobridge/jvb.conf`
- `/etc/jitsi/meet/<domain>-config.js`
- `/etc/nginx/conf.d/<domain>.conf`
- `/etc/prometheus/prometheus.yml`
- `/etc/grafana/provisioning/datasources/prometheus.yml`
- `/etc/grafana/provisioning/dashboards/jvb.yml`
- `/var/lib/grafana/dashboards/jvb-first-phase.json`

## Systemd services

- `prosody`
- `jicofo`
- `jitsi-videobridge`
- `nginx`
- `prometheus`
- `grafana-server`

## Opened ports

- `80/tcp`
- `443/tcp`
- `10000/udp`
- `5222/tcp` only if `EXPOSE_XMPP_PORTS=true`
- `5280/tcp` only if `EXPOSE_XMPP_PORTS=true`

## Observability

- JVB metrics endpoint: `http://127.0.0.1:8080/metrics`
- Prometheus URL: `http://127.0.0.1:9090`
- Prometheus JVB target status:
- Grafana URL: `http://<server-ip>:3000`
- Grafana user:
- Grafana password source: `config.env`
- Dashboard: `Jitsi / JVB First Phase`

## Browser/media smoke test

- Room URL: `https://<domain>/jvb-smoke`
- Client 1 browser/machine:
- Client 2 browser/machine:
- Audio established: yes/no
- Video established: yes/no
- JVB ICE/DTLS/media errors in logs: yes/no

## Errors and fixes

- Error:
- Component:
- Fix:
- Remaining risk:

## Java 21 compatibility notes

- Jicofo:
- JVB:
- Any Java 17 fallback used: no

## Phase 2 suggestions

- jitsi-meet-torture or synthetic browser clients
- UDP/NIC/kernel tuning
- JVB `stress_level` tracking under controlled load
- Java 21 G1GC/ZGC comparison
- multi-JVB architecture

