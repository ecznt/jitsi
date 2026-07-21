# İki JVB için üç Grafana dashboard'ı — production copy-paste guide

Bu guide yalnızca aşağıdaki üç yeni dashboard'ın iki JVB için kurulmasını kapsar:

| Dashboard | UID | Davranış |
|---|---|---|
| JVB Multi-Node Capacity and Bottleneck Analysis | `jvb-capacity-bottleneck-multinode` | `jvb-1` veya `jvb-2` seçilir |
| JVB Multi-Node Thread, Lock and Stall Forensics | `jvb-thread-stall-multinode` | `jvb-1` veya `jvb-2` seçilir |
| JVB Fleet and Application Overview | `jvb-fleet-application-overview` | İki JVB ve uygulama toplamları aynı anda gösterilir |

Mevcut tek-node dashboard'lar silinmez ve overwrite edilmez:

- `jvb-48core-capacity`
- `jvb-thread-stall-forensics`

Alert, Alertmanager, watchdog ve JFR kurulumu bu guide'ın dışındadır. Kurulum scripti çalıştırılmayacaktır. Komutlar sırayla, tek tek uygulanmalıdır.

## 1. Mimari ve zorunlu etiket

Prometheus üç job altında iki JVB'yi scrape etmelidir:

| Job | JVB-1 | JVB-2 |
|---|---|---|
| `jvb` | port 8080 | port 8080 |
| `jvb-jmx` | port 9404 | port 9404 |
| `node` | port 9100 | port 9100 |

Her target aşağıdaki sabit etiketi taşımalıdır:

```yaml
jvb_node: jvb-1
```

veya:

```yaml
jvb_node: jvb-2
```

`instance` etiketi fiziksel JVB kimliği olarak kullanılmaz. Üç farklı port üç farklı `instance` üretebilir. Dashboard'lar job'ları `jvb_node` üzerinden eşleştirir.

## 2. Production değişkenlerini hazırla

Bu komutları Prometheus ve Grafana'nın çalıştığı merkezi monitoring makinesinde uygula.

```bash
export JVB1_IP='REPLACE_WITH_JVB1_PRIVATE_IP'
export JVB2_IP='REPLACE_WITH_JVB2_PRIVATE_IP'
export PROMETHEUS_URL='http://127.0.0.1:9093'
export GRAFANA_URL='http://REPLACE_WITH_GRAFANA_IP:3000'
```

Değerleri göster:

```bash
printf 'JVB1_IP=%s\nJVB2_IP=%s\nPROMETHEUS_URL=%s\nGRAFANA_URL=%s\n' \
  "$JVB1_IP" "$JVB2_IP" "$PROMETHEUS_URL" "$GRAFANA_URL"
```

Beklenen örnek:

```text
JVB1_IP=10.10.10.11
JVB2_IP=10.10.10.12
PROMETHEUS_URL=http://127.0.0.1:9093
GRAFANA_URL=http://10.10.10.20:3000
```

**Devam etme koşulu:** Çıktıda `REPLACE_WITH` veya boş değer kalmamalıdır.

Kontrol:

```bash
printf '%s\n' "$JVB1_IP" "$JVB2_IP" "$GRAFANA_URL" | grep -n 'REPLACE_WITH' || true
```

Beklenen: çıktı yok.

## 3. Merkezi servisleri ve doğrulanmış portları kontrol et

```bash
systemctl is-active prometheus.service
systemctl is-active grafana-server.service
```

Beklenen:

```text
active
active
```

Prometheus:

```bash
curl -fsS --max-time 5 "$PROMETHEUS_URL/-/ready"
```

Beklenen:

```text
Prometheus Server is Ready.
```

Grafana:

```bash
curl -fsS --max-time 5 "$GRAFANA_URL/api/health" | jq '{database,version,commit}'
```

Beklenen örnek:

```json
{
  "database": "ok",
  "version": "13.1.0",
  "commit": "..."
}
```

**Devam etme koşulu:** Prometheus ready olmalı ve Grafana `database: ok` dönmelidir.

Sorun halinde yalnızca teşhis:

