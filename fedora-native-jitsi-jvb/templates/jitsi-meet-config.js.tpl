var config = {
    hosts: {
        domain: '${JITSI_DOMAIN}',
        muc: 'conference.${JITSI_DOMAIN}',
        focus: 'focus.${JITSI_DOMAIN}'
    },

    bosh: '//${JITSI_DOMAIN}/http-bind',
    websocket: 'wss://${JITSI_DOMAIN}/xmpp-websocket',
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

