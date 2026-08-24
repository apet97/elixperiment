# syntax=docker/dockerfile:1.7

FROM hexpm/elixir:1.20.3-erlang-29.0.5-alpine-3.24.1@sha256:a3db74529efc4a125feca654f0a6699ff573574be0bf1dc8e22b47a7119d69ba AS build

ARG HEX_VERSION=2.5.1
ARG REBAR3_VERSION=3.25.1
ARG REBAR3_SHA512=69073f6ad163f74971545015238614c327893960c1b3f26df5377df135c773a0716b48b65c2a48cef878f185dd92805abc69894adfa3fd27a90c62a64ba371e2

ENV MIX_ENV=prod \
    LANG=C.UTF-8

WORKDIR /build

RUN apk add --no-cache \
      build-base=0.5-r4 \
      ca-certificates=20260611-r0 \
      git=2.54.0-r0

RUN mix local.hex "${HEX_VERSION}" --force \
    && mix local.rebar rebar3 \
      "https://github.com/erlang/rebar3/releases/download/${REBAR3_VERSION}/rebar3" \
      --sha512 "${REBAR3_SHA512}" \
      --force

COPY mix.exs mix.lock ./
COPY config ./config

RUN mix deps.get --only prod \
    && mix deps.compile

COPY assets ./assets
COPY lib ./lib
COPY priv ./priv
COPY rel ./rel

RUN mix compile \
    && mix assets.deploy \
    && mix release

FROM alpine:3.24.1@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b AS runtime

ARG GIT_SHA=unbound
ARG RELEASE_VERSION=0.1.0

LABEL org.opencontainers.image.title="Pumble Automation" \
      org.opencontainers.image.description="Secure Pumble workflow automation service" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.version="${RELEASE_VERSION}"

ENV LANG=C.UTF-8 \
    HOME=/tmp \
    PHX_SERVER=true

RUN apk add --no-cache \
      ca-certificates=20260611-r0 \
      libcrypto3=3.5.7-r0 \
      libssl3=3.5.7-r0 \
      libstdc++=15.2.0-r5 \
      ncurses-libs=6.6_p20260516-r0 \
      tini=0.19.0-r3 \
      tzdata=2026c-r0 \
      zlib=1.3.2-r0

WORKDIR /app

COPY --from=build --chown=10001:10001 /build/_build/prod/rel/pumble_automation ./

USER 10001:10001

EXPOSE 4000

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["/app/bin/pumble_automation", "start"]
