# Debian 13 Production JVB Deployment Guide

Bu dokuman yalnizca production Debian makinesindeki Jitsi Videobridge (JVB)
sorumlulugunu kapsar. Mevcut Jitsi client'in build, deploy, Nginx veya uygulama
ayarlari bu kapsamin disindadir.

Kesin deployment profili:

| Alan | Karar |
| --- | --- |
| Isletim sistemi | Debian 13 (Trixie) |
| Servis | Yalnizca `jitsi-videobridge2` |
| Java | OpenJDK 21 headless JDK |
| Collector | Generational ZGC |
| Heap | `Xms=8g`, `SoftMaxHeapSize=32g`, `Xmx=393216m` (384 GiB) |
| Video cap | Global `lastN=16` |
| Monitoring | Ayni makinede JMX Exporter, Node Exporter, Prometheus ve Grafana |
| Client | Kapsam disi; mevcut client degistirilmez |

## 1. Mimari ve sorumluluk siniri

JVB browser client tarafindan dogrudan secilmez. Calisan akis su sekildedir:

```text
Mevcut client
  -> mevcut HTTPS/XMPP signaling katmani (Prosody + Jicofo)
  -> Jicofo konferans icin JVB secer
  -> client RTP/RTCP medyasini JVB_PUBLIC_IP:10000/udp adresine gonderir
  -> Colibri WebSocket kullaniliyorsa web edge JVB_PRIVATE_IP:9091 adresine proxy yapar
```

Bu guide su varsayimlarla yazilmistir:

- Jitsi client baska bir makinede zaten calisiyor ve degistirilmeyecek.
- Prosody ve Jicofo signaling katmani mevcut ya da baska ekip tarafindan
  kurulacak.
- Yeni Debian makinesinde yalnizca `jitsi-videobridge2` ve JVB monitoring
  bilesenleri calisacak.
- Prometheus, Node Exporter, JMX Exporter ve Grafana ayni JVB makinesinde
  calisacak ve yalnizca loopback/yonetim agindan erisilecek.
- JVM yalnizca OpenJDK 21 Generational ZGC profiliyle calisacak.
- Container kullanilmayacak.
- Tek JVB ile baslanacak. Tek JVB restart edilirse aktif toplantilar kesilir.

Prosody ve Jicofo mevcut degilse burada durun. JVB tek basina bir Jitsi client'i
toplantiya alamaz.

## 2. Signaling ekibinden alinacak bilgiler

Kuruluma baslamadan once asagidaki degerleri netlestirin:

| Deger | Ornek | Aciklama |
| --- | --- | --- |
| `MEET_DOMAIN` | `meet.example.org` | Mevcut Jitsi deployment domain'i |
| `XMPP_HOST` | `xmpp.internal.example.org` | JVB'nin baglanacagi Prosody adresi |
| `XMPP_PORT` | `5222` | Prosody client-to-server portu |
| `AUTH_DOMAIN` | `auth.meet.example.org` | JVB XMPP kullanici domain'i |
| `JVB_USER` | `jvb` | Prosody tarafinda acilan servis kullanicisi |
| `JVB_PASSWORD` | secret | Guvenli kanaldan teslim edilen parola |
| `BREWERY_JID` | `jvbbrewery@internal.auth.meet.example.org` | Jicofo ile ayni olmali |
| `JVB_NODE_ID` | `jvb-prod-01` | Her bridge icin benzersiz nickname/server id |
| `JVB_PRIVATE_IP` | `10.20.30.40` | XMPP, proxy ve monitoring agi |
| `JVB_PUBLIC_IP` | `203.0.113.40` | Client'lara ilan edilecek medya IP'si |
| `WEB_PROXY_IP` | `10.20.10.20` | Colibri WebSocket proxy yapacak sunucu |

Signaling ekibi su iki islemi tamamlamalidir:

1. `jvb@AUTH_DOMAIN` hesabini Prosody'de olusturmak.
2. Jicofo `brewery-jid` degerini `BREWERY_JID` ile ayni yapmak.

JVB devreye alindiginda signaling ekibinden Jicofo logunda yeni bridge'in
goruldugunu teyit etmesini isteyin. Client tarafinda degisiklik yapilmaz.

## 3. Production kapasite tabani

120 kisilik tek konferans hedefi icin baslangic tabani:

- En az 16 fiziksel/garantili vCPU
- Bu 384 GiB hard-heap profili icin en az 512 GB fiziksel RAM
- JVB heap: 8 GiB initial, 32 GiB soft hedef, 384 GiB hard ust sinir
- Hizli yerel disk; `/var` icin en az 80 GB ve diagnostics icin ayri,
  en az 500 GB bos alani olan filesystem
