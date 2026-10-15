
#!/usr/bin/env bash
set -Eeuo pipefail

log() {
    printf '[workspace] %s\n' "$*"
}

die() {
    log "ERROR: $*"
    exit 1
}

# Fail immediately instead of constructing a malformed URL.
for name in GITHUB_TOKEN GITHUB_USERNAME GITHUB_OWNER REPO_NAME SSH_PUBLIC_KEY; do
    [[ -n "${!name:-}" ]] ||
        die "Required Render environment variable '$name' is missing or empty."
done

# Validate the repository path components.
[[ "$GITHUB_OWNER" =~ ^[A-Za-z0-9-]+$ ]] ||
    die "GITHUB_OWNER must be a GitHub account or organization name."

[[ "$REPO_NAME" =~ ^[A-Za-z0-9._-]+$ ]] ||
    die "REPO_NAME must contain only the repository name, not owner/repo."

REPO_URL="https://github.com/${GITHUB_OWNER}/${REPO_NAME}.git"

CREDENTIAL_DIR="/home/developer/.config/git"
CREDENTIAL_FILE="${CREDENTIAL_DIR}/credentials"

mkdir -p /run/sshd /workspace

# Configure key-only SSH access for the developer account.
install -d -m 700 -o developer -g developer \
    /home/developer/.ssh "$CREDENTIAL_DIR"

printf '%s\n' "$SSH_PUBLIC_KEY" \
    > /home/developer/.ssh/authorized_keys

chown developer:developer /home/developer/.ssh/authorized_keys
chmod 600 /home/developer/.ssh/authorized_keys
unset SSH_PUBLIC_KEY

# Give the SSH account a random runtime-only password.
# SSH password authentication is disabled in sshd_config.
RANDOM_PASSWORD="$(head -c 48 /dev/urandom | base64 | tr -d '\n')"
printf 'developer:%s\n' "$RANDOM_PASSWORD" | chpasswd
unset RANDOM_PASSWORD

# Store the HTTPS credential outside the repository.
# This is a runtime file, not part of the Docker image.
printf 'https://%s:%s@github.com\n' \
    "$GITHUB_USERNAME" "$GITHUB_TOKEN" > "$CREDENTIAL_FILE"

chown developer:developer "$CREDENTIAL_FILE"
chmod 600 "$CREDENTIAL_FILE"
unset GITHUB_TOKEN

# Run Git with the development user's HOME and configuration.
as_developer() {
    runuser -u developer -- env HOME=/home/developer "$@"
}

as_developer git config --global \
    credential.helper "store --file=$CREDENTIAL_FILE"

as_developer git config --global \
    user.name "${GIT_AUTHOR_NAME:-$GITHUB_USERNAME}"

as_developer git config --global \
    user.email "${GIT_AUTHOR_EMAIL:-${GITHUB_USERNAME}@users.noreply.github.com}"

# Clone without embedding the token in the repository's remote URL.
if [[ -d /workspace/.git ]]; then
    log "Repository already exists in /workspace; keeping it."
else
    if find /workspace -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
        die "/workspace is not empty but has no .git directory; refusing to delete files."
    fi

    log "Cloning private repository ${GITHUB_OWNER}/${REPO_NAME}..."

    as_developer git clone -- "$REPO_URL" /workspace
fi

# Ensure origin contains only the public repository URL.
as_developer git -C /workspace remote set-url origin "$REPO_URL"

# Generate SSH host keys if they do not already exist.
ssh-keygen -A

# Render's HTTP health listener must use its configured PORT.
export PORT="${PORT:-10000}"

[[ "$PORT" =~ ^[0-9]+$ ]] || die "PORT must be numeric."

cat > /tmp/health_server.py <<'PY'
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BODY = b"Zed-Is-Active"

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(BODY)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(BODY)

    def do_HEAD(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(BODY)))
        self.send_header("Connection", "close")
        self.end_headers()

    def log_message(self, fmt, *args):
        pass

ThreadingHTTPServer(
    ("0.0.0.0", int(os.environ.get("PORT", "10000"))),
    Handler
).serve_forever()
PY

python3 /tmp/health_server.py &

log "Starting SSH server with key-only authentication."
exec /usr/sbin/sshd -D -e
