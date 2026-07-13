videobridge {
  cc {
    # Global hard cap. Endpoints can request fewer forwarded videos, not more.
    jvb-last-n = ${JVB_LAST_N}
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
          HOSTNAME = "127.0.0.1"
          PORT = "5222"
          DOMAIN = "auth.${JITSI_DOMAIN}"
          USERNAME = "jvb"
          PASSWORD = "${JVB_AUTH_PASSWORD}"
          MUC_JIDS = "jvbbrewery@internal.auth.${JITSI_DOMAIN}"
          MUC_NICKNAME = "jvb-1"
          DISABLE_CERTIFICATE_VERIFICATION = true
        }
      }
    }
    rest {
      enabled = false
    }
  }

  rest {
    prometheus {
      enabled = true
    }
    health {
      enabled = true
    }
    debug {
      enabled = true
    }
  }

  stats {
    enabled = true
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
      send-server-version = false
    }
    public {
      host = "127.0.0.1"
      port = 9091
      send-server-version = false
    }
  }

  websockets {
    enabled = true
    domain = "${JITSI_DOMAIN}"
    tls = true
    server-id = "jvb-1"
  }

  sctp {
    enabled = true
  }

  health {
    require-valid-address = false
  }
}

ice4j {
  harvest {
    mapping {
      static-mappings = [
        {
          local-address = "${PRIVATE_IP}"
          public-address = "${PUBLIC_IP}"
        }
      ]
    }
  }
}
