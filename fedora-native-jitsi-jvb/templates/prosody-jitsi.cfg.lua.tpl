plugin_paths = { "${PROSODY_PLUGIN_PATH}" }

admins = { "focus@auth.${JITSI_DOMAIN}" }

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
        "speakerstats";
        "conference_duration";
        "muc_lobby_rooms";
        "muc_breakout_rooms";
        "av_moderation";
        "room_metadata";
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
        "polls";
        "muc_rate_limit";
        "muc_password_whitelist";
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

Component "focus.${JITSI_DOMAIN}" "client_proxy"
    target_address = "focus@auth.${JITSI_DOMAIN}"

Component "speakerstats.${JITSI_DOMAIN}" "speakerstats_component"
    muc_component = "conference.${JITSI_DOMAIN}"

Component "conferenceduration.${JITSI_DOMAIN}" "conference_duration_component"
    muc_component = "conference.${JITSI_DOMAIN}"

Component "lobby.${JITSI_DOMAIN}" "muc"
    storage = "memory"
    restrict_room_creation = true
    muc_room_locking = false
    muc_room_default_public_jids = true

