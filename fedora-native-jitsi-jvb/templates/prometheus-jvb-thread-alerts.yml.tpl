groups:
  - name: jvb-thread-and-stall
    rules:
      - alert: JVBJavaDeadlockDetected
        expr: max(jvm_threads_deadlocked{job="jvb-jmx"}) > 0
        for: 15s
        labels:
          severity: critical
        annotations:
          summary: "JVB JVM deadlock detected"
          description: "ThreadMXBean reports at least one deadlocked thread. The watchdog should create an incident bundle."

      - alert: JVBBlockedThreadsHigh
        expr: sum(jvm_threads_state{job="jvb-jmx",state=~"BLOCKED|blocked"}) > 8
        for: 1m
        labels:
          severity: warning
        annotations:
          summary: "JVB has more than eight monitor-blocked threads"
          description: "A sustained BLOCKED population can indicate lock contention. Correlate it with CPU, transit delay and the incident thread dumps."

      - alert: JVBThreadCreationBurst
        expr: sum(rate(jvm_threads_started_total{job="jvb-jmx"}[5m])) > 2
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "JVB is creating threads unusually quickly"
          description: "More than two new platform threads per second has persisted for five minutes. Check endpoint churn and cached IO pool behavior."

      - alert: JVBProcessCpuSaturation
        expr: 100 * sum(rate(process_cpu_seconds_total{job="jvb-jmx"}[5m])) / count(node_cpu_seconds_total{job="node",mode="idle"}) > 87.5
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "JVB process is consuming more than 87.5 percent of host CPU capacity"
          description: "On a 48-logical-CPU host this is approximately 42 fully occupied cores. Check media transit delay, softirq and packet drops."

      - alert: JVBStressSustained
        expr: max(jitsi_jvb_stress_level) > 0.90
        for: 2m
        labels:
          severity: warning
        annotations:
          summary: "JVB stress is above 0.90"
          description: "The bridge load measurement is close to its configured overload threshold."

      - alert: JVBMediaTransitP99High
        expr: histogram_quantile(0.99, sum by (le) (rate(jitsi_jvb_rtp_transit_time_bucket[1m]))) > 100
        for: 45s
        labels:
          severity: warning
        annotations:
          summary: "JVB RTP transit p99 is above 100 ms"
          description: "Media processing delay is high even if ThreadMXBean does not report a deadlock. Correlate CPU, BLOCKED threads, GC and kernel drops."

      - alert: JVBHostRunQueuePressure
        expr: sum(node_procs_running{job="node"}) / count(node_cpu_seconds_total{job="node",mode="idle"}) > 1
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Runnable process count exceeds logical CPU count"
          description: "Sustained run-queue pressure means runnable JVB work can wait for CPU even without a Java monitor deadlock."

      - alert: JVBKernelUdpReceiveBufferDrops
        expr: sum(rate(node_netstat_Udp_RcvbufErrors{job="node"}[5m])) > 0
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "Linux is dropping UDP packets because receive buffers are full"
          description: "This is an OS/network backlog failure, not necessarily a Java lock. Inspect NIC queues, IRQ distribution and UDP buffer sizing."

      - alert: JVBKernelSoftnetDrops
        expr: sum(rate(node_softnet_dropped_total{job="node"}[5m])) > 0
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "Linux softnet backlog is dropping packets"
          description: "Packet processing cannot keep up before packets reach JVB. Inspect RSS/IRQ affinity, softirq balance and netdev backlog."

      - alert: JVBWatchdogTriggered
        expr: max_over_time(jvb_watchdog_triggered[1m]) > 0
        labels:
          severity: warning
        annotations:
          summary: "JVB watchdog captured an incident bundle"
          description: "Review /var/lib/jitsi-videobridge/diagnostics/incidents and correlate the timestamp with this dashboard."

      - alert: JVBWatchdogStale
        expr: (time() - max(jvb_watchdog_last_run_timestamp_seconds) > 60) or absent(jvb_watchdog_last_run_timestamp_seconds)
        for: 2m
        labels:
          severity: warning
        annotations:
          summary: "JVB watchdog has not produced a sample for more than one minute"
          description: "Check jvb-stall-watchdog.timer, Prometheus readiness and Node Exporter textfile collection."