```bash
sudo systemctl status prometheus.service grafana-server.service --no-pager -l
sudo ss -H -lntp | grep -E ':(9093|3000)[[:space:]]'
```

## 4. Her JVB'deki exporter'ları yerel olarak doğrula

Önce JVB-1'e SSH ile bağlan:

```bash
systemctl is-active jitsi-videobridge2.service
systemctl is-active prometheus-node-exporter.service
sudo ss -H -lntup | grep -E ':(8080|9404|9100)[[:space:]]'
curl -fsS --max-time 5 http://127.0.0.1:8080/about/health -o /dev/null -w 'JVB health HTTP %{http_code}\n'
curl -fsS --max-time 5 http://127.0.0.1:9404/metrics | grep -m1 '^jmx_exporter_build_info'
curl -fsS --max-time 5 http://127.0.0.1:9100/metrics | grep -m1 '^node_exporter_build_info'
```

Beklenen:

- İki servis de `active`.
- 8080 ve 9404 JVB Java process'ine, 9100 Node Exporter'a ait.
- JVB health sonucu `HTTP 200`.
- JMX ve Node Exporter birer build-info metriği döndürür.

Sonuçlardan biri başarısızsa:

```bash
sudo systemctl status jitsi-videobridge2.service prometheus-node-exporter.service --no-pager -l
sudo journalctl -u jitsi-videobridge2.service -n 50 --no-pager
```

JVB-2'ye SSH ile bağlanıp aynı komutları tekrar çalıştır. İki JVB yerel kontrolleri tamamlanmadan devam etme.

## 5. Merkezi Prometheus'tan iki JVB'ye erişimi doğrula

```bash
curl -fsS --max-time 5 "http://$JVB1_IP:8080/about/health" -o /dev/null -w 'JVB1 health HTTP %{http_code}\n'
curl -fsS --max-time 5 "http://$JVB1_IP:9404/metrics" | grep -m1 '^jmx_exporter_build_info'
curl -fsS --max-time 5 "http://$JVB1_IP:9100/metrics" | grep -m1 '^node_exporter_build_info'
curl -fsS --max-time 5 "http://$JVB2_IP:8080/about/health" -o /dev/null -w 'JVB2 health HTTP %{http_code}\n'
curl -fsS --max-time 5 "http://$JVB2_IP:9404/metrics" | grep -m1 '^jmx_exporter_build_info'
curl -fsS --max-time 5 "http://$JVB2_IP:9100/metrics" | grep -m1 '^node_exporter_build_info'
```

Beklenen:

- JVB1 ve JVB2 health: `HTTP 200`
- İki JMX build-info satırı
- İki Node Exporter build-info satırı

**Devam etme koşulu:** Altı endpoint de merkezi Prometheus makinesinden erişilebilir olmalıdır.

Bağlantı reddedilirse ilgili JVB'de:

```bash
sudo ss -H -lntup | grep -E ':(8080|9404|9100)[[:space:]]'
sudo systemctl cat jitsi-videobridge2.service
sudo systemctl cat prometheus-node-exporter.service
```

`127.0.0.1:PORT` görülüyorsa endpoint yalnızca yerelden erişilebilir. Prometheus JVB-1 üzerinde çalışıyorsa JVB-1 target'larında `127.0.0.1` kullanılabilir; JVB-2 endpoint'leri ise Prometheus'un erişebildiği private IP'ye bind edilmelidir. Bind değişikliği gerekiyorsa aktif konferansları diğer JVB'ye drain etmeden JVB restart etme.

## 6. Gerçek Prometheus config yolunu bul

Önce service komut satırını gör:

```bash
sudo systemctl show prometheus.service -p ExecStart --value
```

Beklenen örnek parça:

```text
--config.file=/etc/prometheus/prometheus.yml
```

Yolu otomatik çıkarmayı dene:

```bash
export PROM_CONFIG="$(sudo systemctl show prometheus.service -p ExecStart --value \
  | grep -oE -- '--config.file(=| )[^ ;}]+' \
  | head -n 1 \
  | sed -E 's/^--config.file(=| )//')"
printf 'PROM_CONFIG=<%s>\n' "$PROM_CONFIG"
```

