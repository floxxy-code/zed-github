
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        openssh-server \
        git \
        ca-certificates \
        curl \
        tar \
        python3 \
        passwd \
        util-linux \
    && curl -fsSL \
        https://bin.ngrok.com/c/bNyj1mQVY4c/ngrok-v3-stable-linux-amd64.tgz \
        -o /tmp/ngrok.tgz \
    && tar -xzf /tmp/ngrok.tgz -C /usr/local/bin \
    && chmod 0755 /usr/local/bin/ngrok \
    && rm -f /tmp/ngrok.tgz \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --shell /bin/bash developer \
    && mkdir -p /run/sshd /workspace \
    && chown developer:developer /workspace \
    && sed -ri 's/^#?PermitRootLogin .*/PermitRootLogin no/' /etc/ssh/sshd_config \
    && sed -ri 's/^#?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config \
    && sed -ri 's/^#?KbdInteractiveAuthentication .*/KbdInteractiveAuthentication no/' /etc/ssh/sshd_config \
    && sed -ri 's/^#?PubkeyAuthentication .*/PubkeyAuthentication yes/' /etc/ssh/sshd_config \
    && sed -ri 's/^#?UsePAM .*/UsePAM no/' /etc/ssh/sshd_config \
    && grep -qE '^UsePAM ' /etc/ssh/sshd_config \
    || printf '\nUsePAM no\n' >> /etc/ssh/sshd_config

WORKDIR /workspace

COPY entrypoint.sh /entrypoint.sh

RUN sed -i 's/\r$//' /entrypoint.sh \
    && sed -i '1s/^\xEF\xBB\xBF//' /entrypoint.sh \
    && chmod 0755 /entrypoint.sh

EXPOSE 10000

ENTRYPOINT ["/bin/bash", "/entrypoint.sh"]
