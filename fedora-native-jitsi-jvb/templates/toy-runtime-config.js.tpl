window.__TOY_RUNTIME_CONFIG__ = {
    DEPLOY_ENV: 'intranet',
    PUBLIC_URL: 'https://${JITSI_DOMAIN}',
    BASE_URL: 'https://${JITSI_DOMAIN}',
    configOverwrite: {
        hosts: {
            domain: '${JITSI_DOMAIN}',
            muc: 'conference.${JITSI_DOMAIN}',
            focus: 'focus.${JITSI_DOMAIN}'
        },
        bosh: 'https://${JITSI_DOMAIN}/http-bind',
        websocket: 'wss://${JITSI_DOMAIN}/xmpp-websocket',
        openBridgeChannel: 'websocket',
        p2p: {
            enabled: false,
            stunServers: []
        },
        analytics: {
            disabled: true
        },
        defaultLanguage: 'tr',
        disableThirdPartyRequests: true,
        disableDeepLinking: true,
        disableInviteFunctions: true,
        enableWelcomePage: true
    },
    interfaceConfigOverwrite: {}
};
