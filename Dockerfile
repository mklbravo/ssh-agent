FROM debian:trixie-slim@sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2

RUN apt-get update \
    && apt-get install --yes --no-install-recommends bash openssh-client socat tini util-linux \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 2522 ssh-agent \
    && useradd --uid 2521 --gid 2522 --no-create-home \
        --home-dir /var/lib/ssh-agent --shell /usr/sbin/nologin ssh-agent \
    && install -d -o 2521 -g 2522 -m 0700 /var/lib/ssh-agent/keys \
    && install -d -o 2521 -g 2522 -m 0710 /run/ssh-agent

COPY --chown=0:0 rootfs/ /

USER 2521:2522

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD ["env", "SSH_AUTH_SOCK=/run/ssh-agent/auth.sock", "ssh-add", "-l"]

ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/usr/local/bin/ssh-agent-entrypoint"]