Beklenen örnek:

```text
PROM_CONFIG=</etc/prometheus/prometheus.yml>
```

Önceki terminalde yaşanan `PROM_CONFIG` boş problemi için zorunlu kontrol:

```bash
test -n "$PROM_CONFIG" && echo 'PROM_CONFIG_NOT_EMPTY=PASS' || echo 'PROM_CONFIG_NOT_EMPTY=FAIL'
sudo test -s "$PROM_CONFIG" && echo 'PROM_CONFIG_FILE=PASS' || echo 'PROM_CONFIG_FILE=FAIL'
```

Beklenen:

```text
PROM_CONFIG_NOT_EMPTY=PASS
PROM_CONFIG_FILE=PASS
```

**Devam etme koşulu:** İki sonuç da `PASS` olmalıdır.

`FAIL` gelirse otomatik sonucu kullanma. İlk komutun çıktısındaki gerçek yolu elle ata:

```bash
export PROM_CONFIG='/REPLACE_WITH_REAL_CONFIG_PATH/prometheus.yml'
```

Ardından iki PASS kontrolünü yeniden çalıştır.

## 7. Timestamp'li config backup oluştur

```bash
export BACKUP="/root/jvb-two-node-dashboards-$(date -u +%Y%m%dT%H%M%SZ)"
sudo install -d -m 0700 "$BACKUP"
sudo cp -a "$PROM_CONFIG" "$BACKUP/prometheus.yml.before"
sudo test -s "$BACKUP/prometheus.yml.before" && echo 'BACKUP=PASS' || echo 'BACKUP=FAIL'
sudo stat -c 'path=%n size=%s bytes mode=%a owner=%U:%G' "$BACKUP/prometheus.yml.before"
```

Beklenen:

- `BACKUP=PASS`
- `size` sıfırdan büyük
- Yol `/root/jvb-two-node-dashboards-...` altında

**Devam etme koşulu:** Backup boşsa config'i düzenleme.

## 8. Mevcut scrape job'larını incele

```bash
sudo grep -nE 'job_name:|targets:|jvb_node:' "$PROM_CONFIG"
```

Beklenen: mevcut `jvb`, `jvb-jmx` ve `node` job'ları görünmelidir.

Aynı isimle yeni job eklenmeyecek. Var olan üç job düzenlenecektir:

```bash
sudoedit "$PROM_CONFIG"
```

Hedef yapı:

```yaml
scrape_configs:
  - job_name: jvb
    metrics_path: /metrics
    static_configs:
      - targets: ['JVB1_SCRAPE_ADDRESS:8080']
        labels:
          jvb_node: jvb-1
      - targets: ['JVB2_SCRAPE_ADDRESS:8080']
        labels:
          jvb_node: jvb-2

  - job_name: jvb-jmx
    metrics_path: /metrics
    static_configs:
      - targets: ['JVB1_SCRAPE_ADDRESS:9404']
        labels:
          jvb_node: jvb-1
      - targets: ['JVB2_SCRAPE_ADDRESS:9404']
        labels:
          jvb_node: jvb-2

  - job_name: node
    metrics_path: /metrics
    static_configs:
      - targets: ['JVB1_SCRAPE_ADDRESS:9100']
        labels:
          jvb_node: jvb-1
      - targets: ['JVB2_SCRAPE_ADDRESS:9100']
        labels:
          jvb_node: jvb-2
```

Kurallar:

- `JVB1_SCRAPE_ADDRESS` ve `JVB2_SCRAPE_ADDRESS` metinlerini gerçek adreslerle değiştir.
- Prometheus JVB-1 üzerinde ve JVB-1 exporter'ları loopback'taysa JVB-1 için `127.0.0.1` kullanılabilir.
- JVB-2 için Prometheus'un erişebildiği private IP kullanılmalıdır.
- Var olan `scrape_interval`, `scrape_timeout`, TLS ve authentication ayarlarını koru.
- Var olan diğer job'lara dokunma.
- Eski statik `instance` etiketi iki target'ta aynı değerse kaldır veya node bazında benzersiz yap. Dashboard kimliği için yine `jvb_node` kullanılacaktır.

