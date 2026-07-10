var interfaceConfig = {
    APP_NAME: 'Jitsi Meet',
    NATIVE_APP_NAME: 'Jitsi Meet',
    PROVIDER_NAME: 'Jitsi',

    DEFAULT_BACKGROUND: '#040404',
    DEFAULT_LOGO_URL: '',
    DEFAULT_WELCOME_PAGE_LOGO_URL: '',

    SHOW_BRAND_WATERMARK: false,
    SHOW_JITSI_WATERMARK: false,
    SHOW_POWERED_BY: false,
    SHOW_WATERMARK_FOR_GUESTS: false,

    MOBILE_APP_PROMO: false,
    DISABLE_JOIN_LEAVE_NOTIFICATIONS: false,
    DISABLE_PRESENCE_STATUS: false,
    DISABLE_TRANSCRIPTION_SUBTITLES: true,

    TOOLBAR_BUTTONS: [
        'microphone', 'camera', 'closedcaptions', 'desktop', 'fullscreen',
        'fodeviceselection', 'hangup', 'profile', 'chat', 'recording',
        'livestreaming', 'etherpad', 'sharedvideo', 'settings', 'raisehand',
        'videoquality', 'filmstrip', 'invite', 'feedback', 'stats',
        'shortcuts', 'tileview', 'videobackgroundblur', 'download',
        'help', 'mute-everyone', 'security'
    ],

    SETTINGS_SECTIONS: [ 'devices', 'language', 'moderator', 'profile', 'calendar' ],
    VIDEO_LAYOUT_FIT: 'both',
    TILE_VIEW_MAX_COLUMNS: 5
};

var loggingConfig = {
    defaultLogLevel: 'warn',
    'modules/RTC/TraceablePeerConnection.js': 'info',
    'modules/xmpp/strophe.util.js': 'log'
};

var config = {
    hosts: {
        domain: '${JITSI_DOMAIN}',
        muc: 'conference.${JITSI_DOMAIN}',
        focus: 'focus.${JITSI_DOMAIN}'
    },

    bosh: '//${JITSI_DOMAIN}/http-bind',
    // XMPP WebSocket is intentionally omitted for the first Fedora-native lab.
    // Browser signaling uses BOSH; JVB media still uses Colibri WebSocket.
    clientNode: 'http://jitsi.org/jitsimeet',

    // Keep two-party smoke tests on JVB instead of direct browser P2P.
    p2p: {
        enabled: false
    },

    openBridgeChannel: 'websocket',
    enableWelcomePage: true,
    prejoinPageEnabled: true,
    disableThirdPartyRequests: true,
    analytics: {
        disabled: true
    },

    testing: {
        p2pTestMode: false
    }
};
