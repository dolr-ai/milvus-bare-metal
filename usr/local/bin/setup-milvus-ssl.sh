#!/bin/bash
set -e

DOMAIN="vector.yral.com"
SSL_DIR="/etc/ssl/milvus"
ACME_HOME="/root/.acme.sh"
NGINX_CONF_DIR="/etc/nginx/conf.d"

echo "=== Milvus SSL Certificate Setup ==="

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
    echo "Installing acme.sh..."
    curl https://get.acme.sh | sh -s email=joel@gobazzinga.io
fi

# Stop nginx temporarily for standalone mode
echo "Stopping nginx temporarily for certificate acquisition..."
systemctl stop nginx

# Set ZeroSSL as default CA
"$ACME_HOME/acme.sh" --set-default-ca --server zerossl

# Issue certificate
echo "Obtaining SSL certificate from ZeroSSL..."
"$ACME_HOME/acme.sh" --issue -d "$DOMAIN" --standalone --httpport 80

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

# Start nginx with new config
echo "Starting nginx with HTTPS configuration..."
systemctl start nginx

echo "✓ SSL certificate setup complete"
echo "✓ Milvus is now accessible at https://$DOMAIN"
