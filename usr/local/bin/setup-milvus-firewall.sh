#!/bin/bash
set -e

echo "=== Configuring Firewall for Milvus ==="

# Configure firewalld
if command -v firewall-cmd &> /dev/null; then
    echo "Configuring firewalld..."

    # Enable firewalld if not already running
    systemctl enable --now firewalld

    # Open required ports
    firewall-cmd --permanent --add-service=ssh
    firewall-cmd --permanent --add-service=http
    firewall-cmd --permanent --add-service=https

    # Reload firewall
    firewall-cmd --reload

    echo "✓ Firewall configured successfully"
else
    echo "⚠ firewalld not found, skipping firewall configuration"
fi

# Configure SELinux for nginx to connect to backend services
if command -v setsebool &> /dev/null; then
    echo "Configuring SELinux for nginx..."
    setsebool -P httpd_can_network_connect on
    echo "✓ SELinux configured successfully"
else
    echo "⚠ SELinux tools not found, skipping SELinux configuration"
fi

echo "✓ Firewall setup complete"
