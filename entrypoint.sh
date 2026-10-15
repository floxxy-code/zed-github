
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
    die "REPO_NAME is invalid."
fi

if [[ ! "$SSH_PUBLIC_KEY" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521)[[:space:]] ]]; then
    die "SSH_PUBLIC_KEY is invalid."
fi

DEVELOPER_HOME="/home/developer"
REPO_URL="https://github.com/${GITHUB_OWNER}/${REPO_NAME}.git"
CREDENTIAL_DIR="${DEVELOPER_HOME}/.config/git"
CREDENTIAL_FILE="${CREDENTIAL_DIR}/credentials"

install -d -m 700 -o developer -g developer \
    "${DEVELOPER_HOME}/.ssh" "$CREDENTIAL_DIR"

printf '%s\n' "$SSH_PUBLIC_KEY" > "${DEVELOPER_HOME}/.ssh/authorized_keys"
chown developer:developer "${DEVELOPER_HOME}/.ssh/authorized_keys"
chmod 600 "${DEVELOPER_HOME}/.ssh/authorized_keys"
unset SSH_PUBLIC_KEY

umask 077
printf 'https://%s:%s@github.com\n' \
    "$GITHUB_USERNAME" "$GITHUB_TOKEN" > "$CREDENTIAL_FILE"
chown developer:developer "$CREDENTIAL_FILE"
chmod 600 "$CREDENTIAL_FILE"
unset GITHUB_TOKEN

as_developer() {
    runuser -u developer -- env HOME="$DEVELOPER_HOME" "$@"
}

as_developer git config --global credential.helper "store --file=$CREDENTIAL_FILE"
as_developer git config --global user.name "${GIT_AUTHOR_NAME:-$GITHUB_USERNAME}"
as_developer git config --global user.email "${GIT_AUTHOR_EMAIL:-${GITHUB_USERNAME}@users.noreply.github.com}"

if [[ ! -d /workspace/.git ]]; then
    if find /workspace -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
        die "/workspace is not empty and is not a Git repository."
    fi
    log "Cloning ${GITHUB_OWNER}/${REPO_NAME}..."
    as_developer git clone "$REPO_URL" /workspace \
        || die "Git clone failed. Check GitHub token permissions."
fi

as_developer git -C /workspace remote set-url origin "$REPO_URL"

mkdir -p /run/sshd
chmod 0755 /run/sshd
ssh-keygen -A

export PORT="${PORT:-10000}"
[[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) \
    || die "PORT is invalid."

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

ThreadingHTTPServer(("0.0.0.0", int(os.environ.get("PORT", "10000"))), Handler).serve_forever()
PYTHON

python3 /tmp/health_server.py &
HEALTH_PID=$!

/usr/sbin/sshd -D -e &
SSHD_PID=$!

cleanup() {
    log "Stopping workspace processes..."
    [[ -n "${NGROK_PID:-}" ]] && kill "$NGROK_PID" 2>/dev/null || true
    kill "$SSHD_PID" "$HEALTH_PID" 2>/dev/null || true
    wait 2>/dev/null || true
}
trap cleanup TERM INT EXIT

log "Configuring ngrok..."
ngrok config add-authtoken "$NGROK_AUTHTOKEN"
unset NGROK_AUTHTOKEN

sleep 2
kill -0 "$HEALTH_PID" 2>/dev/null || die "Health server failed."
kill -0 "$SSHD_PID" 2>/dev/null || die "SSH server failed."

# Keep ngrok alive if its agent exits unexpectedly.
while true; do
    log "Starting/restarting ngrok TCP tunnel for SSH port 22..."
    ngrok tcp 22 --log stdout &
    NGROK_PID=$!

    wait "$NGROK_PID" || true
    NGROK_PID=""

    log "ngrok exited. Retrying in 3 seconds..."
    sleep 3
done
