# Fedora native Jitsi Videobridge first-phase lab

This package prepares a non-container Jitsi Meet stack on Fedora for Jitsi
Videobridge performance/debug work. It is intentionally scoped to:

- Prosody
- Jicofo
- Jitsi Videobridge
- Jitsi Meet web
- Nginx
- Prometheus
- Grafana

It deliberately excludes Jibri, Jigasi, coturn/TURN, Etherpad, recording,
livestreaming, LDAP/JWT/auth integration, multi-JVB, load testing, and virtual
thread changes.

## Important constraints

- Run on a Fedora host, not inside Docker, Podman, or another container.
- Java 21 is installed and selected as the default runtime.
- Jicofo and JVB are launched with Java 21 from systemd.
- Java 17 fallback is not automatic. If Java 21 compatibility fails, the
  verification script reports the failure.
- JVB starts with G1GC, equal Xms/Xmx, and GC logs under `/var/log/jitsi/`.
- The scripts use official Jitsi Debian repository artifacts because Jitsi's
  official easy-install path is Debian/Ubuntu package based. Fedora does not
  have the same official native package path. The artifacts are extracted and
  run with Fedora-native systemd units.

Primary upstream references checked while preparing this package:

- Jitsi self-hosting guide: https://jitsi.github.io/handbook/docs/devops-guide/devops-guide-quickstart/
- JVB reference configuration: https://raw.githubusercontent.com/jitsi/jitsi-videobridge/master/jvb/src/main/resources/reference.conf
- Jicofo reference configuration: https://raw.githubusercontent.com/jitsi/jicofo/master/jicofo-selector/src/main/resources/reference.conf

## Files

- `config.env.example` - copy to `config.env` and edit for the host.
- `scripts/00-discover.sh` - read-only discovery report.
- `scripts/10-install.sh` - install and configure the first-phase stack.
- `scripts/90-verify.sh` - service, Java 21, metrics, and endpoint checks.
- `templates/` - systemd, Prosody, JVB, Jicofo, Nginx, Prometheus, and Grafana templates.

## Usage on the Fedora server

Copy this directory to the Fedora host, then:

```bash
cd fedora-native-jitsi-jvb
cp config.env.example config.env
vi config.env
sudo bash scripts/00-discover.sh
sudo bash scripts/10-install.sh ./config.env
sudo bash scripts/90-verify.sh ./config.env
```

The discovery step does not change the system. Read it before running the
installer, especially the active service and open port sections.

If artifact download fails with a Jitsi repository index error, update this
repository and rerun `scripts/10-install.sh`. The installer supports the current
Jitsi `Packages.xz`, legacy `Packages.gz`, and plain `Packages` index formats.
It also consumes the full package index before selecting a package, avoiding
`curl: (23) Failure writing output to destination` from an early-closed pipe.

## TLS choice

Set `TLS_MODE=letsencrypt` only when the host has a real DNS name pointing at
this server and ports 80/443 are reachable. Otherwise use `TLS_MODE=selfsigned`
for the first lab pass and accept the browser warning on test clients.

## Expected validation

After installation:

- `java -version` must show Java 21.
- `systemctl status prosody jicofo jitsi-videobridge nginx prometheus grafana-server`
  should be healthy.
- `curl http://127.0.0.1:8080/metrics` should return JVB metrics.
- Prometheus should show the `jvb` target as UP.
- Grafana should have a Prometheus datasource and a first-phase JVB dashboard.
- Two browsers should be able to join the same room at
  `https://<JITSI_DOMAIN>/<room>` and establish audio/video.

## Manual browser test

Open the same room from two different browsers or two machines:

```text
https://<JITSI_DOMAIN>/jvb-smoke
```

Use `chrome://webrtc-internals` or `about:webrtc` during debugging, and check:

```bash
journalctl -u jitsi-videobridge -u jicofo -u prosody --since -15m
```

## Phase 2 candidates

- jitsi-meet-torture or synthetic browser clients
- UDP/NIC/kernel tuning
- JVB `stress_level` tracking under load
- Java 21 G1GC/ZGC comparison
- multi-JVB topology