## 9. Config diff ve promtool kontrolü

```bash
sudo diff -u "$BACKUP/prometheus.yml.before" "$PROM_CONFIG" || true
```

Beklenen: yalnızca `jvb`, `jvb-jmx` ve `node` target/label satırları değişmelidir.

Beklenmeyen başka job veya global ayar değişikliği görürsen devam etme.

```bash
sudo promtool check config "$PROM_CONFIG"
```

Beklenen son satır:

```text
SUCCESS
```

Başarısızsa reload yapma:

```bash
sudo promtool check config "$PROM_CONFIG"
sudo diff -u "$BACKUP/prometheus.yml.before" "$PROM_CONFIG" || true
```

## 10. Prometheus'u reload et

```bash
sudo systemctl reload prometheus.service
curl -fsS --max-time 5 "$PROMETHEUS_URL/-/ready"
```

Beklenen:

```text
Prometheus Server is Ready.
```

Reload/ready başarısızsa:

```bash
sudo systemctl status prometheus.service --no-pager -l
sudo journalctl -u prometheus.service --since '-5 minutes' --no-pager
```

## 11. Altı target'ı ve etiketleri doğrula

```bash
curl -fsSG "$PROMETHEUS_URL/api/v1/query" \
  --data-urlencode 'query=up{job=~"jvb|jvb-jmx|node"}' \
  | jq -r '.data.result[] | [.metric.job,.metric.jvb_node,.metric.instance,.value[1]] | @tsv' \
  | sort
```

Beklenen örnek:

```text
jvb       jvb-1  ...:8080  1
jvb       jvb-2  ...:8080  1
jvb-jmx   jvb-1  ...:9404  1
jvb-jmx   jvb-2  ...:9404  1
node      jvb-1  ...:9100  1
node      jvb-2  ...:9100  1
```

**Devam etme koşulu:** Tam olarak altı satır olmalı; her satırın son değeri `1` olmalı.

Kombinasyon sayısı:

```bash
curl -fsSG "$PROMETHEUS_URL/api/v1/query" \
  --data-urlencode 'query=count by (job,jvb_node) (up{job=~"jvb|jvb-jmx|node"})' \
  | jq -r '.data.result[] | [.metric.job,.metric.jvb_node,.value[1]] | @tsv' \
  | sort
```

Beklenen: altı `job + jvb_node` kombinasyonu ve her birinde değer `1`.

Dashboard temel metrikleri:

```bash
curl -fsSG "$PROMETHEUS_URL/api/v1/query" \
  --data-urlencode 'query=sum by (jvb_node) (jvm_threads_current{job="jvb-jmx"})' \
  | jq -r '.data.result[] | [.metric.jvb_node,.value[1]] | @tsv'
```

Beklenen: `jvb-1` ve `jvb-2` için iki ayrı satır.

```bash
curl -fsSG "$PROMETHEUS_URL/api/v1/query" \
  --data-urlencode 'query=sum by (jvb_node) (jitsi_jvb_local_endpoints{job="jvb"})' \
  | jq -r '.data.result[] | [.metric.jvb_node,.value[1]] | @tsv'
```

Beklenen: `jvb-1` ve `jvb-2` için iki ayrı satır.

Bir node eksikse:

```bash
curl -fsS "$PROMETHEUS_URL/api/v1/targets" \
  | jq -r '.data.activeTargets[] | select(.labels.job|test("^(jvb|jvb-jmx|node)$")) | [.labels.job,.labels.jvb_node,.scrapeUrl,.health,.lastError] | @tsv'
```

## 12. Üç JSON dosyasını sunucuya elle koy

Yerel repository'den aşağıdaki dosyaları al:

1. `fedora-native-jitsi-jvb/templates/grafana-dashboard-jvb-capacity-multinode.json`
2. `fedora-native-jitsi-jvb/templates/grafana-dashboard-jvb-thread-forensics-multinode.json`
3. `fedora-native-jitsi-jvb/templates/grafana-dashboard-jvb-fleet-overview.json`

