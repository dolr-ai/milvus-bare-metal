#!/bin/bash
set -e

echo "=== Milvus Setup Script ==="
echo "Installing Milvus with persistent volumes and monitoring..."

# Generate random credentials
MILVUS_USER="admin"
MILVUS_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
echo "Generated Milvus credentials:"
echo "Username: $MILVUS_USER"
echo "Password: $MILVUS_PASSWORD"
echo ""
echo "IMPORTANT: Save these credentials!"
echo ""
read -p "Press Enter to continue..."

# Check and install Docker if needed
if ! command -v docker &> /dev/null; then
    echo "Installing Docker..."
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    rm get-docker.sh
fi

# Create directory structure
echo "Creating directory structure..."
mkdir -p /opt/milvus/volumes/{milvus,etcd,minio}
cd /opt/milvus

# Create docker-compose.yml
echo "Creating docker-compose.yml..."
cat > docker-compose.yml << 'EOF'
version: '3.5'

services:
  etcd:
    container_name: milvus-etcd
    image: quay.io/coreos/etcd:v3.5.5
    environment:
      - ETCD_AUTO_COMPACTION_MODE=revision
      - ETCD_AUTO_COMPACTION_RETENTION=1000
      - ETCD_QUOTA_BACKEND_BYTES=4294967296
      - ETCD_SNAPSHOT_COUNT=50000
    volumes:
      - ./volumes/etcd:/etcd
    command: etcd -advertise-client-urls=http://127.0.0.1:2379 -listen-client-urls http://0.0.0.0:2379 --data-dir /etcd
    healthcheck:
      test: ["CMD", "etcdctl", "endpoint", "health"]
      interval: 30s
      timeout: 20s
      retries: 3
    restart: unless-stopped
    networks:
      - milvus

  minio:
    container_name: milvus-minio
    image: minio/minio:RELEASE.2023-03-20T20-16-18Z
    environment:
      MINIO_ROOT_USER: minioadmin
      MINIO_ROOT_PASSWORD: minioadmin
    ports:
      - "9001:9001"
      - "9000:9000"
    volumes:
      - ./volumes/minio:/minio_data
    command: minio server /minio_data --console-address ":9001"
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:9000/minio/health/live"]
      interval: 30s
      timeout: 20s
      retries: 3
    restart: unless-stopped
    networks:
      - milvus

  standalone:
    container_name: milvus-standalone
    image: milvusdb/milvus:v2.3.3
    command: ["milvus", "run", "standalone"]
    security_opt:
      - seccomp:unconfined
    environment:
      ETCD_ENDPOINTS: etcd:2379
      MINIO_ADDRESS: minio:9000
      COMMON_SECURITY_AUTHORIZATIONENABLED: "true"
    volumes:
      - ./volumes/milvus:/var/lib/milvus
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:9091/healthz"]
      interval: 30s
      start_period: 90s
      timeout: 20s
      retries: 3
    ports:
      - "19530:19530"
      - "9091:9091"
    depends_on:
      - "etcd"
      - "minio"
    restart: unless-stopped
    networks:
      - milvus

  attu:
    container_name: milvus-attu
    image: zilliz/attu:latest
    ports:
      - "8000:3000"
    environment:
      MILVUS_URL: standalone:19530
      SERVER_PORT: 3000
    depends_on:
      standalone:
        condition: service_healthy
    restart: unless-stopped
    networks:
      - milvus

networks:
  milvus:
    driver: bridge
    name: milvus
EOF

# Configure firewall FIRST (before SSL)
echo "Configuring firewall..."
if command -v ufw &> /dev/null; then
    ufw allow 22/tcp     # SSH
    ufw allow 80/tcp     # HTTP (for Let's Encrypt)
    ufw allow 443/tcp    # HTTPS (Web UI)
    ufw allow 9443/tcp   # gRPC over TLS
    ufw --force enable
    echo "Firewall configured: Ports opened"
else
    echo "UFW not found, skipping firewall configuration"
fi

# Install Nginx and acme.sh
echo "Installing Nginx and acme.sh for SSL..."
apt-get update
apt-get install -y nginx socat

# Stop nginx temporarily
systemctl stop nginx

