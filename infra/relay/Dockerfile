FROM alpine:3.22@sha256:5291449c3df73caf6ed85e649dec1b9e818b39a5d8c871e97afc13e9cd5e8fa8 AS download
ARG TARGETARCH
WORKDIR /download
# Pin the release and verify GitHub's published asset digest before extracting it.
RUN case "$TARGETARCH" in \
      amd64) target=x86_64; checksum=677f4c62342a6ba8044459b5fd4302f2b1dcb8402542072e3a4ade5039bc0b9e ;; \
      arm64) target=aarch64; checksum=dc4b9d620642026966d498763ec8ba3a6eefde8d39994b2d63e3d15d7af770f8 ;; \
      *) echo "Unsupported architecture: $TARGETARCH" >&2; exit 1 ;; \
    esac \
    && wget -q "https://github.com/n0-computer/iroh/releases/download/v1.3.0/iroh-relay-v1.3.0-${target}-unknown-linux-musl.tar.gz" -O relay.tar.gz \
    && echo "$checksum  relay.tar.gz" | sha256sum -c - \
    && tar -xzf relay.tar.gz \
    && find . -type f -name iroh-relay -exec cp '{}' /iroh-relay \;

FROM alpine:3.22@sha256:5291449c3df73caf6ed85e649dec1b9e818b39a5d8c871e97afc13e9cd5e8fa8
RUN apk add --no-cache python3 py3-aiohttp py3-cryptography
RUN addgroup -S relay && adduser -S -G relay relay
COPY --from=download /iroh-relay /usr/local/bin/iroh-relay
COPY gateway.py /usr/local/bin/relay-gateway.py
COPY relay.toml /etc/iroh-relay/relay.toml
COPY --chmod=755 entrypoint.sh /usr/local/bin/relay-entrypoint
USER relay
EXPOSE 8080
ENV RUST_LOG=info
# Iroh handles SIGINT gracefully; Docker otherwise defaults to SIGTERM.
STOPSIGNAL SIGINT
HEALTHCHECK --interval=15s --timeout=3s --start-period=5s --retries=3 \
    CMD wget -q -O /dev/null http://127.0.0.1:8080/ping || exit 1
ENTRYPOINT ["/usr/local/bin/relay-entrypoint"]
