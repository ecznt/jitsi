# Fedora Native Jitsi Videobridge Kurulum Guide

Bu guide, Docker/Podman/container kullanmadan Fedora uzerinde Jitsi Videobridge odakli minimum Jitsi Meet test ortamı kurmak icindir. Hedef, production kurulumu degil; JVB performans ve debugging calismalari icin gercek browser/WebRTC trafigi ureten ilk faz lab ortamidir.

## Kapsam

Kurulan bilesenler:

- Prosody
- Jicofo
- Jitsi Videobridge
- Jitsi Meet Web
- Nginx
- Prometheus
- Grafana

Kapsam disi:

- Jibri
- Jigasi
- coturn/TURN
- Etherpad
- recording/livestream
- LDAP/JWT/auth entegrasyonlari
- multi-JVB
- load test
- virtual thread degisiklikleri

## On Kosullar

- Fedora fiziksel sunucu veya fiziksel sunucuya benzer VM.
- Root veya sudo yetkisi.
- Docker, Podman veya container ortaminda calistirmayin.
- Test domaininiz varsa DNS A kaydi bu sunucuya bakmali.
- Domain yoksa `TLS_MODE=selfsigned` ile test edin ve client tarafinda sertifika uyarisini kabul edin.
- 80/tcp, 443/tcp ve 10000/udp portlari hedef test clientlari tarafindan erisilebilir olmali.

## Dosya Yapisi

Kurulum paketi:

```text
fedora-native-jitsi-jvb/
  config.env.example
  README.md
  DELIVERY-CHECKLIST.md
  scripts/
    00-discover.sh
    10-install.sh
    90-verify.sh
  templates/
```

## 1. Paketi Fedora Sunucuya Kopyalayin

Bu repo veya `fedora-native-jitsi-jvb` klasorunu Fedora sunucuya kopyalayin:

```bash
cd /opt
sudo mkdir -p /opt/jitsi-lab
sudo chown "$USER":"$USER" /opt/jitsi-lab
cd /opt/jitsi-lab
```

Repo olarak cektiyseniz:

```bash
git clone <repo-url> jitsi-jvb
cd jitsi-jvb/fedora-native-jitsi-jvb
```

Dosya olarak kopyaladiysaniz:

```bash
cd /opt/jitsi-lab/fedora-native-jitsi-jvb
```

## 2. Konfigurasyon Dosyasini Hazirlayin

```bash
cp config.env.example config.env
vi config.env
```

Minimum duzenlenecek alanlar:

```bash
JITSI_DOMAIN=meet.example.org
TLS_MODE=selfsigned
JVB_HEAP=4g
JICOFO_HEAP=1g
ALLOW_EXISTING_SERVICES=false
```

Gercek domain ve acik 80/443 varsa:

```bash
TLS_MODE=letsencrypt
LE_EMAIL=admin@example.org
```

Domain yoksa self-signed kullanin:

```bash
TLS_MODE=selfsigned
```

## 3. Mevcut Sistemi Kesfedin

Bu adim sistemi degistirmez:

```bash
sudo bash scripts/00-discover.sh
```

Ozellikle sunlari kontrol edin:

- Fedora ve kernel surumu
- SELinux modu
- firewalld durumu
- hostname/domain
- public/private IP
- acik portlar
- mevcut Java surumu
- Java 21 var mi
- Nginx/Apache/Prosody/Grafana/Prometheus calisiyor mu
- production servisi olabilecek aktif process var mi

Aktif ilgili servis varsa installer varsayilan olarak durur. Bu davranisi ancak makinenin lab oldugunu dogruladiktan sonra degistirin:

```bash
ALLOW_EXISTING_SERVICES=true
```

## 4. Kurulumu Calistirin

```bash
sudo bash scripts/10-install.sh ./config.env
```

Installer sunlari yapar:

- Fedora paketlerini kurar.
- `java-21-openjdk-headless` kurar ve default Java olarak Java 21 secmeye calisir.
- Jitsi Debian upstream artifactlerini indirip `/opt/jitsi-native` altina acar.
- Prosody, Jicofo, JVB, Nginx, Prometheus ve Grafana configlerini yazar.
- Jicofo ve JVB icin systemd servisleri olusturur.
- JVB icin G1GC, esit Xms/Xmx ve `/var/log/jitsi/` altinda GC loglarini aktif eder.
- JVB metrics endpointini `http://127.0.0.1:8080/metrics` uzerinden acar.
- Prometheus scrape configine JVB ve Jicofo targetlarini ekler.
- Grafana Prometheus datasource ve ilk faz JVB dashboard'unu provision eder.
- 80/tcp, 443/tcp ve 10000/udp portlarini firewalld uzerinden acar.
- SELinux aciksa gerekli network/http port izinlerini uygular; SELinux'u kapatmaz.

## 5. Otomatik Dogrulama

```bash
sudo bash scripts/90-verify.sh ./config.env
```

Beklenen kontroller:

- `java -version` Java 21 gostermeli.
- Prosody aktif olmali.
- Jicofo aktif olmali.
- JVB aktif olmali.
- Nginx aktif olmali.
- Prometheus aktif olmali.
- Grafana aktif olmali.
- Jicofo process'i Java 21 ile calismali.
- JVB process'i Java 21 ile calismali.
- Jitsi Meet web arayuzu acilmali.
- JVB metrics endpoint cevap vermeli.
- Prometheus `jvb` target'i UP olmali.
- Grafana dashboard provision edilmis olmali.

