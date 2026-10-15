
#!/usr/bin/env bash
set -Eeuo pipefail

log() {
    printf '[workspace] %s\n' "$*"
}

die() {
    log "ERROR: $*"
    exit 1
}

# Validate required Render environment variables.
for name in GITHUB_TOKEN GITHUB_USERNAME GITHUB_OWNER REPO_NAME SSH_PUBLIC_KEY; do
    if [[ -z "${!name:-}" ]]; then
        die "Missing required environment variable: $name"
    fi
done

# Validate repository path components.
[[ "$GITHUB_OWNER" =~ ^[A-Za-z0-9-]+$ ]] ||
    die "GITHUB_OWNER is invalid."

[[ "$REPO_NAME" =~ ^[A-Za-z0-9._-]+$ ]] ||
    die "REPO_NAME must be a repository name, not owner/repository."

REPO_URL="https://github.com/${GITHUB_OWNER}/${REPO_NAME}.git"
DEVELOPER_HOME="/home/developer"
CREDENTIAL_DIR="${DEVELOPER_HOME}/.config/git"
CREDENTIAL_FILE="${CREDENTIAL_DIR}/credentials"

# Prepare SSH directories and authorised public key.
install -d -m 700 -o developer -g developer \
    "${DEVELOPER_HOME}/.ssh" \
    "$CREDENTIAL_DIR"

printf '%s\n' "$SSH_PUBLIC_KEY" \
    > "${DEVELOPER_HOME}/.ssh/authorized_keys"

chown developer:developer \
    "${DEVELOPER_HOME}/.ssh/authorized_keys"

chmod 600 "${DEVELOPER_HOME}/.ssh/authorized_keys"
unset SSH_PUBLIC_KEY

# Configure a private Git credential file at runtime.
# The token is never baked into the Docker image or Git remote URL.
umask 077
printf 'https://%s:%s@github.com\n' \
    "$GITHUB_USERNAME" "$GITHUB_TOKEN" > "$CREDENTIAL_FILE"

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

# Clone the private repository without putting credentials in its URL.
if [[ -d /workspace/.git ]]; then
    log "Git repository already exists; keeping it."
else
    if find /workspace -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
        die "/workspace is not empty and is not a Git repository."
    fi

    log "Cloning ${GITHUB_OWNER}/${REPO_NAME}..."

    if ! as_developer git clone "$REPO_URL" /workspace; then
        die "Git clone failed. Check token permissions, repository owner and repository name."
    fi
fi

as_developer git -C /workspace remote set-url origin "$REPO_URL"

# Generate SSH host keys at runtime.
ssh-keygen -A

# Configure the HTTP health endpoint on Render's assigned port.
export PORT="${PORT:-10000}"

[[ "$PORT" =~ ^[0-9]+$ ]] || die "PORT must be numeric."
(( PORT >= 1 && PORT <= 65535 )) || die "PORT is out of range."

cat > /tmp/health_server.py <<'PY'
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
    Handler,
)
server.serve_forever()
PY

log "Starting HTTP health server on port ${PORT}..."
python3 /tmp/health_server.py &

# Keep the SSH daemon in the foreground so Render tracks the service.
log "Starting SSH daemon on port 22..."
exec /usr/sbin/sshd -D -e
