FROM quay.io/fedora/fedora-bootc:latest

# Update system
RUN dnf update -y && dnf clean all

RUN dnf install -y \
    podman \
    nginx \
    socat \
    firewalld \
    curl \
    unzip \
    cronie \
    && dnf clean all

# Include unit files and containers
ADD etc /etc
ADD usr /usr

# Expose Milvus/Nginx ports
EXPOSE 80 443

# Create necessary directories
RUN mkdir -p /etc/ssl/milvus /var/www/html /var/log/nginx /var/lib/nginx/tmp/client_body /var/lib/nginx/tmp/proxy /var/lib/nginx/tmp/fastcgi /var/lib/nginx/tmp/uwsgi /var/lib/nginx/tmp/scgi

# Enable systemd services
RUN systemctl enable \
    milvus-prepare-dirs.service \
    nginx.service \
    firewalld.service \
    podman.socket \
    podman-auto-update.timer \
    milvus-firewall-setup.service \
    milvus-ssl-setup.service

# Enable Podman quadlet services (these are auto-generated from .container files)
# The quadlet files in /etc/containers/systemd/ will be automatically processed