global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets:
          - 127.0.0.1:9090

  - job_name: jvb
    metrics_path: /metrics
    static_configs:
      - targets:
          - 127.0.0.1:8080
        labels:
          component: jitsi-videobridge
          instance: ${JITSI_DOMAIN}

  - job_name: jicofo
    metrics_path: /metrics
    static_configs:
      - targets:
          - 127.0.0.1:8888
        labels:
          component: jicofo
          instance: ${JITSI_DOMAIN}

