#!/bin/bash
# Redlib setup for neil.social VPS
# Run this on the VPS as neil

set -e

# Download and install binary
cd /tmp
wget https://github.com/redlib-org/redlib/releases/download/v0.36.0/redlib-x86_64-unknown-linux-musl.tar.gz
tar xzf redlib-x86_64-unknown-linux-musl.tar.gz
sudo mv redlib /usr/local/bin/redlib
sudo chmod +x /usr/local/bin/redlib
rm redlib-x86_64-unknown-linux-musl.tar.gz

echo "Done! Now install the systemd service:"
echo "  sudo cp redlib.service /etc/systemd/system/"
echo "  sudo systemctl daemon-reload"
echo "  sudo systemctl enable --now redlib"
echo ""
echo "Then add the NGINX block and reload:"
echo "  sudo nginx -t && sudo systemctl reload nginx"