- Dusuk jitter'li, simetrik ve kapasitesi olculmus ag baglantisi
- Statik public IP veya bire bir NAT
- NTP senkronizasyonu

`-Xmx393216m`, JVM'nin her acilista 384 GiB fiziksel RAM ayiracagi anlamina
gelmez; ancak ZGC allocation baskisinda bu sinira kadar cikabilir. Bu nedenle
512 GB altindaki host bu kesin profil icin uygun kabul edilmez. Daha kucuk bir
hostta `Xmx` sessizce korunmaz; kapasite testiyle daha dusuk bir profil ayrica
tasarlanir.

Bu degerler 120 kisiyi garanti etmez. `lastN=16`, video cozunurlugu, simulcast,
ekran paylasimi ve katilimci uplink kalitesi gercek paket hizini belirler.
Production kabulunden once sentetik ve gercek istemci yuk testi zorunludur.

## 4. Kesin JVM profili

Bu proje icin production JVM profili kesin olarak:

```text
OpenJDK 21 + Generational ZGC + Xms 8 GiB + SoftMax 32 GiB + Xmx 384 GiB
```

Bu bilincli bir proje kararidir. Jitsi self-hosting dokumani halen OpenJDK 17
belirtmektedir; bu nedenle Java/JVB paket kombinasyonu staging yuk testinde
dogrulanmadan production trafigi acilmaz. G1 profili kurulmaz ve ayni process'te
G1/ZGC collector flag'leri birlikte kullanilmaz.

## 5. Debian hazirligi

Debian 13 (Trixie) kullanin. Debian 13'te varsayilan headless Java OpenJDK 21'dir.
Debian 12/backports bu production standardinin kapsami disindadir.

Host'u hazirlayin:

```bash
sudo hostnamectl set-hostname jvb-prod-01
sudo apt update
sudo apt full-upgrade
sudo apt install -y ca-certificates curl gnupg2 apt-transport-https \
  openjdk-21-jdk-headless chrony ufw jq netcat-openbsd git
sudo systemctl enable --now chrony
```

Kontrol edin:

```bash
readlink -f "$(command -v java)"
java -version
java -XX:+UseZGC -XX:+ZGenerational -version
timedatectl status
chronyc tracking
ip -br address
free -h
df -h /var
```

Bu rehberin kullandigi version-controlled alert ve dashboard dosyalarini
production host'a alin. Asagidaki `REPO_ROOT` degeri sonraki adimlarda aynen
kullanilir:

```bash
export REPO_ROOT=/opt/jitsi-jvb-deployment
sudo git clone --depth 1 --branch develop \
  https://github.com/ecznt/jitsi.git "${REPO_ROOT}"
sudo git -C "${REPO_ROOT}" rev-parse HEAD
sudo test -f "${REPO_ROOT}/fedora-native-jitsi-jvb/templates/prometheus-jvb-alerts.yml.tpl"
sudo test -f "${REPO_ROOT}/fedora-native-jitsi-jvb/templates/grafana-dashboard-jvb.json"
```

Clone ciktisindaki commit SHA'yi change kaydina yazin. Production kurulumu
tamamlandiktan sonra `develop` branch'ini otomatik pull etmeyin; yeni commit'i
once staging'de kabul edin.

`openjdk version "21` ve `System clock synchronized: yes` gorulmeden
production'a gecmeyin. Yanlis saat
XMPP sertifika kontrolunu, log korelasyonunu ve Grafana zaman serilerini bozar.

## 6. Ag ve firewall

JVB-only node icin gereken akislar:

| Yon | Port | Kaynak/hedef | Amac |
| --- | --- | --- | --- |
| Inbound | `10000/udp` | Internet -> JVB public IP | WebRTC medya |
| Outbound | `5222/tcp` | JVB -> Prosody | XMPP bridge kaydi |
| Inbound | `9091/tcp` | Yalnizca web proxy -> JVB private IP | Colibri WebSocket |
| Inbound | `22/tcp` | Yalnizca yonetim agi | SSH |
| Local | `8080/tcp` | `127.0.0.1` | JVB native metrics/health |
| Local | `9404/tcp` | `127.0.0.1` | JVM/JMX metrics |
| Local | `9100/tcp` | `127.0.0.1` | Node Exporter |
| Local | `9090/tcp` | `127.0.0.1` | Prometheus |
| Local | `3000/tcp` | `127.0.0.1` | Grafana |

JVB public HTTP portu ile Prometheus'un varsayilan `9090` portu ayni makinede
cakisabilir. Bu guide Colibri WebSocket icin JVB public HTTP portunu `9091`,
Prometheus icin `9090` kullanir.

