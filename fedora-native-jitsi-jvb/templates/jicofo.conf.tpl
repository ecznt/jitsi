jicofo {
  authentication {
    enabled = false
    type = NONE
  }

  bridge {
    brewery-jid = "jvbbrewery@internal.auth.${JITSI_DOMAIN}"
    selection-strategy = SingleBridgeSelectionStrategy
    health-checks {
      enabled = true
      interval = 10 seconds
    }
  }

  conference {
    enable-auto-owner = true
    min-participants = 2
  }

  rest {
    enabled = true
    host = "127.0.0.1"
    port = 8888
    prometheus {
      enabled = true
    }
  }

  octo {
    enabled = false
  }

  sctp {
    enabled = true
  }

  xmpp {
    client {
      enabled = true
      hostname = "127.0.0.1"
      port = 5222
      domain = "auth.${JITSI_DOMAIN}"
      xmpp-domain = "${JITSI_DOMAIN}"
      username = "focus"
      password = "${JICOFO_AUTH_PASSWORD}"
      conference-muc-jid = "conference.${JITSI_DOMAIN}"
      client-proxy = "focus.${JITSI_DOMAIN}"
      disable-certificate-verification = true
      use-tls = false
    }

    trusted-domains = [ "auth.${JITSI_DOMAIN}" ]
  }
}

