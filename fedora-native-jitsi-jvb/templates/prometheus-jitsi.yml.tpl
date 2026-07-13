global:
  scrape_interval: 10s
  scrape_timeout: 8s
  evaluation_interval: 10s

rule_files:
  - /etc/prometheus/jvb-alerts.yml

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets:
          - 127.0.0.1:9090

  - job_name: jvb
    scrape_interval: 5s
    metrics_path: /metrics
    static_configs:
      - targets:
          - 127.0.0.1:8080
        labels:
          component: jitsi-videobridge
          instance: ${JITSI_DOMAIN}

  - job_name: jvb-jmx
    metrics_path: /metrics
    static_configs:
      - targets:
          - 127.0.0.1:9404
        labels:
          component: jitsi-videobridge-jvm
          instance: ${JITSI_DOMAIN}

  - job_name: node
    metrics_path: /metrics
    static_configs:
      - targets:
          - 127.0.0.1:9100
        labels:
          component: fedora-host
          instance: ${JITSI_DOMAIN}

  - job_name: jicofo
    metrics_path: /metrics
    static_configs:
      - targets:
          - 127.0.0.1:8888
        labels:
          component: jicofo
          instance: ${JITSI_DOMAIN}