Ornek UFW kurallari:

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow from <MANAGEMENT_CIDR> to any port 22 proto tcp
sudo ufw allow 10000/udp
sudo ufw allow from <WEB_PROXY_IP> to any port 9091 proto tcp
sudo ufw enable
sudo ufw status verbose
```

Metrics portlarini Internet'e acmayin. NAT varsa router/security-group tarafinda
`10000/udp` portunu JVB private IP'sine bire bir yonlendirin.

## 7. Resmi Jitsi paketinden JVB kurulumu

Jitsi stable APT reposunu ekleyin:

```bash
curl -fsSL https://download.jitsi.org/jitsi-key.gpg.key \
  | gpg --dearmor \
  | sudo tee /usr/share/keyrings/jitsi-keyring.gpg >/dev/null

echo 'deb [signed-by=/usr/share/keyrings/jitsi-keyring.gpg] https://download.jitsi.org stable/' \
  | sudo tee /etc/apt/sources.list.d/jitsi-stable.list

sudo apt update
sudo apt install jitsi-videobridge2
```

Paket hostname sorarsa `MEET_DOMAIN` degerini girin. Paket servisi erken
baslatirsa production config tamamlanana kadar durdurun:

```bash
sudo systemctl stop jitsi-videobridge2
sudo systemctl disable jitsi-videobridge2
```

Kurulan surumleri kaydedin:

```bash
dpkg-query -W 'jitsi-videobridge2' 'openjdk-21-jdk-headless'
apt-cache policy jitsi-videobridge2
systemctl cat jitsi-videobridge2
```

Fedora projesindeki artifact indirme, `.deb` acma veya custom
`jitsi-videobridge.service` olusturma betiklerini Debian'da calistirmayin.
Debian paketi `jitsi-videobridge2.service`, `/etc/jitsi/videobridge/config` ve
`/etc/jitsi/videobridge/jvb.conf` dosyalarinin sahibidir.

## 8. Yedek ve JVB konfigurasyonu

Once paket tarafindan uretilen dosyalari yedekleyin:

```bash
STAMP=$(date +%Y%m%d-%H%M%S)
sudo install -d -m 0700 "/root/jvb-backup-${STAMP}"
sudo cp -a /etc/jitsi/videobridge "/root/jvb-backup-${STAMP}/"
sudo systemctl cat jitsi-videobridge2 \
  | sudo tee "/root/jvb-backup-${STAMP}/jitsi-videobridge2.unit.txt" >/dev/null
```

`/etc/jitsi/videobridge/jvb.conf` dosyasini tamamen silip yeniden yazmayin.
Paketin olusturdugu mevcut bloklari koruyarak asagidaki degerleri merge edin:

```hocon
videobridge {
  cc {
    jvb-last-n = 16
  }

  ice {
    udp {
      port = 10000
    }
    advertise-private-candidates = true
  }

  apis {
    xmpp-client {
      configs {
        xmpp-server-1 {
          HOSTNAME = "<XMPP_HOST>"
          PORT = "5222"
          DOMAIN = "auth.<MEET_DOMAIN>"
          USERNAME = "jvb"
          PASSWORD = "<JVB_PASSWORD>"
          MUC_JIDS = "jvbbrewery@internal.auth.<MEET_DOMAIN>"
          MUC_NICKNAME = "jvb-prod-01"
          DISABLE_CERTIFICATE_VERIFICATION = false
        }
      }
    }
  }

  rest {
    prometheus {
      enabled = true
    }
    health {
      enabled = true
    }
  }

  stats {
    interval = 5 seconds
    jvm {
      enabled = true
    }
    transit-time {
      enable-prometheus = true
    }
  }

  http-servers {
    private {
      host = "127.0.0.1"
      port = 8080
    }
    public {
      host = "<JVB_PRIVATE_IP>"
      port = 9091
    }
  }

  websockets {
    enabled = true
    domains = [ "<MEET_DOMAIN>" ]
    tls = true
    server-id = "jvb-prod-01"
  }

  health {
    require-valid-address = true
  }
}

ice4j {
  harvest {
    mapping {
      static-mappings = [
        {
          local-address = "<JVB_PRIVATE_IP>"
          public-address = "<JVB_PUBLIC_IP>"
        }
      ]
    }
  }
}
```

Notlar:

- Sunucu dogrudan public IP kullaniyorsa `static-mappings` blogunu kaldirin.
- XMPP sertifikasi `XMPP_HOST` ile eslesmelidir. Production'da
  `DISABLE_CERTIFICATE_VERIFICATION=true` kullanmayin.
- Kurulu JVB surumu `websockets.domain` tekil alanini kullaniyorsa paketin
  uretdigi alani koruyun. Yeni referans konfigurasyon `domains = []` kullanir.
- `jvb-last-n=16` bridge cap'idir. Client daha dusuk deger isteyebilir, daha
  yuksek degeri asamaz.

Dosya izinlerini sinirlayin:

```bash
sudo chown root:"$(id -gn jvb)" /etc/jitsi/videobridge/jvb.conf
sudo chmod 0640 /etc/jitsi/videobridge/jvb.conf
```

## 9. JMX Exporter ve JVM dosyalari

JMX Exporter 1.6.0 Java agent modunda kullanilir ve sadece loopback'e bind
edilir:

```bash
sudo install -d -m 0755 /opt/jmx-exporter
sudo curl -fL \
  -o /opt/jmx-exporter/jmx_prometheus_javaagent-1.6.0.jar \
  https://github.com/prometheus/jmx_exporter/releases/download/1.6.0/jmx_prometheus_javaagent-1.6.0.jar
