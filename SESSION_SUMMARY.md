# Jitsi JVB Session Handoff

Bu dosya, sonraki Codex session'inin mevcut calismaya guvenli bicimde devam
edebilmesi icin teknik durum ozetidir. Kimlik bilgileri bilerek dahil
edilmemistir.

## 1. Repository ve kapsam

- Repository: `https://github.com/ecznt/jitsi.git`
- Aktif branch: `develop`
- Fedora lab projesi: `fedora-native-jitsi-jvb/`
- Debian production kurulumu: `DEBIAN_PRODUCTION_JVB_GUIDE.md`
- Production sorumluluk siniri yalnizca JVB ve ayni makinedeki monitoring
  katmanidir. Uzak makinede calisan Jitsi client bu kapsama dahil degildir.
- `toy-toplanti` upstream kaynak koduna kalici degisiklik yapilmamasi istendi.
  Fedora reposundaki build/deploy scriptleri istemciyi ayri bir kaynaktan
  derlemek icindir.

## 2. Son dogrulanan Fedora lab ortami

- Ortam: VMware uzerinde Fedora 43 Workstation
- VM adresi: `192.168.10.132`
- VM kapasitesi: yaklasik 15 GiB RAM, 8 GiB swap
- VM repository yolu:
  `/home/ecz/Desktop/Projects/jitsi/jitsi/fedora-native-jitsi-jvb`
- Domain: `meet.example.org`
- Client DNS/hosts kaydi bu domaini `192.168.10.132` adresine cozmelidir.
- Windows tarafindan DNS override ile HTTPS endpoint'i `HTTP 200` dondu.
- VMware time synchronization etkinlestirildi. Lab ortaminda chrony kaynagi
  erisilemezse bu bir fallback'tir; production'da calisan NTP kullanilmalidir.

Son canli kontrolde asagidaki servislerin tamami `active` durumdaydi:

- `prosody`
- `jicofo`
- `jitsi-videobridge`
- `nginx`
- `prometheus`
- `node-exporter`
- `grafana-server`

Prometheus target durumlari:

- `jicofo`: `up`
- `jvb`: `up`
- `jvb-jmx`: `up`
- `node`: `up`
- `prometheus`: `up`

Jicofo, JVB `2.3.92-g64f9f34f` bridge'ini MUC icinde kesfetti ve health-check
gorevini baslatti. Yeniden baslatma sonrasinda yeni bir Jicofo health timeout
gorulmedi.

## 3. Fedora lab JVB profili

Fedora VM'in RAM kapasitesi nedeniyle production'daki 384 GiB hard heap limiti
bu makineye uygulanmadi. Lab profili:

```text
Java: OpenJDK 21
Collector: Generational ZGC
Xms: 8g
Xmx: 8g
AlwaysPreTouch: enabled
Global lastN: 16
JFR: enabled, max age 2h, max size 1g
GC/safepoint logs: enabled, 10 x 100 MiB rotation
Heap dump on OOM: enabled
Exit on OOM: enabled
JMX exporter: 127.0.0.1:9404
```

Secim, takip edilmeyen yerel `config.env` dosyasinda su degerlerle yapildi:

```bash
JVB_PROFILE_FILE=profiles/jvb-zgc-120.env
JVB_HEAP=8g
JVB_GC_PROFILE=zgc
JVB_LAST_N=16
JITSI_DOMAIN=meet.example.org
```

Ilgili repository dosyalari:

- `fedora-native-jitsi-jvb/profiles/jvb-zgc-120.env`
- `fedora-native-jitsi-jvb/scripts/70-apply-jvb-jvm-profile.sh`
- `fedora-native-jitsi-jvb/scripts/75-apply-jvb-last-n.sh`
- `fedora-native-jitsi-jvb/templates/jitsi-videobridge.service`
- `fedora-native-jitsi-jvb/templates/jvb.conf.tpl`

`/etc/jitsi/videobridge/jvb.conf` icinde RTP/RTCP transit-time Prometheus
metric toplama aciktir. Histogram serileri aktif medya paketi gelmeden
olusturulmayabilir.

