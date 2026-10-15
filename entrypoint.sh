#!/bin/bash
set -e

# Establish human-style logging prefixes
log() { echo "[SYSTEM] $1"; }

log "Setting up workspace profile identities..."
git config --global user.email "${GITHUB_USERNAME}@://github.com"
git config --global user.name "${GITHUB_USERNAME}"
git config --global safe.directory /workspace

log "Purging stale directory blocks..."
rm -rf /workspace/{*,.*} 2>/dev/null || true

log "Fetching project repository state from GitHub..."
git clone "https://${GITHUB_TOKEN}@://github.com{GITHUB_USERNAME}/${REPO_NAME}.git" /workspace

# Serve basic plain-text string on port 80 to catch UptimeRobot monitoring hooks
log "Exposing local health-check framework on port 80..."
echo -e "HTTP/1.1 200 OK\r\nContent-Length: 12\r\n\r\nZed-Is-Active" | nc -lk -p 80 &

log "Starting internal OpenSSH network daemon..."
/usr/sbin/sshd

log "Evaluating active host validation keys..."
mkdir -p /root/.ssh
if [ ! -f /root/.ssh/id_ed25519 ]; then
    ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519 -N "" -q
fi

log "Initializing secure edge loopback proxy tunnel..."
while true; do
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -R 80:localhost:22 nokey@localhost.run || true
    sleep 5
done