sudo chown root:root /opt/jmx-exporter/jmx_prometheus_javaagent-1.6.0.jar
sudo chmod 0644 /opt/jmx-exporter/jmx_prometheus_javaagent-1.6.0.jar
```

Production'da binary'yi kurum artifact reposuna alip SHA-256 ile pinlemek
tercih edilmelidir.

`/etc/jitsi/videobridge/jmx-exporter.yml`:

```yaml
startDelaySeconds: 0
lowercaseOutputName: true
lowercaseOutputLabelNames: true
excludeJvmMetrics: false
rules:
  - pattern: ".*"
```

```bash
sudo chown root:"$(id -gn jvb)" /etc/jitsi/videobridge/jmx-exporter.yml
sudo chmod 0640 /etc/jitsi/videobridge/jmx-exporter.yml
sudo install -d -m 0750 -o jvb -g "$(id -gn jvb)" /var/lib/jitsi-videobridge/diagnostics
sudo install -d -m 0750 -o jvb -g "$(id -gn jvb)" /var/log/jitsi/jvb-gc
```

`/var/lib/jitsi-videobridge/diagnostics` ayri ve hizli bir filesystem uzerinde
olmalidir. Heap dump boyutu canli heap'e bagli olarak cok buyuyebilecegi icin
bu mount'ta en az 500 GB bos alan dogrulanmadan servisi production'a almayin:

```bash
findmnt /var/lib/jitsi-videobridge/diagnostics
df -h /var/lib/jitsi-videobridge/diagnostics
```

## 10. Production JVM profili: Java 21 Generational ZGC

`/etc/jitsi/videobridge/jvm-production.env` olusturun:

```ini
VIDEOBRIDGE_MAX_MEMORY=393216m
VIDEOBRIDGE_GC_TYPE=ZGC
JAVA_TOOL_OPTIONS="-Xms8g -XX:SoftMaxHeapSize=32g -XX:+ZGenerational -XX:+AlwaysPreTouch -XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath=/var/lib/jitsi-videobridge/diagnostics -XX:+ExitOnOutOfMemoryError -Xlog:gc*,safepoint:file=/var/log/jitsi/jvb-gc/zgc.log:time,uptime,level,tags:filecount=10,filesize=100M -XX:StartFlightRecording=filename=/var/lib/jitsi-videobridge/diagnostics/jvb-zgc.jfr,settings=profile,dumponexit=true,maxage=2h,maxsize=1g -javaagent:/opt/jmx-exporter/jmx_prometheus_javaagent-1.6.0.jar=127.0.0.1:9404:/etc/jitsi/videobridge/jmx-exporter.yml"
```

```bash
sudo chown root:"$(id -gn jvb)" /etc/jitsi/videobridge/jvm-production.env
sudo chmod 0640 /etc/jitsi/videobridge/jvm-production.env
sudo install -d -m 0755 /etc/systemd/system/jitsi-videobridge2.service.d
```

`/etc/systemd/system/jitsi-videobridge2.service.d/20-production-jvm.conf`:

```ini
[Service]
EnvironmentFile=/etc/jitsi/videobridge/jvm-production.env
```

Jitsi'nin `jvb.sh` wrapper'i `VIDEOBRIDGE_MAX_MEMORY` degerini `-Xmx`,
`VIDEOBRIDGE_GC_TYPE` degerini `-XX:+Use...` olarak ekler. Bu nedenle env
dosyasinda ikinci bir collector secmeyin. Wrapper `UseZGC`, env dosyasi ise
Java 21 icin `ZGenerational` secenegini saglar.

Bu profilde `Xms` bilerek `Xmx` degerine esitlenmez. `AlwaysPreTouch` yalnizca
initial 8 GiB heap'i onceden sayfalar; 384 GiB'nin tamamini startup'ta fiziksel
bellege dokundurmaz. ZGC normal kosulda 32 GiB soft hedefin altinda kalmaya
calisir, fakat uygulamanin allocation'i durmasin diye gerekirse 384 GiB hard
sinira kadar buyuyebilir. `SoftMaxHeapSize` kapasite siniri degil, ZGC heuristic
hedefidir.

## 11. Systemd limitleri

Resmi JVB Debian service'i normalde 65000 task/process/file limitleriyle gelir.
Once kontrol edin:

```bash
systemctl show jitsi-videobridge2 \
  -p TasksMax -p LimitNOFILE -p LimitNPROC
