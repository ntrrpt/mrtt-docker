FROM alpine:3.24 AS builder

ENV MRTT_SERVICE_MANAGER=docker \
    CARGO_HOME=/root/.cargo \
    RUSTUP_HOME=/root/.rustup \
    PATH=/root/.cargo/bin:/opt/zig:$PATH

# --no-cache
RUN apk add --progress \
    bash \
    build-base \
    ca-certificates \
    curl \
    git \
    musl-dev \
    openssl-dev \
    pkgconf \
    powershell \
    tar \
    xz \
    zig

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --profile minimal --component rustfmt --component clippy --default-toolchain 1.97.1

RUN cargo install cargo-zigbuild --locked

WORKDIR /src

RUN git clone https://github.com/ttrroyy/MRTT /src

ARG GIT_TAG
RUN if [ -n "${GIT_TAG:-}" ]; then \
        git checkout tags/${GIT_TAG}; \
    fi

ARG WEB_PANEL_ANY_ADDR=0
RUN if [ -n "${WEB_PANEL_ANY_ADDR:-}" ]; then \
        sed -i 's/\[127, 0, 0, 1\]/[0, 0, 0, 0]/g' /src/rust-server/web_panel.rs; \
    fi

COPY build-linux.sh /src/rust-server/build-linux.sh

ARG RUN_CHECKS=0
ARG DIAGNOSTICS=0
RUN chmod +x /src/rust-server/build-linux.sh \
    && bash /src/rust-server/build-linux.sh



FROM alpine:3.24 AS mrtt

ARG MRTT_BUILD_DNS_PRIMARY
ARG MRTT_BUILD_DNS_SECONDARY
RUN set -eu; \
    if [ -n "${MRTT_BUILD_DNS_PRIMARY:-}" ]; then \
        printf 'nameserver %s\n' "$MRTT_BUILD_DNS_PRIMARY" > /etc/resolv.conf; \
    fi; \
    if [ -n "${MRTT_BUILD_DNS_SECONDARY:-}" ]; then \
        printf 'nameserver %s\n' "$MRTT_BUILD_DNS_SECONDARY" >> /etc/resolv.conf; \
    fi; \
    timeout -k 5s 120s apk add --no-cache --no-progress \
        ca-certificates \
        iproute2 \
        iptables

COPY network-up.sh tun-recover.sh /usr/local/lib/mrtt/
COPY --from=builder /src/mrtt /usr/local/bin/mrtt

RUN chmod 0755 \
    /usr/local/bin/mrtt \
    /usr/local/lib/mrtt/network-up.sh \
    /usr/local/lib/mrtt/tun-recover.sh

ENTRYPOINT ["/bin/sh", "-ec", "/usr/local/lib/mrtt/network-up.sh; /usr/local/lib/mrtt/tun-recover.sh; exec /usr/local/bin/mrtt \"$@\"", "--"]