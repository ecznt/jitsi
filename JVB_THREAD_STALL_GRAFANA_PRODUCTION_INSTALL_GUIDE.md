# JVB Thread/Stall Alert and Forensics - Manual Production Installation

Bu guide, mevcut production kurulumuna yeni thread/stall gozlem, alert ve
otomatik incident-forensics katmanini eklemek icindir.

Bu guide:

- sifirdan Grafana, Prometheus veya JVB kurmaz;
- genel bir kurulum scripti calistirmaz;
- runtime watchdog dosyalarini operatorun elle kurmasini saglar;
- Prometheus'a ayri bir thread/stall rule dosyasi ekler;
- mevcut dashboard JSON dosyalarini degistirmez;
- JVB veya Grafana restart gerektirmez.

Butun artefaktlari production sunucuya operatorun kendisinin aktardigi
varsayilir. Asagidaki komutlar sunucuda tek tek copy/paste edilmek icindir.

## 1. Kullanilacak dosya

Local repository'deki kaynak:

```text
fedora-native-jitsi-jvb/templates/grafana-dashboard-jvb-thread-forensics.json
fedora-native-jitsi-jvb/templates/prometheus-jvb-thread-alerts.yml.tpl
fedora-native-jitsi-jvb/scripts/95-capture-jvb-incident.sh
fedora-native-jitsi-jvb/scripts/96-jvb-stall-watchdog.sh
fedora-native-jitsi-jvb/templates/jvb-stall-watchdog.env.example
fedora-native-jitsi-jvb/templates/jvb-stall-watchdog.service
fedora-native-jitsi-jvb/templates/jvb-stall-watchdog.timer
```

Sunucuya su gecici adlarla aktarin:

```text
/tmp/grafana-dashboard-jvb-thread-forensics.json
/tmp/prometheus-jvb-thread-alerts.yml
/tmp/jvb-capture-incident
/tmp/jvb-stall-watchdog
/tmp/stall-watchdog.env
/tmp/jvb-stall-watchdog.service
/tmp/jvb-stall-watchdog.timer
```

Dashboard kimligi:

```text
UID: jvb-thread-stall-forensics
Title: JVB Thread, Lock and Stall Forensics
```

Daha once olusturulan dashboard:

```text
UID: jvb-capacity-bottlenecks
Title: JVB Capacity and Bottleneck Analysis
```

UID'ler farklidir. Kaynak repoda mevcut dashboard dosyasinin Git `HEAD` ve
worktree SHA-256 degerleri kurulum guide'i hazirlanirken ayniydi:

```text
c125a909f510ad7761f200c0c7f74ae4b559c61d374f98280691598ec3af5edd
```

## 2. Bu kurulumda kullanilmamasi gerekenler

Production sunucuda sunlari calistirmayin:

```text
fedora-native-jitsi-jvb/scripts/10-install.sh
fedora-native-jitsi-jvb/scripts/60-install-monitoring.sh
```

`95-capture-jvb-incident.sh` ve `96-jvb-stall-watchdog.sh` genel installer
degildir. Bunlar operator tarafindan elle incelenip runtime executable olarak
kurulur; systemd yalniz bu iki sinirli diagnostic bileseni calistirir.

Su ana dashboard dosyasini da yeniden kopyalamayin:

```text
fedora-native-jitsi-jvb/templates/grafana-dashboard-jvb.json
```

Bu guide'in degistirecegi tek Grafana dosyasi yeni ve benzersiz hedef dosyadir:

```text
/var/lib/grafana/dashboards/jvb-thread-stall-forensics.json
```

## 3. Degiskenleri tanimlama

Sunucuda:

```bash
export UPLOAD_JSON=/tmp/grafana-dashboard-jvb-thread-forensics.json
export DASH_DIR=/var/lib/grafana/dashboards
export TARGET_JSON=/var/lib/grafana/dashboards/jvb-thread-stall-forensics.json
export NEW_UID=jvb-thread-stall-forensics
export JVB_SERVICE=jitsi-videobridge2
export UPLOAD_ALERTS=/tmp/prometheus-jvb-thread-alerts.yml
export UPLOAD_CAPTURE=/tmp/jvb-capture-incident
export UPLOAD_WATCHDOG=/tmp/jvb-stall-watchdog
export UPLOAD_ENV=/tmp/stall-watchdog.env
export UPLOAD_SERVICE=/tmp/jvb-stall-watchdog.service
export UPLOAD_TIMER=/tmp/jvb-stall-watchdog.timer
export PROM_CONFIG=/etc/prometheus/prometheus.yml
export ALERT_TARGET=/etc/prometheus/jvb-thread-alerts.yml
export WATCHDOG_ENV=/etc/jitsi/videobridge/stall-watchdog.env
export DIAG_ROOT=/var/lib/jitsi-videobridge/diagnostics
export TEXTFILE_DIR=/var/lib/node_exporter/textfile_collector
```

Upload edilen dosyanin varligini kontrol edin:

```bash
test -s "${UPLOAD_JSON}"
jq empty "${UPLOAD_JSON}"
jq -r '[.uid,.title,.version] | @tsv' "${UPLOAD_JSON}"
test -s "${UPLOAD_ALERTS}"
test -s "${UPLOAD_CAPTURE}"
test -s "${UPLOAD_WATCHDOG}"
test -s "${UPLOAD_ENV}"
test -s "${UPLOAD_SERVICE}"
test -s "${UPLOAD_TIMER}"
```

Beklenen:

```text
jvb-thread-stall-forensics    JVB Thread, Lock and Stall Forensics    1
```

Farkli UID veya title gorurseniz devam etmeyin.

## 4. Grafana provider klasorunu dogrulama

Mevcut provisioning ayarini sadece okuyun:

```bash
sudo grep -R --line-number -- 'path:' /etc/grafana/provisioning/dashboards
```

Ciktida dashboard provider yolu `/var/lib/grafana/dashboards` degilse
`DASH_DIR` ve `TARGET_JSON` degerlerini mevcut provider yoluna gore
degistirin.

Provider dosyasi bulunamiyorsa yeni provider olusturmayin. Bu durumda JSON'u
Grafana UI'daki **Dashboards -> New -> Import** ekranindan import edin ve
asagidaki dosya kopyalama adimini uygulamayin.

## 5. Kurulum oncesi servis ve JVB PID kaydi

```bash
systemctl is-active grafana-server prometheus "${JVB_SERVICE}"

JVB_PID_BEFORE=$(systemctl show -p MainPID --value "${JVB_SERVICE}")
test "${JVB_PID_BEFORE}" -gt 0
printf 'JVB PID before: %s\n' "${JVB_PID_BEFORE}"
```

Grafana, Prometheus ve JVB `active` donmelidir.

## 6. Mevcut dashboard'lari yedekleme ve hash envanteri

```bash
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
BACKUP="/root/jvb-thread-dashboard-${STAMP}"

sudo install -d -m 0700 "${BACKUP}"
sudo cp -a "${DASH_DIR}" "${BACKUP}/dashboards"

sudo find "${DASH_DIR}" -type f -name '*.json' -exec sha256sum '{}' \; \
  | sort \
  | sudo tee "${BACKUP}/dashboards.before.sha256"

sudo find "${DASH_DIR}" -type f -name '*.json' \
  -exec jq -r '[input_filename, (.uid // "NO_UID"), (.title // "NO_TITLE")] | @tsv' '{}' \; \
  | sudo tee "${BACKUP}/dashboards.before.tsv"

printf '%s\n' "${JVB_PID_BEFORE}" \
  | sudo tee "${BACKUP}/jvb-mainpid.before"
```

Envanterde mevcut dashboard'unuzu gorun:

```bash
sudo grep 'jvb-capacity-bottlenecks' "${BACKUP}/dashboards.before.tsv" || true
```

Mevcut dashboard'un UID'si kurum ortaminda farkliysa bu hata degildir; hash
envanteri kurulumdan once var olan butun JSON dosyalarini korur.

## 7. UID ve dosya cakismasini engelleme