```

Her uc deger 65000 degilse drop-in'e ekleyin:

```ini
[Service]
TasksMax=65000
LimitNOFILE=65000
LimitNPROC=65000
```

Global `/etc/systemd/system.conf` dosyasini yalnizca servis drop-in'i yetersizse
degistirin.

## 12. Prometheus ve Node Exporter

Monitoring'i ilk asamada ayni node'da kurmak icin:

```bash
sudo apt install -y prometheus prometheus-node-exporter
```

`/etc/default/prometheus-node-exporter` icindeki `ARGS` degerine systemd
collector ve loopback bind ekleyin:

```bash
ARGS="--collector.systemd --web.listen-address=127.0.0.1:9100"
```

`/etc/default/prometheus` icindeki mevcut `ARGS` degerine Prometheus loopback
bind secenegini ekleyin:

```bash
ARGS="--web.listen-address=127.0.0.1:9090 --storage.tsdb.retention.time=15d --storage.tsdb.retention.size=20GB"
```

Mevcut Prometheus konfigurasyonunu yedekleyip
`/etc/prometheus/prometheus.yml` dosyasini su icerikle olusturun:

```yaml
global:
  scrape_interval: 10s
  scrape_timeout: 8s
  evaluation_interval: 10s

rule_files:
  - /etc/prometheus/jvb-alerts.yml
  - /etc/prometheus/jvb-production-memory-alerts.yml

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: [ "127.0.0.1:9090" ]

  - job_name: jvb
    scrape_interval: 5s
    metrics_path: /metrics
    static_configs:
      - targets: [ "127.0.0.1:8080" ]
        labels:
          component: jitsi-videobridge
          instance: jvb-prod-01

  - job_name: jvb-jmx
    metrics_path: /metrics
    static_configs:
      - targets: [ "127.0.0.1:9404" ]
        labels:
          component: jitsi-videobridge-jvm
          instance: jvb-prod-01

  - job_name: node
    metrics_path: /metrics
    static_configs:
      - targets: [ "127.0.0.1:9100" ]
        labels:
          component: jvb-host
          instance: jvb-prod-01
```

Bu repodaki alert kurallarini kurun:

```bash
REPO_ROOT=/opt/jitsi-jvb-deployment
sudo install -m 0644 \
  "${REPO_ROOT}/fedora-native-jitsi-jvb/templates/prometheus-jvb-alerts.yml.tpl" \
  /etc/prometheus/jvb-alerts.yml
sudo tee /etc/prometheus/jvb-production-memory-alerts.yml >/dev/null <<'EOF'
groups:
  - name: jvb-zgc-production-memory
    rules:
      - alert: JVBHeapNearSoftMaxTarget
        expr: sum by (instance) (jvm_memory_used_bytes{job="jvb-jmx",area="heap"}) > 0.85 * 32 * 1024 * 1024 * 1024
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "JVB heap is near the 32 GiB ZGC soft target"
          description: "Heap usage has exceeded 85 percent of the production soft target."

      - alert: JVBHeapAboveSoftMaxTarget
        expr: sum by (instance) (jvm_memory_used_bytes{job="jvb-jmx",area="heap"}) > 32 * 1024 * 1024 * 1024
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "JVB heap is above the 32 GiB ZGC soft target"
          description: "ZGC is using hard-ceiling headroom; inspect allocation rate, live set and GC logs."
EOF
sudo promtool check rules /etc/prometheus/jvb-alerts.yml
sudo promtool check rules /etc/prometheus/jvb-production-memory-alerts.yml
sudo promtool check config /etc/prometheus/prometheus.yml
```

Genel alert dosyasindaki `JVBHighHeapUsage`, 384 GiB hard `Xmx` yuzdesini
izler ve son savunma alarmidir. Bu profile eklenen iki mutlak alarm ise 32 GiB
soft hedefi izler; production operasyonunda once bunlar dikkate alinir.

Bu proje kararinda Prometheus ve Grafana ayni JVB makinesinde kalir. Exporter,
Prometheus ve Grafana portlari loopback'e bind edilmis olmali; dashboard erisimi
yonetim reverse proxy'si veya SSH tunnel uzerinden saglanmalidir.

## 13. Grafana kurulumu ve dashboard

Grafana'nin resmi APT reposunu kullanin:

```bash
sudo install -d -m 0755 /etc/apt/keyrings
sudo curl -fsSL -o /etc/apt/keyrings/grafana.asc \
  https://apt.grafana.com/gpg-full.key
