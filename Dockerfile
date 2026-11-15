# syntax=docker/dockerfile:1

FROM elixir:1.20-slim AS builder
WORKDIR /app
ENV MIX_ENV=prod

# The elixir slim image ships without a CA bundle; OTP 29 refuses TLS without one.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN mix local.hex --force && mix local.rebar --force
COPY mix.exs mix.lock ./
COPY config config
RUN mix deps.get && mix deps.compile
COPY lib lib
RUN mix compile --warnings-as-errors && mix release

FROM debian:trixie-slim AS runner
ARG TARGETARCH

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl xz-utils libatomic1 \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --uid 1000 app

# Node.js LTS with npm/npx, checksum-verified, so npx-based MCP upstreams
# work out of the box. Pinned: bump deliberately, never implicitly.
RUN cd /tmp \
    && NODE_ARCH="${TARGETARCH/amd64/x64}" \
    && curl -fsSL "https://nodejs.org/dist/v26.13.1/SHASUMS256.txt" -o SHASUMS256.txt \
    && curl -fsSL "https://nodejs.org/dist/v26.13.1/node-v26.13.1-linux-${NODE_ARCH}.tar.xz" -O \
    && grep " node-v26.13.1-linux-${NODE_ARCH}.tar.xz$" SHASUMS256.txt > check.txt \
    && sha256sum -c check.txt \
    && tar -xJf "node-v26.13.1-linux-${NODE_ARCH}.tar.xz" -C /usr/local --strip-components=1 \
    && rm "node-v26.13.1-linux-${NODE_ARCH}.tar.xz" SHASUMS256.txt check.txt

WORKDIR /app
COPY --from=builder --chown=app:app /app/_build/prod/rel/mcp_gateway ./

USER app
ENV PORT=8080 \
    MCP_UPSTREAMS=[] \
    LANG=C.UTF-8

EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s \
    CMD curl -fsS "http://localhost:${PORT}/health" || exit 1

ENTRYPOINT ["/app/bin/mcp_gateway", "start"]