Grafana UI'da once `jvb-thread-stall-forensics` UID veya
`JVB Thread, Lock and Stall Forensics` title ile dashboard bulunmadigini
kontrol edin.

Dosya tabanli cakisma kontrolu:

```bash
CONFLICT=$(sudo find "${DASH_DIR}" -type f -name '*.json' \
  -exec jq -r --arg uid "${NEW_UID}" \
  'select(.uid == $uid) | input_filename' '{}' +)

if [[ -n "${CONFLICT}" ]]; then
  printf 'STOP - dashboard UID already exists: %s\n' "${CONFLICT}" >&2
  false
fi

sudo test ! -e "${TARGET_JSON}"
```

Komut durursa mevcut dosyayi ezmeyin.

## 8. Prometheus target ve metric preflight

```bash
curl -fsS http://127.0.0.1:3000/api/health | jq
curl -fsS http://127.0.0.1:9090/-/ready

curl -fsG http://127.0.0.1:9090/api/v1/query \
  --data-urlencode 'query=up{job=~"jvb|jvb-jmx|node"}' \
  | jq -r '.data.result[] | [.metric.job,.metric.instance,.value[1]] | @tsv'
```

`jvb`, `jvb-jmx` ve `node` target'larinin degeri `1` olmalidir.

Dashboard'un temel metriklerini kontrol edin:

```bash
for METRIC in \
  jvm_threads_current \
  jvm_threads_state \
  jvm_threads_peak \
  jvm_threads_deadlocked \
  jvm_threads_started_total \
  process_cpu_seconds_total \
  node_cpu_seconds_total \
  node_procs_running
do
  COUNT=$(curl -fsG http://127.0.0.1:9090/api/v1/query \
    --data-urlencode "query=count(${METRIC})" \
    | jq -r '.data.result[0].value[1] // "0"')
  printf '%-36s %s\n' "${METRIC}" "${COUNT}"
done
```

Sifir donen metriklerin panelleri `No data` gosterir. Bu durum mevcut
dashboard'u etkilemez fakat yeni dashboard eksik veriyle acilir.

JVB 2.3.92'de bazi direct queue-drop ve transit histogram metrikleri
yayinlanmayabilir. Bu panellerde `No data` gorulmesi JSON kurulum hatasi
degildir.

## 9. Prometheus datasource UID'sini dogrulama

Yeni JSON varsayilan olarak datasource UID `prometheus` kullanir. Grafana
UI'da **Connections -> Data sources -> Prometheus** sayfasindan UID'yi kontrol
edin.

UID `prometheus` ise:

```bash
export PROM_UID=prometheus
```

Farkliysa gercek UID'yi yazin:

```bash
export PROM_UID=<MEVCUT_PROMETHEUS_UID>
```

Yalniz yeni dashboard icin kurulacak aday dosyayi olusturun:

```bash
CANDIDATE=$(mktemp)

jq --arg uid "${PROM_UID}" '
  walk(
    if type == "object" and .type? == "prometheus" and has("uid")
    then .uid = $uid
    else .
    end
  )
' "${UPLOAD_JSON}" > "${CANDIDATE}"

jq -e --arg uid "${NEW_UID}" \
  '.uid == $uid' "${CANDIDATE}" >/dev/null
jq empty "${CANDIDATE}"
```

Bu islem upload edilen kaynak dosyayi veya mevcut dashboard'lari degistirmez.

## 10. Yeni JSON'u kurma

Asagidaki komut yalniz `TARGET_JSON` dosyasini olusturur:

```bash
sudo install -o grafana -g grafana -m 0644 \
  "${CANDIDATE}" "${TARGET_JSON}"

sudo jq -r '[.uid,.title] | @tsv' "${TARGET_JSON}"
sudo ls -l "${TARGET_JSON}"
```

Beklenen UID/title:

```text
jvb-thread-stall-forensics    JVB Thread, Lock and Stall Forensics
```

Mevcut Grafana file provider kendi `updateIntervalSeconds` suresinde yeni
dosyayi algilar. JVB veya Grafana restart etmeyin.