sudo chmod 0644 /etc/apt/keyrings/grafana.asc
echo 'deb [signed-by=/etc/apt/keyrings/grafana.asc] https://apt.grafana.com stable main' \
  | sudo tee /etc/apt/sources.list.d/grafana.list
sudo apt update
sudo apt install -y grafana
```

Datasource ve dashboard provisioning dosyalarini kurun:

```bash
REPO_ROOT=/opt/jitsi-jvb-deployment
sudo install -d -m 0755 \
  /etc/grafana/provisioning/datasources \
  /etc/grafana/provisioning/dashboards \
  /var/lib/grafana/dashboards

sudo install -m 0644 \
  "${REPO_ROOT}/fedora-native-jitsi-jvb/templates/grafana-datasource-prometheus.yml" \
  /etc/grafana/provisioning/datasources/prometheus.yml

sudo install -m 0644 \
  "${REPO_ROOT}/fedora-native-jitsi-jvb/templates/grafana-dashboard-provider.yml" \
  /etc/grafana/provisioning/dashboards/jvb.yml

sudo install -m 0644 \
  "${REPO_ROOT}/fedora-native-jitsi-jvb/templates/grafana-dashboard-jvb.json" \
  /var/lib/grafana/dashboards/jvb-capacity.json

sudo chown -R grafana:grafana /var/lib/grafana/dashboards
sudo jq empty /var/lib/grafana/dashboards/jvb-capacity.json
```

`/etc/grafana/grafana.ini` icinde Grafana'yi loopback'e bind edin:

```ini
[server]
http_addr = 127.0.0.1
http_port = 3000

[auth.basic]
password_policy = true
```

Grafana'yi `127.0.0.1:3000` veya yalnizca monitoring VLAN'i uzerinde tutun.
Internet'e sifresiz `3000/tcp` acmayin. Production erisimini kurum reverse
proxy, TLS ve SSO katmanindan gecirin.

Dashboard baslica sunlari gostermelidir:

- Aktif konferans ve endpoint sayisi
- En buyuk konferans
- JVB stress level
- Inbound/outbound bitrate ve packet rate
- ICE, DTLS ve partially failed conference artislari
- JVM heap, GC, safepoint ve thread sayisi
- Host CPU, load, memory, swap ve disk
- Network throughput, drop ve error sayilari
- JVB/metrics target availability

Dashboard'daki `JVM Heap Used and Maximum` paneli heap'i byte/GiB cinsinden
mutlak olarak gosterir. 32 GiB soft hedef, `JVBHeapNearSoftMaxTarget` ve
`JVBHeapAboveSoftMaxTarget` alarmlariyla izlenir. `heap used / heap max` yuzdesi
384 GiB hard sinira gore hesaplandigi icin tek basina ZGC baskisini gostermez.

Monitoring servislerinin JVB'yi baskilamasini engelleyin:

```bash
sudo systemctl edit prometheus
```

```ini
[Service]
MemoryMax=4G
CPUQuota=200%
OOMScoreAdjust=300
```

```bash
sudo systemctl edit grafana-server
```

```ini
[Service]
MemoryMax=2G
CPUQuota=100%
OOMScoreAdjust=300
```

Bu limitler monitoring'i iki CPU ve toplam 6 GB memory tavaninda tutar. JVB
icin CPU quota uygulanmaz. Yuk testinde Prometheus scrape timeout veya Grafana
OOM gorulurse retention ve dashboard sorgularini azaltin; JVB kaynagini
monitoring lehine dusurmeyin.

## 14. Ilk baslatma sirasi

JVB'yi signaling bilgileri hazir olmadan baslatmayin:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now prometheus-node-exporter
sudo systemctl enable --now prometheus
sudo systemctl enable --now grafana-server
sudo systemctl enable --now jitsi-videobridge2
```

JVB'nin pre-touch edilen initial 8 GiB heap ile baslamasi 10-30 saniye
surebilir. `Xmx=384 GiB` bu asamada tamamen pre-touch edilmez.

Monitoring ve Grafana provisioning kabul kontrolu:

```bash
systemctl is-active prometheus-node-exporter prometheus grafana-server
curl -fsS http://127.0.0.1:9090/-/ready
curl -fsS http://127.0.0.1:3000/api/health | jq
curl -fsG http://127.0.0.1:9090/api/v1/query \
  --data-urlencode 'query=up{job=~"jvb|jvb-jmx|node"}' | jq
sudo test -r /etc/grafana/provisioning/datasources/prometheus.yml
sudo test -r /etc/grafana/provisioning/dashboards/jvb.yml
sudo test -r /var/lib/grafana/dashboards/jvb-capacity.json
sudo journalctl -u grafana-server -b --no-pager \
  | grep -Ei 'provision|error|failed' || true
```