## 6. Browser Medya Testi

Iki farkli browser veya iki farkli client ile ayni odaya girin:

```text
https://<JITSI_DOMAIN>/jvb-smoke
```

Dogru sonuc:

- Iki client ayni odaya katilir.
- Audio/video izinleri verilir.
- Medya akisi kurulur.
- JVB loglarinda ICE/DTLS/media hatasi gorulmez.

Log kontrolu:

```bash
journalctl -u jitsi-videobridge -u jicofo -u prosody --since -15m --no-pager
```

## 7. Metrik ve Dashboard Kontrolu

JVB metrics:

```bash
curl http://127.0.0.1:8080/metrics
```

Prometheus:

```text
http://127.0.0.1:9090
```

Grafana:

```text
http://<server-ip>:3000
```

Varsayilan admin bilgileri `config.env` dosyasindan gelir:

```bash
GRAFANA_ADMIN_USER=admin
GRAFANA_ADMIN_PASSWORD=admin
```

Paylasimli lab ortaminda bu parolayi degistirin.

Dashboard:

```text
Jitsi / JVB First Phase
```

Dashboard panelleri:

- conferences
- endpoints
- endpoints_sending_video
- largest_conference
- bit_rate_upload
- bit_rate_download
- packet_rate_upload
- packet_rate_download
- stress_level
- total_ice_failed
- total_failed_conferences
- rtt_aggregate
- JVM heap
- JVM thread count
- GC pause/log metrics

## 8. Teslim Ciktisi

Kurulum sonunda su dosyayi doldurun:

```text
DELIVERY-CHECKLIST.md
```

Rapor icin ayrica installer su dosyayi uretir:

```text
/var/log/jitsi/fedora-native-install-report.txt
```

Teslimde bulunmasi gerekenler:

- Kurulum ozeti
- Jitsi/JVB/Jicofo artifact versiyonlari
- Java 21 `java -version` ciktisi
- JVB/Jicofo Java 21 process dogrulamasi
- Degisen onemli config dosyalari
- Systemd servis isimleri
- Acilan portlar
- TLS yontemi
- Grafana URL ve erisim bilgisi
- Prometheus target durumu
- JVB metrics endpoint bilgisi
- Test odasi sonucu
- Gorulen hatalar ve cozumleri
- Java 21 uyumluluk notlari

## 9. Siklikla Kontrol Edilecek Komutlar

Servis durumu:

```bash
systemctl status prosody jicofo jitsi-videobridge nginx prometheus grafana-server
```

JVB log:

```bash
journalctl -u jitsi-videobridge -f
```

Jicofo log:

```bash
journalctl -u jicofo -f
```

Prosody log:

```bash
journalctl -u prosody -f
```

Java process kontrolu:

```bash
pgrep -af 'jicofo|videobridge'
```

Port kontrolu:

```bash
ss -tulpen
```

Firewall:

```bash
firewall-cmd --list-all
```

Siyah ekran / web asset kontrolu:

```bash
for f in config.js interface_config.js logging_config.js; do
  echo "== $f =="
  curl -k --resolve meet.example.org:443:127.0.0.1 https://meet.example.org/$f | head
done
```

Bu dosyalardan herhangi biri HTML (`<!doctype html>` veya `<html>`) donduruyorsa Nginx/Jitsi Meet web config yanlistir. Installer `config.js`,
`interface_config.js` ve `logging_config.js` dosyalarini `/etc/jitsi/meet/`
altinda uretir ve Nginx uzerinden dogrudan servis eder.

Browser tarafinda hala siyah ekran varsa Developer Tools Console sekmesini acin
ve ilk kirmizi JavaScript hatasini kontrol edin.

Su hata gorulurse `index.html` interface config dosyasini yuklemiyor demektir:

```text
Uncaught ReferenceError: interfaceConfig is not defined
```

Installer `index.html` icine `interface_config.js` ve `logging_config.js`
scriptlerini app bundle'dan once ekler. Guncelleme sonrasi installer'i tekrar
calistirin ve Nginx'i restart edin.
Ek olarak `config.js` icine de `var interfaceConfig` yazilir; boylece Jitsi
Meet bundle hangi index sirasiyla yuklenirse yuklensin global interface config
mevcut olur.
Guncel installer ayrica `index.html` icinde gercek
`<script src="libs/app.bundle...">` satirindan hemen once `window.interfaceConfig`
ve `var interfaceConfig` tanimlayan inline bir shim ekler. Bu, bundle calismadan
once global degiskenin kesin olarak hazir olmasini saglar.

Su hata gorulurse script tag yanlislikla JavaScript blogunun icine girmis
demektir:

```text
Uncaught SyntaxError: expected expression, got '<'
```

Guncel installer once eski hatali script tag satirlarini temizler, sonra
scriptleri yalnizca `</head>` oncesine ekler.

## 10. Faz 2 Notlari

Bu fazda load test ve tuning yapilmaz. Sonraki faz icin adaylar:

- jitsi-meet-torture veya sentetik browser client
- UDP/NIC/kernel tuning
- JVB `stress_level` takibi
- Java 21 uzerinde G1GC/ZGC karsilastirmasi
- multi-JVB mimarisi
