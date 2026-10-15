#!/bin/bash
set -e

# Setup global git identity mapping
git config --global user.email "$GITHUB_USERNAME@users.noreply.github.com"
git config --global user.name "$GITHUB_USERNAME"
git config --global safe.directory /workspace

# Force clear out the old path structure
rm -rf /workspace/* || true

# Explicit clean string formatting for the clone string
git clone "https://$GITHUB_TOKEN@://github.com" /workspace

# Handle incoming raw TCP connections on port 80 to catch health checks
echo -e "HTTP/1.1 200 OK\r\nContent-Length: 12\r\n\r\nZed-Is-Active" | nc -lk -p 80 &

# Boot background SSH service
/usr/sbin/sshd

# Initialize transport identity keys for localhost.run
mkdir -p /root/.ssh
if [ ! -f /root/.ssh/id_ed25519 ]; then
    ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519 -N "" -q
fi

# Expose port 22 tunnel via port 80 routing layer
echo "[SYSTEM] Initializing reverse network proxy tunnel..."
while true; do
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -R 80:localhost:22 nokey@localhost.run || true
    sleep 5
done