Grafana'da `Jitsi` klasoru altinda `JVB Capacity and Bottleneck Analysis`
dashboard'u otomatik gorunmelidir. Dashboard UID'si
`jvb-capacity-bottlenecks` olmalidir. Datasource `Prometheus` olarak ve default
durumda provision edilmelidir. Panel verileri `No data` gosteriyorsa once
Prometheus `up` sorgusundaki `jvb`, `jvb-jmx` ve `node` sonuclarinin `1`
oldugunu dogrulayin.

Ilk Grafana girisi icin yonetim bilgisayarinizdan SSH tunnel acin; bu komut JVB
sunucusunda degil yonetim bilgisayarinda calistirilir:

```bash
ssh -N -L 3000:127.0.0.1:3000 <ADMIN_USER>@<JVB_PRIVATE_IP>
```

Browser'da `http://127.0.0.1:3000` adresini acin. Yeni kurulumdaki ilk giriste
kullanici/parola `admin` / `admin` degeridir; Grafana'nin istedigi parola
degisikligini hemen tamamlayin. Production'da ortak admin hesabi yerine kurum
SSO veya kisi bazli hesap kullanin.

## 15. Teknik dogrulama

Servis ve JVM:

```bash
sudo systemctl status jitsi-videobridge2 --no-pager
PID=$(systemctl show -p MainPID --value jitsi-videobridge2)
tr '\0' ' ' < "/proc/${PID}/cmdline"
sudo cat "/proc/${PID}/limits" | grep -E 'Max processes|Max open files'
```

Canli komut satirinda sunlar bulunmalidir:

```text
-Xms8g
-Xmx393216m
-XX:SoftMaxHeapSize=32g
-XX:+UseZGC
-XX:+ZGenerational
-XX:+AlwaysPreTouch
-javaagent:...=127.0.0.1:9404:...
```

Canli process `-XX:+UseG1GC` icermemelidir.

Portlar ve metrics:

```bash
sudo ss -lntup | grep -E ':10000|:8080|:9091|:9404|:9100|:9090|:3000'
curl -fsS http://127.0.0.1:8080/metrics >/dev/null
curl -fsS http://127.0.0.1:9404/metrics >/dev/null
curl -fsS http://127.0.0.1:9100/metrics >/dev/null
curl -fsG http://127.0.0.1:9090/api/v1/query \
  --data-urlencode 'query=up{job=~"jvb|jvb-jmx|node"}' | jq
```

XMPP ve bridge kaydi:

```bash
nc -vz <XMPP_HOST> 5222
sudo journalctl -u jitsi-videobridge2 -n 200 --no-pager \
  | grep -E 'Connected|Authenticated|Joined MUC|ERROR|SEVERE|Exception'
```

Beklenen kayitlar:

```text
Connected
Authenticated
Joined MUC: jvbbrewery@internal.auth.<MEET_DOMAIN>
```

Signaling ekibi Jicofo tarafinda `Added new videobridge` kaydini teyit
etmelidir. Bu teyit olmadan client testi baslatilmaz.

## 16. Mevcut client ile kabul

Client ekibine konfigurasyon guide'i verilmez. Yalnizca su JVB kontrati teslim
edilir:

- JVB public media IP ve `10000/udp`
- `JVB_NODE_ID`
- Colibri WebSocket upstream: `JVB_PRIVATE_IP:9091`
- Bridge'in katildigi `BREWERY_JID`
- Bakim penceresi ve test room adi

Client ekibi mevcut uygulamayla iki ve daha fazla katilimcili toplantiyi acar.
JVB sorumlusu ayni anda su kontrolleri yapar:

```bash
watch -n 2 'curl -fsS -H "Accept: application/json" http://127.0.0.1:8080/metrics | jq "{conferences,endpoints,stress_level,bit_rate_download,bit_rate_upload,total_ice_failed,dtls_failed_endpoints}"'
sudo journalctl -u jitsi-videobridge2 -f
```

Kabul kriterleri:

- Konferans ve endpoint sayisi gercek katilimla uyumlu artar.
- Iki kisilik gorusmede P2P kapaliysa endpoint'ler JVB'de gorunur.
- `total_ice_failed`, `dtls_failed_endpoints` ve failed conference sayaclari
  artmaz.
- Her istemci ses ve video alir.
- Client console'da XMPP/Colibri WebSocket disconnect dongusu yoktur.
- Jicofo bridge'i operational gorur.

## 17. Yuk testi ve production gate

120 kisiye tek adimda cikmayin:

