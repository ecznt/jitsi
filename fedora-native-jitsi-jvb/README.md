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
- `scripts/20-stop-services.sh` - stop the Jitsi stack in a safe order.
- `scripts/30-start-services.sh` - start the Jitsi stack in the required order.
- `scripts/40-repair-disconnect.sh` - clean ordered restart plus verification for browser disconnects.
- `scripts/50-build-toy-client.sh` - build TOY in an isolated temporary copy with the Fedora runtime overlay.
- `scripts/60-deploy-toy-client.sh` - back up and deploy the TOY web client without restarting Jitsi services.
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

For manual stop/start operations, use the ordered service scripts:

```bash
sudo bash scripts/20-stop-services.sh
sudo bash scripts/30-start-services.sh
sudo bash scripts/90-verify.sh ./config.env
```

## Deploying the TOY web client

The browser client does not select a JVB directly. It connects to this stack's
Prosody and Jicofo endpoints, and Jicofo assigns the local JVB. This repository
injects a Fedora runtime overlay while building an isolated temporary copy of
`aburakt/toy-toplanti`. The TOY source repository and working tree are never
modified. The overlay changes only `hosts.domain`, `hosts.muc`, `hosts.focus`,
`bosh`, and `websocket`; every other TOY setting remains as defined by the TOY
application. The validated TOY revision already has P2P disabled, so
two-participant calls use the local JVB without an additional override.

On the Fedora machine, after this Jitsi stack is healthy, run these commands
from `fedora-native-jitsi-jvb` as a normal user:

```bash
bash scripts/50-build-toy-client.sh ./config.env
sudo bash scripts/60-deploy-toy-client.sh ./config.env
sudo bash scripts/90-verify.sh ./config.env
```

The build script clones `toy-toplanti` into a temporary directory. To consume an
existing local checkout without changing it, pass its path as the second
argument:

```bash
bash scripts/50-build-toy-client.sh ./config.env ~/Desktop/Projects/toy-toplanti
```

The default remote build is pinned to the TOY commit validated by this
integration. Set `TOY_CLIENT_REF` to another branch, tag, or commit when an
intentional client update is required.

That pinned revision declares `@jitsi/excalidraw` as `^0.0.19`, but the package
is not published in the public npm registry or recorded in its lock file. In
the temporary build copy only, the build script resolves it to the official
Jitsi `v0.0.19` GitHub release tarball and regenerates the temporary lock data
before `npm ci`. Set `TOY_EXCALIDRAW_PACKAGE_URL` to override that artifact URL
when required.

The deploy script takes a timestamped backup, enables Nginx SSI, points the web
config aliases at the deployed TOY client, validates Nginx, and reloads only
Nginx. Rerun build/deploy after `scripts/10-install.sh`, because the native
installer restores the official Jitsi Meet web artifact.

Do not restart `prosody`, `jicofo`, and `jitsi-videobridge` together in one
command during this lab. Jicofo must come up before JVB so it owns the internal
brewery room.

If the browser still shows `You have been disconnected`, run:

```bash
sudo bash scripts/40-repair-disconnect.sh ./config.env
```

During an ordered stop, older unit files can show Java exits as
`status=143` / `Failed with result 'exit-code'`. That is a normal SIGTERM stop,
not a Jitsi runtime failure. Current unit templates mark `143` as a successful
service stop.

If artifact download fails with a Jitsi repository index error, update this
repository and rerun `scripts/10-install.sh`. The installer supports the current
Jitsi `Packages.xz`, legacy `Packages.gz`, and plain `Packages` index formats.
It also consumes the full package index before selecting a package, avoiding
`curl: (23) Failure writing output to destination` from an early-closed pipe.
During artifact download the installer logs each resolved package URL and checks
it with a HEAD request before downloading, so a repository-side 404 reports the
exact package and URL.
Package index entries such as `stable/package.deb` are resolved from the
repository host root, avoiding duplicated paths like `stable/stable/package.deb`.

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

## Troubleshooting

If Jicofo or JVB repeatedly restarts with messages like:

```text
/usr/local/sbin/jitsi-native-jicofo: line 3: /etc/jitsi/jicofo/jicofo.env: Permission denied
/usr/local/sbin/jitsi-native-jvb: line 3: /etc/jitsi/videobridge/jvb.env: Permission denied
```