## 4. Monitoring ve Grafana

Fedora monitoring kurulumu:

```bash
sudo bash scripts/60-install-monitoring.sh ./config.env
sudo bash scripts/90-verify.sh ./config.env
```

Son calistirmada `90-verify.sh` basariyla tamamlandi. Yerel endpointler:

| Bilesen | Endpoint |
| --- | --- |
| JVB application metrics | `127.0.0.1:8080/metrics` |
| JVB JVM/JMX metrics | `127.0.0.1:9404/metrics` |
| Node Exporter | `127.0.0.1:9100/metrics` |
| Prometheus | `127.0.0.1:9090` |
| Grafana | `127.0.0.1:3000` |

Lab agindan kullanilan Grafana adresi:
`http://192.168.10.132:3000`

Dashboard kaynagi:
`fedora-native-jitsi-jvb/templates/grafana-dashboard-jvb.json`

Dashboard su alanlari kapsar:

- Active conferences ve endpoints
- ICE/DTLS/disconnect hatalari
- RTP/RTCP transit P50/P95/P99
- Packet rate ve network bitrate
- UDP/network drop ve error
- Data channel ve Colibri WebSocket mesajlari
- JVM heap, buffer pool, GC, thread ve file descriptor
- JVB process CPU
- Host CPU, load, memory, swap, disk ve systemd durumu

### Metric yorumlama notlari

- `JVB Process CPU` sorgusu:

  ```promql
  100 * rate(process_cpu_seconds_total{job="jvb-jmx"}[5m])
  ```

  Burada `%100` bir tam CPU core'u ifade eder. 8 vCPU hostta `%800` butun
  core'larin teorik toplamidir. Host yuzdesi icin core sayisina bolunmelidir.
- `process_cpu_seconds_total`, packet/byte `_total`, histogram `_count`, `_sum`
  ve `_bucket` ham counter'lari proses calistikca artar. Dashboard'da bunlar
  `rate()` veya `increase()` ile yorumlanmalidir.
- Grafana legend'indeki `Max`, secili zaman araligindaki maksimum oldugu icin
  yalnizca artiyormus gibi gorunebilir. Anlik durum icin `Last` kullanilmalidir.
- Dashboard'daki `average GC pause`, JMX collection toplam suresi/sayisi
  oranidir. ZGC'de bunu dogrudan stop-the-world pause olarak yorumlamayin;
  gercek pause ve safepoint analizi GC logu/JFR ile yapilmalidir.
- Katilimci sayisi sabit olsa bile kamera durumu, simulcast layer, bitrate,
  packet rate, NACK/RTX ve ekran paylasimi degisebildigi icin JVB CPU degisebilir.
- Endpoint sayisi ile OS thread sayisi bire bir degildir.

## 5. Process ve thread modeli

Konferans veya katilimci basina yeni Linux prosesi acilmaz. Tek JVB prosesi
butun konferanslari ortak executor ve IO thread havuzlariyla tasir.

Son canli ornekte yaklasik thread sayilari:

| Process | Thread |
| --- | ---: |
| JVB Java | 98 |
| Jicofo Java | 48 |
| Prometheus | 14 |
| Grafana | 14 |
| Node Exporter | 7 |

JVB thread gruplari arasinda ZGC worker/driver threadleri, JVM runtime ve JIT,
JFR, Jetty, Smack/XMPP, ice4j/UDP, SCTP ve Jitsi media IO havuzlari bulunur.
Katilimcilar sabitlendikten sonra thread sayisinin genel olarak plato yapmasi
beklenir. Process/thread `TIME` degerlerinin artmasi normaldir; `%CPU`, RSS,
thread ve FD sayisinin aciklanamayan sekilde surekli artmasi incelenmelidir.

Canli inceleme:

```bash
PID=$(pgrep -f org.jitsi.videobridge.MainKt)
sudo top -H -p "${PID}"
ps -o pid,nlwp,%cpu,%mem,rss,etime -p "${PID}"
```