# Create initial Nginx config (HTTP only, no SSL yet)
cat > /etc/nginx/sites-available/milvus << 'NGINX_EOF'
# HTTP server block for web UI
server {
    listen 80;
    server_name vector.yral.com;

    location / {
        proxy_pass http://localhost:8000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host $host;
        proxy_cache_bypass $http_upgrade;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
NGINX_EOF

# Install acme.sh
if [ ! -f ~/.acme.sh/acme.sh ]; then
    echo "Installing acme.sh..."
    curl https://get.acme.sh | sh -s email=joel@gobazzinga.io
    source ~/.bashrc
fi

# Get SSL certificate from ZeroSSL (before starting nginx)
mkdir -p /etc/ssl/milvus

if [ ! -f /etc/ssl/milvus/fullchain.pem ]; then
    echo "Obtaining SSL certificate from ZeroSSL..."
    # Use acme.sh with ZeroSSL (standalone mode - nginx must be stopped)
    ~/.acme.sh/acme.sh --set-default-ca --server zerossl
    ~/.acme.sh/acme.sh --issue -d vector.yral.com --standalone --httpport 80

    # Install certificates (without reload since nginx isn't running yet)
    ~/.acme.sh/acme.sh --install-cert -d vector.yral.com \
      --key-file /etc/ssl/milvus/privkey.pem \
      --fullchain-file /etc/ssl/milvus/fullchain.pem

    echo "✓ ZeroSSL certificate obtained and installed"
else
    echo "✓ SSL certificates already exist, skipping..."
fi

# Now configure and start nginx
ln -sf /etc/nginx/sites-available/milvus /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

# Now add complete config with HTTPS redirect and gRPC with SSL
echo "Configuring Nginx with ZeroSSL certificates..."
cat > /etc/nginx/sites-available/milvus << 'NGINX_EOF'
# HTTP redirect to HTTPS
server {
    listen 80;
    server_name vector.yral.com;
    return 301 https://$server_name$request_uri;
}

# HTTPS server with both web UI and gRPC API
server {
    listen 443 ssl http2;
    server_name vector.yral.com;

    # ZeroSSL certificates (trusted by all clients)
    ssl_certificate /etc/ssl/milvus/fullchain.pem;
    ssl_certificate_key /etc/ssl/milvus/privkey.pem;

    # SSL configuration
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    # gRPC API on /api path
    location /milvus.proto {
        grpc_pass grpc://localhost:19530;
        grpc_set_header X-Real-IP $remote_addr;
        grpc_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        grpc_connect_timeout 60s;
        grpc_read_timeout 600s;
        grpc_send_timeout 600s;
    }

    # Web UI on root path
    location / {
        proxy_pass http://localhost:8000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host $host;
        proxy_cache_bypass $http_upgrade;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
NGINX_EOF

# Test and start nginx with new config
nginx -t
systemctl start nginx
systemctl enable nginx

echo "✓ Nginx with SSL configured"

# Save credentials to file
echo "Saving credentials..."
cat > /opt/milvus/credentials.txt << CRED_EOF
Milvus Authentication Credentials
==================================
Username: $MILVUS_USER
Password: $MILVUS_PASSWORD

Generated on: $(date)
CRED_EOF
chmod 600 /opt/milvus/credentials.txt

# Start services
echo "Starting Milvus services..."
docker compose up -d

# Wait for services to start
echo "Waiting for services to initialize (60 seconds)..."
sleep 60

# Note: Milvus authentication is enabled with default root/Milvus credentials
# Users should change the password via Attu or API after first login
echo "Note: Change default password 'Milvus' to generated password via Attu after first login"

# Check status
echo ""
echo "=== Service Status ==="
docker compose ps

echo ""
echo "=== Checking Health ==="
curl -s http://localhost:9091/healthz && echo "✓ Milvus is healthy" || echo "✗ Milvus health check failed"

echo ""
echo "=== Setup Complete ==="
echo ""
echo "🔐 INITIAL LOGIN CREDENTIALS:"
echo "Username: root"
echo "Password: Milvus"
echo ""
echo "⚠️  IMPORTANT: Change password immediately after first login!"
echo "Suggested new password: $MILVUS_PASSWORD"
echo "Credentials saved to: /opt/milvus/credentials.txt"
echo ""
echo "🔒 SECURE ACCESS:"
echo ""
echo "📱 Attu Web UI: https://vector.yral.com"
echo "   Username: root"
echo "   Password: Milvus"
echo "   Address (in Attu): standalone:19530"
echo "   SSL Toggle: OFF (no internal TLS needed)"
echo ""
echo "🔌 Milvus API (for apps): vector.yral.com:443"
echo "   ✓ ZeroSSL/HTTPS encryption"
echo "   ✓ Works from anywhere"
echo "   ✓ No certificate files needed!"
echo ""
echo "📦 Data persisted in: /opt/milvus/volumes/"
echo "🔐 SSL auto-renews via acme.sh"
echo ""
echo "📝 Example Python connection:"
echo "  from pymilvus import connections"
echo "  connections.connect("
echo "      host='vector.yral.com',"
echo "      port='443',"
echo "      user='root',"
echo "      password='YOUR_PASSWORD',"
echo "      secure=True"
echo "  )"
echo ""
echo "📊 Logs:"
echo "  Milvus: docker compose -f /opt/milvus/docker-compose.yml logs -f"
echo "  Nginx:  tail -f /var/log/nginx/error.log"
