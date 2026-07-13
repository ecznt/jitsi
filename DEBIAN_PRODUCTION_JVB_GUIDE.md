# Debian Production JVB Deployment Guide

Bu dokuman yalnizca production Debian makinesindeki Jitsi Videobridge (JVB)
sorumlulugunu kapsar. Mevcut Jitsi client'in build, deploy, Nginx veya uygulama
ayarlari bu kapsamin disindadir.

## 1. Mimari ve sorumluluk siniri

JVB browser client tarafindan dogrudan secilmez. Calisan akis su sekildedir:

```text
Mevcut client
  -> mevcut HTTPS/XMPP signaling katmani (Prosody + Jicofo)
  -> Jicofo konferans icin JVB secer
  -> client RTP/RTCP medyasini JVB_PUBLIC_IP:10000/udp adresine gonderir
  -> Colibri WebSocket kullaniliyorsa web edge JVB_PRIVATE_IP:9090 adresine proxy yapar
```

Bu guide su varsayimlarla yazilmistir:

- Jitsi client baska bir makinede zaten calisiyor ve degistirilmeyecek.
- Prosody ve Jicofo signaling katmani mevcut ya da baska ekip tarafindan
  kurulacak.
- Yeni Debian makinesinde yalnizca `jitsi-videobridge2` ve JVB monitoring
  bilesenleri calisacak.
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
- En az 32 GB RAM
- JVB icin 8 GB sabit heap
- Hizli yerel disk ve `/var` altinda en az 20 GB bos alan
- Dusuk jitter'li, simetrik ve kapasitesi olculmus ag baglantisi
- Statik public IP veya bire bir NAT
- NTP senkronizasyonu

Bu degerler 120 kisiyi garanti etmez. `lastN=16`, video cozunurlugu, simulcast,
ekran paylasimi ve katilimci uplink kalitesi gercek paket hizini belirler.
Production kabulunden once sentetik ve gercek istemci yuk testi zorunludur.

## 4. Java karari

Jitsi'nin guncel Debian/Ubuntu self-hosting dokumani OpenJDK 17 kullanilmasini
istiyor. Bu nedenle ilk production kabul profili:

```text
OpenJDK 17 + G1GC + 8 GB heap
```

Fedora laboratuvarinda dogrulanan Java 21 Generational ZGC profili bu resmi
production tabaninin yerine dogrudan kullanilmamalidir. ZGC gerekiyorsa once
Java 17/G1 ile signaling, medya ve monitoring kabulunu tamamlayin; daha sonra
bu dokumanin ZGC canary bolumunu ayri bir bakim penceresinde uygulayin.

## 5. Debian hazirligi

Debian 12 veya daha yeni desteklenen bir surum kullanin. Once host'u hazirlayin:

```bash
sudo hostnamectl set-hostname jvb-prod-01
sudo apt update
sudo apt full-upgrade
sudo apt install -y ca-certificates curl gnupg2 apt-transport-https \
  openjdk-17-jre-headless chrony ufw jq netcat-openbsd
sudo systemctl enable --now chrony
```

Kontrol edin:

```bash
java -version
timedatectl status
chronyc tracking
ip -br address
free -h
df -h /var
```

`System clock synchronized: yes` gorulmeden production'a gecmeyin. Yanlis saat
XMPP sertifika kontrolunu, log korelasyonunu ve Grafana zaman serilerini bozar.

## 6. Ag ve firewall

JVB-only node icin gereken akislar:

| Yon | Port | Kaynak/hedef | Amac |
| --- | --- | --- | --- |
| Inbound | `10000/udp` | Internet -> JVB public IP | WebRTC medya |
| Outbound | `5222/tcp` | JVB -> Prosody | XMPP bridge kaydi |
| Inbound | `9090/tcp` | Yalnizca web proxy -> JVB private IP | Colibri WebSocket |
| Inbound | `22/tcp` | Yalnizca yonetim agi | SSH |
| Local | `8080/tcp` | `127.0.0.1` | JVB native metrics/health |
| Local | `9404/tcp` | `127.0.0.1` | JVM/JMX metrics |
| Local | `9100/tcp` | `127.0.0.1` | Node Exporter |
| Local | `9090/tcp` | `127.0.0.1` | Prometheus; public JVB HTTP ile ayni hostta cakismaya dikkat |
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
dpkg-query -W 'jitsi-videobridge2' 'openjdk-17-jre-headless'
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

## 10. Desteklenen production JVM profili: Java 17/G1

`/etc/jitsi/videobridge/jvm-production.env` olusturun:

```ini
VIDEOBRIDGE_MAX_MEMORY=8192m
VIDEOBRIDGE_GC_TYPE=G1GC
JAVA_TOOL_OPTIONS="-Xms8g -XX:MaxGCPauseMillis=50 -XX:G1ReservePercent=20 -XX:+AlwaysPreTouch -XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath=/var/lib/jitsi-videobridge/diagnostics -XX:+ExitOnOutOfMemoryError -Xlog:gc*,safepoint:file=/var/log/jitsi/jvb-gc/g1.log:time,uptime,level,tags:filecount=10,filesize=100M -XX:StartFlightRecording=filename=/var/lib/jitsi-videobridge/diagnostics/jvb-g1.jfr,settings=profile,dumponexit=true,maxage=2h,maxsize=1g -javaagent:/opt/jmx-exporter/jmx_prometheus_javaagent-1.6.0.jar=127.0.0.1:9404:/etc/jitsi/videobridge/jmx-exporter.yml"
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
dosyasinda ikinci bir collector secmeyin.

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
ARGS="--web.listen-address=127.0.0.1:9090"
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
sudo install -m 0644 \
  fedora-native-jitsi-jvb/templates/prometheus-jvb-alerts.yml.tpl \
  /etc/prometheus/jvb-alerts.yml
sudo promtool check rules /etc/prometheus/jvb-alerts.yml
sudo promtool check config /etc/prometheus/prometheus.yml
```