ZGC nedeniyle `VIRT` cok buyuk gorunebilir; bu fiziksel RAM kullanimi degildir.
Labda `Xms=8g` ve `AlwaysPreTouch` nedeniyle RSS'nin yaklasik 8 GiB'dan
baslamasi normaldir.

## 6. Debian production hedefi

Production makine Debian'dir ve client ayri bir makinede calismaktadir. Tam
kurulum akisi `DEBIAN_PRODUCTION_JVB_GUIDE.md` icindedir. Kesinlestirilen JVM
profili:

```text
Java: OpenJDK 21
Collector: Generational ZGC
Xms: 8g
SoftMaxHeapSize: 32g
Xmx: 393216m (384 GiB hard ceiling)
lastN: 16
GC/safepoint logs: enabled and rotated
JFR: enabled, rolling 2h/1g
JMX exporter: enabled
Grafana + Prometheus + Node Exporter: same JVB host
```

Bu production profili 512 GiB sinifi host varsayimiyla yazildi. `Xmx=393216m`
JVM baslarken 384 GiB fiziksel RAM'in tamamini ayirmaz; ZGC allocation baskisi
altinda bu hard limite kadar buyuyebilir. Profil, 120 katilimciyi tek basina
garanti etmez; gercek medya senaryosuyla kapasite testi gerekir.

Production'da monitoring portlarini internete acmayin. Loopback/monitoring VLAN,
firewall ve SSH tunnel veya kurum reverse proxy kullanin. JVB media icin gerekli
public UDP erisimi guide'daki port tablosuna gore acilmalidir.

## 7. Sonraki session icin hizli baslangic

1. `git status --short --branch` ile temiz `develop` branch'ini dogrulayin.
2. Fedora lab hedefleniyorsa once VM kapasitesini ve yerel `config.env` dosyasini
   okuyun; 384 GiB production profilini lab VM'e uygulamayin.
3. Servisleri kontrol edin:

   ```bash
   systemctl is-active prosody jicofo jitsi-videobridge nginx \
     prometheus node-exporter grafana-server
   ```

4. Tam Fedora dogrulamasi:

   ```bash
   cd /home/ecz/Desktop/Projects/jitsi/jitsi/fedora-native-jitsi-jvb
   sudo bash scripts/90-verify.sh ./config.env
   ```

5. Prometheus targetlarini kontrol edin:

   ```bash
   curl -fsS http://127.0.0.1:9090/api/v1/targets \
     | jq -r '.data.activeTargets[] | [.labels.job,.health,.lastError] | @tsv'
   ```

6. Gercek medya dogrulamasi icin en az iki client ile ayni konferansa girin.
   Active endpoint/conference, packet rate, bitrate ve transit histogramlarini
   birlikte kontrol edin.
7. Production Debian kurulumu yapilacaksa Fedora scriptlerini calistirmak yerine
   `DEBIAN_PRODUCTION_JVB_GUIDE.md` dosyasini bastan sona izleyin.

## 8. Bilinen acik noktalar ve riskler

- Fedora lab ile Debian production ayni makine veya ayni heap profili degildir.
- RTP/RTCP transit histogramlari yalnizca gercek RTP/RTCP trafik varken kesin
  olarak dogrulanabilir.
- Client DNS'i `meet.example.org` alan adini VM'e cozmezse browser baglanamaz;
  bu durumda servisler saglikli olsa bile `ERR_NAME_NOT_RESOLVED` gorulur.
- Fedora lab JVB XMPP sertifika dogrulamasinin kapali olduguna dair warning
  uretiyor. Bu lab kolayligidir; production'da guvenilir CA ve sertifika
  dogrulamasi kullanilmalidir.
- CPU kapasite karari katilimci sayisiyla tek basina verilmemelidir. Endpoint,
  packets/s, bitrate, NACK/RTX, UDP drop, transit P99, GC ve CPU birlikte
  degerlendirilmelidir.
- Sentetik yuk modulunun kurulmasi daha once iptal edildi; repository'de aktif
  bir sentetik katilimci yuk sistemi oldugu varsayilmamalidir.