```text
10 -> 25 -> 50 -> 80 -> 120 endpoint
```

Her kademede en az 15 dakika bekleyin ve su degerleri kaydedin:

- CPU, steal, load ve packet rate
- JVB stress level
- Network bitrate, drop ve interface error
- ICE/DTLS failure delta
- Heap occupancy, GC pause ve safepoint
- Endpoint/conference sayisi
- Ses ve video kalite gozlemi

Bir kademede packet drop, ICE/DTLS hatasi, sustained stress veya swap artisi
gorulurse bir sonraki kademeye gecmeyin.

## 18. ZGC production kabul kontrolleri

JVB baslatildiktan sonra Java ve collector secimini process uzerinden tekrar
dogrulayin:

```bash
PID=$(systemctl show -p MainPID --value jitsi-videobridge2)
tr '\0' ' ' < "/proc/${PID}/cmdline"
sudo jcmd "${PID}" VM.flags
sudo jcmd "${PID}" GC.heap_info
sudo jcmd "${PID}" VM.command_line
sudo jcmd "${PID}" JFR.check
sudo journalctl -u jitsi-videobridge2 -b --no-pager \
  | grep -E 'openjdk|UseZGC|ZGenerational|OutOfMemory|Exception|SEVERE'
sudo test -s /var/log/jitsi/jvb-gc/zgc.log
sudo test -e /var/lib/jitsi-videobridge/diagnostics/jvb-zgc.jfr
```

Canli process `UseZGC` ve `ZGenerational` icermeli, `UseG1GC` icermemelidir.
`VM.flags`/`VM.command_line` ciktisinda `MaxHeapSize=412316860416`
(393216 MiB), `SoftMaxHeapSize=34359738368` (32 GiB) ve 8 GiB initial heap
gorulmelidir.
JVB `NRestarts=0` olmali ve kernel OOM kaydi bulunmamalidir:

```bash
systemctl show jitsi-videobridge2 -p NRestarts -p MemoryCurrent -p MemoryPeak
sudo journalctl -k -b --no-pager \
  | grep -Ei 'out of memory|oom-kill|killed process' || true
```

## 19. Rollback

JVM rollback, G1 veya Java 17'ye gecis anlamina gelmez. Son kabul edilmis
Java 21/ZGC env dosyasini ve paket surumunu geri yukleyin, ardindan
`systemctl daemon-reload` ve JVB restart uygulayin.

JVB config rollback:

```bash
sudo systemctl stop jitsi-videobridge2
sudo cp -a /root/jvb-backup-<STAMP>/videobridge/. /etc/jitsi/videobridge/
sudo systemctl daemon-reload
sudo systemctl start jitsi-videobridge2
```

Rollback sonrasinda metrics endpoint'leri, MUC join ve Jicofo bridge discovery
yeniden dogrulanmalidir.

## 20. Upgrade politikasi

- Jitsi stable paketini production'a otomatik gecirmeyin.
- Once staging/canary JVB'de paket upgrade ve client uyumluluk testi yapin.
- Kabul edilen paket surumunu kaydedin ve gerekirse `apt-mark hold
  jitsi-videobridge2` uygulayin.
- Her upgrade oncesi `/etc/jitsi/videobridge`, systemd drop-in, Prometheus,
  Grafana provisioning ve dashboard yedegi alin.
- Upgrade sonrasi `jvb.conf` alan adlarinin reference config ile uyumunu kontrol
  edin. Ozellikle WebSocket ve metrics konfigurasyonu surumler arasinda
  degisebilir.

## 21. Referanslar

- Debian 13 OpenJDK 21 paketi:
  https://packages.debian.org/trixie/openjdk-21-jdk-headless
- Jitsi Debian/Ubuntu self-hosting:
  https://jitsi.github.io/handbook/docs/devops-guide/devops-guide-quickstart/
- Jitsi scalable deployment ve JVB ayrimi:
  https://jitsi.github.io/handbook/docs/devops-guide/devops-guide-scalable/
- JVB reference configuration:
  https://github.com/jitsi/jitsi-videobridge/blob/master/jvb/src/main/resources/reference.conf
- JVB Prometheus statistics:
  https://github.com/jitsi/jitsi-videobridge/blob/master/doc/statistics.md
- Oracle Java 21 ZGC tuning ve `SoftMaxHeapSize`:
  https://docs.oracle.com/en/java/javase/21/gctuning/z-garbage-collector.html
- Prometheus Node Exporter:
  https://prometheus.io/docs/guides/node-exporter/
- Prometheus JMX Exporter Java agent:
  https://prometheus.github.io/jmx_exporter/deployment/java-agent/
- Grafana Debian installation:
  https://grafana.com/docs/grafana/latest/setup-grafana/installation/debian/
