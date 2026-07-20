ARG BASE_IMAGE=docker.m.daocloud.io/library/ubuntu:22.04

FROM ${BASE_IMAGE} AS downloader

ARG VECTOR_VERSION=0.33.1
ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates curl tar && \
    rm -rf /var/lib/apt/lists/*

RUN arch="$(dpkg --print-architecture)" && \
    case "${arch}" in \
      arm64) target="aarch64-unknown-linux-musl" ;; \
      amd64) target="x86_64-unknown-linux-musl" ;; \
      *) echo "Unsupported architecture: ${arch}" >&2; exit 1 ;; \
    esac && \
    curl --retry 5 --retry-delay 2 --retry-all-errors -fsSL \
      "https://github.com/vectordotdev/vector/releases/download/v${VECTOR_VERSION}/vector-${VECTOR_VERSION}-${target}.tar.gz" \
      -o /tmp/vector.tar.gz && \
    mkdir -p /opt/vector && \
    tar -xzf /tmp/vector.tar.gz -C /tmp && \
    vector_bin="$(find /tmp -type f -path '*/bin/vector' | head -n 1)" && \
    test -n "${vector_bin}" && \
    cp "${vector_bin}" /opt/vector/vector

FROM ${BASE_IMAGE}

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates && \
    rm -rf /var/lib/apt/lists/*

USER root

COPY --from=downloader /opt/vector/vector /usr/local/bin/vector
COPY entrypoint.sh /entrypoint.sh

RUN chmod 0755 /entrypoint.sh /usr/local/bin/vector

ENV HOST_VECTOR_DIR=/host-vector
ENV BOOTSTRAP_CONFIG=/bootstrap-config/vector.toml

ENTRYPOINT ["/entrypoint.sh"]
