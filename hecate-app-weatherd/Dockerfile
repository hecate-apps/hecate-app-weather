# hecate-app-weather Dockerfile
# Lightweight Erlang release for mesh RPC weather gateway

# Build stage
FROM erlang:27-alpine AS builder

WORKDIR /build

RUN apk add --no-cache git curl bash build-base

RUN curl -fsSL https://s3.amazonaws.com/rebar3/rebar3 -o /usr/local/bin/rebar3 && \
    chmod +x /usr/local/bin/rebar3

# Deps first (cacheable layer)
COPY rebar.config ./
RUN rebar3 get-deps

# Source
COPY config/ config/
COPY src/ src/

# Build release
RUN rebar3 compile
RUN rebar3 as prod release

# Runtime stage
FROM alpine:3.22

RUN apk add --no-cache \
    ncurses-libs \
    libstdc++ \
    libgcc \
    openssl \
    ca-certificates

WORKDIR /app

COPY --from=builder /build/_build/prod/rel/hecate_app_weatherd ./

ENV HOME=/app

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD /app/erts-*/bin/epmd -names 2>/dev/null | grep -q hecate || exit 1

CMD ["bin/hecate_app_weatherd", "foreground"]