Sunucuda önerilen adlar:

```text
/tmp/grafana-dashboard-jvb-capacity-multinode.json
/tmp/grafana-dashboard-jvb-thread-forensics-multinode.json
/tmp/grafana-dashboard-jvb-fleet-overview.json
```

Dosyaları sen elle aktardıktan sonra:

```bash
export CAPACITY_JSON='/tmp/grafana-dashboard-jvb-capacity-multinode.json'
export THREAD_JSON='/tmp/grafana-dashboard-jvb-thread-forensics-multinode.json'
export FLEET_JSON='/tmp/grafana-dashboard-jvb-fleet-overview.json'
```

Dosya kontrolü:

```bash
for file in "$CAPACITY_JSON" "$THREAD_JSON" "$FLEET_JSON"; do
  test -s "$file" && printf 'PASS %s\n' "$file" || printf 'FAIL %s\n' "$file"
done
```

Beklenen: üç satırın tamamı `PASS`.

JSON doğrulaması:

```bash
jq empty "$CAPACITY_JSON" && echo 'CAPACITY_JSON=PASS'
jq empty "$THREAD_JSON" && echo 'THREAD_JSON=PASS'
jq empty "$FLEET_JSON" && echo 'FLEET_JSON=PASS'
```

Beklenen:

```text
CAPACITY_JSON=PASS
THREAD_JSON=PASS
FLEET_JSON=PASS
```

Başlık ve UID:

```bash
for file in "$CAPACITY_JSON" "$THREAD_JSON" "$FLEET_JSON"; do
  jq -r '[.title,.uid] | @tsv' "$file"
done
```

Beklenen:

```text
JVB Multi-Node Capacity and Bottleneck Analysis    jvb-capacity-bottleneck-multinode
JVB Multi-Node Thread, Lock and Stall Forensics   jvb-thread-stall-multinode
JVB Fleet and Application Overview                jvb-fleet-application-overview
```

UID farklıysa veya aynı UID iki dosyada görünüyorsa import etme.

## 13. Capacity dashboard'ını import et

Grafana arayüzünde:

1. **Dashboards > New > Import** aç.
2. `grafana-dashboard-jvb-capacity-multinode.json` dosyasını yükle.
3. Prometheus datasource'u seç.
4. Başlığı kontrol et:
   - `JVB Multi-Node Capacity and Bottleneck Analysis`
5. UID'yi kontrol et:
   - `jvb-capacity-bottleneck-multinode`
6. **Import** seç.

**Durma koşulu:** Grafana mevcut bir dashboard'ı overwrite edeceğini söylüyorsa import'u iptal et. Eski `jvb-48core-capacity` UID'si overwrite edilmemelidir.

Import sonrası:

- Üstte `JVB node` seçicisi görünmeli.
- Seçenekler `jvb-1` ve `jvb-2` olmalı.
- `All` seçeneği olmamalı.

## 14. Thread dashboard'ını import et

Grafana arayüzünde:

1. **Dashboards > New > Import** aç.
2. `grafana-dashboard-jvb-thread-forensics-multinode.json` dosyasını yükle.
3. Prometheus datasource'u seç.
4. Başlığı kontrol et:
   - `JVB Multi-Node Thread, Lock and Stall Forensics`
5. UID'yi kontrol et:
   - `jvb-thread-stall-multinode`
6. **Import** seç.

**Durma koşulu:** Eski `jvb-thread-stall-forensics` dashboard'ı için overwrite uyarısı çıkmamalıdır.

Import sonrası:

- `JVB node` seçicisi görünmeli.
- `jvb-1` ve `jvb-2` ayrı seçilebilmeli.
- `All` seçeneği olmamalı.

## 15. Fleet/Application Overview dashboard'ını import et

Grafana arayüzünde:

1. **Dashboards > New > Import** aç.
2. `grafana-dashboard-jvb-fleet-overview.json` dosyasını yükle.
3. Prometheus datasource'u seç.
4. Başlığı kontrol et:
   - `JVB Fleet and Application Overview`