Grafana logunu kontrol edin:

```bash
sudo journalctl -u grafana-server --since '5 minutes ago' --no-pager \
  | grep -Ei 'provision|dashboard|error|failed' || true
```

## 11. Mevcut dashboard'larin degismedigini kanitlama

Kurulumdan once var olan her JSON dosyasini tekrar dogrulayin:

```bash
sudo sha256sum --check "${BACKUP}/dashboards.before.sha256"
```

Butun satirlar `OK` donmelidir. Yeni dosya kurulum oncesi envanterde
olmadigi icin bu kontrole dahil degildir.

JVB PID'sini kontrol edin:

```bash
JVB_PID_AFTER=$(systemctl show -p MainPID --value "${JVB_SERVICE}")
printf 'before=%s after=%s\n' "${JVB_PID_BEFORE}" "${JVB_PID_AFTER}"
test "${JVB_PID_BEFORE}" = "${JVB_PID_AFTER}"
systemctl show "${JVB_SERVICE}" -p NRestarts -p ActiveState
```

PID ayni olmali ve JVB restart edilmemis olmalidir.

Grafana UI'da iki dashboard'u ayri ayri acin:

```text
JVB Capacity and Bottleneck Analysis
JVB Thread, Lock and Stall Forensics
```

## 12. Yeni dashboard nasil yorumlanir?

- `Monitor BLOCKED` yukseliyor ve ayni anda transit p99 artiyorsa lock
  contention suphesi guclenir.
- `BLOCKED=0`, CPU/run queue yuksekse scheduler veya CPU saturation daha
  olasidir.
- UDP/softnet drop artiyorsa problem Java lock'tan once kernel/network
  katmaninda olabilir.
- Thread creation rate surekli yukseliyorsa endpoint churn, blocked IO veya
  pool davranisi incelenmelidir.
- Grafana stack trace veya kilit sahibini gostermez. Olayin tam UTC zamaninda
  mevcut rolling JFR dump'i ve uc ardisik thread dump ayrica alinmalidir.

Grafana ham event sayisindan cok olay zamanini ve birlikte hareket eden
sinyalleri belirlemek icindir.

## 13. Prometheus alert kurallarini elle kurma

Bu asama mevcut dashboard'u degistirmez. Yeni ve ayri bir Prometheus rule
dosyasi kurar.

Mevcut Prometheus konfigurasyonunu yedekleyin:

```bash
sudo cp -a "${PROM_CONFIG}" "${BACKUP}/prometheus.yml.before"
sudo test ! -e "${ALERT_TARGET}"
sudo install -o root -g prometheus -m 0644 "${UPLOAD_ALERTS}" "${ALERT_TARGET}"
sudo promtool check rules "${ALERT_TARGET}"
```

Mevcut `rule_files` bolumunu okuyun:

```bash
sudo grep -n -A12 '^rule_files:' "${PROM_CONFIG}"
```

Mevcut bir glob `ALERT_TARGET` dosyasini kapsamiyorsa:

```bash
sudoedit "${PROM_CONFIG}"
```

`rule_files` altina yalniz su satiri ekleyin:

```yaml
  - /etc/prometheus/jvb-thread-alerts.yml
```

`PROM_CONFIG` veya `ALERT_TARGET` icin farkli path kullandiysaniz YAML
satirini gercek hedef path ile yazin.

Degisikligi ve syntax'i dogrulayin:

```bash
sudo diff -u "${BACKUP}/prometheus.yml.before" "${PROM_CONFIG}" || true
sudo promtool check config "${PROM_CONFIG}"
sudo systemctl reload prometheus
curl -fsS http://127.0.0.1:9090/-/ready
curl -fsS http://127.0.0.1:9090/api/v1/rules | jq -r '.data.groups[] | select(.name == "jvb-thread-and-stall") | .name'
```

Beklenen rule group:

```text
jvb-thread-and-stall
```

Kurulan algilama kurallari:

- JVM deadlock;
- sustained monitor `BLOCKED` thread;
- thread creation burst;
- JVB process CPU saturation;
- sustained JVB stress;
- RTP transit p99 gecikmesi;
- host run-queue baskisi;
- UDP receive-buffer drop;
- Linux softnet drop;
- watchdog capture ve watchdog stale durumu.

Prometheus bu kurallari evaluate eder. E-posta, Slack veya PagerDuty bildirimi
icin mevcut Alertmanager route/receiver konfigurasyonunuz kullanilir. Bu guide
kuruma ozel notification secret veya receiver eklemez.

## 14. Runtime watchdog dosyalarini elle kurma

Bu asamada genel installer calistirilmaz. Upload ettiginiz dosyalar tek tek
kontrol edilip hedeflerine kopyalanir.

Once dosyalari okuyup syntax kontrolu yapin:

```bash
sudo less "${UPLOAD_CAPTURE}"
sudo less "${UPLOAD_WATCHDOG}"
bash -n "${UPLOAD_CAPTURE}"
bash -n "${UPLOAD_WATCHDOG}"
```

Node Exporter textfile collector path'ini dogrulayin:

```bash
systemctl cat prometheus-node-exporter | grep -- '--collector.textfile.directory'
```

Ciktidaki path farkliysa `TEXTFILE_DIR` degerini degistirin. Collector
parametresi yoksa burada durun; Node Exporter textfile collector'i ayri ve
kontrollu bir servis change'i ile etkinlestirilmelidir.

Hedeflerde daha once ayni mekanizma bulunmadigini kontrol edin:

```bash
sudo test ! -e /usr/local/sbin/jvb-capture-incident
sudo test ! -e /usr/local/sbin/jvb-stall-watchdog
sudo test ! -e /etc/systemd/system/jvb-stall-watchdog.service
sudo test ! -e /etc/systemd/system/jvb-stall-watchdog.timer
```

Diagnostic dizinlerini ve runtime dosyalarini kurun:

```bash
sudo install -d -m 0750 "${DIAG_ROOT}/watchdog"
sudo install -d -m 0750 "${DIAG_ROOT}/incidents"
sudo install -d -m 0755 "${TEXTFILE_DIR}"
sudo install -o root -g root -m 0755 "${UPLOAD_CAPTURE}" /usr/local/sbin/jvb-capture-incident
sudo install -o root -g root -m 0755 "${UPLOAD_WATCHDOG}" /usr/local/sbin/jvb-stall-watchdog
sudo install -o root -g root -m 0644 "${UPLOAD_SERVICE}" /etc/systemd/system/jvb-stall-watchdog.service
sudo install -o root -g root -m 0644 "${UPLOAD_TIMER}" /etc/systemd/system/jvb-stall-watchdog.timer
sudo test -e "${WATCHDOG_ENV}" || sudo install -o root -g root -m 0640 "${UPLOAD_ENV}" "${WATCHDOG_ENV}"
sudo systemd-analyze verify /etc/systemd/system/jvb-stall-watchdog.service /etc/systemd/system/jvb-stall-watchdog.timer
```

Upload edilen systemd unit varsayilan olarak su path'leri kullanir:

```text
/etc/jitsi/videobridge/stall-watchdog.env
/usr/local/sbin/jvb-stall-watchdog
/var/lib/jitsi-videobridge/diagnostics
/var/lib/node_exporter/textfile_collector
```

Kendi production path'leriniz farkliysa unit ve env dosyalarini
`sudoedit` ile gercek path'lere gore degistirin. Ozellikle systemd
`ReadWritePaths` listesi kullanilan diagnostic ve textfile dizinlerini
icermelidir.

## 15. Watchdog'u once capture-kapali gozlem modunda acma

Ilk asamada watchdog metric uretecek fakat otomatik `jcmd` capture
tetiklemeyecek.

```bash
sudoedit "${WATCHDOG_ENV}"
```

Asagidaki degerleri ayarlayin:

```text
JVB_WATCHDOG_CONSECUTIVE_LIMIT=999999
JVB_WATCHDOG_THREAD_LIMIT=0
JVB_WATCHDOG_STATE_DIR=/var/lib/jitsi-videobridge/diagnostics/watchdog
JVB_NODE_EXPORTER_TEXTFILE_DIR=/var/lib/node_exporter/textfile_collector
JVB_INCIDENT_ROOT=/var/lib/jitsi-videobridge/diagnostics/incidents
JVB_SERVICE=
```

Custom path kullaniyorsaniz son dort degeri kendi path ve servis adiniza gore
duzeltin. Bos `JVB_SERVICE`, `jitsi-videobridge2` veya
`jitsi-videobridge` servisinin otomatik bulunmasini saglar.

Timer'i etkinlestirin:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now jvb-stall-watchdog.timer
systemctl is-active jvb-stall-watchdog.timer
systemctl list-timers jvb-stall-watchdog.timer
```

Ilk iki ornekten sonra kontrol edin:

```bash
sudo journalctl -u jvb-stall-watchdog.service -n 50 --no-pager
sudo tail -n 20 "${DIAG_ROOT}/watchdog/samples.jsonl"
curl -fsS http://127.0.0.1:9100/metrics | grep '^jvb_watchdog_'
curl -fsG http://127.0.0.1:9090/api/v1/query --data-urlencode 'query=jvb_watchdog_last_run_timestamp_seconds' | jq
```

Bu modda Grafana'daki watchdog sample ve breach panelleri veri gostermeye
baslar; incident capture olusmaz.

## 16. Baseline ve esik kabulü

En az bir gercek yuk testi boyunca su degerlerin normal araligini kaydedin:

- canli/peak thread;
- `BLOCKED` thread;
- thread creation rate;
- process CPU/host yuzdesi;
- JVB stress;
- RTP transit p99;
- endpoint ve konferans sayisi;
- UDP/softnet drop.

Mutlak toplam thread sayisi production P99 belirlenmeden trigger olmamalidir:

```text
JVB_WATCHDOG_THREAD_LIMIT=0
```

Varsayilan ilk incident esikleri:

```text
JVB_WATCHDOG_CONSECUTIVE_LIMIT=3
JVB_WATCHDOG_COOLDOWN_SECONDS=900
JVB_WATCHDOG_BLOCKED_THREAD_LIMIT=8
JVB_WATCHDOG_CPU_PERCENT_LIMIT=87.5
JVB_WATCHDOG_STRESS_LIMIT=0.90
JVB_WATCHDOG_TRANSIT_P99_MS_LIMIT=100
JVB_THREAD_DUMP_COUNT=3
JVB_THREAD_DUMP_INTERVAL_SECONDS=5
JVB_INCIDENT_JFR_MAX_AGE=10m
```

`87.5`, 48 logical CPU gorunen hostta yaklasik 42 core'un tamamen
kullanilmasina denktir. Bu degerler nihai production gercegi degil, yuk
testiyle kalibre edilecek baslangic esikleridir.

Tek kritik control-plane thread'i uygulamayi etkilerken `BLOCKED >= 8`
olmayabilir. Bu nedenle watchdog ayrica health, RTP transit, CPU ve stress
sinyallerini de kullanir.

## 17. Otomatik capture ve thread on analizini acma

Baseline kabul edildikten sonra:

```bash
sudoedit "${WATCHDOG_ENV}"
```

`JVB_WATCHDOG_CONSECUTIVE_LIMIT` degerini `3` yapin ve kabul edilen diger
esikleri yazin. Yeni oneshot her calismada env dosyasini yeniden okur:

```bash
sudo systemctl restart jvb-stall-watchdog.timer
systemctl show "${JVB_SERVICE}" -p MainPID -p NRestarts -p ActiveState
```

Esiklerden biri uc ardisik 15 saniyelik ornekte asilirsa, 15 dakikalik
cooldown'a tabi bir incident paketi olusur:

```text
<DIAG_ROOT>/incidents/<UTC>-watchdog-<reason>/
```

Paket sunlari icerir:

- son 10 dakikalik mevcut rolling JFR snapshot;
- bes saniye arayla uc thread dump;
- `thread-analysis.txt`;
- `jfr-summary.txt`;
- tekrar eden `BLOCKED` thread isimleri;
- her dump icin thread-state sayilari;
- JVM deadlock izleri;
- ilk 400 lock/park evidence satiri;
- en yuksek per-thread CPU ornekleri;
- process, journal, GC/safepoint ve network/kernel kanitlari;
- JVB, JMX ve Node Exporter metric snapshot'lari.

`thread-analysis.txt` otomatik bir on siniflandirmadir; nihai root-cause
karari degildir. Kilit sahibi, stack ve monitor iliskisi ham dump/JFR ile
dogrulanmalidir.

Planli yuk testi veya bakim penceresinde bir kez manuel capture testi yapin:

```bash
sudo /usr/local/sbin/jvb-capture-incident manual-validation
sudo find "${DIAG_ROOT}/incidents" -maxdepth 2 -type f -printf '%TY-%Tm-%Td %TH:%TM:%TS %s %p\n' | tail -80
```

Aktif kritik toplantida sirf test amaciyla manuel capture yapmayin.

Incident dosyalari conference/endpoint kimligi icerebilir. Dizin izinlerini
genisletmeyin, paylasmadan once redakte edin ve disk/retention alarmi tanimlayin.

## 18. Rollback

Once watchdog'u kapatin ve yalniz bu change ile eklenen runtime dosyalarini
kaldirin:

```bash
sudo systemctl disable --now jvb-stall-watchdog.timer
sudo rm -f /etc/systemd/system/jvb-stall-watchdog.timer
sudo rm -f /etc/systemd/system/jvb-stall-watchdog.service
sudo rm -f /usr/local/sbin/jvb-stall-watchdog
sudo rm -f /usr/local/sbin/jvb-capture-incident
sudo systemctl daemon-reload
```

Prometheus'u onceki konfigurasyona dondurun:

```bash
sudo cp -a "${BACKUP}/prometheus.yml.before" "${PROM_CONFIG}"
sudo rm -f "${ALERT_TARGET}"
sudo promtool check config "${PROM_CONFIG}"
sudo systemctl reload prometheus
```

Yeni JSON dosyasini kaldirin:

```bash
sudo rm -f "${TARGET_JSON}"
```

Dashboard'u file provider yerine Grafana UI ile import ettiyseniz ayni UID'li
yalniz yeni dashboard'u UI'dan silin; mevcut dashboard'u silmeyin.

Mevcut dashboard'larin hala ayni oldugunu dogrulayin:

```bash
sudo sha256sum --check "${BACKUP}/dashboards.before.sha256"
systemctl show "${JVB_SERVICE}" -p MainPID -p NRestarts -p ActiveState
```

Mevcut dashboard klasorunu silmeyin, backup klasorunu topluca geri kopyalamayin
ve ana dashboard JSON dosyasina dokunmayin. Grafana file provider kaldirilan
yeni dashboard'u kendi polling suresinde UI'dan cikarir.

Incident verilerini otomatik silmeyin; kurum retention kararina gore ayri
olarak arsivleyin veya silin.

## 19. Kabul kriterleri

Kurulum yalniz su sartlarda basarili sayilir:

- Kurulum oncesi dashboard hash'lerinin tamami kurulum sonrasinda `OK`.
- Mevcut dashboard UI'da aciliyor.
- Yeni dashboard farkli UID ile ayri aciliyor.
- JVB `MainPID` degismedi.
- `jvb`, `jvb-jmx` ve `node` target'lari `up=1`.
- Temel thread, CPU ve host panelleri veri gosteriyor.
- `jvb-thread-and-stall` Prometheus rule group yuklu.
- Watchdog timer aktif ve 15 saniyede bir ornek uretiyor.
- Watchdog metricleri Node Exporter ve Prometheus'ta gorunuyor.
- Planli test incident'inda `thread-analysis.txt`, uc dump ve JFR mevcut.
- Grafana logunda provisioning hatasi yok.
- Genel installer scriptleri calistirilmadi.
