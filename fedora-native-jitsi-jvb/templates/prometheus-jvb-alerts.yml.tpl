groups:
  - name: jvb-availability
    rules:
      - alert: JVBTargetDown
        expr: up{job="jvb"} == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "JVB metrics target is down"
          description: "Prometheus cannot scrape the JVB endpoint on {{ $labels.instance }}."

      - alert: JVBUnhealthy
        expr: jitsi_jvb_healthy == 0
        for: 30s
        labels:
          severity: critical
        annotations:
          summary: "JVB reports unhealthy"
          description: "The JVB health metric is zero on {{ $labels.instance }}."

      - alert: JVBJmxTargetDown
        expr: up{job="jvb-jmx"} == 0
        for: 2m
        labels:
          severity: warning
        annotations:
          summary: "JVB JVM metrics are unavailable"
          description: "Prometheus cannot scrape the JVB JMX exporter."

      - alert: JVBNodeTargetDown
        expr: up{job="node"} == 0
        for: 2m
        labels:
          severity: warning
        annotations:
          summary: "JVB host metrics are unavailable"
          description: "Prometheus cannot scrape Node Exporter."

  - name: jvb-quality
    rules:
      - alert: JVBRecentIceFailures
        expr: increase(jitsi_jvb_ice_failed_total[5m]) > 0
        for: 1m
        labels:
          severity: warning
        annotations:
          summary: "Recent ICE failures detected"
          description: "{{ $value | printf \"%.0f\" }} ICE failures occurred in five minutes."

      - alert: JVBRecentDtlsFailures
        expr: increase(jitsi_jvb_endpoints_dtls_failed_total[5m]) > 0
        for: 1m
        labels:
          severity: warning
        annotations:
          summary: "Recent DTLS failures detected"
          description: "{{ $value | printf \"%.0f\" }} endpoint DTLS failures occurred in five minutes."

      - alert: JVBFailedConferences
        expr: increase(jitsi_jvb_failed_conferences_total[10m]) + increase(jitsi_jvb_partially_failed_conferences_total[10m]) > 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "Failed or partially failed conferences detected"
          description: "At least one conference failed during the last ten minutes."

      - alert: JVBMessageTransportFailures
        expr: increase(jitsi_jvb_endpoints_no_message_transport_after_delay_total[5m]) > 0
        for: 1m
        labels:
          severity: warning
        annotations:
          summary: "Endpoint message transport failures detected"
          description: "An endpoint failed to establish its message transport."

  - name: jvb-capacity
    rules:
      - alert: JVBHighHostCpu
        expr: 100 * (1 - avg by (instance) (rate(node_cpu_seconds_total{job="node",mode="idle"}[5m]))) > 85
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "JVB host CPU is above 85 percent"
          description: "Sustained CPU pressure can limit packet forwarding capacity."

      - alert: JVBHighHostMemory
        expr: 100 * (1 - node_memory_MemAvailable_bytes{job="node"} / node_memory_MemTotal_bytes{job="node"}) > 90
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "JVB host memory is above 90 percent"
          description: "The host has less than ten percent readily available memory."

      - alert: JVBHighHeapUsage
        expr: 100 * sum by (instance) (jvm_memory_used_bytes{job="jvb-jmx",area="heap"}) / sum by (instance) (jvm_memory_max_bytes{job="jvb-jmx",area="heap"} > 0) > 85
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "JVB JVM heap is above 85 percent"
          description: "Sustained heap pressure can increase GC pauses."

      - alert: JVBLowRootDiskSpace
        expr: 100 * node_filesystem_avail_bytes{job="node",mountpoint="/",fstype!~"tmpfs|overlay"} / node_filesystem_size_bytes{job="node",mountpoint="/",fstype!~"tmpfs|overlay"} < 15
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "Root filesystem has less than 15 percent free"
          description: "Low disk space can break logs, metrics retention, and service restarts."

      - alert: JVBHighNetworkDrops
        expr: sum by (instance) (rate(node_network_receive_drop_total{job="node",device!~"lo|docker.*|veth.*"}[5m]) + rate(node_network_transmit_drop_total{job="node",device!~"lo|docker.*|veth.*"}[5m])) > 1
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Host network packet drops detected"
          description: "Sustained interface drops can directly degrade media quality."