5. UID'yi kontrol et:
   - `jvb-fleet-application-overview`
6. **Import** seç.

Fleet dashboard'da `jvb_node` seçicisi olmaması doğrudur. Bu dashboard her zaman iki node'u ve uygulama toplamlarını birlikte gösterir.

## 16. Capacity node izolasyonunu doğrula

Capacity dashboard'da:

1. `jvb-1` seç.
2. Host CPU, JVB CPU, stress, endpoints, network ve JVM panellerini gözle.
3. Aynı zaman aralığında `jvb-2` seç.
4. Değerlerin seçilen node'a göre değiştiğini doğrula.

Prometheus referans sorgusu:

```bash
curl -fsSG "$PROMETHEUS_URL/api/v1/query" \
  --data-urlencode 'query=100 * sum by (jvb_node) (rate(process_cpu_seconds_total{job="jvb-jmx"}[1m])) / count by (jvb_node) (node_cpu_seconds_total{job="node",mode="idle"})' \
  | jq -r '.data.result[] | [.metric.jvb_node,.value[1]] | @tsv'
```

Beklenen: iki node için ayrı CPU yüzdesi.

## 17. Thread node izolasyonunu doğrula

Thread dashboard'da:

1. `jvb-1` seç.
2. Current, daemon, peak, BLOCKED ve deadlocked değerlerini gözle.
3. `jvb-2` seç.
4. Panellerin yalnızca seçilen JVM'yi gösterdiğini doğrula.

Prometheus referans sorgusu:

```bash
curl -fsSG "$PROMETHEUS_URL/api/v1/query" \
  --data-urlencode 'query=sum by (jvb_node) (jvm_threads_state{job="jvb-jmx",state=~"BLOCKED|blocked"})' \
  | jq -r '.data.result[] | [.metric.jvb_node,.value[1]] | @tsv'
```

Beklenen: mevcutsa her node için ayrı BLOCKED değeri. Hiç BLOCKED thread yoksa exporter davranışına göre boş sonuç veya sıfır görülebilir.

## 18. Fleet toplamlarını ve node kaynağını doğrula

Fleet dashboard'da:

- **Running JVBs / 2** normal durumda `2`.
- Total Conferences iki node toplamı.
- Total Endpoints iki node toplamı.
- Fleet CPU Cores Used iki JVM toplamı.
- Fleet CPU / Total Capacity iki hostun ağırlıklı toplam yüzdesi.
- Worst JVB CPU / Capacity en yoğun node'u gösterir.
- Worst JVB Stress en yüksek stress değerini gösterir.
- Total JVM Threads iki JVM thread toplamıdır.
- Thread ve kapasite zaman serilerinde `jvb-1` ile `jvb-2` ayrı legend olarak görünür.

Thread toplamını elle karşılaştır:

```bash
curl -fsSG "$PROMETHEUS_URL/api/v1/query" \
  --data-urlencode 'query=sum(jvm_threads_current{job="jvb-jmx"})' \
  | jq -r '.data.result[0].value[1]'
```

Node kırılımı:

```bash
curl -fsSG "$PROMETHEUS_URL/api/v1/query" \
  --data-urlencode 'query=sum by (jvb_node) (jvm_threads_current{job="jvb-jmx"})' \
  | jq -r '.data.result[] | [.metric.jvb_node,.value[1]] | @tsv'
```

Beklenen: node kırılımındaki iki değerin toplamı Fleet dashboard'daki Total JVM Threads değerine eşit olmalıdır.

Sorun kaynağı testi:

- Fleet dashboard'da **BLOCKED and Deadlocked by Node** panelini aç.
- Legend içinde `jvb-1 BLOCKED`, `jvb-2 BLOCKED`, `jvb-1 deadlocked`, `jvb-2 deadlocked` serileri bulunmalıdır.
- Bir seri üzerinde data link açıldığında Thread dashboard doğru `var-jvb_node` değeriyle açılmalıdır.
- CPU, stress veya network serisindeki data link Capacity dashboard'ını doğru node seçili olarak açmalıdır.

