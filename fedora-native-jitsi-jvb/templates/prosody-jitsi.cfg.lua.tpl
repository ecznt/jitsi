plugin_paths = { "${PROSODY_PLUGIN_PATH}" }

admins = { "focus@auth.${JITSI_DOMAIN}" }

modules_enabled = modules_enabled or {}
table.insert(modules_enabled, "http")

http_ports = { 5280 }
http_interfaces = { "127.0.0.1" }
https_ports = { }
https_interfaces = { }

http_default_host = "${JITSI_DOMAIN}"
http_external_url = "https://${JITSI_DOMAIN}/"
http_paths = {
    bosh = "/http-bind";
    websocket = "/xmpp-websocket";
}
trusted_proxies = { "127.0.0.1", "::1" }

consider_bosh_secure = true
consider_websocket_secure = true

VirtualHost "${JITSI_DOMAIN}"
    authentication = "anonymous"
    ssl = {
        key = "${TLS_DIR}/${JITSI_DOMAIN}.key";
        certificate = "${TLS_DIR}/${JITSI_DOMAIN}.crt";
    }
    modules_enabled = {
        "bosh";
        "websocket";
        "smacks";
        "pubsub";
    }
    c2s_require_encryption = false
    lobby_muc = "lobby.${JITSI_DOMAIN}"
    main_muc = "conference.${JITSI_DOMAIN}"
    speakerstats_component = "speakerstats.${JITSI_DOMAIN}"
    conference_duration_component = "conferenceduration.${JITSI_DOMAIN}"
    breakout_rooms_muc = "breakout.${JITSI_DOMAIN}"

VirtualHost "auth.${JITSI_DOMAIN}"
    authentication = "internal_hashed"
    ssl = {
        key = "${TLS_DIR}/${JITSI_DOMAIN}.key";
        certificate = "${TLS_DIR}/${JITSI_DOMAIN}.crt";
    }
    c2s_require_encryption = false

Component "conference.${JITSI_DOMAIN}" "muc"
    storage = "memory"
    modules_enabled = {
        "muc_meeting_id";
        "muc_domain_mapper";
    }
    admins = { "focus@auth.${JITSI_DOMAIN}" }
    muc_room_locking = false
    muc_room_default_public_jids = true

Component "breakout.${JITSI_DOMAIN}" "muc"
    storage = "memory"
    modules_enabled = {
        "muc_meeting_id";
        "muc_domain_mapper";
    }
    admins = { "focus@auth.${JITSI_DOMAIN}" }
    muc_room_locking = false
    muc_room_default_public_jids = true

Component "internal.auth.${JITSI_DOMAIN}" "muc"
    storage = "memory"
    modules_enabled = { "ping"; }
    admins = { "focus@auth.${JITSI_DOMAIN}", "jvb@auth.${JITSI_DOMAIN}" }
    muc_room_cache_size = 1000
    muc_room_locking = false
    muc_room_default_public_jids = true

Component "focus.${JITSI_DOMAIN}" "client_proxy"
    target_address = "focus@auth.${JITSI_DOMAIN}"

Component "conferenceduration.${JITSI_DOMAIN}" "conference_duration_component"
    muc_component = "conference.${JITSI_DOMAIN}"

Component "lobby.${JITSI_DOMAIN}" "muc"
    storage = "memory"
    restrict_room_creation = true
    muc_room_locking = false
    muc_room_default_public_jids = true