Production yukunde Prometheus ve Grafana'yi ayri monitoring makinesine tasimak
daha dogrudur. Bu durumda exporter'lari private IP'ye bind edin ve portlari
yalnizca Prometheus sunucusuna acin.

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
sudo install -d -m 0755 \
  /etc/grafana/provisioning/datasources \
  /etc/grafana/provisioning/dashboards \
  /var/lib/grafana/dashboards

sudo install -m 0644 \
  fedora-native-jitsi-jvb/templates/grafana-datasource-prometheus.yml \
  /etc/grafana/provisioning/datasources/prometheus.yml

sudo install -m 0644 \
  fedora-native-jitsi-jvb/templates/grafana-dashboard-provider.yml \
  /etc/grafana/provisioning/dashboards/jvb.yml

sudo install -m 0644 \
  fedora-native-jitsi-jvb/templates/grafana-dashboard-jvb.json \
  /var/lib/grafana/dashboards/jvb-capacity.json

sudo chown -R grafana:grafana /var/lib/grafana/dashboards
```

`/etc/grafana/grafana.ini` icinde Grafana'yi loopback'e bind edin:

```ini
[server]
http_addr = 127.0.0.1
http_port = 3000
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

## 14. Ilk baslatma sirasi

JVB'yi signaling bilgileri hazir olmadan baslatmayin:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now prometheus-node-exporter
sudo systemctl enable --now prometheus
sudo systemctl enable --now grafana-server
sudo systemctl enable --now jitsi-videobridge2
```

JVB'nin pre-touch edilen 8 GB heap ile baslamasi 10-30 saniye surebilir.

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
-Xmx8192m
-XX:+UseG1GC
-XX:+AlwaysPreTouch
-javaagent:...=127.0.0.1:9404:...
```

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

## 18. Opsiyonel Java 21 Generational ZGC canary

Bu adim resmi OpenJDK 17 production tabanindan sapmadir. Yalnizca staging veya
tek JVB'nin yanina ikinci canary JVB eklenebildiginde uygulanmalidir.

1. Kurum tarafindan onayli OpenJDK 21 paketini kurun.
2. Bu makine strict JVB-only node ise `update-alternatives --config java` ile
   Java 21'i secin. Ayni hostta baska Java servisleri varsa global alternative
   degistirmeyin; JVB service'i icin ayri `PATH` drop-in'i hazirlayin.
3. Asagidaki komut basarili olmadan servis config'ini degistirmeyin:

```bash
readlink -f "$(command -v java)"
java -XX:+UseZGC -XX:+ZGenerational -version
```

4. `jvm-production.env` icinde collector ve log dosyasini degistirin:

```ini
VIDEOBRIDGE_MAX_MEMORY=8192m
VIDEOBRIDGE_GC_TYPE=ZGC
JAVA_TOOL_OPTIONS="-Xms8g -XX:+ZGenerational -XX:+AlwaysPreTouch -XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath=/var/lib/jitsi-videobridge/diagnostics -XX:+ExitOnOutOfMemoryError -Xlog:gc*,safepoint:file=/var/log/jitsi/jvb-gc/zgc.log:time,uptime,level,tags:filecount=10,filesize=100M -XX:StartFlightRecording=filename=/var/lib/jitsi-videobridge/diagnostics/jvb-zgc.jfr,settings=profile,dumponexit=true,maxage=2h,maxsize=1g -javaagent:/opt/jmx-exporter/jmx_prometheus_javaagent-1.6.0.jar=127.0.0.1:9404:/etc/jitsi/videobridge/jmx-exporter.yml"
```

5. Bakim penceresinde restart edin ve canli JVM argumanlarini kontrol edin:

```bash
sudo systemctl restart jitsi-videobridge2
PID=$(systemctl show -p MainPID --value jitsi-videobridge2)
tr '\0' ' ' < "/proc/${PID}/cmdline"
```

Canli process `UseZGC` ve `ZGenerational` icermeli, `UseG1GC` icermemelidir.
G1 ile ayni yuk senaryosu, ayni client surumu ve ayni ag kosullari altinda
karsilastirma yapilmadan ZGC production standardi ilan edilmez.

## 19. Rollback

JVM rollback:

1. `jvm-production.env` dosyasini G1 icerigine geri alin.
2. Java 17'yi tekrar varsayilan yapin.
3. `systemctl daemon-reload` ve JVB restart uygulayin.

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

- Jitsi Debian/Ubuntu self-hosting:
  https://jitsi.github.io/handbook/docs/devops-guide/devops-guide-quickstart/
- Jitsi scalable deployment ve JVB ayrimi:
  https://jitsi.github.io/handbook/docs/devops-guide/devops-guide-scalable/
- JVB reference configuration:
  https://github.com/jitsi/jitsi-videobridge/blob/master/jvb/src/main/resources/reference.conf
- JVB Prometheus statistics:
  https://github.com/jitsi/jitsi-videobridge/blob/master/doc/statistics.md
- Prometheus Node Exporter:
  https://prometheus.io/docs/guides/node-exporter/
- Prometheus JMX Exporter Java agent:
  https://prometheus.github.io/jmx_exporter/deployment/java-agent/
- Grafana Debian installation:
  https://grafana.com/docs/grafana/latest/setup-grafana/installation/debian/
