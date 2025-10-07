#!/bin/bash

DOMAIN="vector.yral.com"
SSL_DIR="/etc/ssl/milvus"
ACME_HOME="/var/lib/acme.sh"
NGINX_CONF_DIR="/etc/nginx/conf.d"

echo "=== Milvus SSL Certificate Setup ==="

# Ensure nginx is running before we start
systemctl is-active --quiet nginx || systemctl start nginx

# Check if certificates already exist
if [ -f "$SSL_DIR/fullchain.pem" ] && [ -f "$SSL_DIR/privkey.pem" ]; then
    echo "✓ SSL certificates already exist, skipping acquisition"

    # Ensure HTTPS config is enabled
    if [ ! -f "$NGINX_CONF_DIR/milvus-https.conf" ]; then
        echo "Enabling HTTPS configuration..."
        cp "$NGINX_CONF_DIR/milvus-https.conf.template" "$NGINX_CONF_DIR/milvus-https.conf"
        rm -f "$NGINX_CONF_DIR/milvus-http.conf"
        systemctl reload nginx
    fi

    exit 0
fi

# Create SSL directory
mkdir -p "$SSL_DIR"

# Install acme.sh if not present
if [ ! -f "$ACME_HOME/acme.sh" ]; then
    echo "Installing acme.sh to $ACME_HOME..."
    mkdir -p "$ACME_HOME"
    cd /tmp
    curl https://get.acme.sh | sh -s email=joel@gobazzinga.io --home "$ACME_HOME"
    cd -

    if [ ! -f "$ACME_HOME/acme.sh" ]; then
        echo "⚠ Failed to install acme.sh, SSL setup will be skipped"
        echo "⚠ Milvus is accessible at http://$DOMAIN (without SSL)"
        exit 0
    fi
fi

# Stop nginx temporarily for standalone mode
echo "Stopping nginx temporarily for certificate acquisition..."
systemctl stop nginx

# Ensure nginx starts even if SSL fails
trap "systemctl start nginx" EXIT

# Set ZeroSSL as default CA
"$ACME_HOME/acme.sh" --set-default-ca --server zerossl

# Issue certificate
echo "Obtaining SSL certificate from ZeroSSL..."
if ! "$ACME_HOME/acme.sh" --issue -d "$DOMAIN" --standalone --httpport 80; then
    echo "⚠ Failed to obtain SSL certificate, continuing with HTTP only"
    exit 0
fi

# Install certificate
echo "Installing certificate..."
"$ACME_HOME/acme.sh" --install-cert -d "$DOMAIN" \
    --key-file "$SSL_DIR/privkey.pem" \
    --fullchain-file "$SSL_DIR/fullchain.pem" \
    --reloadcmd "systemctl reload nginx"

# Switch to HTTPS configuration
echo "Enabling HTTPS configuration..."
cp "$NGINX_CONF_DIR/milvus-https.conf.template" "$NGINX_CONF_DIR/milvus-https.conf"
rm -f "$NGINX_CONF_DIR/milvus-http.conf"

echo "✓ SSL certificate setup complete"
echo "✓ Milvus is now accessible at https://$DOMAIN"
