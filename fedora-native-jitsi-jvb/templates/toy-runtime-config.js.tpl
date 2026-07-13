window.__TOY_RUNTIME_CONFIG__ = {
    configOverwrite: {
        hosts: {
            domain: '${JITSI_DOMAIN}',
            muc: 'conference.${JITSI_DOMAIN}',
            focus: 'focus.${JITSI_DOMAIN}'
        },
        bosh: 'https://${JITSI_DOMAIN}/http-bind',
        websocket: 'wss://${JITSI_DOMAIN}/xmpp-websocket'
    },
    interfaceConfigOverwrite: {}
};