update the repository and rerun the installer. The installer keeps `/etc/jitsi`
traversable for service users while keeping secret env/config files group
readable only by the `jitsi` service group. To stop the restart loop before
rerunning:

```bash
sudo systemctl stop jicofo jitsi-videobridge
sudo bash scripts/10-install.sh ./config.env
```

If Java fails before the service starts with GC log permission errors, rerun the
installer. It resets `/var/log/jitsi` ownership to `root:jitsi`, makes the
directory group-writable, and makes existing log files writable by the service
group:

```text
Error opening log file '/var/log/jitsi/jvb-gc.log': Permission denied
Invalid -Xlog option ...
```

If a service exits with `no main manifest attribute`, update and rerun the
installer. Jicofo and JVB artifacts are not launched with `java -jar`; the
installer now discovers the package launcher scripts and falls back to an
explicit classpath/main-class launch only when no launcher exists.

If JVB fails with:

```text
Initial heap size set to a larger value than the maximum heap size
```

update and rerun the installer. The extracted Debian launcher may add its own
lower `-Xmx` value; the Fedora wrapper starts JVB directly with an explicit
classpath and controlled Java 21 heap flags to avoid that conflict. As a quick
temporary workaround on a small VMware lab VM, set `JVB_HEAP=2g` in `config.env`
and rerun the installer.

If `Jitsi Meet web opens` fails only because `meet.example.org` does not
resolve, set `JITSI_DOMAIN` to a real DNS name or add the test name to client
`hosts` files. The verifier uses a local `--resolve` check for Nginx, but real
browsers still need DNS or hosts resolution.

If the browser shows a black page, check that Jitsi Meet JavaScript config
assets are served as JavaScript and not as fallback HTML:

```bash
for f in config.js interface_config.js logging_config.js; do
  curl -k --resolve meet.example.org:443:127.0.0.1 https://meet.example.org/$f | head
done
```

The installer provisions all three files under `/etc/jitsi/meet/` and aliases
them explicitly in Nginx.

If the browser console shows `Uncaught ReferenceError: interfaceConfig is not
defined`, rerun the installer after updating. The installer patches
`index.html` so `interface_config.js` and `logging_config.js` load before the
Jitsi Meet app bundle.
It also embeds `interfaceConfig` and `loggingConfig` directly in `config.js`,
which is the most reliable compatibility path for extracted Jitsi Meet web
artifacts with differing `index.html` script orders.
The installer also inserts an inline `window.interfaceConfig` shim immediately
before the real `libs/app.bundle...` script tag and removes older injected shim
blocks before reapplying it, so reruns are idempotent.

If the console shows `Uncaught SyntaxError: expected expression, got '<'`, the
script tag was inserted inside a JavaScript block. Update and rerun the
installer; it removes previous injected config script tags and reinserts them
only before `</head>`.

If joining a room shows `You have been disconnected`, verify the browser XMPP
paths first:

```bash
curl -k -i --resolve meet.example.org:443:127.0.0.1 https://meet.example.org/http-bind
curl -k -i --http1.1 --resolve meet.example.org:443:127.0.0.1 \
  -H 'Connection: Upgrade' \
  -H 'Upgrade: websocket' \
  -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
  -H 'Sec-WebSocket-Version: 13' \
  https://meet.example.org/xmpp-websocket
```

The web config uses XMPP WebSocket for browser signaling and keeps BOSH as a
fallback. Colibri WebSocket for JVB media remains enabled separately. The
verifier accepts Prosody's small BOSH status page for GET requests and validates
an actual XML BOSH session request separately with POST.

If the browser connects to XMPP but the conference request to
`focus.<JITSI_DOMAIN>` returns `service-unavailable`, the Prosody client proxy
does not see Jicofo's authenticated session. Update the repository and run
`scripts/40-repair-disconnect.sh`; it provisions the required roster
subscription before performing the ordered restart.

If the journal shows `Only owners can configure rooms`, `Failed to create room`,
or `forbidden - auth`, the internal Prosody MUC room was created with the wrong
owner during startup. Update to the latest `develop` branch and rerun the
installer; it restarts Prosody first, then Jicofo, then starts JVB after Jicofo
has had time to own the brewery room.

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
