
#!/usr/bin/env bash
set -Eeuo pipefail

log() {
    printf '[workspace] %s\n' "$*"
}

die() {
    log "ERROR: $*"
    exit 1
}

for name in GITHUB_TOKEN GITHUB_USERNAME GITHUB_OWNER REPO_NAME SSH_PUBLIC_KEY NGROK_AUTHTOKEN; do
    if [[ -z "${!name:-}" ]]; then
        die "Missing required environment variable: $name"
    fi
done

if [[ ! "$GITHUB_OWNER" =~ ^[A-Za-z0-9-]+$ ]]; then
    die "GITHUB_OWNER is invalid."
fi

if [[ ! "$REPO_NAME" =~ ^[A-Za-z0-9._-]+$ ]]; then
    die "REPO_NAME must be a repository name, not owner/repository."
fi

if [[ ! "$SSH_PUBLIC_KEY" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521)[[:space:]] ]]; then
    die "SSH_PUBLIC_KEY is not a supported public key."
fi

DEVELOPER_HOME="/home/developer"
REPO_URL="https://github.com/${GITHUB_OWNER}/${REPO_NAME}.git"
CREDENTIAL_DIR="${DEVELOPER_HOME}/.config/git"
CREDENTIAL_FILE="${CREDENTIAL_DIR}/credentials"

install -d -m 700 -o developer -g developer \
    "${DEVELOPER_HOME}/.ssh" \
    "$CREDENTIAL_DIR"

printf '%s\n' "$SSH_PUBLIC_KEY" \
    > "${DEVELOPER_HOME}/.ssh/authorized_keys"

chown developer:developer "${DEVELOPER_HOME}/.ssh/authorized_keys"
chmod 600 "${DEVELOPER_HOME}/.ssh/authorized_keys"
unset SSH_PUBLIC_KEY

umask 077

printf 'https://%s:%s@github.com\n' \
    "$GITHUB_USERNAME" "$GITHUB_TOKEN" \
    > "$CREDENTIAL_FILE"

chown developer:developer "$CREDENTIAL_FILE"
chmod 600 "$CREDENTIAL_FILE"
unset GITHUB_TOKEN

as_developer() {
    runuser -u developer -- env HOME="$DEVELOPER_HOME" "$@"
}

as_developer git config --global \
    credential.helper "store --file=$CREDENTIAL_FILE"

as_developer git config --global \
    user.name "${GIT_AUTHOR_NAME:-$GITHUB_USERNAME}"

as_developer git config --global \
    user.email "${GIT_AUTHOR_EMAIL:-${GITHUB_USERNAME}@users.noreply.github.com}"

if [[ -d /workspace/.git ]]; then
    log "Git repository already exists; keeping it."
else
    if find /workspace -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
        die "/workspace is not empty and is not a Git repository."
    fi

    log "Cloning ${GITHUB_OWNER}/${REPO_NAME}..."

    if ! as_developer git clone "$REPO_URL" /workspace; then
        die "Git clone failed. Check repository name and token permissions."
    fi
fi

as_developer git -C /workspace remote set-url origin "$REPO_URL"

mkdir -p /run/sshd
chmod 0755 /run/sshd
ssh-keygen -A

export PORT="${PORT:-10000}"

if [[ ! "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
    die "PORT must be a valid TCP port."
fi

cat > /tmp/health_server.py <<'PYTHON'
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BODY = b"Zed-Is-Active"

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(BODY)))
        self.end_headers()
        self.wfile.write(BODY)

    def do_HEAD(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(BODY)))
        self.end_headers()

    def log_message(self, fmt, *args):
        pass

server = ThreadingHTTPServer(
    ("0.0.0.0", int(os.environ.get("PORT", "10000"))),
    Handler
)
server.serve_forever()
PYTHON

python3 -c "from http.server import ThreadingHTTPServer" \
    || die "Python HTTP support is missing."

log "Starting HTTP health server on port ${PORT}..."
python3 /tmp/health_server.py &
HEALTH_PID=$!

sleep 2

if ! kill -0 "$HEALTH_PID" 2>/dev/null; then
    die "HTTP health server failed to start."
fi

log "Starting SSH daemon on port 22..."
/usr/sbin/sshd -D -e &
SSHD_PID=$!

sleep 1

if ! kill -0 "$SSHD_PID" 2>/dev/null; then
    die "SSH daemon failed to start."
fi

log "Configuring ngrok authentication..."
ngrok config add-authtoken "$NGROK_AUTHTOKEN"
unset NGROK_AUTHTOKEN

log "Starting ngrok TCP tunnel for SSH port 22..."
log "Find the assigned public TCP address in the ngrok output below."

exec ngrok tcp 22 --log stdout
