server {
    listen 80;
    listen [::]:80;
    server_name ${JITSI_DOMAIN};

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        return 301 https://$host$request_uri;
    }
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${JITSI_DOMAIN};

    ssl_certificate ${TLS_DIR}/${JITSI_DOMAIN}.crt;
    ssl_certificate_key ${TLS_DIR}/${JITSI_DOMAIN}.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;

    root ${JITSI_MEET_ROOT};
    index index.html;

    add_header X-Content-Type-Options nosniff;
    add_header Referrer-Policy no-referrer;

    location = /config.js {
        alias /etc/jitsi/meet/${JITSI_DOMAIN}-config.js;
    }

    location = /interface_config.js {
        alias /etc/jitsi/meet/${JITSI_DOMAIN}-interface_config.js;
    }

    location = /logging_config.js {
        alias /etc/jitsi/meet/${JITSI_DOMAIN}-logging_config.js;
    }

    location = /external_api.js {
        alias ${JITSI_MEET_ROOT}/libs/external_api.min.js;
    }

    location ^~ /http-bind {
        proxy_pass http://127.0.0.1:5280/http-bind;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_set_header X-Forwarded-Proto https;
        proxy_buffering off;
        proxy_read_timeout 900s;
    }

    location ^~ /xmpp-websocket {
        proxy_pass http://127.0.0.1:5280/xmpp-websocket;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 900s;
    }

    location /colibri-ws/ {
        proxy_pass http://127.0.0.1:9091/colibri-ws/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_read_timeout 900s;
    }

    location ~ ^/([^/?&:'"]+)$ {
        try_files $uri /index.html;
    }

    location / {
        try_files $uri $uri/ /index.html;
    }
}
