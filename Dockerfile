# syntax=docker/dockerfile:1

FROM elixir:1.20-slim AS builder
WORKDIR /app
ENV MIX_ENV=prod

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates git build-essential \
    && rm -rf /var/lib/apt/lists/*

RUN mix local.hex --force && mix local.rebar --force
COPY mix.exs mix.lock ./
COPY config config
RUN mix deps.get && mix deps.compile
COPY lib lib
COPY skills skills
COPY config/allowlist.txt config/allowlist.txt
RUN mix compile && mix release

FROM debian:trixie-slim AS runner
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl libstdc++6 openssl \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --uid 1000 app

WORKDIR /app
COPY --from=builder --chown=app:app /app/_build/prod/rel/mcp_gateway ./
COPY --from=builder --chown=app:app /app/skills ./skills
COPY --from=builder --chown=app:app /app/config/allowlist.txt ./config/allowlist.txt

USER app
ENV PORT=8080 \
    BASE_URL=http://localhost:4000 \
    SKILLS_DIR=/app/skills \
    ALLOWLIST_PATH=/app/config/allowlist.txt \
    LANG=C.UTF-8

EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s \
    CMD curl -fsS "http://localhost:${PORT}/health" || exit 1

ENTRYPOINT ["/app/bin/mcp_gateway", "start"]