## 19. Bir node down senaryosunun beklenen görünümü

Gerçek servisi durdurarak test yapmak zorunlu değildir.

Normal durumda:

```bash
curl -fsSG "$PROMETHEUS_URL/api/v1/query" \
  --data-urlencode 'query=sum(max by (jvb_node) (up{job="jvb"}))' \
  | jq -r '.data.result[0].value[1]'
```

Beklenen: `2`.

Bir JVB scrape edilemezse beklenen Fleet davranışı:

- Running JVBs / 2 değeri `1`.
- Availability by Node panelinde ilgili node `0`.
- Diğer node'un değerleri görünmeye devam eder.
- Detail dashboard'da down node seçildiğinde paneller `No data` gösterebilir.

## 20. Mevcut tek-node dashboard'ların korunduğunu doğrula

Grafana arayüzünde aşağıdaki beş UID ayrı kayıtlar olarak bulunmalıdır:

```text
jvb-48core-capacity
jvb-thread-stall-forensics
jvb-capacity-bottleneck-multinode
jvb-thread-stall-multinode
jvb-fleet-application-overview
```

Eski iki dashboard'ın başlığı ve panelleri değişmemelidir.

Repository erişimi olan makinede:

```bash
git diff --exit-code -- fedora-native-jitsi-jvb/templates/grafana-dashboard-jvb-thread-forensics.json
```

Beklenen: çıktı yok ve exit code `0`.

## 21. Rollback

Prometheus config'i geri al:

```bash
sudo cp -a "$BACKUP/prometheus.yml.before" "$PROM_CONFIG"
sudo promtool check config "$PROM_CONFIG"
sudo systemctl reload prometheus.service
curl -fsS --max-time 5 "$PROMETHEUS_URL/-/ready"
```

Beklenen:

- `promtool`: `SUCCESS`
- Prometheus: `Prometheus Server is Ready.`

Grafana'da yalnızca şu üç yeni UID'yi sil:

```text
jvb-capacity-bottleneck-multinode
jvb-thread-stall-multinode
jvb-fleet-application-overview
```

Şu iki eski UID'yi silme:

```text
jvb-48core-capacity
jvb-thread-stall-forensics
```

## 22. Final kabul listesi

- [ ] Prometheus ve Grafana servisleri healthy.
- [ ] İki JVB'nin 8080, 9404 ve 9100 endpoint'leri scrape edilebiliyor.
- [ ] Altı target `UP=1`.
- [ ] Her target doğru `jvb_node` etiketine sahip.
- [ ] Her `job + jvb_node` kombinasyonunda tam bir target var.
- [ ] Prometheus config backup'ı boş değil.
- [ ] `promtool check config` başarılı.
- [ ] Üç JSON geçerli ve UID'leri farklı.
- [ ] Capacity dashboard'da tek-node seçim çalışıyor.
- [ ] Thread dashboard'da tek-node seçim çalışıyor.
- [ ] İki detail dashboard'da `All` seçeneği yok.
- [ ] Fleet dashboard iki node'u ve toplamları aynı anda gösteriyor.
- [ ] Fleet thread toplamları ile node kırılımı matematiksel olarak uyuşuyor.
- [ ] Fleet data linkleri doğru node seçili detail dashboard açıyor.
- [ ] Eski iki dashboard overwrite edilmedi.

## Operasyon önerileri

1. NOC/operasyon başlangıç ekranı olarak Fleet dashboard'ı kullan.
2. Toplam değer yükseldiğinde sorunun kaynağını aynı paneldeki `jvb_node` serisinden bul.
3. CPU/stress/network problemi için Capacity detail'e geç.
4. BLOCKED/deadlock/thread churn problemi için Thread detail'e geç.
5. `jvb_node` etiketlerini IP adresinden bağımsız ve kalıcı tut. IP değişse bile `jvb-1` ve `jvb-2` kimliklerini değiştirme.
6. Toplanamayan yüzdeleri toplam gibi yorumlama; Fleet dashboard bu nedenle ağırlıklı toplamı ve worst-node değerini ayrı gösterir.
