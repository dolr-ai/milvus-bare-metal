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
    && dnf clean all

# Include unit files and containers
ADD etc /etc
ADD usr /usr

# Expose Milvus/Nginx ports
EXPOSE 80 443

# Create necessary directories
RUN mkdir -p /etc/ssl/milvus /var/www/html

# Enable systemd services
RUN systemctl enable \
    nginx.service \
    firewalld.service \
    podman.socket \
    podman-auto-update.timer \
    milvus-firewall-setup.service \
    milvus-ssl-setup.service

# Enable Podman quadlet services (these are auto-generated from .container files)
# The quadlet files in /etc/containers/systemd/ will be automatically processed